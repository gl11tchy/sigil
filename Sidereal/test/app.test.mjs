import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import vm from 'node:vm';
import { readableOutput } from '../public/output.mjs';
import { pairingFromText } from '../public/pairing.mjs';

const source = (await readFile(new URL('../public/app.mjs', import.meta.url), 'utf8'))
  .replace(/^import .* from '\.\/.*\.mjs';\n/gm, '');
const settle = () => new Promise(resolve => setImmediate(resolve));

// Run the real handlers; only browser services and encryption are replaced.
async function browser({ hash = '', saved } = {}) {
  const elements = new Map(), events = new Map(), timers = new Map(), sockets = [];
  let nextTimer = 0, reloads = 0;
  let stored = saved ?? { room: 'a'.repeat(32), key: { device: true } };
  const sealed = [];
  const element = id => {
    if (!elements.has(id)) elements.set(id, {
      id, value: '', textContent: '', hidden: false, disabled: false, dataset: {}, style: {},
      open: false, focus() {}, contains() { return false; },
      getAttribute(name) { return this[name]; }, setAttribute(name, value) { this[name] = value; },
      addEventListener() {},
      showModal() { this.open = true; }, close() { this.open = false; },
      scrollHeight: 0, scrollTop: 0, clientHeight: 0,
      querySelector(selector) { return element(`${id}-${selector}`); },
      replaceChildren(...children) { this.children = children; },
    });
    return elements.get(id);
  };
  const location = {
    origin: 'https://sidereal.example', protocol: 'https:', pathname: '/', hash,
    reload() { reloads++; },
  };
  const document = {
    hidden: false, getElementById: element,
    createDocumentFragment: () => ({ append(node) { this.parts = [...(this.parts || []), node]; } }),
    createTextNode: text => ({ textContent: text }),
    createElement: () => ({
      textContent: '', dataset: {}, hidden: false, children: [],
      append(...nodes) { this.children.push(...nodes); },
      setAttribute(name, value) { this[name] = value; },
      focus() {}, scrollIntoView() {},
    }),
    querySelectorAll: selector => selector === '[data-key]' ? [] :
      ['new', 'tabs', 'message', 'send', 'paste', 'interrupt'].map(element),
    addEventListener: (name, callback) => events.set(name, callback),
  };
  class FakeSocket {
    static OPEN = 1;
    readyState = 1;
    sent = [];
    routes = [];
    constructor(url) { this.url = url; sockets.push(this); }
    send(frame) {
      const value = JSON.parse(frame);
      (value.route ? this.routes : this.sent).push(JSON.parse(value.route || value.data));
    }
    receive(frame) { this.onmessage({ data: JSON.stringify(frame) }); }
    reply(request = this.sent.at(-1)) {
      this.receive({ data: JSON.stringify({
        challenge: request.challenge, sequence: request.sequence, ok: true,
        state: { tabs: [{ id: 'tab-1', title: 'Fixture', status: 'idle' }], selectedTabID: 'tab-1', terminal: 'READY' },
      }) });
    }
    close() { this.readyState = 3; this.onclose?.(); }
  }
  const indexedDB = {
    open() {
      const request = {};
      queueMicrotask(() => {
        request.result = {
          close() {},
          transaction() {
            const transaction = {
              objectStore: () => ({
                get: () => ({ result: structuredClone(stored) }),
                put: value => { stored = structuredClone(value); return {}; },
                delete: () => { stored = undefined; return {}; },
              }),
            };
            queueMicrotask(() => { transaction.oncomplete?.(); });
            return transaction;
          },
        };
        request.onsuccess();
      });
      return request;
    },
  };
  const app = {
    readableOutput, pairingFromText, document, location, history: { replaceState() {} }, indexedDB,
    window: { addEventListener: (name, callback) => events.set(name, callback) },
    navigator: {}, crypto: { subtle: {} }, URL, URLSearchParams, TextEncoder,
    WebSocket: FakeSocket,
    importKey: async hex => ({ hex }), randomKey: () => 'e'.repeat(64),
    seal: async (value, key, direction) => { sealed.push({ value, key, direction }); return JSON.stringify(value); },
    open: async frame => JSON.parse(frame),
    setTimeout(callback, delay) { const id = ++nextTimer; timers.set(id, { callback, delay }); return id; },
    clearTimeout: id => timers.delete(id),
  };
  vm.runInNewContext(source, app);
  await settle();
  async function authorize(ws = sockets.at(-1)) {
    ws.receive({ hello: (sockets.length % 2 ? 'b' : 'c').repeat(64) });
    await settle();
    assert.equal(ws.sent.at(-1).action, 'state');
    ws.reply();
    await settle();
    assert.equal(element('status').textContent, 'Connected');
    return ws;
  }
  async function fireTimer(delay) {
    const entry = [...timers].find(([, timer]) => timer.delay === delay);
    assert.ok(entry, `Expected a ${delay} ms timer`);
    timers.delete(entry[0]);
    entry[1].callback();
    await settle();
  }
  function submit() {
    element('message').value = 'fixture input';
    let prevented = false;
    element('compose').onsubmit({ preventDefault() { prevented = true; } });
    assert.equal(prevented, true);
  }
  return { app, element, events, location, sockets, authorize, fireTimer, submit, sealed, timers, stored: () => structuredClone(stored), reloads: () => reloads };
}

