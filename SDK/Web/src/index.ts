export const ORZ_ABI_VERSION = 0x0001_0000;
export const ORZ_OK = 0;
export const ORZ_END_OF_STREAM = 1;

export interface EmscriptenOrzModule {
  HEAPU8: Uint8Array;
  HEAPU32: Uint32Array;
  HEAPF64: Float64Array;
  HEAPF32: Float32Array;
  _malloc(size: number): number;
  _free(pointer: number): void;
  _orz_abi_version(): number;
  _orz_build_info(): number;
  _orz_get_format_count(): number;
  _orz_get_format_info(index: number, output: number): number;
  _orz_decoder_create_memory(data: number, size: number, format: number, config: number, output: number): number;
  _orz_decoder_get_stream_info(decoder: number, output: number): number;
  _orz_decoder_render_f32(decoder: number, output: number, frames: number, rendered: number): number;
  _orz_decoder_seek(decoder: number, milliseconds: number | bigint): number;
  _orz_decoder_select_subsong_v1(decoder: number, subsong: number): number;
  _orz_decoder_reset(decoder: number): number;
  _orz_decoder_cancel(decoder: number): number;
  _orz_decoder_destroy_v1(decoder: number): void;
  UTF8ToString(pointer: number): string;
  stringToUTF8(value: string, pointer: number, capacity: number): void;
  lengthBytesUTF8(value: string): number;
}

export interface StreamInfo { sampleRate: number; channels: number; duration: number; subsongCount: number; capabilities: number }

export interface DecoderDependency { id: string; version: string }

export interface BuildInfo {
  sdk: string;
  version: string;
  abi: string;
  profile: string;
  fingerprint: string;
  cacheNamespace: string;
  formats: string[];
  decoders: DecoderDependency[];
}

export interface FormatInfo {
  id: string;
  displayName: string;
  decoderID: string;
  decoderVersion: string;
  category: string;
  capabilities: number;
}

const FORMAT_INFO_SIZE = 56;

/** Parse the stable `orz_build_info()` JSON returned by the WASM module. */
export function buildInfo(module: EmscriptenOrzModule): BuildInfo {
  const pointer = module._orz_build_info();
  if (!pointer) throw new OrzAudioCoreError(-7, 'build info');
  const parsed = JSON.parse(module.UTF8ToString(pointer)) as Partial<BuildInfo>;
  if (!parsed.profile || !parsed.cacheNamespace || !Array.isArray(parsed.formats)) {
    throw new OrzAudioCoreError(-7, 'build info is missing profile/cacheNamespace/formats');
  }
  return {
    sdk: parsed.sdk ?? 'OrzAudioCore',
    version: parsed.version ?? 'unknown',
    abi: parsed.abi ?? 'unknown',
    profile: parsed.profile,
    fingerprint: parsed.fingerprint ?? parsed.cacheNamespace,
    cacheNamespace: parsed.cacheNamespace,
    formats: parsed.formats,
    decoders: parsed.decoders ?? []
  };
}

/**
 * Runtime format list straight from the loaded binary. Compare it with the
 * package manifest to detect a binary/manifest mismatch before playback.
 */
export function supportedFormats(module: EmscriptenOrzModule): FormatInfo[] {
  const count = module._orz_get_format_count();
  const output: FormatInfo[] = [];
  const pointer = module._malloc(FORMAT_INFO_SIZE);
  try {
    for (let index = 0; index < count; index++) {
      module.HEAPU8.fill(0, pointer, pointer + FORMAT_INFO_SIZE);
      module.HEAPU32[pointer >>> 2] = FORMAT_INFO_SIZE;
      module.HEAPU32[(pointer + 4) >>> 2] = module._orz_abi_version();
      check(module._orz_get_format_info(index, pointer), 'format info');
      const string = (offset: number) => {
        const address = module.HEAPU32[(pointer + offset) >>> 2];
        return address ? module.UTF8ToString(address) : '';
      };
      output.push({
        id: string(8), displayName: string(12), decoderID: string(16),
        decoderVersion: string(20), category: string(24),
        capabilities: module.HEAPU32[(pointer + 28) >>> 2]
      });
    }
  } finally { module._free(pointer); }
  return output;
}

