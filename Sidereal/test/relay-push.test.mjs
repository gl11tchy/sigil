// Push delivery runs beside the host's frames, not in front of them.
import test from 'node:test';
import assert from 'node:assert/strict';
import { once } from 'node:events';
import WebSocket from 'ws';
import { createRelay } from '../server.mjs';
import { importKey, seal } from '../public/crypto.mjs';

const origin = 'http://localhost:3099';
const alertToken = n => String(n).repeat(64);
const activityToken = 'cd'.repeat(40);

async function setup(t, options = {}) {
  const relay = createRelay({ publicOrigin: origin, ...options });
  relay.server.listen(0, '127.0.0.1');
  await once(relay.server, 'listening');
  const base = `http://127.0.0.1:${relay.server.address().port}`;
  t.after(() => relay.close());
  const newRoom = async () => (await fetch(`${base}/rooms`, { method: 'POST' })).json();
  return { base, relay, newRoom, ...await newRoom() };
}
// Every frame other than the route handshake, in arrival order.
function connect(base, room, role, options = {}) {
  const ws = new WebSocket(`${base.replace('http', 'ws')}/connect?role=${role}`, options);
  ws.frames = [];
  ws.on('error', () => {});
  ws.on('message', async bytes => {
    const frame = JSON.parse(bytes);
    if (!frame.route) { ws.frames.push(frame); return; }
    const route = await seal({ room }, await importKey(frame.route), `relay-${role}`);
    if (ws.readyState === WebSocket.OPEN) ws.send(JSON.stringify({ route }));
  });
  return ws;
}
const host = (base, room, hostToken) => connect(base, room, 'host', { headers: { Authorization: `Bearer ${hostToken}` } });
const phone = (base, room) => connect(base, room, 'phone', { origin });
async function until(check, what = 'condition') {
  for (let i = 0; i < 400 && !check(); i++) await new Promise(resolve => setTimeout(resolve, 5));
  assert.ok(check(), `timed out waiting for ${what}`);
}
const settle = () => new Promise(resolve => setTimeout(resolve, 50));
const pushes = ws => ws.frames.filter(frame => frame.type === 'push');
const alert = data => JSON.stringify({ push: { data, thread: 'tab-1' } });
const activity = (event, status) => JSON.stringify({ push: { activity: activityToken, event, state: { status } } });

// An APNs stand-in that holds every push until the test answers it.
function heldAPNs() {
  const sent = [], held = [];
  let active = 0, most = 0;
  return {
    sent, held, closed: false,
    get active() { return active; },
    get most() { return most; },
    send(request) {
      sent.push(request);
      most = Math.max(most, ++active);
      return new Promise((resolve, reject) => held.push({ request, resolve, reject }));
    },
    // Answers the oldest held push whose token matches.
    answer(status = 200, token) {
      const index = held.findIndex(entry => !token || entry.request.token === token);
      assert.ok(index >= 0, 'no held push to answer');
      const [entry] = held.splice(index, 1);
      active--;
      if (status === 'down') entry.reject(new Error('down')); else entry.resolve({ status });
    },
    close() { this.closed = true; },
  };
}

