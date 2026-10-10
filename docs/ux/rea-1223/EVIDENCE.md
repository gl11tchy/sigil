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
stronger on focus. Parent visual approval is still required before merge.

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
The attempted direct screenshot notification to parent thread
`01a118da-e3a1-724f-8643-93bb2be6c0e8` returned `thread not found`.
