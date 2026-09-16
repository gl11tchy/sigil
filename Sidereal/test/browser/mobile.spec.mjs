import { test, expect } from '@playwright/test';
import { WebSocket } from 'ws';
import { once } from 'node:events';
import { randomKey, importKey, seal, open } from '../../public/crypto.mjs';

// A synthetic Mac, using the actual relay and encryption. Never touches user sessions.
let sharedRoom, previousHost;
async function pair(page, origin, initialOutput, options = {}) {
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
  const bootstrap = randomKey();
  let key = await importKey(bootstrap), selected = 'one', peer, challenge, serial = Promise.resolve();
  const actions = [], errors = [];
  const terminal = title => `${title}\n\n${Array.from({ length: 35 }, (_, i) => `Line ${i + 1}: Verified the mobile layout and terminal output.`).join('\n')}\n\nReady for your next message.`;
  const outputs = { one: initialOutput ?? terminal('Mobile layout review'), two: terminal('Release checks') };
  let ws;
  for (let attempt = 0; ; attempt++) {
    ws = new WebSocket(`${origin.replace(/^http/, 'ws')}/connect?room=${room}&role=host`, { headers: { Authorization: `Bearer ${hostToken}` } });
    try { await once(ws, 'open'); break; }
    catch (error) { if (attempt >= 9) throw error; await new Promise(resolve => setTimeout(resolve, 100)); }
  }
  previousHost = ws;
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
        if (request.action === 'file') outputs[selected] += `\n\nAttached ${request.name || 'file'}`;
        const state = options.state ?? { tabs: [
          { id: 'one', title: 'Mobile layout review', status: options.statuses?.one ?? 'working' },
          { id: 'two', title: 'Release checks', status: options.statuses?.two ?? 'idle' }],
          selectedTabID: selected, terminal: outputs[selected] };
        ws.send(JSON.stringify({ peer, data: await seal({ challenge, sequence: request.sequence, ok: true, state }, key, 'mac') }));
      }
    }).catch(error => errors.push(error));
  });
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
      expect(await page.evaluate(() => getComputedStyle(document.getElementById('terminal')).overflowWrap)).toBe('break-word');
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


test('idle desktop chrome becomes one composer, with lossless raw output available', async ({ page, baseURL }, testInfo) => {
  await page.setViewportSize({ width: 390, height: 844 });
  const raw = '\n└\n┘\n' + '\n'.repeat(25) + '─'.repeat(80)
    + '\n│ ❯ Build anything\n                    Grok 4.6\n(xhigh) · always-approve\n\n→:expand | Ctrl+e:collapse thinking | Ctrl+x:shortcuts';
  const mac = await pair(page, baseURL, raw);
  try {
    await expect(page.locator('#empty-output')).toBeVisible();
    await expect(page.locator('#terminal')).toHaveText('');
    await expect(page.locator('#keys')).toBeHidden();
    await expect(page.locator('#interrupt')).toBeHidden();
    const header = await page.locator('header').boundingBox();
    expect(header.height).toBeLessThan(90);
    await page.screenshot({ path: testInfo.outputPath('idle-readable.png') });
    await page.getByLabel('Connection settings').click();
    await page.locator('#raw-toggle').click();
    await expect(page.locator('#terminal')).toHaveText(raw);
    await expect(page.locator('#empty-output')).toBeHidden();
    await expect(page.locator('#raw-toggle')).toHaveAttribute('aria-pressed', 'true');
    await page.locator('#raw-toggle').click();
    await expect(page.locator('#empty-output')).toBeVisible();
    await page.getByLabel('Connection settings').click();
    await page.locator('#keys-toggle').click();
    await page.locator('#interrupt').click();
    await expect.poll(() => mac.actions.filter(a => a.text === 'interrupt').length).toBe(1);
    await page.locator('#keys-toggle').click();
    await page.locator('#new').click();
    await expect(page.locator('#terminal')).toContainText('Release checks');
  } finally { mac.close(); }
});

