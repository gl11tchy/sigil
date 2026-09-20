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
  const ticket = randomKey();
  let key = await importKey(bootstrap), selected = 'one', peer, challenge, serial = Promise.resolve();
  const actions = [], errors = [];
  const terminal = title => `${title}\n\n${Array.from({ length: 35 }, (_, i) => `Line ${i + 1}: Verified the mobile layout and terminal output.`).join('\n')}\n\nReady for your next message.`;
  const outputs = { one: initialOutput ?? terminal('Mobile layout review'), two: terminal('Release checks') };
  let ws;
  for (let attempt = 0; ; attempt++) {
    ws = new WebSocket(`${origin.replace(/^http/, 'ws')}/connect?room=${room}&role=host&ticket=${ticket}`, { headers: { Authorization: `Bearer ${hostToken}` } });
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
        if (options.rejectAction === request.action) {
          ws.send(JSON.stringify({ peer, data: await seal({ challenge, sequence: request.sequence, ok: false, error: 'Test action refused.' }, key, 'mac') }));
          return;
        }
        if (request.action === 'restart' && options.restart) {
          selected = 'restarted'; outputs.restarted = 'Session restarted';
        }
        if (request.action === 'input') outputs[selected] += `\n\nYou: ${request.text}`;
        if (request.action === 'file') outputs[selected] += `\n\nAttached ${request.name || 'file'}`;
        const state = options.state ?? { tabs: [
          { id: selected === 'restarted' ? 'restarted' : 'one', title: 'Mobile layout review', status: selected === 'restarted' ? 'idle' : options.statuses?.one ?? 'working' },
          { id: 'two', title: 'Release checks', status: options.statuses?.two ?? 'idle' }],
          selectedTabID: selected, terminal: outputs[selected], capabilities: options.restart ? ['restart'] : [] };
        ws.send(JSON.stringify({ peer, data: await seal({ challenge, sequence: request.sequence, ok: true, ticket, state }, key, 'mac') }));
      }
    }).catch(error => errors.push(error));
  });
  if (!options.skipNavigate) {
    await page.goto(`${origin}/#room=${room}&key=${bootstrap}`);
    await expect(page.locator('#status')).toHaveText('Connected');
  }
  return { actions, errors, room, bootstrap, close: () => ws.close() };
}

test('the welcome screen pairs from a pasted link without a URL fragment', async ({ page, baseURL }, testInfo) => {
  await page.setViewportSize({ width: 390, height: 844 });
  const mac = await pair(page, baseURL, undefined, { skipNavigate: true });
  try {
    await page.goto(baseURL);
    await expect(page.locator('#welcome')).toBeVisible();
    await expect(page.getByRole('button', { name: 'Scan code' })).toBeVisible();
    await expect(page.locator('#standalone-hint')).toBeHidden();
    await expect(page.locator('#status')).toHaveText('Not connected');
    await page.screenshot({ path: testInfo.outputPath('welcome.png') });
    await page.getByRole('button', { name: 'Paste link' }).click();
    await page.locator('#pairing-link').fill(`${baseURL}/#room=${mac.room}&key=${mac.bootstrap}`);
    await page.locator('#paste-form').getByRole('button', { name: 'Connect' }).click();
    await expect(page.locator('#status')).toHaveText('Connected');
    await expect(page.locator('#welcome')).toBeHidden();
    expect(new URL(page.url()).hash).toBe('');
  } finally { mac.close(); }
});

test('a pairing link for another origin stays disconnected', async ({ page, baseURL }) => {
  await page.setViewportSize({ width: 390, height: 844 });
  await page.goto(baseURL);
  await page.getByRole('button', { name: 'Paste link' }).click();
  await page.locator('#pairing-link').fill(
    `https://evil.example/#room=${'ab'.repeat(16)}&key=${'cd'.repeat(32)}`,
  );
  await page.locator('#paste-form').getByRole('button', { name: 'Connect' }).click();
  await expect(page.locator('#error')).toHaveText('This code is for a different Sidereal address.');
  await expect(page.locator('#status')).toHaveText('Not connected');
  await expect(page.locator('#welcome')).toBeVisible();
});

