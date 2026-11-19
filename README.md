# AI Switcher

Use one Mac app to see which account answers Claude Code and to open ChatGPT or Codex with the account you choose. Claude Code can switch to a backup automatically when your main account reaches a limit.

[Download for macOS](https://github.com/moonlitnayeem/claude-switcher/releases/latest) · [All releases](https://github.com/moonlitnayeem/claude-switcher/releases) · [Report a problem](https://github.com/moonlitnayeem/claude-switcher/issues)

![AI Switcher’s account map showing a sample Fable 5.2 request trying the backup. Both account names are fictional.](docs/images/switcher-routing.png)

## Install

Open the DMG, drag **AI Switcher** to **Applications**, then open it. The app supports Apple silicon and Intel Macs running macOS 13 or later. Automatic switching for Claude Code requires Claude Desktop and macOS 15 or later.

## Keep using your Graft setup

1. Keep Graft running. In **AI Switcher → Settings**, turn on **Use my existing Graft setup**. This option appears when Switcher finds Graft’s saved setup.
2. Quit and reopen **AI Switcher**. Open **Claude Code** in its sidebar. You’ll see your main account, its backups and the last account that answered. Graft keeps its sign-ins and its existing connection to Claude. This setup requires no changes in Claude.
3. Choose **Rename label** beside an account, type a nickname such as “Work”, then choose **Save label**. Leave the label empty to use the original name again. The nickname is saved on this Mac. To add a backup, remove one or change which account a chat uses, choose **Manage in Graft**.

In this setup, Graft handles each Claude Code request. AI Switcher reads its status about once a second while the map is open. You can keep working in the same Claude window with the connection Graft already installed.

The globe slowly turns while the map is visible. A pulse along a line means Graft reported a recent reply. **Recent activity** names the account and model that answered. If a chat has a saved backup choice, that backup can answer even before the main account reaches a limit. Turn on macOS **Reduce Motion** to hold the globe still and read the same account status in text.

## Set up Claude Code in AI Switcher

For a Claude profile with no existing router, open **Claude Code** in the sidebar. Under **Your accounts**, use **Add backup** to select another signed-in profile or sign in to a backup. Turn on **Automatic switching**. Allow Keychain access if prompted. If Switcher asks you to reopen the Claude profile, finish your work and reopen it once to connect it to Switcher’s local relay.

Use **Rename label** to give an account a nickname. **Remove backup** takes an account out of this profile’s list and keeps its sign-in for later. To delete an unused sign-in from AI Switcher, choose **Add backup → Forget a saved sign-in…** and confirm. During a request, the **Account map** lights up the path to the account Switcher is trying. If the main account reaches its limit, the map can move to the backup. **Recent activity** records which account answered and shows a later error separately. Turn **Automatic switching** off to use only the profile’s own account for new requests. Your backup list is saved.

### When Fable reaches its limit

Switcher keeps the model you chose, including Fable 5.2. An account can have weekly usage left and still be out of Fable usage. If you’ve reset that account’s allowance and its old reset time is still showing, choose **Recheck Fable** when offered. The next eligible Fable request checks that account once. A successful reply confirms that Fable is available again.

An eligible request can move to another account you’ve connected. Requests tied to an account-owned file, connector or thread can require that account. A saved account choice can also determine which account answers. If all eligible accounts decline Fable, Claude shows the provider’s limit. Claude Chat and Cowork keep using their own accounts.

## Open ChatGPT or Codex

Choose **ChatGPT & Codex** in the sidebar. Pick an account or choose **Add account** and give it a name, such as “Work”. Add as many profiles as you need. If you used AI Switcher 1.1, your two existing profiles, names and sign-ins carry over.

- **ChatGPT** opens chatgpt.com in a separate Google Chrome profile for the selected account. Sign in there the first time. To switch accounts within a tab, use ChatGPT’s account menu. **Use my usual browser** opens ChatGPT in your regular browser. Chats, uploaded files, memory and settings stay with the ChatGPT account that owns them. [OpenAI’s account switching guide](https://help.openai.com/en/articles/20001068-using-multiple-chatgpt-accounts-on-web-and-mobile)
- **Codex** opens the Codex command-line app in Apple Terminal. Choose **Open Codex…**, pick your project folder, then sign in if prompted. To continue working on those files with another account, select its profile and choose **Use same folder**. A new Codex session opens in the same folder. Your running task and its chat history stay with the account that started them.
- **Rename** changes the selected profile’s name. Under **Account options** (•••), **Remove from list…** hides it. **Removed accounts** lets you restore the profile with its sign-ins intact.

![The ChatGPT and Codex page showing the account list and launch buttons.](docs/images/switcher-openai.png)

## Build and check

On macOS with the Swift toolchain, run `./build.sh`. The app is written to `build.noindex/AI Switcher.app`. Run the relevant checks from the repository root.

| Command | What it checks |
| --- | --- |
| `./test.sh` | App behavior and account selection rules |
| `./test-relay.sh` | Requests through a local relay with test accounts |
| `./test-graft-connection.sh` | Reading an existing Graft setup and queuing a Fable recheck |
| `./test-openai.sh` | Named profiles, isolated sign-ins and reopening a local project |
| `./test-layout.sh` | English and Russian windows and accessibility controls |

Release signing and notarization use `release.sh`. See the security guide for where each mode stores its data. [Security guide](SECURITY.md)

AI Switcher is an independent fork of Claude Graft for macOS. The original project was created by Aaditya Vitthal More and released under the MIT license. Claude and Claude Desktop are Anthropic products. ChatGPT and Codex are OpenAI products. [Original project](https://github.com/aaditya-v-more/claude-graft) · [Original website](https://aaditya-v-more.github.io/claude-graft/) · [Creator website](https://aadityamore.com/) · [GitHub](https://github.com/aaditya-v-more) · [LinkedIn](https://www.linkedin.com/in/aadityavmore/) · [MIT license](LICENSE)
