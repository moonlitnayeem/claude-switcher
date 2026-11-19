#!/bin/bash
# Create a signed universal app and disk image. No installation, tags or publishing.
# ./release.sh                       Developer ID build
# ./release.sh --notarize             also submit to Apple with SWITCHER_NOTARY_PROFILE
# SWITCHER_SIGN_IDENTITY=- ./release.sh   local ad-hoc package
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION")"
BUILD="${SWITCHER_BUILD_DIR:-$ROOT/build.noindex}"
DIST="${SWITCHER_DIST_DIR:-$ROOT/dist}"
BASE="ClaudeSwitcher-$VERSION-macOS"
WORK="$(mktemp -d)"
MOUNT="$WORK/verify"
attached=false
cleanup() {
    if $attached; then hdiutil detach -quiet "$MOUNT" || return; fi
    rm -rf "$WORK"
}
trap cleanup EXIT
notarize=false
case "${1:-}" in
    "") ;;
    --notarize) notarize=true ;;
    *) echo "Usage: $0 [--notarize]" >&2; exit 2 ;;
esac
identity="${SWITCHER_SIGN_IDENTITY:-}"
if [[ -z "$identity" ]]; then
    identity="$(security find-identity -v -p codesigning |
        awk -F'"' '/Developer ID Application:/ {if (!found++) print $2}')"
    if [[ -z "$identity" ]]; then
        echo "Set SWITCHER_SIGN_IDENTITY to your Developer ID Application identity, or '-' for a local build." >&2
        exit 1
    fi
fi
if $notarize && [[ "$identity" == "-" || -z "${SWITCHER_NOTARY_PROFILE:-}" ]]; then
    echo "--notarize requires Developer ID signing and a SWITCHER_NOTARY_PROFILE keychain profile." >&2
    exit 1
fi
submit() {
    local submission status
    echo "Submitting $(basename "$1") to Apple"
    xcrun notarytool submit "$1" --keychain-profile "$SWITCHER_NOTARY_PROFILE" \
        --output-format plist > "$WORK/submission.plist"
    submission="$(/usr/libexec/PlistBuddy -c 'Print :id' "$WORK/submission.plist")"
    echo "Waiting for Apple (submission $submission)"
    xcrun notarytool wait "$submission" --keychain-profile "$SWITCHER_NOTARY_PROFILE" \
        --output-format plist > "$WORK/notary.plist"
    # Check the service response even if the command itself finished successfully.
    status="$(/usr/libexec/PlistBuddy -c 'Print :status' "$WORK/notary.plist")"
    if [[ "$status" != Accepted ]]; then
        echo "Apple notarization returned $status for $submission" >&2
        exit 1
    fi
}

SWITCHER_UNIVERSAL=1 SWITCHER_SIGN_IDENTITY="$identity" SWITCHER_BUILD_DIR="$WORK/build" "$ROOT/build.sh"
APP="$WORK/build/Claude Switcher.app"
if $notarize; then
    ditto -c -k --keepParent "$APP" "$WORK/submit.zip"
    submit "$WORK/submit.zip"
    xcrun stapler staple "$APP"
    xcrun stapler validate "$APP"
fi
mkdir -p "$WORK/image" "$MOUNT" "$BUILD" "$DIST"
# Preserve the notarization ticket when copying the app. Everything originated in a clean temp directory.
ditto "$APP" "$WORK/image/Claude Switcher.app"
ln -s /Applications "$WORK/image/Applications"
cp "$ROOT/Resources/InstallerLayout.dsstore" "$WORK/image/.DS_Store"
cp "$ROOT/Resources/Installation.txt" "$WORK/image/Installation.txt"
hdiutil create -quiet -format UDZO -fs HFS+ -volname "Claude Switcher" \
    -srcfolder "$WORK/image" "$WORK/$BASE.dmg"
sign_flags=(--sign "$identity" --identifier com.moonlitnayeem.claude-switcher.installer)
if [[ "$identity" != "-" ]]; then sign_flags+=(--timestamp); fi
codesign "${sign_flags[@]}" "$WORK/$BASE.dmg"
if $notarize; then
    submit "$WORK/$BASE.dmg"
    xcrun stapler staple "$WORK/$BASE.dmg"
    xcrun stapler validate "$WORK/$BASE.dmg"
fi
hdiutil verify -quiet "$WORK/$BASE.dmg"
codesign --verify --strict "$WORK/$BASE.dmg"
hdiutil attach -quiet -readonly -nobrowse -noautoopen -mountpoint "$MOUNT" "$WORK/$BASE.dmg"
attached=true
mounted="$MOUNT/Claude Switcher.app"
codesign --verify --deep --strict "$mounted"
if $notarize; then
    xcrun stapler validate "$mounted"
    spctl --assess --type execute "$mounted"
fi
for part in MacOS/ClaudeSwitcher Resources/graft-launch Resources/graft-relay; do
    lipo "$mounted/Contents/$part" -verify_arch arm64 x86_64
    codesign --verify --strict "$mounted/Contents/$part"
done
[[ "$(readlink "$MOUNT/Applications")" == /Applications ]]
cmp "$ROOT/LICENSE" "$mounted/Contents/Resources/LICENSE"
[[ -f "$MOUNT/.DS_Store" && -f "$MOUNT/Installation.txt" ]]
hdiutil detach -quiet "$MOUNT"
attached=false
# Publish local results only after the mounted image passes all checks.
rm -rf "$BUILD/Claude Switcher.app"
ditto "$APP" "$BUILD/Claude Switcher.app"
ditto -c -k --keepParent "$APP" "$WORK/$BASE.zip"
mkdir -p "$WORK/unzipped"
ditto -x -k "$WORK/$BASE.zip" "$WORK/unzipped"
codesign --verify --deep --strict "$WORK/unzipped/Claude Switcher.app"
if $notarize; then xcrun stapler validate "$WORK/unzipped/Claude Switcher.app"; fi
mv -f "$WORK/$BASE.dmg" "$DIST/$BASE.dmg"
mv -f "$WORK/$BASE.zip" "$DIST/$BASE.zip"
(cd "$DIST" && shasum -a 256 "$BASE.dmg" "$BASE.zip" > "$BASE.sha256")
echo "Verified $DIST/$BASE.dmg"
echo "App: $BUILD/Claude Switcher.app"
