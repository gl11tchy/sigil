import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import vm from 'node:vm';
import { readableOutput } from '../public/output.mjs';
import { pairingFromText } from '../public/pairing.mjs';

// Saved search coalescing and unchanged-poll reuse (browser audit B2 and B4).
const source = (await readFile(new URL('../public/app.mjs', import.meta.url), 'utf8'))
  .replace(/^import .* from '\.\/.*\.mjs';\n/gm, '');
const settle = () => new Promise(resolve => setImmediate(resolve));
const tab = (id, title = 'Fixture', status = 'idle') => ({ id, title, status });

// Run the real handlers; only browser services and encryption are replaced.
// The page counts formatter calls and created elements so tests can see repeated work.
async function browser() {
  const elements = new Map(), timers = new Map(), sockets = [], created = [], formatted = [];
  let nextTimer = 0;
  const stored = { room: 'a'.repeat(32), key: { device: true } };
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
  const document = {
    hidden: false, getElementById: element,
    createDocumentFragment: () => ({ append(node) { this.parts = [...(this.parts || []), node]; } }),
    createTextNode: text => ({ textContent: text }),
    createElement: tag => {
      created.push(tag);
      return {
        tag, textContent: '', dataset: {}, hidden: false, children: [],
        append(...nodes) { this.children.push(...nodes); },
        setAttribute(name, value) { this[name] = value; },
        focus() {}, scrollIntoView() {},
      };
    },
    querySelectorAll: selector => selector === '[data-key]' ? [] :
      ['new', 'tabs', 'message', 'send', 'paste', 'interrupt'].map(element),
    addEventListener() {},
  };
  class FakeSocket {
    static OPEN = 1;
    readyState = 1;
    sent = [];
    constructor(url) { this.url = url; sockets.push(this); }
    send(frame) {
      const value = JSON.parse(frame);
      if (!value.route) this.sent.push(JSON.parse(value.data));
    }
    receive(frame) { this.onmessage({ data: JSON.stringify(frame) }); }
    answer(request, fields = {}, state = { tabs: [tab('tab-1')], selectedTabID: 'tab-1', terminal: 'READY' }) {
      this.receive({ data: JSON.stringify({
        challenge: request.challenge, sequence: request.sequence, ok: true, ...fields, ...(state ? { state } : {}),
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
              objectStore: () => ({ get: () => ({ result: structuredClone(stored) }), put: () => ({}), delete: () => ({}) }),
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
    readableOutput: text => { formatted.push(text); return readableOutput(text); },
    pairingFromText, document, location: { origin: 'https://sidereal.example', protocol: 'https:', pathname: '/', hash: '' },
    history: { replaceState() {} }, indexedDB,
    window: { addEventListener() {} },
    navigator: {}, crypto: { subtle: {} }, URL, URLSearchParams, TextEncoder,
    WebSocket: FakeSocket,
    importKey: async hex => ({ hex }), randomKey: () => 'e'.repeat(64),
    seal: async value => JSON.stringify(value),
    open: async frame => JSON.parse(frame),
    setTimeout(callback, delay) { const id = ++nextTimer; timers.set(id, { callback, delay }); return id; },
    clearTimeout: id => timers.delete(id),
  };
  vm.runInNewContext(source, app);
  await settle();
  async function authorize(state) {
    const ws = sockets.at(-1);
    ws.receive({ hello: 'b'.repeat(64) });
    await settle();
    assert.equal(ws.sent.at(-1).action, 'state');
    ws.answer(ws.sent.at(-1), {}, state);
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
  // Each keystroke fires input with the field's new value, as the browser does.
  async function type(text, { from = '' } = {}) {
    for (const ch of text) {
      from += ch;
      element('session-search').value = from;
      element('session-search').oninput();
      await settle();
    }
  }
  return { app, element, sockets, authorize, fireTimer, type, created, formatted };
}
const searches = socket => socket.sent.filter(request => request.action === 'chats');
const chats = query => ({ chats: [{ id: `chat-${query}`, title: `${query} result`, folder: '/work' }] });

test('typing faster than the Mac answers sends a bounded number of searches and shows only the last', async () => {
  const page = await browser();
  const socket = await page.authorize();
  const shown = [];
  const list = page.element('saved-list');
  list.replaceChildren = (...children) => {
    list.children = children;
    shown.push(...children.map(row => row.children[0].textContent));
  };
  page.element('sessions-toggle').onclick();
  // The first key goes straight out; the next five wait behind it as one search.
  await page.type('alphaw');
  assert.deepEqual(searches(socket).map(request => request.text), ['a']);
  socket.answer(searches(socket).at(-1), chats('a'));
  await settle();
  assert.deepEqual(searches(socket).map(request => request.text), ['a', 'alphaw']);
  // The other seven keys land while that one is out, and join a single waiting search.
  await page.type('orkflow', { from: 'alphaw' });
  assert.equal(searches(socket).length, 2);
  socket.answer(searches(socket).at(-1), chats('alphaw'));
  await settle();
  assert.deepEqual(searches(socket).map(request => request.text), ['a', 'alphaw', 'alphaworkflow']);
  socket.answer(searches(socket).at(-1), chats('alphaworkflow'));
  await settle();
  assert.deepEqual(shown, ['alphaworkflow result']);
  assert.equal(page.element('saved-list').children.length, 1);
  assert.equal(page.element('saved-empty').hidden, true);
  assert.equal(page.element('error').hidden, true);
  // Coalescing never skips a sequence number or leaves the Mac's challenge.
  assert.deepEqual(socket.sent.map(request => request.sequence), socket.sent.map((_, index) => index + 1));
  assert.ok(socket.sent.every(request => request.challenge === 'b'.repeat(64)));
});

test('keys typed before the first reply leave one search waiting, sent with the final query', async () => {
  const page = await browser();
  const socket = await page.authorize();
  page.element('sessions-toggle').onclick();
  await page.type('alphaworkflow');
  assert.deepEqual(searches(socket).map(request => request.text), ['a']);
  socket.answer(searches(socket).at(-1), chats('a'));
  await settle();
  assert.equal(page.element('saved-list').children.length, 0);
  assert.deepEqual(searches(socket).map(request => request.text), ['a', 'alphaworkflow']);
  socket.answer(searches(socket).at(-1), chats('alphaworkflow'));
  await settle();
  assert.deepEqual(page.element('saved-list').children.map(row => row.children[0].textContent), ['alphaworkflow result']);
});

test('a select and a key issued after typing wait only for the search out and the newest one', async () => {
  const page = await browser();
  const socket = await page.authorize({ tabs: [tab('tab-1'), tab('tab-2', 'Other')], selectedTabID: 'tab-1', terminal: 'READY' });
  page.element('sessions-toggle').onclick();
  await page.type('alphaworkflow');
  page.element('tabs').value = 'tab-2';
  page.element('tabs').onchange();
  page.element('interrupt').onclick();
  await settle();
  for (let reply = 0; reply < 3; reply++) {
    socket.answer(socket.sent.at(-1), socket.sent.at(-1).action === 'chats' ? chats(socket.sent.at(-1).text) : {},
      { tabs: [tab('tab-1'), tab('tab-2', 'Other')], selectedTabID: socket.sent.at(-1).action === 'select' ? 'tab-2' : 'tab-1', terminal: 'READY' });
    await settle();
  }
  assert.deepEqual(socket.sent.map(request => [request.action, request.text ?? request.tabID]),
    [['state', undefined], ['chats', 'a'], ['chats', 'alphaworkflow'], ['select', 'tab-2'], ['key', 'interrupt']]);
});

// Answer whatever is out until nothing new is sent.
async function drain(socket) {
  for (let turn = 0; turn < 20 && socket.sent.at(-1).answered !== true; turn++) {
    const request = socket.sent.at(-1);
    request.answered = true;
    socket.answer(request, request.action === 'chats' ? chats(request.text) : {});
    await settle();
  }
}

test('a search typed after a select does not hold the select behind an obsolete query', async () => {
  const page = await browser();
  const socket = await page.authorize({ tabs: [tab('tab-1'), tab('tab-2', 'Other')], selectedTabID: 'tab-1', terminal: 'READY' });
  socket.sent[0].answered = true;
  page.element('sessions-toggle').onclick();
  await page.type('alpha');
  page.element('tabs').value = 'tab-2';
  page.element('tabs').onchange();
  await page.type('workflow', { from: 'alpha' });
  await drain(socket);
  assert.deepEqual(socket.sent.map(request => [request.action, request.text ?? request.tabID]),
    [['state', undefined], ['chats', 'a'], ['select', 'tab-2'], ['chats', 'alphaworkflow']]);
  assert.deepEqual(page.element('saved-list').children.map(row => row.children[0].textContent), ['alphaworkflow result']);
});

test('keys queued between searches keep their order and are never dropped', async () => {
  const page = await browser();
  const socket = await page.authorize();
  socket.sent[0].answered = true;
  page.element('sessions-toggle').onclick();
  await page.type('a');
  page.element('interrupt').onclick();
  await page.type('bc', { from: 'a' });
  page.element('interrupt').onclick();
  await page.type('d', { from: 'abc' });
  await drain(socket);
  // "abc" was obsolete before its turn, so it never reached the Mac; both keys did, in order.
  assert.deepEqual(socket.sent.map(request => [request.action, request.text]),
    [['state', undefined], ['chats', 'a'], ['key', 'interrupt'], ['key', 'interrupt'], ['chats', 'abcd']]);
  assert.deepEqual(page.element('saved-list').children.map(row => row.children[0].textContent), ['abcd result']);
  assert.equal(page.element('error').hidden, true);
});

test('a search waiting through a new handshake is not sent, and the next one starts fresh', async () => {
  const page = await browser();
  const socket = await page.authorize();
  page.element('sessions-toggle').onclick();
  await page.type('ab');
  assert.deepEqual(searches(socket).map(request => request.text), ['a']);
  socket.receive({ hello: 'd'.repeat(64) });
  await settle();
  assert.equal(socket.sent.at(-1).action, 'state');
  assert.equal(socket.sent.at(-1).challenge, 'd'.repeat(64));
  assert.equal(socket.sent.at(-1).sequence, 1);
  socket.answer(socket.sent.at(-1));
  await settle();
  assert.equal(page.element('status').textContent, 'Connected');
  assert.deepEqual(searches(socket).map(request => request.text), ['a']);
  await page.type('c', { from: 'ab' });
  const next = searches(socket).at(-1);
  assert.equal(next.text, 'abc');
  assert.equal(next.challenge, 'd'.repeat(64));
  socket.answer(next, chats('abc'));
  await settle();
  assert.deepEqual(page.element('saved-list').children.map(row => row.children[0].textContent), ['abc result']);
});

test('a coalesced search still trims an oversized query to what the Mac reads', async () => {
  const page = await browser();
  const socket = await page.authorize();
  page.element('sessions-toggle').onclick();
  await page.type('xy');
  page.element('session-search').value = `${'😀'.repeat(150)}${'x'.repeat(9000)}`;
  page.element('session-search').oninput();
  await settle();
  socket.answer(searches(socket).at(-1), chats('x'));
  await settle();
  const sent = searches(socket).at(-1);
  assert.equal(searches(socket).length, 2);
  assert.equal([...sent.text].length, 200);
  assert.ok(sent.text.startsWith('😀'.repeat(150)));
  assert.ok(new TextEncoder().encode(sent.text).length <= 8192);
  assert.equal(socket.readyState, 1);
});
