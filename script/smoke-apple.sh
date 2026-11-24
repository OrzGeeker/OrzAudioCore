#!/usr/bin/env bash
# Link and run a minimal SwiftPM consumer against a macOS-capable xcframework.
#
# Usage: smoke-apple.sh <OrzAudioCore.xcframework>
# Validates the modulemap, Headers and static link path without embedding a dylib.
set -euo pipefail

XCFRAMEWORK="${1:?usage: smoke-apple.sh <OrzAudioCore.xcframework>}"
[[ -d "$XCFRAMEWORK" ]] || { echo "missing xcframework: $XCFRAMEWORK" >&2; exit 2; }
[[ -d "$XCFRAMEWORK/macos-arm64" ]] || { echo "xcframework has no macOS slice (lite is iOS-only)" >&2; exit 2; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/orz-apple-smoke.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
ln -s "$(cd "$(dirname "$XCFRAMEWORK")" && pwd)/$(basename "$XCFRAMEWORK")" "$TMP/OrzAudioCore.xcframework"
mkdir -p "$TMP/Sources/Smoke"
cat > "$TMP/Package.swift" <<'SWIFT'
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "OrzAppleSmoke",
    platforms: [.macOS(.v13)],
    targets: [
        .binaryTarget(name: "OrzAudioCore", path: "OrzAudioCore.xcframework"),
        .executableTarget(name: "Smoke", dependencies: ["OrzAudioCore"],
            linkerSettings: [.linkedLibrary("z"), .linkedLibrary("c++")])
    ]
)
SWIFT
cat > "$TMP/Sources/Smoke/main.swift" <<'SWIFT'
import OrzAudioCore

let abi = orz_abi_version()
precondition(abi >> 16 == 1, "unexpected ABI major")
let count = orz_get_format_count()
precondition(count > 0, "binary exposes no formats")
let info = String(cString: orz_build_info())
precondition(info.contains("\"profile\""), "build info lacks profile")
print("OrzAudioCore Apple smoke: ABI \(abi >> 16).\(abi & 0xffff), \(count) formats")
SWIFT
swift build --package-path "$TMP" -c release
"$TMP/.build/release/Smoke"
