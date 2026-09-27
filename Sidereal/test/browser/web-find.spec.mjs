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
// 900 lines of two matches each, which wrap at 390 px and not at 844 px: 1,800 matches.
const sparse = Array.from({ length: 900 }, (_, i) => `line ${String(i).padStart(4, '0')}: needle alpha beta gamma delta epsilon zeta needle`).join('\n');
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
    const visible = range => {
      const rect = range.getBoundingClientRect();
      return rect.bottom > box.top && rect.top < box.bottom && rect.right > box.left && rect.left < box.right;
    };
    const api = typeof Highlight === 'function' && CSS.highlights?.has('find-match');
    const marks = [...terminal.querySelectorAll('mark')].map(mark => { const range = document.createRange(); range.selectNodeContents(mark.firstChild); return { mark, range }; });
    const matches = api ? [...CSS.highlights.get('find-match')] : marks.map(item => item.range);
    const current = api ? [...CSS.highlights.get('find-current')][0] : marks.find(item => item.mark.dataset.current === 'true')?.range;
    const texts = [];
    for (const walker = document.createTreeWalker(terminal, NodeFilter.SHOW_TEXT); walker.nextNode();) texts.push(walker.currentNode.length);
    return {
      api, text, count: document.getElementById('find-count').textContent,
      elements: terminal.querySelectorAll('*').length, longestText: Math.max(0, ...texts),
      shown: matches.length, shownVisible: matches.filter(visible).length,
      current: current ? { ...describe(current), visible: visible(current) } : null,
      lineHeight: parseFloat(getComputedStyle(terminal).lineHeight), height: terminal.clientHeight,
      scrollTop: terminal.scrollTop,
    };
  });
}
// Every match in view against the highlighted ones, from the boxes of all matches. `matches` are
// [start, end] offsets in the text; `far` counts highlights more than a quarter screen out of view.
function coverage(page, matches) {
  return page.evaluate(matches => {
    const terminal = document.getElementById('terminal'), nodes = [], starts = [];
    let total = 0;
    for (const walker = document.createTreeWalker(terminal, NodeFilter.SHOW_TEXT); walker.nextNode(); total += walker.currentNode.length) {
      nodes.push(walker.currentNode); starts.push(total);
    }
    const point = (offset, end) => {
      let low = 0, high = nodes.length - 1;
      while (low < high) {
        const middle = (low + high + 1) >> 1;
        if (end ? starts[middle] < offset : starts[middle] <= offset) low = middle; else high = middle - 1;
      }
      return [nodes[low], offset - starts[low]];
    };
    const api = typeof Highlight === 'function' && CSS.highlights?.has('find-match');
    const ranges = api ? [...CSS.highlights.get('find-match')] : [...terminal.querySelectorAll('mark')].map(mark => {
      const range = document.createRange(); range.selectNodeContents(mark.firstChild); return range;
    });
    const shown = new Set(ranges.map(range => starts[nodes.indexOf(range.startContainer)] + range.startOffset));
    const frame = terminal.getBoundingClientRect(), height = terminal.clientHeight, width = terminal.clientWidth;
    const top = frame.top + terminal.clientTop, left = frame.left + terminal.clientLeft, wide = terminal.scrollWidth > width;
    let visible = 0, missing = 0, far = 0;
    // One range for every match: WebKit updates each live range when the text is replaced.
    const range = document.createRange();
    for (const [start, end] of matches) {
      range.setStart(...point(start, false)); range.setEnd(...point(end, true));
      const box = range.getBoundingClientRect();
      if (box.bottom > top && box.top < top + height && (!wide || (box.right > left && box.left < left + width))) {
        visible++;
        if (!shown.has(start)) missing++;
      }
    }
    for (const range of ranges) {
      const box = range.getBoundingClientRect();
      if (box.bottom < top - height / 2 || box.top > top + 1.5 * height
        || (wide && (box.right < left - width / 2 || box.left > left + 1.5 * width))) far++;
    }
    return { shown: ranges.length, visible, missing, far };
  }, matches);
}
const frames = page => page.evaluate(() => new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve))));
// Milliseconds from a click or a query in the page until the frame after it has painted.
const timed = (page, id, query) => page.evaluate(async ([id, query]) => {
  const start = performance.now(), element = document.getElementById(id);
  if (query === undefined) element.click();
  else { element.value = query; element.dispatchEvent(new Event('input')); }
  await new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)));
  return performance.now() - start;
}, [id, query]);
async function toggleRaw(page) {
  await page.getByLabel('Connection settings').click();
  await page.locator('#raw-toggle').click();
  await page.getByLabel('Connection settings').click();
}

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
        // At most 500 matches in view are highlighted, never every match. In WebKit, text nodes of
        // tens of thousands of characters made each highlighted range slow to paint.
        expect(state.shown).toBeGreaterThan(0);
        expect(state.shown).toBeLessThanOrEqual(500);
        expect(state.shownVisible).toBeGreaterThan(0);
        expect(state.longestText).toBeLessThanOrEqual(4096);
        if (api) {
          expect(state.elements).toBe(0);
          expect(await page.evaluate(() => document.querySelectorAll('*').length)).toBe(nodesBefore);
        } else {
          expect(state.elements).toBe(state.shown);
        }
        expect(state.current).toEqual({ start: 0, end: 1, text: 'a', visible: true });
        // Previous from the first match wraps to the last, outside any window shown so far. In
        // WebKit this took over a second when the output was one text node.
        const wrapTime = await timed(page, 'find-previous');
        await expect(page.locator('#find-count')).toHaveText(`${total} of ${total}`);
        expect(wrapTime).toBeLessThan(400);
        await frames(page);
        const last = count(dense, 'a').at(-1).index;
        const wrapped = await findState(page);
        expect(wrapped.current).toEqual({ start: last, end: last + 1, text: 'a', visible: true });
        expect(wrapped.shownVisible).toBeGreaterThan(0);
        expect(wrapped.shown).toBeLessThanOrEqual(500);
        expect(wrapped.longestText).toBeLessThanOrEqual(4096);
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
        expect(closed.longestText).toBeLessThanOrEqual(4096);
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

    test('Find highlights every match in view and none far from it', async ({ page, baseURL }) => {
      const matches = count(sparse, 'needle').map(match => [match.index, match.index + 6]);
      const mac = await pair(page, baseURL, { terminal: () => sparse });
      try {
        await expect(page.locator('#terminal')).toHaveText(sparse);
        await openFind(page, 'needle');
        await expect(page.locator('#find-count')).toHaveText(`1 of ${matches.length}`);
        for (const at of [0, 0.3, 0.6, 1]) {
          await page.locator('#terminal').evaluate((el, at) => { el.scrollTop = at * (el.scrollHeight - el.clientHeight); }, at);
          await expect.poll(async () => {
            const state = await coverage(page, matches);
            return [state.visible > 0, state.missing, state.far];
          }).toEqual([true, 0, 0]);
        }
      } finally { mac.close(); }
    });

    test('Find highlights only the columns in view on one long raw line', async ({ page, baseURL }) => {
      // One 10,500-character line with 3,000 matches, as raw JSON output can be.
      const line = '{"k":1}'.repeat(1500);
      const matches = count(line, '"').map(match => [match.index, match.index + 1]);
      const mac = await pair(page, baseURL, { terminal: () => line });
      try {
        await expect(page.locator('#terminal')).toHaveText(line);
        await toggleRaw(page);
        await expect(page.locator('#terminal')).toHaveAttribute('data-raw', 'true');
        await page.getByRole('button', { name: 'Find in output' }).click();
        // Every match on the line was highlighted; in WebKit this keystroke took seconds.
        const typeTime = await timed(page, 'find-query', '"');
        await expect(page.locator('#find-count')).toHaveText(`1 of ${matches.length}`);
        expect(typeTime).toBeLessThan(1000);
        const state = await coverage(page, matches);
        expect(state).toMatchObject({ missing: 0, far: 0 });
        expect(state.visible).toBeGreaterThan(0);
        expect(state.shown).toBeLessThan(200);
        // Scrolling along the line moves the highlighted columns with the reader.
        await page.locator('#terminal').evaluate(el => { el.scrollLeft = el.scrollWidth / 2; });
        await expect.poll(async () => {
          const state = await coverage(page, matches);
          return [state.visible > 0, state.missing, state.far];
        }).toEqual([true, 0, 0]);
        // Previous wraps to the end of the line and brings it into view.
        const wrapTime = await timed(page, 'find-previous');
        await expect(page.locator('#find-count')).toHaveText(`${matches.length} of ${matches.length}`);
        expect(wrapTime).toBeLessThan(400);
        await frames(page);
        const [start, end] = matches.at(-1);
        expect((await findState(page)).current).toEqual({ start, end, text: '"', visible: true });
        expect((await coverage(page, matches)).missing).toBe(0);
      } finally { mac.close(); }
    });

    test('Find highlights the matches in view again after a resize or a font change', async ({ page, baseURL }) => {
      const matches = count(sparse, 'needle').map(match => [match.index, match.index + 6]);
      const mac = await pair(page, baseURL, { terminal: () => sparse });
      const covered = async () => { const state = await coverage(page, matches); return state.visible > 0 && state.missing === 0; };
      try {
        await expect(page.locator('#terminal')).toHaveText(sparse);
        // Without scroll anchoring, text that wraps again moves under the reader with no scroll event.
        await page.locator('#terminal').evaluate(el => { el.style.overflowAnchor = 'none'; });
        await openFind(page, 'needle');
        await expect(page.locator('#find-count')).toHaveText(`1 of ${matches.length}`);
        await page.locator('#terminal').evaluate(el => { el.scrollTop = el.scrollHeight / 4; });
        await expect.poll(covered).toBe(true);
        // A font that loads late changes the wrapping under the same scroll offset.
        await page.locator('#terminal').evaluate(el => { el.style.fontSize = '11px'; el.style.lineHeight = '16px'; });
        expect((await coverage(page, matches)).missing).toBeGreaterThan(0);
        // WebKit drops a listener on document.fonts after a collection if nothing else holds it.
        await page.requestGC();
        await page.evaluate(() => document.fonts.dispatchEvent(new Event('loadingdone')));
        await expect.poll(covered).toBe(true);
        for (const size of [{ width: 844, height: 390 }, { width: 1200, height: 844 }]) {
          await page.setViewportSize(size);
          await expect.poll(covered).toBe(true);
        }
      } finally { mac.close(); }
    });

    test('Find measures no boxes for a small scroll and a few dozen for a new screen', async ({ page, baseURL }) => {
      const mac = await pair(page, baseURL, { terminal: () => dense });
      try {
        await expect(page.locator('#terminal')).toHaveText(dense);
        await openFind(page, 'a');
        await expect(page.locator('#find-count')).toHaveText('1 of 31200');
        await frames(page);
        await page.evaluate(() => {
          const measure = Range.prototype.getBoundingClientRect;
          window.findBoxes = 0;
          Range.prototype.getBoundingClientRect = function () { window.findBoxes++; return measure.call(this); };
        });
        const boxes = async operation => {
          await page.evaluate(() => { window.findBoxes = 0; });
          await operation();
          await frames(page);
          return page.evaluate(() => window.findBoxes);
        };
        const scroll = screens => boxes(() => page.locator('#terminal').evaluate((el, screens) => { el.scrollTop += screens * el.clientHeight; }, screens));
        // Each scroll within a quarter screen of the last highlights keeps them and measures nothing.
        expect(await scroll(0.1)).toBe(0);
        expect(await scroll(0.1)).toBe(0);
        // A new screen or a new query costs binary searches, never a pass over 31,200 matches.
        const moved = await scroll(1);
        expect(moved).toBeGreaterThan(0);
        expect(moved).toBeLessThanOrEqual(80);
        await page.getByRole('searchbox', { name: 'Find in output' }).fill('');
        const typed = await boxes(() => page.getByRole('searchbox', { name: 'Find in output' }).fill('a'));
        await expect(page.locator('#find-count')).toHaveText('1 of 31200');
        expect(typed).toBeGreaterThan(0);
        expect(typed).toBeLessThanOrEqual(80);
      } finally { mac.close(); }
    });
  });
}