test('a phone that reconnects while pushes wait on Apple gets the host reply at once', async t => {
  const apns = heldAPNs();
  const { base, room, hostToken } = await setup(t, { apns });
  const mac = host(base, room, hostToken);
  await until(() => mac.frames.some(frame => frame.type === 'ready'), 'ready');
  let away = phone(base, room);
  await until(() => mac.frames.some(frame => frame.type === 'peer'), 'peer');
  mac.send(JSON.stringify({ pushToken: alertToken(1), pushEnvironment: 'development' }));
  away.terminate();
  await until(() => mac.frames.some(frame => frame.type === 'left'), 'left');
  for (const data of ['AAAA', 'BBBB', 'CCCC']) mac.send(alert(data));
  await until(() => apns.sent.length === 1, 'first push with Apple');

  const peers = mac.frames.filter(frame => frame.type === 'peer').length;
  const back = phone(base, room);
  await until(() => mac.frames.filter(frame => frame.type === 'peer').length > peers, 'second peer');
  const { peer } = mac.frames.findLast(frame => frame.type === 'peer');
  mac.send(JSON.stringify({ peer, hello: 'fresh-challenge' }));
  await until(() => back.frames.length === 1, 'hello');
  assert.deepEqual(back.frames[0], { hello: 'fresh-challenge' });
  back.send(JSON.stringify({ data: 'command' }));
  await until(() => mac.frames.some(frame => frame.data === 'command'), 'command');
  mac.send(JSON.stringify({ peer, data: 'reply' }));
  await until(() => back.frames.length === 2, 'reply');
  assert.deepEqual(back.frames[1], { data: 'reply' });
  // All of that happened while Apple still held the first push and the rest waited their turn.
  assert.equal(apns.active, 1);
  assert.equal(apns.sent.length, 1);
  assert.deepEqual(pushes(mac), []);

  apns.answer(200);
  await until(() => apns.sent.length === 2, 'second push');
  apns.answer(400);
  await until(() => apns.sent.length === 3, 'third push');
  apns.answer('down');
  await until(() => pushes(mac).length === 3, 'three answers');
  assert.deepEqual(apns.sent.map(request => request.payload.sigil.data), ['AAAA', 'BBBB', 'CCCC']);
  assert.deepEqual(pushes(mac), [
    { type: 'push', ok: true, status: 200 },
    { type: 'push', ok: false, status: 400 },
    { type: 'push', ok: false, reason: 'unreachable' },
  ]);
  assert.equal(apns.most, 1);
  mac.close(); back.close();
});

test('pushes go to Apple one at a time in the order sent, and a Live Activity ends after its update', async t => {
  const apns = heldAPNs();
  const { base, room, hostToken } = await setup(t, { apns });
  const mac = host(base, room, hostToken);
  await until(() => mac.frames.some(frame => frame.type === 'ready'), 'ready');
  mac.send(JSON.stringify({ pushToken: alertToken(1), pushEnvironment: 'development' }));
  mac.send(alert('AAAA'));
  mac.send(activity('update', 'working'));
  mac.send(activity('end', 'exited'));
  mac.send(JSON.stringify({ pushToken: null }));
  mac.send(alert('BBBB'));
  for (let step = 1; step <= 3; step++) {
    await until(() => apns.sent.length === step, `push ${step}`);
    await settle();
    // The next push is not handed over until Apple answers this one.
    assert.equal(apns.sent.length, step);
    assert.equal(pushes(mac).length, step - 1);
    apns.answer(200);
  }
  await until(() => pushes(mac).length === 4, 'four answers');
  assert.equal(apns.most, 1);
  assert.deepEqual(apns.sent.map(request => request.pushType), ['alert', 'liveactivity', 'liveactivity']);
  const [update, end] = apns.sent.slice(1).map(request => request.payload.aps);
  assert.equal(update.event, 'update');
  assert.equal(end.event, 'end');
  assert.ok(end.timestamp >= update.timestamp);
  assert.equal(end['dismissal-date'], end.timestamp + 300);
  // The token was cleared after the end; the last alert is refused in its place, not ahead of the others.
  assert.deepEqual(pushes(mac), [
    { type: 'push', ok: true, status: 200 },
    { type: 'push', ok: true, status: 200 },
    { type: 'push', ok: true, status: 200 },
    { type: 'push', ok: false, reason: 'token' },
  ]);
  mac.close();
});

