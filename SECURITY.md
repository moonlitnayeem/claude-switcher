# Security

## Report a vulnerability

Open a private advisory for the AI Switcher fork. If GitHub does not offer private reporting, open an issue requesting a private contact channel. Share the Switcher version, macOS version, affected feature and the minimum steps needed to understand the report. Keep account addresses, tokens, session cookies, conversation contents and Keychain data out of public reports. [Private reporting](https://github.com/moonlitnayeem/claude-switcher/security/advisories/new) · [Fork issues](https://github.com/moonlitnayeem/claude-switcher/issues/new)

## Accounts and local data

With **Use my existing Graft setup** enabled, AI Switcher reads Graft’s saved profile names, backup assignments and local relay status. Graft continues to hold its sign-ins and manage the Claude connection. Choosing **Recheck Fable** sends an explicit, account-specific request to Graft’s local control socket. AI Switcher does not copy Graft’s tokens or change Claude settings in this mode.

When AI Switcher manages its own Claude connection, it reads the access token for configured Claude Desktop profiles using their local credentials and the macOS login Keychain. Tokens are used for usage checks, requested session starts and routing. Claude Desktop owns its login and refresh token. Signing in a backup opens the provider’s authorization page. Switcher exchanges the authorization code with the provider and seals the backup login with the local safe-storage key. The Artifacts, Projects and Search Chats features use separate claude.ai browser stores.

**ChatGPT & Codex** launches the official services with separate local profiles under `~/Library/Application Support/ClaudeSwitcher/OpenAIProfiles/`. Chrome manages each browser profile’s cookies. The Codex CLI manages its own sign-in in an account-specific `CODEX_HOME` using its file credential store. Use the provider’s sign-in screen for each account. Profile folders, login files and session data can contain sensitive information.

## Claude Code routing

For profiles managed directly by AI Switcher, Claude Code connects to a relay on the Mac’s loopback interface. The relay receives configuration over a local Unix socket. Its local certificate authority is constrained to `api.anthropic.com`, and its signing key is discarded after the server certificate is issued. Requests to other hosts pass through the tunnel. The selected Claude Code profile receives its proxy and certificate settings when the profile is closed. An existing Graft or custom connection prevents the standalone router from taking over that profile.

When a backup handles an eligible request, the request’s contents go to Anthropic under the backup account. Use accounts you own or have permission to use. AI Switcher keeps its own account records and relay state under `~/Library/Application Support/ClaudeSwitcher/`. Keep the support folder, local control sockets, Keychain exports and conversation files private.

## Downloads and signing

Download packages and SHA-256 checksums from this fork’s GitHub Releases. The checksum identifies the published download. For each release, the notes describe its Developer ID signature and Apple notarization status. Local developer builds can use an ad-hoc signature. Use the release’s documented signature and notarization details when assessing provenance. [AI Switcher releases](https://github.com/moonlitnayeem/claude-switcher/releases)
