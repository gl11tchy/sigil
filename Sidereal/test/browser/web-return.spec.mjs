import { test, expect } from '@playwright/test';
import { WebSocket } from 'ws';
import { once } from 'node:events';
import { randomKey, importKey, seal, open } from '../../public/crypto.mjs';

test.use({ viewport: { width: 390, height: 844 }, deviceScaleFactor: 1, hasTouch: true, colorScheme: 'dark' });

// Generated Mac state over the actual relay and encryption, with explicitly held replies.
let roomAllocation, previousHost;
async function fixtureMac(page, origin, initiallyHidden = false) {
  if (!roomAllocation) {
    const response = await fetch(`${origin}/rooms`, { method: 'POST' });
    expect(response.status).toBe(201);
    roomAllocation = await response.json();
  }
  if (previousHost && previousHost.readyState !== WebSocket.CLOSED) {
    previousHost.close(); await once(previousHost, 'close');
  }
  const { room, hostToken } = roomAllocation;
  const bootstrap = randomKey(), ticket = randomKey();
  let key = await importKey(bootstrap), peer, challenge, peers = 0, serial = Promise.resolve(), ready;
  let holdState = false, holdInput = false;
  const actions = [], errors = [], held = [];
  const registered = new Promise(resolve => { ready = resolve; });
  const ws = new WebSocket(`${origin.replace(/^http/, 'ws')}/connect?role=host`, { headers: { Authorization: `Bearer ${hostToken}` } });
  previousHost = ws;
  ws.on('message', bytes => {
    serial = serial.then(async () => {
      const frame = JSON.parse(bytes);
      if (frame.route) {
        ws.send(JSON.stringify({ route: await seal({ room, ticket }, await importKey(frame.route), 'relay-host') }));
      } else if (frame.type === 'ready') ready();
      else if (frame.type === 'peer' && frame.peer) {
        peer = frame.peer; peers++; challenge = randomKey();
        ws.send(JSON.stringify({ peer, hello: challenge }));
      } else if (frame.data) {
        const request = await open(frame.data, key, 'phone');
        expect(request.challenge).toBe(challenge);
        actions.push({ action: request.action, text: request.text, tabID: request.tabID });
        if (request.action === 'pair') key = await importKey(request.text);
        const target = peer, responseKey = key;
        const reply = async () => {
          const state = { tabs: [{ id: 'return-fixture', title: 'Review page-return recovery', status: 'idle' }],
            selectedTabID: 'return-fixture', terminal: 'Page-return fixture\n\nGenerated session output.\nReady for your next message.' };
          ws.send(JSON.stringify({ peer: target, data: await seal({ challenge: request.challenge,
            clientNonce: request.clientNonce, sequence: request.sequence, ok: true, ticket, state }, responseKey, 'mac') }));
        };
        if ((request.action === 'state' && holdState) || (request.action === 'input' && holdInput)) held.push({ action: request.action, reply });
        else await reply();
      }
    }).catch(error => errors.push(error));
  });
  await once(ws, 'open'); await registered;
  await page.addInitScript(initiallyHidden => {
    // Advance only the suspension heuristic; never turn a fixture into real device timing evidence.
    window.returnFixtureNow = 100_000;
    window.returnFixtureHidden = initiallyHidden;
    Date.now = () => window.returnFixtureNow;
    Object.defineProperty(document, 'hidden', { configurable: true, get: () => Boolean(window.returnFixtureHidden) });
  }, initiallyHidden);
  await page.goto(`${origin}/#room=${room}&key=${bootstrap}`);
  await expect(page.locator('#status')).toHaveText('Connected');
  return { actions, errors, held, peers: () => peers,
    holdStates() { holdState = true; }, holdInputs() { holdInput = true; },
    async release(action) {
      const at = held.findIndex(item => item.action === action);
      expect(at).toBeGreaterThanOrEqual(0);
      await held.splice(at, 1)[0].reply();
    }, close() { ws.close(); } };
}
async function returnPage(page, elapsed, pageshowFirst = false) {
  await page.evaluate(({ elapsed, pageshowFirst }) => {
    window.returnFixtureHidden = true;
    document.dispatchEvent(new Event('visibilitychange'));
    window.dispatchEvent(new PageTransitionEvent('pagehide', { persisted: true }));
    window.returnFixtureNow += elapsed;
    window.returnFixtureHidden = false;
    if (pageshowFirst) window.dispatchEvent(new PageTransitionEvent('pageshow', { persisted: true }));
    document.dispatchEvent(new Event('visibilitychange'));
    window.dispatchEvent(new PageTransitionEvent('pageshow', { persisted: true }));
  }, { elapsed, pageshowFirst });
}
async function screenshot(page, testInfo, name) {
  const path = testInfo.outputPath(`${name}.png`);
  await page.screenshot({ path });
  await testInfo.attach(name, { path, contentType: 'image/png' });
}

