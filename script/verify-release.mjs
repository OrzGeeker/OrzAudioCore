#!/usr/bin/env node
/**
 * Verify every OrzAudioCore asset in a release directory before publishing.
 *
 * Usage: verify-release.mjs <release-dir> [--version <ver>] [--require apple,web,linux-x86_64]
 *
 * It rejects non-canonical asset names, checks each tarball/zip with
 * verify-artifact.mjs, validates SHA-256 sidecars, and finally round-trips a
 * generated schema-v1 lockfile through verify-lockfile.mjs.
 */
import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import process from 'node:process';
import { loadManifest, repoRoot } from './lib/manifest.mjs';

const args = process.argv.slice(2);
const releaseDir = args.shift();
if (!releaseDir) throw new Error('usage: verify-release.mjs <release-dir> [--version <ver>] [--require apple,web]');
const option = name => {
  const index = args.indexOf(name);
  return index >= 0 ? args[index + 1] : undefined;
};
const manifest = loadManifest(path.join(repoRoot, 'decoder-manifest.json'));
const version = option('--version') ?? manifest.sdkVersion;
const required = (option('--require') ?? '').split(',').filter(Boolean);
const prefix = `OrzAudioCore-${version}-`;
const pattern = /^(.+)-(builtin-lite|full|server)(\.xcframework)?\.(tar\.gz|tgz|zip|aar)$/;
const assets = [];
for (const name of fs.readdirSync(releaseDir).sort()) {
  if (!fs.statSync(path.join(releaseDir, name)).isFile()) continue;
  if (name.endsWith('.sha256') || name.endsWith('.swift')) continue;
  if (!name.startsWith(prefix)) throw new Error(`non-canonical release asset name: ${name}`);
  const match = pattern.exec(name.slice(prefix.length));
  if (!match) throw new Error(`non-canonical release asset name: ${name}`);
  assets.push({ name, platform: match[1], profile: match[2], file: path.join(releaseDir, name) });
}
if (!assets.length) throw new Error(`no OrzAudioCore assets in ${releaseDir}`);

const platforms = new Set(assets.map(asset => asset.platform));
for (const platform of required) {
  if (!platforms.has(platform)) throw new Error(`missing required platform in release: ${platform}`);
}

for (const asset of assets) {
  const sidecar = `${asset.file}.sha256`;
  if (!fs.existsSync(sidecar)) throw new Error(`${asset.name}: missing ${path.basename(sidecar)}`);
  // Cross-compiled/Web artifacts cannot execute their native probe on this
  // host; verify-artifact still validates metadata, licenses and headers.
  execFileSync(process.execPath, [path.join(repoRoot, 'script/verify-artifact.mjs'), asset.file, '--run-probe'], { stdio: 'inherit' });
}

const temp = fs.mkdtempSync(path.join(os.tmpdir(), 'orz-release-'));
try {
  const lock = path.join(temp, 'audio-core-sdk.lock.json');
  execFileSync(process.execPath, [path.join(repoRoot, 'script/generate-lockfile.mjs'),
    '--version', version, '--release-dir', releaseDir, '--out', lock], { stdio: 'inherit' });
  execFileSync(process.execPath, [path.join(repoRoot, 'script/verify-lockfile.mjs'), lock, '--release-dir', releaseDir], { stdio: 'inherit' });
} finally {
  fs.rmSync(temp, { recursive: true, force: true });
}

console.log(`verified release ${version}: ${assets.map(asset => asset.name).join(', ')}`);
