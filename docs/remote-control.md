# QR remote control

## Objective and scope

Pair a phone from Sigil Settings and control this Mac using the Sidereal PWA.
The default is internet access through an HTTPS/WebSocket relay, not an exposed
Mac listening port. Sigil must stay open and the Mac must stay awake.

The companion can list and select open tabs, read bounded terminal text, send
text, keys, and phone photos/files, and create a session in the current folder.
Phone files are written into the local drop cache and pasted as paths. It does not
expose arbitrary Mac file access, shell launch configuration, or the local MCP socket.
Remote input has the same authority as typing in an open Grok session.

## Contract and security

- Remote control starts off. Starting it requires an HTTPS companion URL.
- The Mac makes outbound connections only. The included Node relay serves the PWA.
- QR pairing uses a random 256-bit secret in the URL fragment, never a query.
- Pairing expires after five minutes and is consumed once. A phone supplies a
  different 256-bit device key through the encrypted pairing exchange.
- After that exchange the Mac stores origin, device key, and a 256-bit ticket
  in Keychain. Encrypted replies carry the ticket. The phone stores it in
  IndexedDB and reconnects with it. Disconnect on the Mac revokes storage;
  quitting does not. Rooms stay ephemeral; the host re-registers the same
  ticket on a new room after a drop.
- Commands and responses use AES-256-GCM (96-bit random nonce, 128-bit tag).
  Direction is authenticated. Each connection has a fresh Mac-generated challenge;
  each request has a strictly increasing sequence. No command retries or offline queue.
- The Mac keeps the device key and ticket in the login keychain. That keychain
  is not bound to this Mac: Migration Assistant or a restore copies the pairing.
  The phone stores a non-extractable CryptoKey and the ticket in IndexedDB.
  Disconnecting in Sigil revokes Mac storage. Quitting does not.
- The relay routes bounded ciphertext, not terminal contents or encryption keys.
  The web host is trusted to serve the correct client code (as with any web app).
- Frames, peers, rooms, request rates and send buffers have explicit limits.
- No content or credentials in logs, service-worker caches, or repository files.

## Implementation

Swift 6 / macOS 14; CryptoKit, Foundation URLSession, existing SwiftTerm controller.
`Sources/SigilKit/Remote` contains the wire protocol and pairing checks.
`Sources/SigilApp` contains the outbound connection, command adapter and settings UI.
`Sidereal` contains the Node relay, dependency lockfile, static PWA and Node tests.
No change to unrelated tabs, themes, panel behavior, or tab messaging.

Use existing main-actor model methods and small Codable value types:

```swift
struct RemoteRequest: Codable, Sendable {
    let challenge: String
    let sequence: Int
    let action: String
    let tabID: String?
    let text: String?
}
```

## Live stream and session operations (2026-09-24)

- `watch` makes the Mac send events: sealed replies with `event: true` and
  `sequence: 0`, carrying the tab list, the selection and a `screen` of changed
  rows. Rows are addressed by buffer-absolute index (`i`), with text (`t`),
  a wrap flag (`w`) and style runs (`s` = `[start, length, fg, bg, flags]` over
  Character offsets; colours are -1 default, 0…255 ANSI, `2^24 + 0xRRGGBB` true
  colour; flags are SwiftTerm `CharacterStyle` bits). `gen` restarts the index
  space (reset, alternate screen, another tab). A full window carries the tab's
  theme (`palette`, `fg`, `bg`). Events go out only while a phone is watching,
  batched at 80 ms, at most 60 rows a frame. Clients that do not know events drop
  them: neither pending sequence nor error.
- `rows` returns older rows before `index`; `close`, `rename` (`name`) and
  `archive` act on a tab (archive needs a saved Grok chat); `new` with
  `worktree: true` makes a worktree first. Tabs report `provider`,
  `providerName`, `folder` and `canArchive`; projects report `repository`;
  state reports `mac` and the capabilities `screen` and `sessionOps`.
- `prompt` in state and events: an approval question read from the last screen
  rows (numbered menus such as Claude Code's and Codex's, or `[y/n]` questions),
  with `choices`, `yes` and `no` keys. `answer` (`text` = key) types the digit,
  or the letter and Return, only after reading the screen again and finding the
  same kind of prompt; anything else is refused.
- Spec: `docs/phone-companion-2-spec.md`.

## Verification and boundaries

Build/tests: `swift test --no-parallel`.
Full native gate: `Scripts/verify.sh`.
Companion: `cd Sidereal && npm ci && npm test && npm audit --omit=dev`.
Test unauthenticated, expired, reused, tampered, reflected and replayed messages;
revocation; transport limits; and real terminal input/output using an isolated fixture.
Browser-check the phone-sized companion and native QR settings with synthetic data.
Never operate existing personal sessions during QA. Never log pairing secrets.
Hosting needs a real HTTPS deployment; local tests do not prove cellular/iPhone access.

## References

