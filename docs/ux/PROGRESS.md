## REA-1194: incremental web output (2026-10-13)

Generated ~400KB encrypted-loopback polls at390×844/4x Chromium CPU measured
70.95/72.90/75.20ms median/p95/max before changes; final local source measured
7.35/9.10/9.10ms with the same five warmups/20 samples and direct render region.
Exact formatter checkpoints and verified DOM prefix retention replace full work
on ordinary tail changes; unsafe/earlier edits conservatively replay. Full
formatter oracle,33 Node checks,216 Chromium/WebKit web-find/mobile passes with
two explicit skips, new Find/raw/copy/selection/node checks and screenshots are
documented in [QA](../qa/rea-1194.md). Related chrome scope is unchanged. Final
new-case focus passes; the repaired gate passed Verify but caught the required
iPhone formatter mirror. Resource parity is synchronized; next exact-head
native gate and parent review pending. No merge/install/deploy,
provider calls, personal data, local AppTests/build or second implementation.

## REA-1212: bounded APNs connection recovery (2026-10-13)

Unchanged-code loopback reproduction produced two status0 sends on one unanswered
connection. The client now snapshots one intent, permits one no-response-only
fresh retry, bounds attempt/total time at10s/20s clipped to original expiry,
retires idle connections at10minutes, fences old callbacks/shared replacements
and prevents shutdown resurrection. All27 focused Node checks passed, including
GOAWAY, concurrent failures, unknown duplicate attempts/order and a real-relay
rate-charge check. A sealed alert's one actionable receipt is checked only in CI;
passive duplicate fallback/physical delivery remain unverified. [QA](../qa/rea-1212.md)
records evidence and limits. First CI38442630258 compiled and ran1,316 Swift
tests/113 suites with three inherited fixture issues (unordered JSON bytes and
clock advance before actual queue admission). Node203+58/browser219/37 XCTest
passed; native checks skipped. Test-only canonical bytes and required queue
admission preserve earlier assertions; production unchanged. Exact-head gate
and parent personal review pending;
no merge/install, actual provider calls, personal data, denied retry or next ticket.

## REA-1210: original push expiry (2026-10-13)

One fake-clock/held local APNs test reproduced the unchanged-code missing
alert/update/end expirations. New additive original-issued/expiry metadata is
fixed at Mac admission and validated/copied by the relay before waiting. Local
and APNs deadlines align; stale waiting events expire without freshening. Legacy
frames retain zero storage, activity timestamps freeze, and alert collapse keys
separate rooms/tabs. Sealed bytes, identity, client freshness and permissions stay
intact. All 46 focused Node tests and strict local formatting/syntax/diff checks
passed. [QA](../qa/rea-1210.md) records synthetic checks and provider limits.
First candidate CI38430272868 compiled and ran 1,316 Swift tests/113 suites
with two existing bare-tab collapse-ID expectations failing; new timing suites,
37 XCTest, Node192+58 and browser219 passed (one skip), native checks skipped.
Test-only room capture now preserves exact replacement-room hash checks, with
all other assertions retained and production unchanged.
Exact-head CI and parent personal review remain pending; no merge/installation,
actual provider calls, personal data, process inventory or denied retry.

## REA-1231: reopen Grok with saved options (2026-10-13)

Sidebar and remote opening now choose saved model and valid saved effort
independently, using Settings only for each absent/invalid field. A saved model
survives missing/stale/failed catalogs. Relaunch restoration and provider/identity
checks stay unchanged; no tooltip/redesign or automatic model substitution.

Unchanged-code test-only CI38384966225 reproduced three issues in its new test:
Settings model, Settings effort and incorrect resume arguments. The other 1,280
Swift tests and 37 XCTest cases passed. [QA](../qa/rea-1231.md) records generated
history/fake-CLI coverage and limits. AppTests run only in CI; real Grok model
acceptance/rejection-choice UI, real phone and rendered AX/window-ID behavior
remain unobserved. Await exact-head CI and parent personal review. No merge,
installation, personal histories, paid inference or next ticket.

## REA-1222: Cancel preserves a saved pairing (2026-10-13)

Cancel now stops only its pending generation without clearing saved credentials
or notifying other copies. A completed or reopened generation is protected;
old connection failures check identity before closing sockets. Explicit Disconnect
and failed-revoke retry keep their existing behavior.

Unchanged-code test-only CI38375377798 reproduced four issues exclusively in the
new origin-A/origin-B cancellation test: deletion, two notices, another copy stopped
and restore failed. The other 1,272 Swift tests and all 37 XCTest cases passed.
Focused in-memory/loopback fixtures and limits are in [QA](../qa/rea-1222.md).
AppTests remain CI-only; real phone, rendered UI and daily-app behavior are
unobserved. Await candidate CI and parent personal final-diff review. No merge,
installation, actual Keychain/phone state or personal histories were touched.

First candidate CI38377097064 failed compiling a test argument provider's
main-actor origin constants. Moving the same two examples into the test body
repairs that isolation error; production code is unchanged. The failed run remains
in QA evidence, and corrected-head CI is required.

## REA-1225: selected folders and unused worktree attempts (2026-10-13)

Candidate for parent personal review; no merge, installation or manual UI
acceptance recorded. The missing-folder fallback was reproduced against main
`c1d886d` by test-only CI38359248731 (seven issues in the new cases only;
1,250 Swift tests, 37 XCTest cases passing). Creation now validates the selected
folder in the exact source commit before allocating resources. Attempt receipts
guard non-force rollback; changed, locked, possibly started or uncertain resources
retain their complete recovery paths. Inline, Options and phone starts share the
same contract. Home repositories default to their project folder while preserving
explicit choices, including an additive per-project native-phone default.

Focused safety fixtures and limits are in [REA-1225 QA](../qa/rea-1225.md).
AppTests remain CI-only. Required renamed-debug AX/window-ID verification is
unobserved; no local build/process/cache-denial retry or daily-app interaction.
Independent task-finishing and Web New Session work are unchanged.

## REA-1247: preserve distinguishing Recents titles

Multi-project rows now prioritize the title over a bounded project name and a
separate fixed-width relative time. Hover actions reuse the resting accessory
allocation, so title geometry stays stable; search, single-project rows and the
full-width rename field retain their existing paths. Generated native captures
at 200/272/430pt in both themes reproduce the baseline and demonstrate the
change, including wide/non-Latin titles, pinned/working marks and Archived.
The representative 272pt title grows from 94 to 154pt. Actual guarded pointer
hover (including a corrected full-label/frame working-row capture after parent
found the prior selector picked its tab) and supported Rename/Archive AX actions were exercised without keystrokes.
All 57 existing search-highlight tests, app-only builds, signatures and strict
lint/diff checks passed; AppTests run only in normal PR CI. [Evidence and
limits](../qa/rea-1247.md) preserve driver misses and incomplete Unarchive
navigation, with normal owned-fixture cleanup. Exact-head CI and parent personal
review remain required. No merge, daily-app action or next ticket.

# Workbench progress ledger

The resumable record for the [experience contract](EXPERIENCE.md). Each entry
says what was built, how it was checked, what the check showed, and what is
still open. Nothing here is a timing; counts are counted actions.

## REA-1229: user ownership in the Sigil-only list (2026-10-13)

Retain exact conversation IDs from saved pins, archives, names and colors,
including unknown or unreadable history. A separate preferences-only migration
uses independent immutable addition records plus the existing compatibility list, checks
persistence/readback before completion, and reconciles failed future actions
and another copy's later arrivals. Opening alone and Notes alone stay excluded;
provider identity/binding and history parsing are unchanged.

Generated test-only baseline CI38348628425 at
`71c40caf598afc3e34216770ebb159b63625107d` reproduced 31 issues in the eight new
ownership cases on unchanged main production code: 1,239 Swift tests/109 suites,
37 XCTest cases passing. Focused final fixtures cover all categories, overlapping
writes, failed persistence/completion and retry, relaunch, pending identity and
the open-chat/Notes exclusions. See [QA](../qa/rea-1229.md); observed final
exact-head CI and parent review are recorded in the PR and task receipts.

Strict local formatting and diff checks passed. AppTests/builds remain CI-only;
prior local process/cache denials are not retried. No daily-app replacement,
personal histories or paid inference. PR162's blocked note and all pending manual
validation remain untouched. Await parent personal review before merge.

## REA-1351: quiet compatibility details

Newer compatible CLI notices share one collapsed native popover control in the
sidebar footer. Installed/checked versions and limitations remain on demand;
unsupported majors and real history failures retain visible actions. The version,
parser, lifecycle and binding rules are unchanged.

[The verification record](../qa/rea-1351.md) includes actual generated native
before/after screenshots, source/executable hashes, passing shortcut/Escape/focus,
notice counts, availability, search, project navigation, small-window scrolling,
light/dark and failure actions. Seven focused version and eight palette tests
passed against real SigilKit objects; no local AppTests compile/run occurred.
Normal exact-head PR CI and parent personal review remain required. Spoken
VoiceOver, macOS 14 and multiple-display behavior remain unverified. REA-1350's
separate owner manual pointer acceptance remains pending; its exact four CI
exceptions and the six-test gate are unchanged. No daily-app replacement or merge.

Parent review found that the warning Settings links reached Appearance, not the
General pane containing the promised facts. One-shot General routing now preserves
ordinary opens and manual tab choices; actual owned native captures prove both
warning actions and repeated routing. The first exact-head CI run passed 1,222
Swift tests and 37 XCTest tests but failed the hosted physical-top assertion's
unflipped-coordinate assumption. The check now honors the host's coordinate
orientation while retaining the 34-point budget and every other assertion.
The old failure remains in the verification record. Corrected-head CI and parent
review of this focused delta remain required; the four pointer exceptions are unchanged.

## REA-1272: find conversations by note text

