import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import vm from 'node:vm';
import { createReadableOutput, commonPrefixLength } from '../public/output.mjs';
import { pairingFromText } from '../public/pairing.mjs';

const source = (await readFile(new URL('../public/app.mjs', import.meta.url), 'utf8'))
  .replace(/^import .* from '\.\/.*\.mjs';\n/gm, '');
const settle = () => new Promise(resolve => setImmediate(resolve));
// Answers New's CLI list as a Mac from before the choice does.
async function skipOptions(socket) {
  const request = socket.sent.at(-1);
  assert.equal(request.action, 'options');
  socket.receive({ data: JSON.stringify({
    challenge: request.challenge, clientNonce: request.clientNonce, sequence: request.sequence, ok: false, error: 'Unknown action.' }) });
  await settle();
}

// Run the real handlers; only browser services and encryption are replaced.
async function browser({ hash = '', saved = { room: 'a'.repeat(32), key: { device: true } }, faults = {} } = {}) {
  const elements = new Map(), events = new Map(), timers = new Map(), sockets = [];
  let nextTimer = 0, reloads = 0, randomCounter = 0;
  let stored = saved;
  const sealed = [];
  const element = id => {
    if (!elements.has(id)) elements.set(id, {
      id, value: '', textContent: '', hidden: false, disabled: false, readOnly: false, dataset: {}, style: {},
      open: false, focus() {}, contains() { return false; },
      getAttribute(name) { return this[name]; }, setAttribute(name, value) { this[name] = value; },
      addEventListener() {},
      showModal() { this.open = true; }, close() { this.open = false; },
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
  const location = {
    origin: 'https://sidereal.example', protocol: 'https:', pathname: '/', hash,
    reload() { reloads++; },
  };
  const document = {
    hidden: false, getElementById: element,
    createDocumentFragment: () => ({ parts: [], append(node) { this.parts.push(node); } }),
    createTextNode: text => ({ textContent: text }),
    createElement: () => ({
      textContent: '', dataset: {}, hidden: false, children: [],
      append(...nodes) { this.children.push(...nodes); },
      setAttribute(name, value) { this[name] = value; },
      focus() {}, scrollIntoView() {},
    }),
    querySelectorAll: selector => selector === '[data-key]' ? [] :
      ['new', 'tabs', 'message', 'send', 'paste', 'interrupt', 'stop'].map(element),
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
        challenge: request.challenge, clientNonce: request.clientNonce, sequence: request.sequence, ok: true,
        state: { tabs: [{ id: 'tab-1', title: 'Fixture', status: 'idle', provider: 'grokBuild', sessionID: 'native-fixture', cwd: '/tmp/fixture' }], selectedTabID: 'tab-1', terminal: 'READY' },
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
                put: value => { if (faults.storage) throw new Error('Storage unavailable'); stored = structuredClone(value); return {}; },
                delete: () => { stored = undefined; return {}; },
              }),
            };
            queueMicrotask(() => {
              if (faults.holdCompletion) faults.pending.push(transaction);
              else transaction.oncomplete?.();
            });
            return transaction;
          },
        };
        request.onsuccess();
      });
      return request;
    },
  };
  const app = {
    createReadableOutput, commonPrefixLength, pairingFromText, document, location, history: { replaceState() {} }, indexedDB,
    window: { addEventListener: (name, callback) => events.set(name, callback) },
    navigator: {}, crypto: { subtle: {} }, URL, URLSearchParams, TextEncoder,
    WebSocket: FakeSocket,
    importKey: async hex => ({ hex }), randomKey: () => ++randomCounter === 1 ? 'e'.repeat(64) : randomCounter.toString(16).padStart(64, '0'),
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

test('streamed output that overlaps each poll keeps history under the cap', async () => {
  const { app } = await browser();
  const bucket = { history: '', tail: '', exhausted: false };
  const line = n => `line ${String(n).padStart(6, '0')} ${'x'.repeat(1000)}\n`;
  const window = start => Array.from({ length: 40 }, (_, i) => line(start + i)).join('');
  // Each poll scrolls 20 lines, and the old and new snapshots share the other 20.
  for (let start = 0; start <= 20 * 30; start += 20) app.applyTail(bucket, window(start));
  assert.ok(bucket.history.length <= 400_000, `history is ${bucket.history.length} characters`);
  assert.ok((bucket.history + bucket.tail).endsWith(window(600)));
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

test('an 8 KB message with an attachment is refused before anything is sent', async () => {
  const page = await browser();
  const socket = await page.authorize();
  page.element('attach').files = [{ name: 'notes.txt', type: 'text/plain', size: 5 }];
  page.element('attach').onchange();
  page.element('message').value = 'a'.repeat(8192);
  page.element('compose').onsubmit({ preventDefault() {} });
  await settle();
  assert.match(page.element('error').textContent, /under 8 KB/);
  assert.deepEqual(socket.sent.map(request => request.action), ['state']);
});

test('picking more than 16 files says the rest were not added', async () => {
  const page = await browser();
  await page.authorize();
  page.element('attach').files = Array.from({ length: 20 }, (_, index) => ({ name: `note${index}.txt`, type: 'text/plain', size: 5 }));
  page.element('attach').onchange();
  assert.equal(page.app.attachmentsFor().length, 16);
  assert.match(page.element('error').textContent, /Up to 16 files per message/);
});

test('an oversized file keeps its own error and does not use a free slot', async () => {
  const page = await browser();
  await page.authorize();
  page.element('attach').files = Array.from({ length: 15 }, (_, index) => ({ name: `note${index}.txt`, type: 'text/plain', size: 5 }));
  page.element('attach').onchange();
  page.element('attach').files = [
    { name: 'big.zip', type: 'application/zip', size: 5 * 1024 * 1024 },
    { name: 'last.txt', type: 'text/plain', size: 5 },
  ];
  page.element('attach').onchange();
  assert.equal(page.app.attachmentsFor().length, 16);
  assert.equal(page.element('error').textContent, 'Keep files under 4 MB.');
});

test('a sent attachment leaves the queue when the Mac switches tabs during the send', async () => {
  const page = await browser();
  page.app.btoa = btoa;
  const socket = await page.authorize();
  const both = selectedTabID => ({ tabs: [
    { id: 'tab-1', title: 'One', status: 'idle' }, { id: 'tab-2', title: 'Two', status: 'idle' }],
    selectedTabID, terminal: 'READY' });
  const answer = (request, state) => socket.receive({ data: JSON.stringify({
    challenge: request.challenge, clientNonce: request.clientNonce, sequence: request.sequence, ok: true, state }) });
  page.element('attach').files = [{ name: 'notes.txt', type: 'text/plain', size: 5,
    arrayBuffer: async () => new Uint8Array([1, 2, 3, 4, 5]).buffer }];
  page.element('attach').onchange();
  page.element('message').value = 'look';
  page.element('compose').onsubmit({ preventDefault() {} });
  await settle(); await settle();
  const file = socket.sent.at(-1);
  assert.equal(file.action, 'file');
  assert.equal(file.tabID, 'tab-1');
  answer(file, both('tab-2'));
  await settle(); await settle();
  answer(socket.sent.at(-1), both('tab-2'));
  await settle();
  await page.fireTimer(100);
  answer(socket.sent.at(-1), both('tab-2'));
  await settle();
  assert.deepEqual(socket.sent.map(request => request.action), ['state', 'file', 'input', 'key']);
  await page.fireTimer(1000);
  answer(socket.sent.at(-1), both('tab-1'));
  await settle();
  assert.equal(page.element('attachments').hidden, true);
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
    challenge: enter.challenge, clientNonce: enter.clientNonce, sequence: enter.sequence, ok: false, error: 'Refused.' }) });
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
  socket.receive({ data: JSON.stringify({ challenge: input.challenge, clientNonce: input.clientNonce, sequence: input.sequence, ok: true,
    state: { tabs: [{ id: 'tab-1', title: 'One', status: 'idle' }, { id: 'tab-2', title: 'Two', status: 'idle' }],
      selectedTabID: 'tab-2', terminal: 'TWO' } }) });
  await settle();
  assert.equal(page.element('message').value, '');
  await page.fireTimer(100);
  const enter = socket.sent.at(-1);
  assert.equal(enter.action, 'key');
  assert.equal(enter.tabID, 'tab-1');
  socket.receive({ data: JSON.stringify({ challenge: enter.challenge, clientNonce: enter.clientNonce, sequence: enter.sequence, ok: true,
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
  socket.receive({ data: JSON.stringify({ challenge: request.challenge, clientNonce: request.clientNonce, sequence: request.sequence, ok: true,
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
  socket.receive({ data: JSON.stringify({ challenge: request.challenge, clientNonce: request.clientNonce, sequence: request.sequence, ok: true,
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
    challenge: projects.challenge, clientNonce: projects.clientNonce, sequence: projects.sequence, ok: false, error: 'Unknown action.' }) });
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
  // The restarted Mac joins again, so the relay brings a new handshake.
  socket.receive({ hello: 'd'.repeat(64) });
  await settle();
  const state = socket.sent.at(-1);
  assert.equal(state.action, 'state');
  socket.receive({ data: JSON.stringify({ challenge: state.challenge, clientNonce: state.clientNonce, sequence: state.sequence, ok: true,
    state: { tabs: [{ id: 'tab-9', title: 'Fixture', status: 'idle', provider: 'grokBuild', sessionID: 'native-fixture', cwd: '/tmp/fixture' }], selectedTabID: 'tab-9', terminal: 'READY' } }) });
  await settle();
  assert.equal(page.element('message').value, 'long message');
  assert.equal(page.element('attachments').children.length, 1);
});

test('a new session on the same Mac does not take the closed tab\'s draft', async () => {
  const page = await browser();
  const socket = await page.authorize();
  page.element('message').value = 'long message';
  page.element('attach').files = [{ name: 'notes.txt', type: 'text/plain', size: 5 }];
  page.element('attach').onchange();
  await page.fireTimer(1000);
  const poll = socket.sent.at(-1);
  assert.equal(poll.action, 'state');
  socket.receive({ data: JSON.stringify({ challenge: poll.challenge, clientNonce: poll.clientNonce, sequence: poll.sequence, ok: true,
    state: { tabs: [{ id: 'tab-9', title: 'Other', status: 'idle' }], selectedTabID: 'tab-9', terminal: 'READY' } }) });
  await settle();
  assert.equal(page.element('message').value, '');
  assert.equal(page.element('attachments').children.length, 0);
});

test('a command timeout closes the connection before later commands can run', async () => {
  const page = await browser();
  const socket = await page.authorize();
  page.element('new').onclick(); await settle();
  assert.equal(socket.sent.at(-1).action, 'projects');
  await page.fireTimer(10000);
  assert.equal(socket.readyState, 3);
  assert.equal(page.element('error').hidden, false);
  const count = socket.sent.length;
  page.element('new').onclick(); await settle();
  assert.equal(socket.sent.length, count);
  assert.notEqual(page.element('status').textContent, 'Connected');
});

test('a late reply after a command timeout cannot repaint a disconnected session', async () => {
  const page = await browser();
  const socket = await page.authorize();
  page.element('new').onclick(); await settle();
  const timedOut = socket.sent.at(-1);
  await page.fireTimer(10000);
  socket.receive({ data: JSON.stringify({
    challenge: timedOut.challenge, clientNonce: timedOut.clientNonce, sequence: timedOut.sequence, ok: true,
    state: { tabs: [{ id: 'tab-1', title: 'Late', status: 'idle' }], selectedTabID: 'tab-1', terminal: 'LATE' },
  }) });
  await settle();
  assert.equal(socket.readyState, 3);
  assert.notEqual(page.element('status').textContent, 'Connected');
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
  socket.receive({ data: JSON.stringify({ challenge: request.challenge, clientNonce: request.clientNonce, sequence: request.sequence, ok: true,
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
  socket.receive({ data: JSON.stringify({ challenge: request.challenge, clientNonce: request.clientNonce, sequence: request.sequence, ok: true,
    state: { tabs: [], selectedTabID: null, terminal: '' } }) });
  await settle();
  const placeholder = page.element('tabs').children[0];
  assert.equal(placeholder.value, '');
  assert.equal(placeholder.textContent, 'No open sessions');
  assert.equal(page.element('tabs').disabled, true);
  assert.equal(page.element('new').disabled, false);
  assert.equal(page.element('empty-output-h2').textContent, 'No open sessions.');
});

async function selectionFixture(entry = 'picker') {
  const page = await browser();
  const socket = await page.authorize();
  const tabs = [
    { id: 'tab-1', title: 'One', status: 'idle' }, { id: 'tab-2', title: 'Two', status: 'idle' },
  ];
  const state = selectedTabID => ({ tabs, selectedTabID, terminal: selectedTabID });
  page.element('message').value = 'First draft';
  page.app.render(state('tab-2')); page.element('message').value = 'Second draft';
  page.app.render(state('tab-1'));
  const select = () => {
    if (entry === 'picker') { page.element('tabs').value = 'tab-2'; page.element('tabs').onchange(); }
    else if (entry === 'browse') {
      page.element('sessions-dialog').open = true; page.app.renderSessionList();
      page.element('session-list').children[1].onclick();
    } else {
      page.element('sessions-dialog').open = true; page.element('session-search').value = 'Two';
      page.app.renderSaved([{ id: 'native-two', title: 'Two', folder: '/tmp/two' }]);
      page.element('saved-list').children[0].onclick();
    }
  };
  const reply = (request, selectedTabID, ws = socket) => ws.receive({ data: JSON.stringify({
    challenge: request.challenge, clientNonce: request.clientNonce, sequence: request.sequence, ok: true, state: state(selectedTabID),
  }) });
  return { page, socket, state, select, reply };
}

for (const entry of ['picker', 'browse', 'saved']) {
  test(`pending ${entry} selection makes the composer readonly without losing either draft`, async () => {
    const { page, socket, state, select, reply } = await selectionFixture(entry);
    select(); await settle();
    const request = socket.sent.at(-1);
    assert.equal(request.action, entry === 'saved' ? 'open' : 'select');
    assert.equal(page.element('message').readOnly, true);
    assert.equal(page.element('message').disabled, false);
    assert.equal(page.element('compose-status').textContent, 'Switching…');
    assert.equal(page.element('message').value, 'First draft');
    page.app.render(state('tab-1')); // An old state poll must not unlock the pending selection.
    assert.equal(page.element('message').readOnly, true);
    reply(request, 'tab-2'); await settle();
    assert.equal(page.element('message').readOnly, false);
    assert.equal(page.element('message').value, 'Second draft');
    page.app.render(state('tab-1'));
    assert.equal(page.element('message').value, 'First draft');
    assert.equal(socket.sent.some(r => ['input', 'key'].includes(r.action)), false);
  });

  test(`failed ${entry} selection restores an editable composer for the old target`, async () => {
    const { page, socket, select } = await selectionFixture(entry);
    select(); await settle();
    assert.equal(page.element('message').readOnly, true);
    const request = socket.sent.at(-1);
    socket.receive({ data: JSON.stringify({ challenge: request.challenge, clientNonce: request.clientNonce,
      sequence: request.sequence, ok: false, error: 'This tab is closed.' }) });
    await settle();
    assert.equal(page.element('message').readOnly, false);
    assert.equal(page.element('tabs').value, 'tab-1');
    assert.equal(page.element('message').value, 'First draft');
    assert.equal(page.element('send').disabled, false);
    assert.equal(socket.sent.some(r => ['input', 'key'].includes(r.action)), false);
  });
}

for (const end of ['disconnect', 'timeout']) {
  test(`selection ${end} restores the old target and never replays the selection`, async () => {
    const { page, socket, select, reply } = await selectionFixture();
    select(); await settle();
    assert.equal(page.element('message').readOnly, true);
    const oldRequest = socket.sent.at(-1);
    if (end === 'disconnect') socket.close(); else await page.fireTimer(10000);
    await settle();
    assert.equal(page.element('message').readOnly, false);
    assert.equal(page.element('message').disabled, false);
    assert.equal(page.element('tabs').value, 'tab-1');
    assert.equal(page.element('message').value, 'First draft');
    page.app.connect(); const current = page.sockets.at(-1);
    current.receive({ hello: 'c'.repeat(64) }); await settle(); reply(current.sent.at(-1), 'tab-1', current); await settle();
    assert.equal(current.sent.some(r => r.action === 'select'), false);
    select(); await settle(); const pending = current.sent.at(-1);
    reply(oldRequest, 'tab-2'); await settle();
    assert.equal(page.element('message').readOnly, true);
    assert.equal(page.element('message').value, 'First draft');
    reply(pending, 'tab-2', current); await settle();
    assert.equal(page.element('message').readOnly, false);
    assert.equal(page.element('message').value, 'Second draft');
  });
}

test('pending selection blocks Stop and Interrupt without queuing a key for the old target', async () => {
  const { page, socket, select, reply } = await selectionFixture();
  select(); await settle();
  const request = socket.sent.at(-1);
  assert.equal(page.element('stop').disabled, true);
  assert.equal(page.element('interrupt').disabled, true);
  void page.element('stop').onclick(); void page.element('interrupt').onclick();
  await settle(); reply(request, 'tab-2'); await settle();
  assert.equal(socket.sent.some(r => r.action === 'key'), false);
});

test('a selection timeout releases its draft before the socket close event arrives', async () => {
  const { page, socket, select } = await selectionFixture();
  select(); await settle();
  assert.equal(page.element('message').readOnly, true);
  // Browser WebSocket.close() initiates an asynchronous close handshake.
  const close = socket.close.bind(socket);
  socket.close = () => { socket.readyState = 2; };
  await page.fireTimer(10000);
  assert.equal(page.element('message').readOnly, false);
  assert.equal(page.element('tabs').value, 'tab-1');
  assert.equal(page.element('message').value, 'First draft');
  assert.equal(socket.sent.some(r => ['input', 'key'].includes(r.action)), false);
  close();
});

test('an old selection completion cannot unlock a newer connection selection', async () => {
  const { page, select, reply } = await selectionFixture();
  const original = page.app.request;
  let release;
  page.app.request = () => new Promise(resolve => { release = resolve; });
  select(); await settle(); assert.equal(page.element('message').readOnly, true);
  page.app.request = original;
  page.app.connect(); const current = page.sockets.at(-1);
  current.receive({ hello: 'c'.repeat(64) }); await settle(); reply(current.sent.at(-1), 'tab-1', current); await settle();
  select(); await settle(); const pending = current.sent.at(-1);
  release({ ok: true }); await settle();
  assert.equal(page.element('message').readOnly, true);
  assert.equal(page.element('send').disabled, true);
  reply(pending, 'tab-2', current); await settle();
  assert.equal(page.element('message').readOnly, false);
  assert.equal(page.element('message').value, 'Second draft');
});

test('a failed selection restores the picker to the displayed session', async () => {
  const page = await browser();
  const socket = await page.authorize();
  await page.fireTimer(1000);
  const poll = socket.sent.at(-1);
  socket.receive({ data: JSON.stringify({ challenge: poll.challenge, clientNonce: poll.clientNonce, sequence: poll.sequence, ok: true,
    state: { tabs: [{ id: 'tab-1', title: 'One', status: 'idle' }, { id: 'tab-2', title: 'Two', status: 'idle' }],
      selectedTabID: 'tab-1', terminal: '' } }) });
  await settle();
  page.element('tabs').value = 'tab-2';
  page.element('tabs').onchange();
  await settle();
  const request = socket.sent.at(-1);
  assert.equal(request.action, 'select');
  socket.receive({ data: JSON.stringify({ challenge: request.challenge, clientNonce: request.clientNonce, sequence: request.sequence,
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
    challenge: poll.challenge, clientNonce: poll.clientNonce, sequence: poll.sequence, ok: true, ticket,
    state: { tabs: [{ id: 'tab-1', title: 'Fixture', status: 'idle', provider: 'grokBuild', sessionID: 'native-fixture', cwd: '/tmp/fixture' }], selectedTabID: 'tab-1', terminal: 'READY' },
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
  assert.equal(page.element('message').readOnly, false);
  assert.equal(page.element('stop').disabled, false);
  assert.equal(page.element('interrupt').disabled, false);
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
  socket.receive({ data: JSON.stringify({ challenge: stale.challenge, clientNonce: stale.clientNonce, sequence: stale.sequence,
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
  const page = await browser({ hash: `#room=${'a'.repeat(32)}&key=${'b'.repeat(64)}`, saved: null });
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
    challenge: request.challenge, clientNonce: request.clientNonce, sequence: request.sequence, ok: true,
    projects: [{ name: 'Widget', folder: '/work/widget' }, { name: 'Other', folder: '/work/other' }],
    state: { tabs: [{ id: 'tab-1', title: 'Fixture', status: 'idle', provider: 'grokBuild', sessionID: 'native-fixture', cwd: '/tmp/fixture' }], selectedTabID: 'tab-1', terminal: 'READY' },
  }) });
  await settle();
  await skipOptions(socket);
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
    challenge: again.challenge, clientNonce: again.clientNonce, sequence: again.sequence, ok: true,
    projects: [{ name: 'Widget', folder: '/work/widget' }],
    state: { tabs: [{ id: 'tab-1', title: 'Fixture', status: 'idle', provider: 'grokBuild', sessionID: 'native-fixture', cwd: '/tmp/fixture' }], selectedTabID: 'tab-1', terminal: 'READY' },
  }) });
  await settle();
  await skipOptions(socket);
  page.element('project-list').children[0].onclick();
  await settle();
  assert.equal(socket.sent.at(-1).action, 'new');
  assert.equal(socket.sent.at(-1).text, '/work/widget');
  assert.equal(socket.sent.at(-1).provider, undefined);
  assert.equal(page.element('provider-field').hidden, true);
});

test('New offers the Mac\'s CLIs and starts the chosen one', async () => {
  const page = await browser();
  const socket = await page.authorize();
  const providers = [
    { id: 'grokBuild', name: 'Grok Build', takesModel: true },
    { id: 'claudeCode', name: 'Claude Code', takesModel: false },
    { id: 'kimi', name: 'Kimi Code', takesModel: false, problem: 'Set up Kimi Code sign-in in Sigil on your Mac, then try again.' },
  ];
  async function openNew() {
    page.element('new').onclick();
    await settle();
    const projects = socket.sent.at(-1);
    assert.equal(projects.action, 'projects');
    socket.receive({ data: JSON.stringify({
      challenge: projects.challenge, clientNonce: projects.clientNonce, sequence: projects.sequence, ok: true,
      projects: [{ name: 'Widget', folder: '/work/widget' }],
    }) });
    await settle();
    const options = socket.sent.at(-1);
    assert.equal(options.action, 'options');
    socket.receive({ data: JSON.stringify({
      challenge: options.challenge, clientNonce: options.clientNonce, sequence: options.sequence, ok: true,
      options: { providers, provider: 'grokBuild', models: ['grok-4.6'], model: 'grok-4.6', efforts: [{ id: 'high', name: 'High' }], effort: 'high', locations: [] },
    }) });
    await settle();
    assert.equal(page.element('project-dialog').open, true);
  }
  await openNew();
  assert.equal(page.element('provider-field').hidden, false);
  assert.deepEqual(page.element('provider').children.map(option => [option.value, option.textContent]),
    providers.map(provider => [provider.id, provider.name]));
  assert.equal(page.element('provider').value, 'grokBuild');
  assert.equal(page.element('provider-problem').hidden, true);

  page.element('provider').value = 'kimi';
  page.element('provider').onchange();
  assert.equal(page.element('provider-problem').hidden, false);
  assert.match(page.element('provider-problem').textContent, /Kimi Code sign-in/);
  assert.equal(page.element('project-list').children[0].disabled, true);
  page.element('project-list').children[0].onclick();
  await settle();
  assert.equal(socket.sent.filter(item => item.action === 'new').length, 0);

  page.element('provider').value = 'claudeCode';
  page.element('provider').onchange();
  assert.equal(page.element('provider-problem').hidden, true);
  assert.equal(page.element('project-list').children[0].disabled, false);
  page.element('project-list').children[0].onclick();
  await settle();
  page.element('project-start').onclick();
  await settle();
  const created = socket.sent.at(-1);
  assert.equal(created.action, 'new');
  assert.equal(created.text, '/work/widget');
  assert.equal(created.provider, 'claudeCode');
  socket.reply(created);
  await settle();

  // The next New keeps this page's choice over the Mac's default.
  await openNew();
  assert.equal(page.element('provider').value, 'claudeCode');
});

test('a snapshot with no overlap keeps the previous tail', async () => {
  const page = await browser();
  const socket = await page.authorize();
  await page.fireTimer(1000);
  const first = socket.sent.at(-1);
  socket.receive({ data: JSON.stringify({
    challenge: first.challenge, clientNonce: first.clientNonce, sequence: first.sequence, ok: true,
    state: { tabs: [{ id: 'tab-1', title: 'Fixture', status: 'idle', provider: 'grokBuild', sessionID: 'native-fixture', cwd: '/tmp/fixture' }], selectedTabID: 'tab-1', terminal: 'OLD_TAIL_MARKER' },
  }) });
  await settle();
  await page.fireTimer(1000);
  const next = socket.sent.at(-1);
  socket.receive({ data: JSON.stringify({
    challenge: next.challenge, clientNonce: next.clientNonce, sequence: next.sequence, ok: true,
    state: { tabs: [{ id: 'tab-1', title: 'Fixture', status: 'idle', provider: 'grokBuild', sessionID: 'native-fixture', cwd: '/tmp/fixture' }], selectedTabID: 'tab-1', terminal: 'NEW_WINDOW_ONLY' },
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
      challenge: poll.challenge, clientNonce: poll.clientNonce, sequence: poll.sequence, ok: true,
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
      challenge: poll.challenge, clientNonce: poll.clientNonce, sequence: poll.sequence, ok: true,
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
    challenge: poll.challenge, clientNonce: poll.clientNonce, sequence: poll.sequence, ok: true,
    state: { tabs: [{ id: 'tab-1', title: 'Fixture', status: 'idle', provider: 'grokBuild', sessionID: 'native-fixture', cwd: '/tmp/fixture' }], selectedTabID: 'tab-1', terminal: 'task [\\]' },
  }) });
  await settle();
  await page.fireTimer(1000);
  const next = socket.sent.at(-1);
  socket.receive({ data: JSON.stringify({
    challenge: next.challenge, clientNonce: next.clientNonce, sequence: next.sequence, ok: true,
    state: { tabs: [{ id: 'tab-1', title: 'Fixture', status: 'idle', provider: 'grokBuild', sessionID: 'native-fixture', cwd: '/tmp/fixture' }], selectedTabID: 'tab-1', terminal: 'task [|]' },
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
    challenge: first.challenge, clientNonce: first.clientNonce, sequence: first.sequence, ok: true,
    chats: [{ id: 'chat-1', title: 'One', folder: '/work/one' }],
    state: { tabs: [{ id: 'tab-1', title: 'Fixture', status: 'idle', provider: 'grokBuild', sessionID: 'native-fixture', cwd: '/tmp/fixture' }], selectedTabID: 'tab-1', terminal: 'READY' },
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

test('a long chats search sends only the 200 characters the Mac reads', async () => {
  const page = await browser();
  const socket = await page.authorize();
  page.element('sessions-toggle').onclick();
  page.element('session-search').value = `${'😀'.repeat(150)}${'x'.repeat(9000)}`;
  page.element('session-search').oninput();
  await settle();
  const sent = socket.sent.at(-1);
  assert.equal(sent.action, 'chats');
  assert.equal([...sent.text].length, 200);
  assert.ok(sent.text.startsWith('😀'.repeat(150)));
  assert.equal(socket.readyState, 1);
});

test('a chats search counts characters the way the Mac does', async () => {
  const page = await browser();
  const socket = await page.authorize();
  page.element('sessions-toggle').onclick();
  // Each family emoji is five code points and one character to the Mac.
  const query = `${'👨‍👩‍👧'.repeat(100)}needle`;
  page.element('session-search').value = query;
  page.element('session-search').oninput();
  await settle();
  assert.equal(socket.sent.at(-1).text, query);
});

test('a chats search of stacked accents stays under the 8 KB the Mac accepts', async () => {
  const page = await browser();
  const socket = await page.authorize();
  page.element('sessions-toggle').onclick();
  page.element('session-search').value = `e${'\u0301'.repeat(100)}`.repeat(200);
  page.element('session-search').oninput();
  await settle();
  const sent = socket.sent.at(-1);
  assert.equal(sent.action, 'chats');
  assert.ok(new TextEncoder().encode(sent.text).length <= 8192);
  assert.ok(sent.text.startsWith(`e${'\u0301'.repeat(100)}`));
  assert.equal(socket.readyState, 1);
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
    challenge: request.challenge, clientNonce: request.clientNonce, sequence: request.sequence, ok: true, chatsTruncated: true,
    chats: [{ id: 'chat-1', title: 'Wide one', folder: '/work/one' }],
    state: { tabs: [{ id: 'tab-1', title: 'Fixture', status: 'idle', provider: 'grokBuild', sessionID: 'native-fixture', cwd: '/tmp/fixture' }], selectedTabID: 'tab-1', terminal: 'READY' },
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
    challenge: request.challenge, clientNonce: request.clientNonce, sequence: request.sequence, ok: true,
    projects: [],
    state: { tabs: [{ id: 'tab-1', title: 'Fixture', status: 'idle', provider: 'grokBuild', sessionID: 'native-fixture', cwd: '/tmp/fixture' }], selectedTabID: 'tab-1', terminal: 'READY' },
  }) });
  await settle();
  await skipOptions(socket);
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
    challenge: request.challenge, clientNonce: request.clientNonce, sequence: request.sequence, ok: true, projects,
    state: { tabs: [{ id: 'tab-1', title: 'Fixture', status: 'idle', provider: 'grokBuild', sessionID: 'native-fixture', cwd: '/tmp/fixture' }], selectedTabID: 'tab-1', terminal: 'READY' },
  }) });
  await settle();
  await skipOptions(socket);
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
    challenge: request.challenge, clientNonce: request.clientNonce, sequence: request.sequence, ok: true, projectsTruncated: true,
    projects: [{ name: 'One', folder: '/work/one' }, { name: 'Two', folder: '/work/two' }],
    state: { tabs: [{ id: 'tab-1', title: 'Fixture', status: 'idle', provider: 'grokBuild', sessionID: 'native-fixture', cwd: '/tmp/fixture' }], selectedTabID: 'tab-1', terminal: 'READY' },
  }) });
  await settle();
  await skipOptions(socket);
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
    challenge: request.challenge, clientNonce: request.clientNonce, sequence: request.sequence, ok: true, projects,
    state: { tabs: [{ id: 'tab-1', title: 'Fixture', status: 'idle', provider: 'grokBuild', sessionID: 'native-fixture', cwd: '/tmp/fixture' }], selectedTabID: 'tab-1', terminal: 'READY' },
  }) });
  await settle();
  await skipOptions(socket);
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
    challenge: request.challenge, clientNonce: request.clientNonce, sequence: request.sequence, ok: true,
    chats: [{ id: 'chat-1', title: 'Fix the widget', folder: '/work/widget', transcript: 'SECRET_TRANSCRIPT' }],
    state: { tabs: [{ id: 'tab-1', title: 'Fixture', status: 'idle', provider: 'grokBuild', sessionID: 'native-fixture', cwd: '/tmp/fixture' }], selectedTabID: 'tab-1', terminal: 'READY' },
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
    challenge: request.challenge, clientNonce: request.clientNonce, sequence: request.sequence, ok: true, earlier: 'EARLY_MARKER\n',
    state: { tabs: [{ id: 'tab-1', title: 'Fixture', status: 'idle', provider: 'grokBuild', sessionID: 'native-fixture', cwd: '/tmp/fixture' }], selectedTabID: 'tab-1', terminal: 'TAIL_MARKER' },
  }) });
  await settle();
  assert.match(terminal.textContent, /EARLY_MARKER/);
  assert.match(terminal.textContent, /TAIL_MARKER/);
  await page.fireTimer(1000);
  assert.equal(socket.sent.at(-1).action, 'state');
  const poll = socket.sent.at(-1);
  socket.receive({ data: JSON.stringify({
    challenge: poll.challenge, clientNonce: poll.clientNonce, sequence: poll.sequence, ok: true,
    state: { tabs: [{ id: 'tab-1', title: 'Fixture', status: 'idle', provider: 'grokBuild', sessionID: 'native-fixture', cwd: '/tmp/fixture' }], selectedTabID: 'tab-1', terminal: 'AIL_MARKER!' },
  }) });
  await settle();
  assert.match(terminal.textContent, /EARLY_MARKER/);
  assert.match(terminal.textContent, /AIL_MARKER!/);
  page.element('find-toggle').onclick();
  page.element('find-query').value = 'EARLY_MARKER';
  page.element('find-query').oninput();
  assert.match(page.element('find-count').textContent, /1 of 1/);
});

