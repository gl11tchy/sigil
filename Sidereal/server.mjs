import http from 'node:http';
import { readFile, stat } from 'node:fs/promises';
import { createHash, randomBytes, timingSafeEqual } from 'node:crypto';
import { pathToFileURL } from 'node:url';
import { promisify } from 'node:util';
import { brotliCompress, gzip } from 'node:zlib';
import { WebSocketServer, WebSocket } from 'ws';
import { importKey, open } from './public/crypto.mjs';
import { loadRevision } from './revision.mjs';
import { createAPNs } from './apns.mjs';
import { isIP } from 'node:net';

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
const compressors = { br: promisify(brotliCompress), gzip: promisify(gzip) };
const compressible = type => type.startsWith('text/') || type.endsWith('+xml') || type.endsWith('+json');
// The first of br and gzip the client accepts; otherwise the file goes out as it is.
function encoding(header) {
  const accepted = new Map(String(header || '').split(',').map(part => {
    const [name, ...params] = part.toLowerCase().split(';').map(value => value.trim());
    const q = params.find(value => value.startsWith('q='));
    return [name, q ? Number(q.slice(2)) : 1];
  }));
  return ['br', 'gzip'].find(name => accepted.get(name) > 0);
}
// If-None-Match uses the weak comparison: W/"x" matches "x".
const unchanged = (header, etag) => typeof header === 'string' &&
  header.split(',').some(tag => ['*', etag, `W/${etag}`].includes(tag.trim()));
// Each file is read, hashed and compressed once per version on disk. A changed size, mtime,
// ctime or inode reloads it, so a new deployment's code is never answered from an old copy.
function publicFiles() {
  const files = new Map();
  return async (name, wanted) => {
    const url = new URL(`public/${name}`, import.meta.url);
    const { size, mtimeMs, ctimeMs, ino } = await stat(url);
    const version = `${size}:${mtimeMs}:${ctimeMs}:${ino}`;
    let file = files.get(name);
    if (file?.version !== version) {
      const identity = readFile(url).then(body => ({ body, etag: `"${createHash('sha256').update(body).digest('base64url')}"` }));
      file = { version, identity, encoded: new Map() };
      files.set(name, file);
    }
    try {
      const plain = await file.identity;
      if (!wanted) return plain;
      if (!file.encoded.has(wanted)) {
        file.encoded.set(wanted, compressors[wanted](plain.body).then(body => body.byteLength < plain.body.byteLength
          ? { body, etag: `${plain.etag.slice(0, -1)}-${wanted}"`, encoding: wanted } : plain));
      }
      return await file.encoded.get(wanted);
    } catch (error) {
      if (files.get(name) === file) files.delete(name);
      throw error;
    }
  };
}

// Only the transport peer is established here. Forwarding headers and a boolean
// proxy flag cannot authenticate a source. IPv6 privacy addresses share a /64;
// IPv4-mapped IPv6 uses the same budget as its ordinary IPv4 spelling.
export function clientAddress(request) {
  const value = request.socket?.remoteAddress;
  if (typeof value !== 'string' || value.length > 128) return null;
  const version = isIP(value);
  if (version === 4) return `4:${value}`;
  if (version !== 6) return null;
  const halves = value.toLowerCase().split('%')[0].split('::');
  const words = part => !part ? [] : part.split(':').flatMap(word => {
    if (!word.includes('.')) return [Number.parseInt(word, 16)];
    const bytes = word.split('.').map(Number);
    return [bytes[0] * 256 + bytes[1], bytes[2] * 256 + bytes[3]];
  });
  const left = words(halves[0]), right = words(halves[1]);
  const address = halves.length === 1 ? left : [...left, ...Array(8 - left.length - right.length).fill(0), ...right];
  if (address.slice(0, 5).every(word => word === 0) && address[5] === 0xffff) {
    return `4:${address[6] >> 8}.${address[6] & 255}.${address[7] >> 8}.${address[7] & 255}`;
  }
  return `6:${address.slice(0, 4).map(word => word.toString(16).padStart(4, '0')).join(':')}`;
}

export class SourceLimits {
  #sources = new Map();
  #now;
  #maxSources;

  constructor({ now = Date.now, maxSources = 1024 } = {}) {
    if (!Number.isInteger(maxSources) || maxSources < 1 || maxSources > 1024) throw new RangeError('Invalid source capacity.');
    this.#now = now;
    this.#maxSources = maxSources;
  }

