#!/usr/bin/env node
/**
 * Run the conformance probe for every fixture in Tests/conformance/manifest.json.
 *
 * Usage:
 *   run-conformance.mjs --binary <orz_conformance> --out <dir> [--platform macos-arm64]
 *                       [--fixtures <dir>] [--formats mod,xm] [--frames 8192]
 *                       [--require-all]
 */
import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import process from 'node:process';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const manifest = JSON.parse(fs.readFileSync(path.join(root, 'Tests/conformance/manifest.json'), 'utf8'));
const args = process.argv.slice(2);
const option = (name, fallback) => {
  const index = args.indexOf(name);
  return index >= 0 ? args[index + 1] : fallback;
};
const binary = option('--binary');
const out = path.resolve(option('--out', path.join(root, '.conformance')));
const platform = option('--platform', `${process.platform}-${process.arch}`);
const fixtures = path.resolve(option('--fixtures', process.env.ORZ_CONFORMANCE_FIXTURES ?? path.join(root, 'Tests/conformance/fixtures')));
const frames = option('--frames', '8192');
const wanted = new Set((option('--formats', '') || '').split(',').filter(Boolean));
const requireAll = args.includes('--require-all');
if (!binary || !fs.existsSync(binary)) throw new Error(`missing conformance binary: ${binary}`);

const target = path.join(out, platform);
fs.mkdirSync(target, { recursive: true });
const index = { platform, generatedAt: new Date().toISOString(), formats: {} };
let failures = 0;

for (const entry of manifest.formats) {
  if (wanted.size && !wanted.has(entry.format)) continue;
  if (!entry.path) {
    index.formats[entry.format] = { status: 'skipped', reason: entry.skipReason };
    fs.writeFileSync(path.join(target, `${entry.format}.json`), `${JSON.stringify({ format: entry.format, skipped: entry.skipReason }, null, 2)}\n`);
    continue;
  }
  const directory = path.join(fixtures, entry.format);
  let file = path.join(fixtures, entry.path);
  if (!fs.existsSync(file)) {
    const candidates = fs.existsSync(directory) ? fs.readdirSync(directory).filter(name => !name.startsWith('.')) : [];
    file = candidates.length ? path.join(directory, candidates[0]) : file;
  }
  if (!fs.existsSync(file)) {
    index.formats[entry.format] = { status: 'missing' };
    if (requireAll) {
      console.error(`missing fixture for ${entry.format}: ${file}`);
      failures++;
    }
    continue;
  }
  const report = path.join(target, `${entry.format}.json`);
  try {
    const stdout = execFileSync(binary, ['--format', entry.format, '--input', file, '--frames', frames], { encoding: 'utf8' });
    fs.writeFileSync(report, stdout);
    const parsed = JSON.parse(stdout);
    index.formats[entry.format] = {
      status: parsed.error ? 'error' : 'ok',
      sampleRate: parsed.stream?.sampleRate,
      channels: parsed.stream?.channels,
      duration: parsed.stream?.duration,
      seekStatus: parsed.seek?.status,
      cancelStatus: parsed.cancel?.status,
    };
    if (parsed.error) failures++;
  } catch (error) {
    fs.writeFileSync(report, `${JSON.stringify({ format: entry.format, error: String(error.stderr ?? error.message) }, null, 2)}\n`);
    index.formats[entry.format] = { status: 'error', error: String(error.stderr ?? error.message) };
    failures++;
  }
}

fs.writeFileSync(path.join(target, 'index.json'), `${JSON.stringify(index, null, 2)}\n`);
console.log(`wrote ${Object.keys(index.formats).length} reports to ${target}`);
if (failures) throw new Error(`${failures} conformance fixture(s) failed`);
