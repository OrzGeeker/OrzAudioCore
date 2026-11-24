#!/usr/bin/env node
/**
 * Generate a schema-v1 OrzAudioCore lockfile from a directory of release assets.
 *
 * Usage:
 *   generate-lockfile.mjs --version 1.4.0 --release-dir ./release [--commit <sha>]
 *                         [--tag v1.4.0] [--out audio-core-sdk.lock.json] [--manifest file]
 */
import { createHash } from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import process from 'node:process';
import { buildInfo, loadManifest, repoRoot } from './lib/manifest.mjs';

const args = process.argv.slice(2);
const option = (name, fallback) => {
  const index = args.indexOf(name);
  return index >= 0 ? args[index + 1] : fallback;
};
const version = option('--version');
const releaseDir = option('--release-dir');
if (!version || !releaseDir) {
  throw new Error('usage: generate-lockfile.mjs --version <ver> --release-dir <dir> [--commit sha] [--tag v<ver>] [--out file]');
}
const tag = option('--tag', `v${version}`);
const commit = option('--commit', '0000000');
const manifest = loadManifest(option('--manifest', path.join(repoRoot, 'decoder-manifest.json')));
const out = option('--out');

const prefix = `OrzAudioCore-${version}-`;
const pattern = /^(.+)-(builtin-lite|full|server)(\.xcframework)?\.(tar\.gz|tgz|zip|aar)$/;
const assets = [];
for (const name of fs.readdirSync(releaseDir).sort()) {
  if (!name.startsWith(prefix)) continue;
  const match = pattern.exec(name.slice(prefix.length));
  if (!match) continue;
  const platform = match[1];
  assets.push({
    name,
    platform: platform.startsWith('macos-') ? platform : ['ios', 'apple'].includes(platform) ? 'apple' : platform.startsWith('android') ? 'android' : platform,
    profile: match[2],
    sha256: createHash('sha256').update(fs.readFileSync(path.join(releaseDir, name))).digest('hex'),
  });
}
if (!assets.length) throw new Error(`no OrzAudioCore assets found in ${releaseDir}`);

const profiles = {};
for (const profile of new Set(assets.map(asset => asset.profile))) {
  const info = buildInfo(manifest, profile);
  profiles[profile] = {
    cacheNamespace: info.cacheNamespace,
    fingerprint: info.fingerprint,
    formats: info.formats,
    decoders: info.decoders,
  };
}

const lock = {
  schemaVersion: 1,
  repository: 'https://github.com/OrzGeeker/OrzAudioCore',
  version,
  tag,
  commit,
  profiles,
  assets,
};
const text = `${JSON.stringify(lock, null, 2)}\n`;
if (out) fs.writeFileSync(out, text);
else process.stdout.write(text);