  #entry(source) {
    if (!source) return null;
    let entry = this.#sources.get(source);
    const time = this.#now();
    if (!entry) {
      if (this.#sources.size >= this.#maxSources) this.sweep();
      if (this.#sources.size >= this.#maxSources) return null;
      entry = { tokens: 5, refill: time, touched: time, rooms: 0, sockets: 0 };
      this.#sources.set(source, entry);
    }
    entry.tokens = Math.min(5, entry.tokens + Math.max(0, time - entry.refill) / 12000);
    entry.refill = Math.max(entry.refill, time);
    entry.touched = Math.max(entry.touched, time);
    return entry;
  }

  allocate(source) {
    const entry = this.#entry(source);
    // Room slots include five-minute reconnect grace. Leave room for a NAT's
    // recoveries while one source can own at most a fifth of global capacity.
    if (!entry || entry.rooms >= 20 || entry.tokens < 1) return false;
    entry.tokens -= 1;
    entry.rooms += 1;
    return true;
  }

  releaseRoom(source) {
    const entry = this.#sources.get(source);
    if (!entry || entry.rooms === 0) return;
    entry.rooms -= 1;
    entry.touched = Math.max(entry.touched, this.#now());
  }

  reserveConnection(source) {
    const entry = this.#entry(source);
    if (!entry || entry.sockets >= 20) return null;
    entry.sockets += 1;
    let released = false;
    return () => {
      if (released) return;
      released = true;
      entry.sockets -= 1;
      entry.touched = Math.max(entry.touched, this.#now());
    };
  }

  sweep() {
    const time = this.#now();
    for (const [source, entry] of this.#sources) {
      // An idle minute also fully replenishes the five-token bucket. Never
      // evict occupied entries or let eviction grant an early fresh budget.
      if (!entry.rooms && !entry.sockets && time - entry.touched >= 60000) this.#sources.delete(source);
    }
  }
}

export function createRelay({ publicOrigin, maxRooms = 100, now = Date.now, apns = null } = {}) {
  if (!Number.isInteger(maxRooms) || maxRooms < 1 || maxRooms > 100) throw new RangeError('Room capacity must be between 1 and 100.');
  const origin = new URL(publicOrigin);
  if (origin.origin !== publicOrigin || !(origin.protocol === 'https:' ||
      (origin.protocol === 'http:' && ['localhost', '127.0.0.1'].includes(origin.hostname)))) {
    throw new Error('PUBLIC_ORIGIN must be an HTTPS origin (HTTP is allowed only on loopback).');
  }
  const rooms = new Map();
  const tickets = new Map();
  const limits = new SourceLimits({ now });
  const wss = new WebSocketServer({ noServer: true, maxPayload: 110000, perMessageDeflate: false });
  const files = publicFiles();
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
      const source = clientAddress(req);
      if (!source) { res.writeHead(403).end(); return; }
      expireRooms();
      if (rooms.size >= maxRooms || !limits.allocate(source)) { res.writeHead(429).end(); return; }
      const room = randomBytes(16).toString('hex'), hostToken = token();
      rooms.set(room, { hostToken, source, created: now(), disconnectedAt: now(), hosted: false, host: null, phone: null });
      res.writeHead(201, { 'Content-Type': 'application/json' }).end(JSON.stringify({ room, hostToken }));
      return;
    }
    const asset = req.method === 'GET' && assets.get(req.url);
    if (!asset) { res.writeHead(404).end(); return; }
    try {
      const compress = compressible(asset[1]);
      const file = await files(asset[0], compress && encoding(req.headers['accept-encoding']));
      const font = asset[1].startsWith('font/');
      // Fonts never change under one name and weigh ~500 KB; let the phone keep them.
      // Everything else is kept but checked on each use, so a new deployment's code loads at once.
      res.setHeader('Cache-Control', font ? 'public, max-age=604800, immutable' : 'no-cache');
      res.setHeader('ETag', file.etag);
      if (compress) res.setHeader('Vary', 'Accept-Encoding');
      if (unchanged(req.headers['if-none-match'], file.etag)) { res.writeHead(304).end(); return; }
      if (file.encoding) res.setHeader('Content-Encoding', file.encoding);
      res.writeHead(200, { 'Content-Type': font ? asset[1] : `${asset[1]}; charset=utf-8`, 'Content-Length': file.body.byteLength }).end(file.body);
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
  // Alerts for a phone that is away. The host registers the phone's device token
  // once per connection; the relay keeps it only as long as the room lives and
  // never logs it. Payload text stays sealed: the phone's extension opens it.
  const hexToken = value => typeof value === 'string' && value.length >= 64 && value.length <= 200 && /^[a-f0-9]+$/.test(value);
  const pushEnvironments = new Set(['production', 'development']);
  const registerPush = (room, value) => {
    if (value.pushToken === null) { room.push = undefined; return true; }
    if (!hexToken(value.pushToken) || !pushEnvironments.has(value.pushEnvironment)) return false;
    room.push = { token: value.pushToken, environment: value.pushEnvironment };
    return true;
  };
  const activityState = state => {
    if (!state || typeof state !== 'object' || Array.isArray(state)) return null;
    const out = {};
    if (typeof state.status === 'string' && state.status.length <= 16) out.status = state.status;
    if (typeof state.since === 'number' && Number.isFinite(state.since)) out.since = state.since;
    if (typeof state.asking === 'boolean') out.asking = state.asking;
    return out.status ? out : null;
  };
  const pushLifetimes = { alert: 300, update: 60, end: 900 };
  const pushTiming = (push, lifetime) => {
    const receivedAt = Math.floor(now() / 1000);
    // Old hosts cannot reveal their sealed original issuance. Preserve no-store
    // behavior instead of granting a new lifetime when a queued push is sent.
    if (!Object.hasOwn(push, 'issuedAt') && !Object.hasOwn(push, 'expiresAt')) {
      return { issuedAt: receivedAt, expiration: 0, expiresAt: null };
    }
    const { issuedAt, expiresAt } = push;
    if (!Number.isSafeInteger(issuedAt) || !Number.isSafeInteger(expiresAt) || issuedAt <= 0 ||
        issuedAt > receivedAt + 30 || expiresAt <= issuedAt || expiresAt - issuedAt > lifetime) return null;
    return { issuedAt, expiration: expiresAt, expiresAt };
  };
  // Returns what builds the APNs request for a host's push frame from the phone's
  // registration when it goes out, or null when the frame is malformed. It keeps only
  // the checked fields, never the frame.
  const pushRequest = (push, roomID) => {
    if (!push || typeof push !== 'object' || Array.isArray(push)) return null;
    if (typeof push.data === 'string') {
      if (push.data.length > 3000 || !/^[A-Za-z0-9+/=]+$/.test(push.data)) return null;
      const thread = typeof push.thread === 'string' && /^[A-Za-z0-9-]{1,64}$/.test(push.thread) ? push.thread : undefined;
      const data = push.data;
      const timing = pushTiming(push, pushLifetimes.alert);
      if (!timing) return null;
      const collapseId = thread ? createHash('sha256').update(JSON.stringify([roomID, thread])).digest('hex') : undefined;
      return { expiresAt: timing.expiresAt, build: registration => ({
        environment: registration?.environment, token: registration?.token, pushType: 'alert', collapseId,
        expiration: timing.expiration,
        payload: {
          aps: {
            alert: { title: 'Sigil', body: 'A session needs you.' }, sound: 'default', 'mutable-content': 1,
            category: 'SESSION', ...(thread ? { 'thread-id': thread } : {}),
          },
          sigil: { data },
        },
      }) };
    }
    if (hexToken(push.activity) && (push.event === 'update' || push.event === 'end')) {
      const state = activityState(push.state);
      if (!state) return null;
      const { activity, event } = push;
      const timing = pushTiming(push, pushLifetimes[event]);
      if (!timing) return null;
      return { expiresAt: timing.expiresAt, build: registration => {
        const seconds = timing.issuedAt;
        return {
          environment: registration?.environment, token: activity, pushType: 'liveactivity', priority: 10,
          expiration: timing.expiration,
          payload: {
            aps: {
              timestamp: seconds, event, 'content-state': state,
              ...(event === 'end' ? { 'dismissal-date': seconds + 300 } : {}),
            },
          },
        };
      } };
    }
    return null;
  };
  // Apple can take ten seconds to answer. Pushes wait in a short queue per room, sent one at a
  // time in order, so a reply to the phone never waits behind one. A push keeps the token
  // registered before it; a full queue answers at once instead of holding more.
  const maxQueuedPushes = 60;
  const queuePush = (ws, room, roomID, push) => {
    const request = pushRequest(push, roomID);
    if (!request) return false;
    const { build, expiresAt } = request;
    if (expiresAt !== null && expiresAt <= Math.floor(now() / 1000)) {
      send(ws, { type: 'push', ok: false, reason: 'expired' }); return true;
    }
    const queue = room.pushes ??= [];
    if (queue.length >= maxQueuedPushes) { send(ws, { type: 'push', ok: false, reason: 'busy' }); return true; }
    queue.push({ ws, build, expiresAt, registration: room.push });
    if (queue.length === 1) deliverPushes(room).catch(() => {});
    return true;
  };
  // The first push in the queue is the one with Apple; every push gets its answer in turn.
  const deliverPushes = async room => {
    const queue = room.pushes;
    while (queue.length) {
      const { ws, build, expiresAt, registration } = queue[0];
      let answer;
      // A host connection that closed or was replaced sends nothing more, and its pushes do not count.
      const live = !room.closed && room.host === ws;
      if (live && now() - (room.pushWindow || 0) >= 60000) { room.pushWindow = now(); room.pushCount = 0; }
      if (!live) answer = { ok: false, reason: 'closed' };
      else if (expiresAt !== null && expiresAt <= Math.floor(now() / 1000)) answer = { ok: false, reason: 'expired' };
      else if (++room.pushCount > 60) answer = { ok: false, reason: 'rate' };
      else if (!apns || !registration || registration.gone) answer = { ok: false, reason: apns ? 'token' : 'off' };
      else {
        const request = build(registration);
        try {
          const { status } = await apns.send(request);
          // Apple's 410 names the token it was sent: an ended activity's, not the phone's.
          if (status === 410 && request.pushType === 'alert') {
            registration.gone = true;
            if (room.push === registration) room.push = undefined;
          }
          answer = { ok: status === 200, status };
        } catch {
          answer = { ok: false, reason: 'unreachable' };
        }
      }
      queue.shift();
      send(ws, { type: 'push', ...answer });
    }
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
    limits.releaseRoom(room.source);
    clearTimeout(room.dropPhone);
    // Queued pushes not yet with Apple are not sent; the host hears so before its socket goes.
    room.closed = true;
    for (const { ws } of room.pushes?.splice(1) ?? []) send(ws, { type: 'push', ok: false, reason: 'closed' });
    if (room.ticket && tickets.get(room.ticket) === id) {
      const next = liveRoomFor(room.ticket, id);
      if (next) tickets.set(room.ticket, next); else tickets.delete(room.ticket);
    }
    room.phone?.terminate(); room.host?.terminate();
  };
  server.on('upgrade', (req, socket, head) => {
    // Node removes its socket error listener before 'upgrade'; a peer reset would crash the relay.
    socket.on('error', () => socket.destroy());
    const reject = (status = 403) => {
      socket.once('finish', () => socket.destroy());
      socket.end(`HTTP/1.1 ${status} ${status === 429 ? 'Too Many Requests' : 'Forbidden'}\r\nConnection: close\r\n\r\n`);
    };
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
    const source = clientAddress(req);
    if (!source) { reject(); return; }
    const release = limits.reserveConnection(source);
    if (!release) { reject(429); return; }
    socket.once('close', release);
    try { wss.handleUpgrade(req, socket, head, ws => {
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
              if (room && !room.hosted && now() - room.created >= 30000) { deleteRoom(id); room = undefined; }
              if (!room || !equal(req.headers.authorization, `Bearer ${room.hostToken}`)) { ws.close(1008); return; }
            }
            routed = true;
            routingKey = null;
            clearTimeout(routeTimer);
            if (role === 'host') {
              room.hosted = true;
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
          if (role === 'host' && room.host === ws && ('pushToken' in value || 'push' in value)) {
            if ('pushToken' in value ? !registerPush(room, value) : !queuePush(ws, room, id, value.push)) ws.close(1008);
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
    }); } catch { release(); socket.destroy(); }
  });
  function expireRooms() {
    for (const [id, room] of rooms) {
      if ((!room.hosted && now() - room.created >= 30000) ||
          (!room.host && now() - room.disconnectedAt > 300000) || now() - room.created > 86400000) deleteRoom(id);
    }
  }
  const timer = setInterval(() => {
    expireRooms();
    limits.sweep();
    for (const ws of wss.clients) {
      if (!ws.alive) ws.terminate();
      else { ws.alive = false; ws.ping(); }
    }
  }, 15000);
  timer.unref();
  return { server, close() {
    clearInterval(timer);
    apns?.close?.();
    for (const id of rooms.keys()) deleteRoom(id);
    for (const ws of wss.clients) ws.terminate();
    wss.close(); server.close(); server.closeAllConnections();
  } };
}
if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const relay = createRelay({
    publicOrigin: process.env.PUBLIC_ORIGIN,
    apns: createAPNs({
      key: process.env.APNS_KEY, keyId: process.env.APNS_KEY_ID, teamId: process.env.APNS_TEAM_ID,
      topic: process.env.APNS_TOPIC,
    }),
  });
  relay.server.listen(Number(process.env.PORT || 3000), '0.0.0.0');
  process.on('SIGTERM', () => relay.close());
  process.on('SIGINT', () => relay.close());
}
