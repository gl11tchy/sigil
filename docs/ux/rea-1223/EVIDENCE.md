# REA-1223 evidence

Base: `9be7470ce8f66bd6f866b48f449bfa0bf221201f`, checked against GitHub main.
Ticket: https://linear.app/reasonable-glyph/issue/REA-1223/open-new-session-without-re-checking-all-six-clis-every-time

## Native checks

The renamed ad-hoc debug bundle `Sg1223Native.app`, ID
`com.gl11tchy.sigil.rea1223.native`, used a generated temporary home and six
fake CLIs. The synthetic shell fails closed when a fake executable is missing;
it cannot fall through to installed CLIs. No inference, personal histories,
Keychain access, daily-app installation or front-app keystrokes were used.
Temporary, uncommitted fixture code enabled the ordinary startup/entry checks
while retaining test-mode in-memory credentials and unrelated startup guards.
It seeded a synthetic project, explicit default provider/worktree preferences,
and Grok model `saved-synthetic-model` / effort `high`.

- Current-main reproduction: another New Session performed all six probes.
  See [baseline counts](baseline-counts.json).
- Revised app: all six startup checks succeeded; another New Session added zero
  probes while the results were fresh. See [counts](cache-counts.json).
- One Claude click opened the real PTY running its fake CLI. AX reported
  `FOCUSED | AXTextArea | Claude Code terminal` after launch.
- Return to session restored the existing terminal. Opening Options and Cancel
  returned to inline entry without launching a CLI.
- A Grok click retained the selected generated project and passed
  `--model saved-synthetic-model --reasoning-effort high`. Native receipt files
  include only generated paths and arguments.
- Moving the fake Codex executable aside required exactly one replacement shell
  check. Codex became disabled with an explicit missing-executable reason;
  the other five providers stayed available. See [counts](missing-counts.json).

## Visual review

[Dark](native-dark.png), [light](native-light.png), and
[unavailable Codex](native-unavailable.png) are native window-ID captures,
not image-renderer mockups. All inline glyphs use existing monochrome paths,
the selected terminal theme's actual background, and restrained inset depth.
Names/status use normal text contrast; the keyboard ring and glyph edge are
stronger on focus. The parent reviewed and approved both dark/light captures
from the initial PR head. The functional remediation below awaits code
re-review; the glyph treatment and screenshot files are unchanged.

## Automated validation and limits

Local: three bounded `ProviderInstallationTests` passed, production/debug build,
strict Swift format lint and `git diff --check`. AppTests were compiled but
were not run locally; they open windows and run only in ordinary PR CI.

Focused AppTests cover the five-minute boundary, coalescing, forced refresh,
missing executable, timeout-result recheck on a user request, path round-trip
invalidation, stale/cancelled callbacks, restoration with a fresh later provider,
first-use CLI defaults and worktree preference, saved choices, active project,
inline cancel/return/options, and terminal focus. Existing launch-safety tests
remain. This evidence is synthetic; it establishes no customer impact,
authentication, entitlement or paid-provider correctness. VoiceOver speech,
physical keyboard driving, and arbitrary installed/custom terminal themes were
not exercised natively.

REA-1250 owns automatic timeout retries/classification. REA-1261 retains Settings
CLI inventory and expanded default selection. REA-1225 retains worktree rollback
and missing-subfolder validation; this uses the existing worktree policy.

The initial workspace-home fixture timed out before reaching its fake scripts;
the cause was not established. A fresh temporary runtime reached them and passed.
A later missing-file replay initially disabled its own test-enabling guard; that
fixture guard was latched and the shell made fail-closed before replay passed.

## Launch recovery remediation

Remote new/open/restart and Options now start or join a bounded, coalesced
routine check before launch, then revalidate availability, executable existence
and cancellation. A cancelled waiter leaves another request's check running;
configuration changes and superseded generations cannot authorize a launch.
Remote options refresh before reporting inventory. Options keeps the chosen
folder/model/effort while checking and cancels its launch task on disappearance.
Idle stale/unknown status says a check is required; only pending work says
Checking. A missing executable becomes an explicit unavailable result.

Added CI-only tests cover remote new/open/restart at the five-minute boundary
and after executable disappearance, recovery on a later request, joined and
cancelled requests, remote options, Options left open with chosen overrides,
closed/cancelled Options and a restart target closed during a check.

The first ordinary CI run at `af238c7` ran 1,021 tests and failed with seven
focus assertions in two tests. The cancel-focus test now uses a key-window
stand-in, matching AppModel's key-window requirement. Initial empty entry keeps
the established startup key-view loop instead of competing with it; an explicit
New Session or return from Options still focuses the provider row. Existing
startup focus coverage remains intact for the next CI run.

Remediation validation: app and test targets compiled, three bounded Kit tests
passed, and strict format/diff checks passed locally. These new AppTests have
not run locally. No additional native UI replay was performed for remediation;
the parent will re-review and verify ordinary CI on the new exact head.

## CI assertion correction and bounded native attempt

CI `38036421159` at `6790ecb` ran 1,027 tests and reported four assertions in
the remote expiry/disappearance test. These were test assumptions: an open
returned the same filesystem directory with a directory-URL trailing slash,
and restarting a background tab retained the selected live Grok tab, as the
existing restart contract requires. The test now checks the reply's actual
replacement ID, provider, session identity, position, unchanged background
selection and canonical working path. Pending/failure probe counts, no-launch
assertions and existing-live-process coverage remain intact. Production launch
code and the glyph treatment were unchanged for this correction.

The upload-evidence step found no `*.xcresult` because Verify failed before the
iPhone/native-relay step ran. That step was confirmed skipped; the unconditional
upload then had no generated files. No workflow or storage change was made.

A requested inexpensive Options native check built a renamed debug bundle
with a fresh generated home, fake CLIs and an opt-in controllable five-minute
clock. Temporary fixture source was removed after build. Startup version
checks reached all six fake CLIs, but the owned window was off-screen, AX exposed
no usable controls, and a window-ID capture could not create an image. A single
bounded relaunch reproduced that state; its cause was not established. The
fixture was stopped. Options Start was not exercised and no native success or
new screenshot is claimed. The daily app was untouched; AppTests remain CI-only.
After the assertion correction and fixture removal, app/test targets compiled,
three bounded Kit tests passed, and strict format/diff checks passed locally.
