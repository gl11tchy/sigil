import test from 'node:test';
import assert from 'node:assert/strict';
import http2 from 'node:http2';
import { once } from 'node:events';
import { generateKeyPairSync, verify } from 'node:crypto';
import { createAPNs } from '../apns.mjs';

function keyPair() {
  const { privateKey, publicKey } = generateKeyPairSync('ec', { namedCurve: 'prime256v1' });
  return { pem: privateKey.export({ type: 'pkcs8', format: 'pem' }), publicKey };
}

test('push is off without all four settings', () => {
  const { pem } = keyPair();
  assert.equal(createAPNs({}), null);
  assert.equal(createAPNs({ key: pem, keyId: 'K', teamId: 'T' }), null);
  assert.notEqual(createAPNs({ key: pem, keyId: 'K', teamId: 'T', topic: 'com.example.app' }), null);
});

test('the bearer token is an ES256 JWT with the key id and team, reused for fifty minutes', () => {
  const { pem, publicKey } = keyPair();
  let clock = 1_700_000_000_000;
  const apns = createAPNs({ key: pem, keyId: 'KEYID12345', teamId: 'TEAM123456', topic: 'com.example.app', now: () => clock });
  const jwt = apns.bearer();
  const [header, claims, signature] = jwt.split('.');
  assert.deepEqual(JSON.parse(Buffer.from(header, 'base64url')), { alg: 'ES256', kid: 'KEYID12345' });
  assert.deepEqual(JSON.parse(Buffer.from(claims, 'base64url')), { iss: 'TEAM123456', iat: 1_700_000_000 });
  assert.ok(verify('sha256', Buffer.from(`${header}.${claims}`), { key: publicKey, dsaEncoding: 'ieee-p1363' }, Buffer.from(signature, 'base64url')));
  clock += 49 * 60 * 1000;
  assert.equal(apns.bearer(), jwt);
  clock += 2 * 60 * 1000;
  assert.notEqual(apns.bearer(), jwt);
  // A base64 copy of the key, as an environment variable carries it, works too.
  assert.notEqual(createAPNs({ key: Buffer.from(pem).toString('base64'), keyId: 'K', teamId: 'T', topic: 't' }), null);
});

