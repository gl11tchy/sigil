import { test, expect } from '@playwright/test';
import { WebSocket } from 'ws';
import { once } from 'node:events';
import { randomKey, importKey, seal, open } from '../../public/crypto.mjs';

// A synthetic Mac, using the actual relay and encryption. Never touches user sessions.
async function pair(page, origin) {
  const allocation = await fetch(`${origin}/rooms`, { method: 'POST' });
  expect(allocation.status).toBe(201);
  const { room, hostToken } = await allocation.json();
  const bootstrap = randomKey();
  let key = await importKey(bootstrap), selected = 'one', peer, challenge, serial = Promise.resolve();
  const actions = [], errors = [];
  const terminal = title => `${title}\n\n${Array.from({ length: 35 }, (_, i) => `Line ${i + 1}: Verified the mobile layout and terminal output.`).join('\n')}\n\nReady for your next message.`;
  const outputs = { one: terminal('Mobile layout review'), two: terminal('Release checks') };
  const ws = new WebSocket(`${origin.replace(/^http/, 'ws')}/connect?room=${room}&role=host`, { headers: { Authorization: `Bearer ${hostToken}` } });
  ws.on('message', bytes => {
    serial = serial.then(async () => {
      const frame = JSON.parse(bytes);
      if (frame.type === 'peer') {
        peer = frame.peer; challenge = randomKey();
        ws.send(JSON.stringify({ peer, hello: challenge }));
      } else if (frame.data) {
        const request = await open(frame.data, key, 'phone');
        expect(request.challenge).toBe(challenge);
        actions.push(request);
        if (request.action === 'pair') key = await importKey(request.text);
        if (request.action === 'select') selected = request.tabID;
        if (request.action === 'new') selected = 'two';
        if (request.action === 'input') outputs[selected] += `\n\nYou: ${request.text}`;
        ws.send(JSON.stringify({ peer, data: await seal({ challenge, sequence: request.sequence, ok: true,
          state: { tabs: [{ id: 'one', title: 'Mobile layout review', status: 'working' },
            { id: 'two', title: 'Release checks', status: 'idle' }], selectedTabID: selected, terminal: outputs[selected] },
        }, key, 'mac') }));
      }
    }).catch(error => errors.push(error));
  });
  await once(ws, 'open');
  await page.goto(`${origin}/#room=${room}&key=${bootstrap}`);
  await expect(page.locator('#status')).toHaveText('Connected');
  return { actions, errors, close: () => ws.close() };
}

for (const width of [320, 390, 768, 1280]) {
  test(`reading and sending fit the ${width}px viewport`, async ({ page, baseURL }, testInfo) => {
    await page.setViewportSize({ width, height: width === 320 ? 568 : 844 });
    const consoleErrors = [];
    page.on('pageerror', error => consoleErrors.push(error.message));
    const mac = await pair(page, baseURL);
    try {
      await page.screenshot({ path: testInfo.outputPath('connected.png') });
      const geometry = await page.evaluate(() => {
        const rect = id => document.getElementById(id).getBoundingClientRect().toJSON();
        return { send: rect('send'), terminal: rect('terminal'), height: innerHeight,
          width: innerWidth, pageHeight: document.documentElement.scrollHeight,
          pageWidth: document.documentElement.scrollWidth, font: parseFloat(getComputedStyle(document.getElementById('terminal')).fontSize) };
      });
      expect(geometry.pageHeight).toBeLessThanOrEqual(geometry.height + 1);
      expect(geometry.pageWidth).toBeLessThanOrEqual(geometry.width);
      expect(geometry.send.bottom).toBeLessThanOrEqual(geometry.height);
      expect(geometry.terminal.height).toBeGreaterThan(geometry.height * .5);
      expect(geometry.font).toBeGreaterThanOrEqual(14);
      expect((await page.locator('#tabs').boundingBox()).height).toBeGreaterThanOrEqual(44);
      await page.locator('#message').fill('Check the mobile composer');
      await page.locator('#send').click();
      await expect(page.locator('#message')).toHaveValue('');
      await expect.poll(() => mac.actions.filter(a => a.action === 'key' && a.text === 'enter').length).toBe(1);
      await page.locator('#tabs').selectOption('two');
      await expect(page.locator('#terminal')).toContainText('Release checks');
      await page.locator('#keys-toggle').click();
      await expect(page.locator('#keys')).toBeVisible();
      await expect(page.locator('#latest')).toBeHidden();
      await page.getByRole('button', { name: 'Up arrow', exact: true }).click();
      await expect.poll(() => mac.actions.filter(a => a.text === 'up').length).toBe(1);
      await page.screenshot({ path: testInfo.outputPath('keys.png') });
      expect(mac.errors).toEqual([]);
      expect(consoleErrors).toEqual([]);
    } finally { mac.close(); }
  });
}

