# Phone-remote verification

Spec: `tasks/spec.md`. Plan: `tasks/plan.md`. Closes Task 6. The deploy half of
the old `tasks/todo.md` line stays open as Task 7.

Swift and WebKit are macOS-only, so those two ran on the CI runner, not here.
Everything else ran on Linux. Every claim below is about this branch's own
content, not the `main` it forked from.

## Playwright

`Sidereal/test/browser/mobile.spec.mjs` is wired into `Scripts/verify.sh:62-64`
and runs against a real relay plus a synthetic encrypted Mac. It covers the
spec's browser criteria: attach to chip to send (`a photo from the phone is
queued as a chip and sent as a file`), reading and sending at 320 / 390 / 768 /
1280px, the composer above the on-screen keyboard, the readable-mode Grok
composer and TUI gutters, and the lossless raw toggle.

The 44px touch-target loop previously ran at 400 / 414 / 430px and asserted
Attach but not Send, so it did not substantiate the spec's "Attach and send
stay 44px targets at 320-430px". This change adds `#send` to that loop and
extends it down to 320 and 390px. 20 tests now pass:

```
npx playwright test --project=chromium
```

The container has Chromium only, so WebKit ran in CI, where `Scripts/verify.sh`
installs both and runs both projects. CI run 126 on `b3d094d` is the run that
carries the widened loop; runs from before it did not execute these assertions.

## Native tests

`swift test --no-parallel` covers the file path end to end:

| Check | Test |
| --- | --- |
| `file` action writes the drop cache and pastes the path | `Tests/SigilAppTests/RemoteCommandsTests.swift:75` |
| Chunk assembly, empty files, bad ids, mismatched and excess chunk counts | `Tests/SigilKitTests/RemoteUploadTests.swift:12,31,43` |
| PNG magic bytes, name sanitizing, 4 MB cap, cache trim | `Tests/SigilKitTests/TerminalDropTests.swift:53,71,100` |
| File chunks get a larger text budget than prompt text | `Tests/SigilKitTests/RemoteSessionTests.swift:97` |
| Dropped path is pasted into the child PTY | `Tests/SigilKitTests/TerminalControllerTests.swift:142` |

Two notes on where the size boundaries actually live, because the first draft of
this file got them wrong.

`RemoteSession.swift:66` caps request text at 48,000 bytes for a `file` action
and 8,192 bytes otherwise; 65,536 is the separate encrypted-plaintext ceiling at
lines 109 and 123. `fileChunksMayBeLargerThanPromptText` sends a 20,000-byte
chunk and rejects an 8,193-byte `input`, so it covers the 8 KB prompt-text
limit, not the 64 KB one.

`RemoteUpload.Inbox` has its own 4 MB guard at `RemoteUpload.swift:41`, but it
is unreachable: `maxChunks` (128) times `maxChunkBytes` (32 KB) is exactly
`TerminalDrop.maxRemoteBytes`. The reachable boundary is the chunk count, which
was untested, so this change adds it. The 4 MB cap itself is enforced and tested
one layer down, in `TerminalDrop.writeRemoteFile`.

Swift does not run on Linux, so the chunk-count assertion added here was first
executed by CI. CI run 126 on `b3d094d` is green, and that job is
`Scripts/verify.sh` on `macos-15`: native tests, both browser projects, format
lint, signed debug bundle and smoke launch. Cite that run and not an earlier
one: run 122 on `31e7f0f` and run 124 on `d7a8990` both predate the Swift and
Playwright assertions on this branch.

## Node suites

```
npm --prefix Sidereal ci --ignore-scripts && npm --prefix Sidereal test
npm --prefix Site ci --ignore-scripts && npm --prefix Site test
```

Sidereal 52 passed, 0 failed. Site 7 passed, 0 failed.

## Railway: revision still not proven

Sidereal is deployed and is the pairing default, but nothing here shows which
revision is running, so Task 7 stays open. The routing half is now settled:
checked against Railway on 2026-09-19, `remote.sigilapp.dev` is a verified custom
domain on the Sidereal service with a valid certificate, and the apex
`sigilapp.dev` has moved onto the site service on the same terms.

The reason the revision cannot be read is structural, not a gap in the checking.
The service's source is a local upload, so each deployment carries a snapshot id
and no commit SHA. The active deployment,
`c5c7e7de-76a8-44d0-8d89-a1fdbe349ce2`, was created at 2026-09-18T17:40:14Z,
which is 57 seconds after #43 merged, and #44 touched no Sidereal runtime file.
That timing is suggestive, not evidence: nothing in Railway says what is inside
the snapshot. Connecting the GitHub repo as the service's source is what would
make every future deployment carry a SHA.

`docs/remote-control.md` records the project, environment and service ids, both
custom domains, sleeping disabled, and now the active deployment. That is routing
and configuration. This container's egress cannot reach either host, so there is
no fresh GET to go with it.

`PUBLIC_ORIGIN` is a separate open point, and it stays agent work under Task 11
rather than becoming an owner action: `tasks/product-site-spec.md` reserves only
Namecheap for the owner, and moving this variable is Task 11's own acceptance
criterion. What stopped it here is narrower. A connected Railway app is served
variable names without values, so this session could not read back what it is set
to, and this session's own permissions refused the write; a session with Railway
write access can finish it without the owner touching Railway.

Until the value is confirmed, treat pairing on `remote.sigilapp.dev` as unproven
rather than working. `Sidereal/server.mjs:86` rejects a phone whose `Origin` does
not equal `PUBLIC_ORIGIN`, so a value still pointing at the apex would refuse
every phone on the new host.

What would close Task 7: give the service a source whose revision is readable,
which means connecting the GitHub repo rather than another `railway up` upload,
then record the deployment id and the SHA it carries. The `railway up` command in
`docs/remote-control.md` would deploy the current tree but would again record no
SHA, so it cannot close this on its own.

Task 10 in `tasks/product-site-todo.md`, the owner-only Namecheap change, is now
done, and the apex has moved to the site service. Task 11 is what still follows:
move Sidereal's `PUBLIC_ORIGIN`, prove both hosts and `POST /rooms`, run
`RemoteIntegrationTests` and `Scripts/verify.sh`, and browser-check production.

## Still device-only

Physical camera scan, cellular access and iOS Home Screen installation cannot
be checked by an agent. `docs/remote-control.md` already says so.
