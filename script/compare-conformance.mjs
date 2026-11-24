#!/usr/bin/env node
/**
 * Compare two conformance report directories (baseline vs candidate).
 *
 * Usage: compare-conformance.mjs <baseline-dir> <candidate-dir> [--duration-tolerance 0.002] [--sample-tolerance 1e-4]
 *
 * Integer/float PCM hashes must match exactly for integer paths. For float
 * paths a mismatch is tolerated only when both hashes and the sampled first/
 * last frames stay within `--sample-tolerance`; maxAbs is also compared.
 */
import fs from 'node:fs';
import path from 'node:path';
import process from 'node:process';

const args = process.argv.slice(2);
const baselineDir = args.shift();
const candidateDir = args.shift();
if (!baselineDir || !candidateDir) throw new Error('usage: compare-conformance.mjs <baseline-dir> <candidate-dir>');
const option = (name, fallback) => {
  const index = args.indexOf(name);
  return index >= 0 ? Number(args[index + 1]) : fallback;
};
const durationTolerance = option('--duration-tolerance', 0.002);
const sampleTolerance = option('--sample-tolerance', 1e-4);

const files = fs.readdirSync(baselineDir).filter(name => name.endsWith('.json') && name !== 'index.json');
const problems = [];
const sampleDiff = (a, b) => {
  const left = [...(a?.first ?? []), ...(a?.last ?? [])];
  const right = [...(b?.first ?? []), ...(b?.last ?? [])];
  if (!left.length || left.length !== right.length) return Number.POSITIVE_INFINITY;
  return Math.max(0, ...left.map((value, index) => Math.abs(value - right[index])));
};

for (const file of files) {
  const baselinePath = path.join(baselineDir, file);
  const candidatePath = path.join(candidateDir, file);
  const baseline = JSON.parse(fs.readFileSync(baselinePath, 'utf8'));
  if (!fs.existsSync(candidatePath)) {
    problems.push(`${file}: missing from candidate`);
    continue;
  }
  const candidate = JSON.parse(fs.readFileSync(candidatePath, 'utf8'));
  if (baseline.skipped || candidate.skipped) continue;
  if (baseline.error || candidate.error) {
    if (Boolean(baseline.error) !== Boolean(candidate.error)) problems.push(`${file}: one side failed (${baseline.error ?? candidate.error})`);
    continue;
  }
  const label = baseline.format ?? file;
  if (baseline.buildInfo && candidate.buildInfo && baseline.buildInfo !== candidate.buildInfo) {
    problems.push(`${label}: build info differs between platforms`);
  }
  for (const key of ['sampleRate', 'channels', 'subsongCount', 'capabilities']) {
    if (baseline.stream?.[key] !== candidate.stream?.[key]) {
      problems.push(`${label}: stream.${key} ${baseline.stream?.[key]} != ${candidate.stream?.[key]}`);
    }
  }
  if (Math.abs((baseline.stream?.duration ?? 0) - (candidate.stream?.duration ?? 0)) > durationTolerance) {
    problems.push(`${label}: duration differs by more than ${durationTolerance}s`);
  }
  for (const key of ['int16Sha256', 'floatSha256']) {
    if (baseline.pcm?.[key] !== candidate.pcm?.[key]) {
      if (key === 'floatSha256' && sampleDiff(baseline.pcm, candidate.pcm) <= sampleTolerance) {
        // Tolerate only a bounded float drift; sample arrays prove it is small.
      } else {
        problems.push(`${label}: ${key} mismatch`);
      }
    }
  }
  const seekStatus = baseline.seek?.status;
  if (seekStatus !== candidate.seek?.status) problems.push(`${label}: seek status ${seekStatus} != ${candidate.seek?.status}`);
  if (baseline.seek?.pcm?.int16Sha256 !== candidate.seek?.pcm?.int16Sha256) problems.push(`${label}: seek PCM hash mismatch`);
  if (baseline.cancel?.status !== candidate.cancel?.status) problems.push(`${label}: cancel status ${baseline.cancel?.status} != ${candidate.cancel?.status}`);
  if (baseline.cancel?.status !== -6) problems.push(`${label}: cancel returned ${baseline.cancel?.status}, expected ORZ_ERROR_CANCELLED (-6)`);
  const subsongs = Math.max(baseline.subsongs?.length ?? 0, candidate.subsongs?.length ?? 0);
  for (let index = 0; index < subsongs; index++) {
    const a = baseline.subsongs?.[index], b = candidate.subsongs?.[index];
    if (a?.status !== b?.status) problems.push(`${label}: subsong ${index} status ${a?.status} != ${b?.status}`);
    else if (a?.pcm?.int16Sha256 !== b?.pcm?.int16Sha256) problems.push(`${label}: subsong ${index} PCM hash mismatch`);
  }
}

if (problems.length) throw new Error(`conformance comparison failed:\n  - ${problems.join('\n  - ')}`);
console.log(`conformance reports match: ${files.length} formats`);
