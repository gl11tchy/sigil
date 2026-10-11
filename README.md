# Sigil

![Platform](https://img.shields.io/badge/platform-macOS%2014%2B-000000)
![Swift](https://img.shields.io/badge/Swift-6-F05138)
[![CI](https://github.com/gl11tchy-team/sigil/actions/workflows/ci.yml/badge.svg)](https://github.com/gl11tchy-team/sigil/actions/workflows/ci.yml)
![License](https://img.shields.io/badge/license-MIT-6A6A6A)

A native macOS app for Claude Code, Codex, Devin, Cursor, Kimi Code, and Grok Build.
It runs each provider's real CLI in a terminal tab. Grok, Claude Code and Codex
have searchable native conversation history.

By gl11tchy.

![Sigil, showing the thread list beside a running session](docs/screenshot.png)

*Demo data. The conversations and the session shown are invented.*

## What it adds

- **Provider picker.** Press ⌘T or click a new-session plus, then click a large
  provider icon to launch its CLI in the chosen folder. Claude Code uses `claude`,
  Codex uses `codex`, Devin uses `devin`, Cursor uses `cursor-agent`, and Kimi Code
  uses `kimi`. Install and sign in to each CLI separately. Kimi Code can also sign
  in from Settings › General: with a Kimi account (`kimi login` in the browser) or
  with a Kimi Platform API key, which stays in the Keychain. Sigil uses your login shell's PATH
  and the standard installation folders. Grok keeps its configured Settings path.
  The sidebar lists only chats started in Sigil; chats that the terminal or other
  apps wrote to the same Grok, Claude Code and Codex history stay hidden unless
  Settings › Show chats from other apps is on. Known native
  conversations can resume and restore without creating replacements. A new Codex
  tab has no verified native ID until opened from history; Sigil does not guess it.
  Export and tab messaging remain Grok-only. Other unsupported controls stay hidden.
  See [provider capabilities and format limits](docs/provider-capabilities.md).
  Only matched provider journal events can mark completion. Titles and silence cannot.
  Claude and unidentified Codex tabs keep an explicit unknown or working state.
- **Thread sidebar.** Recognized Grok, Claude Code and Codex conversations on this machine. Home lists the
  sessions that are open right now, with a light on the ones still working,
  then the project list; open a folder to see its chats and start a new one with the plus. Recents
  and Archived sit under the folders as destinations you open. Search by title, folder or
  path. Click a chat to reopen it; if it is already open, the app moves to that
  tab. Hover archive on a chat or a project. Hover X closes an open tab, or
  deletes a closed Grok chat. `⌘`-click selects several chats — `⇧`-click or `⇧↑`/`⇧↓`
  extends the range — and the context menu archives or deletes the selection at
  once. Grok workflow and subagent children stay off the list unless
  you turn them on in Settings. Native-history adapters exclude subagent directories.
  These choices do not stop background work.
- **Search highlight.** Matches from the sidebar Search field (`⌘⇧F`) light up in
  each visible title, in the project name or path on the subtitle, and in the
  Projects header. A hit on the CLI summary or a path still paints a visible run.
  Combine words across conversation names and folders, such as `sigil auth`.
- **Rename.** Name a known Grok, Claude Code or Codex conversation from the row's context menu, `F2` in the
  thread list, or `⌘⇧R` for the session on screen. The name is what the sidebar,
  tabs, and search use, and it survives the CLI rewriting its own summary.
  Reset Name, or a blank rename, brings that summary back.
- **Pins.** Hover a row and pin a chat. Pinned chats stay at the top of Recents
  and of an open project, in the order you pinned them. Hover a folder to pin
  it; pinned folders stay at the top of the project list.
- **Projects.** A list of working folders, newest folder first. Open a folder to
  see its chats. Pin a folder to keep it above the rest. The plus on a folder
  starts a session there.
- **Photo drop.** Drag an image onto the session, or paste one with ⌘V. Grok
  attaches it the same way it does in a regular terminal.
- **Tabs.** Several sessions at once, each in its own folder.
- **Right panel.** ⌥⌘B opens a second column beside the session. It holds a plain
  login shell in the same folder (⌥⌘1) and a notes pad kept per conversation
  (⌥⌘2), saved as one Markdown file per chat under `~/Library/Application
  Support/Sigil/notes/`. The shell is a scratch terminal only: no conversation,
  no tab messaging.
- **Status light.** A green dot per tab while the agent is working, and a dot on the
  Dock icon when a background tab finishes a turn.
- **Terminal colors and font size**, applied live; reopen a session to apply Grok’s interface theme.
- **Transcript export**, through `grok export`.
- **Delete Grok history**, from the row's hover X when the chat is not open, or
  from the context menu. The conversation folder goes to the Trash. Claude and
  Codex history stays read-only; Archive changes only Sigil's own list.
- **Tab restore.** Known Grok, Claude Code and Codex conversations can return on the next launch.
  Unavailable references stay saved. New Codex tabs without a native ID cannot restore.
  Starting the app never creates a replacement conversation.
- **Tab messaging.** Off by default. Turn it on in Settings, and each Grok session gets four
  tools: `list_tabs`, `send_to_tab`, `ask_tab` and `reply_to`. A tab can hand work to
  another tab, or ask it a question and wait for the answer. See below.

## Phone remote control

Open **Settings → Remote** to connect a phone using a QR code. The hosted
web companion is [https://remote.sigilapp.dev](https://remote.sigilapp.dev).
The native **[Sigil for iPhone](iOS/README.md)** app and included **Sidereal** PWA
use the same encrypted relay to control sessions from an internet connection.
The iPhone app also reopens supported saved conversations; the Mac supplies each
provider's capabilities. See its README for pairing, controls, development, and
verification limits. For self-hosting, deploy the relay over HTTPS and enter that
address in Sigil. The Mac makes outbound connections only; no router ports need opening.

See [Sidereal setup](Sidereal/README.md) for hosting, pairing, controls, and limits.
Remote access is off by default. Disconnecting revokes it. Quitting preserves pairing for the next launch.

## Tab messaging

Grok Build has no channel between sessions. Sigil supplies one: it owns every tab, so it
carries the messages itself.

Turning the switch on registers a `sigil` MCP server in `~/.grok/config.toml`, pointing at
a small helper inside the app bundle. Turning it off removes that entry again. Only
sessions started or restarted after you turn it on receive the tools.

A message is queued in the other tab, marked with the sending tab's name. The user can
deliver or dismiss it from the inbox banner. Sigil does not inject an incoming message
without the user's approval. An `ask` waits until the other tab calls
`reply_to`, or until the timeout runs out (5 minutes by default, 15 at most).

The socket lives at `~/Library/Application Support/Sigil/bridge.sock` and is readable only
by you. Any process running as you can talk to it, which is the same trust level as the
terminal itself.

## Keyboard

| Shortcut | Action |
| --- | --- |
| `⌘T` | New session in the current folder |
| `⌘⇧N` | New session in another folder |
| `⌘W` | Close tab (warns while work is active or uncertain) |
| `⌘⇧]` / `⌘⇧[` | Next / previous tab |
| `⌘1`…`⌘9` | Go to tab |
| `⌃⌘T` | List open tabs and jump to one |
| `⌘X` / `⌘C` / `⌘V` / `⌘A` | Cut / copy / paste / select all |
| `⌘F` | Find in the terminal |
| `⌘G` / `⌘⇧G` | Next / previous terminal match |
| `⌘⇧F` | Find conversations |
| `⌘B` | Hide or show the thread list |
| `⌥⌘B` | Hide or show the utility panel |
| `⌥⌘1` / `⌥⌘2` | Panel terminal / notes |
| `⌘+` / `⌘-` / `⌘0` | Font size |
| `⌘R` | Reload the conversation list |
| `⌥⌘R` | Rebuild conversation history |
| `⌘⇧R` | Rename the conversation on screen |
| `⌃⌘A` | Archive / unarchive selection, or remove a project |
| `⌃⌘P` | Pin / unpin the selected conversation or project |
| `⌘Return` | Deliver the selected Grok tab message |
| `⌘,` | Settings |

In the thread list, `↑` and `↓` move the selection, `⇧↑` and `⇧↓` extend a
multi-selection, `Return` opens it, and `F2` renames it.

## Requirements

- macOS 14 or later; Apple silicon for the currently published CI zip
- At least one supported provider CLI, installed and signed in separately
- For Grok: `~/.grok/bin/grok` (set another path in Settings)
- Optional: `~/.grok/bin/grok-sigil`, the themed CLI build described below

The app is deliberately **not** sandboxed: it starts `grok` as a child process, and
that process needs the same access to your files and network that it has in a terminal.

## Build

```sh
Scripts/build-app.sh
```

This attempts a universal release build containing Apple silicon (`arm64`) and
Intel (`x86_64`) executables, verifies both architectures, and writes `dist/Sigil.app`.
The universal build currently fails; without an explicit fallback, the script
stops instead of packaging an old or single-architecture executable.

CI currently sets `SIGIL_ALLOW_THIN=1` and publishes an **arm64-only** zip for
Apple silicon. That artifact does not support Intel Macs. Universal-build repair
is tracked separately in [REA-1228](https://linear.app/reasonable-glyph/issue/REA-1228/make-the-universal-arm64-x86-64-build-succeed-and-stop-shipping-a-thin).

Release builds need Apple's Metal Toolchain. Install it once if Xcode does not have it:

```sh
xcodebuild -downloadComponent MetalToolchain
```

For a faster local bundle on the current Mac:

```sh
SIGIL_CONFIG=debug Scripts/build-app.sh
```

To allow a release build to fall back to the current Mac's architecture (the
same fallback currently enabled in CI):

```sh
SIGIL_ALLOW_THIN=1 Scripts/build-app.sh
```

Local bundles use an ad-hoc signature. To keep macOS folder permissions across rebuilds,
set a signing identity:

```sh
SIGIL_CODESIGN_IDENTITY="Apple Development: Your Name (TEAMID)" Scripts/build-app.sh
```

### Signed and notarized distribution build

Store App Store Connect API credentials in Keychain once:

```sh
xcrun notarytool store-credentials "sigil-notary" \
  --key "/path/to/AuthKey_KEYID.p8" \
  --key-id "KEYID" \
  --issuer "ISSUER_UUID"
```

Then build, sign, submit, staple, and verify the app:

```sh
SIGIL_DISTRIBUTION=1 \
SIGIL_CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
SIGIL_NOTARY_PROFILE="sigil-notary" \
SIGIL_VERSION="1.0.0" \
SIGIL_BUILD="1" \
Scripts/build-app.sh
```

The distribution command requires a verified universal build. It stops on signing,
notarization, stapling, or Gatekeeper errors. Notarization waits for 30 minutes by
default; set `SIGIL_NOTARY_TIMEOUT` to another duration such as `45m` if needed.

Install that bundle on this Mac (quits a running copy first):

```sh
Scripts/install.sh
```

That copies `dist/Sigil.app` to `/Applications/Sigil.app` and opens it. GitHub
cannot write to this Mac. After a merge to `main` and successful gates, CI builds a zip and attaches
it to the rolling [latest release](https://github.com/gl11tchy-team/sigil/releases/latest).
The isolated runner uses a pinned Xcode 26.5 image with an iOS 26.5 simulator.
Guest toolchain checks must pass before a new runner base is published.
On this Mac, agents must run `Scripts/install-latest.sh` after that merge. It
rebuilds HEAD and swaps the new bundle into place without quitting a running
app. Restart Sigil to load the new binary. Download the zip, or rebuild
locally and run `Scripts/install.sh`, if you are installing by hand.

Double-click the finished app, or run `open dist/Sigil.app`.

### Crash logs

If Sigil dies, it writes what it knew to `~/Library/Logs/Sigil/`: the open tabs,
the tail of the selected terminal, and the signal or exception that ended it.
Help ▸ Reveal Crash Logs opens the newest one in Finder. One report per run,
named in UTC so the folder always sorts by time, and ten are kept. A run that
never crashes leaves no file behind. Set `SIGIL_CRASH_LOG_DIR` to write them
somewhere else.

For where the app died, read the report macOS writes for the same crash under
`~/Library/Logs/DiagnosticReports`. Sigil's own report does not walk the stack:
doing that inside a signal handler can hang a process that would otherwise have
died and left that report behind.

Debug build that stays attached to the terminal:

```sh
Scripts/dev.sh
```

Regenerate the app icon:

```sh
Scripts/make-icon.sh
```

## The themed CLI

The detail column is a program someone else drew, so theming only the window
would leave two designs on screen. `Scripts/build-grok-cli.sh` builds the
open-source [Grok Build](https://github.com/xai-org/grok-build) CLI with its
theme patches on top — a `GROK_THEME` override and a `sigil-host` theme that
takes its colours from the window — and installs it as `~/.grok/bin/grok-sigil`.

```sh
brew install protobuf   # once; the build also needs Rust
Scripts/build-grok-cli.sh
```

The app uses the normal `grok` discovered by your login shell by default. A
themed build is an explicit choice: select `grok-sigil` with **Choose…** in
**Settings → General → Grok CLI**. The separate themed build stays at its
pinned upstream revision until you rebuild it; updating your normal Grok does
not update this copy. **Use Installed Grok** returns to automatic discovery,
and **Check Again** refreshes the path and version shown in Settings.

Unchosen paths saved by older defaults migrate to installed discovery. Explicit
choices and other custom paths stay selected, including when their file is
missing. New, resumed and restarted tabs use the executable from the current
availability check; existing running tabs keep their process.

Each Grok tab receives `GROK_THEME` set to the window's theme. Sigil Dark, Sigil Light, and the
app palettes without a named CLI theme send `sigil-host` plus `GROK_THEME_*`
colour keys so the themed TUI matches the window. Normal installed `grok`
ignores unsupported theme variables and runs with its own appearance.
The patches are `Scripts/grok-cli/sigil-neon.patch` and
`Scripts/grok-cli/sigil-host.patch`.

## Verify

```sh
Scripts/verify.sh
iOS/scripts/ci.sh
```

Requires Node 22 or later for the Sidereal tests.

Runs the build, native and Sidereal tests, dependency audit, shell checks, optional Swift format lint, debug app bundling, and
a launch smoke check. The separate iOS gate builds the real app and both extensions,
then runs app-hosted simulator tests through a local relay. It requires Xcode 26
and an installed iOS 26 simulator. Neither gate makes paid model calls.
The smoke launch uses temporary home, preferences, cache, and Grok
folders. It does not restore tabs, register the bridge, or start a real session.

## Task records

Completed task records and the disposition of retained plans are indexed in
[task history](docs/history/README.md). Historical checkboxes and verification
receipts describe their original checkpoints; they are not new work instructions.

## License

MIT — see [LICENSE](LICENSE).

Sigil bundles [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) (MIT) and
[swift-argument-parser](https://github.com/apple/swift-argument-parser) (Apache 2.0).
Their license texts ship in `Sigil.app/Contents/Resources/ThirdPartyLicenses`. Sigil wraps
the Grok Build CLI but does not include it.

## Where the conversations come from

Grok history reads `~/.grok/sessions/` (or `$GROK_HOME/sessions`), where the CLI keeps
one directory per working directory and one directory per conversation inside it. The
app watches that tree, so the list stays current while sessions run — including ones
started outside the app.

New Grok sessions are started with an app-chosen `--session-id`, so a conversation is
traceable from the tab back to its directory on disk.


Claude and Codex use isolated, bounded, read-only native-history adapters.
[Integration boundaries](docs/provider-capabilities.md) describe exact formats,
resumption, lifecycle evidence and unsupported actions.

### Remote compatibility

This revision requires both host and phone clients to echo the phone's fresh nonce
inside authenticated replies. Update both together; older clients receive an
upgrade error rather than dispatching commands. Terminal menu text is unverified,
with full available operation context and literal choices, not a verified approval.
See [the protocol and trust boundary](docs/remote-control.md).

See the [release notes](docs/release-notes-2026-09-27.md) and
[local verification evidence](docs/qa/product-hardening/README.md).
