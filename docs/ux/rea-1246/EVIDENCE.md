# REA-1246 implementation evidence

Ticket: [REA-1246](https://linear.app/reasonable-glyph/issue/REA-1246/give-the-site-a-stamped-deploy-script-and-a-revision-on-health).
Base: `be90c2544792a9538e279ada89672c0b3476224b` (fresh `origin/main`).
Worktree: `sigil-rea-1246`; branch: `fix/rea-1246-stamped-deploy`.

## Reproduction

Before edits, a generated dirty, non-main Git repository ran the original
Sidereal wrapper with a fake Railway executable. It exited zero after one upload
without requesting health. Site had no deployment wrapper. The existing Site
tests passed, then the new JSON health assertion failed against the bare `ok`
response. These are synthetic implementation reproductions, not observations of
either running production service.

## Implemented scope

Both wrappers now share staging, source checks, scoped target/domain verification,
one upload and bounded identity polling. The new Site health shape matches
Sidereal's revision contract, and both Docker recipes require a valid stamp.
Per-service manifests drive staging and hashing; both bundles receive one
canonical loader. The [deployment contract](../../deployment.md) documents the
source overrides, environment options, CLI requirements and manual image layout.

## Verification

Initial focused editing gate: `node --test Site/test/deploy.test.mjs Site/test/revision.test.mjs`
passed all 32 tests. Coverage includes:

- Both real shell wrappers with a fake CLI in an isolated home and a local Git
  remote: exact UUID arguments, dirty/non-main refusal and explicit overrides,
  stamped runtime-only uploads, one upload and staging cleanup.
- Wrong project/environment/service/instance, denied/deleted environment, wrong
  domain and malformed CLI metadata; all stop before upload or health requests.
- Credential-bearing URLs, query/fragment/path/scheme/port errors, duplicate and
  unsupported flags, invalid deadlines, and an upload failure. Synthetic secret
  sentinels in CLI errors and URLs never reach command output.
- Wrong commit or hash, redirects, malformed/oversized bodies, stalled and
  unreachable health; each fails after one upload. A previous revision followed
  by the uploaded identity succeeds without another upload.
- Ignored runtime files and generated symlinks refuse upload. Site starts from a
  stamped bundle without Git and serves the exact no-store identity. Missing or
  malformed production stamps fail startup. Every staged file, manifest and
  Docker recipe affects the hash; unused files do not.

Sidereal's focused revision gate passed all eight tests, including copied-bundle
health, stale/invalid stamps, Dockerfile-only changes and the stamp entry point
under a symlink with and without `--preserve-symlinks-main`.

Initial affected-service gate:

| Command | Result |
| --- | --- |
| `npm --prefix Site ci --ignore-scripts` | Passed; unchanged lockfile |
| `npm --prefix Sidereal ci --ignore-scripts` | Passed; unchanged lockfile |
| `npm --prefix Site test` | 50 passed, zero failed/skipped |
| `npm --prefix Sidereal test` | 187 passed, zero failed/skipped |
| `shellcheck Scripts/*.sh` | Passed, including both deployment wrappers |
| `bash -n Scripts/deploy-site.sh` | Passed |
| `bash -n Scripts/deploy-sidereal.sh` | Passed |
| `node --check Scripts/deploy-service.mjs` | Passed |
| `git diff --check` | Passed |

The first complete Site run exposed a copied-server cache fixture that omitted
the new revision loader. That fixture now copies the canonical loader; the
complete repeat passed all 50 tests, including the eight existing static-cache
checks. No cache or asset-serving implementation change was needed.

Self-review covered the whole ticket diff against fresh `origin/main`; main
remained `be90c2544792a9538e279ada89672c0b3476224b`. Only this ticket's service,
deployment, test and documentation files changed. Known parked branches were
preserved. The ordinary exact-head PR CI gate is reported on the PR; local results
do not substitute for it.

## Parent review remediation

Parent review of `0bed7546d36fd7870b71527a8eccd72f25946873` identified the two
stale production commands in `docs/remote-control.md` and the staging race in
[discussion_r4237436146](https://github.com/gl11tchy-team/sigil/pull/146#discussion_r4237436146).
The commands now use their respective wrappers and documented health origins:
`https://remote.sigilapp.dev/health` and `https://sigilapp.dev/health`. Existing
project/environment/service IDs and historical deployment receipts are unchanged.
These are runbook corrections; the commands were not executed.

Six deterministic regression cases ran against the reviewed implementation: a
tracked runtime edit, an untracked runtime edit, and an added untracked runtime
file for each service. A test-only filesystem preload changes a generated input
immediately after a staging copy and records an acknowledgement. All six initially
failed because the old flow uploaded and exited zero. Both dirty booleans remained
true; the tracked and existing-untracked cases also retained identical Git status
text. No timer race or live provider was involved.

The shared stager now records manifested file names and bytes before copying,
compares each staged copy with those bytes, then re-enumerates and re-reads source
inputs after stamping. Persistent changes refuse before upload, including changes
to untracked public inputs. Existing HEAD/dirty guards and explicit overrides
remain. Unchanged dirty tracked and untracked inputs still upload with the
override, and the fake CLI captures their exact staged bytes.

Latest review-fix checks:

| Command | Result |
| --- | --- |
| `node --test --test-name-pattern='runtime input.*staging\|unchanged dirty' Site/test/deploy.test.mjs` | Eight passed, zero failed/skipped |
| `npm --prefix Site test` | 58 passed, zero failed/skipped |
| `npm --prefix Sidereal test` | 187 passed, zero failed/skipped |
| `shellcheck Scripts/*.sh` | Passed |
| Separate `bash -n` checks for both wrappers | Passed |
| `node --check Scripts/deploy-service.mjs` | Passed |
| `node --check Site/test/deploy.test.mjs` | Passed |
| `git diff --check` | Passed |

The comparison uses bounded filesystem reads, not a transaction or filesystem
lock. Transient changes restored between reads and edits after the final
comparison are outside this check. All race inputs, mutation acknowledgements,
CLI homes, Git remotes and HTTP endpoints were generated fixtures. No actual
deployment, authenticated Railway call, CI rerun or native application check ran.
Fresh main remained `be90c2544792a9538e279ada89672c0b3476224b`; unrelated
worktrees and the daily app were preserved. The same normal PR receives one
complete follow-up push and stops for personal final review and ordinary CI.

## Limits and excluded work

All HTTP tests bind generated loopback servers. Deployment tests replace Railway
and use empty CLI homes and local fixture Git remotes. No real Railway command,
production health request, upload, variable change, credential change or domain
creation ran. CLI compatibility was checked against public official source; the
installed authenticated CLI and real target metadata remain unverified here.

No Docker image was built. Local tests use Node `v26.4.0`; ordinary PR CI uses
Node 22 and remains a separate exact-head gate. The five-minute maximum is
enforced in code; fixtures shorten deadlines to one or three seconds.

Native Swift/AppTests, GUI smoke, browser/device checks and the complete native
`Scripts/verify.sh` were not run locally: the parent authorized focused Node/shell
checks for this service-only ticket, and AppTests are CI-only. The daily Sigil
application and parked worktrees were preserved. No merge or distribution ran.
Matching source identity does not establish operational health. A real rollout
and REA-1248's future CI deployment wiring remain separate work.
