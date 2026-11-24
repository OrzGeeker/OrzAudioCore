import { AudioDecoder, OrzAudioCoreError, createDecoder, type EmscriptenOrzModule } from './index.js';
import {
  ControlIndex,
  ORZ_PCM_PROTOCOL_VERSION,
  StreamState,
  freeFrames,
  resetRing,
  usedFrames,
  type DecodeRequest,
  type WorkerRequest,
  type WorkerResponse,
} from './protocol.js';

type ModuleFactory = (options?: { locateFile?: (path: string, prefix: string) => string }) => Promise<EmscriptenOrzModule>;

interface ActiveStream {
  generation: number;
  decoder: AudioDecoder;
  stop: boolean;
  seek: number | null;
  rendered: number;
  control?: Int32Array;
  ring?: Float32Array;
  capacityFrames: number;
  channels: number;
  sampleRate: number;
  startedAt: number;
}

const scope = globalThis as unknown as {
  postMessage(message: WorkerResponse, transfer?: Transferable[]): void;
  addEventListener(type: 'message', listener: (event: MessageEvent<WorkerRequest>) => void): void;
  location?: { href: string };
};

let modulePromise: Promise<EmscriptenOrzModule> | undefined;
let moduleUrlOverride: string | undefined;
let wasmUrlOverride: string | undefined;
let active: ActiveStream | undefined;

function moduleUrl(): string {
  return moduleUrlOverride ?? new URL('../wasm/orz_audio_builtin.mjs', import.meta.url).href;
}

async function loadModule(): Promise<EmscriptenOrzModule> {
  if (!modulePromise) {
    modulePromise = (async () => {
      const url = moduleUrl();
      const namespace = await import(/* @vite-ignore */ url) as {
        default?: ModuleFactory;
        OrzAudioCoreModule?: ModuleFactory;
      };
      const factory = namespace.default ?? namespace.OrzAudioCoreModule;
      if (!factory) throw new Error(`OrzAudioCore WASM module ${url} has no default factory`);
      const base = wasmUrlOverride ?? new URL('../wasm/', url).href;
      return factory({ locateFile: path => (path.endsWith('.wasm') ? wasmUrlOverride ?? `${base}${path}` : `${base}${path}`) });
    })().catch(error => {
      modulePromise = undefined;
      throw error;
    });
  }
  return modulePromise;
}

function waitTurn(): Promise<void> {
  return new Promise(resolve => setTimeout(resolve, 2));
}

function consume(message: WorkerRequest): void {
  if (message.type === 'init') {
    moduleUrlOverride = message.moduleUrl;
    wasmUrlOverride = message.wasmUrl;
    modulePromise = undefined;
    scope.postMessage({ type: 'warmed', protocolVersion: ORZ_PCM_PROTOCOL_VERSION });
    return;
  }
  if (message.type === 'warmup') {
    moduleUrlOverride = message.moduleUrl ?? moduleUrlOverride;
    loadModule().then(
      () => scope.postMessage({ type: 'warmed', protocolVersion: ORZ_PCM_PROTOCOL_VERSION }),
      error => scope.postMessage({ type: 'error', generation: 0, message: error instanceof Error ? error.message : String(error) }),
    );
    return;
  }
  if (message.type === 'stop') {
    if (active?.decoder) active.stop = true;
    active?.decoder.cancel();
    return;
  }
  if (message.type === 'seek') {
    if (active && active.generation === message.generation) active.seek = message.positionMs;
    return;
  }
  if (message.type === 'stats') {
    scope.postMessage({
      type: 'stats',
      generation: active?.generation ?? 0,
      underruns: active?.control ? Atomics.load(active.control, ControlIndex.underruns) : 0,
      renderedFrames: active?.rendered ?? 0,
    });
    return;
  }
  if (message.type === 'decode') {
    void decode(message).catch(error => {
      active?.control && Atomics.store(active.control, ControlIndex.state, StreamState.Failed);
      scope.postMessage({
        type: 'error',
        generation: message.generation,
        message: error instanceof Error ? error.message : String(error),
        status: typeof (error as { status?: number }).status === 'number' ? (error as { status: number }).status : undefined,
      });
      active?.decoder.close();
      active = undefined;
    });
  }
}