test('a push keeps the token registered before it, and a 410 forgets only the token Apple named', async t => {
  const apns = heldAPNs();
  const { base, room, hostToken } = await setup(t, { apns });
  const mac = host(base, room, hostToken);
  await until(() => mac.frames.some(frame => frame.type === 'ready'), 'ready');

  // Replacement: each queued push goes to the token registered just before it.
  mac.send(JSON.stringify({ pushToken: alertToken(1), pushEnvironment: 'development' }));
  mac.send(alert('AAAA'));
  mac.send(JSON.stringify({ pushToken: alertToken(2), pushEnvironment: 'production' }));
  mac.send(alert('BBBB'));
  mac.send(activity('update', 'working'));
  for (let step = 1; step <= 3; step++) { await until(() => apns.sent.length === step, `push ${step}`); apns.answer(200); }
  await until(() => pushes(mac).length === 3, 'three answers');
  assert.deepEqual(apns.sent.map(request => [request.token, request.environment]), [
    [alertToken(1), 'development'], [alertToken(2), 'production'], [activityToken, 'production'],
  ]);

  // A dead token: the pushes queued behind the 410 are refused without going to Apple.
  mac.send(JSON.stringify({ pushToken: alertToken(3), pushEnvironment: 'production' }));
  mac.send(alert('CCCC'));
  mac.send(alert('DDDD'));
  mac.send(activity('update', 'idle'));
  await until(() => apns.sent.length === 4, 'dead push');
  apns.answer(410);
  await until(() => pushes(mac).length === 6, 'answers after 410');
  assert.deepEqual(pushes(mac).slice(3), [
    { type: 'push', ok: false, status: 410 },
    { type: 'push', ok: false, reason: 'token' },
    { type: 'push', ok: false, reason: 'token' },
  ]);
  mac.send(alert('EEEE'));
  await until(() => pushes(mac).length === 7, 'forgotten token');
  assert.deepEqual(pushes(mac)[6], { type: 'push', ok: false, reason: 'token' });
  assert.equal(apns.sent.length, 4);

  // A 410 for a token already replaced leaves the new registration alone.
  mac.send(JSON.stringify({ pushToken: alertToken(4), pushEnvironment: 'production' }));
  mac.send(alert('FFFF'));
  mac.send(JSON.stringify({ pushToken: alertToken(5), pushEnvironment: 'production' }));
  mac.send(alert('GGGG'));
  await until(() => apns.sent.length === 5, 'replaced push');
  apns.answer(410);
  await until(() => apns.sent.length === 6, 'push to the new token');
  apns.answer(200);
  mac.send(alert('HHHH'));
  await until(() => apns.sent.length === 7, 'later push');
  apns.answer(200);
  await until(() => pushes(mac).length === 10, 'answers after replacement');
  assert.deepEqual(apns.sent.slice(4).map(request => request.token), [alertToken(4), alertToken(5), alertToken(5)]);
  assert.deepEqual(pushes(mac).slice(7).map(frame => frame.status), [410, 200, 200]);

  // An ended activity's 410 leaves the phone's alert token alone, as before.
  mac.send(activity('update', 'idle'));
  await until(() => apns.sent.length === 8, 'activity push');
  apns.answer(410);
  mac.send(alert('IIII'));
  await until(() => apns.sent.length === 9, 'alert after activity 410');
  apns.answer(200);
  await until(() => pushes(mac).length === 12, 'final answers');
  assert.deepEqual(pushes(mac).slice(10).map(frame => frame.status), [410, 200]);
  assert.equal(apns.held.length, 0);
  mac.close();
});