test('attached file names keep their extension and non-Latin letters', async () => {
  const { app } = await browser();
  const bytes = value => new TextEncoder().encode(value).length;
  assert.equal(app.remoteFileName('文档.pdf'), '文档.pdf');
  assert.equal(app.remoteFileName('Отчёт.txt'), 'Отчёт.txt');
  assert.equal(app.remoteFileName('é.json'), 'é.json');
  assert.equal(app.remoteFileName('???.csv'), 'file.csv');
  const long = app.remoteFileName(`${'a'.repeat(90)}.pdf`);
  assert.match(long, /^a+\.pdf$/);
  assert.ok(bytes(long) <= 80);
  const wide = app.remoteFileName(`${'文'.repeat(40)}.xlsx`);
  assert.match(wide, /^文+\.xlsx$/);
  assert.ok(bytes(wide) <= 80);
});

test('Send clears the draft only after the Enter acknowledgement', async () => {
  const page = await browser();
  const socket = await page.authorize();
  page.submit();
  await settle();
  assert.equal(socket.sent.at(-1).action, 'input');
  assert.equal(socket.sent.at(-1).text, 'fixture input');
  assert.equal(socket.sent.at(-1).tabID, 'tab-1');
  socket.reply();
  await settle();
  assert.equal(page.element('message').value, 'fixture input');
  await page.fireTimer(100);
  assert.deepEqual(socket.sent.map(request => request.action), ['state', 'input', 'key']);
  assert.equal(socket.sent.at(-1).text, 'enter');
  assert.equal(socket.sent.at(-1).tabID, 'tab-1');
  socket.reply();
  await settle();
  assert.equal(page.element('message').value, '');
  assert.equal(page.element('send').disabled, true); // Empty messages cannot be sent.
});

test('a refused Enter keeps the sent draft and reports the failure', async () => {
  const page = await browser();
  const socket = await page.authorize();
  page.submit();
  await settle();
  socket.reply();
  await settle();
  await page.fireTimer(100);
  const enter = socket.sent.at(-1);
  assert.equal(enter.action, 'key');
  socket.receive({ data: JSON.stringify({
    challenge: enter.challenge, sequence: enter.sequence, ok: false, error: 'Refused.' }) });
  await settle();
  assert.equal(page.element('message').value, 'fixture input');
  assert.equal(page.element('error').hidden, false);
  assert.equal(socket.sent.at(-1).action, 'key');
});

test('a Mac tab switch during Send files the sent draft under its own tab', async () => {
  const page = await browser();
  const socket = await page.authorize();
  page.submit();
  await settle();
  const input = socket.sent.at(-1);
  socket.receive({ data: JSON.stringify({ challenge: input.challenge, sequence: input.sequence, ok: true,
    state: { tabs: [{ id: 'tab-1', title: 'One', status: 'idle' }, { id: 'tab-2', title: 'Two', status: 'idle' }],
      selectedTabID: 'tab-2', terminal: 'TWO' } }) });
  await settle();
  assert.equal(page.element('message').value, '');
  await page.fireTimer(100);
  const enter = socket.sent.at(-1);
  assert.equal(enter.action, 'key');
  assert.equal(enter.tabID, 'tab-1');
  socket.receive({ data: JSON.stringify({ challenge: enter.challenge, sequence: enter.sequence, ok: true,
    state: { tabs: [{ id: 'tab-1', title: 'One', status: 'idle' }, { id: 'tab-2', title: 'Two', status: 'idle' }],
      selectedTabID: 'tab-2', terminal: 'TWO' } }) });
  await settle();
  page.element('tabs').value = 'tab-1';
  page.element('tabs').onchange();
  await settle();
  socket.reply();
  await settle();
  assert.equal(page.element('message').value, '');
});

test('a stale send finishing after reconnect cannot enable a newer in-flight send', async () => {
  const page = await browser();
  const original = await page.authorize();
  page.submit();
  await settle();
  original.reply();
  await settle();
  original.close();
  page.element('reconnect').onclick();
  const replacement = await page.authorize();
  page.element('message').value = 'second send';
  page.submit();
  await settle();
  assert.equal(replacement.sent.at(-1).action, 'input');
  await page.fireTimer(100);
  await settle();
  assert.equal(page.element('error').hidden, false);
  assert.equal(page.element('send').disabled, true);
});

test('a malformed state rejects the command, closes the socket, and recovers', async () => {
  const page = await browser();
  const socket = await page.authorize();
  page.element('tabs').value = 'tab-1';
  page.element('tabs').onchange();
  await settle();
  const request = socket.sent.at(-1);
  assert.equal(request.action, 'select');
  socket.receive({ data: JSON.stringify({ challenge: request.challenge, sequence: request.sequence, ok: true,
    state: { tabs: [{ id: 'x', title: 'A', status: 'idle' }, { id: 'x', title: 'B', status: 'idle' }],
      selectedTabID: 'x', terminal: '' } }) });
  await settle();
  assert.equal(socket.readyState, 3);
  assert.equal(page.element('error').hidden, false);
  page.element('reconnect').onclick();
  const replacement = await page.authorize();
  page.element('message').value = 'after recovery';
  page.submit();
  await settle();
  assert.equal(replacement.sent.at(-1).action, 'input');
});

