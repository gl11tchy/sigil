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
a branch as blocked after two repair rounds without progress, and no merge,
deployment or app replacement without existing explicit authorization. Record
evidence in [docs/ux/PROGRESS.md](docs/ux/PROGRESS.md). The workbench harness is
in `Scripts/workbench/`.
