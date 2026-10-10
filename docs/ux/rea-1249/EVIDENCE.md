# REA-1249 evidence

Ticket: [Give Archive and Pin a key for the sidebar row and the open chat](https://linear.app/reasonable-glyph/issue/REA-1249/give-archive-and-pin-a-key-for-the-sidebar-row-and-the-open-chat).

Status: implementation ready for code review; native keyboard acceptance is
blocked. No merge or daily-app replacement was performed.

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

## Native attempt and blocked acceptance

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

Remaining acceptance: a successful real-app Shift-Down twice → ⌃⌘A sequence,
next-row highlight/focus, terminal working confirmation, project commands and
menu directions, with an owned-window screenshot attached to the PR. The
observed menu snapshot preceded the final focus guard; there is no final-head
native acceptance claim. The branch remains blocked on this native evidence
even if CI passes. Full local verification, local AppTests, iPhone validation
and distribution were not run; ordinary PR CI owns the integrated gate.