test('a state naming an unknown selected tab is rejected the same way', async () => {
  const page = await browser();
  const socket = await page.authorize();
  page.element('message').value = 'queued';
  page.element('paste').onclick();
  await settle();
  const request = socket.sent.at(-1);
  socket.receive({ data: JSON.stringify({ challenge: request.challenge, sequence: request.sequence, ok: true,
    state: { tabs: [{ id: 'tab-1', title: 'A', status: 'idle' }], selectedTabID: 'ghost', terminal: '' } }) });
  await settle();
  assert.equal(socket.readyState, 3);
  assert.equal(page.element('message').value, 'queued');
});

test('an unanswered connection reports and closes after ten seconds', async () => {
  const page = await browser();
  const socket = page.sockets.at(-1);
  await page.fireTimer(10000);
  assert.equal(socket.readyState, 3);
  assert.match(page.element('error').textContent, /did not respond/);
  page.element('reconnect').onclick();
  await page.authorize();
  assert.equal(page.element('status').textContent, 'Connected');
});

test('New falls back to a new session when the Mac has no project list', async () => {
  const page = await browser();
  const socket = await page.authorize();
  page.element('new').onclick();
  await settle();
  const projects = socket.sent.at(-1);
  assert.equal(projects.action, 'projects');
  socket.receive({ data: JSON.stringify({
    challenge: projects.challenge, sequence: projects.sequence, ok: false, error: 'Unknown action.' }) });
  await settle();
  const created = socket.sent.at(-1);
  assert.equal(created.action, 'new');
  assert.equal(created.text, undefined);
  socket.reply(created);
  await settle();
  assert.equal(page.element('error').hidden, true);
  assert.equal(page.element('project-dialog').open, false);
});

test('a Sigil restart carries the draft and attachments to the restored tab', async () => {
  const page = await browser();
  const socket = await page.authorize();
  page.element('message').value = 'long message';
  page.element('attach').files = [{ name: 'notes.txt', type: 'text/plain', size: 5 }];
  page.element('attach').onchange();
  assert.equal(page.element('attachments').children.length, 1);
  await page.fireTimer(1000);
  const poll = socket.sent.at(-1);
  assert.equal(poll.action, 'state');
  socket.receive({ data: JSON.stringify({ challenge: poll.challenge, sequence: poll.sequence, ok: true,
    state: { tabs: [{ id: 'tab-9', title: 'Fixture', status: 'idle' }], selectedTabID: 'tab-9', terminal: 'READY' } }) });
  await settle();
  assert.equal(page.element('message').value, 'long message');
  assert.equal(page.element('attachments').children.length, 1);
});

test('a command that times out keeps the socket so later commands can use it', async () => {
  const page = await browser();
  const socket = await page.authorize();
  page.element('new').onclick();
  await settle();
  assert.equal(socket.sent.at(-1).action, 'projects');
  await page.fireTimer(10000);
  assert.equal(socket.readyState, 1);
  assert.equal(page.element('error').hidden, false);
  page.element('new').onclick();
  await settle();
  assert.equal(socket.sent.at(-1).action, 'projects');
  assert.equal(socket.readyState, 1);
});

test('a late reply after a command timeout does not close the socket', async () => {
  const page = await browser();
  const socket = await page.authorize();
  page.element('new').onclick();
  await settle();
  const timedOut = socket.sent.at(-1);
  await page.fireTimer(10000);
  socket.receive({ data: JSON.stringify({
    challenge: timedOut.challenge, sequence: timedOut.sequence, ok: true,
    state: { tabs: [{ id: 'tab-1', title: 'Late', status: 'idle' }], selectedTabID: 'tab-1', terminal: 'LATE' },
  }) });
  await settle();
  assert.equal(socket.readyState, 1);
  assert.equal(page.element('status').textContent, 'Connected');
  assert.equal(page.element('terminal').textContent, 'READY');
});

test('a command queued behind a poll does not run after a new handshake', async () => {
  const page = await browser();
  const socket = await page.authorize();
  await page.fireTimer(1000);
  assert.equal(socket.sent.at(-1).action, 'state');
  page.element('new').onclick();
  await settle();
  assert.equal(socket.sent.filter(request => request.action === 'projects').length, 0);
  socket.receive({ hello: 'd'.repeat(64) });
  await settle();
  assert.equal(socket.sent.filter(request => request.action === 'projects').length, 0);
  assert.equal(socket.sent.at(-1).action, 'state');
  assert.equal(socket.sent.at(-1).challenge, 'd'.repeat(64));
  socket.reply();
  await settle();
  assert.equal(socket.readyState, 1);
  assert.equal(page.element('status').textContent, 'Connected');
});

test('reconnect waits longer after each failed attempt', async () => {
  const page = await browser();
  const socket = await page.authorize();
  socket.close();
  await settle();
  await page.fireTimer(500);
  assert.equal(page.sockets.length, 2);
  page.sockets.at(-1).close();
  await settle();
  await page.fireTimer(1000);
  assert.equal(page.sockets.length, 3);
});

test('a new Mac handshake on the same socket is accepted without disconnecting', async () => {
  const page = await browser();
  const socket = await page.authorize();
  socket.receive({ hello: 'd'.repeat(64) });
  await settle();
  assert.equal(socket.readyState, 1);
  assert.equal(socket.sent.at(-1).action, 'state');
  assert.equal(socket.sent.at(-1).challenge, 'd'.repeat(64));
  socket.reply();
  await settle();
  assert.equal(page.element('status').textContent, 'Connected');
  assert.equal(page.element('status').dataset.connected, 'true');
});

