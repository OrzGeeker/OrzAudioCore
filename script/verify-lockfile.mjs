#!/usr/bin/env node
/**
 * Validate an OrzAudioCore SDK lockfile.
 *
 * Usage:
 *   verify-lockfile.mjs <lock.json> [--manifest decoder-manifest.json]
 *                                    [--release-dir <dir>] [--allow-legacy]
 *
 * `--release-dir` recomputes SHA-256 for every asset found in the directory.
 * `--manifest` (default: repository manifest) also checks that profile format
 * lists and cache namespaces match the generator. Legacy 1.3.x lockfiles are
 * accepted with `--allow-legacy` and reported as needing migration.
 */
import { createHash } from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import process from 'node:process';
import { buildInfo, loadManifest, repoRoot } from './lib/manifest.mjs';

const args = process.argv.slice(2);
const lockPath = args.shift();
if (!lockPath) throw new Error('usage: verify-lockfile.mjs <lock.json> [--manifest file] [--release-dir dir] [--allow-legacy]');
const option = name => {
  const index = args.indexOf(name);
  return index >= 0 ? args[index + 1] : undefined;
};
const manifestPath = option('--manifest') ?? path.join(repoRoot, 'decoder-manifest.json');
const releaseDir = option('--release-dir');
const allowLegacy = args.includes('--allow-legacy');
const manifest = loadManifest(manifestPath);
const lock = JSON.parse(fs.readFileSync(lockPath, 'utf8'));

const problems = [];
const check = (condition, message) => { if (!condition) problems.push(message); };
const sha256 = file => createHash('sha256').update(fs.readFileSync(file)).digest('hex');
const semver = /^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-([0-9A-Za-z.-]+))?$/;

if (!lock.schemaVersion) {
  if (!allowLegacy) {
    throw new Error('legacy lockfile (no schemaVersion); migrate to schema v1 or pass --allow-legacy');
  }
  const required = ['repository', 'version', 'tag', 'commit'];
  for (const field of required) check(typeof lock[field] === 'string', `missing ${field}`);
  for (const [field, value] of Object.entries(lock)) {
    if (/Sha256/i.test(field)) check(/^[0-9a-f]{64}$/.test(value), `${field} is not a sha256`);
  }
  console.log(`legacy lockfile accepted (${lock.version}); add schemaVersion/profiles/assets for schema v1`);
} else {
  check(lock.schemaVersion === 1, 'schemaVersion must be 1');
  check(lock.repository === 'https://github.com/OrzGeeker/OrzAudioCore', `unexpected repository ${lock.repository}`);
  check(semver.test(lock.version), `invalid version ${lock.version}`);
  check(lock.tag === `v${lock.version}`, 'tag must be v<version>');
  check(/^[0-9a-f]{7,40}$/.test(lock.commit), 'commit must be a git hash');
  check(lock.profiles && typeof lock.profiles === 'object', 'missing profiles');
  check(Array.isArray(lock.assets) && lock.assets.length > 0, 'missing assets');

  const names = new Set();
  for (const asset of lock.assets ?? []) {
    check(!names.has(asset.name), `duplicate asset ${asset.name}`);
    names.add(asset.name);
    check(/^OrzAudioCore-[0-9A-Za-z.+-]+-[a-z0-9_-]+-(builtin-lite|full|server)(\.xcframework)?\.(tar\.gz|tgz|zip|aar)$/.test(asset.name),
      `asset name does not follow OrzAudioCore-<version>-<platform>-<profile>: ${asset.name}`);
    check(/^[0-9a-f]{64}$/.test(asset.sha256), `${asset.name}: invalid sha256`);
    check(lock.profiles?.[asset.profile], `${asset.name}: unknown profile ${asset.profile}`);
    if (releaseDir) {
      const file = path.join(releaseDir, asset.name);
      check(fs.existsSync(file), `${asset.name}: missing from ${releaseDir}`);
      if (fs.existsSync(file)) check(sha256(file) === asset.sha256, `${asset.name}: sha256 mismatch`);
    }
  }

  for (const [profile, entry] of Object.entries(lock.profiles ?? {})) {
    if (!(profile in { 'builtin-lite': 1, full: 1, server: 1 })) {
      problems.push(`unknown profile ${profile}`);
      continue;
    }
    check(/^[0-9a-f]{12}$/.test(entry.cacheNamespace?.split('-').at(-1) ?? ''), `${profile}: malformed cacheNamespace`);
    check(entry.fingerprint === entry.cacheNamespace, `${profile}: fingerprint differs from cacheNamespace`);
    if (lock.version === manifest.sdkVersion) {
      const expected = buildInfo(manifest, profile);
      check(JSON.stringify(entry.formats) === JSON.stringify(expected.formats), `${profile}: format list differs from manifest`);
      check(JSON.stringify(entry.decoders) === JSON.stringify(expected.decoders), `${profile}: decoder list differs from manifest`);
      check(entry.cacheNamespace === expected.cacheNamespace, `${profile}: cacheNamespace differs from generator`);
    }
  }
}

if (problems.length) {
  throw new Error(`lockfile verification failed:\n  - ${problems.join('\n  - ')}`);
}
console.log(`verified ${lockPath}: ${lock.version} (${lock.schemaVersion ? 'schema v1' : 'legacy'})`);
