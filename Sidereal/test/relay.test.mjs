import test from 'node:test';
import assert from 'node:assert/strict';
import { once } from 'node:events';
import net from 'node:net';
import WebSocket from 'ws';
import { createRelay } from '../server.mjs';
import { importKey, seal } from '../public/crypto.mjs';

async function setup(t, options = {}) {
  const relay = createRelay({ publicOrigin: 'http://localhost:3099', ...options });
  relay.server.listen(0, '127.0.0.1');
  await once(relay.server, 'listening');
  const base = `http://127.0.0.1:${relay.server.address().port}`;
  t.after(() => relay.close());
  const res = await fetch(`${base}/rooms`, { method: 'POST' });
  return { ...await res.json(), base, relay };
}
function connect(base, room, role, options = {}) {
  const { ticket, ...wsOptions } = options;
  const params = new URLSearchParams({ role });
  const ws = new WebSocket(`${base.replace('http', 'ws')}/connect?${params}`, wsOptions);
  ws.on('error', () => {});
  ws.on('message', async bytes => {
    const frame = JSON.parse(bytes);
    if (!frame.route) return;
    const route = await seal({ ...(room ? { room } : {}), ticket },
      await importKey(frame.route), `relay-${role}`);
    if (ws.readyState === WebSocket.OPEN) ws.send(JSON.stringify({ route }));
  });
  assert.equal(new URL(ws.url).search, `?role=${role}`);
  return ws;
}
function ticket() { return 'ab'.repeat(32); }
function message(ws) {
  return new Promise(resolve => {
    function onMessage(data) {
      const frame = JSON.parse(data);
      if (frame.route) return;
      ws.off('message', onMessage); resolve(frame);
    }
    ws.on('message', onMessage);
  });
}

test('host is authenticated and ciphertext routes only to its paired room', async t => {
  const { base, room, hostToken } = await setup(t);
  const bad = connect(base, room, 'host');
  await once(bad, 'error');
  const host = connect(base, room, 'host', { headers: { Authorization: `Bearer ${hostToken}` } });
  assert.equal((await message(host)).type, 'ready');
  const peerNotice = message(host);
  const phone = connect(base, room, 'phone', { origin: 'http://localhost:3099' });
  const { peer } = await peerNotice;
  if (phone.readyState !== WebSocket.OPEN) await once(phone, 'open');
  const received = message(phone);
  host.send(JSON.stringify({ peer, hello: 'fresh-challenge' }));
  assert.deepEqual(await received, { hello: 'fresh-challenge' });
  const encrypted = message(host);
  phone.send(JSON.stringify({ data: 'opaque-ciphertext' }));
  assert.deepEqual(await encrypted, { peer, data: 'opaque-ciphertext' });
  const response = message(phone);
  host.send(JSON.stringify({ peer, data: 'encrypted-response' }));
  assert.deepEqual(await response, { data: 'encrypted-response' });
  const closed = once(phone, 'close');
  host.close();
  phone.close();
  await closed;
});

test('foreign browser origins and unknown rooms cannot connect', async t => {
  const { base, room } = await setup(t);
  await once(connect(base, room, 'phone', { origin: 'https://evil.example' }), 'error');
  assert.equal((await once(connect(base, '0'.repeat(32), 'phone', { origin: 'http://localhost:3099' }), 'close'))[0], 1008);
});

test('a host websocket may send the companion origin the way a bundled Mac app does', async t => {
  const { base, room, hostToken } = await setup(t);
  const allowed = connect(base, room, 'host', {
    headers: { Authorization: `Bearer ${hostToken}`, Origin: 'http://localhost:3099' },
  });
  assert.equal((await message(allowed)).type, 'ready');
  allowed.close();
  await once(
    connect(base, room, 'host', {
      headers: { Authorization: `Bearer ${hostToken}`, Origin: 'https://evil.example' },
    }),
    'error',
  );
});

