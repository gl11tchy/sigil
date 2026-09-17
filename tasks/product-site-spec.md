# Spec: Product site and Sidereal origin split

ASSUMPTIONS (locked):
1. Static `Site/` on Railway serves the apex.
2. Sidereal stays a separate origin at `https://remote.sigilapp.dev`.
3. Download is `https://github.com/gl11tchy/sigil/releases/latest/download/Sigil.zip`.
4. No accounts. No per-user subdomains.
5. Namecheap DNS is owner-only.
6. Attribution handle is `gl11tchy` only. Never put a real name or personal email in the repo or on the site.

Locked host layout:
- `https://sigilapp.dev` — product page
- `https://sigilapp.dev/docs` — docs
- `https://remote.sigilapp.dev` — Sidereal PWA + relay

## Capability map

| Module id | Responsibility | Depends on |
|---|---|---|
| origin-split | Mac default relay origin, alias remap, restore policy, user-facing URLs in repo docs | — |
| product-site | Static landing + `/docs` in `Site/` | origin-split (copy names `remote.sigilapp.dev`) |
| site-host | Node static server, security headers, Docker, `Scripts/verify.sh` | product-site |
| cutover | New Railway site service, Sidereal `PUBLIC_ORIGIN`, custom domains | site-host, origin-split |

Build order: origin-split → product-site → site-host → cutover.

Today `RemoteControl.productionOrigin` is `https://sigilapp.dev` and that host serves Sidereal (`Sidereal/server.mjs` assets at `/`, `POST /rooms`, `GET /health`). A public `/` visit must become the product page. Pairing QR URLs are `{origin}/#room=…&key=…` with an empty path (`RemoteControl.origin` rejects any other path). The relay origin therefore cannot stay on the apex.

## Objective

Ship a public product site for Sigil so a visitor can understand the app, download the latest zip, see the real window, and learn how to pair a phone — without landing in the Sidereal PWA.

Who: one developer, at a desk, in a dark room, next to a terminal. They are not browsing. They want the zip and the pairing steps.

Why: `sigilapp.dev` currently opens the relay. That hides the product and collides with a landing page.

Success: the three hosts above each do one job; the zip link is the GitHub latest asset; pairing copy and the Mac default origin both name `https://remote.sigilapp.dev`; existing phones must scan once after the split (accepted cost: the PWA origin changes, and IndexedDB does not follow).

## Tech Stack

- Static HTML and CSS in `Site/public`. No JavaScript on the product site. No bundler, no framework, no accounts.
- Node 22 static file server (`Site/server.mjs`), same shape as `Sidereal/server.mjs`: allowlisted GET routes, no directory listing, no runtime npm dependencies.
- Design tokens from `DESIGN.md` / Sidereal `public/style.css` (Sigil Neon). Identity preservation; do not run a new palette.
- macOS app: Swift 6, existing `RemoteControl` origin helpers. No crypto or ticket changes.
- Railway: new site service from `Site/` (Dockerfile, Node 22 Alpine). Existing Sidereal service stays; its public origin becomes `https://remote.sigilapp.dev`.
- Tests: Node `node:test` for the site; Swift Testing for origin remap. `Scripts/verify.sh` runs both.

## Commands

```
Site tests:     npm --prefix Site ci --ignore-scripts && npm --prefix Site test
Site dev:       PUBLIC_ORIGIN=http://127.0.0.1:8080 PORT=8080 npm --prefix Site start
Origin tests:   swift test --no-parallel --filter RemoteCommandsTests
                swift test --no-parallel --filter RemoteControlTests
Sidereal:       npm --prefix Sidereal ci --ignore-scripts && npm --prefix Sidereal test
Full gate:      Scripts/verify.sh
Site image:     docker build -t sigil-site Site
Live health:    curl -fsS https://sigilapp.dev/health
                curl -fsS https://remote.sigilapp.dev/health
Live origin:    SIGIL_REMOTE_TEST_ORIGIN=https://remote.sigilapp.dev swift test --no-parallel --filter RemoteIntegrationTests
```

Local site listen: loopback only in tests. Production bind matches Sidereal (`0.0.0.0`, `PORT`).

