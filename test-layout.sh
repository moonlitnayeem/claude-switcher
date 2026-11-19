#!/bin/bash
# Exercises the real window with temporary profiles and mocked update replies.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
# A synced Documents folder can add Finder metadata while the bundle is being signed.
# A fresh local fixture also keeps concurrent test runs independent.
if [[ -n "${SWITCHER_LAYOUT_BUILD_DIR:-}" ]]; then
    BUILD="$SWITCHER_LAYOUT_BUILD_DIR"
else
    BUILD="$(mktemp -d "${TMPDIR:-/tmp}/ai-switcher-layout.XXXXXX")"
    trap 'rm -rf "$BUILD"' EXIT
fi
APP="$BUILD/Layout Checks.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# Keep Shared and the app's views, but let the test own the application lifecycle:
# starting Graft's delegate would start monitoring the user's profiles.
sed -e '/^@main$/d' \
    -e 's/static let claudeUpdates = ClaudeDesktopUpdater()/static let claudeUpdates = ClaudeDesktopUpdater(session: layoutSession, version: { "1.49585.0" })/' \
    "$ROOT/Sources/App/ClaudeGraftApp.swift" > "$BUILD/ClaudeGraftApp.swift"
sources=()
for source in "$ROOT"/Sources/App/*.swift; do
    [[ "$source" == */ClaudeGraftApp.swift ]] || sources+=("$source")
done
swiftc -whole-module-optimization -swift-version 5 \
    -target "$(uname -m)-apple-macos${MACOS_DEPLOYMENT_TARGET:-13.0}" \
    "$ROOT"/Sources/Shared/*.swift "${sources[@]}" \
    "$BUILD/ClaudeGraftApp.swift" "$ROOT/Tests/Dashboard/DemoDashboard.swift" "$ROOT/Tests/Layout/main.swift" \
    -o "$APP/Contents/MacOS/LayoutChecks"
# A second process, so the checks can also read a window as an assistive app
# does, from outside.
swiftc -swift-version 5 \
    -target "$(uname -m)-apple-macos${MACOS_DEPLOYMENT_TARGET:-13.0}" \
    "$ROOT/Tests/Layout/outside.swift" -o "$APP/Contents/Resources/outside-reader"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.moonlitnayeem.claude-switcher.layout-checks</string>
<key>CFBundleExecutable</key><string>LayoutChecks</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleDevelopmentRegion</key><string>en</string>
<key>LSUIElement</key><true/>
</dict></plist>
PLIST
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
for localization in "$ROOT"/Resources/*.lproj; do
    ditto "$localization" "$APP/Contents/Resources/$(basename "$localization")"
done
codesign --force --sign - "$APP" >/dev/null
for language in en ru; do
    "$APP/Contents/MacOS/LayoutChecks" -AppleLanguages "($language)"
done