async function decode(message: DecodeRequest): Promise<void> {
  active?.decoder.close();
  active = undefined;
  const module = await loadModule();
  const decoder = createDecoder(module, new Uint8Array(message.data), message.format);
  if (message.subsong && message.subsong > 0) decoder.selectSubsong(message.subsong);
  const info = decoder.info;
  const channels = message.channels ?? info.channels ?? 2;
  let control: Int32Array | undefined;
  let ring: Float32Array | undefined;
  let capacityFrames = message.capacityFrames ?? 0;
  if (message.control && message.samples) {
    control = new Int32Array(message.control);
    ring = new Float32Array(message.samples);
    capacityFrames = message.capacityFrames ?? ring.length / channels;
    resetRing(control, message.generation);
    Atomics.store(control, ControlIndex.generation, message.generation);
  }
  const stream: ActiveStream = {
    generation: message.generation,
    decoder,
    stop: false,
    seek: null,
    rendered: 0,
    control,
    ring,
    capacityFrames,
    channels,
    sampleRate: info.sampleRate || 44100,
    startedAt: performance.now(),
  };
  active = stream;
  scope.postMessage({
    type: 'ready', generation: stream.generation, sampleRate: stream.sampleRate,
    channels, duration: info.duration, subsongCount: info.subsongCount,
  });

  const chunkFrames = message.chunkFrames ?? 2048;
  const startFrames = message.startFrames ?? Math.min(stream.sampleRate, capacityFrames ? capacityFrames / 2 : 4096);
  while (!stream.stop) {
    if (stream.seek !== null) {
      if (!await performSeek(stream, module, message)) break;
    }
    if (control && ring) {
      const free = freeFrames(control, capacityFrames);
      if (free < chunkFrames) {
        await waitTurn();
        continue;
      }
      const pcm = renderOrStop(decoder, Math.min(chunkFrames, free));
      if (!pcm) break;
      if (pcm.length === 0) break;
      const frames = pcm.length / channels;
      let write = Atomics.load(control, ControlIndex.write);
      for (let frame = 0; frame < frames; frame++) {
        const target = ((write + frame) % capacityFrames) * channels;
        for (let channel = 0; channel < channels; channel++) {
          ring[target + channel] = pcm[frame * channels + Math.min(channel, info.channels - 1)];
        }
      }
      Atomics.store(control, ControlIndex.write, (write + frames) % capacityFrames);
      stream.rendered += frames;
      if (Atomics.load(control, ControlIndex.state) === StreamState.Priming &&
          usedFrames(Atomics.load(control, ControlIndex.write), Atomics.load(control, ControlIndex.read), capacityFrames) >= startFrames) {
        Atomics.store(control, ControlIndex.state, StreamState.Running);
        scope.postMessage({ type: 'started', generation: stream.generation });
      }
      // A seek request may have arrived during render; yielding also lets a
      // stop message run before the next chunk.
      await waitTurn();
    } else {
      const pcm = renderOrStop(decoder, Math.min(chunkFrames, message.chunkFrames ?? 2048));
      if (!pcm) break;
      const end = pcm.length === 0;
      scope.postMessage({
        type: 'pcm', generation: stream.generation, samples: pcm, frames: pcm.length / channels,
        channels, sampleRate: stream.sampleRate, end,
      }, [pcm.buffer]);
      if (end) break;
      stream.rendered += pcm.length / channels;
      await waitTurn();
    }
  }

  if (control) {
    Atomics.store(control, ControlIndex.state, stream.stop ? StreamState.Stopped : StreamState.Ended);
  }
  const underruns = control ? Atomics.load(control, ControlIndex.underruns) : 0;
  if (stream.generation === active?.generation) {
    scope.postMessage({
      type: stream.stop ? 'stopped' : 'ended',
      generation: stream.generation,
      rendered: stream.rendered,
      decodeRate: stream.rendered / stream.sampleRate / Math.max((performance.now() - stream.startedAt) / 1000, 0.001),
      underruns,
    } as WorkerResponse);
  }
  decoder.close();
  if (active === stream) active = undefined;
}

function renderOrStop(decoder: AudioDecoder, frames: number): Float32Array | null {
  try {
    return decoder.render(frames);
  } catch (error) {
    if (error instanceof OrzAudioCoreError && error.status === -6) return null;
    throw error;
  }
}

async function performSeek(stream: ActiveStream, module: EmscriptenOrzModule, message: DecodeRequest): Promise<boolean> {
  const position = stream.seek!;
  stream.seek = null;
  if (stream.control) {
    resetRing(stream.control, stream.generation);
    Atomics.store(stream.control, ControlIndex.generation, stream.generation);
  }
  try {
    stream.decoder.seek(position);
  } catch {
    const replacement = createDecoder(module, new Uint8Array(message.data), message.format);
    if (message.subsong && message.subsong > 0) replacement.selectSubsong(message.subsong);
    stream.decoder.close();
    stream.decoder = replacement;
    let remaining = Math.floor(position * stream.sampleRate / 1000);
    while (remaining > 0 && !stream.stop) {
      const frames = stream.decoder.render(Math.min(2048, remaining)).length / stream.channels;
      if (frames <= 0) throw new Error(`cannot seek ${message.format} to ${position}ms`);
      remaining -= frames;
      await waitTurn();
    }
  }
  stream.rendered = Math.floor(position * stream.sampleRate / 1000);
  scope.postMessage({ type: 'seeked', generation: stream.generation, positionMs: position });
  return !stream.stop;
}

scope.addEventListener('message', event => consume(event.data));