test('Find paints long output as short text nodes that lay out as one node would', async ({ page, baseURL }) => {
  await page.setViewportSize({ width: 390, height: 844 });
  // Long lines with spaces, with ASCII and no spaces, with no ASCII at all, and mixed.
  const output = ['word '.repeat(1800), 'x'.repeat(8200), '🙂é日本'.repeat(1700), 'ab🙂'.repeat(2400), 'end'].join('\n');
  expect(new TextEncoder().encode(output).length).toBeLessThan(60_000);
  const mac = await pair(page, baseURL, { terminal: () => output });
  try {
    for (const raw of [false, true]) {
      if (raw) await toggleRaw(page);
      await expect(page.locator('#terminal')).toHaveText(raw ? output : readableOutput(output));
      const layout = await page.locator('#terminal').evaluate(el => {
        const text = el.textContent, pieces = [...el.childNodes], ends = [];
        for (let total = 0; ends.length < pieces.length;) ends.push(total += pieces[ends.length].length);
        // The box of the character after each boundary and of the last character.
        const boxes = () => [...ends.slice(0, -1), text.length - 1].map(offset => {
          const nodes = [...el.childNodes], range = document.createRange();
          let node = 0, at = offset;
          while (at >= nodes[node].length) at -= nodes[node++].length;
          range.setStart(nodes[node], at);
          range.setEnd(nodes[node], at + (text.charCodeAt(offset) >> 10 === 0x36 ? 2 : 1));
          const box = range.getBoundingClientRect();
          return [box.top, box.left];
        });
        const chunked = { height: el.scrollHeight, width: el.scrollWidth, boxes: boxes() };
        el.replaceChildren(document.createTextNode(text));
        const single = { height: el.scrollHeight, width: el.scrollWidth, boxes: boxes() };
        el.replaceChildren(...pieces);
        return { text, types: pieces.map(piece => piece.nodeType), ends, chunked, single };
      });
      expect(layout.types.every(type => type === 3)).toBe(true);
      expect(layout.ends.length).toBeGreaterThan(8);
      // The same lines at the same heights. A box may move to the side by one layout unit (1/64 px),
      // which WebKit reports rounded out to a whole pixel.
      expect([layout.chunked.height, layout.chunked.width]).toEqual([layout.single.height, layout.single.width]);
      layout.chunked.boxes.forEach(([top, left], index) => {
        expect(top).toBe(layout.single.boxes[index][0]);
        expect(Math.abs(left - layout.single.boxes[index][1])).toBeLessThanOrEqual(1);
      });
      // Nodes end after a newline or between two ASCII characters, so no glyph or pair is split.
      const ascii = at => layout.text.charCodeAt(at) >= 32 && layout.text.charCodeAt(at) < 127;
      for (const end of layout.ends.slice(0, -1)) expect(layout.text[end - 1] === '\n' || (ascii(end - 1) && ascii(end))).toBe(true);
      // Only the line with no ASCII in it needs a node over 4,096 characters.
      const sizes = layout.ends.map((end, index) => end - (layout.ends[index - 1] ?? 0));
      expect(sizes.filter(size => size > 4096)).toEqual(['🙂é日本'.repeat(1700).length + 1]);
    }
  } finally { mac.close(); }
});
