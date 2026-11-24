#!/usr/bin/env node
/**
 * Validate a packaged OrzAudioCore artifact.
 *
 * Usage: verify-artifact.mjs <artifact.tar.gz|artifact.zip> [--run-probe] [--require-probe]
 *
 * The check is intentionally independent of the packaging scripts: it reads
 * only the unpacked artifact, so it catches a manifest that claims formats the
 * binary does not expose.
 */
import { execFileSync, spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import process from 'node:process';
import { buildInfo, loadManifest, repoRoot } from './lib/manifest.mjs';

const args = process.argv.slice(2);
const artifact = args.shift();
if (!artifact) throw new Error('usage: verify-artifact.mjs <artifact.tar.gz|artifact.zip> [--run-probe]');
const runProbe = args.includes('--run-probe');
const requireProbe = args.includes('--require-probe');
const manifest = loadManifest(path.join(repoRoot, 'decoder-manifest.json'));
const temp = fs.mkdtempSync(path.join(os.tmpdir(), 'orz-artifact-'));

function fail(message) {
  throw new Error(`artifact verification failed: ${message}`);
}

function walkDirectories(dir) {
  const output = [];
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    if (entry.name.startsWith('._') || entry.name === '__MACOSX') continue;
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) {
      output.push(full);
      output.push(...walkDirectories(full));
    }
  }
  return output;
}

function walk(dir) {
  const output = [];
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    if (entry.name.startsWith('._') || entry.name === '__MACOSX') continue;
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) output.push(...walk(full));
    else output.push(full);
  }
  return output;
}

function sha256(file) {
  return createHash('sha256').update(fs.readFileSync(file)).digest('hex');
}

function readJSON(file) {
  return JSON.parse(fs.readFileSync(file, 'utf8'));
}