test('Send never crosses a same-socket reauthorization between paste and Enter', async () => {
  const page = await browser();
  const socket = await page.authorize();
  page.submit(); await settle();
  socket.reply(); await settle();
  socket.receive({ hello: 'd'.repeat(64) }); await settle();
  assert.notEqual(page.element('status').textContent, 'Connected');
  socket.reply(); await settle();
  await page.fireTimer(100);
  assert.equal(socket.sent.filter(r => r.action === 'key').length, 0);
  assert.equal(page.element('message').value, 'fixture input');
});

test('a lost acknowledgement invalidates queued keys before reconnect', async () => {
  const page = await browser();
  const socket = await page.authorize();
  await page.fireTimer(1000);
  const queued = page.app.request('key', 'enter', 'tab-1').catch(error => error.message);
  await page.fireTimer(10000);
  await queued;
  assert.equal(socket.readyState, 3);
  assert.equal(socket.sent.some(r => r.action === 'key'), false);
});


test('delayed ticket persistence cannot apply an old connection snapshot', async () => {
  const page = await browser();
  const socket = await page.authorize();
  let release;
  const held = new Promise(resolve => { release = resolve; });
  const originalStorage = page.app.storage;
  page.app.storage = async (mode, value) => {
    if (mode === 'put') await held;
    return originalStorage(mode, value);
  };
  await page.fireTimer(1000);
  const old = socket.sent.at(-1);
  socket.receive({ data: JSON.stringify({ challenge: old.challenge, clientNonce: old.clientNonce,
    sequence: old.sequence, ok: true, ticket: 'f'.repeat(64),
    state: { tabs: [{ id: 'old-tab', title: 'Old Mac', status: 'idle' }], selectedTabID: 'old-tab', terminal: 'STALE_PRIVATE_OUTPUT' },
  }) });
  await settle();
  page.app.connect();
  await page.authorize();
  release(); await settle();
  assert.equal(page.element('terminal').textContent, 'READY');
  assert.equal(page.element('tabs').value, 'tab-1');
});

