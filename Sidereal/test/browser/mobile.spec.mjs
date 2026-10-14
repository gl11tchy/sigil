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
  let key = await importKey(bootstrap), selected = 'one', peer, challenge, replayData, serial = Promise.resolve();
  const actions = [], errors = [];
  const terminal = title => `${title}\n\n${Array.from({ length: 35 }, (_, i) => `Line ${i + 1}: Verified the mobile layout and terminal output.`).join('\n')}\n\nReady for your next message.`;
  const outputs = { one: initialOutput ?? terminal('Mobile layout review'), two: terminal('Release checks') };
  let ws;
  let ready;
  const registered = new Promise(resolve => { ready = resolve; });
  const onMessage = bytes => {
    serial = serial.then(async () => {
      const frame = JSON.parse(bytes);
      if (frame.route) {
        ws.send(JSON.stringify({ route: await seal({ room, ticket }, await importKey(frame.route), 'relay-host') }));
      } else if (frame.type === 'ready') {
        ready();
      } else if (frame.type === 'peer') {
        peer = frame.peer; challenge = options.reuseChallenge && challenge ? challenge : randomKey();
        ws.send(JSON.stringify({ peer, hello: challenge }));
      } else if (frame.data) {
        const request = await open(frame.data, key, 'phone');
        expect(request.challenge).toBe(challenge);
        if (options.replayReplies && replayData) {
          ws.send(JSON.stringify({ peer, data: replayData })); return;
        }
        actions.push(request);
        if (await options.onRequest?.(request) === false) return;
        if (request.action === 'pair') key = await importKey(request.text);
        if (request.action === 'select' && options.rejectAction !== 'select') selected = request.tabID;
        if (request.action === 'new') selected = 'two';
        const projects = request.action === 'projects'
          ? (options.projects ?? [{ name: 'Release checks', folder: '/tmp/release' }]) : undefined;
        const chats = request.action === 'chats'
          ? (options.chats ?? []).filter(chat => `${chat.title} ${chat.folder}`.toLowerCase().includes(String(request.text || '').toLowerCase()))
          : undefined;
        const earlier = request.action === 'earlier'
          ? (typeof options.earlier === 'function' ? options.earlier(request)
            : typeof options.earlier === 'string' ? options.earlier : '') : undefined;
        if (options.rejectAction === request.action) {
          ws.send(JSON.stringify({ peer, data: await seal({ challenge, sequence: request.sequence, clientNonce: request.clientNonce, ok: false, error: 'Test action refused.' }, key, 'mac') }));
          return;
        }
        if (request.action === 'restart' && options.restart) {
          selected = options.switchDuringRestart ? 'two' : 'restarted'; outputs.restarted = 'Session restarted';
        }
        if (request.action === 'input') outputs[selected] += `\n\nYou: ${request.text}`;
        if (request.action === 'file') outputs[selected] += `\n\nAttached ${request.name || 'file'}`;
        const state = options.state ?? { tabs: [
          { provider: 'grokBuild', sessionID: 'native-one', cwd: '/tmp/one', capabilities: { resume: true }, id: outputs.restarted ? 'restarted' : 'one', title: 'Mobile layout review', status: outputs.restarted ? 'idle' : options.statuses?.one ?? 'working' },
          { provider: 'grokBuild', sessionID: 'native-two', cwd: '/tmp/two', capabilities: { resume: true }, id: 'two', title: 'Release checks', status: options.statuses?.two ?? 'idle' }],
          selectedTabID: selected, terminal: outputs[selected], capabilities: options.restart ? ['restart'] : [] };
        const payload = { challenge, sequence: request.sequence, clientNonce: options.omitNonce ? undefined : request.clientNonce, ok: true, ticket, state, restartedTabID: request.action === 'restart' && options.restart ? 'restarted' : undefined, restartedSession: request.action === 'restart' && options.restart ? { provider: 'grokBuild', sessionID: 'native-one', cwd: '/tmp/one' } : undefined };
        if (projects) payload.projects = projects;
        if (request.action === 'options' && (options.providers || options.sessionOptions)) {
          payload.options = options.sessionOptions ?? { providers: options.providers, provider: options.providers[0].id, models: [], model: '', efforts: [], effort: '', locations: [] };
        }
        if (request.action === 'createProject' && options.createProject) payload.project = options.createProject(request);
        if (chats) payload.chats = chats;
        if (earlier !== undefined) payload.earlier = earlier;
        const sealedReply = await seal(payload, key, 'mac');
        replayData ??= sealedReply;
        ws.send(JSON.stringify({ peer, data: sealedReply }));
      }
    }).catch(error => errors.push(error));
  };
  for (let attempt = 0; ; attempt++) {
    ws = new WebSocket(`${origin.replace(/^http/, 'ws')}/connect?role=host`, { headers: { Authorization: `Bearer ${hostToken}` } });
    // The server can send routing immediately in the same read as the upgrade.
    ws.on('message', onMessage);
    try { await once(ws, 'open'); break; }
    catch (error) { if (attempt >= 9) throw error; await new Promise(resolve => setTimeout(resolve, 100)); }
  }
  previousHost = ws;
  await registered;
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

test('a rejected code shows its reason on the scanner, above the camera', async ({ page, baseURL }, testInfo) => {
  await page.setViewportSize({ width: 390, height: 844 });
  await page.addInitScript(() => {
    Object.defineProperty(navigator, 'mediaDevices', { configurable: true, value: {
      getUserMedia: async () => {
        const canvas = Object.assign(document.createElement('canvas'), { width: 64, height: 64 });
        const context = canvas.getContext('2d');
        setInterval(() => { context.fillStyle = '#fff'; context.fillRect(0, 0, 64, 64); }, 50);
        return canvas.captureStream(10);
      },
    } });
    // Every frame reads as a code from another Sidereal address.
    globalThis.jsQR = () => ({ data: `https://evil.example/#room=${'ab'.repeat(16)}&key=${'cd'.repeat(32)}` });
  });
  await page.goto(baseURL);
  await page.getByRole('button', { name: 'Scan code' }).click();
  const reason = page.locator('#scanner').getByRole('alert');
  await expect(reason).toHaveText('This code is for a different Sidereal address.');
  // One alert only: the page's own error line sits under the scanner.
  await expect(page.locator('#error')).toBeHidden();
  expect(await reason.evaluate(element => {
    const box = element.getBoundingClientRect();
    return document.elementFromPoint(box.x + box.width / 2, box.y + box.height / 2) === element;
  })).toBe(true);
  await page.screenshot({ path: testInfo.outputPath('scanner-error.png') });
  await page.getByRole('button', { name: 'Cancel' }).click();
  await expect(page.locator('#scanner')).toBeHidden();
});

