# Phone remote

- [x] Readable output strips Grok 4.6 composer and TUI padding
- [x] Encrypted chunked file upload pastes a Mac path
- [x] Phone attach, chips, Stop, 44px targets
- [x] Tests and browser (`tasks/verify.md`)
- [x] Deploy: confirm the running Sidereal revision carries all of this. Blocked on the
  previous uploads having no readable revision. Stamped uploads are implemented;
  a live coordinated release and matching `/health` response remain Task 7.
  Done 2026-09-23: #66 records the deploy, and `/health` reports revision 199cc86.

## Remote-stack hardening

- [x] A: Adversarial protocol paths; full verification passed.
- [x] B: Sealed ticket routing and no-query logging; full verification passed.
- [x] C: Git revision stamp and health proof; full verification passed (`tasks/remote-hardening-verify.md`).

## Product correctness and continuity — 2026-09-27

- [x] Record baseline full gate, native build, CI and installed CLI contracts.
- [x] Bind approval context, lifetime and exact responses; test real dispatch.
- [x] Remove unsupported completion claims; verify lifecycle transitions.
- [x] Add provider-native Claude/Codex history, resume and saved-tab continuity.
- [x] Share identity and capabilities across Mac, web and native phone.
- [x] Harden event freshness, upload routing and lost-response behavior.
- [x] Build real iOS app and both extensions; exercise simulator and real relay.
- [x] Measure 900+ history and simultaneous sessions; fix measured blockers.
- [x] Independently review integrated change and repair all findings.
- [x] Repair CI-exposed startup focus race with deterministic RED/GREEN and unchanged focus matrix.
- [x] Update product, setup, capability and verification documentation.
- [x] Run full CI commands locally, self-review and commit the verified integration.

Delivery: publish this branch as one PR. Its GitHub record is the delivery receipt.
Do not merge or deploy. The external Xcode 16.4 runner still needs an Xcode 26+ image.
See [verification and limits](../docs/qa/product-hardening/README.md).
