Shipped in [#36](https://github.com/gl11tchy-team/sigil/pull/36); kept for history.

# Implementation Plan: Persistent remote pairing

Left `tasks/plan.md` in place (phone-remote work, different job).

## Architecture Decisions
- Ticket is a random 256-bit id, separate from the device key. Host connect registers it. Phone connect looks it up. Encrypted replies carry it so the phone can store it.
- Mac Keychain holds `{origin, deviceKey, ticket}`. In-memory store for tests.
- `stop()` closes sockets. `stop(revoke: true)` also clears the store. Quit uses `stop()`.
- Reconnect never gives up while remote is on. After three failed host connects, POST a new room and register the same ticket.
- Auto-start from `AppModel.onAppear` when the store has a pairing.

## Task List

### Phase 1: Relay
- [ ] Task 1: Failing tests for ticket connect after a new room.
- [ ] Task 2: Relay maps ticket → room; deleting a room does not steal a newer mapping.

### Phase 2: Mac pairing
- [ ] Task 3: Failing tests for restored sessions, store, reply ticket, restore without QR, revoke.
- [ ] Task 4: Store, restore, retry, auto-start, encrypted ticket on replies.

### Phase 3: Phone
- [ ] Task 5: Failing tests for storing the ticket and connecting with it.
- [ ] Task 6: Phone persists ticket; reconnects with ticket; bump the service-worker cache.

### Checkpoint
- [ ] `cd Sidereal && npm test && npm run test:browser`
- [ ] `swift test --no-parallel --filter Remote`
- [ ] Docs in `docs/remote-control.md` and `Sidereal/README.md`
- [ ] `Scripts/verify.sh`

## Risks
| Risk | Mitigation |
|------|------------|
| Ticket on plaintext hello leaks a rendezvous id to the page | Send ticket only in encrypted replies and the host query |
| Quit currently calls `stop()` | Default stop does not revoke |
| Keychain in unit tests | Inject an in-memory store; Keychain tests use a unique service |