The Mac sidebar searches the first 64 KiB of eligible conversation notes after
all title/path hits. A serial background index uses provider/native ID/canonical
workspace keys, metadata reuse and stale-scan fences. A separate cancellable
background matcher publishes cached query membership after a 50ms debounce.
Ambiguous flat notes and conflict copies are excluded, and indexing never moves
legacy files. Unsaved edits and publication invalidate the cached sidebar. Phone
search keeps its existing title/path input. Search help states the prefix limit.

[The verification record](../qa/rea-1272.md) records the generated main reproduction
and passing direct Swift 6/Address Sanitizer checks, including 900 sessions/100
notes with no reads during queries. The first two full CI runs each failed the
original quiet-sidebar observation assertion; neither identified its source.
An active-query guard avoids idle note subscriptions but did not eliminate that
CI failure. A temporary trace then passed full CI, showing initial note
publication with a quiet sidebar and complete, event-free filesystem coverage.
This does not establish why the earlier runs failed. The trace is removed and
a controlled held-read publication test adds timing-specific evidence while
preserving the original assertions. A generated benchmark also prompted
off-main matching and independent initial overlays. Clean-head CI then passed
the original filesystem regression and the controlled publication/Observation
assertions, but failed the new test's visible-row assertion because the
temporary directory was hidden by its default worktree filter. The fixture now
explicitly enables those rows, retaining every assertion. A new exact-head CI
gate remains required. Existing local build/process denials remain binding;
no local UI, daily app install or personal data inspection. Parent personal
final-diff review remains required before merge.

## REA-1261: six-provider availability and first-run choice

New Session and Options expose the checked state of all six CLIs. Settings lists
checked paths, reported versions and full problems with one shared Check Again.
Confirmed missing lookup, failed version commands, timeouts, unknown/stale checks
and Kimi's known missing API key remain distinct. History compatibility notices
do not block an installed CLI. A first-run default settles once from the complete
inventory; explicit preferences and in-progress provider choices are preserved.

[The verification record](../qa/rea-1261.md) records the synthetic baseline and
nine passing production-probe/status groups, plus CI-only selection/render tests.
The real renamed-app AX/window-ID screenshot acceptance gate is **unmet**: its
builder reaches the already denied local SwiftPM path, and normal CI artifacts
contain test results rather than a current runnable Mac bundle. No bypass, daily
app replacement or new binary distribution was attempted. Exact-head CI and
parent personal review remain required; no native screenshot success is claimed.

## REA-1264: incomplete history and scan coverage

The isolated candidate separates per-file compatibility notices from actual read
uncertainty. Unsupported files keep their own cached row; a complete scan can
remove an independently deleted row. Missing or invalid Grok summaries protect
that folder's metadata, and incomplete coverage keeps project pins and focus.
Previously available empty roots now remain known during the store's lifetime.
The conversation list contains an accessible notice, with details in Settings.
REA-1214's version acceptance and REA-1216's identity evidence remain unchanged.

[The ticket verification record](../qa/rea-1264.md) records the synthetic baseline
and 14 passing local production-scanner assertion groups. The review pass added
immediate coordinated root observation, per-file non-regular replacement notices,
an applied-scan observation for equal-count folder changes, and retryable seeding.
Strict format lint,
syntax parsing and diff checks passed. Store and app macro compilation are blocked
locally by the Observation plugin sandbox; no SwiftPM retry or local UI run occurred.
The focused store/app tests and the existing app-hosted viewport/accessibility
fixture require normal PR CI; the PR and Linear comment will record exact-head
results before parent review. No daily app install, live provider behavior or
Settings native accessibility proof is claimed.

The first full review-fix run compiled store/app macros and ran 1,114 tests. The
equal-notice-count regression failed because its fixture did not invoke the app
appearance path that starts observation. The fixture now does so before the
controlled scan; all assertions remain. Final-head CI and the hosted accessibility
gate remain required, with the earlier failure retained in the verification record.

## REA-1214: Codex version compatibility

The Codex minor-version cap and installed-versus-checked notices are recorded in
[the ticket verification record](../qa/rea-1214.md). Synthetic history and lifecycle
checks passed. Version notices now share the history scroll area. New Session
rendering and the 200pt × 460pt sidebar regression are covered by CI-only app
tests. CI proved the fixture's data, viewport and scrolling checks after its filter
correction. The exported-tree walker reached only the window and empty hosting
group in CI; all three notice assertions failed. The independent diagnostic
controls also failed in the command-line host, which reported no running app
loop. A dedicated CI-only SwiftUI app host now owns startup and event processing.
All data, viewport, scrolling, control and notice assertions remain. The native
control identifier moved to its exported NSButtonCell. Compile-only host and
configuration checks passed, as did all 28 focused non-UI tests. CI then passed
all 997 SwiftPM tests but rejected the explicit single-iteration option before
the hosted fixture executed. A command-only correction removes that option;
the normal single run and every assertion remain required. Corrected-head CI
evidence remains; no product accessibility repair or exposure is
claimed. The local AX and screenshot attempt did not produce usable visual
evidence. No UX mission or new-tab identity-binding change is claimed by this ticket.

October 10 resumption: corrected-head CI did execute and failed five ordinary
control/notice assertions. The candidate is reconciled with main `d4337d4`,
preserving both progress histories and existing gates. A matched isolated native
diagnostic kept ordinary controls absent without clients through 15 seconds;
a bounded public own-process AX request exposed both identifiers through the
existing getters before an external client ran. The CI-only fixture now requests
its own hierarchy before observing it, preserving every original assertion.
The 30 focused non-UI tests passed. Hosted runtime and the full integrated gate
remain unverified for this local candidate; parent review is required before push.

## REA-1211: unknown state after unobservable input

