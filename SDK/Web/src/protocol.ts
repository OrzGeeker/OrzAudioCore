/**
 * OrzAudioCore Web PCM streaming protocol, version 1.
 *
 * The worker decodes into a SharedArrayBuffer ring buffer. The AudioWorklet
 * consumes the ring, resamples to the device rate and reports underruns. When
 * SharedArrayBuffer is unavailable (missing COOP/COEP headers) the same worker
 * can post copied PCM chunks instead; see `docs/web.md`.
 */

export const ORZ_PCM_PROTOCOL_VERSION = 1;

/** Int32 control-block slots shared by worker and worklet. */
export const ControlIndex = Object.freeze({
  write: 0,
  read: 1,
  state: 2,
  generation: 3,
  underruns: 4,
} as const);

export const ControlSlots = 5;

export enum StreamState {
  Priming = 0,
  Running = 1,
  Ended = 2,
  Failed = 3,
  Stopped = 4,
}

export interface RingBufferOptions {
  control: SharedArrayBuffer;
  samples: SharedArrayBuffer;
  capacityFrames: number;
  channels: number;
  sourceSampleRate: number;
  generation: number;
}

export interface DecodeRequest {
  type: 'decode';
  generation: number;
  data: ArrayBuffer;
  format: string;
  subsong?: number;
  /** Ring-buffer mode (SharedArrayBuffer + AudioWorklet). */
  control?: SharedArrayBuffer;
  samples?: SharedArrayBuffer;
  capacityFrames?: number;
  channels?: number;
  startFrames?: number;
  /** Transfer mode fallback: post copied PCM blocks instead of a ring. */
  chunkFrames?: number;
}

export type WorkerRequest =
  | { type: 'init'; moduleUrl?: string; wasmUrl?: string }
  | { type: 'warmup'; moduleUrl?: string }
  | DecodeRequest
  | { type: 'seek'; generation: number; positionMs: number }
  | { type: 'stop'; generation: number }
  | { type: 'stats' };

export type WorkerResponse =
  | { type: 'warmed'; protocolVersion: number }
  | { type: 'ready'; generation: number; sampleRate: number; channels: number; duration: number; subsongCount: number }
  | { type: 'started'; generation: number }
  | { type: 'seeked'; generation: number; positionMs: number }
  | { type: 'pcm'; generation: number; samples: Float32Array; frames: number; channels: number; sampleRate: number; end: boolean }
  | { type: 'ended'; generation: number; rendered: number; decodeRate: number; underruns: number }
  | { type: 'stopped'; generation: number }
  | { type: 'stats'; generation: number; underruns: number; renderedFrames: number }
  | { type: 'error'; generation: number; message: string; status?: number };

export function usedFrames(write: number, read: number, capacity: number): number {
  return write >= read ? write - read : capacity - read + write;
}

export function freeFrames(control: Int32Array, capacity: number): number {
  const write = Atomics.load(control, ControlIndex.write);
  const read = Atomics.load(control, ControlIndex.read);
  return capacity - usedFrames(write, read, capacity) - 1;
}

/** Resets a ring buffer for a new generation without reallocating it. */
export function resetRing(control: Int32Array, generation: number): void {
  Atomics.store(control, ControlIndex.write, 0);
  Atomics.store(control, ControlIndex.read, 0);
  Atomics.store(control, ControlIndex.state, StreamState.Priming);
  Atomics.store(control, ControlIndex.generation, generation);
}
