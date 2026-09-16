# Sidereal

Live companion: https://sidereal-production-587c.up.railway.app
Sigil uses this address by default.

Phone companion and encrypted relay for Sigil. Deploy this directory as a single
Node 22 service behind HTTPS, with WebSocket upgrades enabled. No database required.
Do not horizontally scale it: room routing is in memory. A restart revokes all rooms.

## Run

```sh
npm ci --ignore-scripts
PUBLIC_ORIGIN=https://your-sidereal-host.example PORT=3000 npm start
```

`PUBLIC_ORIGIN` is the exact public origin (no path or trailing slash). Your reverse
proxy terminates TLS. Keep the Node port private to that proxy. The PWA and relay
must use the same origin. Health check: `GET /health`.
The Dockerfile supports hosts such as Railway with the build root set to `Sidereal`.
Use one replica and do not enable sleeping/serverless behavior for the relay.

Local development only:

```sh
PUBLIC_ORIGIN=http://localhost:3099 PORT=3099 npm start
```

Only debug Sigil builds accept HTTP, and only for loopback hosts. A phone cannot
use your computer's `localhost`; real phone access requires the HTTPS deployment.

## Pair

1. In Sigil, open Settings → Remote.
2. Enter the Sidereal HTTPS address and select Connect Phone.
3. Scan the code with the phone camera. It expires in five minutes.
4. Add Sidereal to the Home Screen using the browser's Share menu.

Pair one phone at a time. The phone can select sessions, read recent terminal
output, send text, attach photos and files, use arrow/Enter/Tab/Escape keys, and
interrupt the current turn.
The phone layout uses one session header and one bottom message box.
Readable output removes a recognized idle Grok composer and empty screen padding.
Connection settings → Show raw terminal keeps the complete snapshot available.
Unknown prompts and Mac-side drafts stay visible in both views.
The paperclip attaches photos or files from the phone; Sigil writes them on the Mac
and pastes their paths into the session. Keys opens terminal controls. Stop appears
while a turn is running. Latest returns to the newest output.
Drafts stay with each session until the page closes; a lost connection keeps them editable.
Connection settings are under the status in the top-right corner.

New starts a session in Sigil's current folder. Paste fills the prompt without
submitting it. Send pastes, then presses Enter.

The terminal view is bounded plain text, not a pixel-perfect terminal emulator.
It shows up to 100 open tabs and the latest 12 KB of readable output. Phone files
are written into Sigil’s drop cache (4 MB each) and pasted as paths. It does not
list closed conversations, resize the Mac terminal, or expose MCP.

The Mac must remain awake with Sigil running. Disconnect in Sigil revokes access;
quitting the app also revokes it. Phone reloads can reconnect while Sigil remains
open. A relay restart or the 24-hour session limit requires a new QR scan.
The phone stores a non-extractable key in IndexedDB, not localStorage. If installing
the PWA creates a separate browser storage area, disconnect and scan again there.
Forget this Mac clears the phone's stored key; it does not revoke other copies of
that credential. Use Disconnect on the Mac to revoke authorization.

## Security boundaries

The QR carries a one-use bootstrap secret in its fragment. The phone replaces it
with a different key during pairing. The relay sees room identifiers, timing and
ciphertext sizes, but not session contents or encryption keys. AES-256-GCM binds
message direction; Mac-generated connection challenges and sequences reject replay.
The web host remains trusted to deliver the correct client JavaScript.

Remote input can authorize anything Grok can do, including file changes. Treat the
phone as access to your Mac's open sessions. Do not share pairing QR screenshots.
No commands are queued offline or automatically retried. After a lost response,
check the terminal before manually resending.

The relay limits itself to 100 rooms, 20 room allocations/minute, one phone per room,
30 frames/second per socket, 110 KB frames, and bounded outgoing buffers. These are
single-process limits, not a replacement for an internet-edge DoS/WAF policy.
Pending rooms and disconnected hosts expire after five minutes. Host reconnection
within that grace interval preserves pairing. Rooms expire after 24 hours.

## Verify

```sh
npm test
npm audit --omit=dev
npx playwright install chromium webkit
npm run test:browser
```

The native `Scripts/verify.sh` installs these dependencies and runs these checks,
then runs native tests including real URLSession → relay → phone protocol tests.

Browser tests use synthetic Mac sessions through the real encrypted relay. They
cover narrow phones, tablets, desktop, drafting, scrolling, and a simulated visual
viewport resize. Real iOS keyboard behavior still requires a physical device check.