Started from main `c2a24a5`, without parked PRs #140 or #142. Before production
changes, CI run [38025826427](https://github.com/gl11tchy-team/sigil/actions/runs/38025826427)
at `805eaa6` executed one synthetic regression with five provider cases. Claude
Code, new Codex, Devin, Cursor and Kimi each incorrectly remained Working with a
non-nil timer: ten expected assertion failures in 0.085 seconds.

The implementation gates Working on observable lifecycle evidence, records a
neutral last-input tooltip and keeps unknown marks grey. Unsupported providers
and missing/rejected Codex transcripts have no completion watch. Codex writer
identity invalidation ends its watch. Running-process close/quit warnings and
validated Grok/Codex turn completion remain covered by synthetic tests. The phone
receives unknown rather than working; its existing Live Activity start rule
requires working or a verified prompt. No iPhone lifecycle code changes.

Final CI run links and results are recorded in
[PR #143](https://github.com/gl11tchy-team/sigil/pull/143).
The first implementation gate at `179763c` ran 1,010 Swift tests in 95 suites:
the lifecycle cases passed, but an existing unread-dot test reported two failures.
The neutral history-row mark was then limited to tabs with recorded input, keeping
the existing unread marker behavior before any submission.
Local application tests remain CI-only. The supported build approval path later
built an isolated renamed debug app through `Scripts/workbench/`. AX actions sent
synthetic prompt/Return bytes through the real terminal controller to fake Claude,
Devin, Cursor, Kimi and new Codex processes. All five remained unknown with grey
tab/sidebar marks, no project working mark, loader or top-bar timer. All retained
their running-process close warning; Claude also retained its quit warning.
[Native screenshots and fixture limits](rea-1211-native/README.md) record the
window IDs and the separate, uncommitted debug fixture used by this check.
No personal provider histories, paid inference, daily app replacement or other
ticket implementations. The fixture app and synthetic tabs exited normally.

## REA-1195: outside note edits

Built from `2c99cda` in a separate worktree; blocked PR #140 remains untouched.
Temporary Markdown fixtures reproduced two failures before the fix: idle atomic
replacement stayed stale, and a queued local save overwrote outside text without
a conflict file. The first run had 15 passing tests and those two failures.

Notes now observe directory/replace events, compare identity plus bytes, preserve
the current outside revision before saving dirty local text, and expose concise
saved/unsaved conflict notices in the panel. The 300ms debounce remains; cached
reads and keystrokes do not add disk reads. Failed preservation keeps disk and
both drafts safe; Retry uses the same preservation path.

Verification: 37 focused notes/watcher tests passed, then 524 SigilKit tests
passed in 27.995 seconds. An inverted conflict condition made the preservation
regression fail; the source was restored. Strict Swift formatting and diff checks
passed. CI results are recorded in the PR. Tests use a throwaway home and temporary notes. SigilAppTests and hosted UI run only in CI;
no local UI smoke, daily-app replacement, personal notes or provider transcripts.
The first CI run executed 1,001 Swift tests and caught one regression: deleting
an unread note adopted a shared flat note. The panel binding test passed. Two
new SigilKit fixtures reproduced deletion/edit adoption before the repair;
adoption now remains read-only, as before. The repaired 526 SigilKit tests passed
in 29.098 seconds. The next exact-head CI result is recorded in the PR.
The notes contract and limits are in [provider capabilities](../provider-capabilities.md#conversation-notes).

## Mission status

| ID | State | Evidence or boundary |
|---|---|---|
| M0 | Done on branch `claude/sigil-native-workbench-88a27e` | [M0 record](#m0-contract-baseline-and-reference-slice) |
| M1 | Next. Not started. | Live projection from `AppModel` behind a setting that defaults off. See [next dependency](#next-dependency). |
| M2 | Not started | Needs M1. Navigation consolidation. |
| M3 | Not started | Needs M1. Live review and a checks-source spec. |
| M4 | Not started | Needs M3. Finish and worktree removal. |
| M5 | Not started | Needs M1. Phone addresses tasks. |
| M6 | Not started | Independent. Per-provider transcript decision records. |

Scope, write ownership and done criteria for M1–M6 are in the
[missions table](EXPERIENCE.md#missions).

## M0: contract, baseline and reference slice

Base revision `2885af2`. Commits on the branch:
`d857727` (contract and pure models), `369c6e6` (reference slice), `042a061`
(this ledger, the harness, the evidence and the precedence notes), and
`310123f` (self-review fix: a stopped fixture process can no longer overwrite
its task's next state). PR: https://github.com/gl11tchy-team/sigil/pull/130.

### What changed

| Area | Files |
|---|---|
| Contract | `docs/ux/EXPERIENCE.md`; precedence notes in `PRODUCT.md`, `DESIGN.md`; mission rules pointer in `AGENTS.md` |
| Pure models (SigilKit) | `Sources/SigilKit/Workbench/WorkbenchModel.swift` (project, workspace, task, process, conversation, attention), `WorkbenchRail.swift` (stable order, Needs-you filter, moves), `WorkbenchColumns.swift` (terminal-first column layout), `WorkspaceChanges.swift` (lock-free, bounded Git change reader) |
| Views (SigilApp) | `Sources/SigilApp/Workbench/WorkbenchStore.swift`, `WorkbenchView.swift`, `TaskRail.swift`, `ContextHeader.swift`, `ReviewRegion.swift`, `WorkbenchControls.swift` |
| Debug-only fixtures | `Sources/SigilApp/Workbench/WorkbenchFixture.swift`, `WorkbenchReferenceRoot.swift` (both wholly inside `#if DEBUG`) |
| Reuse | `RootView.swift`: `WorkingLabel`, `ExitedCapsule` and `WindowChrome` became internal so the workbench reuses them; `ExitedCapsule` gained a close title (default unchanged, "Close Tab"); a `#if DEBUG` branch shows the fixture when `SIGIL_WORKBENCH_FIXTURE` is set |
| Tests | `Tests/SigilKitTests/WorkbenchModelTests.swift`, `WorkspaceChangesTests.swift`, `WorkbenchFixtureGateTests.swift` |
| Harness | `Scripts/workbench/` (build, launch, snap, ax, matrix; Swift helpers in `tools/`) |
| Evidence | `docs/ux/baseline/` (before), `docs/ux/slice/` (after) |

### Checks run

| Command | Result |
|---|---|
| `swift test --filter 'WorkbenchFixtureGateTests\|WorkbenchModelTests\|WorkbenchColumnsTests\|WorkspaceChangesTests'` | 26 tests in 4 suites passed |
| Gate mutation: a temporary `Sources/SigilApp/Workbench/GateProbe.swift` naming `SIGIL_WORKBENCH_PROBE` outside `#if DEBUG` | `onlyDebugCodeNamesTheFixtures` failed as intended; probe removed |
| `swift build -c release --product Sigil`, then `strings` on the binary | Built. 0 matches for `SIGIL_WORKBENCH`, `fixture transcript`, `WorkbenchFixture`. The debug binary has them. |
| `swift build --product Sigil` | Built with no warnings in workbench files |
| `shellcheck -x Scripts/workbench/*.sh` | Passed |
| `Scripts/workbench/build.sh`, then `matrix.sh` | 24 captures, below |
| Integrated gate | The PR's CI runs the full suite, including `SigilAppTests`, on the runners. `SigilAppTests` are not run locally because they open windows on the owner's screen. Result: see the PR. |

### The reference slice, captured

Real debug build (`SigilWB`, `com.gl11tchy.sigil.workbench`) in an isolated
home, launched from an empty environment. Each fixture builds temporary Git
repositories and fake CLIs; the terminals are real PTYs running those CLIs.
Narrow is 900×620 pt; wide is 1512×949 pt, the largest window this display
allows. Every image below was opened and inspected.

| Fixture | Narrow dark | Narrow light | Wide dark | Wide light |
|---|---|---|---|---|
| empty (no projects) | [img](slice/empty-narrow-dark.png) | [img](slice/empty-narrow-light.png) | [img](slice/empty-wide-dark.png) | [img](slice/empty-wide-light.png) |
| no-tasks | [img](slice/no-tasks-narrow-dark.png) | [img](slice/no-tasks-narrow-light.png) | [img](slice/no-tasks-wide-dark.png) | [img](slice/no-tasks-wide-light.png) |
| one task | [img](slice/one-narrow-dark.png) | [img](slice/one-narrow-light.png) | [img](slice/one-wide-dark.png) | [img](slice/one-wide-light.png) |
| busy, three projects | [img](slice/busy-narrow-dark.png) | [img](slice/busy-narrow-light.png) | [img](slice/busy-wide-dark.png) | [img](slice/busy-wide-light.png) |
| provider unavailable | [img](slice/unavailable-narrow-dark.png) | [img](slice/unavailable-narrow-light.png) | [img](slice/unavailable-wide-dark.png) | [img](slice/unavailable-wide-light.png) |
| error (exit 1, missing folder) | [img](slice/error-narrow-dark.png) | [img](slice/error-narrow-light.png) | [img](slice/error-wide-dark.png) | [img](slice/error-wide-light.png) |

Interactions, driven by AX presses in the running app (no keystrokes):

| Step | Observed |
|---|---|
| Press a finished task's row | It became selected; its state changed from Finished to Idle; Needs you went from 3 to 2. [img](slice/interaction-1-selected-finished-task.png) |
| Press Needs you | Only the three tasks needing the user remained, in the same order. [img](slice/interaction-5-needs-you-review-hidden.png) |
| Press Restart on the task that exited 1 | Its fake CLI ran again and exited 1 again; the state stayed "Exited with code 1". The failure is real, so a restart does not hide it. |
| Press a history-only task, then Resume | "Not running" panel with Resume ([img](slice/interaction-2-not-running.png)); after Resume a live Claude Code terminal and "Status unknown", not "Working" ([img](slice/interaction-3-resumed.png)) |
| Press New Task in infra | A new live task in `infra`, selected; its review shows infra's real changes. [img](slice/interaction-4-new-task.png) |
| Press Hide Review, then Review | The review region closed and reopened. |
| Narrow window: press Review, then Show Tasks | Review took the rail's room ([img](slice/interaction-6-narrow-review-over-rail.png)); Show Tasks brought the rail back and closed review ([img](slice/interaction-7-narrow-rail-back.png)) |
| Error fixture: press Dismiss, then Resume | "Not running" with Resume; Resume ran the failing CLI again and it exited 1 again. |
| Error fixture: press the task whose worktree was deleted | "Workspace folder is missing" with the path; Changes says there is nothing to read. [img](slice/interaction-8-workspace-missing.png) |

The AX dump names every control: rows read "title, state, provider,
workspace", section headers are headings, and the file rows read their status
and counts.

### Review fixes on PR 130

Three review findings, each reproduced before its fix.

| Finding | Reproduction before the fix | Fix | Proof after |
|---|---|---|---|
| Git timeout did not cover the pipe drain | A fake Git that starts `sleep 10 &`, prints, and exits 0: a 1 s deadline returned after 10.19 s with success; the whole read took 60.2 s and returned changes | `GitOutput.run` reads both pipes non-blocking on its own thread until one deadline for the exit and the drain; a miss returns failure, kills a Git still running, and closes the read ends | `WorkspaceChangesTests`: inherited pipes after exit 0, a Git that outlives the deadline, a Git that never stops writing, a Git read in full. Each fake Git records its pids and the test kills them |
| New tasks did not get keyboard focus | AX focused element in `SigilWB` (busy fixture) was the window after launch, New Task, Resume and Restart. Pressing an already mounted task's row did focus. [img](slice/focus-0-before-new-task.png) (hollow caret) | `WorkbenchStore.select` focuses at once when the terminal is in a window, else remembers the task; `TerminalPane`'s `onWindowAttachment` calls `terminalDidAttach`, which focuses only the still-selected task that asked. Arrow keys select without focus and cancel a pending one | AX focused element was the selected task's own terminal, read by its text, after launch ([img](slice/focus-1-launch.png)), New Task ([img](slice/focus-2-new-task.png)), Resume ([img](slice/focus-3-resume.png)) and Restart ([img](slice/focus-4-restart.png)). `WorkbenchFocusTests` covers the four paths and arrow keys; it runs in CI |
| A staged rename lost its deleted lines | `old.txt` (3 lines) committed, `git mv old.txt new.txt`, 4 new lines: Git +4 −3, reader +4 −0. A file removed from the index but kept on disk also counted its deletion twice | Each numstat count goes to one entry: its own path, or a rename's old path when no tracked entry owns it; untracked entries take none | `WorkspaceChangesTests`: the reproduction, and a mixed repository whose totals equal Git's. In the running app, `git mv README.md NOTES.md` with new text showed Renamed NOTES.md +2 −1 and totals +5 −7, as Git counted. [img](slice/review-rename-counts.png) |

`ax.sh <pid> focused` prints the focused element's role, label and the start
of its text; the text tells two terminals with the same label apart.

### Two defects found during the PR 130 review fixes

| Defect | Reproduction before the fix | Fix | Proof after |
|---|---|---|---|
| A hidden terminal kept the keyboard | Busy fixture: New Task in infra, then the Bump Node to 22 row (Not running). The AX focused element stayed the new task's Grok Build terminal, mounted at opacity 0 | Selecting a task without a terminal takes the keyboard from any terminal that holds it and gives it to the rail, where ↑ and ↓ work. With the rail hidden, the window keeps it | AX focused element was the rail's list inside the Tasks group after Bump Node, again after a live row and Bump Node, and after ↓ and ↑ (sent to the test app's pid only), which moved the selection. [img](slice/focus-5-no-terminal.png). `WorkbenchFocusTests` covers the rail and the hidden rail; it runs in CI |
| Two review rows had one ID | `git rm --cached kept.txt` makes Git list `D  kept.txt` and `?? kept.txt`; both rows had the ID `kept.txt` | A row's ID is its path and whether it is the untracked side. Counts are unchanged; the untracked row takes none | `WorkspaceChangesTests`: a real repository gives two rows with distinct IDs, the same IDs on a second read, and Git's totals. In the running app, `git rm --cached main.tf` in infra showed Deleted main.tf +0 −16 and Untracked main.tf, totals +2 −16 as Git counted. [img](slice/review-rm-cached.png) |

### A work-tree rename read as a second file

| Defect | Reproduction before the fix | Fix | Proof after |
|---|---|---|---|
| The reader took a rename's old path only when the index column (X) said `R` or `C`. Git also reports a rename in the work-tree column (Y) when the new path is intent-to-add, and a copy there with `status.renames=copies` | Git 2.54: commit `ab/x.txt` (4 lines) and `x.txt`; `mv ab/x.txt new.txt`; `git add -N new.txt`; edit `x.txt`. `git status --porcelain=v1 -z --untracked-files=all` printed ` R new.txt\0ab/x.txt\0 M x.txt\0`. The reader read `ab/x.txt` as its own entry: status from `a`,`b`, path `x.txt`. Rows: Modified new.txt, Modified x.txt twice (one ID for two rows), totals +2 −0 against Git's +1 −0. `old_name.txt` → `new_name.txt` gave a false Modified `_name.txt` | `parseStatus` takes the old-path field when X or Y is `R` or `C`. `status(x:y:)` names the entry Renamed or Copied from either column. `join` is unchanged: the new path takes its own count, and the old path's count only when no tracked entry owns it. A work-tree rename of a path with staged changes also lists that path (`M  a.txt\0 R c.txt\0a.txt\0`); that entry keeps its own count, so no line is counted twice | `WorkspaceChangesTests`: a parse case (` R`, a staged rename followed by a work-tree rename, ` C`), the reproduction in a real repository (rows, distinct IDs, Git's totals), and a staged change then a work-tree rename where numstat does not pair the files (Git +5 −6, reader +5 −6). The three failed before the fix with the phantom `x.txt`, `_name.txt` and `xt` rows. In the running app (`SigilWBRename`, busy fixture), the same steps in infra showed Modified main.tf +1 −6, Renamed new.txt +0 −0, Added state/split.tf +2 −0, Modified x.txt +1 −0, totals +4 −6, as Git counted. [img](slice/review-worktree-rename.png) |

| Command | Result |
|---|---|
| `swift test --filter WorkspaceChangesTests`, before the fix | 18 tests; the 3 new ones failed as above |
| `swift test --filter WorkspaceChangesTests`, after the fix | 18 tests passed |
| `swift-format lint` on the two changed files | No findings |

### An intent-to-add file read as Modified, and paths that start with a combining mark

Found in the stand-in review of PR 135. The shell reproductions ran Homebrew
Git 2.54. The app and the tests run `/usr/bin/git` 2.50.1 (Apple Git-155); the
tests assert the same status output from it.

| Defect | Reproduction before the fix | Fix | Proof after |
|---|---|---|---|
| `status(x:y:)` named an entry Added only when X was `A`. A lone intent-to-add file is ` A` | Commit `a.txt`; write `new.txt` (3 lines); `git add -N new.txt`. Status printed ` A new.txt\0`; `git diff HEAD --numstat -M` printed `3 0 new.txt`. The reader showed Modified new.txt +3 −0 | Outside a conflict (`AA` and `UA` are caught first), Y is `A` only for an intent-to-add path. ` A` is Added. `DA` is Modified: `git rm --cached f.txt`, `git add -N f.txt` and one added line print `DA f.txt\0` and numstat `1 0 f.txt`, because HEAD still has the file. The first version of this fix named `DA` Added; the stand-in review of PR 137 found it. The numstat join is unchanged, so totals still equal Git's | `WorkspaceChangesTests`: a parse case (` A`, `A `, `UA`, `DA`); ` A` in a real repository (Added +3 −0, Git's totals); `DA` in a real repository (Modified +1 −0, Git's totals); ` A` before the first commit (Added +3 −0). The ` A` cases failed before the fix with Modified. The `DA` cases failed on the first version with Added. The no-commit case passed on both, as a guard |
| `parseStatus` read X, Y and the path as `Character`s. The separator space and a leading combining mark (U+0301) form one grapheme | Commit `ab.txt` and `\u{301}x.txt`; `mv ab.txt \u{301}`; `git add -N \u{301}`; edit `\u{301}x.txt`; write `\u{301}u.txt`. Status printed ` R \u{301}\0ab.txt\0 M \u{301}x.txt\0?? \u{301}u.txt\0`. ` R \u{301}` had three Characters and was skipped, so `ab.txt` was read as its own entry: status from `a`,`b`, path `txt`. The other two lost the mark: Modified `x.txt`, Untracked `u.txt`. No row matched a numstat path, so the totals were +0 −0 against Git's +1 −0 | `parseStatus` splits the output as bytes and reads X and Y from bytes 0 and 1, and the path from byte 3 on as UTF-8. `parseNumstat` is unchanged: its separator is a tab, a control character, which Unicode never joins with a following mark | `WorkspaceChangesTests`: a parse case (` R`, ` M`, `??` with the mark, then a plain entry) and the reproduction in a real repository (Renamed `\u{301}` from `ab.txt` +0 −0, Modified `\u{301}x.txt` +1 −0, Untracked `\u{301}u.txt`, distinct IDs, Git's totals). Both failed before the fix with the `txt`, `x.txt` and `u.txt` rows |

In the running app (`SigilWBIntent`, busy fixture), in infra: `git add -N` of a
new 3-line `notes.txt`, `README.md` moved to `\u{301}` and `git add -N`, and an
untracked `\u{301}x.txt`. Review showed Modified main.tf +1 −6, Added notes.txt
+3 −0, Added state/split.tf +2 −0, Renamed `\u{301}` +0 −0, Untracked
`\u{301}x.txt`, totals +6 −6, as Git counted. [img](slice/review-intent-to-add.png)

| Command | Result |
|---|---|
| `swift test --filter WorkspaceChangesTests`, before the fix | 22 tests; the 4 new ones failed as above |
| `swift test --filter WorkspaceChangesTests`, after the first fix | 22 tests passed |
| `swift test --filter WorkspaceChangesTests`, `DA` tests added to the first fix | 24 tests; the `DA` parse case and the `DA` repository test failed with Added |
| `swift test --filter WorkspaceChangesTests`, after the `DA` fix | 24 tests passed |
| `swift-format lint` on the two changed files | No findings |

### A SHA-256 repository with no commit failed to read

Found in the stand-in review of PR 137.

| Defect | Reproduction before the fix | Fix | Proof after |
|---|---|---|---|
| With no commit, the reader diffed against a hard-coded empty tree, `4b825dc6…`. That is the SHA-1 name; a SHA-256 repository does not know it, so every SHA-256 repository with no commit read as `.failed` | Git 2.50.1: `git init --object-format=sha256`; write `f.txt` (2 lines); `git add f.txt`. `git diff 4b825dc642cb6eb9a060e54bf8d69288fbee4904 --numstat` exited 128 with `fatal: ambiguous argument '4b825dc6…': unknown revision or path not in the working tree.` In the same repository `git hash-object -t tree /dev/null` printed `6ef19b41…5321`, and a diff against it printed `2 0 f.txt` | With no commit, `readNow` asks Git for the empty tree with `git hash-object -t tree /dev/null` in the repository, so the name is in the repository's own object format. It runs through `GitOutput.run` with the same timeout. No answer, a non-zero exit or a blank name fails the read; there is no SHA-1 fallback. The constant is gone | `WorkspaceChangesTests.readsASHA256RepositoryWithNoCommitYet`: a SHA-256 repository with no commit and one staged 2-line file gives one row, Added first.txt +2 −0, head `trunk`. It failed before the fix with the `ambiguous argument` error. `aGitThatCannotNameTheEmptyTreeFailsTheRead`: a fake Git whose `hash-object` fails gives `.failed` with Git's message, so no guessed empty tree comes back. The SHA-1 no-commit test now sets `--object-format=sha1`, so a Git that defaults to SHA-256 cannot turn it into a second SHA-256 test (stand-in review nits on PR 138) |

| Command | Result |
|---|---|
| `swift test --filter WorkspaceChangesTests`, before the fix | 20 tests; the 2 new ones failed as above (the fake-Git test got a diff exit instead of Git's message) |
| `swift test --filter WorkspaceChangesTests`, after the fix | 20 tests passed |
| `swift test --filter WorkspaceChangesTests`, after merging main with PR 137 | 26 tests passed |
| `swift-format lint` on the two changed files | No findings |

### Journeys: baseline and slice

The baseline is [baseline/BASELINE.md](baseline/BASELINE.md) (app at `2885af2`,
real screenshots, counted actions, friction). The slice column counts presses
in the fixture build, so it shows the layout's cost, not yet the live app's.

| Journey | Baseline (actions) | Slice (actions) | What changed |
|---|---|---|---|
| Start a task in a project | 5 from a drilled-in project; 6 from Home, where the sheet opened on a different project | 1 (the project's plus) to a running task, then type | The project is the rail section you press in. M1 routes this plus to the existing New Session sheet, which adds its provider and worktree choices. |
| Switch between tasks in two projects | 1–3, depending on strip overflow, drill-in, or tab list | 1 | Every task is always in the rail; no drill-in, no overflow, stable order. |
| Find what needs attention | 0 to see unlabelled dots; 1 (tab list) for words, which called an unread finish "Idle" | 0 to see the count; 1 (Needs you) for the list | States have words in the header, the review facts and AX labels. |
| Review changes and checks | 6 (open panel, type `git status`, `git diff` in a shell) | 0 at wide sizes (review is open), 1 at narrow | Real per-workspace Git changes with branch and counts; checks explicitly "Not connected". |
| Return from the phone | 2 after pairing; 7 or more the first time | Unchanged | M5. The phone still addresses tabs, not tasks. |

### Decisions made in M0

- Only Project → Task is navigation. Workspace, process and conversation are
  facts in the header and review region.
- The rail never reorders on activity. The baseline recorded Projects
  re-sorting between two captures; the slice keeps creation order.
- Space priority is terminal, then review, then rail. A review region open only
  by default gives way to the rail on narrow windows; one the user opened takes
  the rail's room. (First capture showed the default review hiding the rail at
  900 pt; changed and tested in `aDefaultReviewGivesWayToTheRail`.)
- Workbench controls are typed as a real action or an unavailable reason
  (`WorkbenchAction`), so a decorative control cannot be written.
- The fixture's Check Again looks only in the fixture's own `bin` folder, so
  a fixture never runs a CLI installed on this Mac.
- An empty state may repeat the one step it teaches; the empty rail no longer
  carries a second Add Project button (found in the first capture).
- The reused ended-session card says Dismiss in the workbench: the task stays,
  only the ended process goes.

### Unresolved limits

- The slice runs on fixtures in debug builds. No live `AppModel` data reaches
  it yet (M1).
- Fixture states other than the process exit are asserted by the fixture
  (working, needs input, finished). The exit-with-code-1 and missing-folder
  states come through the real paths.
- Rail ↑/↓ and Return are unit-tested (`WorkbenchRail.move`, and
  `WorkbenchFocusTests` for focus) but not driven in the running app, because
  the harness sends no keystrokes. For the PR 130 focus fix, setting AX focus on
  the rail had no effect, so arrow events posted to the `SigilWB` pid only
  reached its focused fixture terminal. ⌘1…⌘9 and Next Needing Attention are
  not in the menus yet (M2).
- Selecting a task with no live terminal leaves keyboard focus on the terminal
  that had it, now hidden. Unchanged by the PR 130 fixes.
- Checks have no source (M3). Finish is unavailable (M4). The phone is
  unchanged (M5).
- VoiceOver speech was not run; the AX tree was read instead.
- In fixture mode the menu bar still belongs to the hidden tab window's model,
  so its commands do nothing useful there. M1 gives the workbench the menus.
- Wide captures stop at 1512×949 pt, the display's visible frame.
- The native iPhone app was not run for the baseline; the phone column uses
  the Sidereal web companion.
- Baseline capture incident (recorded in BASELINE.md): one launch inherited the
  worker's `PATH`, so Sigil's provider check ran the owner's installed CLIs with
  `--version`. No session or model call happened and no binary changed;
  `cursor-agent` left an empty `.running` folder in its own version folder.
  Both harnesses now launch from an empty environment.

### Next dependency

M1 needs a task identity for the live app. `OpenTabsSnapshot.Entry`
(provider, conversation ID, folder) identifies a verified conversation, but a
new Codex tab has no ID until its history is matched. M1 must first give each
task a Sigil-owned ID stored in the ledger, map tabs and ledger conversations
onto it, then feed `WorkbenchStore` from `AppModel` with `WorkbenchActions`
wired to the existing New Session sheet, `restartTab`, `closeTab`,
`refreshProviderInstallations` and `open(_:)`.

## Resume

### REA-1216 — Codex tab identity (2026-10-09)

- Reproduced both defects with the unchanged `recordStartedCodexSessions`
  method extracted into a synthetic Swift harness: a same-folder outside
  writer was adopted, and reversed first use swapped two tabs' conversations.
  This was a selector reproduction, not an AppModel/UI runtime test.
- Replaced folder/time automatic adoption with scoped child-generation and
  exact held-rollout evidence. Device/inode and fresh native metadata must
  agree. Before/after process, descendant and file observations must agree;
  missing/denied evidence and multiple held files remain unbound.
- Added an explicit **Link Conversation…** choice to the shipping Session
  actions menu. The click revalidates the history envelope and target tab;
  unknown-ID Restart behavior and lifecycle-journal boundaries are retained.
- A generated own-child C probe passed `proc_pidinfo`, `proc_listchildpids`
  and `proc_pidfdinfo` under existing permissions. The libproc Swift code
  type-checked against the installed SDK. No personal history or real CLI
  prompt was read/run; no entitlements changed.
- Local focused `swift test --no-parallel --jobs 2 --filter
  ProcessOpenFilesTests` stopped before tests at `sandbox-exec: sandbox_apply:
  Operation not permitted`. Static module compilation reached the same nested
  sandbox restriction in the Observation macro host. Neither gate was retried
  with broader permissions. Regression execution and integrated verification
  are required in CI; no local AppModel test, hosted UI smoke, installation or
  release was run. The previous process-inventory denial remains untouched.
- Tests cover scoped outside writers, reversed first use, same-folder tabs,
  shims/descendants, reused/reparented/new descendants, old writable files,
  initial and later `/new` ambiguity,
  replaced/stale envelopes, explicit linking and closed tabs. Limits: this is
  bounded kernel file evidence, not a documented Codex active-session API or
  proof of turn completion. Actual authenticated Codex behavior is untested.
- Automatic review identified a PID-count/byte-count mistake in the child-list
  wrapper. Verified Apple's libproc implementation, corrected the count and
  full-buffer guard, and added a four-child ambiguity regression alongside the
  existing one-child shim test. Final-head runtime results are tracked in the PR.

```bash
Scripts/workbench/build.sh
Scripts/workbench/matrix.sh docs/ux/slice
```

`launch.sh <fixture> <dark|light> <WxH>` prints a pid; `ax.sh <pid> dump` and
`ax.sh <pid> press <label>` read and press controls; `snap.sh <out.png>`
captures the window; `kill <pid>` quits. The scripts refuse to act on any
process that is not the renamed bundle.

## REA-1223 — inline launch and bounded provider checks

New Session / ⌘T now opens the empty terminal's inline provider surface. One
click starts with existing defaults; Options remains secondary. The owner's
October 10 clarification is reflected in monochrome glyphs impressed into the
actual terminal ground, with restrained inset depth and clearer focus/hover.
Successful checks are reused for five minutes; required replacement checks
still gate their provider, and restoration retains saved order. Blocking
version detection runs on dispatch threads.

Native synthetic receipts, screenshots, validation and limits are recorded in
[REA-1223 evidence](rea-1223/EVIDENCE.md). AppTests run only in ordinary PR CI.
The earlier modal-entry audit above is retained as historical evidence.
REA-1250, REA-1261 and REA-1225 retain the independent work listed in that receipt.
Parent reviews final code and native screenshots before merge.

Parent review approved the initial dark/light provider impressions. The
follow-up remediation starts or joins required checks from remote launches and
Options, preserving cancellation, current generations and existing terminals.
It also addresses the first PR CI run's cancel/startup focus failures without
changing the glyph treatment. Updated coverage and remaining CI/native limits
are recorded in the same evidence file; parent code re-review is pending.

## REA-1246 — stamped Site and Sidereal uploads

Site health now exposes the shared source revision contract. Both deployment
wrappers require verified source, explicit target identities and an existing
health destination, stage from a common manifest contract, upload once, then wait
up to five minutes for the exact commit and source hash. A matching stamp proves
source identity; it does not establish operational health.

[REA-1246 evidence](rea-1246/EVIDENCE.md) records generated fake-CLI and loopback
fixtures, the baseline failure, verification and limits. No production deploy or
native application change ran. REA-1248 owns future CI deployment wiring. Parent
reviews the final code and exact-head CI before any merge.

The parent review follow-up corrects both existing production runbook commands
and adds a bounded comparison of runtime file names and bytes across staging.
Generated races now refuse upload while unchanged dirty inputs remain allowed.
The evidence records the six baseline failures, eight focused passes, complete
Node suites and the limits of these reads; no transactional snapshot is claimed.

## REA-1249 — Archive and Pin keyboard commands

File-menu ⌃⌘A/⌃⌘P now resolve the focused sidebar selection or row, otherwise
the selected tab's known conversation. Directional bulk actions reuse existing
archive/pin and working-session confirmation. A removed range keeps the next
surviving highlight, and a list archive keeps focus when closing the open tab.
Focused regression coverage compiles; AppTests execute only in PR CI.

**Blocked native acceptance:** the isolated renamed app's AX window tree did
not expose usable sidebar controls, and both window-ID screenshot methods
failed. Bounded alternatives stopped without claiming keyboard bulk archive
or final-head native success. Details, local checks and remaining acceptance
are in [REA-1249 evidence](rea-1249/EVIDENCE.md). Parent code review and native
evidence are required before merge; no app replacement occurred.

The continued renamed fixture evidence is now accepted by the parent, with
external OS keyboard delivery and a complete physical IME workflow retained
as limits. Two exact-head CI attempts stopped at the same buffered Settings
start and exceeded the existing 45-minute deadline; no root cause is proven.
The only current-main merge conflict was this ledger's appended entries, both
preserved above. At that review checkpoint, the PR145-only diagnostic wrapper
was staged locally, uncommitted and unpushed. It preserves Verify, samples one verified
owned test PID twice after three minutes without progress, bounds artifacts,
and records unavailable sampling without changing the test result. No further
CI run, local AppTests, merge or daily-app action occurred at that checkpoint.

The parent personally approved the complete diagnostic/conflict patch in
review package v3. The follow-up commit records that resolution and includes
the existing, reviewed synthetic three-row selection and Archive-survivor
screenshots, linked from the evidence above. One ordinary PR145 run from one
push is authorized after confirming Sigil CI is idle. Final parent review and
required exact-head CI remain prerequisites to a PR merge; no local AppTests
or daily-app replacement was performed.

## REA-1329 — use installed Grok by default

Generated executables reproduced main selecting a stale separate themed copy
ahead of current host Grok. Automatic discovery now follows login-shell `grok`
and launches its checked path; themed/custom executables are explicit choices.
Known unchosen legacy defaults migrate, while explicit and other custom choices
survive. Grok Settings shows the selection/path/version/problem and offers
Use Installed Grok and Check Again recovery. Cache generations and the ordinary
one-click New Session entry remain in force.

The native production-source probe passed 16 checks. The isolated Kit SwiftPM
attempt was denied at manifest startup, with no tests run or permission bypass.
App tests are CI-only; native Settings AX/screenshots remain unavailable through
the blocked local build route. See [REA-1329 evidence](rea-1329/EVIDENCE.md) for
the migration/recovery journey and evidence limits. Ordinary exact-head CI and
parent personal review precede merge; no worker merge or app installation.

## REA-1250 — recover timed-out provider checks

The shared ProviderChecks engine now distinguishes deadline timeouts from
missing/invalid CLIs and uses one timer for three retries with 5/15/45-second
delays. One activation can advance an attempt without resetting the budget.
Exhaustion says Version check timed out and offers Check Again. Current results
restore the saved prefix in order, retain deferred positions/selection, and
support manual recovery after exhaustion without duplicate tabs.

[Evidence](../qa/rea-1250.md) records the source-base synthetic reproduction
(two assertions), eight changed-source Kit assertions, local syntax/strict
format/whitespace checks, injected scheduler/probe CI regressions, and limits.
SigilAppTests remain CI-only; the local SwiftPM denial was not retried or
bypassed. No personal histories/prompts, local native UI smoke or app installation.
Ordinary exact-head CI evidence is recorded in the ticket PR for parent review.

PR148 review found lost saved rank on tab replacement, routine replenishment of
exhausted retry budgets, activation tied to the main view, and direct-PID timeout
cleanup leaving children. Remediation transfers rank in replacement construction,
preserves exhaustion during ordinary entry/remote Options, uses the app-wide
delegate model hook, and adds bounded identity-fenced descendant cleanup.
Synthetic processes reproduced the original orphan and a separate-group child;
the cleanup does not scan arguments/files or unrelated processes. Updated
regressions include restarted peers, exhausted entry/options, Settings-only
activation and synchronous/asynchronous child cleanup. Final evidence stays in
the PR; parent reviews the revised exact diff. No merge, install or next ticket.

## REA-1266: long Claude transcript titles

The isolated scanner candidate reads complete Claude JSONL records with bounded
chunks and retains the newest explicit rename across append rescans. Empty names
reset to the first prompt. Changed files validate the entire old-prefix fingerprint
in bounded cancellable reads before reusing parse state; this deliberately costs
old-byte I/O while parsing only appended records. Replacement, truncation, rewrites
and read races invalidate or preserve earlier evidence. Unchanged files remain
zero-read cache hits. Caller cancellation reaches detached production work and
cannot publish a canceled scan. Partial JSON/UTF-8 and oversized records retain
bounded state and incomplete-history protection. Codex indexing and parked PR150's
provider UI are separate.

[The verification record](../qa/rea-1266.md) preserves the failed sampled-anchor
candidate and the parent's explicit full-prefix revalidation decision. Revised
production-source cases include the unanchored growth rewrite; the real detached
store cancellation cases remain CI-only. The parent reviews final code and ordinary
exact-head CI. No personal transcript, live CLI
incident, local AppTests, native UI screenshot, merge or daily-app action is claimed.

## REA-1268: selective native-history parsing and title-index reuse

Conservative record selection leaves metadata validation authoritative, including
escaped keys and late conflicting identities. The Codex index uses a store-scoped
cache with full snapshot identity, complete retained-window fingerprint validation,
bounded record carry and window eviction. Missing/evicted index titles restore
transcript titles. Claude's full old-prefix validation, cancellation and publication
ordering remain in place; watcher redesign and REA-1270's disk cache are separate.

[The verification record](../qa/rea-1268.md) records generated baseline/candidate
performance, differential and failure fixtures, local direct production-source
validation and its limits. Existing scanner/watcher methods remain unchanged.
Observation-backed store tests and AppTests run in ordinary exact-head CI. Parent
personal review precedes any merge; no personal history, local UI, daily-app action
or customer impact is claimed.


## REA-1270: private saved history display index

The default store publishes a bounded private display index before its first scan,
including Codex title metadata so unchanged scans read no history bodies. Saved rows
cannot supply launch, Trash, housekeeping or identity-adoption authority. Individual
actions and saved tabs share one delayed source-validation pass after the first
stat-only scan. Valid ordinary launches resume housekeeping and legacy-note migration
automatically. Unchanged failed envelopes remain display-only without restoration
retry loops; forced scans coordinate with waiting actions. The established Codex
process/file binding proof remains independent.

[The verification record](../qa/rea-1270.md) records the generated launch-cache gap,
private atomic-write and untrusted-input failures, measured publication work and its
limits. Local validation uses complete non-Observation production dependencies and
Address Sanitizer. Store and app regressions run in ordinary CI; no personal history,
local AppTests, UI smoke, daily-app replacement or customer impact is claimed.
Parent personal review of the exact final diff precedes any merge. One worker and
one ticket remain in flight.

REA-1270 remediation: initial CI at `7a59188` exposed /var versus /private/var
cache/file URL identity failures and a fixture encoded cwd without the CLI realpath
rule. The revision keeps standardized cache keys and strict no-follow checks,
recognizes only OS system aliases, and corrects the fixture cwd. All five automated
review findings were traced to callers and addressed: failed restoration retries,
remote-open await, Grok identifier compatibility, repeated saved-tab traversals and
forced-scan coordination. Direct ASan index checks include generated /tmp alias and
non-UUID Grok cases; store/app behavior remains CI-only. No merge or app replacement.

Follow-up exact-head CI reduced 42 failures to 11. Closed-source deletion exposed
existence-dependent Foundation path standardization; generated /tmp and /var cases
reproduced it and now pass with stable expansion of only OS aliases. The automatic
launch fixture now calls the real onAppear lifecycle to install its housekeeping
observer. All original success/count/identity assertions remain intact.

## REA-1267: cached history refresh and deliberate recovery

Reload now reuses unchanged native transcript/title-index metadata while retaining
Grok Cmd-R summary rereads. All Trash paths request cached refresh, preserving the
existing queued scan sequencing. Saved display rows still require source parsing;
Retry and View > Rebuild Conversation History retain deliberate full recovery,
including unchanged retained failures and stale cache rows.

[The verification record](../qa/rea-1267.md) records the generated main five-read
reproduction and eight passing permitted direct Swift/ASan scanner checks. Store
sequencing and app deletion tests await ordinary exact-head CI at PR creation.
Existing local build/process denials remain respected. No personal history,
additional worker/ticket, local AppTests, daily-app replacement or customer timing
claim. Parent personal review precedes merge.

## REA-1255: reuse sidebar snapshots during hover and navigation

Equal visibility inputs now share a one-second snapshot across renders and
keyboard events. All filter/membership and mutable tab-identity keys are included;
tab activity remains independently observed by rows. A view-owned passive
filesystem stream schedules quiet invalidation and stops with the sidebar.
Unchanged watched views do no periodic full-list rebuild; unsupported streams
retain bounded fallback refresh. Saved history and project authority are preserved.

[The verification record](../qa/rea-1255.md) defines the generated 1,000-session,
20-row callback sweep and its limits. Baseline app-host CI began before changing
production behavior; the PR carries measured timings and exact-head CI evidence. Local
pure watcher type-check/ASan policy checks pass; local stream delivery is unavailable.
No customer history, local AppTests, daily-app replacement or merge. One ticket
and worker remain active, with parent personal review before merge.

The first baseline run passed 1,172 Swift tests but exposed a read-only SwiftUI
environment override in the new harness; the corrected fixture records the host's
actual setting. Automatic review also identified the existing render-count
regression, watch-path rebuilding on hover and partial-watch coverage. The focused
repair reuses the watch-path set, reconciles startup/remount, preserves scheduled
fallback for partial plans and updates the original assertion without weakening
its row-order contract. No additional implementation worker or ticket was opened.

Runtime CI then exposed lexical versus canonical project-ID assertions and a quiet
watcher event mismatch. A generated local path probe confirmed Foundation retains
`/var` while POSIX resolves `/private/var`; sidebar watches resolve the existing
ancestor with POSIX before restoring a missing suffix. Assertions compare canonical
project identities; the quiet event, idle-build and cancellation requirements remain
unchanged. Final runtime evidence remains pending the repaired exact-head CI.

The next CI passed every SidebarSnapshot test, including actual quiet events,
idle reuse, fallback and cancellation. It also exposed that the shared history-root
helper established scanner authority identities. The follow-up confines native
POSIX spelling to sidebar watch paths, restores history-root behavior and adds an
assertion preserving the original canonical helper contract. A Git admin-root
expectation now uses the consistently native watch plan. No history/root-loss
assertions were changed or removed.

## REA-1259: word starts and conversation categories in search

A generated main fixture reproduced newer `Climbing` above `Rate limiter` for
`lim`. Search now ranks every term at a folded Unicode word start above contains,
then applies one category within a match rank: open, pinned, focused project,
other. Recency and deterministic provider/native-ID/cwd ties follow. Empty-query
recency, global project search, existing highlights and identity proof remain.
The current snapshot key already includes every category input; app-host tests
check immediate reordered rows after tab identity, pin and project changes.

[The verification record](../qa/rea-1259.md) records passing direct Swift 6/ASan
checks against 17 full production dependencies and the generated baseline.
Store/app validation awaits ordinary exact-head CI at PR creation. No local
AppTests, screenshot, personal histories, daily-app replacement or merge; existing
build/process denials remain respected. REA-1256 receives the shared documented
contract only. One worker and ticket remain active until parent personal review.

The first CI failed at compile time because Swift's forward trailing-closure scan
bound existing title closures to the defaulted boost parameter. The fix retains
the original public search signature and adds a required-label boost overload;
all original callers and assertions stay intact. Real Store/AppTests await the
corrected exact-head run. No denied local build or extra worker was used.

## REA-1350: sidebar divider capture and background dragging

The generated current-main fixture reproduced moving local-coordinate feedback and
competing server-side window dragging. Shared 9-point seams now capture mouse-down
with screen-coordinate NSEvent deltas and immediate reversal at physical width caps.
A no-motion click focuses the seam without replacing a saved width with its rendered
cap. The geometry solver, persisted preference and keyboard/AX steps remain.

The final candidate passed 66 drag samples, target edges, bounds, utility panel,
900/760 widths, hide/show, keyboard/AX adjustment and fresh-process persistence.
Saved 430 rendered 218 survived a stationary click and restored 430 after widening.
Generated terminal selection kept the window stationary. Read-only folder labels
retain dragging with the sidebar hidden; the observed 20-point movement for a
30-point path remains a review limitation. Small native header drag
surfaces moved the window 30 points, including the first drag while inactive. A
SwiftUI window gesture still intercepted terminal mouse-down after being narrowed
and was replaced with the bounded native surfaces.

The [QA record](../qa/rea-1350.md) identifies final source-matched evidence in
`rea-1350-final-review-native/` and the initial CI failure investigation. Nine capture tests stay in serial Swift Testing; four rendered interaction
cases, including Notes selection, now use the existing CI-only SwiftUI app host. The filesystem test
now establishes bounded startup quiet before its unchanged assertions. App-only
build, signature, formatting and diff checks passed. The populated native-history
attempt remained AX-unresponsive and is an explicit Notes verification gap.

CI38202086650 was false green: a recorded seam failure and incomplete Swift
Testing output were hidden by a zero command status. The gate now requires a
complete passing summary and rejects recorded failures; seven synthetic guard
tests passed and the real false-green log is rejected. Exact-head CI and parent
personal diff/native review remain required before merge.
No personal histories, process enumeration, denied process reads, daily-app
replacement, merge or next-ticket work occurred. REA-1351 stays separate.

The 0a94 CI completed all 1,220 Swift tests and 37 XCTest cases, then failed
all four new hosted interactions. Exact xcresult details record posted-event
timestamp rounding, a 32-point coordinate difference, missing seam capture/focus
and empty terminal/Notes selection. The new CI-only driver uses guarded native
pointer input and exact target-window receipts; all behavior assertions remain.
Its result is pending. App source and the preserved Mac evidence are unchanged.

CI38207095514 completed the full Swift/XCTest run, then the four hosted cases
failed before input because their visible windows were not key. The correction
activates once before each complete gesture and requires the exact key window;
there is no reactivation during dragging. The multi-point terminal path also
fixes the source-confirmed missing selection-extension event. App behavior
assertions and app source remain unchanged; the next exact-head run is pending.

On 2026-10-12 at 14:22 UTC the owner explicitly chose manual sidebar verification
and requested unblocking. Only the four named REA-1350 pointer tests now skip with
an explicit reason when event-posting permission is unavailable. Their bodies,
assertions and permission/ownership guards remain. The hosted gate verifies exact
identities and still requires both unrelated fixtures to pass; pointer failures,
partial results and other skips fail. All other CI checks and the completion guard
remain mandatory. Skipped pointer behavior and owner manual verification are not
claimed as passed. No denied input retry, security change, merge or installation.

## REA-1273: Finder folder paths

On isolated branch `fix/rea-1273-finder-folder-paths`, based on main `f0e319a`,
existing directories now use the same standardized absolute-path filter as
files. Control rejection, shell quoting, Finder order, the 16-item cap and
bracketed paste remain. No directory enumeration, content reading, upload or
phone behavior change.

[QA evidence](../qa/rea-1273.md) records test-only CI38325625030: 37 XCTest
cases passed, and 1,225 Swift tests completed with eight expected issues in four
folder-path tests. Finder copies sent the basename; mixed drops omitted folders.
The unsafe-folder rejection case passed. The final candidate covers single-folder
copy/drop and mixed drops in both paste modes, the copy operation, symlink names,
controls and exact PTY bytes without Enter. Exact-head CI is required in PR163.

The local standalone Swift probe was blocked at its default compiler cache and
was not retried. No local AppTests or application build, personal histories,
general clipboard inspection, daily-app interaction, merge or installation.
The manual Finder drag/window-ID screenshot remains unobserved. REA-1230's branch
and uncommitted blocked note are preserved. One worker and ticket remain active
until parent personal final-diff review; no next ticket was selected.

## REA-1265: Return during a Codex turn

On isolated branch `fix/rea-1265-preserve-turn-watcher`, based on main `eaa36d0`,
Return retains the validated lifecycle watcher instead of reopening the journal
after the running turn's start event. Codex stays at its last observed state until
provider events arrive; Grok keeps its submission/chunk behavior. A watcher
generation fences every applied state and completion callback, including a
process replaced synchronously during a multi-event poll. Capability and native
identity validation remain required; REA-1218 is separate.

[QA evidence](../qa/rea-1265.md) records test-only CI38331238246 on `2c48757`:
37 XCTest cases passed, and 1,230 Swift tests completed with 14 issues, all in
the targeted TerminalTab cases. The second Return lost t1 completion, and
process replacement allowed stale completion state. The added journal controls
passed, so SessionLifecycle needs no parser or continuation-initializer change.
PR164 records the final exact-head integrated verification result.

No local AppTests, application build, compiler/cache retry, process enumeration,
personal histories or daily-app interaction. Synthetic files and an owned fake
CLI exercise the regressions in CI. Native visual/notification delivery remains
unobserved. REA-1273's manual Finder verification and PR162 remain separate.
No merge, installation or next-ticket work before parent personal final review.

## REA-1227: unavailable added projects

On isolated branch `fix/rea-1227-retain-unavailable-projects`, based on main
`aaef908`, successful scans keep added project references and pins through folder
absence or access failure. Legacy worktree entries still fold into their project.
Literal reference folding preserves aliases/pins through canonical convergence;
display matching emits one pinned row until the paths separate again.
Cached sidebar projections mark unavailable added folders and expose Retry in
the row, context menu, accessibility actions and focused-project notice. Retry
rechecks filesystem/canonical state without a history traversal. Explicit
Remove/Archive preserve files and unrelated shared-list entries. Filtered groups
keep their prior order/dates; snapshot cache and watcher policy are unchanged.

[QA evidence](../qa/rea-1227.md) records test-only CI38338985238 on `027419e`:
37 XCTest cases passed; 1,233 Swift tests in 109 suites completed with 11 issues,
all in the two new retention cases. A scan erased references/pins/focus, and
remount did not restore them. Both explicit Remove/Archive controls passed.
PR165 records the final candidate and exact-head integrated CI result.

No local AppTests/app build, denied cache/process retry, personal histories,
real model calls or daily-app interaction. Generated CI fixtures cover missing,
non-directory and permission-denied folders, remount/Retry, symlink retargeting,
shared copies, file/pin preservation and accessible state text. Manual mounted
image/native UI/VoiceOver observations remain unobserved. Build308 and blocked
PR162 remain untouched. Stop for parent personal final-code review; no merge,
installation or next ticket.

## 2026-10-13 — REA-1218: attach verified late Codex lifecycle

Isolated `fix/rea-1218-late-codex-lifecycle` starts from main
`18d6a17411a0a69726ccdc050e9c4c73170c71f6`. The test-only
`dce595abf850fe7f01d79f7e80a7539ba3e60949` reproduced three issues in
[CI38394128901](https://github.com/gl11tchy-team/sigil/actions/runs/38394128901):
validated explicit linking left lifecycle false, no watcher, and lifecycle false
in the phone snapshot. The other 1,284 Swift tests and all 37 XCTest cases passed.

The candidate carries opaque exact file/process receipts into late attachment,
silently catches up the final post-launch state, and retains the transcript on
Restart. Replaced files, rewritten prefixes, appended headers, ambiguous ownership
and stale process/session generations end observation. Mid-turn Return preserves
the existing watcher; a fresh reader after interruption tails current history.
Generated Kit fixtures and CI-only App fixtures cover the first turn, delayed
identity, completed-before-attachment, background unread completion, phone
capabilities, queued turns and delayed results after close/restart. New kernel
observations are synthetic. Strict local formatting and diff checks passed;
The exact-head integrated result, source tree and limits are recorded in
[PR170's validation](https://github.com/gl11tchy-team/sigil/pull/170) and its
[current checks](https://github.com/gl11tchy-team/sigil/pull/170/checks).
The mission requires that final head's integrated gate to pass.

First candidate `a8c3ecf7aeb8d4719445e18c30a0a46ccd6ea87e` stopped at
test compilation in CI38397622262: `#require` lost an injected closure's
Sendable type. The resolver call now precedes its assertion. Source review
added final file evidence verification after the last lease and capability-only
publication, with focused fixtures. A new exact-head gate follows this relevant
repair; there is no overlapping run or claimed Swift-test pass for the first gate.

Head `a2e3ac84086fb78b599cc747b2ba479bc2ca9a47`, CI38398604337,
ran 1,301 Swift tests in 111 suites with one issue: the restart fixture compared
`/var` and `/private/var` URLs for the same file. The other 1,300 Swift tests and
all 37 XCTest cases passed. The assertion now uses the existing canonical path,
without changing production identity. Personal review and review comment
4258674183 found that alert suppression also dropped Live Activity updates after
consuming the planner transition. Only notification alerts are now suppressed;
actual RemoteControl/loopback-relay cases capture state frames and decrypt the
later live finished alert. No Apple/APNs service or real phone is contacted.

No local AppTests/app build, prior cache/process/build-denial retry, live process
inventory, personal histories, real model calls or daily-app interaction. Actual
Codex, real-phone alerts and renamed-debug AX/window-ID UI remain unobserved.
Protected PR162 and prior manual-review tickets are preserved. Parent personal
final-code review is required before merge, installation or another ticket.

## 2026-10-13 — REA-1209: routed and registered push readiness

Isolated `fix/rea-1209-ready-push-queue` starts from
`fc46fccc2a42affe0ba779cba571452ba8fdfa52`. Test-only
`791746a554e62d514dfcdcc2870cad69fd4c682a`,
[CI38411917626](https://github.com/gl11tchy-team/sigil/actions/runs/38411917626),
changed only a generated loopback proxy/test. Actual RemoteControl emitted a
synthetic stopped alert while the real relay's host challenge was withheld.
One test failed three assertions: no captured alert, backend close1008 and two
room allocations. The other1,302 Swift tests and37 XCTest cases passed.

The candidate gates a bounded push-only queue on routed/registered readiness,
retains original identity/time/fixed expiry, coalesces activity updates and
reserves slots for accepted ends. Pairing/connection/room/token fences reject
stale continuations. Only authenticated phone commands clear ordinary alerts;
known closed-tab ends can be explicitly retired, and otherwise remain eligible
for delivery or expiry. Terminal commands are never queued. Focused generated
fixtures use actual RemoteControl/relay capture, a fake clock and owned write
barriers. Local formatting, JavaScript syntax and diff checks passed; final
exact-head integrated evidence will be recorded in the PR after observation.

First candidate `ed384512fba419d469851ff265b4098aedab6f2e`, CI38415786835,
stopped at test compilation: mutating queue calls and a throwing fixture read
were wrapped by Swift Testing macros. Those calls now precede their assertions;
production behavior is unchanged by this repair. No Swift test pass is claimed
for the first gate. The next gate follows this relevant repair, without overlap.

Repaired66f9d0515b3f62757149f839ad3df1a7bdb52040 / CI38417202880
compiled and ran1,313 Swift tests with8 issues: five in the prior late-Codex
completed catch-up case after connected-phone updates changed capture order,
and three new phone-fixture cases because the proxy omitted required Origin.
All37 XCTest cases and the pure queue suite passed. Ordinary connected-phone
update behavior is restored while ends remain eligible; Origin is forwarded,
and token replacement tests a genuinely queued away update. Prior assertions
remain intact. The next exact-head gate follows those concrete repairs.

No local AppTests/build, denial retry, personal history, real provider/Apple
calls, process inventory, security/credential or public distribution changes.
Relay allocation/proxy policy, APNs TTL policy and HTTP/2 retry remain separate.
Physical delivery and rendered Settings/AX/window-ID behavior are unobserved.
Protected PR162 and all ten earlier manual-review records remain preserved.
Stop for parent personal final-code review; no merge/install or next ticket.

## REA-1206: web New session choices (2026-10-13)

The web New sheet retains repository metadata and uses REA-1225's per-project
worktree default, with explicit choices, advertised Grok model/effort and a small
New project form restricted to advertised locations. A persisted pending result
prevents duplicate creation across connection loss and reload. An exact
authenticated project record can reconcile folder adoption; a lost session start
has no authoritative outcome receipt in this protocol and remains blocked with
Mac recovery guidance. Closing a sheet does not cancel a dispatched action.

The baseline's two New tests passed. Focused synthetic Node checks passed (153
tests, including replacement-pairing storage failure and pending preparation); local Playwright was blocked at server bind (`EPERM`, port 3099), without
retry or permission expansion. Local Chromium/WebKit screenshots remain unverified. Following direct owner
approval on October 14, one commit/status retry succeeded; ordinary exact-head
PR CI will supply browser screenshots and the integrated native checks. Scope, bounded
reconciliation and limits are in [REA-1206 QA](../qa/rea-1206.md). No native app,
backend protocol, cleanup, installed bundle or earlier manual-review record was
changed. The prior approval hold and original patch/test evidence are preserved. No
Linear comment was written or retried; only the explicitly approved existing
record status changed.


REA-1206's first completed browser gate passed 233 cases with two skips and one
Chromium lost-project reload failure. Its six phone-size screenshots exposed a
WebKit select-height mismatch. The focused repair distinguishes preparation from
dispatch, waits for actual synthetic receipt before testing lost replies, and
reuses the CLI picker with 44px geometry assertions. Exact-head CI after that
repair remains the acceptance gate; no native success was claimed from the
browser-failed run.


Automatic-review regressions on REA-1206 were reproduced against `543a6b3` (four
new cases fail), then repaired within the existing frontend protocol. The menu
preserves the advertised empty model, initial failed persistence leaves no false
unknown outcome, an atomic shared-origin IndexedDB claim prevents two contexts
from dispatching, and dismissed project success skips metadata reads. Settlement
uses the exact claim ID and stale ticket writes preserve it. Focused157 tests
pass; two-page encrypted browser coverage and final screenshots await fresh CI.


### REA-1206 release-gate fixture synchronization · 2026-10-14

PR175 merged at c4dec35 with the reviewed tree. Main CI38501085476 attempts1/2
failed different immediate pending-queue assertions in the existing
RemotePushReadinessTests helper. Both follow its fixed 400 ms wait after
asynchronous 300 ms alert batching. The original failed receipts are preserved.

A bounded fixture-only follow-up now requires the observable pending event using
the existing 4-second readiness helper. All eight callers and their original
safety assertions remain. No production or CI-policy change. Local native
execution remains prohibited; normal follow-up PR CI is pending. No further
unchanged-main rerun, merge, release, app replacement or REA-1207 implementation.
Actual official build352 remains installed and verified; web deployment and prior
device/manual acceptance remain open. See the [release-gate evidence](../qa/rea-1206-release-gate.md).

### REA-1207 transport-peer limits · 2026-10-14

On fresh main 139bf43, generated in-process HTTP requests reproduced A consuming
all 20 shared allocation tokens and B receiving 429. Admission now uses canonical
socket peers (/64 for IPv6, unified IPv4-mapped forms), a five-token burst/refill,
20 allocated rooms and 20 WebSockets per source, and a bounded 1,024-entry source
table. The room allowance includes existing five-minute reconnect grace and NAT
headroom; global 100 rooms/300 TCP connections remain. Unhosted rooms expire at 30
seconds. Forwarded headers are never trusted without a verified ingress rule;
none is enabled, so proxy/NAT users share one peer budget. Docker, deployment,
proxy/network/security settings and dependency versions remain unchanged.

Afterward A accepted 5 requests and B returned 201. Sixteen no-listener synthetic
tests pass. Removing the connection reservation fails the actual upgrade-admission
case; byte-for-byte restoration passes. Automatic review identified pressure from
closed connection-only entries; full idle buckets now reclaim under capacity
pressure without erasing allocation debt. Proxy identity and distributed exhaustion
remain explicit limits. Native 429/recovery cases and encrypted
expiry/grace integration are added for the normal PR CI gate, pending. No local
native build/AppTests, process enumeration, binding retry, live relay/APNs exercise
or customer data. Installed build360, protected PR162 and prior manual records remain
intact. See [QA evidence and limits](../qa/rea-1207.md). Parent exact-head review
is required before merge.


### REA-1217 eligible alert evaluation · 2026-10-14

Generated native counter fixtures reproduced prompt invocations on fresh main
a815c58 while remote was off or enabled without consumers: ordinary25-event
paths invoked once, suppressed paths25 times. Baseline PR178 CI38521292698 had
exactly these four expected issues and no other Swift failure. The same branch
now gates reads/scheduling by per-tab consumers, keeps alert/activity baselines
independent, preserves unchanged-token baselines and owns each delayed callback.
Last-consumer removal cancels only unneeded tasks; watch streaming remains separate.

Queue/drain, watch/protocol and existing generation assignments are byte-identical.
Compatibility fixtures establish baselines after eligibility, with original
queue/generation/timing/expiry assertions preserved. New deterministic lifecycle
and encrypted watch cases are added; repaired-head normal CI is pending. No local
native command, process enumeration, denied retry, personal agent data, model
switch, extra worker, power measurement, deployment, merge or app replacement.
Installed build364 and held PR162 remain untouched. See [QA evidence](../qa/rea-1217.md).


## REA-1215 — remote idle-sleep ownership (2026-10-14)

Started from main `671f7a4` in one isolated worktree. PR179 baseline `7f83fb5`
uses a generated current-turn journal, fake child/throwaway CLI home and an
in-memory saved alert registration while the phone is away; CI38535865150 is
red at fixture setup (unknown provider availability), before the intended
power expectation. The corrected fake availability and full repair are local
only. Only watcher injection changed the baseline production source.

Repair uses separate effective validated-work revisions, observable alert arming,
one process-owned assertion and an injected monotonic power-policy deadline.
Quiet polls and relay reconnects cannot renew it or imply completion. Current
journal/lease loss removes only power eligibility. A failed release preserves
ownership for retry, and independent Sigil copies never release each other's ID.
New CI fixtures cover the policy table, missing journal, quiet long turns/timer,
consumer transitions, independent copies, interruption/disconnection, assertion
failures and encrypted registration observation. UI change is explanatory copy
only. Native tests/build/formatting remain CI-only; manual Grok/pmset acceptance
is unverified. No merge or app replacement before parent personal review.
See [QA record](../qa/rea-1215.md).

REA-1215 approval record: exact remote/private ADMIN/push checks resolved the
initial trust rejection. Parent supplied the owner's standing next-ticket
instruction after the scope-authorization denial; the same denied call was
retried once with this evidence and allowed. Corrected baseline `0c34b9b` is
submitted on PR179. Preserve the original fixture setup failure; corrected
behavior reproduction remains pending. No denial bypass or local native retry.

REA-1215 corrected baseline verified: CI38539738876 at `0c34b9b` recorded exactly
the intended missing-assertion issue (created[] instead of one), after all
current-turn/paired-alert/fake-child setup checks passed. Actual checkout
`f582a8fb` has expected parents and head-tree parity. 1327Swift tests/113suites,
one intended issue;37XCTest,248relay,58site,236browser/two skips passed. Later
native checks skipped after the expected failure. Full repair is now ready for
its exact-head CI; no local native execution or manual pmset claim.
