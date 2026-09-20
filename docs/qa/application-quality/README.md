# Application quality pass — 2026-09-20

## Delivered

- Phone workspace: full-width session title, separate activity status, compact Stop,
  one message composer, responsive keyboard layout, and clearer pairing steps.
- Searchable session picker with draft retention, literal output search with match
  navigation, and copying of displayed output. Raw terminal remains available.
- Return inserts a newline. Command/Ctrl+Return or Send submits explicitly.
- Ended sessions can restart remotely. Running and unknown tabs cannot be restarted.
  The existing conversation and folder stay intact; the phone draft follows the explicit
  replacement tab ID, even if the Mac changes selection before answering.
  Older Mac versions retain the desktop-restart fallback.
- Desktop search combines terms across conversation titles and folders, with matching
  highlights. Terminal Find buttons expose their keyboard shortcuts.
- Pairing offers Copy Pairing Link and hides server configuration until requested.
  Manual paste stays usable while clipboard access is pending. Desktop fullscreen no
  longer shows an iPhone-only warning.
- Stop errors are reported. Connection loss leaves drafts editable and disables sending.

## Review coverage

Reviewed the project/session sidebar, tab strip, terminal and find bar, launch settings,
phone pairing, notes/shell panel, encrypted relay, attachments, and reconnect lifecycle.
Preserved the established desktop density, themes, notes, session storage, encryption,
and real terminal. No synthetic conversation renderer or extra model-output filtering.

## Verification

`Scripts/verify.sh` passed:

- 72 Sidereal Node tests and 7 Site tests.
- 70 browser tests across Chromium and WebKit, including 320–1280px viewports,
  44px touch targets, simulated keyboard resizing, file attachment, drafts, recovery,
  session search, keyboard focus during activity updates, output search, pairing failures, and raw output.
- 468 Swift Testing tests plus 39 XCTest tests.
- Production dependency audits: zero vulnerabilities.
- Shell syntax, shellcheck, strict Swift formatting, signed debug bundle and smoke launch.

Regression tests failed before the relevant changes: session/output search, phone
Return behavior, native multi-term search and restart, fullscreen advice, and pending
clipboard access, and session-picker focus across polling and Safari dismissal.
Full gate rerun passed after fixing a missing fake-DOM path by
retaining direct text rendering when output search is inactive.

Native UI verification used a separate bundle ID, temporary home, local fake CLI,
and an in-memory pairing store. No live user conversations or pairing keys changed.
Verified combined project/title search, opening its result, terminal find, expanded
server settings, and Copy Pairing Link feedback.

A visible 390px Chrome window connected to that actual native build through the real
local relay. Verified QR decoding/pairing, sending text to the native PTY and receiving
its response, output search, Copy output feedback, Stop, remote restart with draft
retention, and the session sheet. The disposable pairing was revoked afterward.

## Evidence

All screenshots contain isolated test data.

- [Mobile output search](mobile-live-find.png)
- [Session picker](mobile-sessions.png)
- [Draft retained after native restart](mobile-restarted.png)
- [Pairing screen](welcome.png)
- [Desktop multi-term search](desktop-search.png)
- [Desktop terminal find](desktop-find.png)

## Limits

No physical iPhone camera, Safari keyboard, or Home Screen test was possible here.
Browser keyboard checks simulate visualViewport changes; they are not device proof.
The native integration used a fake CLI, not a paid Grok model turn.
This is a locally verified implementation, not a production deployment or installed-app
update. The running user app was left intact. Existing review/CI/merge gates still apply
before release; a Mac-changing merge must use the repository's install-latest workflow.