test('an ended session disables remote actions but keeps local editing and picker', async () => {
  const page = await browser();
  const socket = await page.authorize();
  await page.fireTimer(1000);
  const request = socket.sent.at(-1);
  assert.equal(request.action, 'state');
  socket.receive({ data: JSON.stringify({ challenge: request.challenge, sequence: request.sequence, ok: true,
    state: { tabs: [{ id: 'tab-1', title: 'Done', status: 'exited' }], selectedTabID: 'tab-1', terminal: '' } }) });
  await settle();
  assert.equal(page.element('tabs').children[0].textContent, 'Done · Ended');
  assert.equal(page.element('send').disabled, true);
  assert.equal(page.element('paste').disabled, true);
  assert.equal(page.element('interrupt').disabled, true);
  assert.equal(page.element('new').disabled, false);
  assert.equal(page.element('tabs').disabled, false);
  assert.equal(page.element('message').disabled, false);
  assert.equal(page.element('empty-output-h2').textContent, 'Session ended');
  assert.equal(page.element('empty-output-p').textContent, 'Restart this session in Sigil on your Mac.');
});

test('an empty session list keeps a labelled placeholder and disables the picker', async () => {
  const page = await browser();
  const socket = await page.authorize();
  await page.fireTimer(1000);
  const request = socket.sent.at(-1);
  socket.receive({ data: JSON.stringify({ challenge: request.challenge, sequence: request.sequence, ok: true,
    state: { tabs: [], selectedTabID: null, terminal: '' } }) });
  await settle();
  const placeholder = page.element('tabs').children[0];
  assert.equal(placeholder.value, '');
  assert.equal(placeholder.textContent, 'No open sessions');
  assert.equal(page.element('tabs').disabled, true);
  assert.equal(page.element('new').disabled, false);
  assert.equal(page.element('empty-output-h2').textContent, 'No open sessions.');
});

test('a failed selection restores the picker to the displayed session', async () => {
  const page = await browser();
  const socket = await page.authorize();
  await page.fireTimer(1000);
  const poll = socket.sent.at(-1);
  socket.receive({ data: JSON.stringify({ challenge: poll.challenge, sequence: poll.sequence, ok: true,
    state: { tabs: [{ id: 'tab-1', title: 'One', status: 'idle' }, { id: 'tab-2', title: 'Two', status: 'idle' }],
      selectedTabID: 'tab-1', terminal: '' } }) });
  await settle();
  page.element('tabs').value = 'tab-2';
  page.element('tabs').onchange();
  await settle();
  const request = socket.sent.at(-1);
  assert.equal(request.action, 'select');
  socket.receive({ data: JSON.stringify({ challenge: request.challenge, sequence: request.sequence,
    ok: false, error: 'This tab is closed.' }) });
  await settle();
  assert.equal(page.element('tabs').value, 'tab-1');
  assert.equal(page.element('error').hidden, false);
});

test('Send does not submit Enter after its paste connection is replaced', async () => {
  const page = await browser();
  const original = await page.authorize();
  page.submit();
  await settle();
  assert.equal(original.sent.at(-1).action, 'input');
  original.reply();
  await settle();
  original.close();
  page.element('reconnect').onclick();
  const replacement = await page.authorize();
  await page.fireTimer(100);
  assert.deepEqual(original.sent.map(request => request.action), ['state', 'input']);
  assert.deepEqual(replacement.sent.map(request => request.action), ['state']);
  assert.equal(page.element('error').hidden, false);
});

test('a command waiting behind a poll never crosses a reconnect', async () => {
  const page = await browser();
  const original = await page.authorize();
  await page.fireTimer(1000);
  page.submit();
  await settle();
  original.close();
  page.element('reconnect').onclick();
  const replacement = await page.authorize();
  assert.deepEqual(original.sent.map(request => request.action), ['state', 'state']);
  assert.deepEqual(replacement.sent.map(request => request.action), ['state']);
  assert.equal(page.element('message').value, 'fixture input');
});

test('a ticket in a Mac reply is stored and used on reconnect', async () => {
  const page = await browser();
  const socket = await page.authorize();
  await page.fireTimer(1000);
  const poll = socket.sent.at(-1);
  const ticket = 'cd'.repeat(32);
  socket.receive({ data: JSON.stringify({
    challenge: poll.challenge, sequence: poll.sequence, ok: true, ticket,
    state: { tabs: [{ id: 'tab-1', title: 'Fixture', status: 'idle' }], selectedTabID: 'tab-1', terminal: 'READY' },
  }) });
  await settle();
  assert.equal(page.stored().ticket, ticket);
  const reloaded = await browser({ saved: page.stored() });
  const next = String(reloaded.sockets.at(-1).url);
  assert.equal(new URL(next).searchParams.has('ticket'), false);
  assert.equal(new URL(next).searchParams.has('room'), false);
  const restored = reloaded.sockets.at(-1);
  restored.receive({ route: 'f'.repeat(64) });
  await settle();
  assert.equal(restored.routes[0].ticket, ticket);
  assert.equal(restored.routes[0].room, 'a'.repeat(32));
  assert.equal(restored.sent.length, 0);
});

