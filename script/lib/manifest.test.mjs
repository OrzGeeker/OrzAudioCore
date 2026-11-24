import assert from 'node:assert/strict';
import test from 'node:test';
import {
  PROFILE_IDS,
  buildInfo,
  cacheNamespace,
  decoderSetHash,
  decodersForProfile,
  formatsForProfile,
  generatedHeader,
  loadManifest,
  sbom,
} from './manifest.mjs';

const manifest = loadManifest();

test('profile build info is deterministic and profile-specific', () => {
  for (const profile of Object.keys(PROFILE_IDS)) {
    const first = buildInfo(manifest, profile);
    const second = buildInfo(manifest, profile);
    assert.deepEqual(first, second);
    assert.equal(first.profile, profile);
    assert.equal(first.cacheNamespace, cacheNamespace(manifest, profile));
    assert.equal(first.fingerprint, first.cacheNamespace);
    assert.match(first.cacheNamespace, new RegExp(`^orzaudio-${manifest.sdkVersion}-${profile}-[0-9a-f]{12}$`));
    assert.deepEqual(first.formats, formatsForProfile(manifest, profile).map(format => format.id));
    assert.deepEqual(first.decoders, decodersForProfile(manifest, profile));
  }
  assert.notEqual(cacheNamespace(manifest, 'full'), cacheNamespace(manifest, 'server'));
  assert.notDeepEqual(buildInfo(manifest, 'builtin-lite').formats, buildInfo(manifest, 'full').formats);
});

test('decoder set hash changes when a decoder version changes', () => {
  const changed = structuredClone(manifest);
  changed.formats.find(format => format.decoder === 'openmpt').version = '99.0.0';
  assert.notEqual(decoderSetHash(manifest, 'full'), decoderSetHash(changed, 'full'));
});

test('generated header selects build info by compile-time profile id', () => {
  const header = generatedHeader(manifest);
  for (const [profile, id] of Object.entries(PROFILE_IDS)) {
    assert.match(header, new RegExp(`#define ORZ_BUILD_INFO_JSON_${id} `));
    assert.ok(header.includes(`\\"profile\\":\\"${profile}\\"`));
  }
  assert.match(header, /#if ORZ_PROFILE_ID == 0/);
  assert.match(header, /#elif ORZ_PROFILE_ID == 1/);
  assert.match(header, /#elif ORZ_PROFILE_ID == 2/);
  assert.match(header, /#error "Unsupported ORZ_PROFILE_ID/);
});

test('sbom covers every decoder exactly once', () => {
  const components = sbom(manifest).components;
  assert.equal(new Set(components.map(component => `${component.name}@${component.version}`)).size, components.length);
  for (const format of manifest.formats) {
    const component = components.find(entry => entry.name === format.decoder && entry.version === format.version);
    assert.ok(component?.properties[0].value.split(',').includes(format.id), `${format.id} missing from SBOM`);
  }
});
