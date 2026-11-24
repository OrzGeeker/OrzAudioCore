# Web SDK

The npm package is `@orzmusic/audio-core`. It ships two WASM projections:

| Asset | Profile | Use |
|---|---|---|
| `wasm/orz_audio.js` + `.wasm` | full | classic worker / `importScripts` |
| `wasm/orz_audio_builtin.mjs` + `.wasm` | builtin-lite | ESM loader, `ym`/`mid`/`bp` |

Both are versioned with the package; `decoder-manifest.json` in the package is
the same manifest the native SDK uses. Release tarballs carry
`metadata/build-info.json`, `metadata/sbom.cdx.json` and `licenses/`.

## Load and decode

```ts
import { createDecoder } from '@orzmusic/audio-core';
import createModule from '@orzmusic/audio-core/wasm/orz_audio_builtin.mjs';

const module = await createModule({
  locateFile: file => new URL(`@orzmusic/audio-core/wasm/${file}`, import.meta.url).href,
});
const decoder = createDecoder(module, bytes, 'ym');
const pcm = decoder.render(2048); // Float32Array, interleaved
```

`buildInfo(module)` and `supportedFormats(module)` expose the runtime truth.
Compare `buildInfo.formats` with `decoder-manifest.json` before trusting a
format; a binary/manifest mismatch is a packaging bug.

## Worker + AudioWorklet bridge

`@orzmusic/audio-core/worker` is an ES module worker. It owns the decoder and
writes into a SharedArrayBuffer ring buffer; `@orzmusic/audio-core/worklet`
registers `orz-ring-buffer`, which drains and resamples that ring on the audio
thread.

```ts
import { ControlSlots, StreamState } from '@orzmusic/audio-core/protocol';

const control = new SharedArrayBuffer(ControlSlots * Int32Array.BYTES_PER_ELEMENT);
const samples = new SharedArrayBuffer(capacityFrames * channels * 4);
const worker = new Worker(
  new URL('@orzmusic/audio-core/worker', import.meta.url),
  { type: 'module' }
);
worker.postMessage({
  type: 'decode', generation: 1, data: bytes.buffer, format: 'mod',
  control, samples, capacityFrames, channels: 2,
}, [bytes.buffer]);

await audioContext.audioWorklet.addModule(
  new URL('@orzmusic/audio-core/worklet', import.meta.url)
);
const node = new AudioWorkletNode(audioContext, 'orz-ring-buffer', {
  processorOptions: { control, samples, capacityFrames, channels: 2,
    sourceSampleRate: 44100, generation: 1 }
});
```

Protocol v1 control slots: `0` write, `1` read, `2` state
(`0 priming / 1 running / 2 ended / 3 failed / 4 stopped`), `3` generation,
`4` underruns. The worker yields between chunks so `stop` and `seek` messages
run; seek resets the ring and reports `seeked`. `cancel`/`close` never leak a
decoder handle: every path destroys it in a `finally`-style cleanup.

When the worker has no `control`/`samples`, it posts copied `pcm` blocks
(`{type:'pcm', samples, frames, end}`) instead. This is the degradation path.

## COOP/COEP and SharedArrayBuffer

SharedArrayBuffer requires cross-origin isolation. Serve the page with:

```
Cross-Origin-Opener-Policy: same-origin
Cross-Origin-Embedder-Policy: require-corp
```

and make sure WASM/worker assets are same-origin or carry
`Cross-Origin-Resource-Policy: cross-origin`. Without these headers the browser
removes `SharedArrayBuffer`; use the transfer mode above (higher GC pressure,
slightly higher latency, no audio-thread resampler) or decode to PCM in a
normal worker and feed `AudioBufferSourceNode`.

## Caching and versioning

- Use `buildInfo.cacheNamespace` as the cache key prefix. It is
  `orzaudio-<sdkVersion>-<profile>-<decoderSetHash>` and changes when a decoder
  version or format set changes.
- Pin the npm package version; do not mix WASM assets from two versions.
- `npm test` covers the binding and protocol helpers. `script/verify-web-release.mjs`
  checks that the full WASM implements every full-profile format.

## Browser smoke tests

Release CI loads the full WASM in a browser automation job, decodes a `.mod`
fixture and checks the returned PCM/hash. Chrome and Safari run at least one
fixture each. Conformance reports are attached to the release; the Web report
is compared with the native reports using `script/compare-conformance.mjs`.
