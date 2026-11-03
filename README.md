<p align="center">
  <img src="assets/banner.png" alt="notch-limits — Claude Code & Codex usage limits, right at your Mac's notch" width="100%">
</p>

<p align="center">
  <img src="https://img.shields.io/badge/macOS-14%2B-black?logo=apple" alt="macOS 14+">
  <img src="https://img.shields.io/badge/Swift-5.9-F05138?logo=swift&logoColor=white" alt="Swift 5.9">
  <img src="https://img.shields.io/badge/SwiftUI-native-0A84FF" alt="SwiftUI">
  <img src="https://img.shields.io/badge/dependencies-none-success" alt="No dependencies">
  <img src="https://img.shields.io/badge/license-MIT-blue" alt="MIT License">
</p>

# notch-limits

**[Website](https://notch-limits.vercel.app)** · **[Download for macOS](https://github.com/matheusm/notch-limits/releases/latest/download/NotchLimits.dmg)** · [Releases](https://github.com/matheusm/notch-limits/releases)

**A tiny native macOS app that shows your Claude Code and OpenAI Codex usage limits around the MacBook notch.** It covers the 5-hour session limit, the weekly limit and per-model limits, for as many accounts as you use.

The notch area becomes a Dynamic Island-style pill with one progress ring per account. Hover over it and it expands to show every rate-limit window, its percentage and when it resets. On Macs without a notch it falls back to a menu bar item.

If you juggle **multiple Claude Code accounts** (for example personal Max and a work Team plan via `CLAUDE_CONFIG_DIR`) and a **ChatGPT/Codex** plan, you can see at a glance which one still has quota left, without running `/usage` in each terminal.

<p align="center">
  <img src="assets/screenshot-collapsed.png" alt="Collapsed: progress rings next to the MacBook notch" width="520"><br>
  <img src="assets/screenshot-expanded.png" alt="Expanded: per-account usage bars, percentages and reset times" width="520">
</p>

## Features

- **Notch HUD:** progress rings attached to the notch that expand on hover, like a Dynamic Island for your AI quotas.
- **Menu bar fallback:** the menu bar icon appears automatically when no screen has a notch (for example clamshell mode with an external monitor) or when notch mode is off. Clicking it opens the same black panel as the expanded notch, in light mode too.
- **Claude Code limits:** session (5h), weekly (all models) and weekly per-model limits (e.g. Opus/Fable), with exact reset times.
- **Codex limits:** primary and secondary rate-limit windows for ChatGPT plans (Plus, Pro, Team…).
- **Multiple accounts:** any number of Claude Code config dirs plus Codex homes, found automatically in `~/.claude*` and `~/.codex*` and managed in a Settings window.
- **Colors only when needed:** neutral gray rings, orange at 70% and red at 90%.
- **Pace projection:** each bar in the notch panel (and the menu bar panel) has a subtle tick where usage would be if spread evenly over the window, and "At this pace: limit today 16:20" appears under any window you are on track to hit before it resets. It is a linear projection from the current snapshot, with no stored history, and only shows once 15% of the window has passed.
- **Best account now:** with two or more accounts of the same provider, the expanded panel tags the one with the most headroom "Best now".
- **Optional notifications:** a heads-up when a limit reaches 90%, and another when a limit you hit resets ("Claude Work is available again"). Off by default; turn them on in Settings.
- **Read-only and local:** it reuses the credentials your CLIs already store. It never refreshes, rewrites or uploads tokens anywhere other than the official usage endpoint.
- **Local-first:** it reads the usage snapshots Claude Code and Codex already write to disk and only calls the API when they are more than 10 minutes old.
- **Small and dependency-free:** pure Swift + SwiftUI.
- **Launch at login** toggle built in.
- **English, Português and Español:** the UI follows your macOS language order and falls back to English.

## Requirements

- macOS 14 Sonoma or later (the notch HUD needs a MacBook with a notch)
- Xcode Command Line Tools (`xcode-select --install`)
- Logged in to [Claude Code](https://docs.anthropic.com/en/docs/claude-code) with a Claude subscription (Pro/Max/Team) and/or [Codex CLI](https://github.com/openai/codex) with ChatGPT sign-in

## Install

**One line** (installs into `~/Applications`, no Gatekeeper prompt):

```bash
curl -fsSL https://raw.githubusercontent.com/matheusm/notch-limits/main/install.sh | bash
```

**Or download the app:** grab [`NotchLimits.dmg`](https://github.com/matheusm/notch-limits/releases/latest/download/NotchLimits.dmg) (or the [`.zip`](https://github.com/matheusm/notch-limits/releases/latest/download/NotchLimits.zip)), open it and drag Notch Limits to Applications. The app is not notarized yet, so on first launch open **System Settings → Privacy & Security → Open Anyway**.

Universal binary (Apple Silicon + Intel): a 3 MB DMG or a 1.7 MB zip.

### Build from source

```bash
git clone https://github.com/matheusm/notch-limits.git
cd notch-limits
./build.sh          # build, install to ~/Applications and launch
./build.sh --dist   # universal NotchLimits.dmg + .zip in dist/
swift test          # run the test suite
```

### Contributing

Code must pass the same checks CI runs on every push and pull request:

```bash
brew install swiftlint
swiftlint lint --strict   # strict style rules (.swiftlint.yml); any warning fails
swift build               # compiler warnings are errors
swift test
```

The website in `site/` deploys to [notch-limits.vercel.app](https://notch-limits.vercel.app) automatically on every push to `main` that changes it.

## Configuration

Accounts are found automatically. At launch, and whenever you open Settings, the app looks at the folders directly inside your home folder:

| Account | Found when | Default name |
| --- | --- | --- |
| Default Claude Code account | `~/.claude.json` exists | Claude |
| Other Claude Code config dirs | a `~/.claude<suffix>` folder contains a `.claude.json` file | Claude Work (for `~/.claude-work`) |
| Codex | a `~/.codex` or `~/.codex<suffix>` folder contains an `auth.json` file | Codex, Codex Team (for `~/.codex-team`) |

Discovery only checks that these files exist. It does not read them, your shell configuration or the Keychain. If nothing is found, the app shows the default Claude Code (`~/.claude`) and Codex (`~/.codex`) accounts with a hint to log in.

### Settings

Open Settings with the gear button in the expanded notch or in the menu bar panel. The window uses the same black look as the notch panel. Clicking the gear in the notch collapses the notch so it never covers the window; it expands again once you move the pointer away from the notch and back.

Every account, found or configured, has a row where you can:

- show or hide it with its **Shown** / **Hidden** chip (the last visible account cannot be hidden),
- pick its icon by clicking the icon at the start of the row,
- rename it (click the name, then press Return or click elsewhere to apply; an empty name keeps the previous one),
- move it up or down.

Changes apply immediately, without a restart and without any network request, and are saved to `~/.config/notch-limits/accounts.json`.

The **Notifications** section has a single toggle (a chip), off by default: **Notify at 90% and when a limit resets**. Turning it on asks macOS for permission; if you deny it, the toggle turns back off. If macOS has no answer on record when you open Settings (for example after notification permissions were reset), the toggle shows off; turning it on asks again. Once it is on you get, per account:

- **"… is close to its limit"** when a limit window reaches 90%, once per window period (going back under 90% and over it again before the reset does not repeat it);
- **"… is available again"** when a window that was at 90% or more resets and no other window of that account is still at 90% or more. It arrives within about a minute of the reset time, without waiting for the API.

Notifications are text-only banners, with no sound or badge, and they make no extra network requests. They only use data that is less than 15 minutes old, and the first reading after launch never notifies, so a restart never repeats an alert. The setting is stored in the app's preferences, not in `accounts.json`.

### accounts.json

The file is still supported, and Settings now writes it too. You only need to edit it by hand for config folders outside your home folder or not named `.claude*` / `.codex*`:

```json
[
  { "name": "Claude Personal", "provider": "claude", "path": "~/.claude", "icon": "claude" },
  { "name": "Claude Work", "provider": "claude", "path": "~/.claude-work", "icon": "briefcase.fill" },
  { "name": "Codex", "provider": "codex", "path": "~/.codex", "icon": "codex" }
]
```

| Field | Description |
| --- | --- |
| `name` | Label shown in the expanded panel |
| `provider` | `claude` or `codex` |
| `path` | Claude: the `CLAUDE_CONFIG_DIR` of that account (default `~/.claude`). Codex: the `CODEX_HOME` (default `~/.codex`) |
| `icon` | `claude`, `codex`, or any [SF Symbol](https://developer.apple.com/sf-symbols/) name (`leaf.fill`, `briefcase.fill`, `building.2.fill`…) |
| `enabled` | Optional. `false` hides the account; missing means shown. Settings writes it only on hidden accounts |

When the file exists, it is the source of truth: accounts found later that are not in it are added hidden, so your setup stays as it was, and you turn them on in Settings. Before Settings first overwrites a file that was written or edited by hand (not one it saved itself), it copies it to `accounts.json.bak`; an existing backup is never replaced. If `accounts.json` is a symlink (for example into a dotfiles repo), Settings writes through it and keeps the link. Entries with an unknown `provider` are ignored, and Settings drops them when it saves. If the file is empty or invalid, the app uses the accounts it finds.

The accounts are split between the two sides of the notch in order: the first half on the left, the rest on the right. After editing the file by hand, restart the app or click the gear button: every click re-reads the file and your home folder, even when Settings is already open.

### Multiple Claude Code accounts

Claude Code keeps one login per config directory. A common setup is one alias per account:

```bash
# ~/.zshrc
alias claude-work='CLAUDE_CONFIG_DIR=$HOME/.claude-work claude'
```

Log in once with `claude-work`. The `~/.claude-work` folder is found automatically as "Claude Work" the next time the app starts or you open Settings. If you already have an `accounts.json`, it appears there hidden: turn it on in Settings. You only need to add an `accounts.json` entry for config folders outside your home folder or not named `.claude*`.

## Usage

| Action | Result |
| --- | --- |
| Hover the notch | Expands the panel with every limit window and reset time |
| Move the mouse away | Collapses back to the rings |
| **Notch** chip | Turn the notch HUD off and use the menu bar item instead |
| **Login** chip | Launch at login |
| ⚙ | Settings: show, hide, rename, reorder and pick icons for accounts; turn on notifications |
| ↻ / ⏻ | Refresh now / quit |

Each ring shows the **highest** usage among that account's windows, since that is the limit you will hit first.

In the expanded panel (and the menu bar panel), when a provider has two or more accounts with fresh data, the one with the lowest of those numbers gets a neutral **Best now** tag: it has the most headroom right now. Claude and Codex accounts are ranked separately. There is no tag when the lowest values tie, when every account is at 100%, or when fewer than two accounts of that provider have data less than 15 minutes old. The collapsed rings do not change.

## How it works

notch-limits is **local-first**: it reads the usage snapshot your CLIs already keep on disk, and only calls the usage API when that snapshot is more than 10 minutes old.

| Provider | Local snapshot (no network) | API fallback | Credentials (read-only) |
| --- | --- | --- | --- |
| Claude Code | `cachedUsageUtilization` in `~/.claude.json` (or `$CLAUDE_CONFIG_DIR/.claude.json`), written by Claude Code itself | `GET https://api.anthropic.com/api/oauth/usage` | Keychain item `Claude Code-credentials` (or `Claude Code-credentials-<sha256(config dir)[:8]>` for a custom `CLAUDE_CONFIG_DIR`) |
| Codex | Latest `rate_limits` event in `$CODEX_HOME/sessions/**/*.jsonl`, written on every Codex response | `GET https://chatgpt.com/backend-api/wham/usage` | `$CODEX_HOME/auth.json` |

- Local files are re-read every minute and whenever you open the notch or the menu. **Opening the panel never makes a network request.**
- The API is only called when the newest data is more than 10 minutes old, or when you press ↻. When Claude Code or Codex are in use, their own snapshots keep the app up to date with zero extra requests.
- Each account shows how old its data is ("updated 3 min ago"). The age turns orange after 15 minutes.
- If the API answers `429`, the app waits for the `Retry-After` delay and keeps showing the last snapshot in the meantime.

These are the same endpoints that Claude Code's `/usage` and Codex's `/status` use. The Keychain is read through `/usr/bin/security`, which is already on the item's access list, so there is no permission prompt.

## Troubleshooting

- **"Token expired — open the CLI to renew it":** access tokens are short-lived, and notch-limits never refreshes them on purpose, to avoid racing your CLI. Run `claude` (or `claude-work`, `codex`…) once and the account comes back on the next refresh.
- **"API rate limited — retrying in N min":** the usage endpoint only allows a few requests per minute (shared with Claude Code's `/usage`). The app honors the `Retry-After` header, keeps showing the last good data and retries automatically.
- **A Codex account doesn't show up:** notch-limits reads the login Codex keeps in `auth.json` in its home folder (`~/.codex` by default), which is where Codex stores it unless you changed `cli_auth_credentials_store`. With `keyring` or `auto` in `~/.codex/config.toml`, Codex keeps the login in the system credential store instead, and notch-limits can't see it.
- **Nothing next to the notch:** check that the built-in display is active. In clamshell mode the app automatically switches to the menu bar.
- **No notifications:** check that the toggle is on in Settings → Notifications, then open **System Settings → Notifications → Notch Limits** and allow notifications (banner style). Notifications only work in the installed app, not when it runs unbundled with `swift run`.

## Notes

- The UI is available in English, Portuguese and Spanish (System Settings → General → Language & Region). PRs adding more languages are welcome; all strings live in `tr(en, pt, es)` calls (see `Sources/NotchLimits/L10n.swift`).
- The endpoints above are undocumented and may change without notice.
- This is an unofficial community project. It is not affiliated with or endorsed by Anthropic or OpenAI. "Claude" and "Codex" are trademarks of their respective owners.

## License

[MIT](LICENSE)
