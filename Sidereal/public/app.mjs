import { importKey, randomKey, seal, open } from './crypto.mjs';
import { readableOutput } from './output.mjs';
const $ = id => document.getElementById(id);
const drafts = new Map();
let tabsSignature = '';
let rawOutput = '', rawMode = false;
let credential, bootstrap, newDeviceKey, socket, challenge, sequence = 0, selected;
let selectedStatus = null, tabCount = 0;
let connected = false, busy = false, stopped = false, reconnectTimer, pollTimer, connectTimer, generation = 0;
let incoming = Promise.resolve(), outgoing = Promise.resolve(), pending = new Map();
const showError = text => { $('error').textContent = text; $('error').hidden = !text; };

async function storage(mode, value) {
  const db = await new Promise((resolve, reject) => {
    const request = indexedDB.open('sidereal', 1);
    request.onupgradeneeded = () => request.result.createObjectStore('pairing');
    request.onsuccess = () => resolve(request.result);
    request.onerror = () => reject(request.error);
  });
  try {
    return await new Promise((resolve, reject) => {
      const transaction = db.transaction('pairing', mode === 'get' ? 'readonly' : 'readwrite');
      const store = transaction.objectStore('pairing');
      const request = mode === 'get' ? store.get('mac') : mode === 'delete' ? store.delete('mac') : store.put(value, 'mac');
      transaction.oncomplete = () => resolve(request.result);
      transaction.onerror = () => reject(transaction.error);
      transaction.onabort = () => reject(transaction.error);
    });
  } finally { db.close(); }
}
function updateControls() {
  const disabled = !connected || busy;
  const ended = selectedStatus === 'exited';
  document.querySelectorAll('#controls button, #controls textarea, #session-toolbar button, #session-toolbar select').forEach(element => {
    // Never disable a focused editor while a command is pending: it closes the phone keyboard.
    if (element.id === 'message') { element.disabled = !selected; return; }
    if (element.id === 'keys-toggle' || element.id === 'latest') { element.disabled = false; return; }
    if (element.id === 'new') { element.disabled = disabled; return; }
    if (element.id === 'tabs') { element.disabled = disabled || tabCount === 0; return; }
    element.disabled = disabled || !selected || ended;
  });
  $('send').disabled = disabled || !selected || ended || !$('message').value.trim();
  $('raw-toggle').hidden = !selected;
  $('forget').hidden = !credential;
  $('reconnect').hidden = !credential || connected;
}
function offline(message = 'Disconnected') {
  connected = false;
  $('status').textContent = message;
  $('status').dataset.connected = 'false';
  clearTimeout(pollTimer);
  clearTimeout(connectTimer);
  for (const item of pending.values()) { clearTimeout(item.timer); item.reject(new Error('Connection lost. Check the terminal before sending again.')); }
  pending.clear();
  updateControls();
}
function render(state) {
  if (!state || !Array.isArray(state.tabs) || state.tabs.length > 100 || typeof state.terminal !== 'string') throw new Error('Invalid Mac response');
  const nextSelected = state.selectedTabID ?? null;
  const ids = new Set();
  for (const tab of state.tabs) {
    if (!tab || typeof tab.id !== 'string' || !tab.id || typeof tab.title !== 'string'
      || !['starting', 'working', 'idle', 'exited'].includes(tab.status) || ids.has(tab.id)) {
      throw new Error('Invalid Mac response');
    }
    ids.add(tab.id);
  }
  if (nextSelected !== null && (typeof nextSelected !== 'string' || !ids.has(nextSelected))) {
    throw new Error('Invalid Mac response');
  }
  const changedSession = selected !== nextSelected;
  if (changedSession) {
    if (selected) drafts.set(selected, $('message').value);
    $('message').value = drafts.get(nextSelected) || '';
  }
  selected = nextSelected;
  selectedStatus = selected ? state.tabs.find(tab => tab.id === selected).status : null;
  tabCount = state.tabs.length;
  for (const id of drafts.keys()) { if (!state.tabs.some(tab => tab.id === id)) drafts.delete(id); }
  const tabs = state.tabs.map(tab => {
    const option = document.createElement('option');
    option.value = tab.id;
    const suffix = tab.status === 'working' ? ' · Working'
      : tab.status === 'exited' ? ' · Ended' : tab.status === 'starting' ? ' · Starting' : '';
    option.textContent = `${tab.title}${suffix}`;
    return option;
  });
  if (!tabs.length) { const empty = document.createElement('option'); empty.value = ''; empty.textContent = 'No open sessions'; tabs.push(empty); }
  const signature = JSON.stringify(state.tabs);
  if (signature !== tabsSignature) { $('tabs').replaceChildren(...tabs); tabsSignature = signature; }
  $('tabs').value = selected || '';
  $('welcome').hidden = true;
  $('controls').hidden = false;
  rawOutput = state.terminal;
  $('session-toolbar').hidden = false;
  $('brand').hidden = true;
  renderOutput(changedSession);
  if (changedSession) resizeMessage();
  updateControls();
}
function renderOutput(changedSession = false) {
  const terminal = $('terminal');
  const atBottom = terminal.scrollHeight - terminal.scrollTop - terminal.clientHeight < 60;
  const output = rawMode ? rawOutput : readableOutput(rawOutput);
  $('empty-output').hidden = Boolean(output);
  const ended = Boolean(selected) && selectedStatus === 'exited';
  $('empty-output').querySelector('h2').textContent = ended ? 'Session ended' : selected ? 'Ready when you are.' : 'No open sessions.';
  $('empty-output').querySelector('p').textContent = ended ? 'Restart this session in Sigil on your Mac.' : selected ? 'Send a message to this session.' : 'Choose New to start a session.';
  terminal.dataset.raw = String(rawMode);
  if (terminal.textContent !== output || changedSession) {
    terminal.textContent = output;
    if (atBottom || changedSession) terminal.scrollTop = terminal.scrollHeight;
  }
  updateLatest();
}

