# REA-1206 post-merge release gate

PR175 merged as `c4dec35eb5b2cd22b0b11e7fbfc0fd5bfd1b1fb5`, with the same
tree as approved head `5cb3d028b58152b02be5352d923d0679adfbe6ef`.
The complete PR gate passed. Main run
[38501085476](https://github.com/gl11tchy-team/sigil/actions/runs/38501085476)
then failed twice in the pre-existing native push-readiness fixture:

| Attempt | Failing assertion | Other case |
| --- | --- | --- |
| 1 | `anAlertRaisedDuringReconnectSleepUsesTheNextReadyOnTheSameRoom`, line 103: immediate pending queue assertion false | Stop/disconnect passed |
| 2, single unchanged rerun | `stopAndDisconnectClearQueuedPushes(revoke: true)`, line 86: pending count 0 instead of 1 | Reconnect-sleep case passed |

Both attempts passed 230 Sidereal Node tests, 58 Site tests, 236 browser cases
(2 existing engine-specific skips) and 37 XCTest cases. Each Swift Testing run
executed 1,316 tests in 113 suites with one issue. Native iPhone verification,
release bundle and publication were skipped. Both failed logs and terminal
metadata are preserved in the existing external REA-1206 evidence ledger.
No further rerun of unchanged main is planned.

## Correction

`ReadyPushContext.interrupt()` slept 400 ms after scheduling the production 300 ms
alert evaluation. A sleep establishes elapsed time, not completion of a main-actor
callback. It now uses the existing bounded 4-second polling helper to require a
nonempty pending queue before returning. All eight callers already hold either
the relay route or the send gate, keeping the queued event observable. Their
original exact-count, no-send, expiry, revocation, token and reconnect assertions
remain unchanged. A missing event fails the fixture instead of silently proceeding.

This is test-fixture synchronization only. No production push behavior, protocol,
timing, timeout, CI check or assertion was weakened or changed.

## Validation and limits

- The two original CI failures are the before-change evidence; they are distinct
  immediate assertions on the same helper, not proof of customer impact.
- Local native builds and `SigilAppTests` remain prohibited. Compilation and
  execution of this correction must be established by the normal follow-up PR CI.
- Only source/whitespace review runs locally. No local app, browser binding,
  provider data, keychain or credentials are used.
- Installed Sigil 1.0.0/build352 remains the verified official build-603.1 from
  main 52e96e3. Full manifest, executable hashes and strict signature were read
  back after the failed release gate; no new installation was attempted.
- Served web deployment, physical-device and earlier manual acceptance remain
  open. REA-1207 is paused with a clean reproduction-only worktree; no allocation
  or proxy implementation is included here. Protected PR162 remains separate.

Parent must review the exact final follow-up head before any merge. A later
passing main release is required before another official app update.
