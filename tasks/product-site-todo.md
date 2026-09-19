# Tasks: Product site and Sidereal origin split

Spec: `tasks/product-site-spec.md`. Plan: `tasks/product-site-plan.md`.
Do not edit `tasks/plan.md` or `tasks/todo.md`.

## Task 1: Failing origin tests

**Description:** Write failing Swift tests for the new production origin, alias remap, and retired-origin resume skip.

**Acceptance criteria:**
- [ ] `productionOrigin` is expected to be `https://remote.sigilapp.dev`.
- [ ] `preferredOrigin` maps `https://sigilapp.dev` and `legacyRailwayOrigin` onto it; leaves `productionOrigin` and `https://example.com` unchanged.
- [ ] `origin` still rejects userinfo, query, fragment, non-root path, and non-loopback HTTP.
- [ ] A Keychain/in-memory pairing stored at `https://sigilapp.dev` does not `resumeIfPaired` and does not restore as paired when starting at `productionOrigin`.
- [ ] Tests fail on current `main` before Task 2.

**Verification:**
- [ ] `swift test --no-parallel --filter RemoteCommandsTests` fails on the new assertions.
- [ ] `swift test --no-parallel --filter RemoteControlTests` fails on the new resume assertion.

**Dependencies:** None

**Files likely touched:**
- `Tests/SigilAppTests/RemoteCommandsTests.swift`
- `Tests/SigilAppTests/RemoteControlTests.swift`

**Estimated scope:** S

## Task 2: Origin remap

**Description:** Point the Mac at the Sidereal host. Apply `preferredOrigin` in `start(urlText:)`. Do not auto-resume pairings whose origin is rewritten. Leave ticket/crypto/Keychain schema alone.

**Acceptance criteria:**
- [ ] `RemoteControl.productionOrigin == "https://remote.sigilapp.dev"`.
- [ ] Settings default and `onAppear` remap still use `preferredOrigin`.
- [ ] Retired origins do not resume; a pairing already at `productionOrigin` still resumes with no QR.
- [ ] Task 1 tests pass.

**Verification:**
- [ ] `swift test --no-parallel --filter RemoteCommandsTests`
- [ ] `swift test --no-parallel --filter RemoteControlTests`

**Dependencies:** Task 1

**Files likely touched:**
- `Sources/SigilApp/RemoteControl.swift`

**Estimated scope:** S

## Checkpoint: Origin

- [ ] Native origin tests pass.
- [ ] Pairing-persist still holds for `https://remote.sigilapp.dev` records.

## Task 3: Site server and failing HTTP tests

**Description:** Add `Site/` with a Sidereal-style allowlisted static server, stub `public/index.html` and `public/docs/index.html`, and a `node:test` suite that encodes the spec contracts. Tests fail until Tasks 4–5 fill the pages.

**Acceptance criteria:**
- [ ] `createSite({ publicOrigin })` serves allowlisted GET routes only.
- [ ] `GET /health` is `ok`. `GET /rooms`, `GET /connect`, `GET /app.mjs`, `POST /rooms` are 404.
- [ ] Security headers: CSP with `script-src 'none'`, `default-src 'self'`, `frame-ancestors 'none'`, `base-uri 'none'`, `form-action 'none'`, `object-src 'none'`, `Referrer-Policy: no-referrer`, `X-Content-Type-Options: nosniff`, `X-Frame-Options: DENY`. HSTS only when `publicOrigin` is HTTPS.
- [ ] Tests assert the exact zip href, `https://remote.sigilapp.dev` pairing copy, `gl11tchy` attribution, no `mailto:`, no apex pairing URL.
- [ ] No runtime npm dependencies. `engines.node` >= 22.

**Verification:**
- [ ] `npm --prefix Site ci --ignore-scripts && npm --prefix Site test` (fails on missing landing/docs copy until 4–5; server/header/404 assertions can pass).

**Dependencies:** None (parallel with Tasks 1–2)

**Files likely touched:**
- `Site/package.json` (lockfile generated)
- `Site/server.mjs`
- `Site/test/site.test.mjs`
- `Site/public/index.html`
- `Site/public/docs/index.html`

**Estimated scope:** M

## Task 4: Landing page

**Description:** Build `/` as a Sigil Neon product page. Zero JS. Real screenshot. One download action.