async function request(action, text, tabID = selected, pairing = false) {
  const current = generation;
  const previous = outgoing;
  let release;
  outgoing = new Promise(resolve => { release = resolve; });
  await previous;
  try {
    if (current !== generation) throw new Error("Connection changed. Check the terminal before sending again.");
    return await transmit(action, text, tabID, pairing);
  } finally { release(); }
}
async function transmit(action, text, tabID, pairing) {
  if (!socket || socket.readyState !== WebSocket.OPEN || !challenge || (!connected && !pairing && action !== 'state')) throw new Error('Not connected.');
  const ws = socket, current = generation, seq = ++sequence;
  const message = { challenge, sequence: seq, action, ...(tabID ? { tabID } : {}), ...(text !== undefined ? { text } : {}) };
  const data = await seal(message, pairing ? bootstrap : credential.key, 'phone');
  if (current !== generation || ws.readyState !== WebSocket.OPEN) throw new Error('Connection lost.');
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => {
      pending.delete(seq);
      reject(new Error('No response. Check the terminal before sending again.'));
      ws.close();
    }, 10000);
    pending.set(seq, { resolve, reject, timer });
    ws.send(JSON.stringify({ data }));
  });
}
function poll() {
  clearTimeout(pollTimer);
  pollTimer = setTimeout(async () => {
    if (!connected || document.hidden) return;
    if (!busy) { try { await request('state'); } catch (error) { showError(error.message); } }
    if (connected) poll();
  }, 1000);
}
function connect() {
  clearTimeout(reconnectTimer);
  if (!credential || stopped) return;
  const current = ++generation;
  socket?.close();
  offline('Connecting…');
  challenge = null; sequence = 0;
  const url = new URL('/connect', location.origin);
  url.protocol = location.protocol === 'https:' ? 'wss:' : 'ws:';
  url.search = new URLSearchParams({ room: credential.room, role: 'phone' });
  const ws = socket = new WebSocket(url);
  connectTimer = setTimeout(() => {
    if (current !== generation || socket !== ws) return;
    showError('The Mac did not respond. Keep Sigil open and try again.');
    ws.close();
  }, 10000);
  incoming = Promise.resolve();
  ws.onmessage = event => {
    incoming = incoming.then(async () => {
      if (current !== generation) return;
      if (typeof event.data !== 'string' || event.data.length > 110000) throw new Error('Invalid response');
      const frame = JSON.parse(event.data);
      if (typeof frame.hello === 'string' && /^[a-f0-9]{64}$/.test(frame.hello)) {
        if (challenge) throw new Error('Unexpected handshake');
        challenge = frame.hello;
        const authorization = bootstrap ? request('pair', newDeviceKey, undefined, true) : request('state');
        authorization.then(() => {
          if (current !== generation) return;
          bootstrap = null; newDeviceKey = null;
          clearTimeout(connectTimer);
          connected = true; busy = false;
          $('status').textContent = 'Connected'; $('status').dataset.connected = 'true';
          showError(''); updateControls(); poll();
        }).catch(error => { showError(error.message); });
      } else if (frame.error === 'unauthorized') {
        // A dropped pairing acknowledgement can leave the Mac already using the device key.
        if (bootstrap) { bootstrap = null; newDeviceKey = null; ws.close(); }
        else { stopped = true; showError('Pairing expired or was disconnected. Scan a new code in Sigil.'); ws.close(); }
      } else if (frame.data) {
        const reply = await open(frame.data, credential.key, 'mac');
        if (current !== generation) return;
        const item = pending.get(reply.sequence);
        if (!item || reply.challenge !== challenge) throw new Error('Invalid response');
        if (reply.ok !== true) {
          pending.delete(reply.sequence); clearTimeout(item.timer);
          item.reject(new Error(reply.error || 'The Mac could not complete this action.'));
          return;
        }
        if (reply.state) render(reply.state);
        pending.delete(reply.sequence); clearTimeout(item.timer);
        item.resolve(reply);
      } else throw new Error('Invalid response');
    }).catch(() => { if (current === generation) { showError('Could not verify the connection.'); ws.close(); } });
  };
  ws.onclose = () => {
    if (current !== generation) return;
    offline();
    if (!stopped) reconnectTimer = setTimeout(connect, 3000);
  };
  ws.onerror = () => { if (current === generation) showError('Cannot reach Sigil. Keep the Mac awake and connected.'); };
}
async function perform(work) {
  if (!connected || busy) return;
  const current = generation;
  busy = true; updateControls(); showError('');
  try { await work(); }
  catch (error) { showError(error.message); $('tabs').value = selected || ''; }
  finally { if (generation === current) { busy = false; updateControls(); } }
}
async function sendText(submit) {
  const text = $('message').value;
  if (!text.trim()) return;
  if (new TextEncoder().encode(text).length > 8192) { showError('Keep the message under 8 KB.'); return; }
  const target = selected, current = generation;
  await request('input', text, target);
  if (current !== generation) throw new Error('Connection changed. Check the terminal before sending again.');
  if (submit) {
    await new Promise(resolve => setTimeout(resolve, 100));
    if (current !== generation) throw new Error('Connection changed. Check the terminal before sending again.');
    await request('key', 'enter', target);
  }
  if (selected === target && $('message').value === text) {
    $('message').value = ''; resizeMessage();
  } else if (selected !== target && drafts.get(target) === text) {
    drafts.delete(target);
  }
}
function updateLatest() {
  const terminal = $('terminal');
  $('latest').hidden = terminal.scrollHeight - terminal.scrollTop - terminal.clientHeight < 60;
}
function resizeMessage() {
  const terminal = $('terminal');
  const atBottom = terminal.scrollHeight - terminal.scrollTop - terminal.clientHeight < 60;
  const message = $('message');
  message.style.height = 'auto';
  message.style.height = `${message.scrollHeight + 2}px`;
  if (atBottom) terminal.scrollTop = terminal.scrollHeight;
  updateLatest();
}
function updateViewport() {
  const viewport = window.visualViewport;
  // Leave pinch zoom to the browser; only follow normal keyboard/browser resizing.
  if (!viewport || viewport.scale !== 1) return;
  const terminal = $('terminal');
  const atBottom = terminal.scrollHeight - terminal.scrollTop - terminal.clientHeight < 60;
  document.documentElement.style.setProperty('--viewport-height', `${viewport.height}px`);
  document.documentElement.style.setProperty('--viewport-top', `${viewport.offsetTop}px`);
  if (atBottom) terminal.scrollTop = terminal.scrollHeight;
  updateLatest();
}
window.visualViewport?.addEventListener('resize', updateViewport);
window.visualViewport?.addEventListener('scroll', updateViewport);
updateViewport();
$('raw-toggle').onclick = () => {
  rawMode = !rawMode;
  $('raw-toggle').setAttribute('aria-pressed', String(rawMode));
  $('raw-toggle').textContent = rawMode ? 'Show readable output' : 'Show raw terminal';
  renderOutput(true);
};
$('message').oninput = () => { resizeMessage(); updateControls(); };
$('terminal').onscroll = updateLatest;
$('latest').onclick = () => { $('terminal').scrollTop = $('terminal').scrollHeight; updateLatest(); };
$('keys-toggle').onclick = () => {
  const terminal = $('terminal');
  const atBottom = terminal.scrollHeight - terminal.scrollTop - terminal.clientHeight < 60;
  const expanded = $('keys-toggle').getAttribute('aria-expanded') !== 'true';
  $('keys-toggle').setAttribute('aria-expanded', String(expanded));
  $('keys').hidden = !expanded;
  if (atBottom) terminal.scrollTop = terminal.scrollHeight;
  updateLatest();
};
$('compose').onsubmit = event => { event.preventDefault(); void perform(() => sendText(true)); };
$('paste').onclick = () => void perform(() => sendText(false));
$('tabs').onchange = () => void perform(() => request('select', undefined, $('tabs').value));
$('new').onclick = () => void perform(() => request('new'));
$('interrupt').onclick = () => void perform(() => request('key', 'interrupt'));
document.querySelectorAll('[data-key]').forEach(button => { button.onclick = () => void perform(() => request('key', button.dataset.key)); });
$('reconnect').onclick = () => { stopped = false; connect(); };
$('forget').onclick = async () => {
  stopped = true; ++generation; clearTimeout(reconnectTimer); socket?.close(); offline();
  credential = null; bootstrap = null; newDeviceKey = null; selected = null; drafts.clear(); tabsSignature = '';
  selectedStatus = null; tabCount = 0;
  $('keys').hidden = true; $('keys-toggle').setAttribute('aria-expanded', 'false');
  rawOutput = ''; rawMode = false;
  $('raw-toggle').setAttribute('aria-pressed', 'false'); $('raw-toggle').textContent = 'Show raw terminal';
  $('session-toolbar').hidden = true; $('brand').hidden = false;
  $('terminal').textContent = ''; $('message').value = ''; $('controls').hidden = true; $('welcome').hidden = false;
  try { await storage('delete'); showError(''); } catch { showError('Could not clear pairing. Clear this site’s data in browser settings.'); }
  updateControls();
};
document.addEventListener('keydown', event => {
  const details = $('connection');
  if (event.key === 'Escape' && details.open) { details.open = false; $('connection-toggle').focus(); }
});
document.addEventListener('pointerdown', event => {
  const details = $('connection');
  if (details.open && !details.contains(event.target)) details.open = false;
});
document.addEventListener('visibilitychange', () => {
  if (document.hidden) { clearTimeout(pollTimer); }
  else if (connected) poll();
  else if (!stopped) connect();
});
async function start() {
  const fragment = new URLSearchParams(location.hash.slice(1));
  history.replaceState(null, '', location.pathname);
  if (!crypto.subtle) throw new Error('Open Sidereal using HTTPS.');
  if (fragment.has('room') || fragment.has('key')) {
    const room = fragment.get('room');
    if (!/^[a-f0-9]{32}$/.test(room)) throw new Error('Invalid code. Scan a new code in Sigil.');
    bootstrap = await importKey(fragment.get('key'));
    newDeviceKey = randomKey();
    credential = { room, key: await importKey(newDeviceKey) };
    await storage('put', credential);
  } else credential = await storage('get');
  updateControls();
  if (credential) connect();
  if ('serviceWorker' in navigator) navigator.serviceWorker.register('/sw.js').catch(() => {});
}
start().catch(error => showError(error.message));
// A camera scan can reuse the open page and change only its fragment.
window.addEventListener('hashchange', () => { if (location.hash) location.reload(); });