test('a stored ticket reconnects without a QR fragment or URL ticket', async ({ page, baseURL }) => {
  const urls = [];
  page.on('websocket', socket => urls.push(new URL(socket.url())));
  await page.setViewportSize({ width: 390, height: 844 });
  const mac = await pair(page, baseURL);
  try {
    await page.goto(baseURL);
    await expect(page.locator('#status')).toHaveText('Connected');
    expect(urls.length).toBeGreaterThanOrEqual(2);
    for (const url of urls) expect(url.search).toBe('?role=phone');
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

test('loading earlier output keeps the text the reader was on in place', async ({ page, baseURL }) => {
  await page.setViewportSize({ width: 390, height: 844 });
  let batch = 0;
  const earlier = () => {
    batch += 1;
    return Array.from({ length: 60 }, (_, i) => `Batch ${batch} line ${i + 1}: older output.`).join('\n') + '\n';
  };
  const mac = await pair(page, baseURL, undefined, { earlier });
  try {
    await expect.poll(() => mac.actions.filter(a => a.action === 'state').length).toBeGreaterThan(1);
    const measure = (marker, top) => page.locator('#terminal').evaluate((el, [wanted, scrollToTop]) => {
      if (scrollToTop) el.scrollTop = 0;
      // The output is painted as short text nodes; measure in the one that holds the line.
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
    const loads = mac.actions.filter(a => a.action === 'earlier').length;
    const before = await measure(null, true);
    await expect.poll(() => mac.actions.filter(a => a.action === 'earlier').length).toBe(loads + 1);
    await expect(page.locator('#terminal')).toContainText(`Batch ${loads + 1} line 1:`);
    const after = await measure(before.text, false);
    expect(Math.abs(after.offset - before.offset)).toBeLessThan(40);
  } finally { mac.close(); }
});

for (const position of ['history', 'latest']) {
  test(`resizing a draft from desktop to phone and back preserves ${position} position`, async ({ page, baseURL }, testInfo) => {
    await page.setViewportSize({ width: 1512, height: 844 });
    // Short terminal lines do not rewrap, so this isolates composer reflow from text wrapping.
    const output = Array.from({ length: 100 }, (_, index) => `Output line ${index + 1}`).join('\n');
    const mac = await pair(page, baseURL, output);
    try {
      await page.evaluate(() => document.fonts.ready);
      const draft = 'Keep this unsent draft fully visible when the desktop window changes to a narrow phone screen.';
      const message = page.locator('#message');
      await message.fill(draft);
      await message.focus();
      await message.evaluate(el => el.setSelectionRange(5, 12));
      const terminal = page.locator('#terminal');
      await terminal.evaluate((el, position) => {
        el.scrollTop = position === 'history' ? 220 : el.scrollHeight;
        el.dispatchEvent(new Event('scroll'));
      }, position);
      const initialTop = await terminal.evaluate(el => el.scrollTop);
      const height = () => message.evaluate(el => ({ client: el.clientHeight, scroll: el.scrollHeight }));
      const desktop = await height();
      expect(desktop.scroll).toBeLessThanOrEqual(desktop.client);
      for (const width of [390, 1512]) {
        await page.setViewportSize({ width, height: 844 });
        await expect.poll(async () => { const size = await height(); return size.scroll - size.client; }).toBeLessThanOrEqual(1);
        if (width === 390) await expect.poll(async () => (await height()).client).toBeGreaterThan(desktop.client);
        else await expect.poll(async () => Math.abs((await height()).client - desktop.client)).toBeLessThanOrEqual(1);
        await expect(message).toHaveValue(draft);
        await expect(message).toBeFocused();
        expect(await message.evaluate(el => [el.selectionStart, el.selectionEnd])).toEqual([5, 12]);
        const scroll = await terminal.evaluate(el => ({ top: el.scrollTop, fromBottom: el.scrollHeight - el.scrollTop - el.clientHeight }));
        if (position === 'history') expect(Math.abs(scroll.top - initialTop)).toBeLessThanOrEqual(1);
        else expect(scroll.fromBottom).toBeLessThanOrEqual(1);
        await page.screenshot({ path: testInfo.outputPath(`draft-${width}.png`) });
      }
      expect(mac.actions.filter(action => ['input', 'key'].includes(action.action))).toEqual([]);
      expect(mac.errors).toEqual([]);
    } finally { mac.close(); }
  });
}

test('reflowing a tall draft preserves manual reading just above the follow threshold', async ({ page, baseURL }) => {
  await page.setViewportSize({ width: 390, height: 844 });
  const output = Array.from({ length: 100 }, (_, index) => `Output line ${index + 1}`).join('\n');
  const mac = await pair(page, baseURL, output);
  try {
    await page.evaluate(() => document.fonts.ready);
    const draft = 'A tall unsent draft\n'.repeat(6);
    await page.locator('#message').fill(draft);
    const before = await page.locator('#terminal').evaluate(el => {
      el.scrollTop = el.scrollHeight - el.clientHeight - 70;
      return el.scrollTop;
    });
    // A keyboard/browser viewport event also remeasures an already tall editor.
    await page.evaluate(() => visualViewport.dispatchEvent(new Event('resize')));
    expect(await page.locator('#terminal').evaluate(el => el.scrollTop)).toBe(before);
    await expect(page.locator('#message')).toHaveValue(draft);
    await expect(page.locator('#message')).toBeFocused();
    expect(mac.actions.filter(action => ['input', 'key'].includes(action.action))).toEqual([]);
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
    await page.getByRole('button', { name: 'Release checks' }).click();
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

test('a multi-chunk file upload stays under the relay frame limit', async ({ page, baseURL }) => {
  await page.setViewportSize({ width: 390, height: 844 });
  const mac = await pair(page, baseURL);
  try {
    await page.locator('#attach').setInputFiles({
      name: 'data.bin', mimeType: 'application/octet-stream', buffer: Buffer.alloc(2 * 1024 * 1024, 7) });
    await page.locator('#send').click();
    await expect.poll(() => mac.actions.filter(a => a.action === 'key' && a.text === 'enter').length,
      { timeout: 15000 }).toBe(1);
    expect(mac.actions.filter(a => a.action === 'file').length).toBe(64);
    await expect(page.locator('#attachments')).toBeHidden();
    await expect(page.locator('#status')).toHaveText('Connected');
  } finally { mac.close(); }
});

test('an attachment over 4 MB is refused when it is picked', async ({ page, baseURL }) => {
  await page.setViewportSize({ width: 390, height: 844 });
  const mac = await pair(page, baseURL);
  try {
    await page.locator('#attach').setInputFiles([
      { name: 'notes.txt', mimeType: 'text/plain', buffer: Buffer.from('Test attachment') },
      { name: 'report.pdf', mimeType: 'application/pdf', buffer: Buffer.alloc(5 * 1024 * 1024, 7) }]);
    await expect(page.locator('#attachments')).toContainText('notes.txt');
    await expect(page.locator('#attachments')).not.toContainText('report.pdf');
    await expect(page.locator('#error')).toHaveText('Keep files under 4 MB.');
  } finally { mac.close(); }
});

test('a failed send does not paste the uploaded files again on retry', async ({ page, baseURL }) => {
  await page.setViewportSize({ width: 390, height: 844 });
  const mac = await pair(page, baseURL, 'Ready', { rejectAction: 'input' });
  const files = () => mac.actions.filter(a => a.action === 'file').length;
  const inputs = () => mac.actions.filter(a => a.action === 'input').length;
  try {
    await page.locator('#attach').setInputFiles({ name: 'notes.txt', mimeType: 'text/plain', buffer: Buffer.from('Test attachment') });
    await page.locator('#message').fill('Please read this');
    await page.locator('#send').click();
    await expect(page.locator('#error')).toHaveText('Test action refused.');
    expect(files()).toBe(1);
    await expect(page.locator('#attachments')).toBeHidden();
    await page.locator('#send').click();
    await expect.poll(inputs).toBe(2);
    expect(files()).toBe(1);
  } finally { mac.close(); }
});

test('quick taps on the terminal keys are all sent in order', async ({ page, baseURL }) => {
  await page.setViewportSize({ width: 390, height: 844 });
  const mac = await pair(page, baseURL);
  try {
    await page.locator('#keys-toggle').click();
    // Four taps faster than one relay round trip.
    await page.evaluate(() => {
      for (const key of ['down', 'down', 'down', 'enter']) document.querySelector(`[data-key="${key}"]`).click();
    });
    await expect.poll(() => mac.actions.filter(a => a.action === 'key').map(a => a.text))
      .toEqual(['down', 'down', 'down', 'enter']);
    await expect(page.locator('[data-key="down"]')).toBeEnabled();
  } finally { mac.close(); }
});

test('a terminal key tapped during an attachment send does not land inside it', async ({ page, baseURL }) => {
  await page.setViewportSize({ width: 390, height: 844 });
  const mac = await pair(page, baseURL);
  try {
    await page.locator('#keys-toggle').click();
    await page.locator('#attach').setInputFiles({
      name: 'data.bin', mimeType: 'application/octet-stream', buffer: Buffer.alloc(256 * 1024, 7) });
    await page.locator('#message').fill('read this');
    await page.locator('#send').click();
    await expect.poll(() => mac.actions.filter(a => a.action === 'file').length).toBeGreaterThan(0);
    await page.evaluate(() => document.querySelector('[data-key="enter"]').click());
    await expect.poll(() => mac.actions.filter(a => a.action === 'key').length, { timeout: 15000 }).toBeGreaterThan(0);
    await page.waitForTimeout(300);
    const order = mac.actions.filter(a => ['file', 'input', 'key'].includes(a.action)).map(a => a.action);
    expect(order).toEqual([...Array(8).fill('file'), 'input', 'key']);
    await expect(page.locator('[data-key="enter"]')).toBeEnabled();
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

test('a live working iPhone dump is the plan, not tofu squares or thinking chrome', async ({ page, baseURL }, testInfo) => {
  await page.setViewportSize({ width: 390, height: 844 });
  const raw = [
    '⠹',
    '|',
    '⠹',
    '|',
    '⠹',
    '|  ...',
    '⠹',
    '|  icons.',
    '⠹',
    '|  • Folder and recent chats stay right where they are.',
    '⠹',
    '|  • When Grok Build is chosen, the model picker and effort slider drop in below it—nothing fancy, just two simple rows.',
    '⠹',
    '',
    '         ∴ Thinking… 16s',
    '5m42s ↓130k [stop]',
  ].join('\n');
  const mac = await pair(page, baseURL, raw, { statuses: { one: 'working' } });
  try {
    const text = await page.locator('#terminal').innerText();
    await expect(page.locator('#terminal')).toContainText('Folder and recent chats stay right where they are.');
    await expect(page.locator('#terminal')).toContainText('When Grok Build is chosen');
    await expect(page.locator('#terminal')).not.toContainText('Thinking');
    await expect(page.locator('#terminal')).not.toContainText('[stop]');
    await expect(page.locator('#terminal')).not.toContainText('5m42s');
    expect(text).not.toMatch(/^\s*[│|]/m);
    expect(text).not.toMatch(/[\u2800-\u28FF\uFFFD]/);
    await expect(page.locator('#stop')).toBeVisible();
    await page.screenshot({ path: testInfo.outputPath('working-iphone.png') });
  } finally { mac.close(); }
});

test('a live new chat is the sentence, not tofu, thinking, or the truncated composer', async ({ page, baseURL }, testInfo) => {
  await page.setViewportSize({ width: 390, height: 844 });
  const raw = [
    '⠹',
    '|',
    '⠹',
    '|  The text on the left side should now',
    '⠹',
    '|  align properly without indentation.',
    '⠹',
    '',
    '         ∴ Thinking… 18s          24s ↓22.8k',
    '[stop]',
    '',
    '╭──────────────────────────────────────╮',
    '│ ❯                                    │',
    '│                                      │',
    '│      Grok 4.7 (xhigh) · always-approve│',
    '╰──────────────────────────────────────╯',
    'Shift+Tab:mode | Esc:cancel | Ctrl+x:',
  ].join('\n');
  const mac = await pair(page, baseURL, raw, { statuses: { one: 'working' } });
  try {
    const text = await page.locator('#terminal').innerText();
    await expect(page.locator('#terminal')).toHaveText(
      'The text on the left side should now align properly without indentation.',
    );
    await expect(page.locator('#terminal')).not.toContainText('Thinking');
    await expect(page.locator('#terminal')).not.toContainText('[stop]');
    await expect(page.locator('#terminal')).not.toContainText('Shift+Tab');
    await expect(page.locator('#terminal')).not.toContainText('Grok 4.7');
    await expect(page.locator('#terminal')).not.toContainText('Ctrl+x');
    expect(text).not.toMatch(/^\s*[│|]/m);
    expect(text).not.toMatch(/[\u2800-\u28FF\uFFFD]/);
    await expect(page.locator('#stop')).toBeVisible();
    await page.screenshot({ path: testInfo.outputPath('new-chat-working.png') });
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

test('a pairing link asks before it replaces the paired Mac and keeps it if pairing fails', async ({ page, baseURL }, testInfo) => {
  await page.setViewportSize({ width: 390, height: 844 });
  const mac = await pair(page, baseURL);
  const other = `${baseURL}/#room=${'1'.repeat(32)}&key=${'2'.repeat(64)}`;
  try {
    const dialog = page.locator('#replace-dialog');
    await page.goto(other);
    await expect(dialog).toBeVisible();
    await expect(dialog).toContainText('Replace the paired Mac?');
    await page.screenshot({ path: testInfo.outputPath('replace-confirm.png'), animations: 'disabled' });
    await page.locator('#replace-keep').click();
    await expect(page.locator('#status')).toHaveText('Connected');
    await page.goto(other);
    await page.locator('#replace-accept').click();
    await expect(dialog).toBeHidden();
    await expect(page.locator('#status')).toHaveText(/Connecting|Disconnected/);
    // The link's room has no Mac, so the old pairing must still be stored.
    await page.goto(baseURL);
    await expect(page.locator('#status')).toHaveText('Connected');
  } finally { mac.close(); }
});

test('Forget this Mac asks first and Cancel keeps the pairing', async ({ page, baseURL }, testInfo) => {
  await page.setViewportSize({ width: 390, height: 844 });
  const mac = await pair(page, baseURL);
  try {
    const dialog = page.locator('#forget-dialog');
    await page.locator('#connection-toggle').click();
    // Forget reads as destructive and sits apart from the buttons above it.
    await expect(page.locator('#forget')).toHaveCSS('color', 'rgb(199, 42, 53)');
    const gap = await page.evaluate(() => {
      const buttons = [...document.querySelectorAll('.connection-panel button')].filter(button => !button.hidden);
      const index = buttons.findIndex(button => button.id === 'forget');
      return buttons[index].getBoundingClientRect().top - buttons[index - 1].getBoundingClientRect().bottom;
    });
    expect(gap).toBeGreaterThanOrEqual(16);
    await page.locator('#forget').click();
    await expect(dialog).toBeVisible();
    await expect(dialog).toContainText('Forget this Mac?');
    await expect(page.locator('#forget-accept')).toHaveCSS('color', 'rgb(199, 42, 53)');
    await page.screenshot({ path: testInfo.outputPath('forget-confirm.png'), animations: 'disabled' });
    await page.locator('#forget-cancel').click();
    await expect(dialog).toBeHidden();
    await expect(page.locator('#controls')).toBeVisible();
    await expect(page.locator('#status')).toHaveText('Connected');
    await page.locator('#connection-toggle').click();
    await page.locator('#forget').click();
    await page.locator('#forget-accept').click();
    await expect(page.locator('#welcome-actions')).toBeVisible();
    await expect(page.locator('#controls')).toBeHidden();
  } finally { mac.close(); }
});

test('the connection control is named by the visible status', async ({ page, baseURL }) => {
  await page.setViewportSize({ width: 390, height: 844 });
  await page.goto(baseURL);
  const toggle = page.locator('#connection-toggle');
  await expect(toggle).toHaveAccessibleName('Not connected connection settings');
  const mac = await pair(page, baseURL);
  try {
    await expect(toggle).toHaveAccessibleName('Connected connection settings');
    // Status changes are announced from outside the summary, which flattens its children.
    await expect(toggle.locator('[role=status]')).toHaveCount(0);
    await expect(page.getByRole('status').filter({ hasText: /^Connected$/ })).toHaveCount(1);
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

test('an error from a chats search shows inside the open Chats sheet', async ({ page, baseURL }, testInfo) => {
  await page.setViewportSize({ width: 390, height: 844 });
  const mac = await pair(page, baseURL, undefined, { rejectAction: 'chats' });
  try {
    await page.locator('#sessions-toggle').click();
    await page.locator('#session-search').fill('release');
    const alert = page.locator('#sessions-dialog [role=alert]');
    await expect(alert).toHaveText('Test action refused.');
    await expect(alert).toBeInViewport();
    await page.screenshot({ path: testInfo.outputPath('sheet-error.png') });
    await page.locator('#sessions-close').click();
    await expect(page.locator('#error')).toHaveText('Test action refused.');
  } finally { mac.close(); }
});

test('opening Chats on a touch screen does not raise the keyboard', async ({ page, baseURL }) => {
  await page.setViewportSize({ width: 390, height: 844 });
  await page.addInitScript(() => {
    const original = window.matchMedia.bind(window);
    window.matchMedia = query => /pointer:\s*fine/.test(query)
      ? { ...original(query), matches: false, media: query } : original(query);
  });
  const mac = await pair(page, baseURL);
  try {
    await page.locator('#sessions-toggle').click();
    await expect(page.locator('#sessions-dialog')).toBeVisible();
    await expect(page.locator('#session-search')).not.toBeFocused();
  } finally { mac.close(); }
});

test('folder paths in the project and chats sheets use the mono face', async ({ page, baseURL }, testInfo) => {
  await page.setViewportSize({ width: 390, height: 844 });
  const mac = await pair(page, baseURL, undefined, {
    chats: [{ id: 'saved-1', title: 'Release notes', folder: '/Users/me/Code/sigil' }],
    providers: [{ id: 'grokBuild', name: 'Grok Build' }, { id: 'claudeCode', name: 'Claude Code' }],
  });
  try {
    await page.getByRole('button', { name: 'New session' }).click();
    const project = page.locator('#project-list small').first();
    await expect(project).toHaveText('/tmp/release');
    await expect(project).toHaveCSS('font-family', /monospace/);
    const cli = page.getByLabel('CLI');
    await expect(cli).toHaveValue('grokBuild');
    await cli.selectOption('claudeCode');
    await page.screenshot({ path: testInfo.outputPath('projects.png'), animations: 'disabled' });
    await page.locator('#project-cancel').click();
    await page.getByRole('button', { name: 'Browse open and saved chats' }).click();
    await page.getByRole('searchbox', { name: 'Search chats' }).fill('release');
    const saved = page.locator('#saved-list small').first();
    await expect(saved).toHaveText('/Users/me/Code/sigil');
    await expect(saved).toHaveCSS('font-family', /monospace/);
    await page.screenshot({ path: testInfo.outputPath('saved.png'), animations: 'disabled' });
  } finally { mac.close(); }
});

for (const entry of ['picker', 'browse']) {
  for (const outcome of ['success', 'failure']) {
    test(`pending ${entry} session selection preserves readonly drafts through ${outcome}`, async ({ page, baseURL }, testInfo) => {
      let hold = false, release;
      const gate = new Promise(resolve => { release = resolve; });
      const options = { onRequest: async request => { if (hold && request.action === 'select') await gate; } };
      const mac = await pair(page, baseURL, undefined, options);
      try {
        const message = page.locator('#message');
        await message.fill('First draft');
        await page.locator('#tabs').selectOption('two');
        await expect(page.locator('#terminal')).toContainText('Release checks');
        await message.fill('Second draft');
        await page.locator('#tabs').selectOption('one');
        await expect(message).toHaveValue('First draft');
        hold = true;
        if (outcome === 'failure') options.rejectAction = 'select';
        const count = mac.actions.filter(action => action.action === 'select').length;
        if (entry === 'picker') await page.locator('#tabs').selectOption('two');
        else {
          await page.getByRole('button', { name: 'Browse open and saved chats' }).click();
          await page.locator('#session-list button').filter({ hasText: 'Release checks' }).click();
          // A person can dismiss Chats while the Mac's selection reply is pending.
          await page.locator('#sessions-dialog').evaluate(el => {
            el.dataset.testClosed = 'false';
            el.addEventListener('close', () => { el.dataset.testClosed = 'true'; }, { once: true });
          });
          await page.keyboard.press('Escape');
          await expect(page.locator('#sessions-dialog')).toHaveAttribute('data-test-closed', 'true');
        }
        await expect.poll(() => mac.actions.filter(action => action.action === 'select').length).toBe(count + 1);
        await expect(message).not.toBeEditable();
        await expect(message).toBeEnabled();
        await message.focus();
        await page.keyboard.type('Typing before the Mac replies');
        await expect(message).toBeFocused();
        await expect(message).toHaveValue('First draft');
        await expect(page.locator('#send')).toBeDisabled();
        await expect(page.locator('#stop')).toBeDisabled();
        await expect(page.locator('#interrupt')).toBeDisabled();
        await expect(page.locator('#compose-status')).toHaveText('Switching…');
        await page.screenshot({ path: testInfo.outputPath('selection-pending.png') });
        release();
        await expect(message).toBeEditable();
        await expect(message).toBeFocused();
        await expect(message).toHaveValue(outcome === 'success' ? 'Second draft' : 'First draft');
        await expect(page.locator('#tabs')).toHaveValue(outcome === 'success' ? 'two' : 'one');
        if (outcome === 'failure') await expect(page.locator('#error')).toHaveText('Test action refused.');
        options.rejectAction = null; hold = false;
        await page.locator('#tabs').selectOption(outcome === 'success' ? 'one' : 'two');
        await expect(message).toHaveValue(outcome === 'success' ? 'First draft' : 'Second draft');
        expect(mac.actions.filter(action => ['input', 'key'].includes(action.action))).toEqual([]);
        expect(mac.errors).toEqual([]);
      } finally { release(); mac.close(); }
    });
  }
}

test('session search switches conversations and keeps each draft', async ({ page, baseURL }) => {
  const mac = await pair(page, baseURL);
  try {
    await page.locator('#message').fill('Keep this draft');
    await page.getByRole('button', { name: 'Browse open and saved chats' }).click();
    await page.getByRole('searchbox', { name: 'Search chats' }).fill('release');
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

test('new output keeps a selection the reader is making in the terminal', async ({ page, baseURL }) => {
  await page.setViewportSize({ width: 390, height: 844 });
  let terminal = 'First command\nStep 1 of 3';
  const mac = await pair(page, baseURL, undefined, { get state() {
    return { tabs: [{ id: 'one', title: 'Mobile layout review', status: 'working' }], selectedTabID: 'one', terminal, capabilities: [] };
  } });
  const polls = () => mac.actions.filter(action => action.action === 'state').length;
  try {
    await expect(page.locator('#terminal')).toHaveText('First command\nStep 1 of 3');
    await page.evaluate(() => {
      const text = document.getElementById('terminal').firstChild;
      getSelection().setBaseAndExtent(text, 0, text, 'First command'.length);
    });
    terminal = 'First command\nStep 1 of 3\nthird line';
    await expect(page.locator('#terminal')).toContainText('third line');
    expect(await page.evaluate(() => getSelection().toString())).toBe('First command');
    // Output that rewrites the displayed text waits until the selection ends.
    terminal = 'First command\nStep 2 of 3\nthird line';
    const seen = polls();
    await expect.poll(polls).toBeGreaterThan(seen + 1);
    await expect(page.locator('#terminal')).toContainText('Step 1 of 3');
    expect(await page.evaluate(() => getSelection().toString())).toBe('First command');
    await page.evaluate(() => getSelection().removeAllRanges());
    await expect(page.locator('#terminal')).toHaveText('First command\nStep 2 of 3\nthird line');
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
    await page.getByRole('button', { name: 'Browse open and saved chats' }).click();
    const row = page.locator('#session-list button').filter({ hasText: 'Mobile layout review' });
    await row.focus();
    statuses.one = 'idle';
    await expect(row).toContainText('Ready');
    await expect(row).toBeFocused();
    await row.press('Escape');
    await expect(page.getByRole('button', { name: 'Browse open and saved chats' })).toBeFocused();
  } finally { mac.close(); }
});


test('restart keeps drafts with their own sessions when the Mac changes selection', async ({ page, baseURL }) => {
  const mac = await pair(page, baseURL, '', { statuses: { one: 'exited' }, restart: true, switchDuringRestart: true });
  try {
    await page.locator('#tabs').selectOption('two');
    await expect(page.locator('#terminal')).toContainText('Release checks');
    await page.locator('#message').fill('Existing second-session draft');
    await page.locator('#tabs').selectOption('one');
    await expect(page.locator('#terminal')).toHaveText('');
    await page.locator('#message').fill('Draft for the restarted session');
    await page.locator('#restart').click();
    await expect(page.locator('#tabs')).toHaveValue('two');
    await expect(page.locator('#message')).toHaveValue('Existing second-session draft');
    await page.locator('#tabs').selectOption('restarted');
    await expect(page.locator('#message')).toHaveValue('Draft for the restarted session');
  } finally { mac.close(); }
});

test('restart retains draft and attachments while its tab is outside the capped list', async ({ page, baseURL }) => {
  const tabs = Array.from({ length: 99 }, (_, i) => ({ id: `tab-${i}`, title: `Session ${i}`, status: 'idle' }));
  const original = { id: 'one', title: 'Hidden restart', status: 'idle', provider: 'grokBuild', sessionID: 'native-one', cwd: '/tmp/one' };
  const state = { tabs: [...tabs, original], selectedTabID: 'one', terminal: '', capabilities: ['restart'], tabsTruncated: true };
  const options = { state, restart: true, onRequest(request) {
    if (request.action === 'restart') {
      state.tabs = [...tabs, { id: 'tab-99', title: 'Session 99', status: 'idle' }];
      state.selectedTabID = 'tab-0';
    }
  } };
  const mac = await pair(page, baseURL, '', options);
  try {
    await page.locator('#message').fill('Keep my hidden-session draft');
    await page.locator('#attach').setInputFiles({ name: 'notes.txt', mimeType: 'text/plain', buffer: Buffer.from('Test attachment') });
    original.status = 'exited';
    await expect(page.locator('#restart')).toBeVisible();
    await page.locator('#restart').click();
    await expect(page.locator('#tabs')).toHaveValue('tab-0');
    const polls = mac.actions.filter(a => a.action === 'state').length;
    await expect.poll(() => mac.actions.filter(a => a.action === 'state').length).toBeGreaterThan(polls);
    state.tabs = [...tabs, { id: 'restarted', title: 'Hidden restart', status: 'idle', provider: 'grokBuild', sessionID: 'native-one', cwd: '/tmp/one' }];
    state.selectedTabID = 'restarted';
    await expect(page.locator('#tabs')).toHaveValue('restarted');
    await expect(page.locator('#message')).toHaveValue('Keep my hidden-session draft');
    await expect(page.locator('#attachments')).toContainText('notes.txt');
    state.tabs = [tabs[0]];
    state.selectedTabID = 'tab-0';
    state.tabsTruncated = false;
    await expect(page.locator('#tabs')).toHaveValue('tab-0');
    state.tabs = [tabs[0], { id: 'restarted', title: 'Hidden restart', status: 'idle', provider: 'grokBuild', sessionID: 'native-one', cwd: '/tmp/one' }];
    state.selectedTabID = 'restarted';
    await expect(page.locator('#tabs')).toHaveValue('restarted');
    await expect(page.locator('#message')).toHaveValue('');
    await expect(page.locator('#attachments')).toBeHidden();
  } finally { mac.close(); }
});

test('unverified menu shows the full operation and only literal terminal choices', async ({ page, baseURL }, testInfo) => {
  await page.setViewportSize({ width: 390, height: 844 });
  const operation = `Inspect ${'long-path/'.repeat(36)}critical-end.txt`;
  const mac = await pair(page, baseURL, '', { state: {
    tabs: [{ id: 'one', title: 'Review', status: 'working', provider: 'codex', processRunning: true,
      capabilities: { structuredApproval: false, resume: true } }],
    selectedTabID: 'one', terminal: 'Which file?\n1. README.md\n2. CHANGELOG.md',
    prompt: { id: 'instance-one', question: 'Which file?', operation, verified: false,
      style: 'menu', choices: [{ label: 'README.md', key: '1' }, { label: 'CHANGELOG.md', key: '2' }] },
  } });
  try {
    await expect(page.locator('#interaction')).toBeVisible();
    await expect(page.locator('#interaction-heading')).toHaveText('Terminal controls');
    await expect(page.locator('#interaction-operation')).toHaveText(operation);
    await expect(page.locator('#interaction').getByRole('button', { name: 'Yes', exact: true })).toHaveCount(0);
    await page.locator('#interaction').getByRole('button', { name: 'README.md', exact: true }).click();
    await expect.poll(() => mac.actions.filter(a => a.action === 'key' && a.text === '1').length).toBe(1);
    expect(mac.actions.some(a => a.action === 'answer')).toBe(false);
    expect(mac.actions.find(a => a.action === 'key' && a.text === '1').text).toBe('1');
    await page.screenshot({ path: testInfo.outputPath('unverified-operation.png') });
  } finally { mac.close(); }
});

test('unknown lifecycle stays explicit and unsupported restart stays hidden', async ({ page, baseURL }) => {
  const state = { tabs: [{ id: 'one', title: 'Codex', status: 'unknown', provider: 'codex',
    processRunning: true, capabilities: { resume: false, history: true } }], selectedTabID: 'one', terminal: 'Provider output',
    capabilities: ['restart'] };
  const mac = await pair(page, baseURL, '', { state });
  try {
    await expect(page.locator('#session-status')).toHaveText('Status unknown');
    state.tabs[0].status = 'exited'; state.tabs[0].processRunning = false;
    await expect(page.locator('#session-status')).toHaveText('Session ended');
    await expect(page.locator('#restart')).toBeHidden();
    state.terminal = '';
    await expect(page.locator('#empty-output')).toContainText('Open this conversation from Chats.');
  } finally { mac.close(); }
});


test('a replayed old hello and sealed reply cannot authenticate a fresh browser connection', async ({ page, baseURL }) => {
  const options = { reuseChallenge: true };
  const mac = await pair(page, baseURL, 'AUTHENTICATED_OUTPUT', options);
  try {
    await expect(page.locator('#terminal')).toContainText('AUTHENTICATED_OUTPUT');
    options.replayReplies = true;
    await page.reload();
    await page.waitForTimeout(1200);
    await expect(page.locator('#status')).not.toHaveText('Connected');
    await expect(page.locator('#terminal')).not.toContainText('AUTHENTICATED_OUTPUT');
    expect(mac.actions.some(a => ['input', 'answer', 'key'].includes(a.action))).toBe(false);
  } finally { mac.close(); }
});

test('an old Mac without the authenticated client nonce gets a clear upgrade error', async ({ page, baseURL }) => {
  const mac = await pair(page, baseURL, '', { omitNonce: true, skipNavigate: true });
  try {
    await page.goto(`${baseURL}/#room=${mac.room}&key=${mac.bootstrap}`);
    await expect(page.locator('#error')).toContainText('Update Sigil on your Mac');
    await expect(page.locator('#controls')).toBeHidden();
  } finally { mac.close(); }
});

const webNewOptions = {
  providers: [{ id: 'grokBuild', name: 'Grok Build', takesModel: true }, { id: 'claudeCode', name: 'Claude Code', takesModel: false },
    { id: 'kimi', name: 'Kimi Code', takesModel: false, problem: 'Set up Kimi Code sign-in in Sigil on your Mac, then try again.' }],
  provider: 'grokBuild', models: ['grok-4.6', 'grok-fast'], model: 'grok-4.6',
  efforts: [{ id: '', name: 'CLI default' }, { id: 'high', name: 'High' }], effort: 'high',
  locations: [{ name: '~/Code', folder: '/tmp/code' }], startsInWorktree: true,
};
const webNewProjects = [
  { name: 'Sigil', folder: '/tmp/code/sigil', repository: true, worktreeDefault: true },
  { name: 'Home repository', folder: '/tmp/home', repository: true, worktreeDefault: false },
  { name: 'Notes', folder: '/tmp/notes', repository: false },
];
function webNewState() {
  return { tabs: [{ id: 'one', title: 'Synthetic task', status: 'idle', provider: 'grokBuild', sessionID: 'fixture-session', cwd: '/tmp/code/sigil' }],
    selectedTabID: 'one', terminal: 'Synthetic output', capabilities: ['sessionOps'] };
}

test('REA-1206 New sheet sends advertised choices and shows repository defaults at phone size', async ({ page, baseURL }, testInfo) => {
  await page.setViewportSize({ width: 390, height: 844 });
  const errors = []; page.on('pageerror', error => errors.push(error.message));
  const mac = await pair(page, baseURL, undefined, { state: webNewState(), sessionOptions: webNewOptions, projects: webNewProjects });
  try {
    await page.getByRole('button', { name: 'New session', exact: true }).click();
    const dialog = page.locator('#project-dialog'); await expect(dialog).toBeVisible();
    await expect(page.getByLabel('Model', { exact: true })).toHaveValue('grok-4.6');
    const worktree = page.getByRole('switch', { name: 'Start in a new worktree' });
    await expect(worktree).toBeChecked();
    await page.screenshot({ path: testInfo.outputPath('rea-1206-new-session.png'), animations: 'disabled' });
    await testInfo.attach('New session · 390×844', { path: testInfo.outputPath('rea-1206-new-session.png'), contentType: 'image/png' });
    await page.getByRole('button', { name: 'Home repository /tmp/home' }).click();
    await expect(worktree).not.toBeChecked();
    await worktree.check();
    await page.getByLabel('Model', { exact: true }).selectOption('grok-fast');
    await page.getByLabel('Effort', { exact: true }).selectOption('');
    await page.getByRole('button', { name: 'Start session', exact: true }).click();
    await expect(dialog).not.toBeVisible();
    expect(mac.actions.filter(request => request.action === 'new')).toMatchObject([
      { text: '/tmp/home', provider: 'grokBuild', model: 'grok-fast', effort: '', worktree: true },
    ]);
    await page.getByRole('button', { name: 'New session', exact: true }).click();
    await page.getByLabel('CLI', { exact: true }).selectOption('kimi');
    await expect(page.getByRole('button', { name: 'Start session', exact: true })).toBeDisabled();
    await expect(page.locator('#provider-problem')).toContainText('Set up Kimi Code');
    await page.getByLabel('CLI', { exact: true }).selectOption('claudeCode');
    await expect(page.getByLabel('Model', { exact: true })).not.toBeVisible();
    await page.getByRole('button', { name: 'Notes /tmp/notes' }).click();
    await expect(worktree).not.toBeVisible();
    await page.getByRole('button', { name: 'Start session', exact: true }).click();
    await expect(dialog).not.toBeVisible();
    const last = mac.actions.filter(request => request.action === 'new').at(-1);
    expect(last.provider).toBe('claudeCode'); expect(last.model).toBeUndefined(); expect(last.effort).toBeUndefined(); expect(last.worktree).toBeUndefined();
    expect(errors).toEqual([]);
  } finally { mac.close(); }
});

test('REA-1206 New project validates, adopts an existing folder and selects without starting', async ({ page, baseURL }, testInfo) => {
  await page.setViewportSize({ width: 390, height: 844 });
  const existing = { name: 'existing', folder: '/tmp/code/existing', repository: true, worktreeDefault: false };
  const options = { state: webNewState(), sessionOptions: webNewOptions, projects: webNewProjects, createProject() { options.projects = [existing, ...webNewProjects]; return existing; } };
  const mac = await pair(page, baseURL, undefined, options);
  try {
    await page.getByRole('button', { name: 'New session', exact: true }).click();
    await page.getByRole('button', { name: 'New project', exact: true }).click();
    await page.getByLabel('Folder name').fill('../escape');
    await expect(page.getByRole('button', { name: 'Create project', exact: true })).toBeDisabled();
    await page.getByLabel('Folder name').fill('existing');
    await expect(page.getByLabel('Location', { exact: true })).toHaveValue('/tmp/code');
    await page.screenshot({ path: testInfo.outputPath('rea-1206-new-project.png'), animations: 'disabled' });
    await testInfo.attach('New project · 390×844', { path: testInfo.outputPath('rea-1206-new-project.png'), contentType: 'image/png' });
    await page.getByRole('button', { name: 'Back', exact: true }).click();
    expect(mac.actions.filter(request => request.action === 'createProject')).toHaveLength(0);
    await page.getByRole('button', { name: 'New project', exact: true }).click();
    await page.getByLabel('Folder name').fill(' existing ');
    await page.getByRole('button', { name: 'Create project', exact: true }).click();
    await expect(page.locator('#new-project-form')).not.toBeVisible();
    await expect(page.locator('#project-list button').first()).toHaveAttribute('aria-pressed', 'true');
    await expect(page.getByRole('switch')).not.toBeChecked();
    expect(mac.actions.filter(request => request.action === 'createProject')).toMatchObject([{ text: '/tmp/code', name: 'existing' }]);
    expect(mac.actions.filter(request => request.action === 'new')).toHaveLength(0);
    await page.getByRole('button', { name: 'Cancel', exact: true }).click();
    expect(mac.actions.filter(request => request.action === 'new')).toHaveLength(0);
  } finally { mac.close(); }
});

test('REA-1206 a lost start stays blocked after reconnect and reload without matching by folder or title', async ({ page, baseURL }, testInfo) => {
  await page.setViewportSize({ width: 390, height: 844 });
  let hold = true;
  const mac = await pair(page, baseURL, undefined, { state: webNewState(), sessionOptions: webNewOptions, projects: webNewProjects,
    onRequest(request) { if (hold && request.action === 'new') return false; } });
  try {
    await page.getByRole('button', { name: 'New session', exact: true }).click();
    await page.getByRole('button', { name: 'Start session', exact: true }).click();
    await expect(page.locator('#new-outcome')).toContainText('Waiting for the Mac');
    await page.getByRole('button', { name: 'Cancel', exact: true }).click();
    await page.reload(); hold = false;
    await expect(page.locator('#status')).toHaveText('Connected');
    await page.getByRole('button', { name: 'New session', exact: true }).click();
    await expect(page.locator('#new-outcome')).toContainText('session start result is unknown');
    await expect(page.getByRole('button', { name: 'Start session', exact: true })).toBeDisabled();
    await expect(page.getByLabel('CLI', { exact: true })).toBeDisabled();
    await page.screenshot({ path: testInfo.outputPath('rea-1206-unknown-start.png'), animations: 'disabled' });
    await testInfo.attach('Unknown start · 390×844', { path: testInfo.outputPath('rea-1206-unknown-start.png'), contentType: 'image/png' });
    expect(mac.actions.filter(request => request.action === 'new')).toHaveLength(1);
  } finally { mac.close(); }
});

test('REA-1206 a lost project result uses exact authoritative project pages without another create', async ({ page, baseURL }) => {
  await page.setViewportSize({ width: 390, height: 844 });
  let hold = true;
  const created = { name: 'fresh', folder: '/tmp/code/fresh', repository: false };
  const options = { state: webNewState(), sessionOptions: webNewOptions, projects: webNewProjects,
    onRequest(request) { if (hold && request.action === 'createProject') return false; } };
  const mac = await pair(page, baseURL, undefined, options);
  try {
    await page.getByRole('button', { name: 'New session', exact: true }).click();
    await page.getByRole('button', { name: 'New project', exact: true }).click();
    await page.getByLabel('Folder name').fill('fresh');
    await page.getByRole('button', { name: 'Create project', exact: true }).click();
    await expect(page.locator('#new-outcome')).toContainText('Waiting for the Mac');
    await page.reload(); hold = false;
    await expect(page.locator('#status')).toHaveText('Connected');
    await page.getByRole('button', { name: 'New session', exact: true }).click();
    options.projects = [{ ...created, folder: '/other/fresh' }];
    await page.getByRole('button', { name: 'Check projects', exact: true }).click();
    await expect(page.locator('#project-error')).toContainText('exact folder is not');
    await expect(page.getByRole('button', { name: 'Start session', exact: true })).toBeDisabled();
    options.projects = [created];
    await page.getByRole('button', { name: 'Check projects', exact: true }).click();
    await expect(page.locator('#new-outcome')).not.toBeVisible();
    await expect(page.getByRole('button', { name: 'Start session', exact: true })).toBeEnabled();
    expect(mac.actions.filter(request => request.action === 'createProject')).toHaveLength(1);
  } finally { mac.close(); }
});

test('REA-1206 Cancel during creation does not cancel dispatch or reopen the sheet on a late reply', async ({ page, baseURL }) => {
  await page.setViewportSize({ width: 390, height: 844 });
  let release;
  const gate = new Promise(resolve => { release = resolve; });
  const created = { name: 'fresh', folder: '/tmp/code/fresh', repository: false };
  const options = { state: webNewState(), sessionOptions: webNewOptions, projects: webNewProjects,
    async onRequest(request) { if (request.action === 'createProject') await gate; },
    createProject() { options.projects = [created]; return created; } };
  const mac = await pair(page, baseURL, undefined, options);
  try {
    await page.getByRole('button', { name: 'New session', exact: true }).click();
    await page.getByRole('button', { name: 'New project', exact: true }).click();
    await page.getByLabel('Folder name').fill('fresh');
    await page.getByRole('button', { name: 'Create project', exact: true }).click();
    await expect(page.locator('#new-outcome')).toContainText('Waiting for the Mac');
    await expect(page.getByRole('button', { name: 'Back', exact: true })).toBeDisabled();
    await page.getByRole('button', { name: 'Cancel', exact: true }).click();
    release();
    await expect(page.getByRole('button', { name: 'New session', exact: true })).toBeEnabled();
    await expect(page.locator('#project-dialog')).not.toBeVisible();
    expect(mac.actions.filter(request => request.action === 'createProject')).toHaveLength(1);
    expect(mac.actions.filter(request => request.action === 'new')).toHaveLength(0);
  } finally { release(); mac.close(); }
});
