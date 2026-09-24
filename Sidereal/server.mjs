import http from 'node:http';
import { readFile } from 'node:fs/promises';
import { randomBytes, timingSafeEqual } from 'node:crypto';
import { pathToFileURL } from 'node:url';
import { WebSocketServer, WebSocket } from 'ws';
import { importKey, open } from './public/crypto.mjs';
import { loadRevision } from './revision.mjs';

const revision = await loadRevision(undefined, { required: process.env.SIGIL_REQUIRE_REVISION === '1' });

const token = () => randomBytes(32).toString('hex');
const equal = (a, b) => typeof a === 'string' && Buffer.byteLength(a) === Buffer.byteLength(b) && timingSafeEqual(Buffer.from(a), Buffer.from(b));
const hex64 = value => typeof value === 'string' && value.length === 64 && /^[a-f0-9]+$/.test(value);
const assets = new Map([
  ['/', ['index.html', 'text/html']], ['/app.mjs', ['app.mjs', 'text/javascript']],
  ['/output.mjs', ['output.mjs', 'text/javascript']],
  ['/crypto.mjs', ['crypto.mjs', 'text/javascript']], ['/pairing.mjs', ['pairing.mjs', 'text/javascript']],
  ['/jsqr.js', ['jsqr.js', 'text/javascript']], ['/style.css', ['style.css', 'text/css']],
  ['/sw.js', ['sw.js', 'text/javascript']], ['/manifest.webmanifest', ['manifest.webmanifest', 'application/manifest+json']],
  ['/icon.svg', ['icon.svg', 'image/svg+xml']],
  ...[180, 192, 512].map(size => [`/icon-${size}.png`, [`icon-${size}.png`, 'image/png']]),
  ...['Inter-Regular', 'Inter-Medium', 'Inter-SemiBold', 'JetBrainsMono-Regular', 'JetBrainsMono-Medium']
    .map(name => [`/fonts/${name}.woff2`, [`fonts/${name}.woff2`, 'font/woff2']]),
]);