test('a same-document QR fragment reloads the app but an empty fragment does not', async () => {
  const page = await browser();
  page.events.get('hashchange')();
  assert.equal(page.reloads(), 0);
  page.location.hash = `#room=${'a'.repeat(32)}&key=${'b'.repeat(64)}`;
  page.events.get('hashchange')();
  assert.equal(page.reloads(), 1);
});

test('sending never disables the editor or erases a newer draft', async () => {
  const page = await browser();
  const socket = await page.authorize();
  page.submit();
  await settle();
  assert.equal(page.element('message').disabled, false);
  page.element('message').value = 'My next thought';
  socket.reply();
  await settle();
  assert.equal(page.element('message').value, 'My next thought');
});

test('disconnect preserves an editable draft while remote actions are disabled', async () => {
  const page = await browser();
  const socket = await page.authorize();
  page.element('message').value = 'Keep this draft';
  socket.close();
  assert.equal(page.element('message').disabled, false);
  assert.equal(page.element('send').disabled, true);
  assert.equal(page.element('message').value, 'Keep this draft');
});


test('a replayed reply from a stale epoch is dropped without consuming the current request', async () => {
  const page = await browser();
  const socket = await page.authorize();
  const stale = socket.sent[0];
  socket.receive({ hello: 'd'.repeat(64) });
  await settle();
  const current = socket.sent.at(-1);
  assert.equal(current.sequence, stale.sequence);
  assert.notEqual(current.challenge, stale.challenge);
  socket.receive({ data: JSON.stringify({ challenge: stale.challenge, sequence: stale.sequence,
    ok: true, ticket: 'f'.repeat(64), state: { tabs: [], terminal: 'REPLAY' } }) });
  await settle();
  assert.equal(socket.readyState, 1);
  assert.equal(page.element('error').hidden, true);
  assert.equal(page.element('terminal').textContent, 'READY');
  assert.equal(page.stored().ticket, undefined);
  socket.reply(current);
  await settle();
  assert.equal(page.element('status').textContent, 'Connected');
  assert.equal([...page.timers.values()].some(timer => timer.delay === 10000), false);
});

test('duplicate hello does not reset sequence or replace a pending request', async () => {
  const page = await browser();
  const socket = await page.authorize();
  await page.fireTimer(1000);
  const pending = socket.sent.at(-1);
  const count = socket.sent.length;
  socket.receive({ hello: pending.challenge });
  await settle();
  assert.equal(socket.sent.length, count);
  assert.equal(socket.readyState, 1);
  socket.reply(pending);
  await settle();
  page.element('new').onclick();
  await settle();
  assert.equal(socket.sent.at(-1).sequence, pending.sequence + 1);
  assert.equal(socket.sent.at(-1).action, 'projects');
});

test('unauthorized after a dropped pairing acknowledgement retries with the persisted device key', async () => {
  const page = await browser({ hash: `#room=${'a'.repeat(32)}&key=${'b'.repeat(64)}` });
  const socket = page.sockets.at(-1);
  socket.receive({ hello: 'c'.repeat(64) });
  await settle();
  assert.equal(socket.sent.at(-1).action, 'pair');
  assert.equal(page.sealed.at(-1).key.hex, 'b'.repeat(64));
  socket.receive({ error: 'unauthorized' });
  await settle();
  assert.equal(socket.readyState, 3);
  await page.fireTimer(500);
  const next = await page.authorize();
  assert.equal(next.sent[0].action, 'state');
  assert.equal(page.sealed.at(-1).key.hex, page.stored().key.hex);
  assert.equal(page.sealed.at(-1).key.hex, 'e'.repeat(64));
});

test('unauthorized without bootstrap stops automatic reconnect and asks for a new scan', async () => {
  const page = await browser();
  const socket = await page.authorize();
  socket.receive({ error: 'unauthorized' });
  await settle();
  assert.equal(socket.readyState, 3);
  assert.match(page.element('error').textContent, /Scan a new code/);
  assert.equal(page.timers.size, 0);
  page.events.get('visibilitychange')();
  await settle();
  assert.equal(page.sockets.length, 1);
  assert.equal(page.element('status').textContent, 'Disconnected');
});

test('a rejected pairing shows Scan and Paste so the phone can pair again', async () => {
  const page = await browser();
  const socket = await page.authorize();
  socket.receive({ error: 'unauthorized' });
  await settle();
  assert.equal(page.element('welcome').hidden, false);
  assert.equal(page.element('controls').hidden, true);
  assert.equal(page.element('welcome-actions').hidden, false);
  assert.equal(page.element('welcome-.pairing-steps').hidden, false);
  assert.equal(page.element('welcome-h2').textContent, 'Pair again');
  assert.match(page.element('error').textContent, /Scan a new code/);
});


