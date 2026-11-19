# AI Switcher

AI Switcher shows which account answered a Claude Code request in Claude Desktop. When your main account reaches a limit, an eligible request can move to a backup while you keep the same chat and model. You can also open the OpenAI desktop app or start a new desktop Codex task in a local project.

[Download for macOS](https://github.com/moonlitnayeem/claude-switcher/releases/latest) · [All releases](https://github.com/moonlitnayeem/claude-switcher/releases) · [Report a problem](https://github.com/moonlitnayeem/claude-switcher/issues)

![AI Switcher’s account map showing a sample Fable 5.2 request trying the backup. Both account names are fictional.](docs/images/switcher-routing.png)

## Install

Open the DMG, drag **AI Switcher** to **Applications**, then open it. The app supports Apple silicon and Intel Macs running macOS 13 or later. Automatic switching for Claude Code requires Claude Desktop and macOS 15 or later.

## Use Claude Code in Claude Desktop with Graft

1. Keep Graft running. In **AI Switcher → Settings**, turn on **Use my existing Graft setup**. This option appears when Switcher finds Graft’s saved setup.
2. Quit and reopen **AI Switcher**. Open **Claude Desktop** in its sidebar. You’ll see your main account, its backups and the last account that answered. Graft keeps its sign-ins and its existing connection to Claude. This setup requires no changes in Claude.
3. Choose **Rename label** beside an account, type a nickname such as “Work”, then choose **Save label**. Leave the label empty to use the original name again. The nickname is saved on this Mac. To add a backup, remove one or change which account a chat uses, choose **Manage in Graft**.

On the main profile, choose **Open Claude Desktop** to continue in the installed app. In this setup, Graft handles each eligible Claude Code request sent through its existing connection. AI Switcher reads its status about once a second while the map is open. You can keep working in the same Claude window with the connection Graft already installed.

The globe slowly turns while the map is visible. A pulse along a line means Graft reported a recent reply. **Recent activity** names the account and model that answered. If a chat has a saved backup choice, that backup can answer even before the main account reaches a limit. Turn on macOS **Reduce Motion** to hold the globe still and read the same account status in text.

## Connect a separate Claude Desktop profile directly

For a Claude Desktop profile with no existing router, open **Claude Desktop** in the sidebar. Under **Your accounts**, use **Add backup** to select another signed-in profile or sign in to a backup. Turn on **Automatic switching**. Allow Keychain access if prompted. If Switcher asks you to reopen the Claude profile, finish your work and reopen it once to connect it to Switcher’s local relay.

Use **Rename label** to give an account a nickname. **Remove backup** takes an account out of this profile’s list and keeps its sign-in for later. To delete an unused sign-in from AI Switcher, choose **Add backup → Forget a saved sign-in…** and confirm. During a request, the **Account map** lights up the path to the account Switcher is trying. If the main account reaches its limit, the map can move to the backup. **Recent activity** records which account answered and shows a later error separately. Turn **Automatic switching** off to use only the profile’s own account for new requests. Your backup list is saved.

### Use Claude Code in Terminal

On the main Claude profile, open **More → Open Claude Code in Terminal…** and pick a local project folder. The Claude CLI uses its regular Terminal sign-in and settings. The account map follows Claude Desktop’s connection. Opening Terminal leaves that connection in place.

### When Fable reaches its limit

Switcher keeps the model you chose, including Fable 5.2. An account can have weekly usage left and still be out of Fable usage. If you’ve reset that account’s allowance and its old reset time is still showing, choose **Recheck Fable** when offered. The next eligible Fable request checks that account once. A successful reply confirms that Fable is available again.

An eligible request can move to another account you’ve connected. Requests tied to an account-owned file, connector or thread can require that account. A saved account choice can also determine which account answers. If all eligible accounts decline Fable, Claude shows the provider’s limit. Claude Chat and Cowork keep using their own accounts.

## Use the OpenAI desktop app

Open **ChatGPT & Codex** in the sidebar. **Open desktop app** brings the installed OpenAI app forward with its own signed-in account. If that account hits a usage limit, account switching is manual. Use the desktop app’s own account controls.

Choose **Open project…** and select a folder on your Mac. Codex opens a fresh desktop composer for that folder and waits for your message. **Reopen project** brings you back to that folder for a new task. The files stay on disk, and existing chats and running tasks stay with the account that started them. The account choices in AI Switcher’s **Browser and Terminal profiles** section apply to those optional tools.

![AI Switcher showing the OpenAI desktop launch and project actions.](docs/images/switcher-openai.png)

### Browser and Terminal profiles

Expand **Browser and Terminal profiles** to use named accounts with Chrome and the Codex command-line app. Pick an account or choose **Add account** and give it a name, such as “Work”. Add as many profiles as you need. Your two AI Switcher 1.1 profiles, their names and sign-ins carry over.

- **Open in Chrome** opens chatgpt.com in a separate Chrome profile for the selected account. Sign in there the first time. To switch accounts inside a tab, use ChatGPT’s account menu. **Use my usual browser** opens ChatGPT in your regular browser. Chats, uploaded files, memory and settings stay with the ChatGPT account that owns them. [OpenAI’s account switching guide](https://help.openai.com/en/articles/20001068-using-multiple-chatgpt-accounts-on-web-and-mobile)
- **Open in Terminal…** starts the Codex command-line app. Pick a project folder, then sign in if prompted. Select another profile and choose **Use same folder** to start a new Terminal session under that account with the same local files.
- **Rename** changes a profile’s name. Under **Account options** (•••), **Remove from list…** hides it. **Removed accounts** lets you restore the profile with its sign-ins intact.

## Build and check

On macOS with the Swift toolchain, run `./build.sh`. The app is written to `build.noindex/AI Switcher.app`. Run the relevant checks from the repository root.

| Command | What it checks |
| --- | --- |
| `./test.sh` | App behavior and account selection rules |
| `./test-relay.sh` | Requests through a local relay with test accounts |
| `./test-graft-connection.sh` | Reading an existing Graft setup and queuing a Fable recheck |
| `./test-openai.sh` | Desktop launch and project actions, named profiles and isolated Terminal sessions |
| `./test-layout.sh` | English and Russian windows and accessibility controls |

Release signing and notarization use `release.sh`. See the security guide for where each mode stores its data. [Security guide](SECURITY.md)

AI Switcher is an independent fork of Claude Graft for macOS. The original project was created by Aaditya Vitthal More and released under the MIT license. Claude and Claude Desktop are Anthropic products. ChatGPT and Codex are OpenAI products. [Original project](https://github.com/aaditya-v-more/claude-graft) · [Original website](https://aaditya-v-more.github.io/claude-graft/) · [Creator website](https://aadityamore.com/) · [GitHub](https://github.com/aaditya-v-more) · [LinkedIn](https://www.linkedin.com/in/aadityavmore/) · [MIT license](LICENSE)
