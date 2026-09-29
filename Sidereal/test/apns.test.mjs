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
  const apns = createAPNs({ key: pem, keyId: 'K', teamId: 'T', topic: 'com.example.app', hosts: { production: host, development: host } });
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
  assert.equal(seen[0].headers['apns-collapse-id'], 'tab-1');
  assert.match(seen[0].headers.authorization, /^bearer [A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$/);
  assert.deepEqual(seen[0].body, { aps: { alert: { title: 'Sigil' }, 'mutable-content': 1 }, sigil: { data: 'sealed' } });

  const activity = await apns.send({
    environment: 'production', token: 'cd'.repeat(40), pushType: 'liveactivity', priority: 5,
    payload: { aps: { timestamp: 1, event: 'update', 'content-state': { status: 'idle' } } },
  });
  assert.equal(activity.status, 200);
  assert.equal(seen[1].headers['apns-topic'], 'com.example.app.push-type.liveactivity');
  assert.equal(seen[1].headers['apns-push-type'], 'liveactivity');
  assert.equal(seen[1].headers['apns-priority'], '5');

  const gone = await apns.send({ environment: 'production', token: 'bad', pushType: 'alert', payload: { aps: {} } });
  assert.deepEqual(gone, { status: 410, reason: 'Unregistered' });
});
