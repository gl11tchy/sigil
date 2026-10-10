# Workbench progress ledger

The resumable record for the [experience contract](EXPERIENCE.md). Each entry
says what was built, how it was checked, what the check showed, and what is
still open. Nothing here is a timing; counts are counted actions.

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
