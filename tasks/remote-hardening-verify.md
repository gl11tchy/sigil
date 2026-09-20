# Remote-stack hardening verification — 2026-09-20

Completed in order A → B → C. Each full gate passed before the next task started.
The initial checkpoint was uncommitted on the existing BB task branch, based on
`f50c7a161dc6e81dbf6fec783312c8f9a2387bf2`.

| Gate (`Scripts/verify.sh`) | A | B | C |
| --- | --- | --- | --- |
| Sidereal Node tests | 79 | 85 | 91 |
| Site Node tests | 7 | 7 | 7 |
| Chromium + WebKit | 72 | 72 | 72 |
| Swift Testing | 473 | 473 | 473 |
| XCTest | 39 | 39 | 39 |
| Production dependency audits | passed | passed | passed |
| Bash syntax, shellcheck, strict Swift format | passed | passed | passed |
| Signed debug bundle and isolated smoke launch | passed | passed | passed |

## A — adversarial paths

The stale-epoch regression failed with a closed socket before the one-line fix.
It now checks that a stale reply cannot consume a current request, render state,
or rotate its ticket. The valid current reply still completes.

Node and Swift test fresh nonces and independent sending/receiving size limits.
Node handler tests cover duplicate hello, both unauthorized paths, and ticket
persistence across a simulated IndexedDB reload. Real browser reload/reconnect
also passes through IndexedDB and the encrypted relay.

## B — sealed routing

Both clients now put only `role` in their WebSocket query. Room IDs also moved:
leaving those in host URLs would preserve the slot-hijacking path via room fallback.
The first client frame seals routing fields to a fresh, single-use relay key sent
over WSS. This key is separate from the end-to-end device key. The relay cannot
open phone/Mac command traffic. See `Sidereal/README.md` for the wire contract.

Tests cover query rejection/redaction, unsealed tickets, routing replay/reflection,
handshake timeout, wrong host authorization, ticket rebinding, and room recreation.
Native integration verifies CryptoKit routing and paired restart through the Node
relay. Browser tests assert ticket-free URLs for initial pairing and reconnect.

The first full run after moving host room IDs found a test-fixture listener race.
The synthetic host now attaches its listener before awaiting the upgrade and waits
for routing readiness. Focused browser tests and the full gate passed afterward.

## C — readable revision

`Scripts/deploy-sidereal.sh` creates an isolated, stamped runtime bundle. Tests run
that actual script with only Railway replaced by a capture executable; no upload
occurs. They verify the staged file allowlist, source hash, and staging cleanup.

A copied runtime without Git metadata serves the exact stamp on `/health`.
Missing production stamps, malformed metadata, and modified runtime files fail
closed. Uncommitted builds explicitly use `-dirty` plus a source hash.

The local `/health` returned HTTP 200 with:

```json
{"status":"ok","revision":"f50c7a161dc6e81dbf6fec783312c8f9a2387bf2-dirty","gitSHA":"f50c7a161dc6e81dbf6fec783312c8f9a2387bf2","dirty":true,"sourceSHA256":"e39b6839bd4cd54358eba6341aca048bfe94e5b329d8055047f75ef04f9a94e6"}
```

## Release boundary

At the initial checkpoint, no commits, pushes, production uploads, or installed-app changes had been made.
The existing live-deployment Task 7 remains open. The changed handshake requires a
coordinated Mac/relay/PWA release; existing stored device keys and tickets remain valid.
Docker was unavailable, so the image itself was not built. The copied-image runtime,
Docker's stamp-validation command, and the upload packaging path were tested locally.

## Authorized release follow-up

The follow-up request authorizes PR creation, review fixes, squash merge after
green CI and a fresh automated approval, and a coordinated Mac/relay release.
The PR release comment will record the merge SHA, installed bundle verification,
Railway deployment ID, live health stamp, and production protocol checks.
