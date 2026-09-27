# Implementation Plan: Phone remote that you can actually use

Skills: using-agent-skills, impeccable, frontend-ui-engineering, planning-and-task-breakdown, spec-driven-development, test-driven-development, incremental-implementation, write-swift, security-and-hardening, apple-design, git-workflow-and-versioning

ASSUMPTIONS: Readable companion, not a pixel TUI. Attach writes to SigilDrops and pastes a path, same as Mac drag-drop. Visual lane is Sigil Neon. Image-gen mocks skipped: DESIGN.md is the contract and the screenshot is the defect.

## Architecture Decisions
- Strip the current Grok 4.6 composer (`Shift+Tab:mode`, `| >`, stacked rules) and collapse space-padded TUI rows that wrap into a black void on a phone.
- `file` action carries base64 chunks under the existing 64 KB plaintext / 100 KB frame caps. Mac assembles, writes, pastes the path.
- One attach control uses the iOS file sheet (library, camera, Files).

## Task List

### Phase 1: Readable output
- [x] Task 1: Failing tests for the live Grok 4.6 footer and space-padded rows.
- [x] Task 2: `readableOutput` strips that chrome and keeps drafts.

### Phase 2: File upload
- [x] Task 3: Failing tests for chunk assembly, size, names, and PTY paste.
- [x] Task 4: `file` action + `RemoteUpload` + `TerminalDrop.writeRemoteFile`.

### Phase 3: Phone UI
- [x] Task 5: Attach, chips, Stop while working, composer layout.
- [x] Task 6: Playwright + native tests. Evidence: `tasks/verify.md`.
- [x] Task 7: Redeploy Sidereal and record the revision. The active deployment,
  `c5c7e7de-76a8-44d0-8d89-a1fdbe349ce2`, postdates #43 by under a minute, but the service
  deploys from local uploads, so it carries a snapshot id and no SHA and nothing proves what
  is in it. Local-upload stamping is now implemented: `Scripts/deploy-sidereal.sh`
  packages a Git SHA, dirty flag, and runtime hash; `/health` exposes and validates it.
  Closing Task 7 still needs a coordinated live Mac/relay/PWA release and the matching
  health response. The follow-up release request authorizes deployment after PR review and merge.
  Done 2026-09-23: #66 records the deploy, and `/health` reports revision 199cc86.

## Risks
| Risk | Mitigation |
|------|------------|
| HEIC decode fails in Safari | Fall back to original bytes if ≤ 4 MB |
| iOS PWA stale cache | Bump service-worker cache name |
| Chunk DoS | 4 pending transfers, 4 MB, 128 chunks, 60 s expiry |

## Remote-stack hardening (A → B → C)

- [x] A: Node/Swift adversarial tests and stale-epoch reply drop. Full `Scripts/verify.sh` passed before B.
- [x] B: First sealed routing envelope, no URL tickets/room IDs, no-query logging policy. Full `Scripts/verify.sh` passed before C.
- [x] C: Stamped upload bundle and revision-bearing `/health`; full `Scripts/verify.sh` passed.

Evidence: `tasks/remote-hardening-verify.md`.

Release follow-up: open the PR, clear CI and automated review, squash merge, install
the merged Mac build, then deploy the matching stamped relay/PWA and verify production.

# Product correctness and continuity — 2026-09-27

Skills: using-agent-skills, planning-and-task-breakdown, git-workflow-and-versioning,
code-review-and-quality, security-and-hardening, incremental-implementation,
test-driven-development, write-swift.

## Baseline and scope

Start at `be13238`, equal to fresh `origin/main`; its CI succeeded. Preserve the
terminal-first interface, existing providers and all CLI-owned history. Deliver
one integration PR; do not merge, install over the running app, or deploy.
Prior completed plans above remain historical evidence, not current acceptance.

## Ordered work and ownership

1. Approval identity and dispatch: exact operation and choices, host-owned
   interaction lifetime, consume-before-dispatch, conservative raw controls where
   no provider request broker exists. Verify detector, real PTY dispatch, races,
   replacement, duplicate and wrong-session tests. Approval worker owns prompt,
   interaction, terminal revision and approval command code.
2. Provider contracts and lifecycle: small native identity/capability model,
   version-isolated history readers, genuine CLI resume, no title/silence success.
   Verify installed help, official sources, fixtures and process tests. Provider
   worker owns SigilKit provider/history and TerminalTab lifecycle.
3. Integrate continuity and remote: parent owns AppModel, web companion,
   notifications, reconnect freshness, target-bound uploads and documentation.
   Verify preserved snapshots, unsupported actions, relay and browser journeys.
4. Native product gate: native worker owns complete simulator app + embedded
   extensions, actual native tests, shared relay tests and CI. Include phone
   operation context and capability consumption with shared wire contracts.
5. After integration: benchmark at least 900 conversations and concurrent tabs,
   independent review, repair findings, run full local CI commands, then push
   one branch and open one PR. Record all verification boundaries accurately.

## Shared contracts

- Provider-native identity contains provider, native session ID and project path.
- Grok IDs remain stable; non-Grok list IDs are provider-qualified.
- Capabilities are authoritative data, not inferred from a non-nil session ID.
- Terminal text is untrusted. Missing authoritative approval support never claims
  verified structured approval. Raw input remains clearly labeled.
- New event frames carry a monotonically increasing eventSequence, scoped to the
  authenticated connection challenge; legacy hosts use request/reply polling.
- No offline command queue, blind retry, paid model calls or production changes.

## Checkpoints

- Baseline tests and native build recorded separately from introduced failures.
- Core implementation integrated before independent review.
- Full verification and self-review before the single integration push.