export class OrzAudioCoreError extends Error {
  constructor(public readonly status: number, operation: string) { super(`${operation} failed with OrzAudioCore status ${status}`); }
}

export class AudioDecoder {
  readonly info: StreamInfo;
  #handle: number;
  constructor(private readonly module: EmscriptenOrzModule, handle: number) {
    this.#handle = handle;
    const pointer = module._malloc(64);
    try {
      module.HEAPU8.fill(0, pointer, pointer + 64);
      module.HEAPU32[pointer >>> 2] = 64;
      module.HEAPU32[(pointer + 4) >>> 2] = ORZ_ABI_VERSION;
      check(module._orz_decoder_get_stream_info(handle, pointer), 'stream info');
      this.info = {
        sampleRate: module.HEAPU32[(pointer + 8) >>> 2], channels: module.HEAPU32[(pointer + 12) >>> 2],
        duration: module.HEAPF64[(pointer + 16) >>> 3], subsongCount: module.HEAPU32[(pointer + 24) >>> 2],
        capabilities: module.HEAPU32[(pointer + 28) >>> 2]
      };
    } finally { module._free(pointer); }
  }
  render(maxFrames: number): Float32Array {
    if (!this.#handle || maxFrames <= 0) throw new OrzAudioCoreError(-1, 'render');
    const bytes = maxFrames * this.info.channels * 4;
    const pcm = this.module._malloc(bytes), rendered = this.module._malloc(4);
    try {
      const status = this.module._orz_decoder_render_f32(this.#handle, pcm, maxFrames, rendered);
      if (status === ORZ_END_OF_STREAM) return new Float32Array();
      check(status, 'render');
      const count = this.module.HEAPU32[rendered >>> 2] * this.info.channels;
      return this.module.HEAPF32.slice(pcm >>> 2, (pcm >>> 2) + count);
    } finally { this.module._free(rendered); this.module._free(pcm); }
  }
  seek(milliseconds: number): void {
    // Emscripten builds with WASM_BIGINT require BigInt for the uint64 ABI.
    const position = typeof BigInt === 'function' ? BigInt(Math.max(0, Math.trunc(milliseconds))) : milliseconds;
    check(this.module._orz_decoder_seek(this.#handle, position), 'seek');
  }
  selectSubsong(index: number): void { check(this.module._orz_decoder_select_subsong_v1(this.#handle, index), 'select subsong'); }
  reset(): void { check(this.module._orz_decoder_reset(this.#handle), 'reset'); }
  cancel(): void { if (this.#handle) this.module._orz_decoder_cancel(this.#handle); }
  close(): void { if (this.#handle) { this.module._orz_decoder_destroy_v1(this.#handle); this.#handle = 0; } }
}

export function createDecoder(module: EmscriptenOrzModule, data: Uint8Array, format: string): AudioDecoder {
  if (module._orz_abi_version() !== ORZ_ABI_VERSION) throw new OrzAudioCoreError(-8, 'ABI negotiation');
  const dataPointer = module._malloc(data.length), length = module.lengthBytesUTF8(format) + 1;
  const formatPointer = module._malloc(length), outputPointer = module._malloc(4);
  try {
    module.HEAPU8.set(data, dataPointer); module.stringToUTF8(format, formatPointer, length);
    module.HEAPU32[outputPointer >>> 2] = 0;
    check(module._orz_decoder_create_memory(dataPointer, data.length, formatPointer, 0, outputPointer), 'create');
    const handle = module.HEAPU32[outputPointer >>> 2];
    try { return new AudioDecoder(module, handle); }
    catch (error) { module._orz_decoder_destroy_v1(handle); throw error; }
  } finally { module._free(outputPointer); module._free(formatPointer); module._free(dataPointer); }
}

function check(status: number, operation: string): void { if (status !== ORZ_OK) throw new OrzAudioCoreError(status, operation); }