for (const width of [400, 414, 430]) {
  test(`keys and header controls keep 44px touch targets at ${width}px`, async ({ page, baseURL }, testInfo) => {
    await page.setViewportSize({ width, height: 844 });
    const consoleErrors = [];
    page.on('pageerror', error => consoleErrors.push(error.message));
    page.on('console', message => { if (['warning', 'error'].includes(message.type())) consoleErrors.push(message.text()); });
    const mac = await pair(page, baseURL);
    try {
      await page.locator('#keys-toggle').click();
      for (const control of await page.locator('#keys button:visible, #new, #keys-toggle, #attach-toggle, #connection-toggle, #stop').all()) {
        const box = await control.boundingBox();
        expect(box.width).toBeGreaterThanOrEqual(44);
        expect(box.height).toBeGreaterThanOrEqual(44);
      }
      expect(await page.evaluate(() => document.documentElement.scrollWidth)).toBeLessThanOrEqual(width);
      expect(consoleErrors).toEqual([]);
      await page.screenshot({ path: testInfo.outputPath(`keys-${width}.png`) });
    } finally { mac.close(); }
  });
}

test('an ended session keeps drafting but disables remote actions', async ({ page, baseURL }, testInfo) => {
  await page.setViewportSize({ width: 390, height: 844 });
  const consoleErrors = [];
  page.on('pageerror', error => consoleErrors.push(error.message));
  page.on('console', message => { if (['warning', 'error'].includes(message.type())) consoleErrors.push(message.text()); });
  const mac = await pair(page, baseURL, '', { statuses: { one: 'exited' } });
  try {
    await expect(page.locator('#tabs')).toContainText('Ended');
    await expect(page.locator('#empty-output')).toContainText('Session ended');
    await expect(page.locator('#empty-output')).toContainText('Restart this session in Sigil on your Mac.');
    await page.locator('#message').fill('Restarting notes');
    await expect(page.locator('#send')).toBeDisabled();
    await expect(page.locator('#message')).toBeEditable();
    await expect(page.locator('#new')).toBeEnabled();
    await expect(page.locator('#tabs')).toBeEnabled();
    await page.locator('#keys-toggle').click();
    await expect(page.locator('#paste')).toBeDisabled();
    await expect(page.locator('#interrupt')).toBeDisabled();
    expect(consoleErrors).toEqual([]);
    await page.screenshot({ path: testInfo.outputPath('ended.png') });
  } finally { mac.close(); }
});

test('an empty session list keeps New available and disables the picker', async ({ page, baseURL }, testInfo) => {
  await page.setViewportSize({ width: 390, height: 844 });
  const consoleErrors = [];
  page.on('pageerror', error => consoleErrors.push(error.message));
  page.on('console', message => { if (['warning', 'error'].includes(message.type())) consoleErrors.push(message.text()); });
  const mac = await pair(page, baseURL, '', { state: { tabs: [], selectedTabID: null, terminal: '' } });
  try {
    await expect(page.locator('#empty-output')).toContainText('No open sessions');
    await expect(page.locator('#tabs')).toContainText('No open sessions');
    await expect(page.locator('#tabs')).toBeDisabled();
    await expect(page.locator('#new')).toBeEnabled();
    await expect(page.locator('#message')).toBeDisabled();
    expect(consoleErrors).toEqual([]);
    await page.screenshot({ path: testInfo.outputPath('empty.png') });
  } finally { mac.close(); }
});

test('a photo from the phone is queued as a chip and sent as a file', async ({ page, baseURL }, testInfo) => {
  await page.setViewportSize({ width: 390, height: 844 });
  const png = Buffer.from(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
    'base64');
  const mac = await pair(page, baseURL);
  try {
    await page.locator('#attach').setInputFiles({ name: 'shot.png', mimeType: 'image/png', buffer: png });
    await expect(page.locator('#attachments')).toContainText('shot.png');
    await expect(page.locator('#send')).toBeEnabled();
    await page.screenshot({ path: testInfo.outputPath('attach.png') });
    await page.locator('#send').click();
    await expect.poll(() => mac.actions.filter(a => a.action === 'file').length).toBeGreaterThan(0);
    await expect.poll(() => mac.actions.filter(a => a.action === 'key' && a.text === 'enter').length).toBe(1);
    await expect(page.locator('#attachments')).toBeHidden();
    await page.screenshot({ path: testInfo.outputPath('attach.png') });
  } finally { mac.close(); }
});