const newSessionOptions = {
  providers: [{ id: 'grokBuild', name: 'Grok Build', takesModel: true }, { id: 'claudeCode', name: 'Claude Code', takesModel: false }],
  provider: 'grokBuild', models: ['grok-4.6', 'grok-fast'], model: 'grok-4.6',
  efforts: [{ id: '', name: 'CLI default' }, { id: 'high', name: 'High' }], effort: 'high',
  locations: [{ name: 'Code', folder: '/tmp/code' }], startsInWorktree: true,
};
const newSessionProjects = [
  { name: 'Repository', folder: '/tmp/code/repo', repository: true, worktreeDefault: true },
  { name: 'Home repository', folder: '/tmp/home', repository: true, worktreeDefault: false },
  { name: 'Plain', folder: '/tmp/plain', repository: false },
];
async function newReply(socket, fields = {}) {
  const request = socket.sent.at(-1);
  socket.receive({ data: JSON.stringify({ challenge: request.challenge, clientNonce: request.clientNonce, sequence: request.sequence, ok: true, ...fields }) });
  await settle();
}
async function openNewSheet(page, socket, { options = newSessionOptions, projects = newSessionProjects, sessionOps = true } = {}) {
  page.app.render({ tabs: [], selectedTabID: null, terminal: '', capabilities: sessionOps ? ['sessionOps'] : [] });
  page.element('new').onclick(); await settle();
  await newReply(socket, { projects });
  assert.equal(socket.sent.at(-1).action, 'options');
  await newReply(socket, options === null ? { ok: false, error: 'Unknown action.' } : { options });
}
function creationForm(page, name = 'fresh') {
  page.element('project-add').onclick();
  page.element('project-name').value = name;
  page.element('project-name').oninput();
}
function submitProject(page) { page.element('new-project-form').onsubmit({ preventDefault() {} }); }

