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
The Dockerfile supports hosts such as Railway using a stamped runtime bundle.
Use one replica and do not enable sleeping/serverless behavior for the relay.

## Stamped uploads

Run `Scripts/verify.sh` from the repo root before releasing. Then use
`Scripts/deploy-sidereal.sh --project <id> --environment <id> --service <id>
--health-url https://<relay-host>/health`.
The [shared deployment contract](../docs/deployment.md) requires clean source at
fresh `origin/main`, verifies the exact target and existing domain, stages only
manifested inputs, and uploads once. Explicit dirty and non-main overrides are
documented there. The generated stamp travels with the bundle even though local
`Sidereal/revision.json` is gitignored.

The wrapper exits zero only when `/health` matches both commit and source hash
within five minutes. Docker rejects missing, malformed or stale stamps during
build and startup. This proves running source identity; operational checks still
belong to a separately authorized rollout. CLI output and credentials are not logged.

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
Ended sessions offer Restart only when the native conversation can resume. Drafts
move only after matching provider, native session ID and project path. Unknown
identities never inherit another conversation's draft.

New asks which project to use, then starts a session there. Both the Mac and phone
companion need the current secure protocol; older endpoints show an upgrade error.

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

## Push alerts

Set `APNS_KEY` (the contents of the `.p8`, PEM or base64), `APNS_KEY_ID`,
`APNS_TEAM_ID` and `APNS_TOPIC` (the iPhone app's bundle id) and the relay
forwards a host's `{pushToken, pushEnvironment}` and `{push: …}` frames to Apple
over HTTP/2 with an ES256 token. Alert text stays sealed with the phone's device
key; the relay adds a fixed fallback body. Live Activity updates carry only a
status word, a timestamp and an asking flag. Without the four settings the relay
answers `{type: "push", ok: false, reason: "off"}`.

## Security boundaries

The QR carries a one-use bootstrap secret in its fragment. The phone replaces it
with a different key during pairing. The relay sees room identifiers, timing and
ciphertext sizes and routing tickets, but not session contents or device keys. AES-256-GCM binds
message direction; Mac-generated connection challenges and sequences stop the Mac from
accepting replayed phone requests. The phone contributes a fresh client nonce and requires its encrypted echo,
so an old Mac challenge plus a recorded reply cannot authenticate a new connection. The web host, on the same origin as the relay, remains trusted to deliver the
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

The relay retains its global ceiling of 100 rooms and 300 TCP connections. Each
source has a five-token room-allocation bucket, replenished at one token per
12 seconds, at most 20 allocated live rooms, and at most 20 open WebSockets,
including connections still waiting to route. WebSocket admission is checked
before the upgrade. Closing a socket frees only its connection slot; deleting a
room frees its room slot without erasing token debt. IPv4-mapped IPv6 shares the
IPv4 budget; native IPv6 addresses share a /64 budget. A shared NAT shares these
limits too. The room allowance includes disconnected rooms during the existing
five-minute grace, leaving recovery headroom while one source can occupy at most
one fifth of global room capacity. Source state is capped at 1,024 entries;
entries with no rooms or sockets expire after an idle minute, pruned by the
15-second sweep. Occupied counters are retained. Room-allocation limits and per-source WebSocket admission
return 429; the global TCP ceiling still drops excess connections. The Mac reports
room-allocation 429 as “The relay is busy. Retrying.”

Source identity currently comes **only from `req.socket.remoteAddress`**.
`X-Forwarded-For`, `Forwarded`, `X-Real-IP`, and a boolean `TRUST_PROXY` setting do
not establish trust and are not used. Behind a reverse proxy, its transport peer
shares one budget across the users it represents. End-user isolation behind
Railway or another proxy is therefore not established by this change. Supporting
forwarded addresses requires a separately verified ingress peer and precise
header/hop contract; do not enable header trust based on a boolean or guessed
proxy range. This PR changes no deployment, ingress or proxy configuration.

Rooms that never authenticate a host expire at 30 seconds. The 15-second sweep
removes them, and allocation/first-host authentication also checks expiry.
After an authenticated host disconnects, the existing five-minute grace interval
preserves its room. After that the Mac allocates a new room and re-registers the
same ticket. Rooms still expire after 24 hours. Limits remain one phone per room,
30 frames/second per socket, 110 KB frames, 60 pushes/minute per room, and bounded
outgoing buffers. These single-process limits mitigate one source's starvation;
they do not guarantee availability against distributed exhaustion or replace an
internet-edge DoS/WAF policy. APNs token registration and abuse are separate
exposures, not fixed by room-allocation limits.

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


## Protocol upgrade and approval limits

Update the Mac and phone companion together. Each request now carries a fresh
phone nonce, echoed in sealed replies. Missing support produces an upgrade error.
Native event streams also require rising event counters; this PWA uses correlated
request/reply polling. It keeps no offline command queue and does not blindly retry.

A detected menu shows its available operation context and literal choices under
**Terminal controls**. These buttons type into the terminal; they are not verified
provider approvals. Oversized/ambiguous menus fall back to the ordinary terminal.
Successful dispatch does not prove the provider accepted or completed an action.