test('routing uses a separate sealed first message, never the URL or the device key', async () => {
  const ticket = 'd'.repeat(64);
  const page = await browser({ saved: { room: 'a'.repeat(32), key: { device: true }, ticket } });
  const socket = page.sockets.at(-1);
  assert.equal(socket.url.search, '?role=phone');
  socket.receive({ route: 'f'.repeat(64) });
  await settle();
  assert.equal(socket.routes.length, 1);
  assert.equal(socket.routes[0].ticket, ticket);
  assert.deepEqual(Object.keys(socket.routes[0]).sort(), ['room', 'ticket']);
  assert.equal(page.sealed.at(-1).key.hex, 'f'.repeat(64));
  assert.equal(page.sealed.at(-1).direction, 'relay-phone');
  assert.equal(socket.sent.length, 0);
  socket.receive({ route: 'e'.repeat(64) });
  await settle();
  assert.equal(socket.routes.length, 1);
});

test('a new chat asks which project and cancel does not start one', async () => {
  const page = await browser();
  const socket = await page.authorize();
  page.element('new').onclick();
  await settle();
  assert.equal(socket.sent.at(-1).action, 'projects');
  const request = socket.sent.at(-1);
  socket.receive({ data: JSON.stringify({
    challenge: request.challenge, sequence: request.sequence, ok: true,
    projects: [{ name: 'Widget', folder: '/work/widget' }, { name: 'Other', folder: '/work/other' }],
    state: { tabs: [{ id: 'tab-1', title: 'Fixture', status: 'idle' }], selectedTabID: 'tab-1', terminal: 'READY' },
  }) });
  await settle();
  assert.equal(page.element('project-dialog').open, true);
  assert.equal(page.element('project-list').children.length, 2);
  const labels = page.element('project-list').children.map(button => button.children.map(node => node.textContent).join(' '));
  assert.deepEqual(labels, ['Widget /work/widget', 'Other /work/other']);
  page.element('project-cancel').onclick();
  await settle();
  assert.equal(socket.sent.filter(item => item.action === 'new').length, 0);
  page.element('new').onclick();
  await settle();
  const again = socket.sent.at(-1);
  assert.equal(again.action, 'projects');
  socket.receive({ data: JSON.stringify({
    challenge: again.challenge, sequence: again.sequence, ok: true,
    projects: [{ name: 'Widget', folder: '/work/widget' }],
    state: { tabs: [{ id: 'tab-1', title: 'Fixture', status: 'idle' }], selectedTabID: 'tab-1', terminal: 'READY' },
  }) });
  await settle();
  page.element('project-list').children[0].onclick();
  await settle();
  assert.equal(socket.sent.at(-1).action, 'new');
  assert.equal(socket.sent.at(-1).text, '/work/widget');
});

test('a snapshot with no overlap keeps the previous tail', async () => {
  const page = await browser();
  const socket = await page.authorize();
  await page.fireTimer(1000);
  const first = socket.sent.at(-1);
  socket.receive({ data: JSON.stringify({
    challenge: first.challenge, sequence: first.sequence, ok: true,
    state: { tabs: [{ id: 'tab-1', title: 'Fixture', status: 'idle' }], selectedTabID: 'tab-1', terminal: 'OLD_TAIL_MARKER' },
  }) });
  await settle();
  await page.fireTimer(1000);
  const next = socket.sent.at(-1);
  socket.receive({ data: JSON.stringify({
    challenge: next.challenge, sequence: next.sequence, ok: true,
    state: { tabs: [{ id: 'tab-1', title: 'Fixture', status: 'idle' }], selectedTabID: 'tab-1', terminal: 'NEW_WINDOW_ONLY' },
  }) });
  await settle();
  const text = page.element('terminal').textContent;
  assert.match(text, /OLD_TAIL_MARKER/);
  assert.match(text, /NEW_WINDOW_ONLY/);
});

test('a sliding snapshot under a fixed footer keeps each line once', async () => {
  const page = await browser();
  const socket = await page.authorize();
  const lines = Array.from({ length: 40 }, (_, index) => `line ${String(index).padStart(3, '0')} of the streamed answer`);
  const snapshot = step => lines.slice(step * 3, step * 3 + 20).join('\n') + `\n\nFOOTER Thinking… ${9 + step}s`;
  for (let step = 0; step < 6; step++) {
    await page.fireTimer(1000);
    const poll = socket.sent.at(-1);
    socket.receive({ data: JSON.stringify({
      challenge: poll.challenge, sequence: poll.sequence, ok: true,
      state: { tabs: [{ id: 'tab-1', title: 'Fixture', status: 'working' }], selectedTabID: 'tab-1', terminal: snapshot(step) },
    }) });
    await settle();
  }
  const text = page.element('terminal').textContent;
  for (const line of lines.slice(0, 35)) assert.equal(text.split(line).length - 1, 1, line);
  assert.equal(text.split('FOOTER').length - 1, 1);
  assert.match(text, /FOOTER Thinking… 14s$/);
});

test('a repeated block keeps the text between its copies when the snapshot slides', async () => {
  const page = await browser();
  const socket = await page.authorize();
  const block = Array.from({ length: 8 }, (_, index) => `    at frame${index} (worker.js:${index + 10})`).join('\n');
  const snapshots = [
    `PREFIX_LINE\n${block}\nUNIQUE_BETWEEN_COPIES\n${block}\n\nFOOTER Thinking… 9s`,
    `${block}\nNEW_AFTER_SECOND_COPY\n\nFOOTER Thinking… 10s`,
  ];
  for (const terminal of snapshots) {
    await page.fireTimer(1000);
    const poll = socket.sent.at(-1);
    socket.receive({ data: JSON.stringify({
      challenge: poll.challenge, sequence: poll.sequence, ok: true,
      state: { tabs: [{ id: 'tab-1', title: 'Fixture', status: 'working' }], selectedTabID: 'tab-1', terminal },
    }) });
    await settle();
  }
  const text = page.element('terminal').textContent;
  for (const marker of ['PREFIX_LINE', 'UNIQUE_BETWEEN_COPIES', 'NEW_AFTER_SECOND_COPY']) {
    assert.equal(text.split(marker).length - 1, 1, marker);
  }
  assert.equal(text.split('at frame0 ').length - 1, 2);
  assert.equal(text.split('FOOTER').length - 1, 1);
});

