# GrokBuild

A native macOS window around the local `grok` CLI. It wraps a `grok` terminal with tabs and a session sidebar.

gl11tchy

## Requirements

- macOS 14 or later
- The `grok` CLI installed at `~/.grok/bin/grok`

## Build

```sh
Scripts/build-app.sh
```

Writes `dist/GrokBuild.app`. Double-click it, or run `open dist/GrokBuild.app`.

Debug (rebuilds every time; stdout and stderr stay in the terminal):

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

## Sessions

The sidebar reads history from `~/.grok/sessions/` (or `$GROK_HOME/sessions` if that is set). Each conversation lives at `<encoded-cwd>/<session-uuid>/`.