## Project Structure

```
Site/
  package.json              # name "sigil-site", type module, engines node >=22
  package-lock.json
  Dockerfile                # node:22-alpine, USER node, PORT=3000
  server.mjs                # allowlisted static server + /health
  public/
    index.html              # product page
    docs/index.html         # /docs
    style.css               # Sigil Neon tokens
    screenshot.png          # copy of docs/screenshot.png
    icon.svg                # copy of Sidereal/public/icon.svg
  test/
    site.test.mjs           # routes, headers, download href, copy contracts
Sources/SigilApp/RemoteControl.swift    # productionOrigin + preferredOrigin
Tests/SigilAppTests/RemoteCommandsTests.swift
Tests/SigilAppTests/RemoteControlTests.swift
Scripts/verify.sh
.gitignore                  # Site/node_modules/
README.md, Sidereal/README.md, docs/remote-control.md
```

Do not add `Site/` under `Sidereal/`. Do not serve Sidereal assets from the apex. Do not edit `tasks/plan.md` or `tasks/todo.md`.

## Code Style

Tokens and type match the shipping PWA, not a new brand:

```css
:root {
  color-scheme: dark;
  font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
  background: #08090b;
  color: #d5dae1;
  --raised: #1a1a1a;
  --selected: #262626;
  --hairline: #2b2b2b;
  --text-dim: #abb0b8;
  --text-faint: #8d9198;
  --accent: #4ef0c4;
  --radius: 6px;
}
```

Human copy in the system sans. Paths, key caps, hostnames, and the download filename in `ui-monospace, "SF Mono", Menlo, monospace`. One radius: 6px containers, 5px small controls. Accent only on the download control, focus rings, and the working hairline around the screenshot — never as decoration.

Download control (exact href):

```html
<a class="download" href="https://github.com/gl11tchy/sigil/releases/latest/download/Sigil.zip">Download Sigil.zip</a>
```

HTML is semantic (`header`, `main`, `nav`, one `h1` per page). Body line length 65–75ch. `text-wrap: balance` on `h1`–`h3`. `letter-spacing` on display type ≥ `-0.04em`. Headings use `clamp()` with max ≤ 6rem. Every animation has `@media (prefers-reduced-motion: reduce)` and does not gate visibility on a reveal class.

Banned: gradient text, glass cards, side-stripe borders, identical feature card grids, uppercase tracked eyebrows on every section, 32px radii, cream/sand body, Inter / IBM Plex / Fraunces, Unsplash stock, inline `script`, `innerHTML`, per-user hostnames, analytics, cookies.

Pairing steps may be numbered once — they are a real sequence. Do not number the rest of the page.

### Design direction

Register for this surface: brand (the page is the product). `PRODUCT.md` remains Product for the Mac app.

Scene: the same dark desk as `PRODUCT.md`. Dark body is required.

Strategy: Restrained Sigil Neon (already committed in `DESIGN.md`). Do not drench the hero in mint.

Voice words: dense, nocturnal, terminal-adjacent.

Named references: the Sigil Neon window, Sidereal `public/style.css`, the screenshot in `docs/screenshot.png`.

Anti-references: Stripe/Linear marketing, editorial magazine serif, “AI coding” purple, generic three-column icon grids.

Imagery: the existing app screenshot, with the README caption (“Demo data. The conversations shown are invented; the session on the right is real.”). Copy the file into `Site/public/screenshot.png`. Do not hotlink `docs/`.

Copy source: `PRODUCT.md` (what it is), `README.md` (what it adds, keyboard, requirements, zip install), `Sidereal/README.md` (pair steps, limits). Public `/docs` does not publish Railway IDs, crypto internals, or `docs/remote-control.md` ops notes.

Landing sections, in order: wordmark + Docs/Download; one-sentence product claim + download; screenshot; how to pair (four steps); footer (MIT, `gl11tchy`, GitHub). Primary action is the zip. Secondary is Docs. Pairing is on the landing and on `/docs`; the PWA is not iframed.

### Origin split behavior

`RemoteControl.productionOrigin` becomes `https://remote.sigilapp.dev` (no path, no trailing slash).

