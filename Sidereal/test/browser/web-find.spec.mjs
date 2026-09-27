import { test, expect } from '@playwright/test';
import { WebSocket } from 'ws';
import { once } from 'node:events';
import { randomKey, importKey, seal, open } from '../../public/crypto.mjs';
import { readableOutput } from '../../public/output.mjs';

// A synthetic Mac on the actual relay and encryption, as in mobile.spec.mjs. Never touches user sessions.
let sharedRoom, previousHost;
async function pair(page, origin, options) {
  if (!sharedRoom) {
    const allocation = await fetch(`${origin}/rooms`, { method: 'POST' });
    expect(allocation.status).toBe(201);
    sharedRoom = await allocation.json();
  }
  const { room, hostToken } = sharedRoom;
  if (previousHost && previousHost.readyState !== WebSocket.CLOSED) {
    previousHost.close();
    await once(previousHost, 'close');
  }
  const bootstrap = randomKey(), ticket = randomKey();
  let key = await importKey(bootstrap), peer, challenge, serial = Promise.resolve(), ws, ready;
  const actions = [];
  const registered = new Promise(resolve => { ready = resolve; });
  const onMessage = bytes => {
    serial = serial.then(async () => {
      const frame = JSON.parse(bytes);
      if (frame.route) {
        ws.send(JSON.stringify({ route: await seal({ room, ticket }, await importKey(frame.route), 'relay-host') }));
      } else if (frame.type === 'ready') {
        ready();
      } else if (frame.type === 'peer') {
        peer = frame.peer; challenge = randomKey();
        ws.send(JSON.stringify({ peer, hello: challenge }));
      } else if (frame.data) {
        const request = await open(frame.data, key, 'phone');
        actions.push(request);
        if (request.action === 'pair') key = await importKey(request.text);
        const state = { tabs: [{ id: 'one', title: 'Find fixture', status: 'idle' }], selectedTabID: 'one', terminal: options.terminal(), capabilities: [] };
        const payload = { challenge, sequence: request.sequence, ok: true, ticket, state };
        if (request.action === 'earlier') payload.earlier = options.earlier ? options.earlier(request) : '';
        ws.send(JSON.stringify({ peer, data: await seal(payload, key, 'mac') }));
      }
    });
  };
  for (let attempt = 0; ; attempt++) {
    ws = new WebSocket(`${origin.replace(/^http/, 'ws')}/connect?role=host`, { headers: { Authorization: `Bearer ${hostToken}` } });
    ws.on('message', onMessage);
    try { await once(ws, 'open'); break; }
    catch (error) { if (attempt >= 9) throw error; await new Promise(resolve => setTimeout(resolve, 100)); }
  }
  previousHost = ws;
  await registered;
  await page.goto(`${origin}/#room=${room}&key=${bootstrap}`);
  await expect(page.locator('#status')).toHaveText('Connected');
  return { actions, close: () => ws.close() };
}

// 780 lines of 40 matches: 31,200 matches in 62,399 characters, under one sealed message's 64 KB.
const dense = Array.from({ length: 780 }, () => `${'a '.repeat(39)}a`).join('\n');
const count = (text, query) => [...text.matchAll(new RegExp(query.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'), 'giu'))];

// What Find shows, read from the page: highlights where the browser has them, else marks.
function findState(page) {
  return page.evaluate(() => {
    const terminal = document.getElementById('terminal');
    const text = terminal.textContent;
    const offset = (node, at) => {
      let total = 0;
      const walker = document.createTreeWalker(terminal, NodeFilter.SHOW_TEXT);
      while (walker.nextNode()) { if (walker.currentNode === node) return total + at; total += walker.currentNode.length; }
      return -1;
    };
    const describe = range => ({ start: offset(range.startContainer, range.startOffset), end: offset(range.endContainer, range.endOffset), text: range.toString() });
    const box = terminal.getBoundingClientRect();
    const visible = range => { const rect = range.getBoundingClientRect(); return rect.bottom > box.top && rect.top < box.bottom; };
    const api = typeof Highlight === 'function' && CSS.highlights?.has('find-match');
    const marks = [...terminal.querySelectorAll('mark')].map(mark => { const range = document.createRange(); range.selectNodeContents(mark.firstChild); return { mark, range }; });
    const matches = api ? [...CSS.highlights.get('find-match')] : marks.map(item => item.range);
    const current = api ? [...CSS.highlights.get('find-current')][0] : marks.find(item => item.mark.dataset.current === 'true')?.range;
    return {
      api, text, count: document.getElementById('find-count').textContent,
      elements: terminal.querySelectorAll('*').length, childNodes: terminal.childNodes.length,
      shown: matches.length, shownVisible: matches.filter(visible).length,
      current: current ? { ...describe(current), visible: visible(current) } : null,
      lineHeight: parseFloat(getComputedStyle(terminal).lineHeight), height: terminal.clientHeight,
      scrollTop: terminal.scrollTop,
    };
  });
}
const frames = page => page.evaluate(() => new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve))));

