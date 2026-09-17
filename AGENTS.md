# Agent rules

After a merge to `main` that changes the Mac app, install it on this Mac before you stop:

```sh
git checkout main && git pull --ff-only
Scripts/install-latest.sh
```

That copies over `/Applications/Sigil.app`. Do not quit a running Sigil. Do not ask the owner to update.
