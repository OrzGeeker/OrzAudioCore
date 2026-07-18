import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
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
assert.equal(packageJson.version, JSON.parse(fs.readFileSync(path.join(root, 'decoder-manifest.json'))).sdkVersion);
assert.ok(packageJson.exports['./wasm/orz_audio.js']);
assert.ok(packageJson.exports['./wasm/orz_audio.wasm']);
console.log(`verified full and builtin-lite Web assets for ${packageJson.version}`);
