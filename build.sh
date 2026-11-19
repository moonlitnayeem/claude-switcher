#!/bin/bash
# Build a native debug copy with ./build.sh, or set SWITCHER_UNIVERSAL=1 for distribution.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
BUILD="${SWITCHER_BUILD_DIR:-$ROOT/build.noindex}"
IDENTITY="${SWITCHER_SIGN_IDENTITY:--}"
DEPLOYMENT="${MACOS_DEPLOYMENT_TARGET:-13.0}"
VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION")"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
APP="$WORK/AI Switcher.app"
CONTENTS="$APP/Contents"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources" "$BUILD"
archs=("$(uname -m)")
if [[ "${SWITCHER_UNIVERSAL:-0}" == 1 ]]; then
    archs=(arm64 x86_64)
fi
sign_flags=(--force --sign "$IDENTITY" --options runtime)
if [[ "$IDENTITY" != "-" ]]; then sign_flags+=(--timestamp); fi

compile() {
    local output="$1" arch slice
    shift
    local slices=() jobs=() job failed=0
    for arch in "${archs[@]}"; do
        slice="$WORK/$(basename "$output").$arch"
        swiftc -O -whole-module-optimization -swift-version 5 \
            -target "$arch-apple-macos$DEPLOYMENT" "$@" -o "$slice" &
        jobs+=("$!")
        slices+=("$slice")
    done
    for job in "${jobs[@]}"; do
        if ! wait "$job"; then failed=1; fi
    done
    if [[ "$failed" == 1 ]]; then return 1; fi
    if [[ "${#slices[@]}" == 1 ]]; then
        mv "${slices[0]}" "$output"
    else
        lipo -create "${slices[@]}" -output "$output"
    fi
}

shared=("$ROOT"/Sources/Shared/*.swift)
echo "Compiling AI Switcher and its helpers for ${archs[*]}"
compile "$CONTENTS/Resources/graft-launch" "${shared[@]}" "$ROOT/Sources/Launcher/main.swift"
compile "$CONTENTS/Resources/graft-relay" "${shared[@]}" "$ROOT"/Sources/Relay/*.swift
compile "$CONTENTS/MacOS/AISwitcher" "${shared[@]}" "$ROOT"/Sources/App/*.swift

cp "$ROOT/Resources/Info.plist" "$CONTENTS/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION" \
    -c "Set :CFBundleShortVersionString $VERSION" "$CONTENTS/Info.plist"
cp "$ROOT/Resources/AppIcon.icns" "$ROOT/LICENSE" "$CONTENTS/Resources/"
for localization in "$ROOT"/Resources/*.lproj; do
    ditto --noextattr --norsrc "$localization" "$CONTENTS/Resources/$(basename "$localization")"
done
for helper in graft-launch graft-relay; do
    codesign "${sign_flags[@]}" --identifier "com.moonlitnayeem.claude-switcher.$helper" \
        "$CONTENTS/Resources/$helper"
done
codesign "${sign_flags[@]}" "$APP"
codesign --verify --deep --strict "$APP"
# Only replace this product's bundle, leaving other builds and test results intact.
rm -rf "$BUILD/AI Switcher.app"
ditto --noextattr --norsrc "$APP" "$BUILD/AI Switcher.app"
codesign --verify --deep --strict "$BUILD/AI Switcher.app"
echo "Built $BUILD/AI Switcher.app ($VERSION)"
