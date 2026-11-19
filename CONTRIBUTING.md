# Contributing to AI Switcher

AI Switcher is a native macOS fork of Claude Graft. Changes to account routing, profile ownership or chat history need regression coverage for the behavior a user can observe. The inherited design notes document storage formats and failure cases encountered in earlier versions. [Working on AI Switcher](CLAUDE.md) · [Design notes](notes)

## Build and test

Use a macOS Swift toolchain with AppKit and SwiftUI. The app targets macOS 13 or later. Automatic account routing requires macOS 15 or later. The core tests, relay integration tests and dashboard fixtures use temporary state.

```sh
./test.sh
./test-relay.sh
./test-layout.sh
./build.sh
```

The native app is written to `build.noindex/AI Switcher.app`. Set `SWITCHER_UNIVERSAL=1` for an Apple silicon and Intel build. The layout tests exercise the English and Russian interfaces and use macOS Accessibility for external control checks. To capture the routing dashboard with fictional accounts, run `Tools/render-dashboard.sh`. It writes the light, dark and empty-state images under `build.noindex/dashboard-previews/`. Screen capture requires a graphical macOS session.

Use a disposable profile for manual experiments. A shortcut bundles its own launcher, and existing shortcuts receive a new launcher when its version changes. For a development test, create a disposable shortcut with the launcher you intend to exercise.

## Pull requests

Open pull requests against this fork’s `main` branch. Describe the user-visible change and the checks you ran. A routing change should cover what happens to the next request, an ongoing conversation, a failed account and a repeated retry where relevant. A change to stored profile data should account for existing installs and partially completed operations. Add new user-facing strings to the English and Russian catalogs.

CI runs the core and relay suites, exercises window layouts and verifies a universal build and its code signatures. [Fork pull requests](https://github.com/moonlitnayeem/claude-switcher/pulls) · [CI workflow](.github/workflows/ci.yml)

## Release packages

The app version comes from `VERSION`. Run the tests before preparing a release. The package script builds a universal app, verifies both architectures and signatures from the mounted disk image, and writes a DMG, ZIP and SHA-256 file to `dist/`. It also leaves the app bundle under `build.noindex/`.

```sh
SWITCHER_SIGN_IDENTITY=- ./release.sh
SWITCHER_SIGN_IDENTITY='Developer ID Application: Your Name (TEAMID)' ./release.sh
SWITCHER_NOTARY_PROFILE='your-notary-profile' ./release.sh --notarize
```

The first command produces an ad-hoc local package. The second uses the named signing identity. The third selects a Developer ID Application identity and uses the specified Keychain profile to submit the app and DMG to Apple, then staples and verifies the tickets. Set both variables to select a specific identity for notarization. Publish the verified artifacts and their checksum together on this fork’s GitHub Releases, with the signing and notarization status that applies to that build. [Packaging script](release.sh) · [Fork releases](https://github.com/moonlitnayeem/claude-switcher/releases)

## Reports and licensing

For a routing issue, include the Switcher version, macOS version, selected model, primary/backup roles, and the states shown under Accounts and Routing activity. Use fictional account labels when sharing screenshots. Diagnostics live in `~/Library/Application Support/ClaudeSwitcher/`. Review and redact local paths and identifiers before sharing excerpts. Submit security reports through the private reporting route. Contributions ship under the MIT license. [Fork issues](https://github.com/moonlitnayeem/claude-switcher/issues) · [Security](SECURITY.md) · [License](LICENSE)