test('HTTP has fixed asset routes and security headers', async t => {
  const { base } = await setup(t);
  const res = await fetch(`${base}/does-not-exist`);
  assert.equal(res.status, 404);
  assert.equal(res.headers.get('referrer-policy'), 'no-referrer');
  assert.match(res.headers.get('content-security-policy'), /default-src 'self'/);
  assert.match(res.headers.get('content-security-policy'), /media-src 'self' blob:/);
  assert.equal((await fetch(`${base}/rooms`)).status, 404);
  const pairing = await fetch(`${base}/pairing.mjs`);
  assert.equal(pairing.status, 200);
  assert.match(pairing.headers.get('content-type'), /javascript/);
  const scanner = await fetch(`${base}/jsqr.js`);
  assert.equal(scanner.status, 200);
  assert.match(scanner.headers.get('content-type'), /javascript/);
  for (const name of ['Inter-Regular', 'Inter-Medium', 'Inter-SemiBold', 'JetBrainsMono-Regular', 'JetBrainsMono-Medium']) {
    const font = await fetch(`${base}/fonts/${name}.woff2`);
    assert.equal(font.status, 200);
    assert.equal(font.headers.get('content-type'), 'font/woff2');
    assert.equal(Buffer.from(await font.arrayBuffer()).subarray(0, 4).toString('latin1'), 'wOF2');
  }
  const page = await (await fetch(`${base}/`)).text();
  assert.doesNotMatch(page, /apple-mobile-web-app-capable/);
  assert.doesNotMatch(page, /mobile-web-app-capable/);
  const manifest = await (await fetch(`${base}/manifest.webmanifest`)).json();
  assert.equal(manifest.display, 'browser');
});

test('rejecting an unauthorized phone closes it and releases the slot', async t => {
  const { base, room, hostToken } = await setup(t);
  const host = connect(base, room, 'host', { headers: { Authorization: `Bearer ${hostToken}` } });
  await message(host);
  const notice = message(host);
  const phone = connect(base, room, 'phone', { origin: 'http://localhost:3099' });
  const { peer } = await notice;
  const closed = once(phone, 'close');
  const left = message(host);
  host.send(JSON.stringify({ peer, error: 'unauthorized' }));
  await closed;
  assert.equal((await left).type, 'left');
  const nextNotice = message(host);
  const next = connect(base, room, 'phone', { origin: 'http://localhost:3099' });
  await once(next, 'open');
  assert.equal((await nextNotice).type, 'peer');
});

test('a host that rejects a phone and closes at once still reaches the phone', { timeout: 5000 }, async t => {
  const { base, room, hostToken } = await setup(t);
  const host = connect(base, room, 'host', { headers: { Authorization: `Bearer ${hostToken}` } });
  await message(host);
  const notice = message(host);
  const phone = connect(base, room, 'phone', { origin: 'http://localhost:3099' });
  const { peer } = await notice;
  const rejected = message(phone);
  // One write carries the rejection and the close frame, as when the Mac
  // revokes a pairing and cancels its socket straight away.
  host._socket.cork();
  host.send(JSON.stringify({ peer, error: 'unauthorized' }));
  host.close();
  host._socket.uncork();
  assert.equal((await rejected).error, 'unauthorized');
});

