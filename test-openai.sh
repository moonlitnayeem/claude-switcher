#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
BUILD="$(mktemp -d)"
trap 'rm -rf "$BUILD"' EXIT
swiftc -swift-version 5 -target "$(uname -m)-apple-macos13.0" \
    "$ROOT/Sources/App/OpenAIProfileLauncher.swift" "$ROOT/Tests/OpenAIProfiles/main.swift" \
    -o "$BUILD/account-checks"
"$BUILD/account-checks"