`preferredOrigin` maps both retired aliases onto it:

- `https://sidereal-production-587c.up.railway.app` (existing `legacyRailwayOrigin`)
- `https://sigilapp.dev` (retired apex relay)

`origin(_:)` stays a format check. It still accepts the old apex as HTTPS. Aliasing is `preferredOrigin` only.

`RemoteControlView` already assigns `preferredOrigin` on appear. `start(urlText:)` must apply `preferredOrigin` before `origin(_:)`.

Retired stored pairings do not auto-resume. The phone PWA lived on the old origin; IndexedDB will not move. `resumeIfPaired` and `restoredSession` skip a Keychain record whose origin `preferredOrigin` rewrites. The next Connect Phone issues a new QR against `productionOrigin`. Do not rewrite a retired origin into Keychain and pretend the phone is still paired. Do not change tickets, device keys, or relay crypto.

Settings default stays `RemoteControl.productionOrigin`. Custom HTTPS origins that are not aliases stay as typed (`preferredOrigin("https://example.com")` unchanged).

## Testing Strategy

Failing tests first on every slice. Repository commands only.

**Site (small, `Site/test/site.test.mjs`):** boot `createSite({ publicOrigin })` on loopback. Assert:

- `GET /` is 200 HTML, one `h1`, product claim, screenshot `img` with a real `alt`, pairing steps that name `https://remote.sigilapp.dev`.
- Download `href` is exactly `https://github.com/gl11tchy/sigil/releases/latest/download/Sigil.zip`.
- `GET /docs` and `GET /docs/` are 200 HTML covering install, requirements, keyboard, pairing, and limits (Mac must stay open; remote is off by default; Disconnect revokes).
- `GET /health` is 200 `ok`.
- `GET /rooms`, `GET /connect`, `GET /app.mjs`, `POST /rooms` are 404. Apex is not the relay.
- Security headers match the server contract below. HTML responses do not set long-lived cache.
- Attribution is `gl11tchy`. No `mailto:` and no personal email.
- Copy never tells the visitor to pair at `https://sigilapp.dev` or to use a per-user subdomain.

**Native (small):** extend `qrIsDecodableAndURLValidationIsStrict` and add resume tests:

- `productionOrigin == "https://remote.sigilapp.dev"`.
- `preferredOrigin` maps both retired aliases to `productionOrigin`, and leaves `productionOrigin` and a foreign HTTPS origin unchanged.
- `origin(productionOrigin)` round-trips. `origin` still rejects userinfo, query, fragment, non-root path, and non-loopback HTTP.
- Keychain pairing stored at `https://sigilapp.dev` does not `resumeIfPaired` and does not restore as paired when starting at `productionOrigin`.
- Keychain pairing already at `productionOrigin` still resumes without a QR (pairing-persist unchanged).

**Verify:** `Scripts/verify.sh` runs Site `npm ci --ignore-scripts`, `npm test`, then the existing Sidereal and Swift gates. Ignore `Site/node_modules/` in git.

**Browser (manual checkpoint, not a new CI browser suite):** open `/` and `/docs` at 320 / 768 / 1024 / 1440. Keyboard tab through Download and Docs. Contrast AA using the DESIGN.md tokens (already floored). No console errors. After cutover, repeat on the production URLs.

**Live relay:** after cutover only, `SIGIL_REMOTE_TEST_ORIGIN=https://remote.sigilapp.dev` for `RemoteIntegrationTests`. Do not point that env at the apex.

## Boundaries

Always:

- Treat every HTTP request as untrusted. Allowlist routes. Cap request URL length. No user-supplied fetch (no SSRF).
- Encode text in HTML. No inline script. CSP `script-src 'none'`.
- Ship CSP, `Referrer-Policy: no-referrer`, `X-Content-Type-Options: nosniff`, `X-Frame-Options: DENY`, `frame-ancestors 'none'`, `base-uri 'none'`, `form-action 'none'`, `object-src 'none'`. HSTS `max-age=31536000` when `publicOrigin` is HTTPS.
- Download is a navigation to GitHub. Do not proxy the zip.
- Run `Scripts/verify.sh` before a PR. Site `npm audit --omit=dev` in verify (no production deps expected).
- Apply `preferredOrigin` in `start(urlText:)`. Skip resume for retired origins.
- Attribution `gl11tchy` only.
- Keep Sidereal one replica, no sleep. Site service: no sleep (public face).

