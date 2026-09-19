# Phone-remote verification

Spec: `tasks/spec.md`. Plan: `tasks/plan.md`. Closes Task 6 and the
`tasks/todo.md` "Tests, browser, deploy" line.

Swift and WebKit are macOS-only, so those two ran on the CI runner, not here.
Everything else ran on Linux at `31e7f0f`.

## Playwright

`Sidereal/test/browser/mobile.spec.mjs` is 18 tests wired into
`Scripts/verify.sh:62-64` and run against a real relay plus a synthetic
encrypted Mac. They cover the spec's browser criteria directly: attach to chip
to send (`a photo from the phone is queued as a chip and sent as a file`),
44px targets at 400 / 414 / 430px, reading and sending at 320 / 390 / 768 /
1280px, the composer above the on-screen keyboard, the readable-mode Grok
composer and TUI gutters, and the lossless raw toggle.

```
npx playwright test --project=chromium
```

18 passed. The container has Chromium only, so WebKit ran in CI, where
`Scripts/verify.sh` installs both and runs both projects.

## Native tests

`swift test --no-parallel` covers the file path end to end:

| Check | Test |
| --- | --- |
| `file` action writes the drop cache and pastes the path | `Tests/SigilAppTests/RemoteCommandsTests.swift:75` |
| Chunk assembly, empty files, bad ids, oversize | `Tests/SigilKitTests/RemoteUploadTests.swift:12,31,43` |
| PNG magic bytes, name sanitizing, 4 MB cap, cache trim | `Tests/SigilKitTests/TerminalDropTests.swift:53,71,100` |
| File chunks may exceed the 64 KB prompt ceiling | `Tests/SigilKitTests/RemoteSessionTests.swift:97` |
| Dropped path is pasted into the child PTY | `Tests/SigilKitTests/TerminalControllerTests.swift:142` |

Swift does not run on Linux. CI run 122 on `31e7f0f` is green, and that job is
`Scripts/verify.sh` on `macos-15`: native tests, both browser projects, format
lint, signed debug bundle and smoke launch.

## Node suites

```
npm --prefix Sidereal ci --ignore-scripts && npm --prefix Sidereal test
npm --prefix Site ci --ignore-scripts && npm --prefix Site test
```

Sidereal 52 passed, 0 failed. Site 7 passed, 0 failed.

## Railway

Sidereal is deployed and is the pairing default. `docs/remote-control.md`
records the project, environment and service ids, `PUBLIC_ORIGIN` matching
`https://remote.sigilapp.dev`, sleeping disabled, and a `RemoteIntegrationTests`
run against the deployed relay. PRs #41, #42 and #43 were fixes made against
that live host. This container cannot reach either host, so the live GETs are
the record in `docs/remote-control.md`, not a fresh curl.

The apex cutover for `sigilapp.dev` is not part of this plan. It is
`tasks/product-site-todo.md` Tasks 10 and 11, and it is owner-only Namecheap
work tracked in `tasks/product-site-verify.md`.

## Still device-only

Physical camera scan, cellular access and iOS Home Screen installation cannot
be checked by an agent. `docs/remote-control.md` already says so.
