# Sidereal

Live companion: https://remote.sigilapp.dev
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
must use the same origin. Health check: `GET /health` returns JSON with `status`,
`revision`, `gitSHA`, `dirty`, and `sourceSHA256`. An unstamped local checkout reports
`revision: "development"`, never a guessed commit.
The Dockerfile supports hosts such as Railway with the build root set to `Sidereal`.
Use one replica and do not enable sleeping/serverless behavior for the relay.

## Stamped uploads

Run `Scripts/verify.sh` from the repo root before releasing. Then use
`Scripts/deploy-sidereal.sh --project <id> --environment <id> --service <id>`.
The script stages only Docker/runtime files, stamps the actual Git HEAD and a
SHA-256 of the staged runtime and Dockerfile, and uploads that directory. No `.git`, local
credentials, test output, or `node_modules` enter the upload. The generated stamp
travels with the bundle even though local `Sidereal/revision.json` is gitignored.

Uncommitted changes add `-dirty` to the revision; the source hash distinguishes
uploads from the same commit. This does not pretend uncommitted code is in Git.
Docker rejects a missing, malformed, or stale stamp at build time and startup.
After deployment, compare `/health` with the revision and source hash printed by
the upload script. A successful upload alone does not prove the running revision.

For a manual Docker build, run `npm --prefix Sidereal run stamp` immediately before
`docker build Sidereal`. Re-stamp after any runtime edit. GitHub auto-deploy is not
required; a future GitHub pipeline must stamp its checkout before building too.

Local development only:

```sh
PUBLIC_ORIGIN=http://localhost:3099 PORT=3099 npm start
```

Only debug Sigil builds accept HTTP, and only for loopback hosts. A phone cannot
use your computer's `localhost`; real phone access requires the HTTPS deployment.

## Pair

1. In Sigil, open Settings → Remote.
2. Enter the Sidereal HTTPS address and select Connect Phone.
3. Scan the code on the phone, or copy the pairing link and paste it into the companion. It expires in five minutes.
4. Add to Home Screen from that Safari tab as a shortcut. If iPhone offers Open as Web App, turn it off.

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
Connection settings are under the dot in the top-right corner.
The session title at the top switches between open sessions. Chats opens a
searchable list of open and saved chats; a saved chat opens on the Mac. Scroll to the
top of the output to load earlier output. Find searches the recent output with previous/next
matches. Connection settings also lets you copy the displayed output.
Ended sessions offer Restart when the connected Mac supports it; drafts move to the
restarted session. Older Macs still ask you to restart on the desktop.

New asks which project to use, then starts a session there. The project list,
saved chats, and earlier output need Sigil from #54 or later. On an older Mac, New
starts in Sigil's current folder and the other two show "Unknown action."

Paste fills the prompt without
submitting it. Send pastes, then presses Enter. Return in the phone message box
adds a new line; Command/Ctrl+Return sends from a hardware keyboard.

The terminal view is bounded plain text, not a pixel-perfect terminal emulator.
It shows up to 100 open tabs and the latest 12 KB of readable output. Phone files
are written into Sigil’s drop cache (4 MB each) and pasted as paths. It does not
resize the Mac terminal or expose MCP.

Sigil must be running to control sessions. Scan once; the phone reconnects after
a Sigil restart, a Mac sleep, a relay restart, or a new room. Disconnect in Sigil
revokes the Mac pairing. Quitting does not. The phone stores a non-extractable
key and a reconnect ticket in IndexedDB, not localStorage. A Home Screen shortcut
must open in Safari so it uses that store. A standalone web app does not.
Forget this Mac clears the phone's stored key; it does not revoke other copies of
that credential. Use Disconnect on the Mac to revoke authorization.

## Security boundaries

The QR carries a one-use bootstrap secret in its fragment. The phone replaces it
with a different key during pairing. The relay sees room identifiers, timing and
ciphertext sizes and routing tickets, but not session contents or device keys. AES-256-GCM binds
message direction; Mac-generated connection challenges and sequences stop the Mac from
accepting replayed phone requests. The Mac's challenge reaches the phone unsealed, so a
relay that replays an earlier challenge can also replay the Mac's earlier replies to the
phone. The web host, on the same origin as the relay, remains trusted to deliver the
correct client JavaScript.

Neither tickets nor room IDs enter WebSocket URLs. The relay sends a fresh per-connection routing
key over WSS. The first client message is `{route: ciphertext}`: AES-256-GCM with
`sigil-remote-v1:relay-phone` or `sigil-remote-v1:relay-host` AAD. Its plaintext carries
only the room/ticket routing fields, never a device key. The relay opens this
single-use envelope before assigning a slot. It expires after ten seconds. The
existing phone/Mac end-to-end encryption starts after routing, unchanged.
A phone can supply a ticket after a Mac restart or a room from a fresh QR code.
A ticket is a routing credential, not permission to decrypt or run commands.

Logging policy: never log query strings, Authorization headers, routing keys,
tickets, or WebSocket frames. The relay emits no access logs and strips queries
from request objects before downstream diagnostics. Reverse-proxy access logs must
use path-only fields (for example, nginx `$uri`, not `$request` or `$request_uri`).
Legacy `?ticket=` upgrades are rejected. Deploy the relay, PWA, and Mac app together;
old clients cannot use this handshake. Existing stored pairings remain valid.

Remote input can authorize anything Grok can do, including file changes. Treat the
phone as access to your Mac's open sessions. Do not share pairing QR screenshots.
No commands are queued offline or automatically retried. After a lost response,
check the terminal before manually resending.

The relay limits itself to 100 rooms, 20 room allocations/minute, one phone per room,
30 frames/second per socket, 110 KB frames, and bounded outgoing buffers. These are
single-process limits, not a replacement for an internet-edge DoS/WAF policy.
Pending rooms and disconnected hosts expire after five minutes. Host reconnection
within that grace interval preserves the room. After that the Mac allocates a
new room and re-registers the same ticket. Rooms expire after 24 hours.

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