test('REA-1206 sends advertised model/effort and explicit repository choices, with per-project defaults', async () => {
  const page = await browser(), socket = await page.authorize();
  await openNewSheet(page, socket);
  assert.equal(page.element('new-worktree').checked, true);
  assert.equal(page.element('worktree-field').hidden, false);
  page.element('project-list').children[1].onclick();
  assert.equal(page.element('new-worktree').checked, false); // Home default wins over the global preference.
  page.element('new-worktree').checked = true; page.element('new-worktree').onchange();
  page.element('new-model').value = 'grok-fast'; page.element('new-model').onchange();
  page.element('new-effort').value = ''; page.element('new-effort').onchange();
  page.element('project-start').onclick(); page.element('project-start').onclick(); await settle();
  const request = socket.sent.at(-1);
  assert.equal(request.action, 'new'); assert.equal(request.text, '/tmp/home');
  assert.equal(request.worktree, true); assert.equal(request.model, 'grok-fast'); assert.equal(request.effort, '');
  assert.equal(socket.sent.filter(item => item.action === 'new').length, 1);
  assert.equal(page.stored().pendingNew.action, 'new');
  await newReply(socket);
  assert.equal(page.stored().pendingNew, undefined);
  await openNewSheet(page, socket);
  page.element('new-worktree').checked = false; page.element('new-worktree').onchange();
  page.element('project-start').onclick(); await settle();
  assert.equal(socket.sent.at(-1).worktree, false);
  await newReply(socket);
});

