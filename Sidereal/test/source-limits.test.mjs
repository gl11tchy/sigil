import test from 'node:test';
import assert from 'node:assert/strict';
import { Duplex } from 'node:stream';
import { once } from 'node:events';
import { createRelay, clientAddress, SourceLimits } from '../server.mjs';

const key = value => clientAddress({ socket: { remoteAddress: value } });
function fixture(t, options = {}) {
  const relay = createRelay({ publicOrigin: 'http://localhost:3099', ...options });
  t.after(() => relay.close());
  return relay;
}
async function allocate(relay, address, headers = {}) {
  const response = {
    status: 200, headers: {}, body: '',
    setHeader(name, value) { this.headers[name] = value; },
    writeHead(status) { this.status = status; return this; },
    end(body = '') { this.body = String(body); },
  };
  await relay.server.listeners('request')[0]({
    method: 'POST', url: '/rooms', headers, socket: { remoteAddress: address },
  }, response);
  return response;
}

test('IPv4 aliases and IPv6 privacy addresses share the intended source budget', () => {
  assert.equal(key('192.0.2.1'), key('::ffff:192.0.2.1'));
  assert.equal(key('192.0.2.1'), key('0:0:0:0:0:ffff:c000:201'));
  assert.equal(key('2001:db8:1:2::1'), key('2001:0DB8:0001:0002:abcd:ef01:1234:5678'));
  assert.notEqual(key('2001:db8:1:2::1'), key('2001:db8:1:3::1'));
  assert.notEqual(key('192.0.2.1'), key('192.0.2.2'));
  for (const value of [undefined, '', 'unknown', '192.0.2.999', '2001:db8::bad::1', 'a'.repeat(129)]) {
    assert.equal(key(value), null);
  }
});

test('25 allocations from A leave B a separate budget in the real HTTP handler', async t => {
  const relay = fixture(t);
  const statuses = [];
  for (let i = 0; i < 25; i++) statuses.push((await allocate(relay, '192.0.2.1')).status);
  assert.deepEqual(statuses.slice(0, 5), Array(5).fill(201));
  assert.deepEqual(statuses.slice(5), Array(20).fill(429));
  assert.equal((await allocate(relay, '198.51.100.2')).status, 201);
});

test('spoofed forwarding headers and mapped-address spelling cannot buy another budget', async t => {
  const relay = fixture(t);
  for (let i = 0; i < 5; i++) {
    assert.equal((await allocate(relay, '192.0.2.1', {
      'x-forwarded-for': `198.51.100.${i}`, forwarded: `for=203.0.113.${i}`, 'x-real-ip': `203.0.113.${i}`,
    })).status, 201);
  }
  assert.equal((await allocate(relay, '::ffff:c000:201', { 'x-forwarded-for': '203.0.113.99' })).status, 429);
  assert.equal((await allocate(relay, '192.0.2.2', { 'x-forwarded-for': '192.0.2.1' })).status, 201);
});

test('IPv6 sources aggregate a /64 but leave adjacent networks independent', async t => {
  const relay = fixture(t);
  for (let i = 1; i <= 5; i++) assert.equal((await allocate(relay, `2001:db8:1:2::${i}`)).status, 201);
  assert.equal((await allocate(relay, '2001:db8:1:2:ffff::1')).status, 429);
  assert.equal((await allocate(relay, '2001:db8:1:3::1')).status, 201);
});

test('invalid or browser allocation requests consume no native budget', async t => {
  const relay = fixture(t);
  for (const headers of [{ origin: 'https://evil.example' }, { 'content-length': '1' }, { 'transfer-encoding': 'chunked' }]) {
    assert.equal((await allocate(relay, '192.0.2.1', headers)).status, 403);
  }
  assert.equal((await allocate(relay, 'not-an-address')).status, 403);
  for (let i = 0; i < 5; i++) assert.equal((await allocate(relay, '192.0.2.1')).status, 201);
});

test('abandoned rooms expire at 30 seconds and release global capacity in the sweep', async t => {
  t.mock.timers.enable({ apis: ['setInterval'] });
  let time = 0;
  const relay = fixture(t, { maxRooms: 1, now: () => time });
  assert.equal((await allocate(relay, '192.0.2.1')).status, 201);
  time = 29999;
  t.mock.timers.tick(15000);
  assert.equal((await allocate(relay, '192.0.2.2')).status, 429);
  time = 30000;
  t.mock.timers.tick(15000);
  assert.equal((await allocate(relay, '192.0.2.2')).status, 201);
});

test('abandoned room expiry retains the source token debt', async t => {
  let time = 0;
  const relay = fixture(t, { now: () => time });
  for (let i = 0; i < 5; i++) assert.equal((await allocate(relay, '192.0.2.1')).status, 201);
  time = 12000;
  assert.equal((await allocate(relay, '192.0.2.1')).status, 201);
  time = 30000; // Allocation also sweeps expired rooms rather than waiting for the next tick.
  assert.equal((await allocate(relay, '192.0.2.1')).status, 201);
  assert.equal((await allocate(relay, '192.0.2.1')).status, 429);
});

test('refilled tokens do not bypass the twenty-room source ceiling during reconnect grace', () => {
  let time = 0;
  const limits = new SourceLimits({ now: () => time });
  for (let batch = 0; batch < 4; batch++) {
    time = batch * 60000;
    for (let i = 0; i < 5; i++) assert.equal(limits.allocate('A'), true);
  }
  time = 240000;
  assert.equal(limits.allocate('A'), false);
  assert.equal(limits.allocate('B'), true);
  limits.releaseRoom('A');
  assert.equal(limits.allocate('A'), true);
});

