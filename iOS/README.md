# Sigil for iPhone

The native phone companion for Sigil. Pair with a Mac by QR code, read open
terminal sessions, send text and files, use terminal keys, and reopen supported
saved conversations. The Mac supplies each provider's capabilities. Unsupported
rename, archive, and resume controls stay disabled or hidden.

SwiftUI, iOS 26, no third-party dependencies. The chrome follows the Mac terminal's
light or dark theme.

## Pair and reconnect

1. On the Mac, open Sigil → Settings → Remote and select Connect Phone.
2. In the app, tap Scan code, or tap Paste link.

The app uses the same sealed relay protocol as the Sidereal web companion.
The relay cannot read terminal content or commands. Each connection uses a fresh
phone nonce authenticated by the Mac. Both companions must support this protocol;
older versions receive an upgrade error rather than weaker authorization.

The Mac streams changed rows only when it supplies monotonic event counters.
Otherwise the app polls authenticated state replies. Offline commands are not
queued. Reconnect does not retry commands. A lost acknowledgement means the user
must inspect the terminal before sending again. A successful reply confirms
input dispatch, not provider acceptance or completion.

Send reserves a finite background task before uploading. If the app goes to the
background during that send, it keeps the same connection until the send settles.
With no send, it closes immediately. Returning before completion keeps that send
and connection. If iOS refuses or expires the allowance, or a reply is lost, the
app retains unsent work and says the send may be incomplete. Inspect the terminal
before sending again: input and Enter are never automatically replayed.
Background execution time is controlled by iOS and is not guaranteed.

More than one Mac can be paired. Pairings, cached screens, drafts, and attachments
stay separate. A notification names its Mac; a forgotten Mac cannot redirect a
notification into the current Mac's session. Restored drafts move to a new tab only
when provider, native conversation ID, and canonical project all match.

## Terminal controls and alerts

The eight terminal keys are unavailable while a request is busy. Stop stays
available during a send, even before the provider starts working. Stop cancels
remaining upload/input/Enter stages; an already transmitted request still needs
its receipt or deadline. The incomplete-send warning and draft remain. Confirmed
full-file receipts remove only those attachments, while partial uploads and newer
work remain. Inspect the terminal before sending again; nothing is replayed.

Sigil has no verified approval response broker connected to the owned terminal session.
Parsed menus appear as **Terminal controls**, with the available operation and
exact choice labels. They send ordinary terminal keys, not verified approvals.
Generic selection menus do not gain invented Yes/No shortcuts.

The app asks for notification permission after connecting. The Mac seals alert
content with the device key. `SigilNotifications` opens only alerts with a valid
UUID and timestamp: at most five minutes old, with 30 seconds of future clock skew.
A file-locked, bounded receipt ledger rejects duplicate IDs for the same Mac.
It stores only IDs and times in the extension's private container.

An invalid or duplicate APNs notification can still produce a passive generic
banner. The extension cannot cancel an already delivered APNs notification. Its
fallback contains no stale alert text, completion claim, or session action.

`SigilWidgets` shows a Live Activity for working sessions or verified approval
state. Parsed terminal hints alone do not claim an authoritative approval.
Physical-device push delivery and background Live Activity updates need separate
signed-device testing.

## Local data

Pairing keys and tickets use the device-only Keychain, shared with the notification
extension. A failed update does not delete an existing Keychain item. If a pairing
cannot be saved, the app says it will end when the app closes and retains existing
in-memory pairings. Unsent drafts and attachments are not saved to disk.

The latest selected screen and tab list are cached per Mac as JSON under
Application Support. On iOS, the files use complete file protection until first
unlock. They are **not encrypted separately by Sigil** and have no automatic expiry.
A newer snapshot replaces them; Forget deletes that Mac's cache. Treat application
data and local crash reports as private because they may contain terminal content.

The readable-output formatter is `Sidereal/public/output.mjs`, copied into
`Sigil/Resources/readable-output.js`. The tests fail if those copies differ.

## Development and verification

Run these from the `iOS` directory:

```bash
scripts/typecheck.sh     # app/shared sources against the simulator SDK
scripts/test.sh          # shared logic, compiled as a macOS executable
scripts/relay-e2e.sh     # shared logic and a real local relay
scripts/native-test.sh   # actual app, both extensions, app-hosted simulator tests
scripts/native-output-test.sh # UIKit/TextKit output, Find, and cover tests
scripts/build.sh         # standalone unsigned simulator build
scripts/ci.sh            # required native verification gate
scripts/ship.sh          # signed archive and App Store Connect upload
```

Xcode 26+ and an installed iOS 26+ simulator runtime are required. Native tests
create and remove their own simulator. They never use a personal pairing or paid
provider session. The native gate verifies `Sigil.app`, `SigilNotifications.appex`,
and `SigilWidgets.appex`, then runs the real app's networking and store against a
real relay with a deterministic Mac fixture. The separate TextKit harness preserves native output, Find, scrolling, and cover tests.
Native flow cases run serially and pin one of eight fresh loopback relay instances.
This keeps the expanded suite below the relay's unchanged per-source room budget
and reconnect grace; it does not relax production rate or socket limits.
Result bundles contain test evidence
and a synthetic accessibility-size composer screenshot.

The `sigil-vm` runner uses a digest-pinned Tahoe/Xcode 26.5 image with iOS 26.5.
Provisioning checks Xcode, simulator availability, Metal and first-launch readiness
before publishing its base. The previous Xcode 16.4 base remains available for
rollback. No GitHub-hosted capacity is used. Native checks still fail rather than
skipping the application build.

Simulator builds do not prove distribution signing, physical-device Keychain
entitlements, APNs delivery, notification service activation, or Live Activity
pushes. `ship.sh` is separate and requires the owner's configured signing account.
See [native verification evidence](../docs/qa/product-hardening/ios-verification.md).

Launch with `-demo` (debug builds only) for synthetic offline sessions:

```bash
xcrun simctl launch booted com.gl11tchy.sigilremote -demo
```
