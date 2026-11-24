#!/usr/bin/env node
/**
 * Download the pinned conformance corpus without committing music files.
 *
 * Usage: fetch-conformance-fixtures.mjs [--out Tests/conformance/fixtures] [--format mod,xm]
 *
 * Uses raw.githubusercontent.com at the commit pinned in manifest.json and
 * verifies every file's SHA-256. Set ORZ_CONFORMANCE_FIXTURES to point at an
 * existing keygenmusic checkout to skip the download.
 */
import { createHash } from 'node:crypto';
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
const out = path.resolve(option('--out', path.join(root, 'Tests/conformance/fixtures')));
const wanted = new Set((option('--format', '') || '').split(',').filter(Boolean));
const existing = process.env.ORZ_CONFORMANCE_FIXTURES;
const { repository, commit } = manifest.corpus;

for (const entry of manifest.formats) {
  if (!entry.path) continue;
  if (wanted.size && !wanted.has(entry.format)) continue;
  const target = path.join(out, entry.format, path.basename(entry.path));
  if (existing) {
    const source = path.join(existing, entry.path);
    if (!fs.existsSync(source)) throw new Error(`${entry.format}: missing ${source}`);
    fs.mkdirSync(path.dirname(target), { recursive: true });
    fs.copyFileSync(source, target);
  } else if (!fs.existsSync(target)) {
    const url = `https://raw.githubusercontent.com/6512345/keygenmusic/${commit}/${entry.path.split('/').map(encodeURIComponent).join('/')}`;
    fs.mkdirSync(path.dirname(target), { recursive: true });
    process.stdout.write(`fetch ${entry.format} <- ${url}\n`);
    const response = await fetch(url);
    if (!response.ok) throw new Error(`${entry.format}: HTTP ${response.status}`);
    fs.writeFileSync(target, Buffer.from(await response.arrayBuffer()));
  }
  const digest = createHash('sha256').update(fs.readFileSync(target)).digest('hex');
  if (digest !== entry.sha256) throw new Error(`${entry.format}: sha256 mismatch (${digest})`);
  console.log(`${entry.format}: ${path.basename(target)}`);
}