test('a redraw replaces the live tail instead of appending it', async () => {
  const page = await browser();
  const socket = await page.authorize();
  await page.fireTimer(1000);
  const poll = socket.sent.at(-1);
  assert.equal(poll.action, 'state');
  socket.receive({ data: JSON.stringify({
    challenge: poll.challenge, sequence: poll.sequence, ok: true,
    state: { tabs: [{ id: 'tab-1', title: 'Fixture', status: 'idle' }], selectedTabID: 'tab-1', terminal: 'task [\\]' },
  }) });
  await settle();
  await page.fireTimer(1000);
  const next = socket.sent.at(-1);
  socket.receive({ data: JSON.stringify({
    challenge: next.challenge, sequence: next.sequence, ok: true,
    state: { tabs: [{ id: 'tab-1', title: 'Fixture', status: 'idle' }], selectedTabID: 'tab-1', terminal: 'task [|]' },
  }) });
  await settle();
  const text = page.element('terminal').textContent;
  assert.equal(text.includes('task [\\]'), false);
  assert.equal(text.includes('task [|]'), true);
});

test('a new search clears the previous saved chats before the reply', async () => {
  const page = await browser();
  const socket = await page.authorize();
  page.element('sessions-toggle').onclick();
  page.element('session-search').value = 'one';
  page.element('session-search').oninput();
  await settle();
  const first = socket.sent.at(-1);
  socket.receive({ data: JSON.stringify({
    challenge: first.challenge, sequence: first.sequence, ok: true,
    chats: [{ id: 'chat-1', title: 'One', folder: '/work/one' }],
    state: { tabs: [{ id: 'tab-1', title: 'Fixture', status: 'idle' }], selectedTabID: 'tab-1', terminal: 'READY' },
  }) });
  await settle();
  assert.equal(page.element('saved-list').children.length, 1);
  page.element('session-search').value = 'two';
  page.element('session-search').oninput();
  assert.equal(page.element('saved-list').children.length, 0);
  await settle();
  const second = socket.sent.at(-1);
  assert.equal(second.action, 'chats');
  assert.equal(second.text, 'two');
  assert.equal(socket.sent.filter(item => item.action === 'open').length, 0);
});

test('a shortened chat list says it is partial', async () => {
  const page = await browser();
  const socket = await page.authorize();
  page.element('sessions-toggle').onclick();
  page.element('session-search').value = 'wide';
  page.element('session-search').oninput();
  await settle();
  const request = socket.sent.at(-1);
  socket.receive({ data: JSON.stringify({
    challenge: request.challenge, sequence: request.sequence, ok: true, chatsTruncated: true,
    chats: [{ id: 'chat-1', title: 'Wide one', folder: '/work/one' }],
    state: { tabs: [{ id: 'tab-1', title: 'Fixture', status: 'idle' }], selectedTabID: 'tab-1', terminal: 'READY' },
  }) });
  await settle();
  assert.equal(page.element('saved-list').children.length, 1);
  assert.equal(page.element('saved-empty').hidden, false);
  assert.match(page.element('saved-empty').textContent, /Showing the first matches/);
});

test('an empty project list can still start a session in the current folder', async () => {
  const page = await browser();
  const socket = await page.authorize();
  page.element('new').onclick();
  await settle();
  const request = socket.sent.at(-1);
  socket.receive({ data: JSON.stringify({
    challenge: request.challenge, sequence: request.sequence, ok: true,
    projects: [],
    state: { tabs: [{ id: 'tab-1', title: 'Fixture', status: 'idle' }], selectedTabID: 'tab-1', terminal: 'READY' },
  }) });
  await settle();
  assert.equal(page.element('project-dialog').open, true);
  const choice = page.element('project-list').children[0];
  assert.ok(choice);
  assert.match(choice.children.map(node => node.textContent).join(' '), /Current folder/);
  choice.onclick();
  await settle();
  assert.equal(socket.sent.at(-1).action, 'new');
  assert.equal(socket.sent.at(-1).text, undefined);
});

test('a full project page can ask for the next page', async () => {
  const page = await browser();
  const socket = await page.authorize();
  page.element('new').onclick();
  await settle();
  const request = socket.sent.at(-1);
  const projects = Array.from({ length: 40 }, (_, index) => ({ name: `P${index}`, folder: `/work/${index}` }));
  socket.receive({ data: JSON.stringify({
    challenge: request.challenge, sequence: request.sequence, ok: true, projects,
    state: { tabs: [{ id: 'tab-1', title: 'Fixture', status: 'idle' }], selectedTabID: 'tab-1', terminal: 'READY' },
  }) });
  await settle();
  const more = [...page.element('project-list').children].find(button => button.dataset.more === 'true');
  assert.ok(more);
  more.onclick();
  await settle();
  assert.equal(socket.sent.at(-1).action, 'projects');
  assert.equal(socket.sent.at(-1).index, 40);
});

