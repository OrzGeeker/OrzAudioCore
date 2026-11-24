/** Minimal AudioWorklet global-scope declarations (not in lib.dom). */
declare const sampleRate: number;
declare const currentTime: number;
declare const currentFrame: number;

declare class AudioWorkletProcessor {
  constructor(options?: unknown);
  readonly port: MessagePort;
}

declare function registerProcessor(name: string, processorCtor: new (options: any) => AudioWorkletProcessor): void;
