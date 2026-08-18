# GrokBuild

A native macOS app around the `grok` command line tool. It runs the real Grok Build
terminal interface in a pseudo-terminal, so the tool behaves exactly as it does in a
terminal — and adds a window, tabs, and a searchable list of every conversation.

By gl11tchy.

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

## Keyboard

| Shortcut | Action |
| --- | --- |
| `⌘T` | New session in the current folder |
| `⌘⇧N` | New session in another folder |
| `⌘W` | Close tab |
| `⌘⇧]` / `⌘⇧[` | Next / previous tab |
| `⌘1`…`⌘9` | Go to tab |
| `⌘+` / `⌘-` / `⌘0` | Font size |
| `⌘R` | Reload the conversation list |
| `⌘,` | Settings |

## Requirements

- macOS 14 or later
- The `grok` CLI at `~/.grok/bin/grok` (set another path in Settings)

The app is deliberately **not** sandboxed: it starts `grok` as a child process, and
that process needs the same access to your files and network that it has in a terminal.

## Build

```sh
Scripts/build-app.sh
```

Writes `dist/GrokBuild.app`. Double-click it, or `open dist/GrokBuild.app`.

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

## Where the conversations come from

The sidebar reads `~/.grok/sessions/` (or `$GROK_HOME/sessions`), where the CLI keeps
one directory per working directory and one directory per conversation inside it. The
app watches that tree, so the list stays current while sessions run — including ones
started outside the app.

New sessions are started with an app-chosen `--session-id`, so a conversation is
traceable from the tab back to its directory on disk.
