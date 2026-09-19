import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import vm from 'node:vm';
import { readableOutput } from '../public/output.mjs';

const source = (await readFile(new URL('../public/app.mjs', import.meta.url), 'utf8'))
  .replace(/^import .* from '\.\/.*\.mjs';\n/gm, '');
const settle = () => new Promise(resolve => setImmediate(resolve));

// Run the real handlers; only browser services and encryption are replaced.
async function browser() {
  const elements = new Map(), events = new Map(), timers = new Map(), sockets = [];
  let nextTimer = 0, reloads = 0;
  const element = id => {
    if (!elements.has(id)) elements.set(id, {
      id, value: '', textContent: '', hidden: false, disabled: false, dataset: {}, style: {},
      open: false, focus() {}, contains() { return false; },
      getAttribute(name) { return this[name]; }, setAttribute(name, value) { this[name] = value; },
      addEventListener() {},
      scrollHeight: 0, scrollTop: 0, clientHeight: 0,
      querySelector(selector) { return element(`${id}-${selector}`); },
      replaceChildren(...children) { this.children = children; },
    });
    return elements.get(id);
  };
  const location = {
    origin: 'https://sidereal.example', protocol: 'https:', pathname: '/', hash: '',
    reload() { reloads++; },
  };
  const document = {
    hidden: false, getElementById: element, createElement: () => ({}),
    querySelectorAll: selector => selector === '[data-key]' ? [] :
      ['new', 'tabs', 'message', 'send', 'paste', 'interrupt'].map(element),
    addEventListener: (name, callback) => events.set(name, callback),
  };
  class FakeSocket {
    static OPEN = 1;
    readyState = 1;
    sent = [];
    constructor(url) { this.url = url; sockets.push(this); }
    send(frame) { this.sent.push(JSON.parse(JSON.parse(frame).data)); }
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
                get: () => ({ result: { room: 'a'.repeat(32), key: {} } }),
                put: () => ({}),
                delete: () => ({}),
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
  vm.runInNewContext(source, {
    readableOutput, document, location, history: { replaceState() {} }, indexedDB,
    window: { addEventListener: (name, callback) => events.set(name, callback) },
    navigator: {}, crypto: { subtle: {} }, URL, URLSearchParams, TextEncoder,
    WebSocket: FakeSocket, seal: async value => JSON.stringify(value), open: async frame => JSON.parse(frame),
    setTimeout(callback, delay) { const id = ++nextTimer; timers.set(id, { callback, delay }); return id; },
    clearTimeout: id => timers.delete(id),
  });
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
  return { element, events, location, sockets, authorize, fireTimer, submit, reloads: () => reloads };
}

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

test('a command that times out keeps the socket so later commands can use it', async () => {
  const page = await browser();
  const socket = await page.authorize();
  page.element('new').onclick();
  await settle();
  assert.equal(socket.sent.at(-1).action, 'new');
  await page.fireTimer(10000);
  assert.equal(socket.readyState, 1);
  assert.equal(page.element('error').hidden, false);
  page.element('new').onclick();
  await settle();
  assert.equal(socket.sent.at(-1).action, 'new');
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
  assert.equal(socket.sent.filter(request => request.action === 'new').length, 0);
  socket.receive({ hello: 'd'.repeat(64) });
  await settle();
  assert.equal(socket.sent.filter(request => request.action === 'new').length, 0);
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
  page.element('reconnect').onclick();
  await settle();
  const next = String(page.sockets.at(-1).url);
  assert.match(next, new RegExp(`ticket=${ticket}`));
  assert.match(next, new RegExp(`room=${'a'.repeat(32)}`));
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
