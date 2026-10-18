import { test, expect } from '@playwright/test';
import { WebSocket } from 'ws';
import { once } from 'node:events';
import { randomKey, importKey, seal, open } from '../../public/crypto.mjs';

// A synthetic Mac over the actual relay and encryption that takes a fixed time per request.
// Never touches user sessions.
const DELAY = 600;
let sharedRoom, previousHost;
async function slowMac(page, origin, options = {}) {
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
  let key = await importKey(bootstrap), selected = 'one', peer, challenge, serial = Promise.resolve(), ready, ws;
  const actions = [], errors = [];
  page.on('pageerror', error => errors.push(error));
  const registered = new Promise(resolve => { ready = resolve; });
  const tabs = [{ id: 'one', title: 'Alphaworkflow review', status: 'idle' }, { id: 'two', title: 'Alphaworkflow release', status: 'idle' }];
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
        expect(request.challenge).toBe(challenge);
        actions.push({ action: request.action, text: request.text, tabID: request.tabID, sequence: request.sequence,
          index: request.index, name: request.name, provider: request.provider });
        if (request.action === 'pair') key = await importKey(request.text);
        await new Promise(resolve => setTimeout(resolve, options.delay ?? DELAY));
        if (request.action === 'select') selected = request.tabID;
        const payload = { challenge, sequence: request.sequence, clientNonce: request.clientNonce, ok: true, ticket,
          state: { tabs, selectedTabID: selected, terminal: `Session ${selected}\nReady.`, mac: 'synthetic-mac', capabilities: options.capabilities ?? ['sessionOps'] } };
        if (request.action === 'chats') {
          Object.assign(payload, options.chats ? options.chats(request)
            : { chats: Array.from({ length: 3 }, (_, i) => ({ id: `chat-${i}`, title: `${request.text} saved ${i}`, folder: '/tmp/fixture' })) });
        }
        ws.send(JSON.stringify({ peer, data: await seal(payload, key, 'mac') }));
      }
    }).catch(error => errors.push(error));
  };
  for (let attempt = 0; ; attempt++) {
    ws = new WebSocket(`${origin.replace(/^http/, 'ws')}/connect?role=host`, { headers: { Authorization: `Bearer ${hostToken}` } });
    ws.on('message', onMessage);
    try { await once(ws, 'open'); break; }
    catch (error) { if (attempt >= 9) throw error; await new Promise(resolve => setTimeout(resolve, 100)); }
  }
  previousHost = ws;
  await registered;
  try {
    await page.goto(`${origin}/#room=${room}&key=${bootstrap}`);
    await expect(page.locator('#status')).toHaveText('Connected');
  } catch (error) {
    ws.close();
    throw new Error(`${error.message}; synthetic actions=${actions.map(item => item.action)}; errors=${errors.map(item => item.message)}`);
  }
  return { actions, errors, close: () => ws.close() };
}
const searches = actions => actions.filter(item => item.action === 'chats');
const queries = actions => searches(actions).filter(item => item.text);

test('opening Chats shows recent saved conversations before typing', async ({ page, baseURL }, testInfo) => {
  await page.setViewportSize({ width: 390, height: 844 });
  const mac = await slowMac(page, baseURL, { chats: () => ({ chats: [
    { id: 'release', title: 'Release checklist', folder: '/tmp/fixture/sigil' },
    { id: 'search', title: 'Search navigation follow-up', folder: '/tmp/fixture/sigil' },
    { id: 'phone', title: 'Phone reconnect test', folder: '/tmp/fixture/companion' },
  ] }) });
  try {
    await page.getByRole('button', { name: 'Browse open and saved chats' }).click();
    await expect(page.locator('#saved-heading')).toHaveText('Recent chats');
    await expect(page.locator('#saved-list button')).toHaveCount(3);
    expect(searches(mac.actions).map(item => item.text)).toEqual(['']);
    expect(mac.errors).toEqual([]);
  } finally {
    const path = testInfo.outputPath('recent-chats-390x844.png');
    await page.screenshot({ path });
    await testInfo.attach('Recent chats at 390×844', { path, contentType: 'image/png' });
    mac.close();
  }
});

