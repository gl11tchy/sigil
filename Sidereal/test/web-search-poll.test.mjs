import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import vm from 'node:vm';
import { pairingDatabase, pairingIndexedDB } from './support/pairing-idb.mjs';
import { readableOutput, createReadableOutput, commonPrefixLength } from '../public/output.mjs';
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
      id, value: '', textContent: '', hidden: false, disabled: false, readOnly: false, dataset: {}, style: {},
      open: false, focus() {}, contains() { return false; },
      getAttribute(name) { return this[name]; }, setAttribute(name, value) { this[name] = value; },
      listeners: {}, addEventListener(type, listener) { (this.listeners[type] ??= []).push(listener); },
      showModal() { this.open = true; }, close() {
        if (!this.open) return;
        this.open = false;
        for (const listener of this.listeners.close || []) listener();
      },
      scrollHeight: 0, scrollTop: 0, clientHeight: 0,
      querySelector(selector) { return element(`${id}-${selector}`); },
      // A fragment hands over its nodes, and the text is the text of the new children.
      replaceChildren(...children) {
        this.children = children.flatMap(child => child.parts ?? [child]);
        this.textContent = this.children.map(child => child.textContent).join('');
      },
    });
    return elements.get(id);
  };
  const document = {
    hidden: false, getElementById: element,
    createDocumentFragment: () => ({ parts: [], append(node) { this.parts.push(node); } }),
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
      ['new', 'tabs', 'message', 'send', 'paste', 'interrupt', 'stop'].map(element),
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
        challenge: request.challenge, clientNonce: request.clientNonce, sequence: request.sequence, ok: true, ...fields, ...(state ? { state } : {}),
      }) });
    }
    close() { this.readyState = 3; this.onclose?.(); }
  }
  const indexedDB = pairingIndexedDB(pairingDatabase(stored));
  const app = {
    commonPrefixLength,
    createReadableOutput: () => {
      const reader = createReadableOutput();
      return { reset: () => reader.reset(), update: (text, options) => { formatted.push(text); return reader.update(text, options); } };
    },
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

test('opening Chats requests and displays recent saved conversations before typing', async () => {
  const page = await browser();
  const socket = await page.authorize();
  page.element('sessions-toggle').onclick();
  await settle();
  assert.deepEqual(searches(socket).map(request => request.text), ['']);
  socket.answer(searches(socket)[0], { chats: [{ id: 'recent-1', title: 'Yesterday’s work', folder: '/tmp/fixture' }] });
  await settle();
  assert.equal(page.element('saved-heading').textContent, 'Recent chats');
  assert.equal(page.element('saved-heading').hidden, false);
  assert.deepEqual(page.element('saved-list').children.map(row => row.children[0].textContent), ['Yesterday’s work']);
});

const savedRow = (id, fields = {}) => ({ id: String(id), title: `Saved ${id}`, folder: '/tmp/fixture', provider: 'grokBuild', ...fields });
const savedRows = page => page.element('saved-list').children.filter(row => row.dataset.more !== 'true');
const moreRow = page => page.element('saved-list').children.find(row => row.dataset.more === 'true');
async function query(page, text) {
  page.element('session-search').value = text;
  page.element('session-search').oninput();
  await settle();
}
async function recentPage({ paging = true, mac = 'mac-a' } = {}) {
  const page = await browser();
  const state = { tabs: [tab('tab-1')], selectedTabID: 'tab-1', terminal: 'READY', mac, capabilities: paging ? ['sessionOps'] : [] };
  const socket = await page.authorize(state);
  page.element('sessions-toggle').onclick();
  await settle();
  const answer = async (fields, request = searches(socket).at(-1), nextState = state) => {
    socket.answer(request, fields, nextState); await settle();
  };
  return { page, socket, state, answer };
}

test('recents, search, and clearing the query replace each other without publishing late rows', async () => {
  const { page, socket, answer } = await recentPage();
  const recent = searches(socket)[0];
  await page.type('alpha');
  await answer({ chats: [savedRow('old-recent')] }, recent);
  assert.equal(savedRows(page).length, 0);
  assert.equal(searches(socket).at(-1).text, 'alpha');
  await answer({ chats: [savedRow('match')] });
  assert.equal(page.element('saved-heading').textContent, 'Saved chats');
  assert.equal(savedRows(page)[0].children[0].textContent, 'Saved match');
  page.element('session-search').value = '   ';
  page.element('session-search').oninput(); await settle();
  assert.equal(searches(socket).at(-1).text, '');
  await answer({ chats: [savedRow('new-recent')] });
  assert.equal(page.element('saved-heading').textContent, 'Recent chats');
  assert.equal(savedRows(page)[0].children[0].textContent, 'Saved new-recent');
});

test('paging consumes partial and duplicate rows, deduplicates provider/folder/id, and opens the exact row', async () => {
  const { page, socket, answer } = await recentPage();
  await answer({ chats: [savedRow('same'), savedRow('same', { folder: '/tmp/other' })], chatsTruncated: true });
  const oldMore = moreRow(page);
  oldMore.onclick(); oldMore.onclick(); await settle();
  assert.equal(searches(socket).length, 2);
  assert.equal(searches(socket).at(-1).index, 2);
  await answer({ chats: [savedRow('same', { title: 'Renamed' }), savedRow('same', { provider: 'claudeCode' })], chatsTruncated: true });
  assert.equal(savedRows(page).length, 3);
  assert.equal(savedRows(page)[0].children[0].textContent, 'Renamed');
  moreRow(page).onclick(); await settle();
  assert.equal(searches(socket).at(-1).index, 4);
  await answer({ chats: [] });
  assert.equal(moreRow(page), undefined);
  savedRows(page)[2].onclick(); await settle();
  assert.equal(socket.sent.at(-1).action, 'open');
  assert.equal(socket.sent.at(-1).name, 'same');
  assert.equal(socket.sent.at(-1).text, '/tmp/fixture');
  assert.equal(socket.sent.at(-1).provider, 'claudeCode');
});

test('a changed query replaces a waiting page index in the existing coalescing queue', async () => {
  const { page, socket, answer } = await recentPage();
  await answer({ chats: Array.from({ length: 40 }, (_, i) => savedRow(i)) });
  page.element('interrupt').onclick(); await settle();
  const key = socket.sent.at(-1);
  moreRow(page).onclick();
  await page.type('new');
  await answer({}, key);
  const next = searches(socket).at(-1);
  assert.equal(next.text, 'new');
  assert.equal(next.index, undefined);
  await answer({ chats: [savedRow('result')] });
  assert.equal(savedRows(page).length, 1);
});

test('closing and reopening a sheet rejects its old page and old row actions', async () => {
  const { page, socket, answer } = await recentPage();
  await answer({ chats: Array.from({ length: 40 }, (_, i) => savedRow(i)) });
  const oldRow = savedRows(page)[0];
  moreRow(page).onclick(); await settle();
  const oldPage = searches(socket).at(-1);
  closeSheet(page);
  page.element('sessions-toggle').onclick(); await settle();
  const before = socket.sent.length; oldRow.onclick(); await settle(); assert.equal(socket.sent.length, before);
  await answer({ chats: [savedRow('late')] }, oldPage);
  assert.equal(savedRows(page).length, 0);
  assert.equal(searches(socket).at(-1).index, undefined);
  await answer({ chats: [savedRow('fresh')] });
  assert.equal(savedRows(page)[0].children[0].textContent, 'Saved fresh');
});

test('a Mac identity change clears rows and rejects the old Mac response before a fresh read', async () => {
  const { page, socket, state, answer } = await recentPage();
  await answer({ chats: [savedRow('old-mac')] }, searches(socket)[0], { ...state, mac: 'mac-b' });
  assert.equal(savedRows(page).length, 0);
  assert.equal(searches(socket).length, 2);
  await answer({ chats: [savedRow('new-mac')] }, searches(socket).at(-1), { ...state, mac: 'mac-b' });
  assert.equal(savedRows(page)[0].children[0].textContent, 'Saved new-mac');
});

test('a saved open queued behind a command is discarded after query, sheet, or Mac changes', async () => {
  for (const change of ['query', 'sheet', 'mac']) {
    const { page, socket, state, answer } = await recentPage();
    await answer({ chats: [savedRow('old-target')] });
    page.element('interrupt').onclick(); await settle();
    const command = socket.sent.at(-1);
    savedRows(page)[0].onclick(); await settle();
    if (change === 'query') await query(page, 'different');
    if (change === 'sheet') closeSheet(page);
    await answer({}, command, change === 'mac' ? { ...state, mac: 'mac-b' } : state);
    assert.equal(socket.sent.some(request => request.action === 'open'), false, change);
    assert.equal(page.element('message').readOnly, false, change);
  }
});

test('disconnecting clears rows, suppresses the old request error, and refreshes on reconnect', async () => {
  const { page, socket, state, answer } = await recentPage();
  await answer({ chats: Array.from({ length: 40 }, (_, i) => savedRow(i)) });
  moreRow(page).onclick(); await settle();
  socket.close(); await settle();
  assert.equal(savedRows(page).length, 0);
  assert.equal(page.element('sessions-error').hidden, true);
  await page.fireTimer(500);
  const next = await page.authorize(state); await settle();
  assert.equal(searches(next).length, 1);
  next.answer(searches(next)[0], { chats: [savedRow('reconnected')] }, state); await settle();
  assert.equal(savedRows(page)[0].children[0].textContent, 'Saved reconnected');
});

test('a page return refresh reloads the open saved list after discarding an in-flight read', async () => {
  const { page, socket, answer } = await recentPage();
  const oldRead = searches(socket)[0];
  page.app.document.hidden = true; page.app.pausePage();
  page.app.document.hidden = false; page.app.resumePage();
  await settle();
  await answer({ chats: [savedRow('old-before-return')] }, oldRead);
  assert.equal(savedRows(page).length, 0);
  const freshState = socket.sent.at(-1);
  assert.equal(freshState.action, 'state');
  await answer({}, freshState);
  assert.equal(searches(socket).length, 2);
  await answer({ chats: [savedRow('after-return')] });
  assert.equal(savedRows(page)[0].children[0].textContent, 'Saved after-return');
  assert.equal(page.element('saved-list')['aria-busy'], 'false');
});

test('Unknown action hides the saved section quietly, while a real failure stays visible', async () => {
  const { page, socket, state, answer } = await recentPage();
  await answer({ ok: false, error: 'Unknown action.' });
  assert.equal(page.element('saved-heading').hidden, true);
  assert.equal(page.element('saved-empty').hidden, true);
  assert.equal(page.element('sessions-error').hidden, true);
  await query(page, 'search');
  await answer({ ok: false, error: 'Could not read chats.' });
  assert.equal(page.element('sessions-error').textContent, 'Could not read chats.');
  assert.equal(page.element('sessions-error').hidden, false);
  await query(page, 'recovery');
  await answer({ chats: [] });
  assert.equal(page.element('sessions-error').hidden, true);
});

test('an empty recent list and an empty search have distinct truthful messages', async () => {
  const { page, answer } = await recentPage();
  await answer({ chats: [] });
  assert.equal(page.element('saved-empty').textContent, 'No recent chats.');
  assert.equal(page.element('saved-empty').hidden, false);
  await query(page, 'missing'); await answer({ chats: [] });
  assert.equal(page.element('saved-empty').textContent, 'No matching chats.');
  assert.equal(page.element('saved-empty').hidden, false);
});

test('old hosts without sessionOps expose one bounded page, and index-ignoring hosts stop on repetition', async () => {
  const old = await recentPage({ paging: false });
  const rows = Array.from({ length: 80 }, (_, i) => savedRow(i));
  await old.answer({ chats: rows });
  assert.equal(savedRows(old.page).length, 40);
  assert.equal(moreRow(old.page), undefined);
  const current = await recentPage();
  await current.answer({ chats: rows.slice(0, 40) });
  moreRow(current.page).onclick(); await settle();
  await current.answer({ chats: rows.slice(0, 40) });
  assert.equal(savedRows(current.page).length, 40);
  assert.equal(moreRow(current.page), undefined);
  assert.equal(searches(current.socket).length, 2);
});

test('manual paging is bounded to 400 consumed rows and never loops automatically', async () => {
  const { page, socket, answer } = await recentPage();
  for (let offset = 0; offset < 400; offset += 40) {
    assert.equal(searches(socket).at(-1).index ?? 0, offset);
    await answer({ chats: Array.from({ length: 40 }, (_, i) => savedRow(offset + i)) });
    if (offset < 360) { moreRow(page).onclick(); await settle(); }
  }
  assert.equal(savedRows(page).length, 400);
  assert.equal(searches(socket).length, 10);
  assert.equal(moreRow(page), undefined);
  assert.match(page.element('saved-empty').textContent, /Search to narrow/);
});

test('malformed rows and incomplete lists cannot impersonate an empty recent list', async () => {
  const { page, answer } = await recentPage();
  await answer({ chats: undefined });
  assert.match(page.element('saved-empty').textContent, /unavailable/);
  await query(page, 'truncated');
  await answer({ chats: [], chatsTruncated: true });
  assert.match(page.element('saved-empty').textContent, /unavailable/);
  await query(page, 'invalid');
  await answer({ chats: [null, savedRow('bad', { provider: {} })] });
  assert.match(page.element('saved-empty').textContent, /unavailable/);
  await query(page, 'safe');
  await answer({ chats: [null, savedRow('bad', { provider: {} }), savedRow('good')] });
  assert.equal(savedRows(page).length, 1);
  assert.equal(savedRows(page)[0].children[0].textContent, 'Saved good');
});

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

test('a select issued after typing waits only for the search out and the newest one', async () => {
  const page = await browser();
  const socket = await page.authorize({ tabs: [tab('tab-1'), tab('tab-2', 'Other')], selectedTabID: 'tab-1', terminal: 'READY' });
  page.element('sessions-toggle').onclick();
  await page.type('alphaworkflow');
  page.element('tabs').value = 'tab-2';
  page.element('tabs').onchange();
  await settle();
  for (let reply = 0; reply < 3; reply++) {
    socket.answer(socket.sent.at(-1), socket.sent.at(-1).action === 'chats' ? chats(socket.sent.at(-1).text) : {},
      { tabs: [tab('tab-1'), tab('tab-2', 'Other')], selectedTabID: socket.sent.at(-1).action === 'select' ? 'tab-2' : 'tab-1', terminal: 'READY' });
    await settle();
  }
  // Keys wait for the switch to end; then one goes out at once.
  page.element('interrupt').onclick();
  await settle();
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

// Close the Chats sheet as the browser does: close(), then the close event.
function closeSheet(page) {
  page.element('sessions-close').onclick();
}

test('clearing the search replaces the waiting query with recents before the next selection', async () => {
  const page = await browser();
  const socket = await page.authorize({ tabs: [tab('tab-1'), tab('tab-2', 'Other')], selectedTabID: 'tab-1', terminal: 'READY' });
  socket.sent[0].answered = true;
  page.element('sessions-toggle').onclick();
  await page.type('alphaw');
  assert.deepEqual(searches(socket).map(request => request.text), ['a']);
  page.element('session-search').value = '';
  page.element('session-search').oninput();
  page.element('session-list').children.find(row => row.dataset.tabId === 'tab-2').onclick();
  await drain(socket);
  assert.deepEqual(socket.sent.map(request => [request.action, request.text ?? request.tabID]),
    [['state', undefined], ['chats', 'a'], ['chats', ''], ['select', 'tab-2']]);
  assert.deepEqual(page.element('saved-list').children, []);
  assert.equal(page.element('error').hidden, true);
});

test('closing the sheet drops the waiting query and shows nothing for it', async () => {
  const page = await browser();
  const socket = await page.authorize();
  socket.sent[0].answered = true;
  page.element('sessions-toggle').onclick();
  await page.type('alphaw');
  closeSheet(page);
  page.element('interrupt').onclick();
  await drain(socket);
  assert.deepEqual(socket.sent.map(request => [request.action, request.text]),
    [['state', undefined], ['chats', 'a'], ['key', 'interrupt']]);
  assert.equal(page.element('saved-empty').hidden, true);
  assert.deepEqual(page.element('saved-list').children, []);
  assert.equal(page.element('error').hidden, true);
});

test('reopening the sheet replaces the obsolete query with recents before the next selection', async () => {
  const page = await browser();
  const socket = await page.authorize({ tabs: [tab('tab-1'), tab('tab-2', 'Other')], selectedTabID: 'tab-1', terminal: 'READY' });
  socket.sent[0].answered = true;
  page.element('sessions-toggle').onclick();
  await page.type('alphaw');
  closeSheet(page);
  page.element('sessions-toggle').onclick();
  page.element('session-list').children.find(row => row.dataset.tabId === 'tab-2').onclick();
  await drain(socket);
  assert.deepEqual(socket.sent.map(request => [request.action, request.text ?? request.tabID]),
    [['state', undefined], ['chats', 'a'], ['chats', ''], ['select', 'tab-2']]);
  assert.deepEqual(page.element('saved-list').children, []);
  assert.equal(page.element('error').hidden, true);
});

test('a new handshake discards the old query and refreshes the open sheet under its new challenge', async () => {
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
  assert.deepEqual(searches(socket).map(request => request.text), ['a', 'ab']);
  assert.equal(searches(socket).at(-1).challenge, 'd'.repeat(64));
  socket.answer(searches(socket).at(-1), chats('ab'));
  await settle();
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

test('unchanged polls neither format the output again nor rebuild the session picker', async () => {
  const page = await browser();
  const socket = await page.authorize();
  const options = page.element('tabs').children;
  assert.deepEqual(page.formatted, ['READY']);
  page.formatted.length = 0;
  page.created.length = 0;
  for (let poll = 0; poll < 5; poll++) {
    await page.fireTimer(1000);
    assert.equal(socket.sent.at(-1).action, 'state');
    socket.answer(socket.sent.at(-1));
    await settle();
  }
  assert.equal(socket.sent.filter(request => request.action === 'state').length, 6);
  assert.deepEqual(page.formatted, []);
  assert.deepEqual(page.created, []);
  assert.equal(page.element('tabs').children, options);
  assert.equal(page.element('terminal').textContent, readableOutput('READY'));
  assert.equal(page.element('session-status').textContent, 'Ready');
});

test('changed text, status, tabs, mode and earlier history show exactly what a fresh format shows', async () => {
  const page = await browser();
  const socket = await page.authorize();
  const terminal = page.element('terminal');
  const poll = async (state, fields = {}) => {
    page.formatted.length = 0;
    page.created.length = 0;
    await page.fireTimer(1000);
    socket.answer(socket.sent.at(-1), fields, state);
    await settle();
  };
  const grown = 'READY\n│ ❯ fix the widget │\nDone.';
  await poll({ tabs: [tab('tab-1')], selectedTabID: 'tab-1', terminal: grown });
  assert.deepEqual(page.formatted, [grown]);
  assert.deepEqual(page.created, []);
  assert.equal(terminal.textContent, readableOutput(grown));
  // Status alone rebuilds the picker but not the output.
  await poll({ tabs: [tab('tab-1', 'Fixture', 'exited')], selectedTabID: 'tab-1', terminal: grown });
  assert.deepEqual(page.formatted, []);
  assert.deepEqual(page.created, ['option']);
  assert.equal(page.element('tabs').children[0].textContent, 'Fixture · Ended');
  assert.equal(page.element('session-status').textContent, 'Session ended');
  assert.equal(terminal.textContent, readableOutput(grown));
  // Raw mode shows the text itself, and readable mode returns without formatting again.
  page.formatted.length = 0;
  page.element('raw-toggle').onclick();
  assert.equal(terminal.textContent, grown);
  page.element('raw-toggle').onclick();
  assert.equal(terminal.textContent, readableOutput(grown));
  assert.deepEqual(page.formatted, []);
  // Text that changes while raw is showing is formatted when readable returns.
  page.element('raw-toggle').onclick();
  const later = `${grown}\nMore.`;
  await poll({ tabs: [tab('tab-1', 'Fixture', 'exited')], selectedTabID: 'tab-1', terminal: later });
  assert.deepEqual(page.formatted, []);
  assert.equal(terminal.textContent, later);
  page.element('raw-toggle').onclick();
  assert.deepEqual(page.formatted, [later]);
  assert.equal(terminal.textContent, readableOutput(later));
  // A new tab rebuilds the picker; switching to it formats its own text once.
  await poll({ tabs: [tab('tab-1', 'Fixture', 'exited'), tab('tab-2', 'Other')], selectedTabID: 'tab-2', terminal: 'SECOND' });
  assert.deepEqual(page.formatted, ['SECOND']);
  assert.deepEqual(page.created, ['option', 'option']);
  assert.deepEqual(page.element('tabs').children.map(option => option.value), ['tab-1', 'tab-2']);
  assert.equal(page.element('tabs').value, 'tab-2');
  assert.equal(terminal.textContent, readableOutput('SECOND'));
  // Earlier history changes the text above the same tail.
  terminal.scrollHeight = 800;
  terminal.clientHeight = 200;
  terminal.scrollTop = 0;
  terminal.onscroll();
  await settle();
  const request = socket.sent.at(-1);
  assert.equal(request.action, 'earlier');
  page.formatted.length = 0;
  socket.answer(request, { earlier: 'EARLY\n' },
    { tabs: [tab('tab-1', 'Fixture', 'exited'), tab('tab-2', 'Other')], selectedTabID: 'tab-2', terminal: 'SECOND' });
  await settle();
  assert.deepEqual(page.formatted, ['EARLY\nSECOND']);
  assert.equal(terminal.textContent, readableOutput('EARLY\nSECOND'));
});
