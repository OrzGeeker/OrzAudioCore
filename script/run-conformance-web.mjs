#!/usr/bin/env node
/**
 * Run conformance fixtures through the Web/WASM binding and emit the same
 * report shape as the native `orz_conformance` probe.
 *
 * Usage:
 *   run-conformance-web.mjs --module SDK/Web/wasm/orz_audio_builtin.mjs \
 *     --wasm SDK/Web/wasm/orz_audio_builtin.wasm --out conformance \
 *     --platform web --formats ym,mid,bp
 */
import { createHash } from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import process from 'node:process';
import { pathToFileURL } from 'node:url';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const manifest = JSON.parse(fs.readFileSync(path.join(root, 'Tests/conformance/manifest.json'), 'utf8'));
const args = process.argv.slice(2);
const option = (name, fallback) => {
  const index = args.indexOf(name);
  return index >= 0 ? args[index + 1] : fallback;
};
const modulePath = path.resolve(option('--module', path.join(root, 'SDK/Web/wasm/orz_audio_builtin.mjs')));
const wasmPath = path.resolve(option('--wasm', path.join(root, 'SDK/Web/wasm/orz_audio_builtin.wasm')));
const out = path.resolve(option('--out', path.join(root, '.conformance')));
const platform = option('--platform', 'web');
const frames = Number(option('--frames', '8192'));
const maxSeconds = Number(option('--max-seconds', '30'));
const fixtures = path.resolve(option('--fixtures', process.env.ORZ_CONFORMANCE_FIXTURES ?? path.join(root, 'Tests/conformance/fixtures')));
const wanted = new Set((option('--formats', 'ym,mid,bp') || '').split(',').filter(Boolean));

if (!fs.existsSync(modulePath) || !fs.existsSync(wasmPath)) {
  throw new Error(`missing WASM assets: ${modulePath} / ${wasmPath}`);
}
const { createDecoder, buildInfo } = await import(pathToFileURL(modulePath));
const factory = (await import(pathToFileURL(modulePath))).default;
const module = await factory({ wasmBinary: fs.readFileSync(wasmPath) });
const target = path.join(out, platform);
fs.mkdirSync(target, { recursive: true });
const info = buildInfo(module);

function summarize(decoder) {
  const channels = decoder.info.channels || 1;
  const pcmParts = [];
  let renderedFrames = 0;
  const maxFrames = Math.min(frames, Math.max(1, Math.floor((decoder.info.duration || 0) * (decoder.info.sampleRate || 44100))), (decoder.info.sampleRate || 44100) * maxSeconds);
  while (renderedFrames < maxFrames) {
    const chunk = decoder.render(Math.min(2048, maxFrames - renderedFrames));
    if (chunk.length === 0) break;
    pcmParts.push(chunk);
    renderedFrames += chunk.length / channels;
  }
  const pcm = new Float32Array(pcmParts.reduce((total, part) => total + part.length, 0));
  let offset = 0;
  for (const part of pcmParts) { pcm.set(part, offset); offset += part.length; }
  const int16 = new Int16Array(pcm.length);
  let maxAbs = 0;
  for (let index = 0; index < pcm.length; index++) {
    const value = Number.isFinite(pcm[index]) ? Math.max(-1, Math.min(1, pcm[index])) : 0;
    maxAbs = Math.max(maxAbs, Math.abs(value));
    int16[index] = Math.round(value * 32767);
  }
  return {
    frames: renderedFrames,
    floatSha256: createHash('sha256').update(Buffer.from(pcm.buffer)).digest('hex'),
    int16Sha256: createHash('sha256').update(Buffer.from(int16.buffer)).digest('hex'),
    maxAbs,
    first: [...pcm.slice(0, Math.min(16, pcm.length))],
    last: [...pcm.slice(Math.max(0, pcm.length - 16))],
  };
}

for (const entry of manifest.formats) {
  if (!entry.path || !wanted.has(entry.format)) continue;
  const directory = path.join(fixtures, entry.format);
  let file = path.join(fixtures, entry.path);
  if (!fs.existsSync(file)) {
    const candidates = fs.existsSync(directory) ? fs.readdirSync(directory).filter(name => !name.startsWith('.')) : [];
    file = candidates.length ? path.join(directory, candidates[0]) : file;
  }
  if (!fs.existsSync(file)) continue;
  const data = new Uint8Array(fs.readFileSync(file));
  const report = { format: entry.format, input: { name: file, bytes: data.length } };
  let decoder;
  try {
    decoder = createDecoder(module, data, entry.format);
    const stream = decoder.info;
    report.stream = { status: 0, sampleRate: stream.sampleRate, channels: stream.channels, duration: stream.duration, subsongCount: stream.subsongCount, capabilities: stream.capabilities };
    report.pcm = summarize(decoder);
    report.seek = { status: -3, message: 'format does not advertise seek' };
    if ((stream.capabilities & 4) && stream.duration > 0) {
      const position = Math.floor(stream.duration * 500);
      try {
        decoder.seek(position);
        report.seek = { status: 0, positionMs: position, pcm: summarize(decoder) };
      } catch (error) {
        report.seek = { status: error.status ?? -7, message: error.message };
      }
    }
    decoder.close();
    decoder = undefined;
    report.subsongs = [];
    if (stream.capabilities & 8) {
      for (let index = 1; index < Math.min(stream.subsongCount, 4); index++) {
        const sub = createDecoder(module, data, entry.format);
        try {
          sub.selectSubsong(index);
          report.subsongs.push({ index, status: 0, sampleRate: sub.info.sampleRate, channels: sub.info.channels, duration: sub.info.duration, pcm: summarize(sub) });
        } catch (error) {
          report.subsongs.push({ index, status: error.status ?? -7 });
        } finally { sub.close(); }
      }
    }
    const cancel = createDecoder(module, data, entry.format);
    cancel.cancel();
    try {
      cancel.render(1);
      report.cancel = { status: 0, expected: -6 };
    } catch (error) {
      report.cancel = { status: error.status ?? -7, expected: -6 };
    } finally { cancel.close(); }
    report.buildInfo = JSON.stringify(info);
    fs.writeFileSync(path.join(target, `${entry.format}.json`), `${JSON.stringify(report, null, 2)}\n`);
  } catch (error) {
    fs.writeFileSync(path.join(target, `${entry.format}.json`), `${JSON.stringify({ format: entry.format, error: String(error.message ?? error) }, null, 2)}\n`);
  } finally {
    decoder?.close();
  }
}
fs.writeFileSync(path.join(target, 'index.json'), `${JSON.stringify({ platform, generatedAt: new Date().toISOString(), formats: Object.fromEntries(wanted ? [...wanted].map(format => [format, { status: fs.existsSync(path.join(target, `${format}.json`)) ? 'ok' : 'missing' }]) : []) }, null, 2)}\n`);
console.log(`wrote Web conformance reports to ${target}`);