test('recent paging, search and clearing keep stable identities and open the selected saved chat', async ({ page, baseURL }) => {
  await page.setViewportSize({ width: 390, height: 844 });
  const row = i => ({ id: `recent-${i}`, title: `Recent conversation ${i}`, folder: '/tmp/fixture', provider: 'grokBuild' });
  const mac = await slowMac(page, baseURL, { delay: 100, chats: request => ({ chats: request.text
    ? [{ id: 'match', title: `${request.text} match`, folder: '/tmp/fixture', provider: 'claudeCode' }]
    : request.index ? [row(39), row(40), row(41), row(42)] : Array.from({ length: 40 }, (_, i) => row(i)) }) });
  try {
    await page.getByRole('button', { name: 'Browse open and saved chats' }).click();
    await expect(page.locator('#saved-heading')).toHaveText('Recent chats');
    await expect(page.locator('#saved-list button')).toHaveCount(41);
    await page.locator('#saved-list button').filter({ hasText: 'Show more' }).click();
    await expect(page.locator('#saved-list button')).toHaveCount(43);
    expect(searches(mac.actions).map(item => item.index ?? 0)).toEqual([0, 40]);
    await expect(page.locator('#saved-list button').filter({ hasText: 'Show more' })).toHaveCount(0);
    await page.locator('#session-search').fill('parser');
    await expect(page.locator('#saved-heading')).toHaveText('Saved chats');
    await expect(page.locator('#saved-list button')).toHaveCount(1);
    await expect(page.locator('#saved-list')).toContainText('parser match');
    await page.locator('#session-search').fill('');
    await expect(page.locator('#saved-heading')).toHaveText('Recent chats');
    await expect(page.locator('#saved-list button')).toHaveCount(41);
    await page.locator('#saved-list button').first().click();
    await expect(page.locator('#sessions-dialog')).toBeHidden();
    expect(mac.actions.find(item => item.action === 'open')).toMatchObject({ name: 'recent-0', text: '/tmp/fixture', provider: 'grokBuild' });
    expect(mac.errors).toEqual([]);
  } finally { mac.close(); }
});

test('a host without the indexed-list contract exposes only its bounded first page', async ({ page, baseURL }) => {
  await page.setViewportSize({ width: 390, height: 844 });
  const mac = await slowMac(page, baseURL, { delay: 100, capabilities: [], chats: () => ({
    chats: Array.from({ length: 80 }, (_, i) => ({ id: `old-${i}`, title: `Older saved chat ${i}`, folder: '/tmp/fixture' })),
  }) });
  try {
    await page.getByRole('button', { name: 'Browse open and saved chats' }).click();
    await expect(page.locator('#saved-list button')).toHaveCount(40);
    await expect(page.locator('#saved-list button').filter({ hasText: 'Show more' })).toHaveCount(0);
    expect(searches(mac.actions)).toHaveLength(1);
    await expect(page.locator('#sessions-error')).toBeHidden();
    expect(mac.errors).toEqual([]);
  } finally { mac.close(); }
});

test('an older Mac that does not know chats keeps the saved section unavailable without an error', async ({ page, baseURL }) => {
  await page.setViewportSize({ width: 390, height: 844 });
  const mac = await slowMac(page, baseURL, { delay: 100, capabilities: [], chats: () => ({ ok: false, error: 'Unknown action.' }) });
  try {
    await page.getByRole('button', { name: 'Browse open and saved chats' }).click();
    await expect.poll(() => searches(mac.actions).length).toBe(1);
    await expect(page.locator('#saved-heading')).toBeHidden();
    await expect(page.locator('#saved-list button')).toHaveCount(0);
    await expect(page.locator('#sessions-error')).toBeHidden();
    await expect(page.locator('#error')).toBeHidden();
    expect(mac.errors).toEqual([]);
  } finally { mac.close(); }
});

