import { ControlIndex, StreamState, usedFrames } from './protocol.js';

interface ProcessorOptions {
  control: SharedArrayBuffer;
  samples: SharedArrayBuffer;
  capacityFrames: number;
  channels: number;
  sourceSampleRate: number;
  generation: number;
}

/**
 * AudioWorklet processor that drains the worker's float32 ring buffer and
 * linearly resamples to the device sample rate. It never blocks the audio
 * thread: when the ring is empty it emits silence and increments the underrun
 * counter that the worker reports through the shared control block.
 */
class OrzRingBufferProcessor extends AudioWorkletProcessor {
  private readonly control: Int32Array;
  private readonly samples: Float32Array;
  private readonly capacityFrames: number;
  private readonly channels: number;
  private readonly ratio: number;
  private readonly generation: number;
  private phase = 0;

  constructor(options: { processorOptions: ProcessorOptions }) {
    super();
    const config = options.processorOptions;
    this.control = new Int32Array(config.control);
    this.samples = new Float32Array(config.samples);
    this.capacityFrames = config.capacityFrames;
    this.channels = config.channels;
    this.ratio = config.sourceSampleRate / sampleRate;
    this.generation = config.generation;
    Atomics.store(this.control, ControlIndex.generation, config.generation);
  }

  process(_inputs: Float32Array[][], outputs: Float32Array[][]): boolean {
    const output = outputs[0];
    if (!output?.length) return true;
    const frames = output[0].length;
    if (Atomics.load(this.control, ControlIndex.generation) !== this.generation) return false;

    let read = Atomics.load(this.control, ControlIndex.read);
    const write = Atomics.load(this.control, ControlIndex.write);
    const available = usedFrames(write, read, this.capacityFrames);
    const producible = Math.min(frames, Math.floor(Math.max(0, available - 1) / this.ratio));

    for (let frame = 0; frame < producible; frame++) {
      const sourceFrame = Math.floor(this.phase);
      const fraction = this.phase - sourceFrame;
      const source = ((read + sourceFrame) % this.capacityFrames) * this.channels;
      const next = ((read + sourceFrame + 1) % this.capacityFrames) * this.channels;
      for (let channel = 0; channel < output.length; channel++) {
        const index = Math.min(channel, this.channels - 1);
        const a = this.samples[source + index];
        output[channel][frame] = a + (this.samples[next + index] - a) * fraction;
      }
      this.phase += this.ratio;
    }
    const consumed = Math.floor(this.phase);
    this.phase -= consumed;
    read = (read + consumed) % this.capacityFrames;
    Atomics.store(this.control, ControlIndex.read, read);
    if (producible < frames && Atomics.load(this.control, ControlIndex.state) === StreamState.Running) {
      Atomics.add(this.control, ControlIndex.underruns, 1);
    }

    // Stop once the producer has finished and the ring is drained.
    return !(Atomics.load(this.control, ControlIndex.state) >= StreamState.Ended && available <= 1);
  }
}

registerProcessor('orz-ring-buffer', OrzRingBufferProcessor);
