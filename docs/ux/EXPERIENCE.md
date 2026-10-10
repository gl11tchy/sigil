# Sigil experience contract

Status: adopted 2026-09-29. This file is the shared UX contract for the Mac app,
the iPhone app and the Sidereal web companion. [PROGRESS.md](PROGRESS.md) is the
resumable evidence ledger that records what is built and proven against it.
[baseline/BASELINE.md](baseline/BASELINE.md) records the app as it was before
this contract.

## Precedence

- For product UX (layout, navigation, journeys, states, controls), this file
  wins. It replaces the earlier "no redesign" non-goal in `PRODUCT.md` and the
  rule that Beautiful UI "wins" over `DESIGN.md`.
- `PRODUCT.md` still owns the outcome, safety and truth priorities. Nothing
  here relaxes them.
- `DESIGN.md` still owns token values, type, shape and motion. Beautiful UI is
  the source those values came from, not an authority over layout.
- These stay fixed: native Swift, AppKit and SwiftUI; the real provider CLIs
  in a real terminal; terminal fidelity; existing user data; remote security.
  Sigil is not a web wrapper and not an SDK chat.

## One journey

Sigil is a coding workbench. The unit of work is a task, not a tab. Every
surface serves one journey:

| Step | The user | Sigil guarantees |
|---|---|---|
| 1. Choose project | Picks a repository from the rail or adds one. | Projects are the user's list, in a stable order. |
| 2. Start a task | Starts a task in that project, in the project folder or a fresh worktree. | The workspace (folder, branch) is named in the context header before any output arrives. |
| 3. Work | Types into the provider's own terminal. | The terminal is the real PTY and the real CLI. Nothing draws over it. |
| 4. Find attention | Sees which tasks finished, need input, failed, or cannot run. | Attention comes from evidence only (see [Truth](#truth-and-attention)). Unknown stays unknown. |
| 5. Review | Opens the review region: changes, checks, conversation, process. | Changes are read from Git in the task's workspace. A missing source says so. |
| 6. Finish | Ends the task: keep, archive, or remove its worktree. | Nothing is deleted without an explicit confirmation that names it. |
| 7. Return from the phone | Opens the same task from the phone. | The phone addresses the task, not a tab. It shows the same identity, state and capabilities. |

The baseline records how many actions each step takes today and where it
breaks. Missions M1 to M6 below close those gaps.

## Five concepts, one hierarchy

| Concept | What it is | Identity | Lifetime | Shown as |
|---|---|---|---|---|
| **Project** | A repository or folder the user works in. | Canonical path of the folder (a Sigil worktree resolves to its project). | Until the user removes it. | A rail section. |
| **Workspace** | The checkout where a task's files change: the project folder itself, or a Sigil worktree on branch `sigil/<name>`. | Canonical path. | Until the task is finished and its worktree removed. | Context header crumb, review region. Never a list. |
| **Task** | One piece of work the user asked for: one workspace, one provider, one conversation lineage. | Sigil's own ledger entry (provider, conversation ID once verified, workspace). A new task has a Sigil ID before the provider assigns one. | Until the user finishes or archives it. | A rail row. |
| **Live process** | The CLI running in a PTY for a task right now. | Process and terminal view. A tab ID is not a conversation ID. | Ephemeral. Ends, restarts, or never starts. | State mark and header state. Never a list. |
| **Verified provider conversation** | The provider's native conversation that the history adapter has matched to the task. | Provider plus native session ID, verified by [provider capabilities](../provider-capabilities.md). | Owned by the provider CLI. | Review region fact: verified, pending, or none. |

Navigation has exactly one hierarchy: **Project → Task**. Workspace, live
process and conversation are attributes of the selected task, shown in the
context header and the review region. They never become a second list, tab
strip, or destination.

Today the app exposes several hierarchies at once: the sidebar's Open list,
Projects → chats, Recents, Archived, the tab strip, the tab list (⌃⌘T), and the
phone's own chat and project lists. Missions M2 and M5 fold them into the rail
and the phone's matching Project → Task list. Archived becomes a filter of the
rail, not a place.

## The workbench

```
┌──────────── canvas ─────────────┬──────────────── page (screen) ──────────────┬──── review ────┐
│ ● ● ●                       +   │ ◉ Rate limiter for /v2/search    Working 3m │ Changes  +42 −7│
│ [ All ][ Needs you · 3 ]        │ acme-api › sigil/7f3a2c1 · Claude Code      │  M src/limit.ts│
│ acme-api                     3  ├─────────────────────────────────────────────│  A test/limit… │
│  ◉ Rate limiter for /v2/sea…    │                                             │ Checks         │
│  • Fix flaky auth test          │          the provider's real terminal       │  Not connected │
│ acme-web                     2  │                                             │ Conversation   │
│  ○ Checkout button states       │                                             │  Verified …    │
│ infra                        2  │                                             │ Finish         │
│  × Terraform: split state       ├─────────────────────────────────────────────│  (unavailable) │
│                                 │ [docked: ended session · Close · Restart]   │                │
└─────────────────────────────────┴─────────────────────────────────────────────┴────────────────┘
```

- **Rail** (on `canvas`, 248pt, 200–320): the Project → Task list. Rows keep
  their order: projects in the user's order, tasks by creation time. Activity
  never reorders them, so a row stays where the user last saw it. A segmented
  filter switches between All and Needs you (with the count). The filter
  hides rows; it never moves them.
- **Screen** (on `page`, the existing inset screen): a 44pt **context header**
  with the task's mark, title, state and elapsed time, and one mono crumb line —
  project › workspace or branch · provider. Below it, the **existing terminal
  pane**, unchanged. Docked cards (tab message, ended session) stay below the
  terminal, never over it.
- **Review region** (a second screen, 340pt, 300–420): Changes, Checks,
  Conversation and process facts, Finish. It opens from the header's Review
  control, which shows the change totals.
- **Space priority**: terminal (at least 480pt) first, then the review region
  when it is open, then the rail. When all three do not fit, opening review
  hides the rail; showing the rail closes review. Nothing overlays the terminal.
- **Appearance**: dark and light token sets from `DESIGN.md`. The workbench
  adds no new colours. Task content wins over decorative chrome: no gradients,
  no ornamental cards, no chrome larger than what it labels.

## States

Every workbench surface ships these states. The reference slice renders each
one from fixtures (see [Reference slice](#reference-slice)).

| State | Rail | Screen | Review |
|---|---|---|---|
| Empty, no projects | Teaches: "Add a project to start." | Add Project… | Hidden. |
| Empty, projects but no tasks | Projects with a start control. | "No tasks in <project>" and Start Task. | Hidden. |
| One task | One section, one row. | Terminal. | Changes of its workspace. |
| Busy, many projects | Sections with counts; mixed marks. | Selected task's terminal. | Selected task's changes. |
| Provider unavailable | Row keeps its place with an unavailable mark. | A panel naming the provider, the problem and what keeps the saved reference; Check Again and Settings. No terminal is faked. | Workspace facts; conversation stays saved. |
| Process ended with an error | Red mark. | Terminal keeps the output; the ended-session card offers Close and Restart. | Unchanged. |
| Workspace missing | Red mark. | "Workspace folder is missing" with its path. | Changes: cannot read, with the reason. |
| Not running (history only) | Plain row. | "Not running" and Resume where the provider can resume. | Last known facts. |

## Controls

- Every control either performs a real action or is visibly unavailable with
  the reason in its help text and accessibility label. There are no
  decorative or dead controls.
- Fixture-only surfaces compile only in debug builds (`#if DEBUG`) and never
  appear in release UI.
- Reuse before adding: New task maps to the inline empty terminal with monochrome
  provider glyphs impressed into its own ground, with shallow inset shadows and
  highlights. One click starts with saved/default settings, and Options
  opens the existing configuration sheet. Reuse provider checks; Restart and
  Close map to the existing tab actions; review's
  scratch shell to the existing right-panel shell; Find to the existing
  terminal find bar; rename, pin and archive to the existing ledger. A second
  persistent control for the same action is a defect. An empty state may
  repeat the one next step it teaches.
- Keyboard first: ↑/↓ move through the rail, Return opens, ⌘1…⌘9 go to the
  first nine tasks in rail order, and a Next Needing Attention command walks
  the filter.
- File → Archive Conversation (⌃⌘A) and Pin Conversation (⌃⌘P) use the
  focused sidebar's multi-selection, then its keyboard row; otherwise they
  use the selected tab's known conversation. All-archived or all-pinned
  targets reverse the command; mixed selections archive or pin every target.
  Project rows reuse project archive/removal and pinning. Unsupported
  providers and text editing disable the commands. A canceled stop prompt
  keeps the selection; a removed range leaves the highlight on the next row.

## Truth and attention

Attention is derived only from evidence the app already treats as proof
(`SessionLifecycleState` and provider journals):

| Evidence | Attention | Mark |
|---|---|---|
| Provider-confirmed turn finished, not yet seen | Finished | Accent dot |
| `waitingForApproval` | Needs input | Orange dot |
| `interrupted` | Stopped | Orange dot |
| `failed`, or exit with a non-zero code | Failed | Red dot |
| Provider CLI unavailable, or workspace missing | Blocked | Red ring |
| `working`, `starting` | None (in progress) | Pixel loader |
| `unknown`, `disconnected`, silence, title change | None — shown as unknown | Grey dot |

A terminal title, silence, or a live process never proves a finished turn.
An approval parsed from terminal text is ordinary terminal input, never a
verified authorization.

## The terminal ceiling

Provider CLIs draw their own interfaces (Ink/React, Ratatui and similar) as
escape sequences into a PTY. Sigil hosts that output faithfully and cannot do
more with it without a different integration:

- Sigil can know: process start and exit, the provider journals it already
  validates (Grok updates, Claude and Codex history), the workspace's Git
  state, the terminal title, and scrollback text for Find and the phone.
- Sigil cannot know reliably from the terminal: message boundaries, tool
  calls, diffs the agent is proposing, or whether a menu on screen is an
  approval. Terminal text is presentation, not a protocol.
- So there is no uniform native transcript across providers. A native
  transcript, per-message actions, or structured approvals require a
  separately justified integration per provider (a documented structured
  output or app-server protocol), with its own spec, tests and fallbacks.
  Until then the terminal is the conversation, and the workbench builds around
  it with facts it can prove.

## Reference slice

The reference slice is a runnable native layout, not a mockup. It lives in
`Sources/SigilApp/Workbench/` and `Sources/SigilKit/Workbench/`:

- Pure models (concepts, attention, rail order and filter, column layout, Git
  change reading) are in SigilKit and unit-tested without windows.
- Views use the existing design kit and the existing `TerminalPane` with a
  real `TerminalController`.
- Fixtures are debug-only. A debug build started with
  `SIGIL_WORKBENCH_FIXTURE=empty|one|busy|unavailable|error` builds temporary
  Git repositories and fake CLIs, and shows the workbench instead of the
  normal window. `SIGIL_WORKBENCH_APPEARANCE=dark|light` and
  `SIGIL_WORKBENCH_WINDOW=<width>x<height>` fix the appearance and size for
  screenshots. Release builds contain none of this.

## Mission rules

These rules bind every mission that follows this contract.

1. At most four concurrent workers. Each has disjoint write ownership, named
   before it starts.
2. Preserve recent hardening: provider truth, remote security, startup focus,
   Sigil-only history, and the safety tests that hold them.
3. Tests and harnesses use isolated homes, fake CLIs and temporary Git
   repositories. No paid inference. No personal sessions, keychains or
   credentials. Never symlink a real CLI into a fake home.
4. Run targeted tests while editing. Run one applicable integrated gate at the
   end. Rerun a gate only after a relevant change.
5. Record evidence as observed. Do not invent timings or counts. Do not ask the
   owner to grade routine decisions; decide, record why, and continue.
6. After two repair rounds without new progress, stop that branch, mark it
   blocked in PROGRESS.md with the evidence, and continue elsewhere. Never
   loop and never declare success without proof.
7. No merge, deployment or replacement of the running app without existing
   explicit authorization.
8. `SigilAppTests` open windows on the owner's screen. Run them in CI, not
   locally. Real-app verification uses a renamed debug bundle, AX presses and
   window-id screenshots, never keystrokes into whatever app is in front.

## Missions

| ID | Scope | Writes | Depends on | Done when |
|---|---|---|---|---|
| **M0** | This contract, the evidence ledger, the baseline, the debug reference slice. | `docs/ux/`, `Sources/*/Workbench/`, workbench tests, precedence notes in `PRODUCT.md`, `DESIGN.md`, `AGENTS.md`. | — | The slice runs in every state; screenshots and baseline exist. |
| **M1** | Live projection: map `AppModel` tabs, ledger conversations and provider installations to workbench inputs; show the workbench as the main window behind a setting that defaults off. | `Sources/SigilApp/Workbench/`, a new adapter file, `RootView.swift`. | M0 | The real app runs a real task in the workbench with every control real or unavailable; CI green. |
| **M2** | Navigation consolidation: the rail replaces the tab strip, tab list and Open list; Recents and Archived become rail filters; ⌘1…⌘9 and Next Needing Attention follow rail order; pins, names and archives migrate unchanged. | `SidebarView.swift`, `TabStripView.swift`, `TabListView.swift`, `AppModel` navigation. | M1 | One hierarchy on the Mac; existing ledger data intact; setting default flips on. |
| **M3** | Review region, live: Git changes per workspace with refresh on focus and turn end; open a file's diff in the existing panel shell; a checks source only after a spec picks one (local command or hosted CI) with its trust boundary. | `Sources/SigilKit/Workbench/`, review views. | M1 | Changes match `git` in temporary repositories; checks either real or explicitly unavailable. |
| **M4** | Finish: keep, archive, or remove a worktree, with confirmation naming the branch and uncommitted changes. | Ledger, `SigilWorktree`, review region. | M3 | No data loss in temporary-repository tests; finished tasks leave the rail. |
| **M5** | Phone return: the phone lists Project → Task with the same identities; commands address the task and resolve to its live process on the Mac; notifications open the task. | `Sidereal/`, `iOS/`, remote protocol (additive, authenticated). | M1 | The same task opens on the phone after a Mac restart; security tests unchanged and green. |
| **M6** | Structured transcript investigation, per provider, only with a written justification and fallbacks. No promise of a uniform transcript. | A spec under `docs/ux/`. | — | A decision record per provider. |