test('typing faster than the Mac answers sends few searches and shows only the final result', async ({ page, baseURL }) => {
  await page.setViewportSize({ width: 390, height: 844 });
  const mac = await slowMac(page, baseURL);
  try {
    await page.getByRole('button', { name: 'Browse open and saved chats' }).click();
    await expect(page.locator('#saved-list button')).toHaveCount(3);
    await page.evaluate(() => {
      globalThis.shownSearches = [];
      new MutationObserver(() => {
        const first = document.querySelector('#saved-list button span');
        if (first) globalThis.shownSearches.push(first.textContent);
      }).observe(document.getElementById('saved-list'), { childList: true });
    });
    await page.locator('#session-search').pressSequentially('a');
    await expect.poll(() => queries(mac.actions)[0]?.text).toBe('a');
    await page.locator('#session-search').pressSequentially('lphaworkflow', { delay: 25 });
    await expect(page.locator('#saved-list button')).toHaveCount(3);
    await expect(page.locator('#saved-list button').first()).toContainText('alphaworkflow saved 0');
    const sent = queries(mac.actions);
    expect(sent.length).toBeLessThanOrEqual(3);
    expect(sent[0].text).toBe('a');
    expect(sent.at(-1).text).toBe('alphaworkflow');
    expect(await page.evaluate(() => globalThis.shownSearches)).toEqual(['alphaworkflow saved 0']);
    // Every request still carries the next sequence number under the Mac's challenge.
    const sequences = mac.actions.map(item => item.sequence);
    expect(sequences).toEqual(sequences.map((_, index) => sequences[0] + index));
    await expect(page.locator('#error')).toBeHidden();
    expect(mac.errors).toEqual([]);
  } finally { mac.close(); }
});

test('a session picked right after typing is not held behind obsolete searches', async ({ page, baseURL }) => {
  await page.setViewportSize({ width: 390, height: 844 });
  const mac = await slowMac(page, baseURL);
  try {
    await page.getByRole('button', { name: 'Browse open and saved chats' }).click();
    await expect(page.locator('#saved-list button')).toHaveCount(3);
    await page.locator('#session-search').pressSequentially('alphaworkflow', { delay: 25 });
    await page.locator('#session-list button', { hasText: 'Alphaworkflow release' }).click();
    await expect(page.locator('#sessions-dialog')).toBeHidden();
    await expect(page.locator('#tabs')).toHaveValue('two');
    await expect(page.locator('#terminal')).toContainText('Session two');
    const at = mac.actions.findIndex(item => item.action === 'select');
    expect(mac.actions[at].tabID).toBe('two');
    expect(queries(mac.actions.slice(0, at)).length).toBeLessThanOrEqual(3);
    expect(queries(mac.actions.slice(0, at)).at(-1).text).toBe('alphaworkflow');
    expect(mac.errors).toEqual([]);
  } finally { mac.close(); }
});

test('a key pressed after the Chats sheet closes never waits for the query left in it', async ({ page, baseURL }) => {
  await page.setViewportSize({ width: 390, height: 844 });
  const mac = await slowMac(page, baseURL);
  try {
    await page.getByRole('button', { name: 'Terminal keys' }).click();
    await page.getByRole('button', { name: 'Browse open and saved chats' }).click();
    await expect(page.locator('#saved-list button')).toHaveCount(3);
    // The first key goes out; the rest wait behind it until the sheet closes.
    await page.locator('#session-search').pressSequentially('a');
    await expect.poll(() => queries(mac.actions)[0]?.text).toBe('a');
    await page.locator('#session-search').pressSequentially('lpha');
    await page.locator('#sessions-close').click();
    await expect(page.locator('#sessions-dialog')).toBeHidden();
    await page.getByRole('button', { name: 'Stop current response' }).click();
    await expect.poll(() => mac.actions.some(item => item.action === 'key')).toBe(true);
    const at = mac.actions.findIndex(item => item.action === 'key');
    expect(queries(mac.actions.slice(0, at)).map(item => item.text)).toEqual(['a']);
    await expect(page.locator('#error')).toBeHidden();
    expect(mac.errors).toEqual([]);
  } finally { mac.close(); }
});
