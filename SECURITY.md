# Security

## Report a vulnerability

Open a private advisory for the Claude Switcher fork. If GitHub does not offer private reporting, open an issue requesting a private contact channel. Share the Switcher version, macOS version, affected feature and the minimum steps needed to understand the report. Keep account addresses, tokens, session cookies, conversation contents and Keychain data out of public reports. [Private reporting](https://github.com/moonlitnayeem/claude-switcher/security/advisories/new) · [Fork issues](https://github.com/moonlitnayeem/claude-switcher/issues/new)

## Accounts and local data

Claude Switcher reads the access token in a configured Claude Desktop profile using that profile’s local credentials and the macOS login Keychain. It uses access tokens for usage checks, explicitly requested session starts and routing. Claude Desktop owns its login and refresh token.

Signing in a backup opens the provider’s authorization page. Switcher exchanges the returned authorization code with the provider and seals the backup login with the local safe-storage key. Switcher keeps its account records and relay state under `~/Library/Application Support/ClaudeSwitcher/`. Treat that folder as private. The Artifacts, Projects and Search Chats features use separate claude.ai browser stores for the accounts signed into those features.

## Routing

Configured Claude Code profiles connect to a relay on the Mac’s loopback interface. The relay receives configuration over a local Unix socket. Its local certificate authority is constrained to `api.anthropic.com`, and its signing key is discarded after the server certificate is issued. Requests to other hosts pass through the tunnel. Claude Code receives per-profile proxy and certificate settings when the profile is closed. Switcher detects an existing Graft route or custom connection as a conflict.

When an alternate account answers a model request, the conversation content in that request goes to Anthropic under the answering account. The dashboard shows the account and model recorded by the relay. Files under `pool/`, Keychain exports and conversation files contain sensitive material and should stay on the Mac.

## Downloads and signing

Download packages and SHA-256 checksums from this fork’s GitHub Releases. The checksum identifies the published download. For each release, the notes describe its Developer ID signature and Apple notarization status. Local developer builds can use an ad-hoc signature. Use the release’s documented signature and notarization details when assessing provenance. [Claude Switcher releases](https://github.com/moonlitnayeem/claude-switcher/releases)