test('the live Grok composer becomes readable status on a phone', async ({ page, baseURL }, testInfo) => {
  await page.setViewportSize({ width: 390, height: 844 });
  const raw = Array.from({ length: 18 }, () => ' '.repeat(120)).join('\n') + '\n'
    + '█\n\n         ∴ Thinking... 2.7s\n3m28s ↓328k [stop]\n\n'
    + `${'─'.repeat(40)}\n${'─'.repeat(40)}\n${'─'.repeat(40)}\n  | >\nGrok 4.6 (xhigh) · always-approve\n  Shift+Tab:mode | Esc:cancel |\nCtrl+x:shortcuts`;
  const mac = await pair(page, baseURL, raw);
  try {
    await expect(page.locator('#terminal')).toHaveText('∴ Thinking... 2.7s\n3m28s ↓328k [stop]');
    await expect(page.locator('#terminal')).not.toContainText('Shift+Tab');
    await expect(page.locator('#stop')).toBeVisible();
    await page.screenshot({ path: testInfo.outputPath('thinking.png') });
  } finally { mac.close(); }
});

test('a boxed waiting composer does not cover the phone transcript', async ({ page, baseURL }, testInfo) => {
  await page.setViewportSize({ width: 390, height: 844 });
  const raw = [
    '> Testing 123',
    '6:56 PM',
    '',
    '♦ user_prompt_submit  [hooks: 1/2]',
    '',
    ': Waiting for response... 9.9s',
    '9.9s ↓318k [stop]',
    '',
    `┌${'─'.repeat(62)}┐`,
    `│${' '.repeat(62)}│`,
    '│  | >                                                         │',
    `│${' '.repeat(62)}│`,
    `└${'─'.repeat(62)}┘`,
    ' Grok 4.6 (xhigh) · always-approve ↩',
    ' Shift+Tab:mode | Esc:cancel | Ctrl+x:shortcuts',
  ].join('\n');
  const mac = await pair(page, baseURL, raw);
  try {
    await expect(page.locator('#terminal')).toContainText('Testing 123');
    await expect(page.locator('#terminal')).toContainText('Waiting for response');
    await expect(page.locator('#terminal')).not.toContainText('Shift+Tab');
    await expect(page.locator('#terminal')).not.toContainText('always-approve');
    await expect(page.locator('#stop')).toBeVisible();
    await page.screenshot({ path: testInfo.outputPath('waiting.png') });
  } finally { mac.close(); }
});

test('tree gutters do not wrap into a column of pipes on a phone', async ({ page, baseURL }, testInfo) => {
  await page.setViewportSize({ width: 390, height: 844 });
  const raw = [
    '|     1 const CACHE = \'sidereal-shell-v7\';',
    '|',
    '|     2 const SHELL = [\'/\', \'/app.mjs\', \'/output.mjs\'];',
    '|          pre_tool_use',
    'Ready for your next message.',
  ].join('\n');
  const mac = await pair(page, baseURL, raw);
  try {
    await expect(page.locator('#terminal')).toContainText("1 const CACHE = 'sidereal-shell-v7';");
    await expect(page.locator('#terminal')).not.toHaveText(/^\s*\|/m);
    await expect(page.locator('#terminal')).toContainText('pre_tool_use');
    await page.screenshot({ path: testInfo.outputPath('gutter.png') });
  } finally { mac.close(); }
});

test('the connection popover closes on Escape and outside pointer presses', async ({ page, baseURL }, testInfo) => {
  await page.setViewportSize({ width: 390, height: 844 });
  const consoleErrors = [];
  page.on('pageerror', error => consoleErrors.push(error.message));
  page.on('console', message => { if (['warning', 'error'].includes(message.type())) consoleErrors.push(message.text()); });
  const mac = await pair(page, baseURL);
  try {
    const details = page.locator('#connection');
    await page.locator('#connection-toggle').click();
    await expect(details).toHaveJSProperty('open', true);
    await page.keyboard.press('Escape');
    await expect(details).toHaveJSProperty('open', false);
    await expect(page.locator('#connection-toggle')).toBeFocused();
    await page.locator('#connection-toggle').click();
    await expect(details).toHaveJSProperty('open', true);
    await page.locator('#terminal').click();
    await expect(details).toHaveJSProperty('open', false);
    expect(consoleErrors).toEqual([]);
    await page.screenshot({ path: testInfo.outputPath('popover.png') });
  } finally { mac.close(); }
});