try {
  const absolute = path.resolve(artifact);
  if (!fs.existsSync(absolute)) fail(`missing artifact ${absolute}`);
  const sidecar = `${absolute}.sha256`;
  if (fs.existsSync(sidecar)) {
    const expected = fs.readFileSync(sidecar, 'utf8').trim().split(/\s+/)[0];
    const actual = sha256(absolute);
    if (expected !== actual) fail(`sha256 mismatch: sidecar ${expected}, file ${actual}`);
  }

  const unpack = path.join(temp, 'unpacked');
  fs.mkdirSync(unpack);
  if (absolute.endsWith('.zip') || absolute.endsWith('.aar')) {
    execFileSync('unzip', ['-q', absolute, '-d', unpack]);
  } else {
    // Windows runner's PATH may resolve MSYS2/Git GNU tar, which mangles
    // drive-letter paths. Prefer the in-box bsdtar with native paths.
    const windowsTar = 'C:\\Windows\\System32\\tar.exe';
    const tarBinary = process.platform === 'win32' && fs.existsSync(windowsTar) ? windowsTar : 'tar';
    execFileSync(tarBinary, ['-xzf', absolute, '-C', unpack]);
  }
  const roots = fs.readdirSync(unpack);
  const root = roots.includes('metadata') || roots.includes('package')
    ? unpack
    : roots.length === 1 && fs.statSync(path.join(unpack, roots[0])).isDirectory()
      ? path.join(unpack, roots[0])
      : unpack;

  const metadataDir = [
    path.join(root, 'metadata'),
    path.join(root, 'package/metadata'),
    path.join(root, 'assets/orz/metadata'),
  ].find(candidate => fs.existsSync(candidate)) ?? null;
  if (!metadataDir) fail('missing metadata/ directory');
  for (const required of ['decoder-manifest.json', 'build-info.json', 'sbom.cdx.json', 'artifact.json']) {
    if (!fs.existsSync(path.join(metadataDir, required))) fail(`missing metadata/${required}`);
  }
  const artifactInfo = readJSON(path.join(metadataDir, 'artifact.json'));
  const info = readJSON(path.join(metadataDir, 'build-info.json'));
  const packagedManifest = readJSON(path.join(metadataDir, 'decoder-manifest.json'));
  const profile = artifactInfo.profile;
  const expected = buildInfo(manifest, profile);

  if (packagedManifest.sdkVersion !== manifest.sdkVersion) fail('packaged manifest version differs from source');
  if (info.version !== manifest.sdkVersion) fail(`build-info version ${info.version} != ${manifest.sdkVersion}`);
  if (info.abi !== manifest.abiVersion) fail(`build-info ABI ${info.abi} != ${manifest.abiVersion}`);
  if (info.profile !== profile) fail(`build-info profile ${info.profile} != artifact profile ${profile}`);
  if (JSON.stringify(info) !== JSON.stringify(expected)) {
    fail(`build-info.json does not match the profile-derived contract for ${profile}`);
  }
  if (artifactInfo.cacheNamespace !== info.cacheNamespace) fail('artifact cacheNamespace differs from build-info');

  const licenses = [
    path.join(root, 'licenses'),
    path.join(root, 'package/licenses'),
    path.join(root, 'assets/orz/licenses'),
  ].find(candidate => fs.existsSync(candidate)) ?? path.join(root, 'licenses');
  if (!fs.existsSync(licenses) || fs.readdirSync(licenses).length === 0) fail('missing licenses/');
  if (profile !== 'builtin-lite') {
    for (const required of ['OrzAudioCore-LICENSE', 'libopenmpt-LICENSE', 'game-music-emu-LICENSE',
      'libsidplayfp-COPYING', 'asap-COPYING', 'sc68-README-GPL3.txt', 'v2m-player-LICENSE',
      'ahx2play-LICENSE', 'libadplug-COPYING']) {
      if (!fs.existsSync(path.join(licenses, required))) fail(`missing license ${required}`);
    }
  }

  const jniLibraries = walk(root).filter(file => file.endsWith('/liborzaudio.so'));
  const wasmFiles = walk(root).filter(file => file.endsWith('.wasm'));
  if (absolute.endsWith('.aar')) {
    if (jniLibraries.length === 0) fail('AAR has no jni/<abi>/liborzaudio.so');
  } else if (wasmFiles.length === 0) {
    const header = walk(root).find(file => file.endsWith('orz_audio_core.h'));
    if (!header) fail('missing public header orz_audio_core.h');
  }

  const xcframework = walkDirectories(root).find(file => file.endsWith('.xcframework'));
  if (xcframework) {
    const slices = fs.readdirSync(xcframework).filter(name =>
      !name.startsWith('.') && name !== 'Info.plist' && fs.statSync(path.join(xcframework, name)).isDirectory());
    if (slices.length === 0) fail('empty xcframework');
    for (const slice of slices) {
      const headers = path.join(xcframework, slice, 'Headers');
      if (!fs.existsSync(path.join(headers, 'orz_audio_core.h'))) fail(`${slice}: missing Headers/orz_audio_core.h`);
      if (!fs.existsSync(path.join(headers, 'module.modulemap'))) fail(`${slice}: missing Headers/module.modulemap`);
      const binary = fs.readdirSync(path.join(xcframework, slice)).find(name => name.startsWith('libOrzAudioCore.'));
      if (!binary) fail(`${slice}: missing static library`);
      // The publish runner may be Linux while the slice is Mach-O. Use
      // llvm-nm when present; otherwise skip the symbol probe rather than
      // failing on a format the host nm cannot read.
      const symbolTool = fs.existsSync('/usr/bin/llvm-nm') ? 'llvm-nm' : 'nm';
      const symbolResult = spawnSync(symbolTool, ['-g', path.join(xcframework, slice, binary)], { encoding: 'utf8', maxBuffer: 64 * 1024 * 1024 });
      if (symbolResult.status === 0) {
        if (!/(^|\s)_?orz_build_info(\s|$)/m.test(symbolResult.stdout)) fail(`${slice}: library does not export orz_build_info`);
      } else {
        console.warn(`warning: ${slice}: cannot inspect Mach-O symbols on this host; skipping nm check`);
      }
    }
  }

  const wasm = wasmFiles.find(file => file.endsWith('orz_audio.wasm'));
  if (wasm && !xcframework) {
    const expectedWasm = ['orz_audio.js', 'orz_audio.wasm', 'orz_audio_builtin.js', 'orz_audio_builtin.mjs', 'orz_audio_builtin.wasm'];
    for (const name of expectedWasm) {
      if (!walk(root).some(file => file.endsWith(name))) fail(`web artifact missing ${name}`);
    }
  }

  let runtime = null;
  if (runProbe) {
    const probe = walk(root).find(file => /^orz_artifact_probe(\.exe)?$/.test(path.basename(file)));
    if (!probe) {
      if (requireProbe) fail('artifact has no orz_artifact_probe');
    } else {
      const result = spawnSync(probe, [], { encoding: 'utf8' });
      if (result.status !== 0) {
        if (requireProbe) fail(`orz_artifact_probe failed: ${result.stderr || result.stdout}`);
      } else {
        runtime = JSON.parse(result.stdout);
        const runtimeInfo = runtime.buildInfo;
        if (JSON.stringify(runtimeInfo) !== JSON.stringify(info)) {
          fail('runtime orz_build_info() differs from metadata/build-info.json');
        }
        const runtimeFormats = runtime.formats.map(format => format.id).sort();
        const expectedFormats = [...expected.formats].sort();
        if (JSON.stringify(runtimeFormats) !== JSON.stringify(expectedFormats)) {
          fail(`runtime formats ${runtimeFormats} != build-info formats ${expectedFormats}`);
        }
      }
    }
  }

  console.log(`verified ${path.basename(absolute)}: ${info.version} ${profile} ${info.cacheNamespace}` +
    `${runtime ? ` (runtime formatCount=${runtime.formatCount})` : ''}`);
} finally {
  fs.rmSync(temp, { recursive: true, force: true });
}