test('REA-1206 changing project resets its explicit choice and non-model providers omit model/effort', async () => {
  const page = await browser(), socket = await page.authorize();
  await openNewSheet(page, socket);
  page.element('new-worktree').checked = false; page.element('new-worktree').onchange();
  page.element('project-list').children[1].onclick();
  page.element('project-list').children[0].onclick();
  assert.equal(page.element('new-worktree').checked, true);
  page.element('project-list').children[2].onclick();
  assert.equal(page.element('worktree-field').hidden, true);
  page.element('provider').value = 'claudeCode'; page.element('provider').onchange();
  assert.equal(page.element('model-field').hidden, true);
  page.element('project-start').onclick(); await settle();
  const request = socket.sent.at(-1);
  assert.equal(request.provider, 'claudeCode'); assert.equal(request.worktree, undefined);
  assert.equal(request.model, undefined); assert.equal(request.effort, undefined);
  await newReply(socket);
});

test('REA-1206 unsupported sessionOps hides worktree and project creation and leaves the Mac default authoritative', async () => {
  const page = await browser(), socket = await page.authorize();
  await openNewSheet(page, socket, { sessionOps: false });
  assert.equal(page.element('worktree-field').hidden, true); assert.equal(page.element('project-add').hidden, true);
  assert.match(page.element('worktree-detail').textContent, /Mac applies its worktree default/);
  creationForm(page); submitProject(page); await settle();
  assert.equal(socket.sent.filter(item => item.action === 'createProject').length, 0);
  page.element('project-start').onclick(); await settle();
  assert.equal(socket.sent.at(-1).worktree, undefined);
  await newReply(socket);
});

