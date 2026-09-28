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

// What Find shows, read from the page: highlights where the browser has them, and marks without
// them or over complex text. Highlights hold static ranges, measured and read through one range.
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
    const scratch = document.createRange();
    const live = range => { scratch.setStart(range.startContainer, range.startOffset); scratch.setEnd(range.endContainer, range.endOffset); return scratch; };
    const describe = range => ({ start: offset(range.startContainer, range.startOffset), end: offset(range.endContainer, range.endOffset), text: live(range).toString() });
    const box = terminal.getBoundingClientRect();
    const visible = range => {
      const rect = live(range).getBoundingClientRect();
      return rect.bottom > box.top && rect.top < box.bottom && rect.right > box.left && rect.left < box.right;
    };
    // Find registers a highlight only while it has ranges.
    const api = typeof Highlight === 'function' && Boolean(CSS.highlights);
    const marks = [...terminal.querySelectorAll('mark')];
    const over = (first, last) => ({ startContainer: first.firstChild, startOffset: 0, endContainer: last.firstChild, endOffset: last.firstChild.length });
    const matches = [...(CSS.highlights?.get('find-match') ?? []), ...marks.map(mark => over(mark, mark))];
    // A match across two chunks has a mark in each. A marked current match has no highlight.
    const currentMarks = marks.filter(mark => mark.dataset.current === 'true');
    const current = [...(CSS.highlights?.get('find-current') ?? [])][0] ?? (currentMarks.length ? over(currentMarks[0], currentMarks[currentMarks.length - 1]) : undefined);
    const texts = [];
    for (const walker = document.createTreeWalker(terminal, NodeFilter.SHOW_TEXT); walker.nextNode();) texts.push(walker.currentNode.length);
    return {
      api, text, count: document.getElementById('find-count').textContent,
      // Long output is in blocks of whole lines; the elements Find adds are the others.
      blocks: terminal.querySelectorAll(':scope > span').length, elements: terminal.querySelectorAll(':not(:scope > span)').length,
      longestText: Math.max(0, ...texts),
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
    const ranges = [...(CSS.highlights?.get('find-match') ?? []), ...[...terminal.querySelectorAll('mark')].map(mark => (
      { startContainer: mark.firstChild, startOffset: 0, endContainer: mark.firstChild, endOffset: mark.firstChild.length }))];
    const index = new Map(nodes.map((node, at) => [node, at]));
    const shown = new Set(ranges.map(range => starts[index.get(range.startContainer)] + range.startOffset));
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
    for (const shownRange of ranges) {
      range.setStart(shownRange.startContainer, shownRange.startOffset); range.setEnd(shownRange.endContainer, shownRange.endOffset);
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
// The longest frame, in milliseconds, while each of `steps` frames clicks Next or scrolls the
// output by `screens`, and the frame after the last.
const longestFrame = (page, steps, screens) => page.evaluate(async ([steps, screens]) => {
  const terminal = document.getElementById('terminal'), next = document.getElementById('find-next');
  const frame = () => new Promise(resolve => requestAnimationFrame(resolve));
  let last = await frame(), longest = 0;
  for (let step = 0; step <= steps; step++) {
    if (step < steps) { if (screens) terminal.scrollTop += screens * terminal.clientHeight; else next.click(); }
    const now = await frame();
    longest = Math.max(longest, now - last); last = now;
  }
  return longest;
}, [steps, screens]);
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
        const total = count(dense, 'a').length, matches = count(dense, 'a').map(match => [match.index, match.index + 1]);
        expect(total).toBe(31_200);
        await expect(page.locator('#find-count')).toHaveText(`1 of ${total}`);
        const state = await findState(page);
        expect(state.api).toBe(api);
        expect(state.text).toBe(dense);
        // Every match in view is highlighted, and at most 500 out of view, never every match. In
        // WebKit, text nodes of tens of thousands of characters made each highlighted range slow to paint.
        const inView = await coverage(page, matches);
        expect(inView).toMatchObject({ shown: state.shown, missing: 0 });
        expect(inView.visible).toBeGreaterThan(0);
        expect(state.shown - inView.visible).toBeLessThanOrEqual(500);
        expect(state.longestText).toBeLessThanOrEqual(4096);
        // Blocks of whole lines of about 1,024 characters: a mark lays out its block again, not all the text.
        expect(state.blocks).toBeGreaterThan(1);
        expect(state.blocks).toBeLessThanOrEqual(Math.ceil(dense.length / 1024));
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
        const wrappedInView = await coverage(page, matches);
        expect(wrappedInView).toMatchObject({ shown: wrapped.shown, missing: 0 });
        expect(wrappedInView.visible).toBeGreaterThan(0);
        expect(wrapped.shown - wrappedInView.visible).toBeLessThanOrEqual(500);
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

    test('Find marks the match it jumped to while the reader holds a selection', async ({ page, baseURL }) => {
      const matches = count(sparse, 'needle').map(match => [match.index, match.index + 6]);
      const mac = await pair(page, baseURL, { terminal: () => sparse });
      const selected = () => page.evaluate(() => getSelection().toString());
      try {
        await expect(page.locator('#terminal')).toHaveText(sparse);
        await openFind(page, 'needle');
        await expect(page.locator('#find-count')).toHaveText(`1 of ${matches.length}`);
        await frames(page);
        // The first 30 characters, across the first match, which is marked without highlights.
        await page.evaluate(length => {
          const walker = document.createTreeWalker(document.getElementById('terminal'), NodeFilter.SHOW_TEXT);
          const start = walker.nextNode();
          let node = start, at = length;
          while (at > node.length) { at -= node.length; node = walker.nextNode(); }
          getSelection().setBaseAndExtent(start, 0, node, at);
        }, 30);
        expect(await selected()).toBe(sparse.slice(0, 30));
        // Previous wraps to the last match, far from the marks painted so far. The marks waited for
        // the selection to end, so the current match had none. A click takes focus from the search
        // field, as a drag in the output would have.
        await page.getByRole('button', { name: 'Previous match' }).click();
        await expect(page.locator('#find-count')).toHaveText(`${matches.length} of ${matches.length}`);
        const [start, end] = matches.at(-1);
        await expect.poll(async () => (await findState(page)).current).toEqual({ start, end, text: 'needle', visible: true });
        // The jump scrolls at once; the matches around it are highlighted on the next frame.
        await expect.poll(() => coverage(page, matches)).toMatchObject({ missing: 0, far: 0 });
        expect(await selected()).toBe(sparse.slice(0, 30));
        // Back at the top, the text under the selection is marked again and the selection stays.
        await page.locator('#terminal').evaluate(el => { el.scrollTop = 0; });
        await expect.poll(async () => { const state = await coverage(page, matches); return [state.visible > 0, state.missing]; }).toEqual([true, 0]);
        expect(await selected()).toBe(sparse.slice(0, 30));
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

    test('Find paints other matches in accent ink on the tint and fills the current one, highlighted or marked', async ({ page, baseURL, browserName }) => {
      // The Latin lines are highlighted where the browser can; WebKit marks the block with the Hebrew line.
      const text = [...Array.from({ length: 80 }, (_, i) => `plain line ${i} kiwi`), 'שלום עולם kiwi'].join('\n');
      const mac = await pair(page, baseURL, { terminal: () => text });
      try {
        await expect(page.locator('#terminal')).toHaveText(readableOutput(text));
        await openFind(page, 'kiwi');
        await page.getByRole('button', { name: 'Previous match' }).click();
        await expect(page.locator('#find-count')).toHaveText('81 of 81');
        await frames(page);
        for (const colorScheme of ['light', 'dark']) {
          await page.emulateMedia({ colorScheme });
          const styles = await page.evaluate(() => {
            const terminal = document.getElementById('terminal'), probe = document.createElement('span');
            const paint = style => ({ background: style.backgroundColor, color: style.color });
            const color = value => { probe.style.color = value; terminal.append(probe); const resolved = getComputedStyle(probe).color; probe.remove(); return resolved; };
            return {
              other: { background: color('var(--accent-tint)'), color: color('var(--accent-ink)') },
              current: { background: color('var(--accent-fill)'), color: color('var(--on-accent)') },
              highlights: ['find-match', 'find-current'].map(name => paint(getComputedStyle(terminal, `::highlight(${name})`))),
              marks: [...terminal.querySelectorAll('mark')].map(mark => ({ current: mark.dataset.current === 'true', ...paint(getComputedStyle(mark)), ring: getComputedStyle(mark).boxShadow })),
            };
          });
          if (api) expect(styles.highlights, colorScheme).toEqual([styles.other, styles.current]);
          expect(styles.marks.length > 0, colorScheme).toBe(!api || browserName === 'webkit');
          expect(styles.marks.some(mark => mark.current), colorScheme).toBe(!api || browserName === 'webkit');
          for (const { current, ...mark } of styles.marks) expect(mark, colorScheme).toEqual({ ...(current ? styles.current : styles.other), ring: 'none' });
        }
      } finally { mac.close(); }
    });

    test('Find highlights every match in view on dense output, readable and raw, narrow and wide', async ({ page, baseURL }) => {
      // Up to 1,320 matches in view: more than the 500 out of view that are highlighted with them.
      const matches = count(dense, 'a').map(match => [match.index, match.index + 1]);
      const mac = await pair(page, baseURL, { terminal: () => dense });
      const covered = async () => {
        const state = await coverage(page, matches);
        return { inView: state.visible > 0, missing: state.missing, far: state.far, outOfView: state.shown - state.visible };
      };
      try {
        await expect(page.locator('#terminal')).toHaveText(dense);
        await openFind(page, 'a');
        await expect(page.locator('#find-count')).toHaveText(`1 of ${matches.length}`);
        for (const raw of [false, true]) {
          if (raw) await toggleRaw(page);
          await expect(page.locator('#terminal')).toHaveAttribute('data-raw', String(raw));
          for (const size of [{ width: 390, height: 844 }, { width: 1200, height: 844 }]) {
            await page.setViewportSize(size);
            await page.locator('#terminal').evaluate(el => { el.scrollTop = el.scrollHeight / 2; el.scrollLeft = 0; });
            await frames(page);
            // A font that loads late chooses the highlights again for the view as it is now.
            await page.evaluate(() => document.fonts.dispatchEvent(new Event('loadingdone')));
            await frames(page);
            const fresh = await covered();
            expect(fresh).toMatchObject({ inView: true, missing: 0, far: 0 });
            expect(fresh.outOfView).toBeLessThanOrEqual(500);
            // A fifth of a screen down, and across where a raw line is wider than the view.
            await page.locator('#terminal').evaluate(el => { el.scrollTop += el.clientHeight / 5; el.scrollLeft += el.clientWidth / 5; });
            await expect.poll(async () => { const { inView, missing, far } = await covered(); return { inView, missing, far }; })
              .toEqual({ inView: true, missing: 0, far: 0 });
          }
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

    test('Find highlights only the columns in view on a long right-to-left raw line', async ({ page, baseURL, browserName }) => {
      // Hebrew runs right to left, so the first match is at the right end of the line. Columns found
      // as if boxes ran left to right highlighted none in view at either end and every one mid-line.
      // WebKit marks every match on a line this long of complex text at once.
      const whole = api && browserName === 'webkit';
      const line = 'שלום עולם '.repeat(400);
      const matches = count(line, 'שלום').map(match => [match.index, match.index + 4]);
      const mac = await pair(page, baseURL, { terminal: () => line });
      try {
        await expect(page.locator('#terminal')).toHaveText(line);
        await toggleRaw(page);
        await expect(page.locator('#terminal')).toHaveAttribute('data-raw', 'true');
        await page.getByRole('button', { name: 'Find in output' }).click();
        const typeTime = await timed(page, 'find-query', 'שלום');
        await expect(page.locator('#find-count')).toHaveText(`1 of ${matches.length}`);
        expect(typeTime).toBeLessThan(1000);
        await frames(page);
        expect((await findState(page)).current).toEqual({ start: 0, end: 4, text: 'שלום', visible: true });
        for (const at of [0, 0.5, 1]) {
          await page.locator('#terminal').evaluate((el, at) => { el.scrollLeft = at * (el.scrollWidth - el.clientWidth); }, at);
          await expect.poll(async () => {
            const state = await coverage(page, matches);
            return [state.visible > 0, state.missing, whole ? state.shown === matches.length : state.far === 0 && state.shown < 200];
          }).toEqual([true, 0, true]);
        }
        // Previous wraps to the last match, at the left end of the line, and brings it into view.
        const wrapTime = await timed(page, 'find-previous');
        await expect(page.locator('#find-count')).toHaveText(`${matches.length} of ${matches.length}`);
        expect(wrapTime).toBeLessThan(400);
        await frames(page);
        const [start, end] = matches.at(-1);
        expect((await findState(page)).current).toEqual({ start, end, text: 'שלום', visible: true });
        expect(await coverage(page, matches)).toMatchObject({ missing: 0, ...(!whole && { far: 0 }) });
      } finally { mac.close(); }
    });

    test('Find scrolls to the matches on a raw line of 80,000 px with no ASCII words', async ({ page, baseURL }) => {
      // In WebKit, a text node that wide on one line gives empty boxes: Previous did not scroll, and
      // every match on the line was highlighted, which took seconds.
      const line = 'привет мир '.repeat(1000);
      const matches = count(line, 'привет').map(match => [match.index, match.index + 6]);
      const mac = await pair(page, baseURL, { terminal: () => line });
      try {
        await expect(page.locator('#terminal')).toHaveText(line);
        await toggleRaw(page);
        await expect(page.locator('#terminal')).toHaveAttribute('data-raw', 'true');
        expect(await page.locator('#terminal').evaluate(el => el.scrollWidth)).toBeGreaterThan(70_000);
        await page.getByRole('button', { name: 'Find in output' }).click();
        const typeTime = await timed(page, 'find-query', 'привет');
        await expect(page.locator('#find-count')).toHaveText(`1 of ${matches.length}`);
        expect(typeTime).toBeLessThan(1000);
        await frames(page);
        const state = await findState(page);
        expect(state.longestText).toBeLessThanOrEqual(256);
        expect(await coverage(page, matches)).toMatchObject({ missing: 0, far: 0 });
        expect(state.shown).toBeLessThan(200);
        const wrapTime = await timed(page, 'find-previous');
        await expect(page.locator('#find-count')).toHaveText(`${matches.length} of ${matches.length}`);
        expect(wrapTime).toBeLessThan(400);
        await frames(page);
        const [start, end] = matches.at(-1);
        expect((await findState(page)).current).toEqual({ start, end, text: 'привет', visible: true });
        expect(await page.locator('#terminal').evaluate(el => el.scrollLeft)).toBeGreaterThan(70_000);
        expect(await coverage(page, matches)).toMatchObject({ missing: 0, far: 0 });
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

    test('Find makes no range per match, so new output repaints as fast after the reader moves', async ({ page, baseURL }) => {
      let terminal = dense;
      const mac = await pair(page, baseURL, { terminal: () => terminal });
      // The longest frame until the count reads `text`, and the frame after it.
      const repaint = text => page.evaluate(async text => {
        const frame = () => new Promise(resolve => requestAnimationFrame(resolve)), count = document.getElementById('find-count');
        let last = await frame(), longest = 0, settled = 0;
        for (const start = last; settled < 2 && last - start < 10_000;) {
          const now = await frame();
          longest = Math.max(longest, now - last); last = now;
          if (count.textContent === text) settled++;
        }
        return settled < 2 ? Infinity : longest;
      }, text);
      try {
        await expect(page.locator('#terminal')).toHaveText(dense);
        await openFind(page, 'a');
        await expect(page.locator('#find-count')).toHaveText('1 of 31200');
        // Streamed output: every chunk is painted again, before the reader has moved.
        let painted = repaint('1 of 31201');
        terminal = `${dense}\nb a`;
        const fresh = await painted;
        // Every range made from here on is counted. WebKit updates each live range on every change to
        // the text until it is collected: after the reader moved through Find, a poll took 715 ms.
        await page.evaluate(() => {
          const create = Document.prototype.createRange;
          window.findRanges = 0;
          Document.prototype.createRange = function () { window.findRanges++; return create.call(this); };
          window.Range = new Proxy(Range, { construct: (target, args) => { window.findRanges++; return Reflect.construct(target, args); } });
        });
        await page.getByRole('button', { name: 'Previous match' }).click();
        await expect(page.locator('#find-count')).toHaveText('31201 of 31201');
        await page.getByRole('button', { name: 'Next match' }).click();
        await expect(page.locator('#find-count')).toHaveText('1 of 31201');
        await longestFrame(page, 20, 0);
        await expect(page.locator('#find-count')).toHaveText('21 of 31201');
        await longestFrame(page, 20, 1);
        await longestFrame(page, 20, -1);
        expect(await page.evaluate(() => window.findRanges)).toBe(0);
        painted = repaint('21 of 31202');
        terminal = `${dense}\nb a a`;
        const moved = await painted;
        expect(moved).toBeLessThan(Math.max(100, 2 * fresh));
      } finally { mac.close(); }
    });

    // Without highlights every match in view is marked, as the scroll test below times.
    if (api) for (const [script, unit, query, repeat] of [['Arabic', 'السلام عليكم ورحمة الله وبركاته ', 'ال', 3], ['Hebrew', 'שלום עולם את הדבר הזה ', 'ה', 4],
      ['Hindi', 'यह एक परीक्षण है और यह सही है ', 'है', 3], ['Japanese', 'これは私の友達の家の猫の名前です', 'の', 5]]) for (const long of [false, true]) {
      // WebKit marks every match on a line of over 2,048 characters of these scripts at once. Before
      // highlights, a frame there took up to 153 ms, on raw Arabic.
      const most = long ? 160 : 100;
      test(`Find stays under ${most} ms a frame over ${script}${long ? ' on long lines' : ''}, readable and raw`, async ({ page, baseURL }) => {
        // A change to a highlight paints every highlighted range in view again: in WebKit a tenth to
        // half a millisecond a range over these scripts, and two to three times that with a text color.
        // Lines of about 90 or 2,200 characters, under one sealed message's 64 KB.
        const line = unit.repeat(long ? Math.ceil(2200 / unit.length) : repeat), lines = Math.floor(58_000 / (new TextEncoder().encode(line).length + 1));
        const text = Array.from({ length: lines }, () => line).join('\n');
        const mac = await pair(page, baseURL, { terminal: () => text });
        try {
          await page.setViewportSize({ width: 1280, height: 844 });
          const times = [];
          for (const raw of [false, true]) {
            const shown = raw ? text : readableOutput(text);
            if (raw) await toggleRaw(page);
            await expect(page.locator('#terminal')).toHaveText(shown);
            if (!raw) await openFind(page, query);
            await expect(page.locator('#find-count')).toHaveText(new RegExp(` of ${count(shown, query).length}$`));
            await frames(page);
            times.push({ raw, next: Math.round(await longestFrame(page, 3, 0)), scrolled: Math.round(await longestFrame(page, 12, 1 / 4)) });
          }
          expect(times.filter(time => time.next >= most || time.scrolled >= most)).toEqual([]);
        } finally { mac.close(); }
      });
    }

    // In WebKit a match inside a grapheme cluster, as 'है' in 'हैं', is marked with the whole cluster.
    // When that sent every match in view to highlights, a frame took over 50 ms. Chromium highlights
    // every match, over any text, as the tests above time.
    if (api) test('Find stays under 50 ms a frame when Hindi matches fall inside clusters', async ({ page, baseURL, browserName }) => {
      test.skip(browserName !== 'webkit', 'Only WebKit marks matches');
      const line = 'यह एक परीक्षण है और वे सही हैं '.repeat(3), lines = Math.floor(58_000 / (new TextEncoder().encode(line).length + 1));
      const text = Array.from({ length: lines }, () => line).join('\n'), shown = readableOutput(text);
      const mac = await pair(page, baseURL, { terminal: () => text });
      try {
        await page.setViewportSize({ width: 1280, height: 844 });
        await expect(page.locator('#terminal')).toHaveText(shown);
        await openFind(page, 'है');
        await expect(page.locator('#find-count')).toHaveText(`1 of ${count(shown, 'है').length}`);
        await frames(page);
        const times = { next: Math.round(await longestFrame(page, 6, 0)), scrolled: Math.round(await longestFrame(page, 12, 1 / 4)) };
        expect(Object.values(times).filter(time => time >= 50), JSON.stringify(times)).toEqual([]);
        expect(await page.locator('#terminal').evaluate(el => el.textContent)).toBe(shown);
      } finally { mac.close(); }
    });

    test('Find paints again only the chunks whose marks change as the reader scrolls', async ({ page, baseURL }) => {
      const mac = await pair(page, baseURL, { terminal: () => dense });
      try {
        await expect(page.locator('#terminal')).toHaveText(dense);
        await openFind(page, 'a');
        await expect(page.locator('#find-count')).toHaveText('1 of 31200');
        await frames(page);
        // Painting all of the output for each new window took over 50 ms in a third of the frames
        // of a scroll in WebKit. The last chunk, never near the view, stays the same node.
        const last = await page.locator('#terminal').evaluateHandle(el => el.lastChild);
        const scrolled = await longestFrame(page, 16, 1 / 2);
        expect(await page.locator('#terminal').evaluate(el => el.scrollTop)).toBeGreaterThan(0);
        expect(await last.evaluate(node => node.isConnected)).toBe(true);
        expect(scrolled).toBeLessThan(100);
        await expect.poll(async () => { const state = await coverage(page, count(dense, 'a').map(match => [match.index, match.index + 1])); return [state.visible > 0, state.missing, state.far]; })
          .toEqual([true, 0, 0]);
      } finally { mac.close(); }
    });

    // A new mark lays out its block again. In one inline run of all 400,000 characters kept, each
    // new window laid out all of them: over 50 ms a frame in WebKit.
    if (!api) test('Find scrolls 400,000 characters of marks a screen a frame in under 50 ms', async ({ page, baseURL }) => {
      test.setTimeout(120_000);
      // 34 slices of 11,900 characters, each under the 12 KB a slice may hold.
      const slice = name => Array.from({ length: 150 }, (_, i) => `${name} line ${String(i).padStart(4, '0')}: alpha verified project output with trace details and data.`)
        .join('\n').slice(0, 11_899) + '\n';
      let slices = 0;
      const tail = slice('TAIL');
      const mac = await pair(page, baseURL, { terminal: () => tail, earlier: () => slices < 33 ? slice(`HISTORY-${++slices}`) : '' });
      try {
        await expect(page.locator('#terminal')).toHaveText(tail);
        // Each scroll to the top loads one earlier slice, paced under the relay's 30 messages a second.
        for (let loaded = tail.length; slices < 33;) {
          await page.waitForTimeout(100);
          await page.locator('#terminal').evaluate(el => { el.scrollTop = 0; el.dispatchEvent(new Event('scroll')); });
          await page.waitForFunction(length => document.getElementById('terminal').textContent.length > length, loaded);
          loaded = await page.locator('#terminal').evaluate(el => el.textContent.length);
        }
        const text = await page.locator('#terminal').evaluate(el => el.textContent);
        expect(text.length).toBeGreaterThan(400_000);
        await openFind(page, 'a');
        await expect(page.locator('#find-count')).toHaveText(`1 of ${count(text, 'a').length}`);
        await page.locator('#terminal').evaluate(el => { el.scrollTop = el.scrollHeight / 3; });
        await frames(page);
        const scrolled = await longestFrame(page, 60, 1);
        expect(scrolled).toBeLessThan(50);
        await expect.poll(async () => { const state = await coverage(page, count(text, 'a').map(match => [match.index, match.index + 1])); return [state.visible > 0, state.missing, state.far]; })
          .toEqual([true, 0, 0]);
      } finally { mac.close(); }
    });
  });
}

test('Find paints long output as short text nodes that lay out as one node would', async ({ page, baseURL }) => {
  await page.setViewportSize({ width: 390, height: 844 });
  // Long lines with spaces, with ASCII and no spaces, with no ASCII at all, and mixed; Cyrillic and
  // Hebrew words; a combining mark after each space; emoji joined into one cluster; short and blank lines.
  const short = Array.from({ length: 120 }, (_, i) => i % 7 ? `line ${i}: ${'ab '.repeat(i % 25)}` : '').join('\n');
  const output = ['word '.repeat(600), 'x'.repeat(3000), short, '🙂é日本'.repeat(600), 'ab🙂'.repeat(750), 'привет мир '.repeat(300),
    'שלום עולם '.repeat(300), short, 'ж \u0301'.repeat(1000), '👩\u200d💻'.repeat(700), 'end'].join('\n');
  expect(new TextEncoder().encode(output).length).toBeLessThan(60_000);
  const mac = await pair(page, baseURL, { terminal: () => output });
  try {
    for (const raw of [false, true]) {
      if (raw) await toggleRaw(page);
      await expect(page.locator('#terminal')).toHaveText(raw ? output : readableOutput(output));
      const layout = await page.locator('#terminal').evaluate(el => {
        const text = el.textContent, children = [...el.childNodes], pieces = [], ends = [];
        for (const walker = document.createTreeWalker(el, NodeFilter.SHOW_TEXT); walker.nextNode();) pieces.push(walker.currentNode);
        for (let total = 0; ends.length < pieces.length;) ends.push(total += pieces[ends.length].length);
        // The box of the character after each boundary and of the last character.
        const boxes = nodes => [...ends.slice(0, -1), text.length - 1].map(offset => {
          const range = document.createRange();
          let node = 0, at = offset;
          while (at >= nodes[node].length) at -= nodes[node++].length;
          range.setStart(nodes[node], at);
          range.setEnd(nodes[node], at + (text.charCodeAt(offset) >> 10 === 0x36 ? 2 : 1));
          const box = range.getBoundingClientRect();
          return [box.top, box.left];
        });
        getSelection().selectAllChildren(el);
        const copied = getSelection().toString();
        getSelection().removeAllRanges();
        // Block elements of text nodes, then the text nodes of the last block.
        const elements = children.filter(child => child.nodeType === 1), tail = children.slice(elements.length);
        const blocks = [...elements.map(child => ({ text: child.textContent,
          block: child.localName === 'span' && getComputedStyle(child).display === 'block' && [...child.childNodes].every(node => node.nodeType === 3) })),
        { text: tail.map(node => node.textContent).join(''), block: tail.length > 0 && tail.every(node => node.nodeType === 3) }];
        const chunked = { height: el.scrollHeight, width: el.scrollWidth, boxes: boxes(pieces) };
        el.replaceChildren(document.createTextNode(text));
        const single = { height: el.scrollHeight, width: el.scrollWidth, boxes: boxes([el.firstChild]) };
        el.replaceChildren(...children);
        return { text, copied, blocks, ends, chunked, single };
      });
      // The text nodes are in blocks of whole lines, the last in the terminal itself: each ends after a
      // line feed, and holds one line or under 2,048 characters. A selection copies the text as it came.
      expect(layout.blocks.length).toBeGreaterThan(8);
      expect(layout.blocks.filter(block => !block.block)).toEqual([]);
      expect(layout.blocks.slice(0, -1).filter(block => !block.text.endsWith('\n'))).toEqual([]);
      expect(layout.blocks.filter(block => block.text.length >= 2048 && block.text.slice(0, -1).includes('\n'))).toEqual([]);
      expect(layout.blocks.filter(block => block.text.slice(0, -1).includes('\n')).length).toBeGreaterThan(0);
      expect(layout.copied).toBe(layout.text);
      expect(layout.ends.length).toBeGreaterThan(8);
      // The same lines at the same heights, to a layout unit (1/64 px). A box, or the widest line, may
      // move to the side by one layout unit where glyph advances add up in another order, rounded out
      // to a pixel.
      expect(layout.chunked.height).toBe(layout.single.height);
      expect(Math.abs(layout.chunked.width - layout.single.width)).toBeLessThanOrEqual(1);
      // WebKit lays out a mark after a space wider than it paints it, so a long line of them shows a
      // gap after each node; only the heights of that line's boxes are compared.
      const line = at => layout.text.slice(layout.text.lastIndexOf('\n', at - 1) + 1);
      const offsets = [...layout.ends.slice(0, -1), layout.text.length - 1];
      layout.chunked.boxes.forEach(([top, left], index) => {
        expect(top).toBeCloseTo(layout.single.boxes[index][0], 1);
        if (!line(offsets[index]).startsWith('ж')) expect(Math.abs(left - layout.single.boxes[index][1])).toBeLessThanOrEqual(1);
      });
      // Nodes end where a grapheme cluster starts, so no glyph is split, and none is over 256
      // characters: in WebKit a box in a longer run of non-ASCII text on one line costs milliseconds.
      const clusters = new Set([...new Intl.Segmenter(undefined, { granularity: 'grapheme' }).segment(layout.text)].map(part => part.index));
      expect(layout.ends.slice(0, -1).filter(end => !clusters.has(end))).toEqual([]);
      const sizes = layout.ends.map((end, index) => end - (layout.ends[index - 1] ?? 0));
      expect(Math.max(...sizes)).toBeLessThanOrEqual(256);
      // A line with spaces or ASCII pairs is split only there, and never between a space and its mark.
      const ascii = at => layout.text.charCodeAt(at) >= 32 && layout.text.charCodeAt(at) < 127;
      for (const end of layout.ends.slice(0, -1)) {
        if (['word', 'x', 'ab', 'привет', 'שלום'].some(start => line(end).startsWith(start))) {
          expect(layout.text[end - 1] === '\n' || layout.text[end - 1] === ' ' || (ascii(end - 1) && ascii(end))).toBe(true);
        }
        if (line(end).startsWith('ж')) expect(layout.text[end - 1]).not.toBe(' ');
      }
    }
  } finally { mac.close(); }
});