- [CryptoKit sealed boxes](https://developer.apple.com/documentation/cryptokit/aes/gcm/sealedbox)
- [Web Crypto AES-GCM parameters](https://developer.mozilla.org/en-US/docs/Web/API/AesGcmParams)
- [Secure contexts](https://developer.mozilla.org/en-US/docs/Web/Security/Defenses/Secure_Contexts)
- [ws server limits](https://github.com/websockets/ws/blob/master/doc/ws.md)

## Local evidence

- `Scripts/verify.sh`: native tests, companion tests/audit, shell checks, formatting,
  signed debug bundle and isolated smoke launch passed.
- Native integration sends encrypted input through the real Node relay into an
  isolated PTY, receives its output encrypted, and verifies stop closes the phone.
- Browser checked at 390 × 844: QR-fragment pairing, sending, session creation and
  reload/reconnect. Browser interaction used a synthetic encrypted host, not personal sessions.
- Native Settings checked in a separate temporary app identity; the entire QR fits
  without scrolling. Vision also decoded the generated QR payload in a unit test.
- Independent review found and fixed replay-reset ownership, relay reconnect grace,
  unauthorized peer eviction, connection-bound Send, and terminal input-mode handling.
- Railway deployment `4dbae614-d6c6-4aa6-8bff-450204cd5e24` reached SUCCESS.
  Public HTTPS health, security headers, and the deployed browser page passed.
- `SIGIL_REMOTE_TEST_ORIGIN=https://remote.sigilapp.dev swift test --no-parallel --filter RemoteIntegrationTests`
  passed against the deployed relay: encrypted pairing, PTY input/output, and revocation.
- Physical camera scan, cellular access, and iOS Home Screen installation remain
  device-only checks; no physical phone was available to the agent. Sidereal does
  not install as a standalone iOS web app, so a Home Screen shortcut uses Safari
  storage. A leftover standalone icon is split from Safari until it is replaced.

## Hosted deployment

- Project: `26f52bc8-daae-4371-aa70-4cebb2d0f222` (sidereal).
- Environment: `1a3850e2-c49f-45c4-bb54-627dd102c646` (production).
- Sidereal service: `d7e3c251-0ae2-45f9-b4b1-c819d3fa9ece`.
- Site service: `060788b3-4ab1-45fb-8623-68027835cbc0`.
- Companion origin: `https://remote.sigilapp.dev`. `PUBLIC_ORIGIN` is set to that host,
  confirmed by the owner from the Railway dashboard on 2026-09-19. It has to equal that
  host: `Sidereal/server.mjs:86` rejects a phone WebSocket whose `Origin` header differs
  from it, so a value left over from before the cutover would stop the companion pairing
  outright. A connected Railway app is served variable names without values, so an agent
  cannot re-check this; read it in the dashboard or the CLI if it is ever in doubt.
- Site preview: `https://site-production-c4d1.up.railway.app`. The apex `sigilapp.dev` is a
  custom domain on the site service, ownership verified, certificate valid. Railway reports
  the apex record as propagated against its target `s00d1xh1.up.railway.app`; an apex alias
  has no readable CNAME value, so the valid certificate is the evidence it resolves.
- `remote.sigilapp.dev` is a custom domain on the Sidereal service, ownership verified,
  certificate valid, `remote` CNAME propagated to `1bkrlt5p.up.railway.app`.
- Single replica in `sfo`; `/health`; app sleeping disabled through service settings.
- Source: local upload; no GitHub auto-deploy yet. Deployments therefore carry a snapshot id
  and no Railway commit SHA. New uploads use the stamped bundle described below;
  `/health` reports its Git SHA, dirty flag, and runtime source hash. The last recorded
  deployment is `c8b32797-2b3d-4e8f-aa4d-a27448a1012a` (2026-09-23, revision
  `199cc86f60d88aa6962251eaf647c455400c5fcd`, source hash
  `b6e2254d668e02992cd992fa30d5f65df0fbfbcff8e8514199da2297a254df72`, confirmed by `/health`
  and a paired phone session against the live host).
- Re-deploy Sidereal with `Scripts/deploy-sidereal.sh --project 26f52bc8-daae-4371-aa70-4cebb2d0f222 --environment 1a3850e2-c49f-45c4-bb54-627dd102c646 --service d7e3c251-0ae2-45f9-b4b1-c819d3fa9ece --detach`.
- Verify the new Sidereal `/health` JSON against the revision and source hash printed by the upload script. Release the matching Mac build and relay/PWA together after merge.
- Re-deploy the site with `railway up ./Site --path-as-root --project 26f52bc8-daae-4371-aa70-4cebb2d0f222 --environment 1a3850e2-c49f-45c4-bb54-627dd102c646 --service 060788b3-4ab1-45fb-8623-68027835cbc0 --detach`.
- Rollback: remove/revert the active Railway deployment. This only ends remote
  sessions; it does not alter Mac sessions or files. Restarting the relay drops
  live sockets; a stored ticket reconnects when Sigil is running.
