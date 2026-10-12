# Build identity

`SigilCommit` in the installed bundle is the authoritative source identity:
the full Git commit, with `-dirty` for tracked or untracked source changes, or
`unknown` when the source directory is not its own Git checkout. Edited SwiftPM
dependency checkouts and ignored files under compiled source/resource paths
also mark it dirty, matching the installer input boundary. Generated build
outputs and ignored Finder metadata do not. About Sigil uses the bundle's version, build
and seven-character commit; it retains `-dirty` and renders missing metadata as
`unknown`. It still opens the standard native About panel, and the existing
Close Tab command closes that key window rather than a conversation tab.

CI supplies `SIGIL_BUILD=run_number.run_attempt` to every bundle it builds.
The final ZIP's `CFBundleVersion` determines the `build-N.attempt` release tag;
its version, build and short commit determine the title. The full commit and
ZIP SHA-256 are recorded in the notes. `fetch-depth: 0` remains required.
Local builds may override `SIGIL_BUILD`; otherwise full checkouts use their
commit count and shallow/outside-Git builds use 1. A local count is not unique
across branches and is never treated as source identity.

Both PRs and main check the final ZIP's plist against the checkout SHA and CI
build number. PR ZIPs contain a debug bundle; main retains the existing release
build. Publication requires a clean full commit matching `GITHUB_SHA`. Dirty,
unknown and mismatched artifacts are rejected before any remote mutation.

Before creating a release, the publisher checks authenticated paginated release
listings for a colliding release (including drafts), then checks the source tag.
The by-tag REST endpoint covers published releases; draft visibility requires
the [authenticated list endpoint](https://docs.github.com/en/rest/releases/releases#list-releases).
An existing published release is accepted idempotently only if its metadata,
provenance notes, source tag and downloaded ZIP match exactly. It does not upload, edit Latest or
prune on that path. A different source, ZIP or incomplete draft stops the run;
nothing is overwritten. A new release retains `gh release create`'s upload-before-
publish behavior. Its uploaded ZIP and tag are read back before pruning.

Pruning retains the prior limit of 100 releases and exact allowlist
`latest|build-[0-9]+\.[0-9]+`, excluding the newly verified tag. Other tags remain
untouched. Delete failures retain the previous warning behavior; draft tag
cleanup failure is tolerated only when the release is already gone.

Run the synthetic Git/ZIP/GitHub-boundary checks with:

```sh
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s Scripts/tests -p test_build_identity.py
```

The fixtures exercise clean/dirty/outside-Git/shallow/equal-count source state,
final-ZIP metadata, idempotent reruns, source/artifact collisions, denied reads
and unchanged pruning boundaries. They do not compile or launch an app, use
credentials, publish releases or delete remote data. SigilAppTests run in CI
only; DistributionSigningTests covers the menu/options and native About
display/Close behavior. Release publication on main remains a post-review
validation step; the PR does not claim it has already run.