Ask first:

- Namecheap DNS, extra hosts (`www`, per-user labels), or moving the apex before `remote.sigilapp.dev` is healthy.
- Adding JS, analytics, accounts, cookies, or a form.
- Changing pairing crypto, tickets, or Keychain schema.
- New npm dependencies, including Playwright for the site.
- Changing CI to skip Sidereal or Swift tests.
- Custom domain on a new Railway project (add a service to project `26f52bc8-daae-4371-aa70-4cebb2d0f222`).

Never:

- Serve Sidereal (`/rooms`, `/connect`, PWA assets) on `sigilapp.dev` after cutover.
- Point `PUBLIC_ORIGIN` at the apex once the product site owns it.
- Merge the Mac `productionOrigin` change while `https://remote.sigilapp.dev/health` is not `ok`.
- Change Namecheap (owner-only). The agent may add a Railway custom domain and print the records.
- Create `*.sigilapp.dev` per-user hosts.
- Overwrite `tasks/plan.md` or `tasks/todo.md`.
- Commit secrets, `.env`, `Site/node_modules/`, or `dist/`.
- Put a real name or personal email in git, LICENSE, the site, or Railway notes.
- Log pairing secrets. Operate personal sessions during QA.

### Threat model (site)

Trust boundary: public GET on the apex. Assets: none (no accounts, no pairing secrets). Abuse cases: crawl `/rooms` expecting the relay; clickjack the download; inject script; proxy-fetch the zip; confuse pairing onto the apex. Mitigations: 404 on relay paths, frame deny, script-none CSP, no server-side URL fetch, copy and tests that name `remote.sigilapp.dev` only.

### Cutover order

Do not flip the apex until the new relay host is live.

1. Deploy Sidereal reachable as `https://remote.sigilapp.dev` with `PUBLIC_ORIGIN=https://remote.sigilapp.dev`. `GET /health` is `ok`. Phone origin header must match that value (`Sidereal/server.mjs`).
2. Deploy `Site/` to a new Railway service. Confirm its Railway hostname serves `/` and `/docs` and 404s `/rooms`.
3. Owner sets Namecheap so `remote.sigilapp.dev` stays on Sidereal and `sigilapp.dev` points at the site service.
4. Confirm `https://sigilapp.dev/` is the product page, `https://sigilapp.dev/docs` is docs, `https://remote.sigilapp.dev/` is Sidereal.
5. Then merge/ship the Mac `productionOrigin` change (same PR is allowed if it lands after step 4 on the hosts).

Rollback: point the apex custom domain back at the Sidereal service and restore `PUBLIC_ORIGIN=https://sigilapp.dev`. That restores the old PWA on `/` and takes the product site off the apex. Mac builds that already default to `remote.sigilapp.dev` still need that host, so do not delete `remote.sigilapp.dev` during rollback.

## Success Criteria

- `https://sigilapp.dev/` is the product page: claim, screenshot, exact GitHub zip href, pairing steps for `https://remote.sigilapp.dev`.
- `https://sigilapp.dev/docs` documents install, requirements, keyboard, pairing, and limits.
- `https://remote.sigilapp.dev/health` is `ok` and `/` is the Sidereal PWA. `POST /rooms` from a native client still allocates a room.
- `https://sigilapp.dev/rooms` and `/connect` are 404.
- `RemoteControl.productionOrigin` is `https://remote.sigilapp.dev`. Retired aliases remap. Pairing-persist still resumes only for that origin.
- `Scripts/verify.sh` runs Site tests and still runs Sidereal + Swift + smoke.
- No accounts, no per-user subdomains, no personal email, attribution `gl11tchy`.
- Live proof is a READY Railway deploy **and** a GET of the production URLs after that. A merge alone is not proof.

## Open Questions

None. DNS is owner-only, not an open product choice. Existing phones rescan once; that cost is accepted.
