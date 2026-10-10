# REA-1211 native acceptance

Captured on the connected Mac on 2026-10-10, finishing at 06:10 UTC.
Application code under test is PR #143 commit
`9938f27596c4391ab17a87cead017b63676ed58f`. This evidence addition changes only
documentation and screenshots.

## Observed behavior

The real New Session UI launched one fake provider process at a time. An AX menu
action sent `Synthetic lifecycle prompt\r` through the selected tab's existing
`TerminalController.send(text:)`. Each fake child wrote the received line to its
isolated receipt file; screenshots show the terminal's prompt and receipt echo.
The actual `onUserSubmit` callback ran. No activity state was assigned by the fixture.

| Provider | Post-submit screenshot, window 6841 | AX status | Close warning / window |
|---|---|---|---|
| Claude Code | [Claude](claude-submitted.png) | Status unknown | Claude Code is still running. / 6869 |
| Devin | [Devin](devin-submitted.png) | Status unknown | Devin is still running. / 6883 |
| Cursor | [Cursor](cursor-agent-submitted.png) | Status unknown | Cursor is still running. / 6889 |
| Kimi Code | [Kimi](kimi-submitted.png) | Status unknown | Kimi Code is still running. / 6895 |
| New Codex, no transcript | [Codex](codex-submitted.png) | Status unknown | Codex is still running. / 6901 |

All five screenshots show grey tab/sidebar marks and no loader or elapsed timer.
The synthetic home project has zero history chats, no working dot, and no working
count. No history discovery or tab identity binding is exercised by this fixture.

Claude's [close warning](claude-close-warning.png), window 6869, says
“Claude Code is still running.” / “Claude Code will stop.” with Cancel and Close
Tab. Its [quit warning](claude-quit-warning.png), window 6873, says
“Claude Code is still running. Quit anyway?” with Cancel and Quit. AX independently
read those strings and buttons. Each synthetic tab was then closed through its
normal confirmation; the renamed app quit normally with no tabs remaining.

## Isolation and method

`Scripts/workbench/build.sh` produced a debug, ad-hoc-signed `Sg1211Native.app`,
bundle ID `com.gl11tchy.sigil.rea1211.native`, under the task workspace. The
signature was verified. The daily app was not installed, replaced or quit.
Runtime `HOME`, `CFFIXED_USER_HOME` and `ZDOTDIR` pointed to a generated home;
PATH began with that home's fake CLI directory. Codex and Claude history roots
were absent synthetic paths. All six CLI executables were fake scripts; the
version-check trace verified their paths and `--version` arguments. No personal
history, real provider session, network inference or credentials were used.

For this native check only, a separate uncommitted debug fixture was compiled
into the renamed bundle and then removed from the implementation checkout:

- `XCTestConfigurationFilePath=/dev/null` retained in-memory credentials and
  suppressed unrelated production startup services.
- A seven-line debug branch in `AppModel.onAppear` refreshed fake provider
  installation checks despite that test-mode flag.
- A ten-line debug menu addition in `SigilApp.swift` exposed the synthetic send
  action above. It called the existing terminal controller directly.
- `NativeLifecycleFixture` required the opt-in environment flag, exact renamed
  bundle ID, matching isolated home variables, fake PATH prefix and all six fake
  executable files before either addition could run.

Those fixture sources remain outside the PR. They do not alter lifecycle parsing,
submit handling, activity display, provider timeouts, close/quit warnings or
capability policy. The screenshots exercise the shipping tab/sidebar/top-bar UI
with real PTY input, but not the full ordinary credential/startup configuration.

AX and screenshot helpers checked the app PID, exact bundle ID and renamed
executable. Captures used only verified owned window IDs with
`screencapture -x -o -l <id>`. No keystrokes went into the front app, and no
permission dialog or access setting was accepted or changed.

## Limits and repaired fixture timing

The earlier renamed process timed out its fake CLI version checks. A supported
same-bundle relaunch with the saved synthetic environment succeeded; traces show
all six fake version invocations. The earlier timeout's cause is unverified.
A historical Documents-folder TCC request did not establish a current pending
approval; action-time inspection found no permission dialog.

An initial Cursor send ran before its child produced a receipt. A later send
verified the receipt before capture. An early quit check read the UI before the
warning settled; activating the same owned app and repeating AX Quit verified
the warning. AX close presses returned `-25204` while their synchronous modal
was open; subsequent AX reads and window captures verified the actual alerts.
No application code was changed to resolve these harness timing issues.

The fixed last-input tooltip is covered by CI/source inspection; native hover
was not exercised. Phone snapshots, lack of a completion watch, and validated
Grok/Codex Working-to-Idle behavior are covered by the ordinary CI gate's
synthetic tests. The iPhone Live Activity start condition was source-inspected;
no live phone, authenticated response or customer impact was exercised.
SigilAppTests ran only in CI.
