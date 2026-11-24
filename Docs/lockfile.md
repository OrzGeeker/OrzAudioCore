# SDK lockfile schema

Downstream projects pin OrzAudioCore with one schema-v1 JSON file. The canonical
schema lives in `schemas/audio-core-sdk.lock.schema.json`; generate it from a
release directory with `script/generate-lockfile.mjs`, and validate it with
`script/verify-lockfile.mjs` in consumer CI.

## Example

```json
{
  "schemaVersion": 1,
  "repository": "https://github.com/OrzGeeker/OrzAudioCore",
  "version": "1.4.0",
  "tag": "v1.4.0",
  "commit": "e94ae7f",
  "profiles": {
    "full": {
      "cacheNamespace": "orzaudio-1.4.0-full-a107c62bbe34",
      "fingerprint": "orzaudio-1.4.0-full-a107c62bbe34",
      "formats": ["xm", "mod", "..."],
      "decoders": [{"id": "openmpt", "version": "0.8.0"}]
    }
  },
  "assets": [
    {
      "name": "OrzAudioCore-1.4.0-linux-x86_64-full.tar.gz",
      "platform": "linux-x86_64",
      "profile": "full",
      "sha256": "…64 hex…"
    }
  ]
}
```

## Rules

- `version`/`tag` are the SDK semver and `v<semver>`; `commit` is the tag commit.
- `profiles` contains one entry per profile an asset uses. `formats` and
  `decoders` must equal `build-info.json` from that profile.
- `cacheNamespace` is `orzaudio-<version>-<profile>-<decoderSetHash>`.
  `decoderSetHash` is the first 12 hex of SHA-256 over the profile's format ids
  and `decoder@version` pairs. A decoder patch or format change invalidates it.
- `assets[].name` follows `OrzAudioCore-<version>-<platform>-<profile>.<ext>`
  (`tar.gz`, `tgz`, `zip`, optional `.xcframework.zip`).
- `assets[].sha256` is the checksum of the uploaded file, not the unpacked tree.

## Generate

```bash
node script/generate-lockfile.mjs --version 1.4.0 --release-dir ./release \
  --commit "$(git rev-parse --short=7 v1.4.0)" > audio-core-sdk.lock.json
```

## Verify

```bash
# Structure + manifest consistency (when the lock version matches this repo)
node script/verify-lockfile.mjs audio-core-sdk.lock.json

# Also re-hash assets in a local release directory
node script/verify-lockfile.mjs audio-core-sdk.lock.json --release-dir ./release

# Legacy 1.3.x lockfiles remain readable during migration
node script/verify-lockfile.mjs audio-core-sdk.lock.json --allow-legacy
```

`script/verify-release.mjs <release-dir>` runs artifact verification for every
asset and then round-trips a generated lockfile before publish.

## Migration from the legacy lockfile

The 1.3.x lockfile flattened `webAsset`, `serverAsset*` and `nativeAsset*` at the
top level. They were not machine-checkable per profile. To migrate, download the
new release assets, run `generate-lockfile.mjs`, and update consumer scripts to
read `assets[]`/`profiles[]`. Bump the pinned version so the cache namespace
changes with the binary.