test('a shortened project page can still ask for the rest', async () => {
  const page = await browser();
  const socket = await page.authorize();
  page.element('new').onclick();
  await settle();
  const request = socket.sent.at(-1);
  socket.receive({ data: JSON.stringify({
    challenge: request.challenge, sequence: request.sequence, ok: true, projectsTruncated: true,
    projects: [{ name: 'One', folder: '/work/one' }, { name: 'Two', folder: '/work/two' }],
    state: { tabs: [{ id: 'tab-1', title: 'Fixture', status: 'idle' }], selectedTabID: 'tab-1', terminal: 'READY' },
  }) });
  await settle();
  const more = [...page.element('project-list').children].find(button => button.dataset.more === 'true');
  assert.ok(more);
  more.onclick();
  await settle();
  assert.equal(socket.sent.at(-1).index, 2);
});

test('a project click does nothing while the next page is loading', async () => {
  const page = await browser();
  const socket = await page.authorize();
  page.element('new').onclick();
  await settle();
  const request = socket.sent.at(-1);
  const projects = Array.from({ length: 40 }, (_, index) => ({ name: `P${index}`, folder: `/work/${index}` }));
  socket.receive({ data: JSON.stringify({
    challenge: request.challenge, sequence: request.sequence, ok: true, projects,
    state: { tabs: [{ id: 'tab-1', title: 'Fixture', status: 'idle' }], selectedTabID: 'tab-1', terminal: 'READY' },
  }) });
  await settle();
  const more = [...page.element('project-list').children].find(button => button.dataset.more === 'true');
  more.onclick();
  await settle();
  const choice = page.element('project-list').children[0];
  choice.onclick();
  await settle();
  assert.equal(page.element('project-dialog').open, true);
  assert.equal(socket.sent.filter(item => item.action === 'new').length, 0);
});

test('saved chat search sends titles and folders and opens the chosen chat', async () => {
  const page = await browser();
  const socket = await page.authorize();
  page.element('sessions-toggle').onclick();
  page.element('session-search').value = 'widget';
  page.element('session-search').oninput();
  await settle();
  const request = socket.sent.at(-1);
  assert.equal(request.action, 'chats');
  assert.equal(request.text, 'widget');
  socket.receive({ data: JSON.stringify({
    challenge: request.challenge, sequence: request.sequence, ok: true,
    chats: [{ id: 'chat-1', title: 'Fix the widget', folder: '/work/widget', transcript: 'SECRET_TRANSCRIPT' }],
    state: { tabs: [{ id: 'tab-1', title: 'Fixture', status: 'idle' }], selectedTabID: 'tab-1', terminal: 'READY' },
  }) });
  await settle();
  const row = page.element('saved-list').children[0];
  assert.ok(row);
  assert.deepEqual(row.children.map(node => node.textContent), ['Fix the widget', '/work/widget']);
  assert.equal(row.children.map(node => node.textContent).join('\n').includes('SECRET_TRANSCRIPT'), false);
  row.onclick();
  await settle();
  assert.equal(socket.sent.at(-1).action, 'open');
  assert.equal(socket.sent.at(-1).name, 'chat-1');
  assert.equal(socket.sent.at(-1).text, '/work/widget');
  assert.equal(socket.sent.at(-1).transcript, undefined);
});

test('scrolling up prepends an earlier slice and a later tail keeps it', async () => {
  const page = await browser();
  const socket = await page.authorize();
  const terminal = page.element('terminal');
  terminal.scrollHeight = 800;
  terminal.clientHeight = 200;
  terminal.scrollTop = 0;
  terminal.onscroll();
  await settle();
  const request = socket.sent.at(-1);
  assert.equal(request.action, 'earlier');
  assert.equal(request.tabID, 'tab-1');
  assert.ok(request.text);
  assert.ok(request.name);
  socket.receive({ data: JSON.stringify({
    challenge: request.challenge, sequence: request.sequence, ok: true, earlier: 'EARLY_MARKER\n',
    state: { tabs: [{ id: 'tab-1', title: 'Fixture', status: 'idle' }], selectedTabID: 'tab-1', terminal: 'TAIL_MARKER' },
  }) });
  await settle();
  assert.match(terminal.textContent, /EARLY_MARKER/);
  assert.match(terminal.textContent, /TAIL_MARKER/);
  await page.fireTimer(1000);
  assert.equal(socket.sent.at(-1).action, 'state');
  const poll = socket.sent.at(-1);
  socket.receive({ data: JSON.stringify({
    challenge: poll.challenge, sequence: poll.sequence, ok: true,
    state: { tabs: [{ id: 'tab-1', title: 'Fixture', status: 'idle' }], selectedTabID: 'tab-1', terminal: 'AIL_MARKER!' },
  }) });
  await settle();
  assert.match(terminal.textContent, /EARLY_MARKER/);
  assert.match(terminal.textContent, /AIL_MARKER!/);
  page.element('find-toggle').onclick();
  page.element('find-query').value = 'EARLY_MARKER';
  page.element('find-query').oninput();
  assert.match(page.element('find-count').textContent, /1 of 1/);
});
