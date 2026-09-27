# Product hardening verification — 2026-09-27

This records the isolated implementation verification, not a claim of flawless
behavior. That phase used no personal sessions or model prompts and did not merge
or deploy. The owner later authorized completing the release. Current CI, review,
installation and deployment receipts belong to [PR #121](https://github.com/gl11tchy-team/sigil/pull/121).

## Revision and environment

Work began at `be132383565d9d4cb4e253ae3f7f1b7183207c8f`. The branch
`codex/sigil-product-hardening` also contains the subsequent main revision
`a39d5baadb4d29f58023a78d73d4ef7d0bcee6bc` (PR #119) and
`92a352dde8587f6b93f14ec2fb6467883f940b26` (PR #120). Their sidebar/search,
asynchronous startup, native output/Find and screen-cache improvements were
preserved, not replaced. The existing native TextKit harness still runs alongside
the new shipping-app XCTest gate.
Revision `6bacc71ea0f6f5ec70caeb333e54fc92377811b8` repaired startup focus.
The release follow-up also closes the unprobed-provider launch race described below.
The native app source is unchanged from `98c1b52`. The Mac/web gate was repeated
for the watcher and startup-focus repairs; the full native gate also passed again on unchanged native code.

Local tools: Apple silicon, macOS 26.5.1, Xcode 26.6, Swift 6.3.3, Node 22.23.1,
Metal 32023.883 and iOS simulator 26.5. Provider contracts: Claude Code 2.1.283,
Codex 0.157.1 and Grok 1.0.40.

## Baseline

An isolated archive of `be13238`, with minimal Git metadata for revision-stamp
tests, passed `Scripts/verify.sh`: 807 Swift Testing cases, 37 XCTest cases,
158 Sidereal Node tests, 18 Site tests and 106 Chromium/WebKit browser cases.
Dependency audits, shell checks, formatting, debug packaging, signature checks
and isolated launch smoke also passed.

Baseline `iOS/scripts/relay-e2e.sh` passed 46 shared/relay cases.
`DERIVED_DATA=/tmp/sigil-native-baseline-derived iOS/scripts/build.sh` built
the actual unsigned simulator app and extensions. The old CI step covered only
selected sources compiled as a macOS executable, not that complete iPhone build.
GitHub baseline CI run `36319283213` was green on Xcode 16.4.

No failure in the existing baseline gates was confirmed. The first archive lacked Git metadata;
its revision-stamp failure was a harness error. During integration, old lifecycle
fixtures required explicit stop confirmation after initial state became unknown.
Old web fixtures required the new authenticated nonce. Those assertions were
updated to the new safety contract, not skipped.
The expanded native fixture reached the relay's 20-room/minute limit. Fixture
setup now retries only explicit HTTP 429 refusals within a bounded deadline.
Production limits and workflow assertions are unchanged; provider commands are
never retried by that fixture change.

## Final commands

The Mac/web gate and native gate are separate; neither substitutes for the other.

| Command | Verified result |
|---|---|
| `Scripts/verify.sh` | Passed: 903 Swift Testing cases, 37 XCTest cases, 161 Sidereal Node tests, 18 Site tests, 114 Chromium/WebKit cases; audits, shell/format checks, debug bundle/signature and isolated smoke passed |
| `iOS/scripts/ci.sh` | Passed: 85 shared/real-relay cases, 18 app-hosted simulator cases, 7 native TextKit cases, no skips |
| `Scripts/verify-provider-contracts.sh` | Installed version/help/resume contracts passed; no model calls |
| `xcrun --sdk macosx metal --version` | Metal compiler available |
| `shellcheck iOS/scripts/ci.sh iOS/scripts/native-test.sh iOS/scripts/native-output-test.sh iOS/scripts/relay-e2e.sh` | Passed |
| `git diff --check` | Passed |

The Mac gate includes real PTY dispatch through the loopback relay. The browser
gate runs both Chromium and WebKit against the real relay and encryption, with a
synthetic Mac endpoint. The native gate builds `Sigil.app`, `SigilNotifications.appex`
and `SigilWidgets.appex`, then runs the app on a fresh simulator through that relay.
The three-second launch smoke is only packaging/startup evidence.

See [native results and screenshot](ios-verification.md). The browser screenshot
shows the long operation scrolled to its exact ending and literal choices. Its
test also checks the unverified Terminal controls label and absence of invented Yes.

![Web terminal operation and literal choices](web-operation.png)

## Safety coverage and review

| Boundary | Regression evidence |
|---|---|
| Approval context and lifetime | `RemotePromptTests`, `RemoteInteractionTests`, `RemoteSessionOpsTests`: changed commands, changes past old display bounds, repeated/replaced prompts, duplicate/wrong-session answers, partial/wrapped menus and literal PTY bytes |
| No false completion | `TerminalTabTests`, `ProviderLifecycleJournalTests`: silence/title never complete; matched native turn events, duplicates, delayed writes, missing files, replaced/truncated/same-inode rewritten files, crashes and real subprocess journal writes |
| Native continuity | `NativeSessionScannerTests`, `ProviderContinuityIntegrationTests`, `NativeStartupRestorationTests`, `NativeHistoryVisibilityTests`: separate native identities, missing projects, deferred restore, unknown formats, mixed metadata, image-only history and no replacement session |
| Provider readiness | `ProviderLaunchAvailabilityTests`: unknown/checking launch rejection, no-modal remote failures, restart without stopping existing work, stale/cancelled probes, mixed-provider saved order across probe and history completion |
| Notes and capabilities | `ConversationNotesStoreTests`, `ProviderAdapterTests`, `ProviderBoundaryTests`: provider isolation, traversal rejection, supported controls only and unchanged Grok paths |
| Remote freshness and routing | `RemoteRelayTests`, `RemoteStreamOrderingTests`, browser/native tests: client nonce, replayed hello/replies/events, re-watch ordering, revocation during notification registration and no stale socket work |
| Upload and lost-response safety | `RemoteUploadTests`, web tests and native flow tests: connection/tab-bound transfers, orphan/duplicate tails, bounded online queues, no blind retry, same-socket epoch changes and ambiguous timeouts |
| Draft/data preservation | Web and `NativeFlowTests`: exact restart identity, capped snapshots, two Macs sharing a tab ID, delayed authorization/ticket writes/Enter acknowledgements, live state before disk cache, events before restart receipts and retired attachment aliases |
| Notifications | `RemoteAlertTests`, native protocol/receipt tests: finished/failed/stopped/attention distinction, unverified hints, fresh alert IDs, duplicate/expired rejection and bounded receipt storage |
| Phone usability | Chromium/WebKit layout/scroll/focus/raw-output tests; native accessibility-size composer/focus and keyboard-layout-guide test |

New regressions were observed failing before repair for approval aliasing and
fabricated choices, duplicate/orphan uploads, same-socket web authorization,
timeout queue continuation, native authorization epoch reuse, and cross-Mac
draft deletion after delayed Enter. Additional regression fixtures exercise the
remaining boundaries above. Not every security invariant was independently
backported to the baseline.

Independent reviewers checked each workstream outside their own implementation.
They found and repaired startup restoration races, native notes isolation,
titleless native-history visibility, raw-key paste semantics, stream ordering,
revocation persistence, capped restart receipts, malformed-reply continuations,
authorization epochs, cross-Mac draft mutation and project-archive capability
boundaries. Confirmed archive operations leave unsupported running tabs alone.
Post-PR #120 review also repaired asynchronous-cache identity loss, restart events
arriving before their receipts, draft overwrite and retired attachment resurrection.
Automated PR review then found that the original Grok watcher policy ignored native
JSONL writes. Real FSEvents regressions failed for Claude/Codex appends and the adjacent
Codex title index after startup events settled. Scoped policies now cover append,
create, delete and index-only renames, while preserving Grok filtering and excluding
unrelated Codex-home files. The 32-test focused watcher/store run and independent
review passed before the full gates were repeated.
The next CI run exposed an existing startup focus lost-wakeup: the key-window
notification could precede terminal attachment. A deterministic real-pane test
failed before repair. Attachment now retries only pending focus for the selected
tab, retaining existing key-window, Find, sheet and selection guards. The original
startup focus matrix is unchanged. All 29 focused cases and independent review
passed, followed by both full local gates.
Automated review of `695048a` found that an absent installation result allowed
launches before startup probes finished. Desktop, phone, history reopening and
restart now share a fail-closed readiness check. Held-probe regressions failed
before repair. Independent review also reproduced two saved-order races: reversed
provider completion and probes finishing before native history. Probe results now
publish together, and mixed-provider restoration waits for the initial history
scan. Missing histories remain saved without blocking available conversations
after that scan. Existing running work is not stopped by a failed readiness check.
The 241-case focused run and both full local gates passed after these repairs.
Documentation was checked
against the implemented capability limits. No reported code finding remains open.

## Separate authenticated CLI continuity check

The release follow-up used existing Claude Max and ChatGPT logins in two new,
empty temporary projects. Each real interactive CLI accepted exactly two tiny
text-only turns: store a synthetic marker, exit, then resume the same native ID
and return that marker. Both providers passed with zero tool calls. No personal
conversation, credential copy, auth change, or API purchase was involved. These
checks are not part of CI and do not prove Sigil GUI, physical-phone, provider
approval, tool execution, or expired-account recovery.

See [sanitized live continuity receipt](provider-live-continuity.json).

## Performance

These are local synthetic fixtures, not field telemetry or cloud capacity claims.

`NativeSessionScannerTests` scanned 900 native conversations with 20 response records each,
plus header and user records:
cold 286 ms, cached 49 ms, and title/path search 9 ms in the focused run.
`HistoryResponsivenessTests` loaded 900 Grok histories beside four live isolated
PTYs: scan 94 ms; 100 searches 922 ms total (12.3 ms maximum single search);
20 sidebar snapshots 158 ms total (10.4 ms maximum single snapshot).
The main-actor 5 ms ticker's longest interval was 29.6 ms. Test-process RSS was
79.7 MiB; that is not standalone app memory or a long-duration leak measurement.

An integrated Mac suite, alongside native verification, repeated that
fixture: scan 183.2 ms; 100 searches 1,211.8 ms (19.8 ms maximum); 20 snapshots
351.8 ms (24.5 ms maximum); longest ticker interval 37.9 ms; test-process RSS
112.4 MiB after earlier suites. Native-history scan repeated at 246.9 ms cold,
43.1 ms cached and 8.8 ms search. These
runs show local variation, not a statistical latency percentile. The final
watcher-repair gate recorded scan 63.4 ms, maximum search 10.3 ms, maximum snapshot
9.0 ms, longest ticker interval 24.5 ms and RSS 112.6 MiB. Its native-history scan
took 247.4 ms cold, 44.3 ms cached and 9.1 ms search. The subsequent startup-fix
gate recorded 59.0 ms scan, 10.3 ms maximum search, 7.0 ms maximum snapshot,
21.8 ms longest ticker interval and 112.7 MiB test-process RSS. Native-history
scan was 255.5 ms cold, 47.2 ms cached and 9.6 ms search.

The original harness ran all 120 UI operations without yielding and recorded a
964 ms synthetic actor stall. The corrected harness yields between separate user
actions and reports per-action cost; it did not hide or optimize production work.
The measured individual actions did not justify another index or database.

An earlier unthrottled native pairing/selection/send/terminal-control/reconnect/error
test took 3.9 seconds. In the expanded final suite, that case took 67.1 seconds,
including fixture room-allocation rate backoff; the separate connection-level
pair/input/reconnect/error case took 3.7 seconds. Reconnect did not resend input
and retained only identity-matched drafts. These are combined fixture journey
times, not isolated reconnect latency percentiles. WAN, cellular and large
streaming workloads remain unmeasured.

## Remaining verification boundaries

- **CI runner upgrade:** the original Xcode 16.4 image could not run this native
  gate. The release follow-up uses a digest-pinned Tahoe/Xcode 26.5 image with
  iOS 26.5, verified inside its isolated guest. Provisioning checks Xcode, runtime,
  Metal and first-launch readiness before publishing a base. Fifteen regression
  fixtures and independent review cover invalid candidates, unknown shutdown
  state, per-base hashes and the guest shutdown path. Actual guest shutdown and
  base publication passed after using the absolute `/sbin/shutdown` path.
  The old base/hash remains for rollback; the unrelated
  Linux runner was not restarted. Swift caches now include the actual toolchain
  fingerprint. No hosted capacity was purchased. Full workflow results are in
  the PR delivery record; a guest preflight alone is not a full CI pass.
  [PR CI run 36331776892](https://github.com/gl11tchy-team/sigil/actions/runs/36331776892)
  confirmed the Mac/web gate passed and the native preflight failed specifically
  because the selected Xcode was 16.4. No native result artifact existed on that
  incompatible runner; upload failed for the same reason.
  [Run 36332912140](https://github.com/gl11tchy-team/sigil/actions/runs/36332912140)
  then caught the startup focus race described above before reaching native
  preflight. That failure was repaired, not attributed to Xcode or skipped.
  [Run 36343235244](https://github.com/gl11tchy-team/sigil/actions/runs/36343235244)
  passed both full gates on Xcode 26.5 at `695048a`, including the native result
  artifact. The subsequent provider-readiness repair requires its own final-head
  CI and review receipt in the PR record.
- **Provider limits:** all parsed approvals remain unverified terminal controls.
  Claude has no integrated final-completion observer. A new Codex tab cannot
  acquire a native ID by guesswork; open its discovered history to resume it.
  See [exact capabilities](../../provider-capabilities.md).
- **Credentials/hardware:** the separate text-only Claude/Codex resume check above
  passed. Provider tool approval and expired-account recovery, physical APNs/Live
  Activities, camera/cellular workflows and device entitlements remain unverified.
  Ordinary CI uses deterministic supported fixtures, not authenticated model calls.
- **Distribution:** the implementation gates used ad-hoc-signed debug Mac bundles
  and unsigned simulator artifacts. They do not prove signed/notarized distribution.
  The separately authorized release must record its actual artifacts and activation.
  Mac and phone clients must be released together for the nonce requirement.

Local raw gate logs are in `/tmp/sigil-hardening-evidence/` and
`/tmp/sigil-release-evidence/`; native result bundles
are under `.build/native-verification/`. These transient artifacts are not committed.
Committed fixtures, commands and screenshots make the checks reproducible.