for (const field of ['provider', 'new-model', 'new-effort']) {
  test(`REA-1206 rejects a forged ${field} selection before dispatch`, async () => {
    const page = await browser(), socket = await page.authorize();
    await openNewSheet(page, socket);
    page.element(field).value = 'not-advertised'; page.element(field).onchange();
    assert.equal(page.element('project-start').disabled, true);
    page.element('project-start').onclick(); await settle();
    assert.equal(socket.sent.filter(item => item.action === 'new').length, 0);
  });
}

test('REA-1206 bounds malformed options and never fabricates a missing model/effort', async () => {
  const page = await browser(), socket = await page.authorize();
  await openNewSheet(page, socket, { options: { ...newSessionOptions,
    models: ['--flag', 'two words', 'x'.repeat(65), null], efforts: [{ id: '-- flag', name: 'Bad' }],
    locations: [{ name: 'Escape', folder: '../outside' }], startsInWorktree: 'yes' } });
  assert.equal(page.element('new-model').children.length, 0);
  assert.equal(page.element('new-effort').children.length, 0);
  assert.equal(page.element('project-add').hidden, true);
  assert.equal(page.element('project-start').disabled, true);
  page.element('project-start').onclick(); await settle();
  assert.equal(socket.sent.filter(item => item.action === 'new').length, 0);
});

