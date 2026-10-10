# Stamped Site and Sidereal uploads

Run the applicable verification checks before a separately authorized rollout.
From the repository root, use either wrapper with explicit Railway UUIDs and the
service's existing HTTPS health URL:

```sh
Scripts/deploy-site.sh \
  --project <project-id> --environment <environment-id> --service <service-id> \
  --health-url https://<site-host>/health

Scripts/deploy-sidereal.sh \
  --project <project-id> --environment <environment-id> --service <service-id> \
  --health-url https://<relay-host>/health
```

The same options can come from `SIGIL_DEPLOY_PROJECT_ID`,
`SIGIL_DEPLOY_ENVIRONMENT_ID`, `SIGIL_DEPLOY_SERVICE_ID`, and
`SIGIL_DEPLOY_HEALTH_URL`. Arguments take precedence. Names and implicit linked
targets are refused. Do not place tokens in arguments or commit CLI credentials.
The scripts use the caller's existing Railway authentication; they do not log CLI
output, link projects, create domains, or change service variables.

## Source and destination checks

Both wrappers fetch `origin/main` and require HEAD to equal the fetched revision.
The whole checkout must be clean, including untracked files. An intentional dirty
upload requires `SIGIL_ALLOW_DIRTY=1`; an intentional non-main upload separately
requires `SIGIL_ALLOW_NON_MAIN=1`. These overrides leave the actual Git HEAD and
dirty state in the stamp. They never bypass destination verification.

The flow checks project, environment and service identities using scoped
`railway status --json`. It also requires the service instance in that environment
and an exact health hostname from scoped `railway domain list --json`.
Unsupported CLI options, missing metadata or an unlisted hostname stop before
upload. Use a CLI supporting these read-only commands; bare `railway domain`
creates a domain and is never a fallback.
The required shapes follow the official CLI's
[status command](https://github.com/railwayapp/cli/blob/master/src/commands/status.rs)
and [domain list command](https://github.com/railwayapp/cli/blob/master/src/commands/domain.rs).

The URL must use HTTPS and the exact `/health` path, without credentials, query,
fragment or a nonstandard port. Redirects are refused. Generated tests may use
HTTP loopback with `SIGIL_DEPLOY_ALLOW_LOOPBACK=1`; that override still requires
the destination to appear in the fake CLI's scoped domain metadata.

## One staged identity contract

`Site/runtime-manifest.json` and `Sidereal/runtime-manifest.json` enumerate the
flat runtime/build files and recursive public directories. `runtimeFiles` in
`Sidereal/revision.mjs` drives both staging and SHA-256 hashing. The manifest,
Dockerfile, package metadata and lockfile, server, revision loader and every public
file enter the hash. Sidereal also includes its APNs module. Paths and byte lengths
frame the sorted file contents, so file boundaries cannot alias one another.
Ignored inputs, symlinks and special files are rejected before upload.

`Scripts/deploy-service.mjs` copies these inputs into a fresh temporary directory.
Both bundles receive the canonical `Sidereal/revision.mjs` loader as
`revision.mjs`; Site's checkout adapter serves local development only. The hash
describes these actual staged bytes. No Git metadata, dependency directories,
tests or unrelated checkout files are included by the current manifests.

`revision.json` contains `revision`, `gitSHA`, `dirty`, and `sourceSHA256`. Dirty
source adds `-dirty` to the revision; the hash distinguishes staged bytes even at
the same commit. The stamp itself is excluded from its hash. Docker validates the
stamp during the build and again at server startup with
`SIGIL_REQUIRE_REVISION=1`. Missing, malformed or stale stamps stop production
startup. The stamp CLI retains its realpath guard for `/tmp` and symlinked entry
points.

For a manual image build, stage into a new empty directory before building that
directory. From the repository root, this prepares a Site bundle without uploading:

```sh
stage="$(mktemp -d "${TMPDIR:-/tmp}/sigil-site-build.XXXXXX")"
node --input-type=module -e \
  'import { stageBundle } from "./Scripts/deploy-service.mjs"; await stageBundle("site", process.argv[1]);' \
  "$stage"
docker build "$stage"
```

Use `"sidereal"` to stage the relay. Local staging alone does not run the release
source/destination checks. A raw Site checkout is not the stamped image layout.
Sidereal's existing `npm --prefix Sidereal run stamp` also supports its flat manual
build layout; re-stamp after any runtime or Dockerfile change.

## Completion and limits

The wrappers upload once with an explicit project, environment and service, then
poll only the verified health URL. Exit zero requires status `ok` and exact matches
for all four stamp fields, including the commit and source hash. A previous
revision may appear while the rollout starts. Unreachable, redirected, oversized,
malformed or mismatched health fails without a second upload.

Polling has a monotonic five-minute deadline; each request is capped at ten
seconds and the remaining deadline. `SIGIL_DEPLOY_TIMEOUT_SECONDS` can shorten the
deadline to an integer from 1 through 300, never extend it. The owned staging
directory is removed on success or failure.

`GET /health` returns cheap, no-store JSON with `status: "ok"` and the stamp. An
unstamped local checkout reports `revision: "development"` and null identity
fields. A matching stamp proves running source identity. It does not prove relay
pairing, push delivery, Site assets, phone behavior or operational health. Record
those separately during an authorized rollout. REA-1248 owns future CI deployment
wiring; these scripts do not schedule or enable production deployments.