test('a push is one HTTP/2 POST with Apple\'s headers, and the answer is a status', async t => {
  const { pem } = keyPair();
  const seen = [];
  const server = http2.createServer((req, res) => {
    let body = '';
    req.setEncoding('utf8');
    req.on('data', chunk => { body += chunk; });
    req.on('end', () => {
      seen.push({ headers: req.headers, body: JSON.parse(body) });
      if (req.headers[':path'].endsWith('/bad')) {
        res.writeHead(410, { 'content-type': 'application/json' }).end(JSON.stringify({ reason: 'Unregistered' }));
      } else res.writeHead(200).end();
    });
  });
  server.listen(0, '127.0.0.1');
  await once(server, 'listening');
  const host = `http://127.0.0.1:${server.address().port}`;
  const apns = createAPNs({ key: pem, keyId: 'K', teamId: 'T', topic: 'com.example.app', hosts: { production: host, development: host },
    now: () => 1_800_000_000_000 });
  t.after(() => { apns.close(); server.close(); });

  const alert = await apns.send({
    environment: 'development', token: 'ab'.repeat(32), pushType: 'alert', collapseId: 'tab-1',
    payload: { aps: { alert: { title: 'Sigil' }, 'mutable-content': 1 }, sigil: { data: 'sealed' } },
  });
  assert.deepEqual(alert, { status: 200, reason: undefined });
  assert.equal(seen[0].headers[':path'], `/3/device/${'ab'.repeat(32)}`);
  assert.equal(seen[0].headers['apns-topic'], 'com.example.app');
  assert.equal(seen[0].headers['apns-push-type'], 'alert');
  assert.equal(seen[0].headers['apns-priority'], '10');
  assert.equal(seen[0].headers['apns-expiration'], '0');
  assert.equal(seen[0].headers['apns-collapse-id'], 'tab-1');
  assert.match(seen[0].headers.authorization, /^bearer [A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$/);
  assert.deepEqual(seen[0].body, { aps: { alert: { title: 'Sigil' }, 'mutable-content': 1 }, sigil: { data: 'sealed' } });

  const activity = await apns.send({
    environment: 'production', token: 'cd'.repeat(40), pushType: 'liveactivity', priority: 5, expiration: 1_800_000_900,
    payload: { aps: { timestamp: 1, event: 'update', 'content-state': { status: 'idle' } } },
  });
  assert.equal(activity.status, 200);
  assert.equal(seen[1].headers['apns-topic'], 'com.example.app.push-type.liveactivity');
  assert.equal(seen[1].headers['apns-push-type'], 'liveactivity');
  assert.equal(seen[1].headers['apns-priority'], '5');
  assert.equal(seen[1].headers['apns-expiration'], '1800000900');

  const gone = await apns.send({ environment: 'production', token: 'bad', pushType: 'alert', payload: { aps: {} } });
  assert.deepEqual(gone, { status: 410, reason: 'Unregistered' });
});

test('REA-1212 recovers an unanswered connection once and the next event reuses the replacement', { timeout: 30000 }, async t => {
  const { pem } = keyPair();
  const connections = [], requests = [];
  const server = http2.createServer();
  server.on('session', session => { connections.push(session); session.on('error', () => {}); });
  server.on('stream', (stream, headers) => {
    stream.on('error', () => {});
    let body = '';
    stream.setEncoding('utf8');
    stream.on('data', chunk => { body += chunk; });
    stream.on('end', () => {
      requests.push({ session: stream.session, headers, body });
      // The first connection accepts every request but never answers it.
      if (stream.session !== connections[0]) { stream.respond({ ':status': 200 }); stream.end(); }
    });
  });
  server.listen(0, '127.0.0.1');
  await once(server, 'listening');
  const host = `http://127.0.0.1:${server.address().port}`;
  const apns = createAPNs({ key: pem, keyId: 'K', teamId: 'T', topic: 'test', hosts: { production: host }, requestTimeoutMs: 100 });
  t.after(() => { apns.close(); connections.forEach(session => session.destroy()); server.close(); });
  const event = { environment: 'production', token: 'ab'.repeat(32), pushType: 'alert', collapseId: 'tab-one',
    expiration: Math.floor(Date.now() / 1000) + 300, payload: { aps: {}, sigil: { data: 'generated-event-one' } } };
  const first = await apns.send(event);
  const second = await apns.send({ ...event, payload: { aps: {}, sigil: { data: 'generated-event-two' } } });
  assert.deepEqual({ first: first.status, second: second.status, connections: connections.length },
    { first: 200, second: 200, connections: 2 });
  assert.equal(requests.length, 3);
  assert.equal(requests[0].body, requests[1].body);
  assert.equal(requests[0].headers['apns-expiration'], requests[1].headers['apns-expiration']);
  assert.equal(requests[0].headers['apns-collapse-id'], requests[1].headers['apns-collapse-id']);
  assert.equal(requests[1].session, requests[2].session);
});

// All credentials and payloads are generated. Every host maps to loopback.
async function recoveryFixture(t, onRequest, options = {}) {
  const connections = [], seen = [];
  const server = http2.createServer();
  server.on('session', session => { connections.push(session); session.on('error', () => {}); });
  server.on('stream', (stream, headers) => {
    stream.on('error', () => {});
    let body = '';
    stream.setEncoding('utf8');
    stream.on('data', chunk => { body += chunk; });
    stream.on('end', () => {
      const request = { stream, session: stream.session, headers, body };
      seen.push(request);
      onRequest(request, { connections, seen });
    });
  });
  server.listen(0, '127.0.0.1');
  await once(server, 'listening');
  const host = `http://127.0.0.1:${server.address().port}`;
  const { pem } = keyPair();
  const apns = createAPNs({ key: pem, keyId: 'K', teamId: 'T', topic: 'test', hosts: { production: host, development: host },
    requestTimeoutMs: 120, totalTimeoutMs: 240, ...options });
  t.after(() => { apns.close(); connections.forEach(session => session.destroy()); server.close(); });
  return { apns, connections, seen };
}

const syntheticEvent = (data = 'event-one', overrides = {}) => ({
  environment: 'production', token: 'ab'.repeat(32), pushType: 'alert', collapseId: 'room-tab',
  expiration: Math.floor(Date.now() / 1000) + 300, payload: { aps: {}, sigil: { data } }, ...overrides,
});
const answer = (request, status = 200) => { request.stream.respond({ ':status': status }); request.stream.end(); };
const waitFor = async predicate => {
  for (let i = 0; i < 200 && !predicate(); i++) await new Promise(resolve => setTimeout(resolve, 5));
  assert.ok(predicate(), 'owned fixture condition did not occur');
};

test('REA-1212 simultaneous failures share a replacement and stale handlers cannot evict it', async t => {
  const fixture = await recoveryFixture(t, (request, { connections }) => {
    if (request.session !== connections[0]) answer(request);
  });
  const results = await Promise.all([fixture.apns.send(syntheticEvent('one')), fixture.apns.send(syntheticEvent('two'))]);
  assert.deepEqual(results.map(result => result.status), [200, 200]);
  assert.equal(fixture.connections.length, 2);
  assert.equal(fixture.seen.length, 4);
  for (const data of ['one', 'two']) {
    const requests = fixture.seen.filter(request => JSON.parse(request.body).sigil.data === data);
    assert.equal(requests.length, 2);
    assert.equal(requests[0].body, requests[1].body);
    assert.equal(requests[0].headers.authorization, requests[1].headers.authorization);
  }
  // The old connection closes after replacement; a later event uses the new one.
  await waitFor(() => fixture.connections[0].destroyed);
  assert.equal((await fixture.apns.send(syntheticEvent('three'))).status, 200);
  assert.equal(fixture.connections.length, 2);
});

test('REA-1212 never retries after any response, including error or informational status', async t => {
  for (const status of [200, 400, 410, 500, 103]) {
    const fixture = await recoveryFixture(t, request => {
      if (status === 103) request.stream.additionalHeaders({ ':status': status });
      else request.stream.respond({ ':status': status });
      setTimeout(() => request.stream.close(http2.constants.NGHTTP2_INTERNAL_ERROR), 10);
    });
    const result = await fixture.apns.send(syntheticEvent());
    assert.equal(result.status, status);
    assert.equal(fixture.seen.length, 1);
    assert.equal(fixture.connections.length, 1);
    fixture.apns.close();
  }
});

test('REA-1212 GOAWAY retires cached transport while accepted streams finish', async t => {
  const fixture = await recoveryFixture(t, (request, { connections }) => {
    if (request.session === connections[0]) request.session.goaway(http2.constants.NGHTTP2_NO_ERROR, request.stream.id);
    answer(request);
  });
  assert.equal((await fixture.apns.send(syntheticEvent('one'))).status, 200);
  await new Promise(resolve => setTimeout(resolve, 30));
  assert.equal((await fixture.apns.send(syntheticEvent('two'))).status, 200);
  assert.equal(fixture.connections.length, 2);
  assert.equal(fixture.seen.length, 2);
});

test('REA-1212 GOAWAY refusal before a response gets only one fresh attempt', async t => {
  const fixture = await recoveryFixture(t, (request, { connections }) => {
    if (request.session === connections[0]) {
      request.session.goaway(http2.constants.NGHTTP2_NO_ERROR, 0);
      request.stream.close(http2.constants.NGHTTP2_REFUSED_STREAM);
    } else answer(request);
  });
  assert.equal((await fixture.apns.send(syntheticEvent())).status, 200);
  assert.equal(fixture.connections.length, 2);
  assert.equal(fixture.seen.length, 2);
  assert.equal(fixture.seen[0].body, fixture.seen[1].body);
});

test('REA-1212 idle connections close and active attempts are not mistaken for idle', async t => {
  const fixture = await recoveryFixture(t, request => setTimeout(() => answer(request), 50), { idleTimeoutMs: 20 });
  assert.equal((await fixture.apns.send(syntheticEvent('one'))).status, 200);
  assert.equal(fixture.connections.length, 1);
  await waitFor(() => fixture.connections[0].destroyed);
  assert.equal((await fixture.apns.send(syntheticEvent('two'))).status, 200);
  assert.equal(fixture.connections.length, 2);
});

test('REA-1212 expiry prevents admission and a fresh retry without renewing the deadline', async t => {
  let clock = 1_800_000_000_000;
  const fixture = await recoveryFixture(t, () => { clock += 1000; }, { now: () => clock });
  await assert.rejects(fixture.apns.send(syntheticEvent('stale', { expiration: 1_800_000_000 })), /unreachable/);
  assert.equal(fixture.connections.length, 0);
  await assert.rejects(fixture.apns.send(syntheticEvent('ending', { expiration: 1_800_000_001 })), /unreachable/);
  assert.equal(fixture.connections.length, 1);
  assert.equal(fixture.seen.length, 1);
  assert.equal(fixture.seen[0].headers['apns-expiration'], '1800000001');
});

test('REA-1212 two failed attempts and response-body waiting stay within a total deadline', async t => {
  const fixture = await recoveryFixture(t, () => {}, { requestTimeoutMs: 80, totalTimeoutMs: 120 });
  const began = performance.now();
  await assert.rejects(fixture.apns.send(syntheticEvent()), /unreachable/);
  assert.ok(performance.now() - began < 1000);
  assert.equal(fixture.seen.length, 2);
  assert.equal(fixture.connections.length, 2);
  const body = await recoveryFixture(t, request => {
    request.stream.respond({ ':status': 200 });
    const timer = setInterval(() => { if (!request.stream.destroyed) request.stream.write(' '); }, 5);
    request.stream.on('close', () => clearInterval(timer));
  }, { requestTimeoutMs: 80, totalTimeoutMs: 120 });
  const bodyBegan = performance.now();
  assert.equal((await body.apns.send(syntheticEvent())).status, 200);
  assert.ok(performance.now() - bodyBegan < 1000);
  assert.equal(body.seen.length, 1);
});

test('REA-1212 shutdown settles pending sends without replacement or resurrection', async t => {
  const fixture = await recoveryFixture(t, () => {});
  const pending = fixture.apns.send(syntheticEvent());
  const rejection = assert.rejects(pending, /unreachable/);
  await waitFor(() => fixture.seen.length === 1);
  fixture.apns.close();
  await rejection;
  await assert.rejects(fixture.apns.send(syntheticEvent('later')), /closed/);
  assert.equal(fixture.connections.length, 1);
  assert.equal(fixture.seen.length, 1);
});

test('REA-1212 uncertain duplicate attempts preserve snapshot identity and activity order', async t => {
  const fixture = await recoveryFixture(t, (request, { connections }) => {
    if (request.session !== connections[0]) answer(request);
  });
  const update = syntheticEvent('update', { pushType: 'liveactivity', payload: { aps: { timestamp: 1_800_000_000, event: 'update' } } });
  const original = JSON.stringify(update.payload);
  const pending = fixture.apns.send(update);
  await waitFor(() => fixture.seen.length === 1);
  update.payload.aps.timestamp++;
  update.payload.aps.event = 'end'; // caller mutation cannot alter an in-flight intent
  update.expiration++;
  assert.equal((await pending).status, 200);
  assert.equal((await fixture.apns.send(syntheticEvent('end', { pushType: 'liveactivity',
    payload: { aps: { timestamp: 1_800_000_001, event: 'end' } } }))).status, 200);
  assert.equal(fixture.seen.length, 3); // first acceptance had no reply; duplication is possible
  assert.equal(fixture.seen[0].body, original);
  assert.equal(fixture.seen[1].body, original);
  assert.equal(fixture.seen[0].headers['apns-expiration'], fixture.seen[1].headers['apns-expiration']);
  assert.equal(fixture.seen[0].headers['apns-collapse-id'], fixture.seen[1].headers['apns-collapse-id']);
  assert.deepEqual(fixture.seen.map(request => JSON.parse(request.body).aps.timestamp), [1_800_000_000, 1_800_000_000, 1_800_000_001]);
});
