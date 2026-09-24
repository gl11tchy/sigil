# Sigil for iPhone

The native phone companion for Sigil. It does what the Sidereal web page does,
as an app: pair with the Mac by QR code, see open sessions, read their output
in the terminal's colours, reply, press terminal keys, stop a turn, start a
session in a project or a fresh worktree, close, rename and archive sessions,
reopen a saved chat, and send photos and files.

After the handshake the app asks the Mac to `watch`: the Mac then sends every
change as it happens, as the rows that changed with their styles, and the app
sends no periodic request. A Mac that predates `watch` is polled once a second
as before. The last screen seen from the Mac is kept on disk, so the app shows
it the moment it opens, before the socket comes up.

It speaks the same sealed protocol as `Sidereal/public/app.mjs` through the
same relay (`https://remote.sigilapp.dev` unless the code names another). The
device key and ticket live in the Keychain, this device only. The readable
output view runs `Sidereal/public/output.mjs` itself, bundled as
`Sigil/Resources/readable-output.js`; `scripts/test.sh` fails if the copies differ.

SwiftUI, iOS 26, no third-party dependencies. Dark only, like the Mac app.

More than one Mac: Pair another Mac (in the Sessions sheet or the menu) adds a
pairing; the Sessions sheet lists the Macs and swaps the whole screen to the one
chosen. Each pairing keeps its own cached screen. A notification or the Lock
Screen card names its Mac and opens it. Forget drops only the Mac on screen.

Alerts: once connected the app asks for notification permission and hands its
APNs token to the Mac. With the app closed, a turn that finishes, a question
that appears, or a session that ends arrives as a notification; the Mac seals
the words with the pairing key, so the relay and Apple carry ciphertext, and
`SigilNotifications` (a notification service extension) opens them. The session
on screen runs a Live Activity while it works or asks (`SigilWidgets`): the
Dynamic Island and a Lock Screen card, updated by the Mac's pushes when the app
is away. Both extensions compile `Shared/`, which the app and the test binary
compile too. Tapping a notification or the card opens that session and nothing
else.

## Pair

1. On the Mac, open Sigil → Settings → Remote and select Connect Phone.
2. In the app, tap Scan code and point the camera at the code, or tap Paste link.

## Working on it

```bash
scripts/typecheck.sh    # every source against the iOS simulator SDK
scripts/test.sh         # protocol, history and formatter tests, as a macOS binary
scripts/relay-e2e.sh    # the same tests plus pairing through a real local relay
scripts/build.sh        # full simulator build
scripts/ci.sh           # all of the above
scripts/ship.sh         # archive and upload to App Store Connect for TestFlight
swift scripts/make-icon.swift Sigil/Assets.xcassets/AppIcon.appiconset/AppIcon.png
```

Xcode 26 with the iOS 26 platform is required.

Launch with `-demo` (debug builds only) for offline sample sessions:

```bash
xcrun simctl launch booted com.gl11tchy.sigilremote -demo
```
