# Sigil

![Platform](https://img.shields.io/badge/platform-macOS%2014%2B-000000)
![Swift](https://img.shields.io/badge/Swift-6-F05138)
[![CI](https://github.com/gl11tchy/sigil/actions/workflows/ci.yml/badge.svg)](https://github.com/gl11tchy/sigil/actions/workflows/ci.yml)
![License](https://img.shields.io/badge/license-MIT-6A6A6A)

A native macOS app around the `grok` command line tool. It runs the real Grok Build
terminal interface in a pseudo-terminal, so the tool behaves exactly as it does in a
terminal — and adds a window, tabs, and a searchable list of every conversation.

By gl11tchy.

![Sigil, showing the thread list beside a running session](docs/screenshot.png)

*Demo data. The conversations shown are invented; the session on the right is real.*

## What it adds

- **Thread sidebar.** Every conversation on this machine, newest first, in Today /
  Yesterday / Previous 7 days buckets. Search by title, folder or path. Click one to
  reopen it; if it is already open, the app moves to that tab.
- **Scope switch.** Show all conversations, or only the ones started in the folder the
  current tab is working in.
- **Tabs.** Several sessions at once, each in its own folder.
- **Status light.** A green dot per tab while the agent is working, and a dot on the
  Dock icon when a background tab finishes a turn.
- **Themes and font size**, applied live to running sessions.
- **Transcript export**, through `grok export`.
- **Delete**, from the row's context menu. The conversation folder goes to the Trash.
- **Tab restore.** The sessions you had open come back on the next launch. Starting the
  app never creates a new conversation.
- **Tab messaging.** Off by default. Turn it on in Settings, and each session gets four
  tools: `list_tabs`, `send_to_tab`, `ask_tab` and `reply_to`. A tab can hand work to
  another tab, or ask it a question and wait for the answer. See below.

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
| `⌘W` | Close tab (warns while the agent is working) |
| `⌘⇧]` / `⌘⇧[` | Next / previous tab |
| `⌘1`…`⌘9` | Go to tab |
| `⌘F` | Find in the terminal |
| `⌘⇧F` | Find conversations |
| `⌘B` | Hide or show the thread list |
| `⌘+` / `⌘-` / `⌘0` | Font size |
| `⌘R` | Reload the conversation list |
| `⌘,` | Settings |

In the thread list, `↑` and `↓` move the selection and `Return` opens it.

## Requirements

- macOS 14 or later
- The `grok` CLI at `~/.grok/bin/grok` (set another path in Settings)

The app is deliberately **not** sandboxed: it starts `grok` as a child process, and
that process needs the same access to your files and network that it has in a terminal.

## Build

```sh
Scripts/build-app.sh
```

This makes a release bundle containing both Apple silicon and Intel executables. It
refuses to package an old or single-architecture executable if that build fails. The
result is `dist/Sigil.app`.

Release builds need Apple's Metal Toolchain. Install it once if Xcode does not have it:

```sh
xcodebuild -downloadComponent MetalToolchain
```

For a faster local bundle on the current Mac:

```sh
SIGIL_CONFIG=debug Scripts/build-app.sh
```

To allow a current-architecture release bundle for local use only:

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

Double-click the finished app, or run `open dist/Sigil.app`.

Debug build that stays attached to the terminal:

```sh
Scripts/dev.sh
```

Regenerate the app icon:

```sh
Scripts/make-icon.sh
```

## Verify

```sh
Scripts/verify.sh
```

Runs the build, tests, shell checks, optional Swift format lint, debug app bundling, and
a launch smoke check. The smoke launch uses temporary home, preferences, cache, and Grok
folders. It does not restore tabs, register the bridge, or start a real session.

## License

MIT — see [LICENSE](LICENSE).

Sigil bundles [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) (MIT) and
[swift-argument-parser](https://github.com/apple/swift-argument-parser) (Apache 2.0).
Their license texts ship in `Sigil.app/Contents/Resources/ThirdPartyLicenses`. Sigil wraps
the Grok Build CLI but does not include it.

## Where the conversations come from

The sidebar reads `~/.grok/sessions/` (or `$GROK_HOME/sessions`), where the CLI keeps
one directory per working directory and one directory per conversation inside it. The
app watches that tree, so the list stays current while sessions run — including ones
started outside the app.

New sessions are started with an app-chosen `--session-id`, so a conversation is
traceable from the tab back to its directory on disk.