test('a standalone Home Screen app warns that Safari is a different store', async ({ page, baseURL }) => {
  await page.setViewportSize({ width: 390, height: 844 });
  await page.addInitScript(() => {
    Object.defineProperty(navigator, 'standalone', { configurable: true, value: true });
  });
  const mac = await pair(page, baseURL, undefined, { skipNavigate: true });
  try {
    await page.goto(baseURL);
    await expect(page.locator('#standalone-hint')).toBeVisible();
    await expect(page.locator('#standalone-hint')).toContainText('Open as Web App');
    await page.getByRole('button', { name: 'Paste link' }).click();
    await page.locator('#pairing-link').fill(`${baseURL}/#room=${mac.room}&key=${mac.bootstrap}`);
    await page.locator('#paste-form').getByRole('button', { name: 'Connect' }).click();
    await expect(page.locator('#status')).toHaveText('Connected');
    await expect(page.locator('#welcome')).toBeHidden();
    await page.getByLabel('Connection settings').click();
    await expect(page.locator('#standalone-panel-hint')).toBeVisible();
  } finally { mac.close(); }
});

test('scan falls back to paste when the camera is missing', async ({ page, baseURL }) => {
  await page.setViewportSize({ width: 390, height: 844 });
  await page.addInitScript(() => {
    Object.defineProperty(navigator, 'mediaDevices', { configurable: true, value: undefined });
  });
  await page.goto(baseURL);
  await page.getByRole('button', { name: 'Scan code' }).click();
  await expect(page.locator('#error')).toContainText('Paste the pairing link');
  await expect(page.locator('#paste-form')).toBeVisible();
  await expect(page.locator('#scanner')).toBeHidden();
});

test('a stored ticket reconnects without a QR fragment', async ({ page, baseURL }) => {
  await page.setViewportSize({ width: 390, height: 844 });
  const mac = await pair(page, baseURL);
  try {
    await page.goto(baseURL);
    await expect(page.locator('#status')).toHaveText('Connected');
  } finally { mac.close(); }
});

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

