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

Focused editing gate: `node --test Site/test/deploy.test.mjs Site/test/revision.test.mjs`
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

Final affected-service gate:

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