**Acceptance criteria:**
- [ ] One `h1`, PRODUCT.md claim, screenshot from `docs/screenshot.png` copied to `Site/public/screenshot.png` with the README demo caption.
- [ ] Download href is exactly `https://github.com/gl11tchy/sigil/releases/latest/download/Sigil.zip`.
- [ ] Four pairing steps name `https://remote.sigilapp.dev`. No iframe of Sidereal.
- [ ] Tokens, type, radius, and bans match the spec. Reduced-motion CSS does not hide content.
- [ ] Icon is a copy of `Sidereal/public/icon.svg`. Footer: MIT, `gl11tchy`, GitHub.

**Verification:**
- [ ] `npm --prefix Site test` — landing assertions pass.
- [ ] Open `http://127.0.0.1:8080/` at 320 / 768 / 1024 / 1440; Tab reaches Download and Docs; no console errors.

**Dependencies:** Task 3

**Files likely touched:**
- `Site/public/index.html`
- `Site/public/style.css`
- `Site/public/screenshot.png`
- `Site/public/icon.svg`
- `Site/test/site.test.mjs`

**Estimated scope:** M

## Task 5: Docs page

**Description:** Build `/docs` from README + Sidereal pair/limits. Not ops notes.

**Acceptance criteria:**
- [ ] `GET /docs` and `GET /docs/` return the same page.
- [ ] Covers install (latest zip), macOS 14+, `grok` path, keyboard table, Settings → Remote pair, Mac must stay open, remote off by default, Disconnect revokes, phone rescan after this host split.
- [ ] Does not publish Railway IDs, crypto internals, or personal email.
- [ ] Same tokens as the landing page. Nav back to `/`.

**Verification:**
- [ ] `npm --prefix Site test` — docs assertions pass.
- [ ] Open `/docs` at 320 / 768 / 1024 / 1440.

**Dependencies:** Task 4

**Files likely touched:**
- `Site/public/docs/index.html`
- `Site/public/style.css`
- `Site/test/site.test.mjs`

**Estimated scope:** S

## Checkpoint: Site

- [ ] `npm --prefix Site test` passes.
- [ ] `/` and `/docs` checked in a real browser at the four widths.
- [ ] Relay paths 404 on the site origin.

## Task 6: Verify gate

**Description:** Fold Site into `Scripts/verify.sh` and CI. Ignore Site install output.

**Acceptance criteria:**
- [ ] `Scripts/verify.sh` runs `npm --prefix Site ci --ignore-scripts`, `npm --prefix Site test`, and `npm --prefix Site audit --omit=dev` before or beside the Sidereal block.
- [ ] `.gitignore` includes `Site/node_modules/`.
- [ ] CI `setup-node` caches `Site/package-lock.json` as well as Sidereal (second `cache-dependency-path` or a combined cache step). Do not drop Swift or Sidereal jobs.

**Verification:**
- [ ] `Scripts/verify.sh`

**Dependencies:** Task 5

**Files likely touched:**
- `Scripts/verify.sh`
- `.gitignore`
- `.github/workflows/ci.yml`

**Estimated scope:** S

## Task 7: Repo URL copy

**Description:** Point user-facing docs at the locked hosts. Do not retarget live Railway IDs until Task 11.

**Acceptance criteria:**
- [ ] README phone-remote section: Sidereal lives at `https://remote.sigilapp.dev`; product/docs at `sigilapp.dev`.
- [ ] `Sidereal/README.md` live companion is `https://remote.sigilapp.dev`.
- [ ] `docs/remote-control.md` intended origin is `https://remote.sigilapp.dev`; live test command uses that host. Existing Railway project/service IDs stay until cutover notes in Task 11.

**Verification:**
- [ ] `rg 'https://sigilapp.dev' README.md Sidereal/README.md docs/remote-control.md` — remaining apex hits are product-site, not relay.
- [ ] `bash -n Scripts/verify.sh`

**Dependencies:** Task 2

**Files likely touched:**
- `README.md`
- `Sidereal/README.md`
- `docs/remote-control.md`

**Estimated scope:** S

## Checkpoint: Gate

- [ ] `Scripts/verify.sh` passes.
- [ ] User-facing copy never pairs at the apex.

## Task 8: Site image

**Description:** Dockerize the site the same way as Sidereal.

**Acceptance criteria:**
- [ ] `Site/Dockerfile`: `node:22-alpine`, `npm ci --omit=dev --ignore-scripts`, `USER node`, `PORT=3000`, `CMD ["node", "server.mjs"]`.
- [ ] Process listens on `0.0.0.0`. `PUBLIC_ORIGIN` required at runtime (HTTPS in production).
- [ ] `/health` used as the Railway health path.

