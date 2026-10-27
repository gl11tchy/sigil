import { test, expect } from '@playwright/test';
import { WebSocket } from 'ws';
import { once } from 'node:events';
import { writeFile } from 'node:fs/promises';
import { randomKey, importKey, seal, open } from '../../public/crypto.mjs';

test.use({ viewport: { width: 390, height: 844 }, deviceScaleFactor: 1, hasTouch: true, colorScheme: 'dark' });

// Generated Mac state over the actual relay and encryption, with explicitly held replies.
let roomAllocation, previousHost;
async function fixtureMac(page, origin, initiallyHidden = false, { controlledPolling = false, identities = [] } = {}) {
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
  let phase = 'setup';
  const actions = [], errors = [], held = [];
  const record = (event, request) => {
    if (!controlledPolling) return;
    if (identities.length >= 64) throw new Error('Request identity trace exceeded its bound');
    identities.push({ event, id: request.id, peer: request.peer, sequence: request.sequence,
      action: ['pair', 'state', 'input', 'key'].includes(request.action) ? request.action : 'other', phase: request.phase });
  };
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
        const identity = { id: `${peers}:${request.sequence}`, peer: peers, sequence: request.sequence,
          action: request.action, phase };
        if (controlledPolling) {
          expect(Number.isSafeInteger(identity.sequence) && identity.sequence > 0).toBe(true);
          expect(actions.some(item => item.id === identity.id)).toBe(false);
        }
        actions.push({ ...identity, text: request.text, tabID: request.tabID });
        record('received', identity);
        if (request.action === 'pair') key = await importKey(request.text);
        const target = peer, responseKey = key;
        const reply = async () => {
          const state = { tabs: [{ id: 'return-fixture', title: 'Review page-return recovery', status: 'idle' }],
            selectedTabID: 'return-fixture', terminal: 'Page-return fixture\n\nGenerated session output.\nReady for your next message.' };
          if (controlledPolling) state.terminal += `\n\nFixture state ${identity.id}.`;
          ws.send(JSON.stringify({ peer: target, data: await seal({ challenge: request.challenge,
            clientNonce: request.clientNonce, sequence: request.sequence, ok: true, ticket, state }, responseKey, 'mac') }));
          record('reply-sent', identity);
        };
        if ((request.action === 'state' && holdState) || (request.action === 'input' && holdInput)) {
          held.push({ ...identity, reply }); record('held', identity);
        } else await reply();
      }
    }).catch(error => errors.push(error));
  });
  await once(ws, 'open'); await registered;
  await page.addInitScript(({ initiallyHidden, controlledPolling }) => {
    // Advance only the suspension heuristic; never turn a fixture into real device timing evidence.
    window.returnFixtureNow = 100_000;
    window.returnFixtureHidden = initiallyHidden;
    Date.now = () => window.returnFixtureNow;
    Object.defineProperty(document, 'hidden', { configurable: true, get: () => Boolean(window.returnFixtureHidden) });
    if (!controlledPolling) return;
    // Control only the real app poll callback, not request deadlines, animation
    // frames or assertion timeouts. Source drift fails the poll-count precondition.
    const schedule = window.setTimeout.bind(window), cancel = window.clearTimeout.bind(window);
    const polls = new Map();
    let next = -1, scheduled = 0, fired = 0, cancelled = 0, failures = 0;
    window.setTimeout = (callback, delay, ...args) => {
      if (delay === 1000 && typeof callback === 'function'
          && Function.prototype.toString.call(callback).includes("if (!busy) { try { await request('state'); }")) {
        const id = next--; polls.set(id, () => callback(...args)); scheduled++;
        return id;
      }
      return schedule(callback, delay, ...args);
    };
    window.clearTimeout = id => {
      if (polls.delete(id)) { cancelled++; return; }
      cancel(id);
    };
    window.returnFixturePoll = {
      snapshot: () => ({ pending: [...polls.keys()], scheduled, fired, cancelled, failures }),
      fire() {
        if (polls.size !== 1) throw new Error('Expected exactly one scheduled app poll');
        const [id, callback] = polls.entries().next().value;
        polls.delete(id); fired++;
        // A native timer does not await its callback. The test waits on the
        // authenticated request identity received by the synthetic Mac instead.
        void Promise.resolve(callback()).catch(() => { failures++; });
      },
    };
  }, { initiallyHidden, controlledPolling });
  try {
    await page.goto(`${origin}/#room=${room}&key=${bootstrap}`);
    await expect(page.locator('#status')).toHaveText('Connected');
  } catch (error) { ws.close(); throw error; }
  return { actions, errors, held, peers: () => peers,
    holdStates() { holdState = true; }, holdInputs() { holdInput = true; },
    markPhase(value) { phase = value; record('boundary', { phase }); },
    async releaseRequest(id) {
      const matches = held.filter(item => item.id === id);
      expect(matches).toHaveLength(1);
      const item = held.splice(held.indexOf(matches[0]), 1)[0];
      record('released', item);
      await item.reply();
    },
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

for (const preHidePoll of [false, true]) test(
  'REA-1202 short return coalesces events and shows pending freshness at phone size'
    + (preHidePoll ? ' with an in-flight pre-hide poll' : ''), async ({ page, baseURL }, testInfo) => {
  const identities = [];
  let mac;
  try {
    mac = await fixtureMac(page, baseURL, false, { controlledPolling: true, identities });
    await page.locator('#message').fill('Draft kept while refreshing');
    await expect.poll(async () => (await page.evaluate(() => window.returnFixturePoll.snapshot())).pending.length).toBe(1);
    expect(mac.actions.map(item => item.action)).toEqual(['pair']);
    const pairedSequence = mac.actions[0].sequence;
    mac.holdStates();
    let prior;
    if (preHidePoll) {
      mac.markPhase('pre-hide-poll');
      await page.evaluate(() => window.returnFixturePoll.fire());
      await expect.poll(() => mac.held.length).toBe(1);
      prior = mac.held[0];
      expect({ action: prior.action, phase: prior.phase, sequence: prior.sequence })
        .toEqual({ action: 'state', phase: 'pre-hide-poll', sequence: pairedSequence + 1 });
    } else expect(mac.held).toHaveLength(0);
    const before = mac.actions.length;
    mac.markPhase('return');
    await returnPage(page, 1000, true);
    await expect(page.locator('#status')).toHaveText('Refreshing…');
    await expect(page.locator('#status')).toHaveAttribute('data-connected', 'false');
    await expect(page.locator('#send')).toBeDisabled();
    await expect(page.locator('#message')).toBeEditable();
    if (prior) {
      expect(mac.actions.slice(before)).toEqual([]); // The fresh read queues behind this exact poll.
      expect(mac.held.map(item => item.id)).toEqual([prior.id]);
      await expect(page.locator('#terminal')).not.toContainText(`Fixture state ${prior.id}.`);
      await mac.releaseRequest(prior.id);
      await expect(page.locator('#terminal')).toContainText(`Fixture state ${prior.id}.`);
      // Applying an old poll is observable but cannot establish return freshness.
      await expect(page.locator('#status')).toHaveText('Refreshing…');
      await expect(page.locator('#status')).toHaveAttribute('data-connected', 'false');
      await expect(page.locator('#send')).toBeDisabled();
      await expect(page.locator('#message')).toBeEditable();
    }
    await expect.poll(() => mac.held.length).toBe(1);
    const fresh = mac.held[0];
    expect({ action: fresh.action, phase: fresh.phase, sequence: fresh.sequence })
      .toEqual({ action: 'state', phase: 'return', sequence: (prior?.sequence ?? pairedSequence) + 1 });
    expect(mac.actions.slice(before).map(item => item.action)).toEqual(['state']);
    expect(mac.peers()).toBe(1);
    expect((await page.evaluate(() => window.returnFixturePoll.snapshot())).fired).toBe(Number(preHidePoll));
    await screenshot(page, testInfo, 'short-refreshing');
    await mac.releaseRequest(fresh.id);
    await expect(page.locator('#status')).toHaveText('Connected');
    await expect(page.locator('#send')).toBeEnabled();
    await expect(page.locator('#message')).toHaveValue('Draft kept while refreshing');
    await expect(page.locator('#terminal')).toContainText(`Fixture state ${fresh.id}.`);
    await screenshot(page, testInfo, 'short-refreshed');
    expect(mac.actions.slice(before).map(item => item.action)).toEqual(['state']);
    expect(mac.held).toHaveLength(0);
    expect(identities.filter(item => item.event === 'released').map(item => item.id))
      .toEqual([...(prior ? [prior.id] : []), fresh.id]);
    expect(await page.evaluate(() => window.returnFixturePoll.snapshot()))
      .toMatchObject({ fired: Number(preHidePoll), failures: 0 });
    expect(mac.errors).toEqual([]);
  } finally {
    try {
      const client = await page.evaluate(() => window.returnFixturePoll?.snapshot()).catch(() => ({ unavailable: true }));
      const path = testInfo.outputPath('short-return-identities.json');
      const body = JSON.stringify({ schema: 1, preHidePoll, identities, client,
        held: mac?.held.map(item => ({ id: item.id, peer: item.peer, sequence: item.sequence,
          action: item.action === 'state' ? 'state' : 'other', phase: item.phase })) ?? [],
        errors: mac?.errors.map(error => ({ name: error.name })) ?? [] }, null, 2);
      expect(Buffer.byteLength(body)).toBeLessThanOrEqual(32768);
      await writeFile(path, body, { flag: 'wx', mode: 0o600 });
      await testInfo.attach('short-return-identities', { path, contentType: 'application/json' });
    } finally { mac?.close(); }
  }
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