test('REA-1206 validates UTF-8 folder names and advertised destinations; Back and Cancel dispatch nothing', async () => {
  const page = await browser(), socket = await page.authorize();
  await openNewSheet(page, socket);
  for (const name of ['', '.hidden', '../escape', 'a/b', 'a:b', 'x\u0000', 'x\u0085', 'x\u200B', '界'.repeat(27)]) {
    creationForm(page, name); submitProject(page); await settle();
    assert.equal(page.element('project-create').disabled, true, name);
  }
  creationForm(page, ' valid ');
  page.element('project-location').value = '/not-advertised'; page.element('project-location').onchange();
  submitProject(page); await settle();
  assert.equal(socket.sent.filter(item => item.action === 'createProject').length, 0);
  page.element('project-back').onclick(); assert.equal(page.element('new-project-form').hidden, true);
  page.element('project-cancel').onclick();
  assert.equal(socket.sent.filter(item => item.action === 'new').length, 0);
});

test('REA-1206 creates or adopts exactly one project, refreshes its metadata and selects it without starting', async () => {
  const page = await browser(), socket = await page.authorize();
  await openNewSheet(page, socket); creationForm(page, ' fresh ');
  submitProject(page); submitProject(page); await settle();
  const request = socket.sent.at(-1);
  assert.equal(request.action, 'createProject'); assert.equal(request.text, '/tmp/code'); assert.equal(request.name, 'fresh');
  assert.equal(socket.sent.filter(item => item.action === 'createProject').length, 1);
  const created = { name: 'fresh', folder: '/tmp/code/fresh', repository: true, worktreeDefault: false };
  await newReply(socket, { project: { name: created.name, folder: created.folder } });
  assert.equal(socket.sent.at(-1).action, 'projects');
  await newReply(socket, { projects: [created] });
  assert.equal(page.element('new-project-form').hidden, true);
  assert.equal(page.element('new-worktree').checked, false);
  assert.equal(socket.sent.filter(item => item.action === 'new').length, 0);
  page.element('project-start').onclick(); await settle();
  assert.equal(socket.sent.at(-1).text, created.folder);
  await newReply(socket);
});

