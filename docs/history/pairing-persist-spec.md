Shipped in [#36](https://github.com/gl11tchy-team/sigil/pull/36); kept for history.

# Spec: Persistent remote pairing

Skills: using-agent-skills, spec-driven-development, planning-and-task-breakdown, test-driven-development, incremental-implementation, security-and-hardening, write-swift, git-workflow-and-versioning

ASSUMPTIONS:
1. Scan once. The phone reconnects without a new QR after Sigil quits, the Mac sleeps, the relay restarts, or a room expires.
2. Disconnect on the Mac revokes the pairing. Forget on the phone clears only the phone.
3. Rooms stay ephemeral. A 256-bit ticket is the durable rendezvous id; the device key stays the encryption secret.
4. If a pairing is stored, Sigil starts remote control on launch.
5. Existing phone clients that only stored a room id need one more scan after this ships.

## Objective
Stop asking the owner to re-scan. Pairing survives Sigil restart and short Mac drops. Success: pair once, quit Sigil, open it again, open Sidereal, and the phone is authorized without a new QR.

## Tech Stack
Existing Swift 6 remote control, CryptoKit, Sidereal relay. Keychain for Mac secrets. IndexedDB already holds the phone key. No new dependencies. No relay database.

## Commands
Companion: `cd Sidereal && npm test && npm run test:browser`
Native: `swift test --no-parallel --filter Remote`
Full: `Scripts/verify.sh`

## Project Structure
`Sources/SigilKit/Remote/RemoteSession.swift` — restored paired session
`Sources/SigilApp/RemotePairingStore.swift` — Keychain + in-memory store
`Sources/SigilApp/RemoteControl.swift` — save, restore, retry, ticket on host connect
`Sources/SigilApp/RemoteCommands.swift` — encrypted ticket on replies
`Sidereal/server.mjs` — ticket → current room
`Sidereal/public/app.mjs` — store ticket; reconnect with ticket
Matching tests under `Tests/` and `Sidereal/test/`

## Code Style
Small Codable values, 64-hex secrets, bounded frames, injected store in tests.

## Testing Strategy
Failing tests first: relay ticket lookup after a new room; Mac store round-trip and restore without QR; phone reconnects with ticket and no fragment; integration pair → stop without revoke → start → ticket connect. Playwright keeps the existing QR path.

## Boundaries
- Always: 256-bit ticket and device key; Keychain `AfterFirstUnlockThisDeviceOnly`; validate ticket/key as 64 hex; Disconnect revokes Mac storage; relay never sees the device key; no secrets in logs.
- Ask first: a relay database or multi-phone pairing.
- Never: persist authorization in UserDefaults; put the device key in a URL; skip pairing for a ticket-only client.

## Success Criteria
- After a successful pair, the Mac has origin, device key, and ticket in Keychain.
- Relaunch with that pairing shows no QR and accepts the stored phone.
- A new room after host drop still finds the phone via the ticket.
- Disconnect clears Keychain and requires a new scan.
- Quit does not clear Keychain.
- Pairing QR still expires in five minutes when unpaired.

## Open Questions
None. Rooms still expire on the relay; the Mac allocates a new room and re-registers the same ticket.
