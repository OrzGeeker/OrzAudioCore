#!/usr/bin/env node
import fs from 'node:fs';
import path from 'node:path';
import process from 'node:process';
import { buildInfo, loadManifest, repoRoot, sbom } from './lib/manifest.mjs';

function usage() {
  throw new Error('usage: generate-release-metadata.mjs <staging-directory> [--profile <name>] [--platform <name>]');
}

const args = process.argv.slice(2);
const stage = args.shift();
if (!stage) usage();
let profile = 'full';
let platform = 'unknown';
while (args.length) {
  const flag = args.shift();
  if (flag === '--profile') profile = args.shift();
  else if (flag === '--platform') platform = args.shift();
  else usage();
}

const manifest = loadManifest(path.join(repoRoot, 'decoder-manifest.json'));
const info = buildInfo(manifest, profile);
const metadata = path.join(stage, 'metadata');
fs.mkdirSync(metadata, { recursive: true });
fs.writeFileSync(path.join(metadata, 'decoder-manifest.json'), `${JSON.stringify(manifest, null, 2)}\n`);
fs.writeFileSync(path.join(metadata, 'build-info.json'), `${JSON.stringify(info, null, 2)}\n`);
fs.writeFileSync(path.join(metadata, 'sbom.cdx.json'), `${JSON.stringify(sbom(manifest), null, 2)}\n`);
fs.writeFileSync(path.join(metadata, 'artifact.json'), `${JSON.stringify({
  sdkVersion: manifest.sdkVersion,
  abiVersion: manifest.abiVersion,
  profile,
  platform,
  cacheNamespace: info.cacheNamespace,
  generatedAt: process.env.SOURCE_DATE_EPOCH
    ? new Date(Number(process.env.SOURCE_DATE_EPOCH) * 1000).toISOString()
    : new Date().toISOString(),
}, null, 2)}\n`);
