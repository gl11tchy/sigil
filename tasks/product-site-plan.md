Skills: using-agent-skills, spec-driven-development, planning-and-task-breakdown, test-driven-development, frontend-ui-engineering, impeccable, security-and-hardening, git-workflow-and-versioning

# Implementation Plan: Product site and Sidereal origin split

ASSUMPTIONS: static `Site/` on Railway for the apex; Sidereal stays `https://remote.sigilapp.dev`; GitHub Releases latest zip is the download; no accounts; no per-user subdomains; Namecheap DNS is owner-only.

## Overview

Split `sigilapp.dev` into a static product site plus docs, and move the Sidereal PWA+relay to `remote.sigilapp.dev`. The Mac default origin and Settings alias map follow the relay. Existing phones scan once. Work lives in `tasks/product-site-*.md` so the in-flight phone-remote `tasks/plan.md` stays untouched.

## Architecture Decisions

- Two Railway services in project `26f52bc8-daae-4371-aa70-4cebb2d0f222`: existing Sidereal, new `site` from `Site/`. Same Node 22 Alpine + allowlisted `node:http` pattern as `Sidereal/server.mjs`.
- Product site is zero-JS HTML/CSS with Sigil Neon tokens already in `DESIGN.md` and `Sidereal/public/style.css`. Screenshot and icon are copies, not hotlinks.
- `preferredOrigin` aliases `https://sigilapp.dev` and the legacy Railway host onto `https://remote.sigilapp.dev`. `origin(_:)` stays a format check. Retired Keychain origins do not auto-resume (PWA origin changed). Pairing-persist is unchanged for records already on `productionOrigin`.
- Download is a plain navigation to `https://github.com/gl11tchy/sigil/releases/latest/download/Sigil.zip`. No zip proxy.
- Cutover is ordered: remote host healthy → site service healthy → owner DNS → then ship the Mac default. Do not point `PUBLIC_ORIGIN` at the apex after the site owns it.
- Branch: `feature/product-site`. One logical commit per task. `Scripts/verify.sh` before the PR. Attribution `gl11tchy` only.

## Task List

### Phase 1: Origin split

- [ ] Task 1: Failing native tests for `productionOrigin`, alias remap, and retired-origin resume.
- [ ] Task 2: Remap in `RemoteControl.start` / resume; keep pairing-persist for the new origin.

### Checkpoint: Origin

- [ ] `swift test --no-parallel --filter RemoteCommandsTests` and `--filter RemoteControlTests` pass.
- [ ] A stored `https://sigilapp.dev` pairing does not resume. A stored `https://remote.sigilapp.dev` pairing still does.

### Phase 2: Product site

- [ ] Task 3: Failing Site HTTP tests and allowlisted static server with stub pages.
- [ ] Task 4: Landing page (claim, screenshot, zip, pairing steps).
- [ ] Task 5: `/docs` page (install, requirements, keyboard, pairing, limits).

### Checkpoint: Site

- [ ] `npm --prefix Site test` passes.
- [ ] Local `/` and `/docs` at 320 / 768 / 1024 / 1440: keyboard, AA tokens, no console errors.
- [ ] `/rooms` and `/connect` 404.

### Phase 3: Gate and copy

- [ ] Task 6: `Scripts/verify.sh`, `.gitignore`, CI npm cache for `Site/`.
- [ ] Task 7: User-facing URLs in README, Sidereal README, and `docs/remote-control.md` (intended hosts; live IDs wait for cutover).

### Checkpoint: Gate

- [ ] `Scripts/verify.sh` passes (Site + Sidereal + Swift + smoke).
- [ ] Repo copy never tells a visitor to pair at the apex.

### Phase 4: Host

- [ ] Task 8: Site Dockerfile and `/health`.
- [ ] Task 9: Railway `site` service deploy to a `*.up.railway.app` hostname (not the apex yet).

### Checkpoint: Host

- [ ] Railway deployment SUCCESS. Railway hostname serves `/`, `/docs`, `/health` and 404s `/rooms`.

### Phase 5: Cutover

- [ ] Task 10: Owner Namecheap — `remote.sigilapp.dev` → Sidereal, apex → site. Agent prints Railway DNS records only.
- [ ] Task 11: Sidereal `PUBLIC_ORIGIN=https://remote.sigilapp.dev`, custom domains, live GET proof, then merge.

### Checkpoint: Complete

- [ ] Production GETs match the spec success criteria.
- [ ] `SIGIL_REMOTE_TEST_ORIGIN=https://remote.sigilapp.dev swift test --no-parallel --filter RemoteIntegrationTests` if the agent can reach the host.
- [ ] PR opened only after verify and live proof. No second Codex round.

## Parallelization

Safe together: Task 1–2 with Task 3–5 on one branch, different files. Sequential: Task 6 after Site tests exist; Task 9 after Dockerfile; Task 11 after Task 10 DNS.

## Risks and Mitigations

| Risk | Impact | Mitigation |
|------|--------|------------|
| Apex flipped before remote is healthy | High | Spec cutover order; Mac default does not merge until `https://remote.sigilapp.dev/health` is ok |
| Auto-resume of apex Keychain pairing | High | Resume skip for rewritten origins; phone scans once |
| Site looks like generic AI landing | Med | Locked Sigil Neon tokens, real screenshot, no card grid, zero JS |
| `tasks/plan.md` overwritten | High | This file is `tasks/product-site-plan.md` only |
| Namecheap mistake | High | Owner-only DNS; agent never logs into Namecheap |

## Open Questions

None.