test('a client that resets a rejected upgrade does not crash the relay', { timeout: 5000 }, async t => {
  const { base, relay } = await setup(t);
  const closed = new Promise(resolve => relay.server.once('upgrade', (req, socket) => socket.once('close', resolve)));
  const client = net.connect(Number(new URL(base).port), '127.0.0.1');
  client.on('error', () => {});
  await once(client, 'connect');
  client.write('GET /connect?role=nope HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n'
    + 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n');
  client.resetAndDestroy();
  await closed;
  assert.equal((await fetch(`${base}/health`)).status, 200);
});

test('an older room survives a brief host disconnect and accepts reconnect', async t => {
  t.mock.timers.enable({ apis: ['setInterval'] });
  let clock = 0;
  const relay = createRelay({ publicOrigin: 'http://localhost:3099', now: () => clock });
  t.after(() => relay.close());
  relay.server.listen(0, '127.0.0.1');
  await once(relay.server, 'listening');
  const base = `http://127.0.0.1:${relay.server.address().port}`;
  const { room, hostToken } = await (await fetch(`${base}/rooms`, { method: 'POST' })).json();
  const options = { headers: { Authorization: `Bearer ${hostToken}` } };
  const host = connect(base, room, 'host', options);
  await message(host);
  clock = 301000;
  const closed = once(host, 'close');
  host.close(); await closed;
  clock += 100;
  t.mock.timers.tick(15000);
  const restored = connect(base, room, 'host', options);
  assert.equal((await message(restored)).type, 'ready');
});

test('a second phone takes over the occupied slot', async t => {
  const { base, room, hostToken } = await setup(t);
  const host = connect(base, room, 'host', { headers: { Authorization: `Bearer ${hostToken}` } });
  await message(host);
  const firstPeer = message(host);
  const first = connect(base, room, 'phone', { origin: 'http://localhost:3099' });
  await firstPeer;
  if (first.readyState !== WebSocket.OPEN) await once(first, 'open');
  const nextPeer = message(host);
  const firstClosed = once(first, 'close');
  const second = connect(base, room, 'phone', { origin: 'http://localhost:3099' });
  await once(second, 'open');
  await firstClosed;
  assert.equal((await nextPeer).type, 'peer');
});

test('a host reconnect with the same token replaces the old socket', async t => {
  const { base, room, hostToken } = await setup(t);
  const options = { headers: { Authorization: `Bearer ${hostToken}` } };
  const first = connect(base, room, 'host', options);
  await message(first);
  const firstClosed = once(first, 'close');
  const second = connect(base, room, 'host', options);
  assert.equal((await message(second)).type, 'ready');
  await firstClosed;
});

test('a host reconnect keeps the current phone and re-announces it', async t => {
  const { base, room, hostToken } = await setup(t);
  const options = { headers: { Authorization: `Bearer ${hostToken}` } };
  const first = connect(base, room, 'host', options);
  await message(first);
  const firstPeer = message(first);
  const phone = connect(base, room, 'phone', { origin: 'http://localhost:3099' });
  await firstPeer;
  if (phone.readyState !== WebSocket.OPEN) await once(phone, 'open');
  const second = connect(base, room, 'host', options);
  const frames = [];
  second.on('message', data => { const frame = JSON.parse(data); if (!frame.route) frames.push(frame); });
  while (frames.length < 2) await once(second, 'message');
  assert.equal(phone.readyState, WebSocket.OPEN);
  assert.equal(frames[0].type, 'ready');
  assert.equal(frames[1].type, 'peer');
  const received = message(phone);
  second.send(JSON.stringify({ peer: frames[1].peer, hello: 'ab'.repeat(32) }));
  assert.deepEqual(await received, { hello: 'ab'.repeat(32) });
});

test('a host that does not return eventually drops the phone', async t => {
  const { base, room, hostToken } = await setup(t);
  const host = connect(base, room, 'host', { headers: { Authorization: `Bearer ${hostToken}` } });
  await message(host);
  const firstPeer = message(host);
  const phone = connect(base, room, 'phone', { origin: 'http://localhost:3099' });
  await firstPeer;
  if (phone.readyState !== WebSocket.OPEN) await once(phone, 'open');
  const phoneClosed = once(phone, 'close');
  host.close();
  await once(host, 'close');
  assert.equal(phone.readyState, WebSocket.OPEN);
  await phoneClosed;
});

test('a host with the wrong token still cannot take the slot', async t => {
  const { base, room, hostToken } = await setup(t);
  const host = connect(base, room, 'host', { headers: { Authorization: `Bearer ${hostToken}` } });
  await message(host);
  await once(connect(base, room, 'host'), 'error');
});

test('an unknown ticket still connects when the room id is present', async t => {
  const { base, room, hostToken } = await setup(t);
  const host = connect(base, room, 'host', { headers: { Authorization: `Bearer ${hostToken}` } });
  await message(host);
  const notice = message(host);
  const phone = connect(base, room, 'phone', { origin: 'http://localhost:3099', ticket: ticket() });
  await once(phone, 'open');
  assert.equal((await notice).type, 'peer');
});

test('after a phone routes by ticket, a room-only phone cannot evict it', { timeout: 5000 }, async t => {
  const { base, room, hostToken } = await setup(t);
  const origin = 'http://localhost:3099';
  const host = connect(base, room, 'host', { headers: { Authorization: `Bearer ${hostToken}` }, ticket: ticket() });
  await message(host);
  const peers = [];
  host.on('message', data => { const frame = JSON.parse(data); if (frame.type === 'peer') peers.push(frame.peer); });
  // The QR room still bootstraps a phone before any phone holds the ticket.
  const bootstrap = connect(base, room, 'phone', { origin });
  await once(bootstrap, 'open');
  while (peers.length < 1) await new Promise(resolve => setTimeout(resolve, 10));
  bootstrap.close();
  await once(bootstrap, 'close');
  const paired = connect(base, room, 'phone', { origin, ticket: ticket() });
  await once(paired, 'open');
  while (peers.length < 2) await new Promise(resolve => setTimeout(resolve, 10));
  const stranger = connect(base, room, 'phone', { origin });
  const first = await Promise.race([
    once(stranger, 'close').then(([code]) => `stranger ${code}`),
    once(paired, 'close').then(() => 'paired'),
  ]);
  assert.equal(first, 'stranger 1008');
  assert.equal(paired.readyState, WebSocket.OPEN);
  assert.equal(peers.length, 2);
});

test('oversized frames are rejected', async t => {
  const { base, room, hostToken } = await setup(t);
  const host = connect(base, room, 'host', { headers: { Authorization: `Bearer ${hostToken}` } });
  await message(host);
  const peer = message(host);
  const phone = connect(base, room, 'phone', { origin: 'http://localhost:3099' });
  await peer;
  const closed = once(phone, 'close');
  phone.send('x'.repeat(110001));
  assert.equal((await closed)[0], 1009);
});

test('a phone can find a new room by ticket after the host reallocates', async t => {
  const relay = createRelay({ publicOrigin: 'http://localhost:3099' });
  t.after(() => relay.close());
  relay.server.listen(0, '127.0.0.1');
  await once(relay.server, 'listening');
  const base = `http://127.0.0.1:${relay.server.address().port}`;
  const first = await (await fetch(`${base}/rooms`, { method: 'POST' })).json();
  const host = connect(base, first.room, 'host', {
    headers: { Authorization: `Bearer ${first.hostToken}` }, ticket: ticket(),
  });
  await message(host);
  host.close();
  await once(host, 'close');
  const second = await (await fetch(`${base}/rooms`, { method: 'POST' })).json();
  const restored = connect(base, second.room, 'host', {
    headers: { Authorization: `Bearer ${second.hostToken}` }, ticket: ticket(),
  });
  await message(restored);
  const notice = message(restored);
  const phone = connect(base, null, 'phone', { origin: 'http://localhost:3099', ticket: ticket() });
  await once(phone, 'open');
  assert.equal((await notice).type, 'peer');
  const received = message(phone);
  restored.send(JSON.stringify({ peer: (await notice).peer, hello: 'fresh-challenge' }));
  assert.deepEqual(await received, { hello: 'fresh-challenge' });
});

test('deleting an old room does not drop a ticket that moved to a newer room', async t => {
  t.mock.timers.enable({ apis: ['setInterval'] });
  let clock = 0;
  const relay = createRelay({ publicOrigin: 'http://localhost:3099', now: () => clock });
  t.after(() => relay.close());
  relay.server.listen(0, '127.0.0.1');
  await once(relay.server, 'listening');
  const base = `http://127.0.0.1:${relay.server.address().port}`;
  const first = await (await fetch(`${base}/rooms`, { method: 'POST' })).json();
  const firstHost = connect(base, first.room, 'host', {
    headers: { Authorization: `Bearer ${first.hostToken}` }, ticket: ticket(),
  });
  await message(firstHost);
  firstHost.close();
  await once(firstHost, 'close');
  const second = await (await fetch(`${base}/rooms`, { method: 'POST' })).json();
  const restored = connect(base, second.room, 'host', {
    headers: { Authorization: `Bearer ${second.hostToken}` }, ticket: ticket(),
  });
  await message(restored);
  clock = 301000;
  t.mock.timers.tick(15000);
  const notice = message(restored);
  const phone = connect(base, null, 'phone', { origin: 'http://localhost:3099', ticket: ticket() });
  await once(phone, 'open');
  assert.equal((await notice).type, 'peer');
});

test('a second host with the same ticket keeps off the phone until the first host leaves', async t => {
  const relay = createRelay({ publicOrigin: 'http://localhost:3099' });
  t.after(() => relay.close());
  relay.server.listen(0, '127.0.0.1');
  await once(relay.server, 'listening');
  const base = `http://127.0.0.1:${relay.server.address().port}`;
  const within = promise => Promise.race([promise, new Promise(resolve => setTimeout(() => resolve('timeout'), 1000))]);
  const first = await (await fetch(`${base}/rooms`, { method: 'POST' })).json();
  const second = await (await fetch(`${base}/rooms`, { method: 'POST' })).json();
  const installed = connect(base, first.room, 'host', {
    headers: { Authorization: `Bearer ${first.hostToken}` }, ticket: ticket(),
  });
  await message(installed);
  const copy = connect(base, second.room, 'host', {
    headers: { Authorization: `Bearer ${second.hostToken}` }, ticket: ticket(),
  });
  await message(copy);
  const notice = message(installed);
  const phone = connect(base, null, 'phone', { origin: 'http://localhost:3099', ticket: ticket() });
  assert.equal((await within(notice)).type, 'peer');
  const left = message(installed);
  phone.close();
  await left;
  installed.close();
  await once(installed, 'close');
  const handedOver = message(copy);
  const next = connect(base, null, 'phone', { origin: 'http://localhost:3099', ticket: ticket() });
  assert.equal((await within(handedOver)).type, 'peer');
  next.close();
});

test('rebinding a room ticket drops the previous mapping', async t => {
  const { base, room, hostToken } = await setup(t);
  const first = 'ab'.repeat(32);
  const second = 'cd'.repeat(32);
  const host = connect(base, room, 'host', {
    headers: { Authorization: `Bearer ${hostToken}` }, ticket: first,
  });
  await message(host);
  host.close();
  await once(host, 'close');
  const restored = connect(base, room, 'host', {
    headers: { Authorization: `Bearer ${hostToken}` }, ticket: second,
  });
  await message(restored);
  assert.equal((await once(connect(base, null, 'phone', { origin: 'http://localhost:3099', ticket: first }), 'close'))[0], 1008);
  const notice = message(restored);
  const phone = connect(base, null, 'phone', { origin: 'http://localhost:3099', ticket: second });
  await once(phone, 'open');
  assert.equal((await notice).type, 'peer');
});

test('ticket connects reject a short token and a missing host', async t => {
  const { base, room, hostToken } = await setup(t);
  assert.equal((await once(connect(base, null, 'phone', { origin: 'http://localhost:3099', ticket: ticket() }), 'close'))[0], 1008);
  await once(
    connect(base, room, 'host', { headers: { Authorization: `Bearer ${hostToken}` }, ticket: 'short' }),
    'close',
  );
});

test('room allocation rejects browser requests and excessive creation', async t => {
  const { base } = await setup(t);
  assert.equal((await fetch(`${base}/rooms`, { method: 'POST', headers: { Origin: 'http://localhost:3099' } })).status, 403);
  for (let i = 0; i < 19; i++) assert.equal((await fetch(`${base}/rooms`, { method: 'POST' })).status, 201);
  assert.equal((await fetch(`${base}/rooms`, { method: 'POST' })).status, 429);
});


function unregisteredPhone(base) {
  const ws = new WebSocket(`${base.replace('http', 'ws')}/connect?role=phone`, { origin: 'http://localhost:3099' });
  ws.on('error', () => {});
  return ws;
}
const routingHello = ws => once(ws, 'message').then(([bytes]) => JSON.parse(bytes).route);

test('query tickets are rejected for both roles and removed from downstream request diagnostics', async t => {
  const { base, room, hostToken, relay } = await setup(t);
  const paths = [];
  relay.server.on('upgrade', req => paths.push(req.url));
  relay.server.on('request', req => paths.push(req.url));
  for (const role of ['host', 'phone']) {
    const ws = new WebSocket(`${base.replace('http', 'ws')}/connect?role=${role}&room=${room}&ticket=${ticket()}`,
      { origin: 'http://localhost:3099', headers: { Authorization: `Bearer ${hostToken}` } });
    await once(ws, 'error');
  }
  await fetch(`${base}/health?ticket=${ticket()}`);
  assert.deepEqual(paths, ['/connect', '/connect', '/health']);
});

test('an unsealed routing ticket cannot displace the active phone', async t => {
  const { base, room, hostToken } = await setup(t);
  const host = connect(base, room, 'host', { headers: { Authorization: `Bearer ${hostToken}` }, ticket: ticket() });
  await message(host);
  const notice = message(host);
  const phone = connect(base, room, 'phone', { origin: 'http://localhost:3099' });
  await notice;
  const attacker = unregisteredPhone(base);
  await routingHello(attacker);
  const closed = once(attacker, 'close');
  attacker.send(JSON.stringify({ ticket: ticket(), room }));
  assert.equal((await closed)[0], 1008);
  assert.equal(phone.readyState, WebSocket.OPEN);
  const received = message(host);
  phone.send(JSON.stringify({ data: 'still-connected' }));
  assert.equal((await received).data, 'still-connected');
});

test('a routing envelope is single-use and cannot be replayed on another socket or direction', async t => {
  const { base, room, hostToken } = await setup(t);
  const host = connect(base, room, 'host', { headers: { Authorization: `Bearer ${hostToken}` }, ticket: ticket() });
  await message(host);
  const original = unregisteredPhone(base);
  const key = await importKey(await routingHello(original));
  const route = await seal({ ticket: ticket() }, key, 'relay-phone');
  const notice = message(host);
  original.send(JSON.stringify({ route }));
  await notice;
  const attacker = unregisteredPhone(base);
  await routingHello(attacker);
  const closed = once(attacker, 'close');
  attacker.send(JSON.stringify({ route }));
  assert.equal((await closed)[0], 1008);
  assert.equal(original.readyState, WebSocket.OPEN);
  const reflected = unregisteredPhone(base);
  const reflectionKey = await importKey(await routingHello(reflected));
  const reflectedClosed = once(reflected, 'close');
  reflected.send(JSON.stringify({ route: await seal({ ticket: ticket() }, reflectionKey, 'relay-host') }));
  assert.equal((await reflectedClosed)[0], 1008);
  assert.equal(original.readyState, WebSocket.OPEN);
  const reused = once(original, 'close');
  original.send(JSON.stringify({ route }));
  assert.equal((await reused)[0], 1008);
});

test('routing handshakes time out without taking a phone slot', async t => {
  const { base } = await setup(t);
  t.mock.timers.enable({ apis: ['setTimeout'] });
  const phone = unregisteredPhone(base);
  await routingHello(phone);
  const closed = once(phone, 'close');
  t.mock.timers.tick(10000);
  assert.equal((await closed)[0], 1008);
});


test('a well-formed wrong host token cannot register a ticket or replace the host', async t => {
  const { base, room, hostToken } = await setup(t);
  const host = connect(base, room, 'host', { headers: { Authorization: `Bearer ${hostToken}` }, ticket: ticket() });
  await message(host);
  const attacker = connect(base, room, 'host', { headers: { Authorization: `Bearer ${'0'.repeat(64)}` }, ticket: ticket() });
  assert.equal((await once(attacker, 'close'))[0], 1008);
  assert.equal(host.readyState, WebSocket.OPEN);
  const notice = message(host);
  connect(base, null, 'phone', { origin: 'http://localhost:3099', ticket: ticket() });
  assert.equal((await notice).type, 'peer');
});

function fakeAPNs() {
  const sent = [];
  return { sent, async send(request) { sent.push(request); return { status: request.token.startsWith('dead') ? 410 : 200 }; }, close() {} };
}

test('a host registers the phone token and sends sealed alerts and activity updates through APNs', async t => {
  const apns = fakeAPNs();
  const { base, room, hostToken } = await setup(t, { apns });
  const host = connect(base, room, 'host', { headers: { Authorization: `Bearer ${hostToken}` } });
  assert.deepEqual(await message(host), { type: 'ready' });
  // Alerts before a token: refused, not delivered.
  host.send(JSON.stringify({ push: { data: 'c2VhbGVk', thread: 'tab-1' } }));
  assert.deepEqual(await message(host), { type: 'push', ok: false, reason: 'token' });
  host.send(JSON.stringify({ pushToken: 'ab'.repeat(32), pushEnvironment: 'development' }));
  host.send(JSON.stringify({ push: { data: 'c2VhbGVk', thread: 'tab-1' } }));
  assert.deepEqual(await message(host), { type: 'push', ok: true, status: 200 });
  assert.equal(apns.sent.length, 1);
  assert.equal(apns.sent[0].environment, 'development');
  assert.equal(apns.sent[0].token, 'ab'.repeat(32));
  assert.equal(apns.sent[0].pushType, 'alert');
  assert.equal(apns.sent[0].collapseId, 'tab-1');
  assert.equal(apns.sent[0].payload.aps['mutable-content'], 1);
  assert.equal(apns.sent[0].payload.aps['thread-id'], 'tab-1');
  assert.equal(apns.sent[0].payload.sigil.data, 'c2VhbGVk');
  // The relay adds nothing readable: the body is the same for every alert.
  assert.equal(apns.sent[0].payload.aps.alert.body, 'A session needs you.');

  host.send(JSON.stringify({ push: { activity: 'cd'.repeat(40), event: 'update', state: { status: 'working', since: 1700000000, asking: false, secret: 'no' } } }));
  assert.deepEqual(await message(host), { type: 'push', ok: true, status: 200 });
  assert.equal(apns.sent[1].pushType, 'liveactivity');
  assert.equal(apns.sent[1].token, 'cd'.repeat(40));
  assert.deepEqual(apns.sent[1].payload.aps['content-state'], { status: 'working', since: 1700000000, asking: false });
  assert.equal(apns.sent[1].payload.aps.event, 'update');
  assert.equal(apns.sent[1].payload.aps['dismissal-date'], undefined);
  host.send(JSON.stringify({ push: { activity: 'cd'.repeat(40), event: 'end', state: { status: 'exited' } } }));
  assert.deepEqual(await message(host), { type: 'push', ok: true, status: 200 });
  assert.ok(apns.sent[2].payload.aps['dismissal-date'] > apns.sent[2].payload.aps.timestamp);

  // An ended activity's 410 leaves the phone's alert token alone.
  host.send(JSON.stringify({ push: { activity: 'dead' + 'cd'.repeat(38), event: 'update', state: { status: 'idle' } } }));
  assert.deepEqual(await message(host), { type: 'push', ok: false, status: 410 });
  host.send(JSON.stringify({ push: { data: 'c2VhbGVk' } }));
  assert.deepEqual(await message(host), { type: 'push', ok: true, status: 200 });
  // A dead alert token is forgotten after Apple says so.
  host.send(JSON.stringify({ pushToken: 'dead' + 'ab'.repeat(30), pushEnvironment: 'production' }));
  host.send(JSON.stringify({ push: { data: 'c2VhbGVk' } }));
  assert.deepEqual(await message(host), { type: 'push', ok: false, status: 410 });
  host.send(JSON.stringify({ push: { data: 'c2VhbGVk' } }));
  assert.deepEqual(await message(host), { type: 'push', ok: false, reason: 'token' });
  host.close();
});

test('push frames are validated, rate limited, and never accepted from a phone', async t => {
  const apns = fakeAPNs();
  const { base, room, hostToken } = await setup(t, { apns });
  const host = connect(base, room, 'host', { headers: { Authorization: `Bearer ${hostToken}` } });
  assert.deepEqual(await message(host), { type: 'ready' });
  host.send(JSON.stringify({ pushToken: 'ab'.repeat(32), pushEnvironment: 'development' }));
  for (const bad of [
    { push: { data: 'not base64!' } },
    { push: { activity: 'cd'.repeat(40), event: 'update', state: { since: 1 } } },
    { push: { activity: 'cd'.repeat(40), event: 'later', state: { status: 'idle' } } },
    { push: 'x' },
  ]) {
    const ws = connect(base, room, 'host', { headers: { Authorization: `Bearer ${hostToken}` } });
    assert.deepEqual(await message(ws), { type: 'ready' });
    ws.send(JSON.stringify({ pushToken: 'ab'.repeat(32), pushEnvironment: 'development' }));
    ws.send(JSON.stringify(bad));
    assert.equal((await once(ws, 'close'))[0], 1008);
  }
  for (const bad of [{ pushToken: 'xyz', pushEnvironment: 'development' }, { pushToken: 'ab'.repeat(32), pushEnvironment: 'staging' }]) {
    const ws = connect(base, room, 'host', { headers: { Authorization: `Bearer ${hostToken}` } });
    assert.deepEqual(await message(ws), { type: 'ready' });
    ws.send(JSON.stringify(bad));
    assert.equal((await once(ws, 'close'))[0], 1008);
  }
  assert.equal(apns.sent.length, 0);

  const live = connect(base, room, 'host', { headers: { Authorization: `Bearer ${hostToken}` } });
  assert.deepEqual(await message(live), { type: 'ready' });
  live.send(JSON.stringify({ pushToken: 'ab'.repeat(32), pushEnvironment: 'development' }));
  // Frames per second are capped at 30 by the socket; spread the pushes over three seconds.
  let refused = 0;
  for (let i = 0; i < 61; i++) {
    if (i && i % 20 === 0) await new Promise(resolve => setTimeout(resolve, 1050));
    live.send(JSON.stringify({ push: { data: 'c2VhbGVk' } }));
    const reply = await message(live);
    if (reply.reason === 'rate') refused++;
  }
  assert.equal(refused, 1);
  assert.equal(apns.sent.length, 60);

  const peerNotice = message(live);
  const phone = connect(base, room, 'phone', { origin: 'http://localhost:3099' });
  await peerNotice;
  phone.send(JSON.stringify({ push: { data: 'c2VhbGVk' } }));
  assert.equal((await once(phone, 'close'))[0], 1008);
  live.close();
});

test('without APNs settings push frames are answered as off and nothing else changes', async t => {
  const { base, room, hostToken } = await setup(t);
  const host = connect(base, room, 'host', { headers: { Authorization: `Bearer ${hostToken}` } });
  assert.deepEqual(await message(host), { type: 'ready' });
  host.send(JSON.stringify({ pushToken: 'ab'.repeat(32), pushEnvironment: 'production' }));
  host.send(JSON.stringify({ push: { data: 'c2VhbGVk' } }));
  assert.deepEqual(await message(host), { type: 'push', ok: false, reason: 'off' });
  host.send(JSON.stringify({ pushToken: null }));
  host.send(JSON.stringify({ push: { data: 'c2VhbGVk' } }));
  assert.deepEqual(await message(host), { type: 'push', ok: false, reason: 'off' });
  host.close();
});
