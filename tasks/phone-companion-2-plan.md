# Plan: phone companion, second wave

Spec: docs/phone-companion-2-spec.md. Vertical slices, one PR per module group.

## PR 1 — live-stream + session-ops
1. SigilKit: `RemoteScreen` (row model, style runs, diff against the last sent rows), tests.
2. TerminalController: `remoteScreen(window:)` reading absolute rows with attributes; palette from the theme.
3. RemoteCommands: `watch`, `rows`, tab fields, `mac`; RemoteControl: event stream on output/activity, coalesced 100 ms, only while a phone is watching.
4. RemoteCommands: `close`, `rename`, `archive`, `new` with `worktree`; project `repository` flag.
5. Phone: `ScreenModel` (rows by gen, history cap), `StyledText` (runs → attributed, readable mapping), disk cache, event handling, no polling.
6. Phone UI: colours in OutputView, provider in rows, swipe/context actions, rename sheet, worktree toggle.
7. Verify: Mac tests, phone tests, real harness screenshots.

## PR 2 — approvals
1. SigilKit `PromptDetector` table tests (Claude Code, Codex, y/n, none).
2. RemoteCommands `prompt` in state, `answer` action; RemoteControl runs detection on change.
3. Phone answer bar.

## PR 3 — alerts
1. Relay: token registration, `push` frames, APNs client over http2 with ES256 JWT, rate limit, tests with a fake APNs.
2. Mac: `notify`/`activity` actions, pairing store keeps the token, push triggers on turn end / prompt / exit when no phone is live.
3. Phone: permission, token registration, NSE target (sealed payload), Live Activity widget target, foreground updates, tap navigation.
4. Deploy relay with APNs variables; ship TestFlight build.

## PR 4 — multi-mac
1. Credential list in Keychain with migration; per-Mac cache and connection switch.
2. Mac picker in the sessions sheet; Add a Mac; notifications choose the Mac.
