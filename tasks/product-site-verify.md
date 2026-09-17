# Product-site verification

Not live. DNS is owner-only. Do not treat this as a production cutover.

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

## Owner DNS (not done)

Do not flip the apex until `remote.sigilapp.dev` is healthy Sidereal.

1. Namecheap CNAME `remote` → `1bkrlt5p.up.railway.app`.
2. Namecheap TXT `_railway-verify.remote` → `railway-verify=fcc2e74a0b9e02bcb9504509004d7d783853f0086368e85cf4cbe618262558a8`.
3. After `https://remote.sigilapp.dev/health` is `ok`, set Sidereal `PUBLIC_ORIGIN=https://remote.sigilapp.dev`.
4. Then move the apex ALIAS for `sigilapp.dev` onto the Site service.

Agent cannot change Namecheap. Apex still serves Sidereal. Do not merge the Mac default origin until step 3.