test('a full push queue answers busy at once, and the rate limit still counts every push Apple gets', async t => {
  const apns = heldAPNs();
  const { base, room, hostToken } = await setup(t, { apns });
  const mac = host(base, room, hostToken);
  await until(() => mac.frames.some(frame => frame.type === 'ready'), 'ready');
  mac.send(JSON.stringify({ pushToken: alertToken(1), pushEnvironment: 'development' }));
  // The socket allows 30 frames a second; send 61 pushes in three bursts while Apple holds the first.
  const data = i => btoa(String(i).padStart(3, '0'));
  for (let i = 0; i < 61; i++) {
    if (i && i % 25 === 0) await new Promise(resolve => setTimeout(resolve, 1050));
    mac.send(alert(data(i)));
  }
  await until(() => pushes(mac).length === 1, 'busy answer');
  assert.deepEqual(pushes(mac), [{ type: 'push', ok: false, reason: 'busy' }]);
  // One push with Apple, 59 waiting: the queue holds 60 and no more.
  assert.equal(apns.sent.length, 1);
  assert.equal(apns.active, 1);
  for (let i = 1; i <= 60; i++) {
    await until(() => apns.sent.length === i, `push ${i}`);
    apns.answer(200);
  }
  await until(() => pushes(mac).length === 61, 'every answer');
  assert.equal(apns.most, 1);
  assert.deepEqual(apns.sent.map(request => request.payload.sigil.data), Array.from({ length: 60 }, (_, i) => data(i)));
  assert.equal(pushes(mac).filter(frame => frame.ok).length, 60);
  // Sixty went to Apple this minute; the next one is over the limit.
  mac.send(alert(data(61)));
  await until(() => pushes(mac).length === 62, 'rate answer');
  assert.deepEqual(pushes(mac)[61], { type: 'push', ok: false, reason: 'rate' });
  assert.equal(apns.sent.length, 60);
  mac.close();
});

test('rooms keep separate push queues, and a new host connection waits behind the old one', async t => {
  const apns = heldAPNs();
  const { base, room, hostToken, newRoom } = await setup(t, { apns });
  const other = await newRoom();
  const first = host(base, room, hostToken);
  const second = host(base, other.room, other.hostToken);
  await until(() => [first, second].every(ws => ws.frames.some(frame => frame.type === 'ready')), 'ready');
  first.send(JSON.stringify({ pushToken: alertToken(1), pushEnvironment: 'development' }));
  second.send(JSON.stringify({ pushToken: alertToken(2), pushEnvironment: 'development' }));
  first.send(alert('AAAA'));
  await until(() => apns.sent.length === 1, 'first room push');
  second.send(alert('BBBB'));
  await until(() => apns.sent.length === 2, 'second room push');
  apns.answer(200, alertToken(2));
  await until(() => pushes(second).length === 1, 'second room answer');
  assert.deepEqual(pushes(first), []);

  // The first room's Mac reconnects while its push is still with Apple.
  first.close();
  await once(first, 'close');
  const again = host(base, room, hostToken);
  await until(() => again.frames.some(frame => frame.type === 'ready'), 'ready again');
  again.send(JSON.stringify({ pushToken: alertToken(1), pushEnvironment: 'development' }));
  again.send(alert('CCCC'));
  await settle();
  assert.equal(apns.sent.length, 2);
  apns.answer(200, alertToken(1));
  await until(() => apns.sent.length === 3, 'queued push');
  apns.answer(200, alertToken(1));
  await until(() => pushes(again).length === 1, 'answer on the new connection');
  assert.deepEqual(apns.sent.map(request => request.payload.sigil.data), ['AAAA', 'BBBB', 'CCCC']);
  assert.deepEqual(pushes(again), [{ type: 'push', ok: true, status: 200 }]);
  again.close(); second.close();
});

test('closing the relay answers queued pushes as closed and sends nothing more to Apple', async t => {
  const apns = heldAPNs();
  const { base, room, hostToken, relay } = await setup(t, { apns });
  const mac = host(base, room, hostToken);
  await until(() => mac.frames.some(frame => frame.type === 'ready'), 'ready');
  mac.send(JSON.stringify({ pushToken: alertToken(1), pushEnvironment: 'development' }));
  for (const data of ['AAAA', 'BBBB', 'CCCC']) mac.send(alert(data));
  await until(() => apns.sent.length === 1, 'first push');
  await settle();
  const closed = once(mac, 'close');
  relay.close();
  await closed;
  assert.equal(apns.closed, true);
  assert.deepEqual(pushes(mac), [
    { type: 'push', ok: false, reason: 'closed' },
    { type: 'push', ok: false, reason: 'closed' },
  ]);
  // The push already with Apple finishes; nothing queued behind it goes out.
  apns.answer(200);
  await settle();
  assert.equal(apns.sent.length, 1);
  assert.equal(apns.held.length, 0);
});
