#!/bin/bash
# Render fixture data in the same SwiftUI window shipped by the app.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT="${1:-$ROOT/build.noindex/dashboard-previews}"
BUILD="$ROOT/build.noindex/dashboard-fixture"
mkdir -p "$OUTPUT" "$BUILD"
sed -e '/^@main$/d' \
    -e 's/static let claudeUpdates = ClaudeDesktopUpdater()/static let claudeUpdates = ClaudeDesktopUpdater(session: fixtureSession, version: { "1.0.0" })/' \
    "$ROOT/Sources/App/ClaudeGraftApp.swift" > "$BUILD/ClaudeGraftApp.swift"
sources=()
for source in "$ROOT"/Sources/App/*.swift; do
    [[ "$source" == */ClaudeGraftApp.swift ]] || sources+=("$source")
done
swiftc -whole-module-optimization -swift-version 5 -target "$(uname -m)-apple-macos${MACOS_DEPLOYMENT_TARGET:-13.0}" \
    "$ROOT"/Sources/Shared/*.swift "${sources[@]}" "$BUILD/ClaudeGraftApp.swift" \
    "$ROOT/Tests/Dashboard/"*.swift -o "$BUILD/DashboardFixture"
"$BUILD/DashboardFixture" "$OUTPUT" "$ROOT/Resources/AppIcon.icns"