test('global capacity remains 100 even with independent source budgets', async t => {
  const relay = fixture(t);
  for (let i = 1; i <= 100; i++) assert.equal((await allocate(relay, `192.0.2.${i}`)).status, 201);
  assert.equal((await allocate(relay, '198.51.100.1')).status, 429);
  assert.throws(() => createRelay({ publicOrigin: 'http://localhost:3099', maxRooms: 101 }), RangeError);
});

test('source-state cardinality is bounded; idle expiry cannot evict occupied budgets', () => {
  let time = 0;
  const limits = new SourceLimits({ now: () => time, maxSources: 2 });
  for (let i = 0; i < 5; i++) assert.equal(limits.allocate('A'), true);
  assert.equal(limits.allocate('B'), true);
  limits.releaseRoom('B');
  assert.equal(limits.allocate('C'), false);
  time = 59999; limits.sweep();
  assert.equal(limits.allocate('C'), false);
  time = 60000; limits.sweep();
  assert.equal(limits.allocate('C'), true);
  assert.equal(limits.allocate('D'), false); // A's occupied entry was not evicted.
});

test('released room slots retain token debt, and backwards time creates no refill', () => {
  let time = 0;
  const limits = new SourceLimits({ now: () => time });
  for (let i = 0; i < 5; i++) { assert.equal(limits.allocate('A'), true); limits.releaseRoom('A'); }
  assert.equal(limits.allocate('A'), false);
  time = -1000; assert.equal(limits.allocate('A'), false);
  time = 12000; assert.equal(limits.allocate('A'), true); limits.releaseRoom('A');
  assert.equal(limits.allocate('A'), false);
});

test('the default source table refuses entry1025 and reuses fully idle capacity', () => {
  let time = 0;
  const limits = new SourceLimits({ now: () => time });
  const releases = [];
  for (let i = 0; i < 1024; i++) {
    const release = limits.reserveConnection(`source-${i}`);
    assert.equal(typeof release, 'function'); releases.push(release);
  }
  assert.equal(limits.reserveConnection('overflow'), null);
  releases.forEach(release => release());
  time = 60000; limits.sweep();
  const reused = limits.reserveConnection('overflow'); assert.equal(typeof reused, 'function'); reused();
});

test('shared-NAT connection reservations have a separate cap and release exactly once', () => {
  const limits = new SourceLimits();
  const held = Array.from({ length: 20 }, () => limits.reserveConnection('A'));
  assert.ok(held.every(release => typeof release === 'function'));
  assert.equal(limits.reserveConnection('A'), null);
  const other = limits.reserveConnection('B'); assert.equal(typeof other, 'function');
  held[0](); held[0]();
  const replacement = limits.reserveConnection('A'); assert.equal(typeof replacement, 'function');
  assert.equal(limits.reserveConnection('A'), null);
  for (let i = 0; i < 5; i++) assert.equal(limits.allocate('A'), true);
  replacement(); other(); held.forEach(release => release());
});

// A generated Duplex exercises the real ws upgrade handler without opening a
// listener or contacting a relay. It captures only fixture handshake output.
class FixtureSocket extends Duplex {
  constructor(address) {
    super(); this.remoteAddress = address; this.output = [];
    this.closedEvent = new Promise(resolve => this.once('close', resolve));
  }
  _read() {}
  _write(bytes, encoding, done) { this.output.push(Buffer.from(bytes)); done(); }
  _final(done) { done(); }
  setTimeout() { return this; }
  setNoDelay() { return this; }
  get response() { return Buffer.concat(this.output).toString('latin1'); }
}
function upgrade(relay, address, headers = {}) {
  const socket = new FixtureSocket(address);
  const request = { method: 'GET', url: '/connect?role=phone', socket, headers: {
    origin: 'http://localhost:3099', upgrade: 'websocket', connection: 'Upgrade',
    'sec-websocket-version': '13', 'sec-websocket-key': 'dGhlIHNhbXBsZSBub25jZQ==', ...headers,
  } };
  relay.server.emit('upgrade', request, socket, Buffer.alloc(0));
  return socket;
}

test('real upgrade admission rejects socket21 before handshake and admits another source', async t => {
  const relay = fixture(t);
  const sockets = Array.from({ length: 20 }, () => upgrade(relay, '192.0.2.1'));
  for (const socket of sockets) assert.match(socket.response, /^HTTP\/1.1 101 /);
  const refused = upgrade(relay, '192.0.2.1', { 'x-forwarded-for': '203.0.113.1' });
  assert.match(refused.response, /^HTTP\/1.1 429 /);
  await refused.closedEvent;
  const other = upgrade(relay, '192.0.2.2'); assert.match(other.response, /^HTTP\/1.1 101 /);
  const closed = once(sockets[0], 'close'); sockets[0].destroy(); await closed;
  const replacement = upgrade(relay, '::ffff:192.0.2.1'); assert.match(replacement.response, /^HTTP\/1.1 101 /);
  assert.match(upgrade(relay, '192.0.2.1').response, /^HTTP\/1.1 429 /);
});

test('a rejected malformed handshake releases its reserved source slot', async t => {
  const relay = fixture(t);
  const bad = upgrade(relay, '192.0.2.1', { 'sec-websocket-key': 'bad' });
  assert.match(bad.response, /^HTTP\/1.1 400 /);
  await bad.closedEvent;
  for (let i = 0; i < 20; i++) assert.match(upgrade(relay, '192.0.2.1').response, /^HTTP\/1.1 101 /);
  assert.match(upgrade(relay, '192.0.2.1').response, /^HTTP\/1.1 429 /);
});