test('drafts, history position, and a keyboard-sized viewport stay usable', async ({ page, baseURL }, testInfo) => {
  await page.setViewportSize({ width: 390, height: 844 });
  const mac = await pair(page, baseURL);
  try {
    await page.locator('#message').fill('Draft for the first session');
    await page.locator('#tabs').selectOption('two');
    await expect(page.locator('#message')).toHaveValue('');
    await page.locator('#message').fill('Draft for the second session');
    await page.locator('#tabs').selectOption('one');
    await expect(page.locator('#message')).toHaveValue('Draft for the first session');
    await page.locator('#terminal').evaluate(el => { el.scrollTop = 0; el.dispatchEvent(new Event('scroll')); });
    await expect(page.locator('#latest')).toBeVisible();
    await expect.poll(() => mac.actions.filter(a => a.action === 'state').length).toBeGreaterThan(0);
    expect(await page.locator('#terminal').evaluate(el => el.scrollTop)).toBe(0);
    await page.locator('#latest').click();
    await expect(page.locator('#latest')).toBeHidden();
    await page.locator('#message').focus();
    await page.setViewportSize({ width: 390, height: 380 });
    await expect.poll(async () => {
      const send = await page.locator('#send').boundingBox();
      return send.y + send.height;
    }).toBeLessThanOrEqual(380);
    expect((await page.locator('#terminal').boundingBox()).height).toBeGreaterThan(100);
    await page.screenshot({ path: testInfo.outputPath('keyboard-height.png') });
    mac.close();
    await expect(page.locator('#status')).not.toHaveText('Connected');
    await expect(page.locator('#send')).toBeDisabled();
    await expect(page.locator('#message')).toBeEditable();
    await expect(page.locator('#message')).toHaveValue('Draft for the first session');
  } finally { mac.close(); }
});

test('the visual viewport keeps the composer above an on-screen keyboard', async ({ page, baseURL }, testInfo) => {
  await page.setViewportSize({ width: 390, height: 844 });
  // Desktop browser runners cannot open an OS keyboard. Model its visual-only resize.
  await page.addInitScript(() => {
    const viewport = Object.assign(new EventTarget(), { height: 844, offsetTop: 0, scale: 1 });
    Object.defineProperty(window, 'visualViewport', { value: viewport });
  });
  const mac = await pair(page, baseURL);
  try {
    await page.locator('#message').fill('A message with the keyboard open');
    await page.locator('#message').focus();
    await page.evaluate(() => {
      Object.assign(visualViewport, { height: 390, offsetTop: 20 });
      visualViewport.dispatchEvent(new Event('resize'));
      visualViewport.dispatchEvent(new Event('scroll'));
    });
    await page.locator('#message').fill('A multiline draft\n'.repeat(12));
    const form = await page.locator('#compose').boundingBox();
    expect(form.y + form.height).toBeLessThanOrEqual(410);
    await expect(page.locator('#message')).toBeFocused();
    expect((await page.locator('#terminal').boundingBox()).height).toBeGreaterThan(120);
    await page.screenshot({ path: testInfo.outputPath('visual-keyboard.png') });
    await page.evaluate(() => {
      Object.assign(visualViewport, { height: 844, offsetTop: 0 });
      visualViewport.dispatchEvent(new Event('resize'));
    });
    expect((await page.locator('#terminal').boundingBox()).height).toBeGreaterThan(500);
    await page.locator('#send').click();
    await expect.poll(() => mac.actions.filter(a => a.text === 'enter').length).toBe(1);
  } finally { mac.close(); }
});