export function createRelay({ publicOrigin, maxRooms = 100, now = Date.now } = {}) {
  const origin = new URL(publicOrigin);
  if (origin.origin !== publicOrigin || !(origin.protocol === 'https:' ||
      (origin.protocol === 'http:' && ['localhost', '127.0.0.1'].includes(origin.hostname)))) {
    throw new Error('PUBLIC_ORIGIN must be an HTTPS origin (HTTP is allowed only on loopback).');
  }
  const rooms = new Map();
  const tickets = new Map();
  let creationWindow = now(), creations = 0;
  const wss = new WebSocketServer({ noServer: true, maxPayload: 110000, perMessageDeflate: false });
  // No request, header, or frame logging. Proxies must log paths only, never queries.
  const server = http.createServer(async (req, res) => {
    req.url = req.url.split('?')[0];
    res.setHeader('Content-Security-Policy', "default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' blob:; media-src 'self' blob:; connect-src 'self'; worker-src 'self'; object-src 'none'; base-uri 'none'; frame-ancestors 'none'; form-action 'none'");
    res.setHeader('Referrer-Policy', 'no-referrer');
    res.setHeader('X-Content-Type-Options', 'nosniff');
    res.setHeader('X-Frame-Options', 'DENY');
    res.setHeader('Cache-Control', 'no-store');
    if (origin.protocol === 'https:') res.setHeader('Strict-Transport-Security', 'max-age=31536000');
    if (req.url === '/health' && req.method === 'GET') {
      res.writeHead(200, { 'Content-Type': 'application/json' }).end(JSON.stringify({ status: 'ok', ...revision }));
      return;
    }
    if (req.url === '/rooms' && req.method === 'POST') {
      // Browsers cannot allocate hosts. Native clients do not send Origin.
      if (req.headers.origin || Number(req.headers['content-length'] || 0) > 0 || req.headers['transfer-encoding']) {
        res.writeHead(403).end(); return;
      }
      if (now() - creationWindow >= 60000) { creationWindow = now(); creations = 0; }
      if (rooms.size >= maxRooms || ++creations > 20) { res.writeHead(429).end(); return; }
      const room = randomBytes(16).toString('hex'), hostToken = token();
      rooms.set(room, { hostToken, created: now(), disconnectedAt: now(), host: null, phone: null });
      res.writeHead(201, { 'Content-Type': 'application/json' }).end(JSON.stringify({ room, hostToken }));
      return;
    }
    const asset = req.method === 'GET' && assets.get(req.url);
    if (!asset) { res.writeHead(404).end(); return; }
    try {
      const data = await readFile(new URL(`public/${asset[0]}`, import.meta.url));
      res.writeHead(200, { 'Content-Type': asset[1].startsWith('font/') ? asset[1] : `${asset[1]}; charset=utf-8` }).end(data);
    } catch { res.writeHead(500).end(); }
  });
  server.requestTimeout = 10000;
  server.headersTimeout = 10000;
  server.maxConnections = 300;
  const send = (socket, value) => {
    if (socket?.readyState !== WebSocket.OPEN) return;
    if (socket.bufferedAmount > 220000) { socket.terminate(); return; }
    socket.send(JSON.stringify(value));
  };
  // Two Sigil copies can share one pairing. Hand the ticket to another room whose host is live.
  const liveRoomFor = (ticket, except) => {
    for (const [other, candidate] of rooms) {
      if (other !== except && candidate.ticket === ticket && candidate.host) return other;
    }
  };
  const deleteRoom = id => {
    const room = rooms.get(id);
    if (!room) return;
    rooms.delete(id);
    clearTimeout(room.dropPhone);
    if (room.ticket && tickets.get(room.ticket) === id) {
      const next = liveRoomFor(room.ticket, id);
      if (next) tickets.set(room.ticket, next); else tickets.delete(room.ticket);
    }
    room.phone?.terminate(); room.host?.terminate();
  };
  server.on('upgrade', (req, socket, head) => {
    // Node removes its socket error listener before 'upgrade'; a peer reset would crash the relay.
    socket.on('error', () => socket.destroy());
    const reject = () => { socket.end('HTTP/1.1 403 Forbidden\r\nConnection: close\r\n\r\n'); };
    const rawURL = req.url;
    req.url = rawURL.split('?')[0]; // Downstream diagnostics must not retain queries.
    let url;
    try { url = new URL(rawURL, publicOrigin); } catch { reject(); return; }
    const role = url.searchParams.get('role');
    // Fail closed for old clients: no bearer tickets in any upgrade URL.
    if (url.pathname !== '/connect' || (url.searchParams.has('ticket') || url.searchParams.has('room'))) { reject(); return; }
    let id, room;
    if (role === 'host') {
      if ((req.headers.origin && req.headers.origin !== publicOrigin)
        || !/^Bearer [a-f0-9]{64}$/.test(req.headers.authorization || '')) { reject(); return; }
    } else if (role === 'phone') {
      if (req.headers.origin !== publicOrigin) { reject(); return; }
    } else { reject(); return; }
    wss.handleUpgrade(req, socket, head, ws => {
      ws.on('error', () => {});
      ws.alive = true;
      ws.on('pong', () => { ws.alive = true; });
      let windowStart = now(), count = 0;
      const peer = randomBytes(16).toString('hex');
      // A fresh, single-use transport key protects the routing envelope. WSS
      // authenticates the relay; end-to-end device keys never enter this layer.
      let routingKey = token(), routed = false, incoming = Promise.resolve();
      const routeTimer = setTimeout(() => ws.close(1008), 10000);
      routeTimer.unref();
      send(ws, { route: routingKey });
      const take = slot => {
        const previous = room[slot];
        room[slot] = ws;
        if (previous && previous !== ws) previous.terminate();
      };
      ws.on('message', (bytes, binary) => {
        if (now() - windowStart >= 1000) { count = 0; windowStart = now(); }
        if (binary || ++count > 30) { ws.close(1008); return; }
        let value;
        try { value = JSON.parse(bytes.toString()); } catch { ws.close(1008); return; }
        if (!value || typeof value !== 'object' || Array.isArray(value)) { ws.close(1008); return; }
        incoming = incoming.then(async () => {
          if (!routed) {
            // A frame that arrived with the close frame still goes through;
            // only a new route needs a live socket.
            if (ws.readyState !== WebSocket.OPEN) return;
            if (typeof value.route !== 'string' || value.route.length > 2048) { ws.close(1008); return; }
            const route = await open(value.route, await importKey(routingKey), `relay-${role}`);
            if (ws.readyState !== WebSocket.OPEN) return;
            if (!route || typeof route !== 'object' || Array.isArray(route)
              || (route.ticket !== undefined && !hex64(route.ticket))
              || (route.room !== undefined && (typeof route.room !== 'string' || !/^[a-f0-9]{32}$/.test(route.room)))) {
              ws.close(1008); return;
            }
            if (role === 'phone') {
              const byTicket = tickets.has(route.ticket);
              id = byTicket ? tickets.get(route.ticket) : route.room;
              room = rooms.get(id);
              if (!room?.host) { ws.close(1008); return; }
              // Only a paired phone holds the ticket. After one routes by it, the QR room
              // id no longer lets anyone take the phone slot while the host keeps that ticket.
              if (byTicket) room.claimedBy = route.ticket;
              else if (room.claimedBy && room.claimedBy === room.ticket) { ws.close(1008); return; }
            } else {
              id = route.room; room = rooms.get(id);
              if (!room || !equal(req.headers.authorization, `Bearer ${room.hostToken}`)) { ws.close(1008); return; }
            }
            routed = true;
            routingKey = null;
            clearTimeout(routeTimer);
            if (role === 'host') {
              take('host');
              clearTimeout(room.dropPhone);
              room.dropPhone = undefined;
              if (route.ticket) {
                if (room.ticket && room.ticket !== route.ticket && tickets.get(room.ticket) === id) {
                  const next = liveRoomFor(room.ticket, id);
                  if (next) tickets.set(room.ticket, next); else tickets.delete(room.ticket);
                }
                room.ticket = route.ticket;
                // A second copy must not take the phone from a room whose host is live.
                if (!rooms.get(tickets.get(route.ticket))?.host || tickets.get(route.ticket) === id) tickets.set(route.ticket, id);
              }
              send(ws, { type: 'ready' });
              if (room.phone) send(ws, { type: 'peer', peer: room.peer });
            } else { take('phone'); room.peer = peer; send(room.host, { type: 'peer', peer }); }
            return;
          }
          const frame = {};
          if (typeof value.data === 'string' && value.data.length <= 100000) frame.data = value.data;
          else if (role === 'host' && typeof value.hello === 'string' && value.hello.length <= 64) frame.hello = value.hello;
          else if (role === 'host' && value.error === 'unauthorized') frame.error = value.error;
          else { ws.close(1008); return; }
          if (role === 'host') {
            if (room.host === ws && value.peer === room.peer) {
              send(room.phone, frame);
              if (frame.error) room.phone?.close(1008);
            }
          } else if (room.phone === ws) send(room.host, { peer, ...frame });
        }).catch(() => ws.close(1008));
      });
      ws.on('close', () => {
        clearTimeout(routeTimer);
        routingKey = null;
        if (!routed) return;
        if (role === 'host' && room.host === ws) {
          room.host = null; room.disconnectedAt = now();
          const next = room.ticket && tickets.get(room.ticket) === id && liveRoomFor(room.ticket, id);
          if (next) tickets.set(room.ticket, next);
          clearTimeout(room.dropPhone);
          const phone = room.phone;
          room.dropPhone = setTimeout(() => {
            if (room.host || room.phone !== phone) return;
            phone?.terminate();
            if (room.phone === phone) room.phone = null;
          }, 3000);
          room.dropPhone?.unref?.();
        } else if (room.phone === ws) {
          room.phone = null;
          send(room.host, { type: 'left', peer });
        }
      });
    });
  });
  const timer = setInterval(() => {
    for (const [id, room] of rooms) {
      if ((!room.host && now() - room.disconnectedAt > 300000) || now() - room.created > 86400000) deleteRoom(id);
    }
    for (const ws of wss.clients) {
      if (!ws.alive) ws.terminate();
      else { ws.alive = false; ws.ping(); }
    }
  }, 15000);
  timer.unref();
  return { server, close() {
    clearInterval(timer);
    for (const id of rooms.keys()) deleteRoom(id);
    for (const ws of wss.clients) ws.terminate();
    wss.close(); server.close(); server.closeAllConnections();
  } };
}
if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const relay = createRelay({ publicOrigin: process.env.PUBLIC_ORIGIN });
  relay.server.listen(Number(process.env.PORT || 3000), '0.0.0.0');
  process.on('SIGTERM', () => relay.close());
  process.on('SIGINT', () => relay.close());
}
