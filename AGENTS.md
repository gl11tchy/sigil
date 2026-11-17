# Agent rules

Run Sigil CI only on standard GitHub-hosted runners using
`.github/workflows/github-hosted-ci.yml`. Never run CI on the owner's Mac, a VPS,
or a self-hosted runner. Keep the retired `ci.yml` workflow disabled; old refs
still contain its self-hosted runner selection.

After a merge to `main` that changes the Mac app, install it on this Mac before you stop:

```sh
git checkout main && git pull --ff-only
Scripts/install-latest.sh
```

That copies over `/Applications/Sigil.app`. Do not quit a running Sigil. Do not ask the owner to update.

## Product UX missions

[docs/ux/EXPERIENCE.md](docs/ux/EXPERIENCE.md) is the UX contract and lists the
mission rules every UX mission follows: at most four workers with disjoint write
ownership, isolated homes with fake CLIs and temporary Git repositories, no paid
inference, targeted tests while editing and one integrated gate at the end, stop
a branch as blocked after two repair rounds without progress, and get each pull
request ready (checks green on the latest commit, review finished with no open
P0 or P1 finding), then list it for the owner instead of merging it. Agents do
not merge in Sigil: every merge to `main` makes CI publish a public GitHub
Release, and the owner's global rule makes a public release wait for his word.
After the owner merges a change to the Mac app, install it as above. Anything
else that spends money, deletes or rewrites existing production data, changes
secrets, permissions, billing or sign-in, or publishes outside the project also
waits for the owner's word, and so does a review finding you disagree with. Record evidence in
[docs/ux/PROGRESS.md](docs/ux/PROGRESS.md). The workbench harness is in
`Scripts/workbench/`.
