import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const web = path.join(root, 'SDK/Web');
const required = [
  'wasm/orz_audio.js',
  'wasm/orz_audio.wasm',
  'wasm/orz_audio_builtin.js',
  'wasm/orz_audio_builtin.mjs',
  'wasm/orz_audio_builtin.wasm',
];

for (const relative of required) {
  const stat = fs.statSync(path.join(web, relative));
  assert.ok(stat.isFile() && stat.size > 0, `missing Web release asset: ${relative}`);
}

const packageJson = JSON.parse(fs.readFileSync(path.join(web, 'package.json'), 'utf8'));
const manifest = JSON.parse(fs.readFileSync(path.join(root, 'decoder-manifest.json')));
assert.equal(packageJson.version, manifest.sdkVersion);
assert.ok(packageJson.exports['./wasm/orz_audio.js']);
assert.ok(packageJson.exports['./wasm/orz_audio.wasm']);

const require = createRequire(import.meta.url);
const gluePath = path.join(web, 'wasm/orz_audio.js');
const glueModule = { exports: {} };
const createModule = new Function(
  'module', 'exports', 'require', '__filename', '__dirname',
  `${fs.readFileSync(gluePath, 'utf8')}\nreturn module.exports;`,
)(glueModule, glueModule.exports, require, gluePath, path.dirname(gluePath));
const wasm = await createModule({
  wasmBinary: fs.readFileSync(path.join(web, 'wasm/orz_audio.wasm')),
});

function canDecode(format) {
  const bytes = Buffer.from(`${format}\0`);
  const pointer = wasm._malloc(bytes.length);
  try {
    wasm.HEAPU8.set(bytes, pointer);
    return wasm._orz_audio_can_decode(pointer) === 1;
  } finally {
    wasm._free(pointer);
  }
}

for (const decoder of manifest.formats.filter(entry => entry.profiles.includes('full'))) {
  assert.ok(canDecode(decoder.id), `full Web binary does not implement manifest format: ${decoder.id}`);
}
console.log(`verified full and builtin-lite Web assets for ${packageJson.version}`);
