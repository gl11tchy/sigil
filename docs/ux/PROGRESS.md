# Workbench progress ledger

The resumable record for the [experience contract](EXPERIENCE.md). Each entry
says what was built, how it was checked, what the check showed, and what is
still open. Nothing here is a timing; counts are counted actions.

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
- Rail ↑/↓ and Return are unit-tested (`WorkbenchRail.move`) but not driven
  in the running app, because the harness sends no keystrokes. ⌘1…⌘9 and Next
  Needing Attention are not in the menus yet (M2).
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

```bash
Scripts/workbench/build.sh
Scripts/workbench/matrix.sh docs/ux/slice
```

`launch.sh <fixture> <dark|light> <WxH>` prints a pid; `ax.sh <pid> dump` and
`ax.sh <pid> press <label>` read and press controls; `snap.sh <out.png>`
captures the window; `kill <pid>` quits. The scripts refuse to act on any
process that is not the renamed bundle.
