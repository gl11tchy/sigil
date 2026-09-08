import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import vm from 'node:vm';

const source = (await readFile(new URL('../public/app.mjs', import.meta.url), 'utf8'))
  .replace(/^import .* from '\.\/crypto\.mjs';\n/, '');
const settle = () => new Promise(resolve => setImmediate(resolve));

// Run the real handlers; only browser services and encryption are replaced.
async function browser() {
  const elements = new Map(), events = new Map(), timers = new Map(), sockets = [];
  let nextTimer = 0, reloads = 0;
  const element = id => {
    if (!elements.has(id)) elements.set(id, {
      id, value: '', textContent: '', hidden: false, disabled: false, dataset: {}, style: {},
      getAttribute(name) { return this[name]; }, setAttribute(name, value) { this[name] = value; },
      scrollHeight: 0, scrollTop: 0, clientHeight: 0,
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
              objectStore: () => ({ get: () => ({ result: { room: 'a'.repeat(32), key: {} } }) }),
            };
            queueMicrotask(() => transaction.oncomplete());
            return transaction;
          },
        };
        request.onsuccess();
      });
      return request;
    },
  };
  vm.runInNewContext(source, {
    document, location, history: { replaceState() {} }, indexedDB,
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

test('Send pastes and submits exactly once on an unchanged connection', async () => {
  const page = await browser();
  const socket = await page.authorize();
  page.submit();
  await settle();
  assert.equal(socket.sent.at(-1).action, 'input');
  assert.equal(socket.sent.at(-1).text, 'fixture input');
  socket.reply();
  await settle();
  assert.equal(page.element('message').value, '');
  await page.fireTimer(100);
  assert.deepEqual(socket.sent.map(request => request.action), ['state', 'input', 'key']);
  assert.equal(socket.sent.at(-1).text, 'enter');
  assert.equal(socket.sent.at(-1).tabID, 'tab-1');
  socket.reply();
  await settle();
  assert.equal(page.element('send').disabled, true); // Empty messages cannot be sent.
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
