# Product-site verification

DNS is owner-only, and it is now applied: both hosts are verified custom domains in
Railway. What is still unproven is which Sidereal revision is running. See the
"Owner DNS" section below.

Skills: using-agent-skills, planning-and-task-breakdown, test-driven-development, code-review-and-quality, git-workflow-and-versioning

## Checks

| Check | Result |
| --- | --- |
| `RemoteControl.productionOrigin` | `https://remote.sigilapp.dev` |
| `preferredOrigin` rewrites `https://sigilapp.dev` | yes, to `productionOrigin` |
| `preferredOrigin` rewrites `https://sidereal-production-587c.up.railway.app` | yes, to `productionOrigin` |
| `Site/` with `Site/test/site.test.mjs` | present |
| `Scripts/verify.sh` runs Site `ci` / `test` / `audit` | yes |
| `tasks/plan.md` / `tasks/todo.md` | not overwritten (still the phone-remote plan) |
| Commit | none (working tree still dirty) |

## Commands

Site `node_modules` was missing, so install ran first.

```
npm --prefix Site ci --ignore-scripts && npm --prefix Site test
```

Exit code: **0**. 7 tests, 0 fail.

```
swift test --no-parallel --filter RemoteCommandsTests.qrIsDecodableAndURLValidationIsStrict
```

Exit code: **0**. `qrIsDecodableAndURLValidationIsStrict` passed.

`Scripts/verify.sh` exit code **0** (`==== verify: PASS ====`). 429 Swift tests, Site 7/7, Sidereal unit + browser, format lint, debug bundle, smoke launch.

Site Railway deploy `e2146cb5-ee2e-4e6d-bde7-d37b2f85a625` is SUCCESS.

```
curl -fsS https://site-production-c4d1.up.railway.app/health
```

Body `ok`. `/` is the product page with the zip href. `/docs` is 200. `/rooms` GET and POST are 404.

Playwright: local and live `/` and `/docs` at 390px and 1280px. Docs click round-trips. No console errors. No horizontal overflow at 390px.

## Owner DNS

Steps 1, 2 and 4 are done. Checked against Railway on 2026-09-19; the container has no
egress to either host, so this records Railway's own view of each domain and not a `curl`.

1. Namecheap CNAME `remote` → `1bkrlt5p.up.railway.app`. Applied. Railway reports the
   record propagated and matching, ownership verified, certificate valid.
2. Namecheap TXT `_railway-verify.remote`. Applied; Railway no longer lists a pending
   verification record for the domain.
3. Sidereal `PUBLIC_ORIGIN=https://remote.sigilapp.dev`. **Open.** The variable exists on
   the service, but a connected Railway app is served variable names without values, so its
   current value cannot be read back from here.
4. Apex `sigilapp.dev` moved onto the Site service. Applied. It is a custom domain on
   service `060788b3-4ab1-45fb-8623-68027835cbc0`, ownership verified, certificate valid,
   and it is no longer attached to Sidereal. An apex alias exposes no readable CNAME value,
   so the issued certificate is the evidence that it resolves to Railway.

Still open, and tracked as Task 7 in `tasks/plan.md`: the Sidereal service deploys from
local uploads, so its deployments carry a snapshot id and no commit SHA. Nothing readable
from Railway says which revision is live.