async function openFind(page, query) {
  await page.getByRole('button', { name: 'Find in output' }).click();
  await page.getByRole('searchbox', { name: 'Find in output' }).fill(query);
  await frames(page);
}

for (const api of [true, false]) {
  const label = api ? 'with CSS highlights' : 'without the Highlight API';
  test.describe(label, () => {
    test.beforeEach(async ({ page }) => {
      await page.setViewportSize({ width: 390, height: 844 });
      if (!api) await page.addInitScript(() => { delete window.Highlight; });
    });

    test('Find counts 31,200 matches exactly and keeps the terminal O(visible)', async ({ page, baseURL }) => {
      const mac = await pair(page, baseURL, { terminal: () => dense });
      try {
        await expect(page.locator('#terminal')).toHaveText(dense);
        const nodesBefore = await page.evaluate(() => document.querySelectorAll('*').length);
        await openFind(page, 'a');
        const total = count(dense, 'a').length;
        expect(total).toBe(31_200);
        await expect(page.locator('#find-count')).toHaveText(`1 of ${total}`);
        const state = await findState(page);
        expect(state.api).toBe(api);
        expect(state.text).toBe(dense);
        // Highlighted matches: the visible screen plus one screen each side, never every match.
        const lines = Math.ceil(state.height / state.lineHeight);
        expect(state.shown).toBeGreaterThan(0);
        expect(state.shown).toBeLessThanOrEqual((3 * lines + 2) * 40);
        expect(state.shownVisible).toBeGreaterThan(0);
        if (api) {
          expect(state.elements).toBe(0);
          expect(state.childNodes).toBe(1);
          expect(await page.evaluate(() => document.querySelectorAll('*').length)).toBe(nodesBefore);
        } else {
          expect(state.elements).toBe(state.shown);
          expect(state.childNodes).toBe(2 * state.shown + 1);
        }
        expect(state.current).toEqual({ start: 0, end: 1, text: 'a', visible: true });
        // Previous from the first match wraps to the last, outside any window shown so far.
        await page.getByRole('button', { name: 'Previous match' }).click();
        await expect(page.locator('#find-count')).toHaveText(`${total} of ${total}`);
        await frames(page);
        const last = count(dense, 'a').at(-1).index;
        const wrapped = await findState(page);
        expect(wrapped.current).toEqual({ start: last, end: last + 1, text: 'a', visible: true });
        expect(wrapped.shownVisible).toBeGreaterThan(0);
        expect(wrapped.shown).toBeLessThanOrEqual((3 * lines + 2) * 40);
        await page.getByRole('button', { name: 'Next match' }).click();
        await expect(page.locator('#find-count')).toHaveText(`1 of ${total}`);
        await frames(page);
        expect((await findState(page)).current).toEqual({ start: 0, end: 1, text: 'a', visible: true });
        // Scrolling by hand moves the highlighted window with the reader.
        await page.locator('#terminal').evaluate(el => { el.scrollTop = el.scrollHeight / 2; });
        await expect.poll(async () => (await findState(page)).shownVisible).toBeGreaterThan(0);
        // Copying and closing leave the text exactly as it came.
        expect(await page.evaluate(() => {
          getSelection().selectAllChildren(document.getElementById('terminal'));
          const copied = getSelection().toString();
          getSelection().removeAllRanges();
          return copied;
        })).toBe(dense);
        await page.getByRole('button', { name: 'Close find' }).click();
        await frames(page);
        const closed = await findState(page);
        expect(closed.elements).toBe(0);
        expect(closed.childNodes).toBe(1);
        expect(closed.shown).toBe(0);
        expect(closed.current).toBeNull();
      } finally { mac.close(); }
    });

    test('Find walks every Unicode match in order and wraps both ways', async ({ page, baseURL }) => {
      // Astral characters shift UTF-16 offsets; the Kelvin sign and long s fold to k and s.
      const text = '🙂 \u212Aiosk ſkis\n日本 KIOSK 🚀🚀 kiosk\nplain line\n' + Array.from({ length: 60 }, (_, i) => `${i} 🙂 kiosk`).join('\n');
      const expected = count(text, 'kiosk').map(match => ({ start: match.index, end: match.index + match[0].length, text: match[0] }));
      expect(expected.length).toBe(63);
      expect(expected[0]).toEqual({ start: 3, end: 8, text: '\u212Aiosk' });
      expect(expected[1].text).toBe('KIOSK');
      const mac = await pair(page, baseURL, { terminal: () => text });
      try {
        await expect(page.locator('#terminal')).toHaveText(text);
        await openFind(page, 'kiosk');
        const seen = [];
        for (let step = 0; step < expected.length; step++) {
          await expect(page.locator('#find-count')).toHaveText(`${step + 1} of ${expected.length}`);
          await frames(page);
          const state = await findState(page);
          expect(state.current.visible).toBe(true);
          seen.push({ start: state.current.start, end: state.current.end, text: state.current.text });
          await page.getByRole('searchbox', { name: 'Find in output' }).press('Enter');
        }
        expect(seen).toEqual(expected);
        await expect(page.locator('#find-count')).toHaveText(`1 of ${expected.length}`);
        await page.getByRole('searchbox', { name: 'Find in output' }).press('Shift+Enter');
        await expect(page.locator('#find-count')).toHaveText(`${expected.length} of ${expected.length}`);
        await frames(page);
        expect((await findState(page)).current).toEqual({ ...expected.at(-1), visible: true });
        await page.getByRole('searchbox', { name: 'Find in output' }).fill('ſkis');
        await expect(page.locator('#find-count')).toHaveText('1 of 1');
        await frames(page);
        expect((await findState(page)).current).toEqual({ start: 9, end: 13, text: 'ſkis', visible: true });
        expect((await findState(page)).text).toBe(text);
      } finally { mac.close(); }
    });

    test('Find follows new output and the raw toggle while it is open', async ({ page, baseURL }) => {
      let terminal = 'alpha   \nbeta alpha   \nalpha ';
      const mac = await pair(page, baseURL, { terminal: () => terminal });
      try {
        await expect(page.locator('#terminal')).toHaveText(readableOutput(terminal));
        await openFind(page, 'a ');
        const readable = count(readableOutput(terminal), 'a ').length, raw = count(terminal, 'a ').length;
        expect(readable).not.toBe(raw);
        await expect(page.locator('#find-count')).toHaveText(readable ? `1 of ${readable}` : 'No matches');
        await page.getByLabel('Connection settings').click();
        await page.locator('#raw-toggle').click();
        await page.getByLabel('Connection settings').click();
        await expect(page.locator('#terminal')).toHaveText(terminal);
        await expect(page.locator('#find-count')).toHaveText(`1 of ${raw}`);
        await page.getByRole('button', { name: 'Next match' }).click();
        await expect(page.locator('#find-count')).toHaveText(`2 of ${raw}`);
        // A poll brings more matches; the count follows and the current match stays.
        terminal += '\ngamma alpha \nalpha a ';
        const grown = count(terminal, 'a ');
        await expect(page.locator('#find-count')).toHaveText(`2 of ${grown.length}`);
        await frames(page);
        const state = await findState(page);
        expect(state.text).toBe(terminal);
        expect(state.current).toMatchObject({ start: grown[1].index, end: grown[1].index + 2, text: 'a ' });
        expect(state.shown).toBe(grown.length);
        await page.getByLabel('Connection settings').click();
        await page.locator('#raw-toggle').click();
        await expect(page.locator('#terminal')).toHaveText(readableOutput(terminal));
        const back = count(readableOutput(terminal), 'a ').length;
        await expect(page.locator('#find-count')).toHaveText(back ? `1 of ${back}` : 'No matches');
      } finally { mac.close(); }
    });

    test('Find keeps a selection the reader is making while output arrives', async ({ page, baseURL }) => {
      let terminal = 'First needle\nStep 1 of 3';
      const mac = await pair(page, baseURL, { terminal: () => terminal });
      const polls = () => mac.actions.filter(action => action.action === 'state').length;
      try {
        await expect(page.locator('#terminal')).toHaveText(terminal);
        await openFind(page, 'needle');
        await expect(page.locator('#find-count')).toHaveText('1 of 1');
        await frames(page);
        await page.evaluate(() => {
          const text = document.getElementById('terminal').firstChild;
          getSelection().setBaseAndExtent(text, 0, text, 'First'.length);
        });
        await page.locator('#find-next').dispatchEvent('click');
        expect(await page.evaluate(() => getSelection().toString())).toBe('First');
        terminal = 'First needle\nStep 2 of 3\nsecond needle';
        const seen = polls();
        await expect.poll(polls).toBeGreaterThan(seen + 1);
        expect(await page.evaluate(() => getSelection().toString())).toBe('First');
        await expect(page.locator('#find-count')).toHaveText('1 of 1');
        await page.evaluate(() => getSelection().removeAllRanges());
        await expect(page.locator('#terminal')).toHaveText(terminal);
        await expect(page.locator('#find-count')).toHaveText('1 of 2');
      } finally { mac.close(); }
    });

    test('Find keeps the reader in place while earlier history loads', async ({ page, baseURL }) => {
      // One earlier slice, then the start of history.
      let batch = 0;
      const earlier = () => {
        batch += 1;
        return batch > 1 ? '' : Array.from({ length: 60 }, (_, i) => `Batch ${batch} line ${i + 1}: older needle output.`).join('\n') + '\n';
      };
      // The only current match is at the end, so Find itself does not scroll up to load history.
      const terminal = Array.from({ length: 60 }, (_, i) => `Line ${i + 1}: current output.`).join('\n') + '\nLast needle line.';
      const mac = await pair(page, baseURL, { terminal: () => terminal, earlier });
      try {
        await expect(page.locator('#terminal')).toHaveText(terminal);
        await openFind(page, 'needle');
        await expect(page.locator('#find-count')).toHaveText('1 of 1');
        expect(mac.actions.filter(a => a.action === 'earlier')).toHaveLength(0);
        const measure = (marker, top) => page.locator('#terminal').evaluate((el, [wanted, scrollToTop]) => {
          if (scrollToTop) el.scrollTop = 0;
          const text = wanted || el.textContent.split('\n')[0];
          const walker = document.createTreeWalker(el, NodeFilter.SHOW_TEXT);
          while (walker.nextNode() && !walker.currentNode.data.includes(text));
          const node = walker.currentNode, at = node.data.indexOf(text);
          const range = document.createRange();
          range.setStart(node, at); range.setEnd(node, at + 6);
          const offset = range.getBoundingClientRect().top - el.getBoundingClientRect().top;
          if (scrollToTop) el.dispatchEvent(new Event('scroll'));
          return { text, offset };
        }, [marker, top]);
        const before = await measure(null, true);
        await expect.poll(() => mac.actions.filter(a => a.action === 'earlier').length).toBe(1);
        await expect(page.locator('#find-count')).toHaveText('1 of 61');
        await frames(page);
        const after = await measure(before.text, false);
        expect(Math.abs(after.offset - before.offset)).toBeLessThan(40);
        expect((await findState(page)).shown).toBeGreaterThan(0);
        // The current match went above any window shown so far; Next reaches the one after it.
        await page.getByRole('button', { name: 'Next match' }).click();
        await expect(page.locator('#find-count')).toHaveText('2 of 61');
        await frames(page);
        const start = 'Batch 1 line 1: older needle output.\nBatch 1 line 2: older '.length;
        expect((await findState(page)).current).toEqual({ start, end: start + 6, text: 'needle', visible: true });
      } finally { mac.close(); }
    });
  });
}