for (const width of [320, 390, 400, 414, 430]) {
  test(`composer, keys, and header controls keep 44px touch targets at ${width}px`, async ({ page, baseURL }, testInfo) => {
    await page.setViewportSize({ width, height: 844 });
    const consoleErrors = [];
    page.on('pageerror', error => consoleErrors.push(error.message));
    page.on('console', message => { if (['warning', 'error'].includes(message.type())) consoleErrors.push(message.text()); });
    const mac = await pair(page, baseURL);
    try {
      await page.locator('#keys-toggle').click();
      for (const control of await page.locator('#keys button:visible, #new, #keys-toggle, #attach-toggle, #send, #connection-toggle, #stop').all()) {
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
    await expect(page.locator('#terminal')).toHaveText('');
    await expect(page.locator('#terminal')).not.toContainText('Thinking');
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
    await expect(page.locator('#terminal')).not.toContainText('Waiting for response');
    await expect(page.locator('#terminal')).not.toContainText('hooks');
    await expect(page.locator('#terminal')).not.toContainText('Shift+Tab');
    await expect(page.locator('#terminal')).not.toContainText('always-approve');
    await expect(page.locator('#stop')).toBeVisible();
    await page.screenshot({ path: testInfo.outputPath('waiting.png') });
  } finally { mac.close(); }
});

test('the live iPhone idle composer does not cover the phone transcript', async ({ page, baseURL }, testInfo) => {
  await page.setViewportSize({ width: 390, height: 844 });
  const raw = [
    '|     1. Delete the Sidereal icon.',
    '|',
    '|     2. Open Safari. It should still say Connected.',
    '|',
    '|     3. Share → Add to Home Screen.',
    '|',
    '|     4. If iPhone shows Open as Web App, turn that off.',
    '|',
    `╭${'─'.repeat(62)}╮`,
    `│${' '.repeat(62)}│`,
    `│${' '.repeat(62)}│`,
    `╰${'─'.repeat(62)}╯`,
    `╭${'─'.repeat(62)}╮`,
    '│  | >                                                - grok   │',
    `╰${'─'.repeat(62)}╯`,
    ' — Grok 4.6 (xhigh) · always-approve —',
    ' Shift+Tab:mode | Ctrl+x:shortcuts',
  ].join('\n');
  const mac = await pair(page, baseURL, raw);
  try {
    await expect(page.locator('#terminal')).toContainText('Delete the Sidereal icon');
    await expect(page.locator('#terminal')).toContainText('Add to Home Screen');
    await expect(page.locator('#terminal')).not.toContainText('Shift+Tab');
    await expect(page.locator('#terminal')).not.toContainText('always-approve');
    await expect(page.locator('#terminal')).not.toContainText('- grok');
    await expect(page.locator('#terminal')).not.toHaveText(/^\s*[│|╭╰]/m);
    await page.screenshot({ path: testInfo.outputPath('iphone-idle.png') });
  } finally { mac.close(); }
});

test('a live iPhone transcript is the messages, not hooks or pipes', async ({ page, baseURL }, testInfo) => {
  await page.setViewportSize({ width: 390, height: 844 });
  const raw = [
    '▼ task completed in 1.8s. Poll Railway deployment until SUCCESS',
    '',
    '◆ Run Prove production Sidereal serves the new stripper  [hooks: 3]',
    '',
    '│  🙋 NEED YOU — Close the Safari tab on the phone, then open remote.sigilapp.dev again.     7:24 PM  │',
    '│  The boxed Grok footer is stripped on the live host. Safari on iPhone keeps the old page until that tab  │',
    '│    is gone.                                                                                         │',
    '',
    '> Done',
    '',
    '✅ DONE — That was the last step. You should see the four steps, not the boxed Grok footer.',
  ].join('\n');
  const mac = await pair(page, baseURL, raw, { statuses: { one: 'idle' } });
  try {
    const text = await page.locator('#terminal').innerText();
    await expect(page.locator('#terminal')).toContainText('NEED YOU');
    await expect(page.locator('#terminal')).toContainText('until that tab is gone.');
    await expect(page.locator('#terminal')).toContainText('> Done');
    await expect(page.locator('#terminal')).toContainText('four steps');
    await expect(page.locator('#terminal')).not.toContainText('hooks');
    await expect(page.locator('#terminal')).not.toContainText('task completed');
    await expect(page.locator('#terminal')).not.toContainText('7:24 PM');
    expect(text).not.toMatch(/^\s*[│|]/m);
    await page.screenshot({ path: testInfo.outputPath('conversation.png') });
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

test('session search switches conversations and keeps each draft', async ({ page, baseURL }) => {
  const mac = await pair(page, baseURL);
  try {
    await page.locator('#message').fill('Keep this draft');
    await page.getByRole('button', { name: 'Browse sessions' }).click();
    await page.getByRole('searchbox', { name: 'Search sessions' }).fill('release');
    await expect(page.locator('#session-list button')).toHaveCount(1);
    await page.locator('#session-list button').click();
    await expect(page.locator('#terminal')).toContainText('Release checks');
    await expect(page.locator('#sessions-dialog')).not.toBeVisible();
    await page.locator('#tabs').selectOption('one');
    await expect(page.locator('#message')).toHaveValue('Keep this draft');
  } finally { mac.close(); }
});

test('find output navigates literal matches without altering output', async ({ page, baseURL }) => {
  const mac = await pair(page, baseURL, 'First <script>\nsecond needle\nthird needle');
  try {
    await page.getByRole('button', { name: 'Find in output' }).click();
    await page.getByRole('searchbox', { name: 'Find in output' }).fill('needle');
    await expect(page.locator('#find-count')).toHaveText('1 of 2');
    await page.getByRole('button', { name: 'Next match' }).click();
    await expect(page.locator('#find-count')).toHaveText('2 of 2');
    await expect(page.locator('#terminal')).toHaveText('First <script>\nsecond needle\nthird needle');
    await page.getByRole('searchbox', { name: 'Find in output' }).fill('absent');
    await expect(page.locator('#find-count')).toHaveText('No matches');
    await expect(page.getByRole('button', { name: 'Next match' })).toBeDisabled();
    await page.getByRole('searchbox', { name: 'Find in output' }).press('Escape');
    await expect(page.locator('#find-bar')).toBeHidden();
  } finally { mac.close(); }
});

test('phone return creates a newline and explicit send submits once', async ({ page, baseURL }) => {
  await page.emulateMedia({ media: 'screen' });
  await page.addInitScript(() => {
    const original = window.matchMedia.bind(window);
    window.matchMedia = query => query === '(pointer: coarse)' ? { matches: true } : original(query);
  });
  const mac = await pair(page, baseURL);
  try {
    await page.locator('#message').fill('First line');
    await page.locator('#message').press('End');
    await page.locator('#message').press('Enter');
    await page.locator('#message').pressSequentially('Second line');
    await expect(page.locator('#message')).toHaveValue('First line\nSecond line');
    expect(mac.actions.filter(a => a.action === 'input')).toHaveLength(0);
    await page.locator('#send').click();
    await expect.poll(() => mac.actions.filter(a => a.action === 'key' && a.text === 'enter').length).toBe(1);
  } finally { mac.close(); }
});


test('restart recovers an ended session without losing its draft', async ({ page, baseURL }) => {
  const mac = await pair(page, baseURL, '', { statuses: { one: 'exited' }, restart: true });
  try {
    await page.locator('#message').fill('Continue with this note');
    await page.getByRole('button', { name: 'Restart session', exact: true }).click();
    await expect(page.locator('#terminal')).toHaveText('Session restarted');
    await expect(page.locator('#message')).toHaveValue('Continue with this note');
    await expect(page.locator('#send')).toBeEnabled();
    await expect(page.locator('#restart')).toBeHidden();
    expect(mac.actions.filter(a => a.action === 'restart')).toHaveLength(1);
  } finally { mac.close(); }
});

test('stop failures are visible and do not become unhandled errors', async ({ page, baseURL }) => {
  const errors = [];
  page.on('pageerror', error => errors.push(error.message));
  const mac = await pair(page, baseURL, 'Still working', { rejectAction: 'key' });
  try {
    await page.locator('#stop').click();
    await expect(page.locator('#error')).toHaveText('Test action refused.');
    expect(errors).toEqual([]);
    await expect(page.locator('#message')).toBeEditable();
  } finally { mac.close(); }
});

test('fullscreen desktop does not show iPhone-only pairing advice', async ({ page, baseURL }) => {
  await page.addInitScript(() => {
    const match = window.matchMedia.bind(window);
    window.matchMedia = query => query === '(display-mode: fullscreen)' ? { matches: true } : match(query);
  });
  await page.goto(baseURL);
  await expect(page.locator('#standalone-hint')).toBeHidden();
});

test('manual pairing stays available while clipboard permission is pending', async ({ page, baseURL }) => {
  await page.addInitScript(() => {
    Object.defineProperty(navigator, 'clipboard', { configurable: true, value: { readText: () => new Promise(() => {}) } });
  });
  await page.goto(baseURL);
  await page.getByRole('button', { name: 'Paste link' }).click();
  await expect(page.locator('#pairing-link')).toBeVisible();
  await expect(page.locator('#pairing-link')).toBeFocused();
});

test('session activity updates preserve keyboard focus inside the picker', async ({ page, baseURL }) => {
  const statuses = { one: 'working' };
  const mac = await pair(page, baseURL, 'Output', { statuses });
  try {
    await page.getByRole('button', { name: 'Browse sessions' }).click();
    const row = page.locator('#session-list button').filter({ hasText: 'Mobile layout review' });
    await row.focus();
    statuses.one = 'idle';
    await expect(row).toContainText('Ready');
    await expect(row).toBeFocused();
    await row.press('Escape');
    await expect(page.getByRole('button', { name: 'Browse sessions' })).toBeFocused();
  } finally { mac.close(); }
});
