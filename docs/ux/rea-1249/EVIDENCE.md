# REA-1249 evidence

Ticket: [Give Archive and Pin a key for the sidebar row and the open chat](https://linear.app/reasonable-glyph/issue/REA-1249/give-archive-and-pin-a-key-for-the-sidebar-row-and-the-open-chat).

Status: the parent accepted the continued native fixture evidence and personally
approved the complete diagnostic/conflict patch in review package v3. This
follow-up commit includes that patch and the two reviewed synthetic screenshots
below. At submission, required exact-head CI is pending; its result is tracked
on PR145. Final parent review remains required before any PR merge. No daily-app
replacement was performed.

## Baseline and scope

Started from post-PR144 main `be90c2544792a9538e279ada89672c0b3476224b`;
a final fetch still returned that main. Source and the isolated app's File menu
had no Archive/Pin command. The old sidebar clamp discarded a removed row's
highlight. The owner's historical ticket audit was retained.

File-menu shortcuts use the focused list's visible selection, then its row,
then the selected tab's known conversation when the list is unfocused or
hidden. Unknown focused targets fail closed. Menu titles state one direction
for mixed selections. Existing provider capabilities, project actions and
stop-working prompts remain authoritative. Removed rows choose the next
surviving row, then the previous survivor at the end. Closing a selected tab
through a list archive suppresses automatic terminal focus until an explicit
tab selection or leaving the list.

No provider parsing, tab-binding identity, history discovery, launch defaults,
dependencies or other ticket implementation changed. Inspection found no
existing Control-Command-A/P menu equivalent in Sigil or SwiftTerm's terminal
key handling; ordinary Control-A/P remain distinct.

## Validation actually performed

| Check | Result |
|---|---|
| Baseline `swift build --product Sigil --jobs 4` | Passed |
| Baseline and changed `Scripts/build-app.sh`, debug, ad hoc signed | Passed; changed bundle preceded the final focus fix |
| Final `swift build --build-tests --jobs 4` | Passed in 15.68 seconds; compiles AppTests without running them |
| Strict Swift format lint, six changed Swift files | Passed |
| `git diff --check` | Passed |
| Standalone assertions compiled against the actual `SidebarOrganization.swift` and existing dependency objects | 12 resolver/highlight assertions passed, with no AppTests or windows |
| Same assertions against a temporary focus-precedence mutation | Failed as expected (exit −5); repository source unchanged |

CI-only coverage adds resolver precedence, invalid/stale targets, next-row
movement, mixed archive/pin direction, selected-tab and hidden-sidebar archive,
working confirmation/cancellation, project pin/archive/removal, unsupported
providers, rename/text/composition guards, and preserving list focus after an
open-row archive. Tests use generated histories and fake CLIs. Runtime results
must come from the ordinary exact-head PR CI; this document does not claim
those compiled tests have passed.

The initial sandboxed final build could not write Swift's existing module
cache. The authorized cache-access retry compiled successfully. There was no
approval denial or permission-setting change.

## Initial native attempt and blocked acceptance

The fixture copied the debug bundle as `Sg1249Native.app`, with bundle ID
`com.gl11tchy.sigil.rea1249.native`, generated five Grok histories, synthetic
HOME/CFFIXED_USER_HOME/provider homes, and fake CLIs behind a controlled login
shell. Helpers verified the exact bundle/PID before AX actions; screenshots
were restricted to a window ID owned by that PID. No global keyboard event,
personal conversation, real CLI inference, or daily-app action was used.

- The first baseline launch stalled in its fixture history watcher. A bounded
  retry using a temporary fixture home produced owned window 7250. AX exposed
  its menu, but returned a recursive application element for the window, with
  no usable sidebar controls. The repository's AX helper reproduced that.
- The changed fixture (PID 69263, owned window 7254) exposed Archive Conversation
  and Pin Conversation, both disabled with no known target. AX pressing Find
  Conversations reported success. Application-scoped AX Tab/Shift-Down calls
  returned success, but the focused element remained AXApplication and menu
  targets stayed disabled. This does **not** prove selection or bulk archive.
- AX trust and screen-capture preflight both returned true. `screencapture -x
  -l` could not create an image. The bounded ScreenCaptureKit alternative first
  needed AppKit initialization, then failed with `SCStreamErrorDomain` −3811,
  “Failed to start stream due to audio/video capture failure.” No screenshot
  was produced. Native retries stopped.
- The fixture was terminated after checking its executable path. The running
  `/Applications/Sigil.app` process was preserved.

At this initial checkpoint, remaining acceptance was a successful real-app
Shift-Down twice → ⌃⌘A sequence,
next-row highlight/focus, terminal working confirmation, project commands and
menu directions, with an owned-window screenshot attached to the PR. The
observed menu snapshot preceded the final focus guard; there is no final-head
native acceptance claim at that checkpoint. The continued verification below
supersedes that initial native blocker. Full local verification, local AppTests,
iPhone validation and distribution were not run; ordinary PR CI owns the
integrated gate.

## Continued native evidence and parent review

The parent personally reviewed the complete continued report, disposable
fixture patch and owned-window screenshots, and accepted the fixture proof.
The unchanged exact-head app established single-row and project menu actions.
A renamed disposable fixture built from head
`303e2346b341b1177e9fc3d81cde76de9e822ab0` changed only entry/Commands wiring and
added fixture controls; all 97 other tracked source/package files matched.
Its AX-driven in-app events exercised shipping handlers for three-row Archive,
survivor Pin, mixed directions, Search/Rename/marked-text guards, Working
confirmation/cancellation, hidden-sidebar fallback and empty-project removal.
Generated CLI input receipts established the actual submit/lifecycle path.

External OS keyboard delivery into the unchanged binary and a full physical
IME workflow remain unverified limits. No application defect was established
by that fixture run. The complete `CONTINUED-EVIDENCE.md`, fixture patch and
11 screenshots remain preserved in the parent's private review package.

Two existing owned-window captures are included here, byte-identical to the
reviewed originals. These depict generated histories in the disposable entry
fixture, with shipping handlers and in-app event transport. They do not prove
external OS keyboard delivery or customer impact; no new screenshot was taken.

- [Synthetic fixture: three rows selected](three-selected.png), SHA-256
  `9781e7f31c2d1d794fe86f26d2205aa8a444d116141b6be7cc973cceefb96555`.
- [Synthetic fixture: Archive removes the range and retains the next survivor](three-archive-next-row.png), SHA-256
  `bfa3ee9e875c185ffc8e0d1b395743401a80ce08a47ee62dc0b1b8ac999e80c8`.

## Repeated CI stall and proposed bounded diagnostics

[Run 38043558092](https://github.com/gl11tchy-team/sigil/actions/runs/38043558092)
attempts 1 and 2, both at exact head 303, ended cancelled. Both check annotations
explicitly report `The job has exceeded the maximum execution time of 45m0s`.
Both logs end after the start of
`SettingsViewTests.submittingTheAlreadyStoredPathDoesNotReapply()`, without a
completion or assertion failure. Output is buffered; this is an observed log
boundary, not proof that Settings caused the stall. Neither run captured stacks.
The Settings test/model/view and verification/workflow blobs matched main;
that test passed on main, which later failed a separate watcher test. Neither
root cause is established and neither test is modified here.

During preparation, main `82f185539329f1dd20d226253a10908db2d600e9` was merged
locally with `--no-commit`. The only conflict was two appended PROGRESS entries. Both the
approved REA-1246 entry and the existing REA-1249 entry are retained verbatim;
approved deployment changes merge unchanged. The reviewed follow-up commit
records that resolution. App/package/Swift test source and `Scripts/verify.sh`
remain identical to PR145 head 303.

The temporary workflow wrapper is restricted to PR145's macOS CI. It runs the
unchanged `Scripts/verify.sh`, inheriting its environment, output and exit
status. It arms only after the repeated Settings start marker, then waits
three minutes without a further test event. It enumerates children only from
its owned Verify process and requires one `swiftpm-testing` descendant. The
PID, PPID, executable path and process birth identity of the entire ancestry
are revalidated before each capture. Missing, ambiguous or changed identity
records a limitation without retargeting or inspecting host processes.

One pair of `/usr/bin/sample` captures is permitted: five seconds each at
10 ms intervals, separated by ten seconds. Each sampler has a ten-second
watchdog; only that owned sampler can be stopped. Verify and its test processes
are never terminated by diagnostics. Sampling failure/denial, missing evidence
storage and sampler timeout preserve Verify's result. The gate's assertions,
serialization and 45-minute job deadline remain unchanged. A kernel file-size
limit bounds each sample/report command log to 1 MiB; the test-event tail is
64 KiB. Receipts flag reports reaching the cap. An always-run artifact upload
includes only that run/attempt's directory, with seven-day retention.

Local diagnostic validation uses generated Python/C processes and a fake
sampler. Ten unittest cases cover timing/progress, bounded files, owned-child
enumeration, foreign/ambiguous/recycled identity refusal, CI refusal, and
unchanged Verify success/failure through unavailable storage, sampling denial,
sampling failure and sampler timeout. An inherited output pipe cannot delay
returning Verify's exit result indefinitely. No local Swift tests, app windows or
real stack sampling were used for this patch. Production five-second captures
and artifact delivery remain unverified until a parent-approved CI run.

The parent personally reviewed the exact unpushed diagnostic/conflict patch
in package v3 and authorized committing it, adding the two existing screenshots,
and one push to PR145 while Sigil CI is idle. The resulting ordinary PR run is
the single instrumented run; no separate dispatch or rerun is authorized.
This instrumentation gathers evidence, not a claimed root-cause fix or passing
integrated gate. Final code and exact-head CI review remain required before merge.
