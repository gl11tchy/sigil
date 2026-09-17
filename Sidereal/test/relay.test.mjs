import test from 'node:test';
import assert from 'node:assert/strict';
import { once } from 'node:events';
import WebSocket from 'ws';
import { createRelay } from '../server.mjs';

async function setup(t) {
  const relay = createRelay({ publicOrigin: 'http://localhost:3099' });
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
  if (room) params.set('room', room);
  if (ticket) params.set('ticket', ticket);
  const ws = new WebSocket(`${base.replace('http', 'ws')}/connect?${params}`, wsOptions);
  ws.on('error', () => {});
  return ws;
}
function ticket() { return 'ab'.repeat(32); }
function message(ws) { return once(ws, 'message').then(([data]) => JSON.parse(data)); }

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
  await closed;
});

test('foreign browser origins and unknown rooms cannot connect', async t => {
  const { base, room } = await setup(t);
  for (const [id, origin] of [[room, 'https://evil.example'], ['0'.repeat(32), 'http://localhost:3099']]) {
    await once(connect(base, id, 'phone', { origin }), 'error');
  }
});

test('HTTP has fixed asset routes and security headers', async t => {
  const { base } = await setup(t);
  const res = await fetch(`${base}/does-not-exist`);
  assert.equal(res.status, 404);
  assert.equal(res.headers.get('referrer-policy'), 'no-referrer');
  assert.match(res.headers.get('content-security-policy'), /default-src 'self'/);
  assert.equal((await fetch(`${base}/rooms`)).status, 404);
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

test('an occupied phone slot and oversized frames are rejected', async t => {
  const { base, room, hostToken } = await setup(t);
  const host = connect(base, room, 'host', { headers: { Authorization: `Bearer ${hostToken}` } });
  await message(host);
  const peer = message(host);
  const phone = connect(base, room, 'phone', { origin: 'http://localhost:3099' });
  await peer;
  await once(connect(base, room, 'phone', { origin: 'http://localhost:3099' }), 'error');
  await once(connect(base, room, 'host', { headers: { Authorization: `Bearer ${hostToken}` } }), 'error');
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
  await once(connect(base, null, 'phone', { origin: 'http://localhost:3099', ticket: first }), 'error');
  const notice = message(restored);
  const phone = connect(base, null, 'phone', { origin: 'http://localhost:3099', ticket: second });
  await once(phone, 'open');
  assert.equal((await notice).type, 'peer');
});

test('ticket connects reject a short token and a missing host', async t => {
  const { base, room, hostToken } = await setup(t);
  await once(connect(base, null, 'phone', { origin: 'http://localhost:3099', ticket: ticket() }), 'error');
  await once(
    connect(base, room, 'host', { headers: { Authorization: `Bearer ${hostToken}` }, ticket: 'short' }),
    'error',
  );
});

test('room allocation rejects browser requests and excessive creation', async t => {
  const { base } = await setup(t);
  assert.equal((await fetch(`${base}/rooms`, { method: 'POST', headers: { Origin: 'http://localhost:3099' } })).status, 403);
  for (let i = 0; i < 19; i++) assert.equal((await fetch(`${base}/rooms`, { method: 'POST' })).status, 201);
  assert.equal((await fetch(`${base}/rooms`, { method: 'POST' })).status, 429);
});
