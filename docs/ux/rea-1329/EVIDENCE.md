# REA-1329: installed Grok discovery and recovery

Base: `c7e753405735c91fd0602e896c89554ebc912e25`.

The owner reported an outdated-Grok notice despite their normal Grok being
current. We did not inspect personal CLI state or reproduce that customer
environment. Generated fixtures reproduce the source-level precedence defect:
main selected `grok-sigil 1.0.0 synthetic-themed` while normal host and installer
Grok both reported `2.0.0`.

## Before and after journey

| Situation | Before | After |
|---|---|---|
| First use; current host Grok and stale themed copy | Separate themed copy won automatically. | Login-shell `grok` wins; Settings shows Installed Grok and its checked path/version. New, resume and restart use that checked path. |
| Old automatic installer/themed path | Could resolve or migrate to the separate themed copy. | Known unchosen defaults restore as installed discovery. |
| Explicit themed/custom path, including a missing file | Explicit choice persisted; recovery required editing its path. | Choice still persists. Settings shows Custom executable, the checked version/problem, Choose…, and Use Installed Grok. Missing custom paths stay failed. |
| Return to installed Grok | No explicit automatic-mode recovery control. | Use Installed Grok clears the override and triggers discovery. Focus loss cannot recommit the removed custom field. |
| Failed or expired check | Check could be repeated from the New Session flow. | Grok Settings also offers Check Again; its targeted check leaves other fresh providers usable. Existing terminals keep running. |

The table describes implemented source behavior. It is not an observed app/AX
walkthrough or evidence that the owner's personal installation was repaired.

## Local evidence and limits

Evidence receipts are in the task's external `rea-1329-evidence` directory:

- Baseline production-source fixture compiled with the installed Xcode SDK and
  reproduced stale themed-copy precedence. Only generated executables ran.
- A standalone native probe compiled ten complete production SigilKit files in
  Swift 6 mode, without stubs. All 16 selection, migration, discovery and checked
  launch checks passed. Compile: 4.112 seconds within 60; execution: 0.719 seconds
  within 15. Source hashes and receipts are retained.
- The isolated, Kit-only SwiftPM attempt stopped at manifest startup:
  `sandbox-exec: sandbox_apply: Operation not permitted`. No tests executed. No
  sandbox bypass, broader permission retry or local SigilAppTests followed.
- Changed Swift files passed syntax parsing, strict formatting and whitespace
  checks before the PR. Added AppSettings and AppModel tests run only in CI.
- No renamed app build/AX walkthrough/window-ID screenshot was possible through
  the blocked local build route. Settings layout and native recovery interaction
  remain app acceptance limits; unit and probe evidence do not replace them.

The ordinary exact-head PR workflow is the integrated gate. Its final result is
recorded on the PR and in the external review receipt. Parent personal review is
required before merge. The worker has not merged, installed or replaced Sigil,
run real prompts, read private histories, or changed credentials/access.
