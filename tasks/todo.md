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
