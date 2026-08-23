# Sigil

![Platform](https://img.shields.io/badge/platform-macOS%2014%2B-000000)
![Swift](https://img.shields.io/badge/Swift-6-F05138)
![Tests](https://img.shields.io/badge/tests-111%20passing-4FA87A)
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
a small helper inside the app bundle. Turning it off removes that entry again. Tabs you
open afterwards can message each other; tabs already open cannot.

A message arrives in the other tab exactly as if you had typed it, on one line, marked
with the sending tab's name. An `ask` waits until the other tab calls `reply_to`, or until
the timeout runs out (5 minutes by default, 15 at most).

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

Writes `dist/Sigil.app`. Double-click it, or `open dist/Sigil.app`.

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

Runs the build, the tests, an optional format lint, the app bundling, and a launch
smoke check.

## License

MIT — see [LICENSE](LICENSE).

Sigil bundles [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) (MIT) and
[swift-argument-parser](https://github.com/apple/swift-argument-parser) (Apache 2.0).
It wraps the Grok Build CLI but does not include it.

## Where the conversations come from

The sidebar reads `~/.grok/sessions/` (or `$GROK_HOME/sessions`), where the CLI keeps
one directory per working directory and one directory per conversation inside it. The
app watches that tree, so the list stays current while sessions run — including ones
started outside the app.

New sessions are started with an app-chosen `--session-id`, so a conversation is
traceable from the tab back to its directory on disk.