test('REA-1202 short return coalesces events and shows pending freshness at phone size', async ({ page, baseURL }, testInfo) => {
  const mac = await fixtureMac(page, baseURL);
  try {
    await page.locator('#message').fill('Draft kept while refreshing');
    mac.holdStates();
    const before = mac.actions.length;
    await returnPage(page, 1000, true);
    await expect(page.locator('#status')).toHaveText('Refreshing…');
    await expect(page.locator('#status')).toHaveAttribute('data-connected', 'false');
    await expect(page.locator('#send')).toBeDisabled();
    await expect(page.locator('#message')).toBeEditable();
    await expect.poll(() => mac.held.length).toBe(1);
    expect(mac.actions.slice(before).map(item => item.action)).toEqual(['state']);
    await screenshot(page, testInfo, 'short-refreshing');
    await mac.release('state');
    await expect(page.locator('#status')).toHaveText('Connected');
    await expect(page.locator('#send')).toBeEnabled();
    await expect(page.locator('#message')).toHaveValue('Draft kept while refreshing');
    await screenshot(page, testInfo, 'short-refreshed');
    expect(mac.errors).toEqual([]);
  } finally { mac.close(); }
});

test('REA-1202 long return replaces the live socket and waits for current state', async ({ page, baseURL }, testInfo) => {
  const mac = await fixtureMac(page, baseURL);
  try {
    mac.holdStates();
    const before = mac.peers();
    await returnPage(page, 31_000);
    await expect.poll(mac.peers).toBe(before + 1);
    await expect(page.locator('#status')).toHaveText('Refreshing…');
    await expect(page.locator('#status')).toHaveAttribute('data-connected', 'false');
    await expect.poll(() => mac.held.length).toBe(1);
    await screenshot(page, testInfo, 'long-refreshing');
    await mac.release('state');
    await expect(page.locator('#status')).toHaveText('Connected');
    expect(mac.actions.map(item => item.action)).toEqual(['pair', 'state']);
    expect(mac.errors).toEqual([]);
  } finally { mac.close(); }
});

test('REA-1202 long return never repeats an input whose acknowledgement was lost', async ({ page, baseURL }) => {
  const mac = await fixtureMac(page, baseURL);
  try {
    mac.holdInputs();
    await page.locator('#message').fill('Synthetic uncertain input');
    await page.locator('#send').click();
    await expect.poll(() => mac.actions.filter(item => item.action === 'input').length).toBe(1);
    const before = mac.peers();
    await returnPage(page, 31_000);
    await expect.poll(mac.peers).toBe(before + 1);
    await expect(page.locator('#status')).toHaveText('Connected');
    await mac.release('input');
    await expect(page.locator('#message')).toHaveValue('Synthetic uncertain input');
    expect(mac.actions.filter(item => item.action === 'input')).toHaveLength(1);
    expect(mac.actions.some(item => item.action === 'key')).toBe(false);
    expect(mac.errors).toEqual([]);
  } finally { mac.close(); }
});

test('REA-1202 a page opened in the background recovers on its first foreground event', async ({ page, baseURL }) => {
  const mac = await fixtureMac(page, baseURL, true);
  try {
    mac.holdStates();
    const before = mac.peers();
    await page.evaluate(() => {
      window.returnFixtureNow += 31_000;
      window.returnFixtureHidden = false;
      document.dispatchEvent(new Event('visibilitychange'));
      window.dispatchEvent(new PageTransitionEvent('pageshow', { persisted: true }));
    });
    await expect.poll(mac.peers).toBe(before + 1);
    await expect(page.locator('#status')).toHaveText('Refreshing…');
    await expect.poll(() => mac.held.length).toBe(1);
    await mac.release('state');
    await expect(page.locator('#status')).toHaveText('Connected');
    expect(mac.errors).toEqual([]);
  } finally { mac.close(); }
});