for (const end of ['disconnect', 'timeout']) {
  test(`REA-1206 ${end} leaves a start blocked across reconnect, reload and changed selections; late replies do not settle it`, async () => {
    const page = await browser(), socket = await page.authorize();
    await openNewSheet(page, socket); page.element('project-start').onclick(); await settle();
    const request = socket.sent.at(-1);
    if (end === 'timeout') await page.fireTimer(10000); else socket.close();
    await settle();
    socket.reply(request); await settle();
    assert.equal(page.stored().pendingNew.action, 'new');
    await page.fireTimer(500); const next = await page.authorize();
    await openNewSheet(page, next);
    page.element('provider').value = 'claudeCode'; page.element('provider').onchange();
    page.element('project-list').children[1].onclick(); page.element('project-start').onclick(); await settle();
    assert.equal(next.sent.filter(item => item.action === 'new').length, 0);
    assert.match(page.element('new-outcome').textContent, /inspect its tabs and worktrees/);
    const restored = await browser({ saved: page.stored() }), restoredSocket = await restored.authorize();
    await openNewSheet(restored, restoredSocket);
    assert.equal(restored.element('project-start').disabled, true);
  });
}

test('REA-1206 lost project reply reconciles only an exact authoritative path, without recreating it', async () => {
  const page = await browser(), socket = await page.authorize();
  await openNewSheet(page, socket); creationForm(page); submitProject(page); await settle();
  socket.close(); await settle(); await page.fireTimer(500); const next = await page.authorize();
  await openNewSheet(page, next);
  page.element('project-check').onclick(); await settle();
  await newReply(next, { projects: [{ name: 'fresh', folder: '/elsewhere/fresh' }] });
  assert.equal(page.stored().pendingNew.action, 'createProject');
  page.element('project-check').onclick(); await settle();
  await newReply(next, { projects: [{ name: 'fresh', folder: '/tmp/code/fresh', repository: false }] });
  assert.equal(page.stored().pendingNew, undefined);
  assert.equal(next.sent.filter(item => item.action === 'createProject').length, 0);
  assert.equal(page.element('project-list').children[0].dataset.folder, '/tmp/code/fresh');
});

test('REA-1206 mismatched creation reply stays unresolved; verified rejection can be retried', async () => {
  const page = await browser(), socket = await page.authorize();
  await openNewSheet(page, socket); creationForm(page); submitProject(page); await settle();
  await newReply(socket, { ok: false, error: 'A file with that name is already there.' });
  assert.equal(page.stored().pendingNew, undefined);
  submitProject(page); await settle();
  await newReply(socket, { project: { name: 'fresh', folder: '/elsewhere/fresh' } });
  assert.equal(page.stored().pendingNew.action, 'createProject');
  submitProject(page); await settle();
  assert.equal(socket.sent.filter(item => item.action === 'createProject').length, 2);
});

test('REA-1206 storage failure prevents dispatch; corrupt saved markers fail closed', async () => {
  const faults = {}, page = await browser({ faults }), socket = await page.authorize();
  await openNewSheet(page, socket); faults.storage = true;
  page.element('project-start').onclick(); await settle();
  assert.equal(socket.sent.filter(item => item.action === 'new').length, 0);
  const restored = await browser({ saved: { room: 'a'.repeat(32), key: { device: true }, pendingNew: { action: 'invalid' } } });
  const next = await restored.authorize(); await openNewSheet(restored, next);
  assert.equal(restored.element('project-start').disabled, true);
});

test('REA-1206 bounded reconciliation scans authoritative pages and keeps unresolved results blocked', async () => {
  const page = await browser({ saved: { room: 'a'.repeat(32), key: { device: true }, pendingNew: { action: 'createProject', folder: '/tmp/code/fresh' } } });
  const socket = await page.authorize(); await openNewSheet(page, socket);
  page.element('project-check').onclick(); await settle();
  for (let index = 0; index < 400; index += 40) {
    assert.equal(socket.sent.at(-1).index, index);
    await newReply(socket, { projects: [{ name: 'Other', folder: `/tmp/other/${index}` }], projectsTruncated: true });
  }
  assert.equal(page.stored().pendingNew.folder, '/tmp/code/fresh');
  assert.equal(page.element('project-start').disabled, true);
  assert.match(page.element('project-error').textContent, /result stays unknown/);
});

test('REA-1206 connection replacement cannot settle an old project attempt or replay it', async () => {
  const page = await browser({ saved: { room: 'a'.repeat(32), key: { device: true }, pendingNew: { action: 'createProject', folder: '/tmp/code/fresh' } } });
  const socket = await page.authorize(); await openNewSheet(page, socket);
  page.element('project-check').onclick(); await settle();
  const old = socket.sent.at(-1); socket.close(); await settle();
  await page.fireTimer(500); const next = await page.authorize();
  socket.receive({ data: JSON.stringify({ challenge: old.challenge, clientNonce: old.clientNonce, sequence: old.sequence, ok: true,
    projects: [{ name: 'fresh', folder: '/tmp/code/fresh' }] }) });
  await settle();
  assert.equal(page.stored().pendingNew.action, 'createProject');
  assert.equal(next.sent.filter(item => ['new', 'createProject'].includes(item.action)).length, 0);
});

test('REA-1206 a failed result write cannot attach the old Mac attempt to a replacement pairing', async () => {
  const faults = { pending: [] }, page = await browser({ faults }), socket = await page.authorize();
  await openNewSheet(page, socket); page.element('project-start').onclick(); await settle();
  faults.holdCompletion = true;
  await newReply(socket);
  assert.equal(faults.pending.length, 1);
  faults.holdCompletion = false;
  await page.app.beginPair({ room: 'd'.repeat(32), key: 'f'.repeat(64) });
  const write = faults.pending[0]; write.error = new Error('Write failed'); write.onabort();
  await settle();
  assert.equal(page.app.pendingNew(), null);
});

test('REA-1206 preparation is not described as a sent request while persistence is pending', async () => {
  const faults = { pending: [] }, page = await browser({ faults }), socket = await page.authorize();
  await openNewSheet(page, socket); faults.holdCompletion = true;
  page.element('project-start').onclick(); await settle();
  assert.match(page.element('new-outcome').textContent, /Preparing/);
  assert.equal(socket.sent.filter(request => request.action === 'new').length, 0);
  faults.holdCompletion = false; faults.pending[0].oncomplete(); await settle();
  assert.match(page.element('new-outcome').textContent, /Waiting for the Mac/);
  assert.equal(socket.sent.filter(request => request.action === 'new').length, 1);
  await newReply(socket);
});
