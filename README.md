# Claude Switcher

Claude Switcher is a macOS menu bar app for people who use Claude Code in Claude Desktop with more than one account. Keep working in the same profile and with the same model. When your primary account reaches a usage limit, Switcher can send an eligible request to a backup account you have connected.

[Download Claude Switcher for macOS](https://github.com/moonlitnayeem/claude-switcher/releases/latest) · [Release history](https://github.com/moonlitnayeem/claude-switcher/releases) · [Report a problem](https://github.com/moonlitnayeem/claude-switcher/issues)

![The Routing window showing automatic switching, a primary and a backup account, and the last account to answer. The screenshot uses fictional accounts.](docs/images/switcher-routing.png)

## Get started

1. Open the **DMG**, drag **Claude Switcher** to **Applications**, and open it. The app runs on Apple silicon and Intel Macs with macOS 13 or later. Automatic account switching requires macOS 15 or later and Claude Desktop.
2. Open **Routing** and choose the Claude profile you want to use. Under **Accounts**, choose **Add an Account**. Select another profile you already use, or choose **Sign In to Another Account…**.
3. Turn on **Automatic switching** for that profile. If Switcher prompts for Keychain access, allow it to use the sign-ins you selected. If the dashboard asks you to reopen the profile, finish any active work and reopen it once so Claude Code picks up the local connection.
4. Use Claude Code normally. **Routing activity** shows the account and model that answered the last successful request. When a later request fails, its result is shown separately.

Turn the switch off at any time to use only the profile's own account for new requests. Your backup list and sign-ins are saved for the next time you turn it on.

## What happens at a limit

Switcher tries the profile's own account first for an ordinary Claude Code inference request. If that account is limited, it tries eligible backups assigned to the profile. A conversation explicitly assigned to an account or tied to an account-owned thread can keep that account. Requests referencing account-owned files, connectors or other resources stay with their owner. Chat and Cowork continue to use their existing accounts.

Fable can have a separate limit even when the account still has weekly usage available. Switcher tracks the reported Fable reset independently. If the provider has already reset the allowance, choose **Recheck Fable** next to that account. The next eligible Fable request can check it once. Switcher keeps the model you selected. If every eligible account declines the request, Claude shows the provider's limit.

During a relay update, active responses can finish and idle connections reconnect to the new relay. The dashboard shows the last observed request, so you can see what actually happened.

## If you already use Claude Graft

Switcher has its own settings, application identifier, relay and saved sign-ins. You can open it alongside Graft to explore the dashboard. Each Claude profile can use one router at a time. To try Switcher while Graft is handling ongoing work, use a separate profile that Graft is not routing.

To move a profile, first finish its active work. In Graft, remove that profile's shared-usage assignments and close the profile once so Graft can restore its connection settings. Graft may forget a backup sign-in when its last assignment is removed. Add that account in Switcher, enable automatic switching for the profile and reopen it. Switcher reports a conflict while Graft still manages the connection.

## How the local connection works

Automatic switching uses a loopback relay and a local certificate limited to the Anthropic API hostname. The selected profile's Claude Code environment points to that relay. Switcher can forward eligible model requests using a backup's authorization, so use accounts that are yours or that you are authorized to use. Saved sign-ins are stored locally in encrypted form. The app does not install a system-wide proxy.

## Build from source

On macOS with the Swift toolchain, run `./build.sh`. The app is written to `build.noindex/Claude Switcher.app`. Use `./test.sh` for app and policy checks, `./test-relay.sh` for loopback routing integration tests, and `./test-layout.sh` for the window and accessibility checks. See `release.sh` for universal builds, signing and notarization.

Claude Switcher is an independent fork of Claude Graft for macOS. The original project was created by Aaditya Vitthal More and released under the MIT license. Claude and Claude Desktop are Anthropic products. [Original project](https://github.com/aaditya-v-more/claude-graft) · [Original website](https://aaditya-v-more.github.io/claude-graft/) · [Creator website](https://aadityamore.com/) · [GitHub](https://github.com/aaditya-v-more) · [LinkedIn](https://www.linkedin.com/in/aadityavmore/) · [MIT license](LICENSE)