**Verification:**
- [ ] `docker build -t sigil-site Site` (if Docker is available) or file review plus `PUBLIC_ORIGIN=http://127.0.0.1:8080 PORT=8080 npm --prefix Site start` and `curl -fsS http://127.0.0.1:8080/health`.

**Dependencies:** Task 6

**Files likely touched:**
- `Site/Dockerfile`
- `Site/server.mjs`
- `Site/package.json`

**Estimated scope:** S

## Task 9: Railway site service

**Description:** Add a `site` service to the existing Sidereal project and deploy `Site/`. Do not attach `sigilapp.dev` yet.

**Acceptance criteria:**
- [ ] Service in project `26f52bc8-daae-4371-aa70-4cebb2d0f222`, environment `1a3850e2-c49f-45c4-bb54-627dd102c646`.
- [ ] Deploy `railway up ./Site --path-as-root --project 26f52bc8-daae-4371-aa70-4cebb2d0f222 --environment 1a3850e2-c49f-45c4-bb54-627dd102c646 --service <site-id> --detach` reaches SUCCESS (poll that deployment id).
- [ ] `PUBLIC_ORIGIN` is the service’s HTTPS origin. Sleeping disabled.
- [ ] Railway hostname: `/` product page, `/docs` docs, `/health` ok, `/rooms` 404.

**Verification:**
- [ ] `curl -fsS https://<railway-hostname>/health`
- [ ] `curl -fsS https://<railway-hostname>/` contains the zip href
- [ ] `curl -s -o /dev/null -w '%{http_code}' https://<railway-hostname>/rooms` is `404`

**Dependencies:** Task 8

**Files likely touched:**
- none required (ops); record service id in `docs/remote-control.md` only in Task 11

**Estimated scope:** S

## Checkpoint: Host

- [ ] Site Railway deploy SUCCESS and hostname GETs match the contracts.
- [ ] Sidereal on the apex is still untouched.

## Task 10: Owner DNS

**Description:** Owner-only Namecheap. Agent adds Railway custom domains and prints records. Agent does not log into Namecheap.

**Acceptance criteria:**
- [ ] `remote.sigilapp.dev` is a custom domain on the Sidereal service.
- [ ] `sigilapp.dev` is a custom domain on the site service (attach only after Task 11 is ready to set Sidereal `PUBLIC_ORIGIN`).
- [ ] Owner applies the Railway-printed records at Namecheap.

**Verification:**
- [ ] Owner confirms DNS. Agent checks `dig`/`curl` only after that.

**Dependencies:** Task 9

**Files likely touched:** none

**Estimated scope:** S (owner action)

## Task 11: Cutover and live proof

**Description:** Move Sidereal `PUBLIC_ORIGIN` to `https://remote.sigilapp.dev`, point hosts per the spec order, prove production, merge.

**Acceptance criteria:**
- [ ] Order: remote Sidereal healthy → site healthy on apex → Mac origin already on the branch.
- [ ] `https://sigilapp.dev/` product page; `/docs` docs; `/rooms` 404.
- [ ] `https://remote.sigilapp.dev/health` ok; `/` is Sidereal; native `POST /rooms` still 201 without an Origin header.
- [ ] `docs/remote-control.md` hosted-deployment section lists both services and the live test origin `https://remote.sigilapp.dev`.
- [ ] `Scripts/verify.sh` green. PR is `feature/product-site`. No secrets. Handle `gl11tchy` only.

**Verification:**
- [ ] `curl -fsS https://sigilapp.dev/health` and `https://remote.sigilapp.dev/health`
- [ ] `SIGIL_REMOTE_TEST_ORIGIN=https://remote.sigilapp.dev swift test --no-parallel --filter RemoteIntegrationTests`
- [ ] Browser: production `/` and `/docs` at 390px and 1280px.
- [ ] Railway status SUCCESS for both deploys. Merge only after that.

**Dependencies:** Task 7, Task 10

**Files likely touched:**
- `docs/remote-control.md`

**Estimated scope:** M

## Checkpoint: Complete

- [ ] Spec success criteria met on production URLs.
- [ ] Phone rescan is documented on `/docs`.
- [ ] `tasks/plan.md` and `tasks/todo.md` unchanged.
