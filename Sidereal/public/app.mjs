import { importKey, randomKey, seal, open } from './crypto.mjs';
import { readableOutput } from './output.mjs';
import { pairingFromText } from './pairing.mjs';
const $ = id => document.getElementById(id);
const drafts = new Map();
const attachmentDrafts = new Map();
const MAX_REMOTE_BYTES = 4 * 1024 * 1024;
const CHUNK = 32 * 1024;
let lastChunkAt = 0;
function attachmentsFor(id = selected) {
  if (!id) return [];
  if (!attachmentDrafts.has(id)) attachmentDrafts.set(id, []);
  return attachmentDrafts.get(id);
}
function remoteFileName(name) {
  const base = String(name || 'file').split(/[/\\]/).pop();
  const clean = part => [...part].map(ch => /[\p{L}\p{M}\p{N}._-]/u.test(ch) ? ch : '-').join('')
    .replace(/-+/g, '-').replace(/^[.-]+|[.-]+$/g, '');
  const bytes = value => new TextEncoder().encode(value).length;
  // Keep the extension: the Mac CLI reads the file type from it.
  const dot = base.lastIndexOf('.');
  let ext = dot > 0 ? clean(base.slice(dot + 1)) : '';
  if (bytes(ext) > 16) ext = '';
  const suffix = ext ? `.${ext}` : '';
  const stem = [...(clean(ext ? base.slice(0, dot) : base) || 'file')];
  while (stem.length > 1 && bytes(stem.join('') + suffix) > 80) stem.pop();
  return (stem.join('').replace(/[.-]+$/, '') || 'file') + suffix;
}
let tabsSignature = '';
let sessionTabs = [], canRestart = false;
const histories = new Map();
let pendingEarlier = null, earlierFlight = false, searchToken = 0;
let findIndex = 0, findMatches = [], displayedOutput = null;
let rawOutput = '', rawMode = false;
let credential, bootstrap, newDeviceKey, socket, challenge, sequence = 0, selected;
let selectedStatus = null, tabCount = 0;
let connected = false, busy = false, stopped = false, revoked = false, reconnectTimer, pollTimer, connectTimer, generation = 0;
let commandEpoch = 0, reconnectDelay = 500;
let incoming = Promise.resolve(), outgoing = Promise.resolve(), pending = new Map();
// A modal sheet makes the page inert, so its errors show inside the sheet.
const sheetErrors = { 'sessions-dialog': 'sessions-error', 'project-dialog': 'project-error' };
const showError = text => {
  const open = Object.keys(sheetErrors).find(id => $(id).open);
  for (const id of ['error', ...Object.values(sheetErrors)]) { $(id).textContent = ''; $(id).hidden = true; }
  const target = $(open ? sheetErrors[open] : 'error');
  target.textContent = text; target.hidden = !text;
};
for (const [dialog, id] of Object.entries(sheetErrors)) {
  $(dialog).addEventListener('close', () => { if ($(id).textContent) showError($(id).textContent); });
}

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
    if (['keys-toggle', 'latest', 'find-toggle', 'find-close', 'find-next', 'find-previous', 'sessions-toggle'].includes(element.id)) { element.disabled = false; return; }
    if (element.id === 'restart') { element.disabled = disabled || !ended; return; }
    if (element.id === 'new') { element.disabled = disabled; return; }
    if (element.id === 'tabs') { element.disabled = disabled || tabCount === 0; return; }
    if (element.id === 'stop' || element.id === 'interrupt') {
      element.disabled = !connected || !selected || ended; return;
    }
    element.disabled = disabled || !selected || ended;
  });
  $('send').disabled = disabled || !selected || ended || !($('message').value.trim() || attachmentsFor().length);
  $('stop').hidden = selectedStatus !== 'working';
  $('restart').hidden = !ended || !canRestart;
  $('copy-output').hidden = !selected;
  $('sessions-toggle').hidden = !connected;
  $('session-status').textContent = !connected ? 'Reconnecting…' : ({ working: 'Working', starting: 'Starting…', idle: 'Ready', exited: 'Session ended' }[selectedStatus] || 'No session');
  $('session-status').dataset.state = connected ? selectedStatus || '' : 'offline';
  if (document.body) document.body.dataset.connected = String(connected && !$('controls').hidden);
  // An ended session already says so in the bar above, and Send is off.
  const composeStatus = busy ? 'Sending…' : !connected && selected ? 'Offline · draft kept' : '';
  $('compose-status').textContent = composeStatus;
  // The row under the composer only exists when it has something to say: a
  // status on the phone, or the send shortcut where a hardware keyboard is likely.
  const tools = $('compose-tools');
  if (tools) tools.hidden = !composeStatus && !hasFinePointer();
  $('find-next').disabled = $('find-previous').disabled = !findMatches.length;
  $('raw-toggle').hidden = !selected;
  $('forget').hidden = !credential;
  $('reconnect').hidden = !credential || connected;
  // After the Mac rejects the pairing, scanning again is the way back.
  const waiting = Boolean(credential) && !revoked;
  const actions = $('welcome-actions');
  if (actions) actions.hidden = waiting;
  $('welcome-reconnect').hidden = !credential;
  $('welcome').querySelector('h2').textContent = revoked && credential ? 'Pair again' : credential ? 'Reconnecting to your Mac' : 'Pick up where you left off.';
  $('welcome').querySelector('p').textContent = waiting ? 'Keep Sigil open and your Mac awake.' : 'Your sessions. Your tools. Away from your desk.';
  $('welcome').querySelector('.pairing-steps').hidden = waiting;
  const standalone = isStandaloneApp();
  for (const id of ['standalone-hint', 'standalone-panel-hint']) {
    const hint = $(id);
    if (hint) hint.hidden = !standalone;
  }
}
function hasFinePointer() {
  return typeof window !== 'undefined' && typeof window.matchMedia === 'function'
    && window.matchMedia('(pointer: fine)').matches;
}
function isStandaloneApp() {
  if (typeof navigator !== 'undefined' && navigator.standalone) return true;
  if (typeof window === 'undefined' || typeof window.matchMedia !== 'function') return false;
  const isiOS = /iPhone|iPad|iPod/.test(navigator.userAgent || '')
    || (navigator.platform === 'MacIntel' && navigator.maxTouchPoints > 1);
  return isiOS && window.matchMedia('(display-mode: standalone)').matches;
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
function historyFor(id) {
  if (!histories.has(id)) histories.set(id, { history: '', tail: '', exhausted: false });
  return histories.get(id);
}
function overlapSuffixPrefix(left, right) {
  if (!left || !right) return 0;
  const max = Math.min(left.length, right.length);
  const begin = left.length - max;
  const first = right[0];
  for (let i = begin; i < left.length; i++) {
    if (left[i] !== first) continue;
    if (right.startsWith(left.slice(i))) return left.length - i;
  }
  return 0;
}
function applyTail(bucket, next) {
  const loaded = bucket.history + bucket.tail;
  if (!loaded) { bucket.tail = next; return; }
  if (next && loaded.endsWith(next)) {
    bucket.history = loaded.slice(0, loaded.length - next.length);
    bucket.tail = next;
    return;
  }
  const overlap = overlapSuffixPrefix(loaded, next);
  if (overlap > 0) {
    bucket.history = loaded.slice(0, loaded.length - overlap);
    bucket.tail = next;
    return;
  }
  const shared = commonPrefixLength(bucket.tail, next);
  const shorter = Math.min(bucket.tail.length, next.length);
  if (shorter > 0 && shared * 2 >= shorter) {
    bucket.tail = next;
    return;
  }
  // A sliding window under a fixed footer has no suffix/prefix overlap.
  // Keep only the old text that scrolled out above the new snapshot's start.
  // Repeated blocks can match early; take the match that agrees longest, then the latest.
  const start = next.slice(0, 200);
  let at = -1, agreed = -1;
  for (let i = start.trim() ? bucket.tail.indexOf(start) : -1; i >= 0; i = bucket.tail.indexOf(start, i + 1)) {
    const shared = commonPrefixLength(bucket.tail.slice(i), next);
    if (shared >= agreed) { agreed = shared; at = i; }
  }
  const scrolled = at > 0 ? bucket.tail.slice(0, at) : bucket.tail;
  const room = 400_000 - bucket.history.length;
  if (room > 0) bucket.history += scrolled.slice(0, room);
  bucket.tail = next;
}
function commonPrefixLength(left, right) {
  const count = Math.min(left.length, right.length);
  let index = 0;
  while (index < count && left[index] === right[index]) index += 1;
  return index;
}
function prependSlice(bucket, slice) {
  if (typeof slice !== 'string' || new TextEncoder().encode(slice).length > 12_000) {
    bucket.exhausted = true;
    return;
  }
  if (!slice) { bucket.exhausted = true; return; }
  const loaded = bucket.history + bucket.tail;
  const overlap = overlapSuffixPrefix(slice, loaded);
  const addition = slice.slice(0, slice.length - overlap);
  if (!addition || bucket.history.length + addition.length > 400_000) {
    bucket.exhausted = true;
    return;
  }
  bucket.history = addition + bucket.history;
}
function takeChars(text, count) {
  return [...text].slice(0, count).join('');
}
function takeEnd(text, count) {
  const chars = [...text];
  return chars.slice(Math.max(0, chars.length - count)).join('');
}
function utf8Limited(text, bytes) {
  const encoder = new TextEncoder();
  let out = '';
  for (const ch of text) {
    if (encoder.encode(out + ch).length > bytes) break;
    out += ch;
  }
  return out;
}
function render(state) {
  if (!state || !Array.isArray(state.tabs) || state.tabs.length > 100 || typeof state.terminal !== 'string') throw new Error('Invalid Mac response');
  if (state.tabsTruncated !== undefined && typeof state.tabsTruncated !== 'boolean') throw new Error('Invalid Mac response');
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
  const allTabsNew = sessionTabs.length > 0 && !sessionTabs.some(tab => ids.has(tab.id));
  sessionTabs = state.tabs;
  canRestart = Array.isArray(state.capabilities) && state.capabilities.includes('restart');
  const bucket = nextSelected ? historyFor(nextSelected) : null;
  let prepended = false;
  if (bucket) {
    applyTail(bucket, state.terminal);
    if (pendingEarlier) {
      if (pendingEarlier.tabID === nextSelected) {
        const before = bucket.history.length;
        prependSlice(bucket, pendingEarlier.slice);
        prepended = bucket.history.length !== before;
      }
      pendingEarlier = null;
    }
  }
  // Absence from a capped snapshot is not evidence that a tab closed.
  // Older Macs omit the flag, so treat a full 100-row response conservatively.
  const completeTabList = state.tabsTruncated === undefined ? state.tabs.length < 100 : !state.tabsTruncated;
  const changedSession = selected !== nextSelected;
  if (changedSession) {
    if (selected) drafts.set(selected, $('message').value);
    // A Sigil restart gives every tab a new ID. Carry the draft to the tab the Mac selected.
    if (selected && nextSelected && completeTabList && allTabsNew
      && !drafts.get(nextSelected) && !attachmentDrafts.get(nextSelected)?.length) {
      drafts.set(nextSelected, drafts.get(selected));
      if (attachmentDrafts.has(selected)) {
        attachmentDrafts.set(nextSelected, attachmentDrafts.get(selected));
        attachmentDrafts.delete(selected);
      }
    }
    $('message').value = drafts.get(nextSelected) || '';
  }
  selected = nextSelected;
  selectedStatus = selected ? state.tabs.find(tab => tab.id === selected).status : null;
  tabCount = state.tabs.length;
  if (completeTabList) for (const id of histories.keys()) if (!ids.has(id)) histories.delete(id);
  for (const id of drafts.keys()) { if (completeTabList && !ids.has(id)) drafts.delete(id); }
  for (const id of attachmentDrafts.keys()) {
    if (completeTabList && !ids.has(id)) {
      for (const item of attachmentDrafts.get(id) || []) if (item.preview) URL.revokeObjectURL(item.preview);
      attachmentDrafts.delete(id);
    }
  }
  const tabs = state.tabs.map(tab => {
    const option = document.createElement('option');
    option.value = tab.id;
    const suffix = tab.status === 'exited' ? ' · Ended' : '';
    option.textContent = tab.title + suffix;
    return option;
  });
  if (!tabs.length) { const empty = document.createElement('option'); empty.value = ''; empty.textContent = 'No open sessions'; tabs.push(empty); }
  const signature = JSON.stringify(state.tabs);
  if (signature !== tabsSignature) { $('tabs').replaceChildren(...tabs); tabsSignature = signature; }
  $('tabs').value = selected || '';
  $('welcome').hidden = true;
  $('controls').hidden = false;
  rawOutput = bucket ? bucket.history + bucket.tail : state.terminal;
  // Connected, the header is the session: the brand yields to its title.
  $('session-toolbar').hidden = false;
  $('brand').hidden = true;
  if ($('sessions-dialog').open) renderSessionList();
  renderOutput(changedSession, prepended);
  if (changedSession) { resizeMessage(); renderAttachments(); }
  updateControls();
}
function renderOutput(changedSession = false, prepended = false) {
  const terminal = $('terminal');
  const atBottom = terminal.scrollHeight - terminal.scrollTop - terminal.clientHeight < 60;
  const fromEnd = terminal.scrollHeight - terminal.scrollTop;
  const output = rawMode ? rawOutput : readableOutput(rawOutput);
  $('empty-output').hidden = Boolean(output);
  const ended = Boolean(selected) && selectedStatus === 'exited';
  $('empty-output').querySelector('h2').textContent = ended ? 'Session ended' : selectedStatus === 'working' ? 'Working…' : selectedStatus === 'starting' ? 'Starting session…' : selected ? 'Ready when you are.' : 'No open sessions.';
  $('empty-output').querySelector('p').textContent = ended ? (canRestart ? 'Restart to pick up where you left off.' : 'Restart this session in Sigil on your Mac.') : selectedStatus === 'working' || selectedStatus === 'starting' ? 'Output will appear here.' : selected ? 'Send a message to this session.' : 'Choose New to start a session.';
  terminal.dataset.raw = String(rawMode);
  if (displayedOutput !== output || changedSession) {
    displayedOutput = output;
    if (changedSession) findIndex = 0;
    paintOutput();
    if (atBottom || changedSession) terminal.scrollTop = terminal.scrollHeight;
    // Older text went in above the reader. Keep the lines they were reading in place.
    else if (prepended) terminal.scrollTop = terminal.scrollHeight - fromEnd;
  }
  updateLatest();
}

function renderSessionList() {
  const query = $('session-search').value.trim().toLocaleLowerCase();
  const matches = sessionTabs.filter(tab => tab.title.toLocaleLowerCase().includes(query));
  $('session-no-results').hidden = matches.length > 0;
  $('session-no-results').textContent = sessionTabs.length ? 'No matching sessions.' : 'No open sessions.';
  const openHeading = $('open-heading');
  if (openHeading) openHeading.hidden = matches.length === 0;
  // Preserve focus during state polls: only rebuild if the displayed entries change.
  const signature = JSON.stringify([matches, selected]);
  if ($('session-list').dataset.signature === signature) return;
  $('session-list').dataset.signature = signature;
  const focusedID = document.activeElement?.dataset.tabId;
  let nextFocus;
  $('session-list').replaceChildren(...matches.map(tab => {
    const button = document.createElement('button');
    button.type = 'button';
    button.setAttribute('aria-current', String(tab.id === selected));
    button.dataset.tabId = tab.id;
    if (tab.id === focusedID) nextFocus = button;
    const title = document.createElement('span');
    title.textContent = tab.title;
    const status = document.createElement('small');
    status.textContent = { idle: 'Ready', working: 'Working', starting: 'Starting…', exited: 'Ended' }[tab.status];
    button.append(title, status);
    button.onclick = () => {
      if (!connected || busy) return;
      void perform(async () => {
        await request('select', undefined, tab.id);
        $('sessions-dialog').close();
        $('sessions-toggle').focus();
      });
    };
    return button;
  }));
  if (focusedID) (nextFocus || $('session-search')).focus();
}
function searchSaved() {
  renderSessionList();
  const query = $('session-search').value.trim();
  const token = ++searchToken;
  if (!query || !$('sessions-dialog').open) { renderSaved([]); return; }
  renderSaved([], { pending: true });
  request('chats', query).then(reply => {
    if (token !== searchToken || $('session-search').value.trim() !== query) return;
    renderSaved(reply.chats, { truncated: reply.chatsTruncated === true });
  }).catch(error => { if (token === searchToken) showError(error.message); });
}
function renderSaved(chats, options = {}) {
  const query = $('session-search').value.trim();
  const safe = [];
  const rows = Array.isArray(chats) ? chats : [];
  if (query) {
    for (const chat of rows.slice(0, 40)) {
      if (!chat || typeof chat.id !== 'string' || typeof chat.title !== 'string' || typeof chat.folder !== 'string') continue;
      if (!chat.id || chat.id.length > 80 || chat.title.length > 300 || chat.folder.length > 4_096) continue;
      if (/[\u0000-\u001F]/.test(chat.id) || /[\u0000-\u001F]/.test(chat.folder)) continue;
      safe.push({ id: chat.id, title: chat.title, folder: chat.folder });
    }
  }
  const heading = $('saved-heading');
  if (heading) heading.hidden = !query;
  const empty = $('saved-empty');
  if (empty) {
    if (options.truncated === true && safe.length > 0) {
      empty.hidden = false;
      empty.textContent = 'Showing the first matches.';
    } else {
      empty.hidden = !query || safe.length > 0 || options.pending === true;
      if (query && safe.length === 0 && !options.pending && !Array.isArray(chats)) {
        empty.textContent = 'The list was too long. Narrow the search.';
      } else if (empty.textContent !== 'No matching chats.') {
        empty.textContent = 'No matching chats.';
      }
    }
  }
  $('saved-list').replaceChildren(...safe.map(chat => {
    const button = document.createElement('button');
    button.type = 'button';
    const title = document.createElement('span');
    title.textContent = chat.title;
    const folder = document.createElement('small');
    folder.textContent = chat.folder;
    button.append(title, folder);
    button.onclick = () => {
      if (!connected || busy) return;
      const id = chat.id, folderPath = chat.folder;
      void perform(async () => {
        await request('open', folderPath, undefined, false, { name: id });
        $('sessions-dialog').close();
      });
    };
    return button;
  }));
}
function projectButton(nameText, folderText, onClick) {
  const button = document.createElement('button');
  button.type = 'button';
  const name = document.createElement('span');
  name.textContent = nameText;
  const folder = document.createElement('small');
  folder.textContent = folderText;
  button.append(name, folder);
  button.onclick = onClick;
  return button;
}
function renderProjects(projects, offset = 0, truncated = false) {
  const safe = [];
  for (const project of (Array.isArray(projects) ? projects : []).slice(0, 40)) {
    if (!project || typeof project.name !== 'string' || typeof project.folder !== 'string') continue;
    if (!project.name || !project.folder || project.folder.length > 4_096) continue;
    if (/[\u0000-\u001F]/.test(project.folder)) continue;
    safe.push({ name: project.name, folder: project.folder });
  }
  const list = $('project-list');
  const kept = offset === 0 ? [] : Array.from(list.children || []).filter(button => button.dataset.more !== 'true');
  const buttons = safe.map(project => projectButton(project.name, project.folder, () => {
    if (!connected || busy) return;
    const folderPath = project.folder;
    $('project-dialog').close();
    void perform(() => request('new', folderPath));
  }));
  if (safe.length > 0 && (safe.length === 40 || truncated)) {
    const next = offset + safe.length;
    const more = projectButton('More projects', 'Show the next folders', () => {
      if (!connected || busy) return;
      void perform(async () => {
        const reply = await request('projects', undefined, undefined, false, { index: next });
        renderProjects(reply.projects, next, reply.projectsTruncated === true);
      });
    });
    more.dataset.more = 'true';
    buttons.push(more);
  }
  if (offset === 0 && safe.length === 0) {
    buttons.push(projectButton('Current folder', 'The folder Sigil uses for a new session', () => {
      if (!connected || busy) return;
      $('project-dialog').close();
      void perform(() => request('new'));
    }));
  }
  list.replaceChildren(...kept, ...buttons);
  const empty = $('project-empty');
  if (empty) empty.hidden = list.children.length > 0;
  if (!$('project-dialog').open) $('project-dialog').showModal();
}
function paintOutput() {
  const output = displayedOutput || '';
  const query = $('find-bar').hidden ? '' : $('find-query').value;
  findMatches = [];
  if (!query) { $('terminal').textContent = output; updateFind(false); return; }
  const fragment = document.createDocumentFragment();
  let cursor = 0;
  if (query) {
    // Escaped literal search preserves source offsets even for Unicode case folding.
    const pattern = new RegExp(query.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'), 'giu');
    for (const match of output.matchAll(pattern)) {
      fragment.append(document.createTextNode(output.slice(cursor, match.index)));
      const mark = document.createElement('mark');
      mark.textContent = match[0];
      fragment.append(mark); findMatches.push(mark);
      cursor = match.index + match[0].length;
    }
  }
  fragment.append(document.createTextNode(output.slice(cursor)));
  $('terminal').replaceChildren(fragment);
  findIndex = Math.min(findIndex, Math.max(0, findMatches.length - 1));
  updateFind(false);
}
function updateFind(scroll = true) {
  findMatches.forEach((mark, index) => { mark.dataset.current = String(index === findIndex); });
  $('find-count').textContent = !$('find-query').value ? '' : findMatches.length ? `${findIndex + 1} of ${findMatches.length}` : 'No matches';
  $('find-next').disabled = $('find-previous').disabled = !findMatches.length;
  if (scroll) findMatches[findIndex]?.scrollIntoView({ block: 'center' });
}
function moveFind(delta) {
  if (!findMatches.length) return;
  findIndex = (findIndex + delta + findMatches.length) % findMatches.length;
  updateFind();
}
function closeFind() {
  $('find-bar').hidden = true;
  $('find-toggle').setAttribute('aria-expanded', 'false');
  paintOutput();
}
$('sessions-toggle').onclick = () => {
  $('session-search').value = '';
  searchToken++;
  renderSaved([]);
  renderSessionList(); $('sessions-dialog').showModal();
  // On a touch screen, focus would raise the keyboard over the list.
  if (hasFinePointer()) $('session-search').focus();
};
$('sessions-close').onclick = () => $('sessions-dialog').close();
$('sessions-dialog').addEventListener('close', () => { if (!$('sessions-toggle').hidden) $('sessions-toggle').focus(); });
$('session-search').oninput = searchSaved;
$('find-toggle').onclick = () => {
  $('find-bar').hidden = false; $('find-toggle').setAttribute('aria-expanded', 'true');
  $('find-query').focus(); paintOutput();
};
$('find-query').oninput = () => { findIndex = 0; paintOutput(); updateFind(); };
$('find-bar').onsubmit = event => { event.preventDefault(); moveFind(1); };
$('find-next').onclick = () => moveFind(1);
$('find-previous').onclick = () => moveFind(-1);
$('find-close').onclick = () => { closeFind(); $('find-toggle').focus(); };
$('find-query').onkeydown = event => {
  if (event.key === 'Escape') { event.preventDefault(); closeFind(); $('find-toggle').focus(); }
  if (event.key === 'Enter' && event.shiftKey) { event.preventDefault(); moveFind(-1); }
};
$('copy-output').onclick = async () => {
  try { await navigator.clipboard.writeText(displayedOutput || ''); $('copy-output').textContent = 'Copied'; }
  catch { showError('Could not copy. Select the output and copy it.'); }
};
$('connection').addEventListener('toggle', () => { if ($('connection').open) $('copy-output').textContent = 'Copy output'; });

async function request(action, text, tabID = selected, pairing = false, extra = {}) {
  const current = generation;
  const epoch = commandEpoch;
  const previous = outgoing;
  let release;
  outgoing = new Promise(resolve => { release = resolve; });
  await previous;
  try {
    if (current !== generation || epoch !== commandEpoch) {
      throw new Error("Connection changed. Check the terminal before sending again.");
    }
    return await transmit(action, text, tabID, pairing, extra);
  } finally { release(); }
}
async function transmit(action, text, tabID, pairing, extra = {}) {
  if (!socket || socket.readyState !== WebSocket.OPEN || !challenge || (!connected && !pairing && action !== 'state')) throw new Error('Not connected.');
  const ws = socket, current = generation, seq = ++sequence;
  const message = { challenge, sequence: seq, action, ...(tabID ? { tabID } : {}), ...(text !== undefined ? { text } : {}), ...extra };
  const data = await seal(message, pairing ? bootstrap : credential.key, 'phone');
  if (current !== generation || ws.readyState !== WebSocket.OPEN) throw new Error('Connection lost.');
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => {
      pending.delete(seq);
      reject(new Error('No response. Check the terminal before sending again.'));
    }, 10000);
    pending.set(seq, { resolve, reject, timer, action, tabID });
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
  const params = new URLSearchParams({ role: 'phone' });
  url.search = params;
  const ws = socket = new WebSocket(url);
  let routed = false;
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
      if (typeof frame.route === 'string' && /^[a-f0-9]{64}$/.test(frame.route)) {
        if (routed) return;
        routed = true;
        // Routing is sealed to this relay connection, never with the device key.
        const key = await importKey(frame.route);
        const route = await seal({ room: credential.room, ticket: credential.ticket }, key, 'relay-phone');
        if (current !== generation || ws.readyState !== WebSocket.OPEN) return;
        ws.send(JSON.stringify({ route }));
      } else if (typeof frame.hello === 'string' && /^[a-f0-9]{64}$/.test(frame.hello)) {
        if (challenge === frame.hello) return;
        commandEpoch++;
        for (const item of pending.values()) {
          clearTimeout(item.timer);
          item.reject(new Error('Connection changed. Check the terminal before sending again.'));
        }
        pending.clear();
        challenge = frame.hello;
        sequence = 0;
        const authorization = bootstrap ? request('pair', newDeviceKey, undefined, true) : request('state');
        authorization.then(() => {
          if (current !== generation) return;
          bootstrap = null; newDeviceKey = null;
          reconnectDelay = 500;
          clearTimeout(connectTimer);
          connected = true; busy = false;
          $('status').textContent = 'Connected'; $('status').dataset.connected = 'true';
          showError(''); updateControls(); poll();
        }).catch(error => { showError(error.message); });
      } else if (frame.error === 'unauthorized') {
        // A dropped pairing acknowledgement can leave the Mac already using the device key.
        if (bootstrap) { bootstrap = null; newDeviceKey = null; ws.close(); }
        else {
          stopped = true; revoked = true;
          $('controls').hidden = true; $('welcome').hidden = false;
          showError('Pairing expired or was disconnected. Scan a new code in Sigil.'); ws.close();
        }
      } else if (frame.data) {
        const reply = await open(frame.data, credential.key, 'mac');
        if (current !== generation) return;
        const item = pending.get(reply.sequence);
        if (!item) return;
        if (reply.challenge !== challenge) return; // A delayed reply from an earlier Mac epoch.
        if (reply.ok !== true) {
          pending.delete(reply.sequence); clearTimeout(item.timer);
          item.reject(new Error(reply.error || 'The Mac could not complete this action.'));
          return;
        }
        if (typeof reply.ticket === 'string' && /^[a-f0-9]{64}$/.test(reply.ticket)
            && reply.ticket !== credential.ticket) {
          credential.ticket = reply.ticket;
          try { await storage('put', credential); } catch { /* keep the in-memory ticket */ }
        }
        if (item.action === 'earlier') pendingEarlier = {
          tabID: item.tabID, slice: typeof reply.earlier === 'string' ? reply.earlier : '',
        };
        if (reply.state) {
          // Restart replaces the Mac tab ID. Move drafts before pruning closed tabs.
          const next = reply.restartedTabID;
          const movedRestart = item.action === 'restart' && typeof next === 'string'
            && next.length > 0 && next.length <= 64 && next !== item.tabID;
          if (movedRestart) {
            const draft = item.tabID === selected ? $('message').value : drafts.get(item.tabID);
            if (draft !== undefined) drafts.set(next, draft);
            if (attachmentDrafts.has(item.tabID)) {
              attachmentDrafts.set(next, attachmentDrafts.get(item.tabID));
              attachmentDrafts.delete(item.tabID);
            }
          }
          render(reply.state);
          if (movedRestart) drafts.delete(item.tabID);
        }
        pending.delete(reply.sequence); clearTimeout(item.timer);
        item.resolve(reply);
      } else throw new Error('Invalid response');
    }).catch(() => { if (current === generation) { showError('Could not verify the connection.'); ws.close(); } });
  };
  ws.onclose = () => {
    if (current !== generation) return;
    if (!stopped) {
      offline('Connecting…');
      reconnectTimer = setTimeout(connect, reconnectDelay);
      reconnectDelay = Math.min(reconnectDelay * 2, 8000);
    } else {
      offline();
    }
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
function isImageFile(file) {
  return (file.type || '').startsWith('image/') || /\.(png|jpe?g|gif|webp|heic|heif|bmp|tiff?)$/i.test(file.name || '');
}
function bytesToBase64(bytes) {
  let binary = '';
  for (let i = 0; i < bytes.length; i += 8192) binary += String.fromCharCode(...bytes.subarray(i, i + 8192));
  return btoa(binary);
}
async function compressImage(file) {
  const bitmap = await createImageBitmap(file);
  const scale = Math.min(1, 1920 / Math.max(bitmap.width, bitmap.height));
  const width = Math.max(1, Math.round(bitmap.width * scale));
  const height = Math.max(1, Math.round(bitmap.height * scale));
  const canvas = typeof OffscreenCanvas === 'function'
    ? new OffscreenCanvas(width, height)
    : Object.assign(document.createElement('canvas'), { width, height });
  canvas.getContext('2d').drawImage(bitmap, 0, 0, width, height);
  bitmap.close();
  const blob = canvas.convertToBlob
    ? await canvas.convertToBlob({ type: 'image/jpeg', quality: 0.82 })
    : await new Promise((resolve, reject) => canvas.toBlob(
      value => { if (value) resolve(value); else reject(new Error('Could not compress that photo.')); },
      'image/jpeg', 0.82));
  if (blob.size > MAX_REMOTE_BYTES) throw new Error('Keep files under 4 MB.');
  return { name: remoteFileName(`${(file.name || 'photo').replace(/\.[^.]+$/, '')}.jpg`), bytes: new Uint8Array(await blob.arrayBuffer()) };
}
async function prepareFile(file) {
  if (isImageFile(file)) {
    try { return await compressImage(file); } catch { /* send the original if it still fits */ }
  }
  if (file.size > MAX_REMOTE_BYTES) throw new Error('Keep files under 4 MB.');
  return { name: remoteFileName(file.name), bytes: new Uint8Array(await file.arrayBuffer()) };
}
async function uploadFile(payload, tabID) {
  const transfer = randomKey().slice(0, 32);
  const count = Math.max(1, Math.ceil(payload.bytes.length / CHUNK));
  for (let index = 0; index < count; index++) {
    const piece = payload.bytes.subarray(index * CHUNK, index * CHUNK + CHUNK);
    // The relay closes a socket over 30 frames/s, and the Mac replies once per chunk.
    const wait = lastChunkAt + 50 - Date.now();
    if (wait > 0) await new Promise(resolve => setTimeout(resolve, wait));
    lastChunkAt = Date.now();
    await request('file', bytesToBase64(piece), tabID, false, { name: payload.name, index, count, transfer });
  }
}
function renderAttachments() {
  const items = attachmentsFor();
  $('attachments').hidden = items.length === 0;
  $('attachments').replaceChildren(...items.map((item, index) => {
    const row = document.createElement('li');
    if (item.preview) {
      const image = document.createElement('img');
      image.src = item.preview;
      image.alt = '';
      row.append(image);
    }
    const label = document.createElement('span');
    label.textContent = item.name;
    const remove = document.createElement('button');
    remove.type = 'button';
    remove.setAttribute('aria-label', `Remove ${item.name}`);
    remove.textContent = '×';
    remove.onclick = () => {
      const [taken] = attachmentsFor().splice(index, 1);
      if (taken?.preview) URL.revokeObjectURL(taken.preview);
      renderAttachments();
    };
    row.append(label, remove);
    return row;
  }));
  updateControls();
}
function clearAttachments(id = selected) {
  const items = id ? attachmentDrafts.get(id) : null;
  if (items) for (const item of items) if (item.preview) URL.revokeObjectURL(item.preview);
  if (id) attachmentDrafts.delete(id);
  else {
    for (const list of attachmentDrafts.values()) {
      for (const item of list) if (item.preview) URL.revokeObjectURL(item.preview);
    }
    attachmentDrafts.clear();
  }
  renderAttachments();
}
async function sendText(submit) {
  const text = $('message').value;
  const files = attachmentsFor().slice();
  if (!text.trim() && !files.length) return;
  if (new TextEncoder().encode(text).length > 8192) { showError('Keep the message under 8 KB.'); return; }
  const target = selected, current = generation;
  // Size-check every file before the Mac pastes any of them into the prompt.
  const payloads = [];
  for (const item of files) payloads.push(await prepareFile(item.file));
  for (const [index, item] of files.entries()) {
    await uploadFile(payloads[index], target);
    // The Mac has pasted this file, so a retry must not send it again.
    const list = attachmentDrafts.get(target);
    const at = list ? list.indexOf(item) : -1;
    if (at >= 0) { list.splice(at, 1); if (item.preview) URL.revokeObjectURL(item.preview); }
    if (selected === target) renderAttachments();
  }
  if (current !== generation) throw new Error('Connection changed. Check the terminal before sending again.');
  if (text.trim()) await request('input', files.length ? ` ${text}` : text, target);
  if (current !== generation) throw new Error('Connection changed. Check the terminal before sending again.');
  if (submit) {
    await new Promise(resolve => setTimeout(resolve, 100));
    if (current !== generation) throw new Error('Connection changed. Check the terminal before sending again.');
    await request('key', 'enter', target);
  }
  if (selected === target) {
    if ($('message').value === text) { $('message').value = ''; resizeMessage(); }
    if (files.length) clearAttachments();
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
  document.body.dataset.compact = String(viewport.height < 600);
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
function maybeLoadEarlier() {
  const terminal = $('terminal');
  if (!connected || !selected || earlierFlight) return;
  const bucket = historyFor(selected);
  if (bucket.exhausted || terminal.scrollHeight <= terminal.clientHeight || terminal.scrollTop > 48) return;
  const loaded = bucket.history + bucket.tail;
  if (!loaded) return;
  const end = utf8Limited(takeEnd(loaded, 40), 80);
  if (!end) return;
  earlierFlight = true;
  const tabID = selected;
  request('earlier', takeChars(loaded, 80), tabID, false, { name: end, index: loaded.length })
    .catch(error => { showError(error.message); })
    .finally(() => { earlierFlight = false; });
}
$('terminal').onscroll = () => { updateLatest(); maybeLoadEarlier(); };
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
$('new').onclick = () => void perform(async () => {
  let reply;
  try { reply = await request('projects'); } catch (error) {
    // A Mac without the project list starts New in its current folder.
    if (error.message !== 'Unknown action.') throw error;
    await request('new');
    return;
  }
  renderProjects(reply.projects, 0, reply.projectsTruncated === true);
});
$('project-cancel').onclick = () => $('project-dialog').close();
$('project-dialog').addEventListener('close', () => { if (!$('new').disabled) $('new').focus(); });
async function interrupt() {
  if (!connected || !selected) return;
  try { await request('key', 'interrupt'); }
  catch (error) { showError(error.message); }
}
$('interrupt').onclick = interrupt;
$('stop').onclick = interrupt;
$('restart').onclick = () => void perform(() => request('restart'));
$('attach-toggle').onclick = () => $('attach').click();
$('attach').onchange = () => {
  const list = attachmentsFor();
  const room = 16 - list.length;
  for (const file of [...$('attach').files].slice(0, Math.max(0, room))) {
    // Photos are compressed before upload; other files must already fit.
    if (!isImageFile(file) && file.size > MAX_REMOTE_BYTES) { showError('Keep files under 4 MB.'); continue; }
    list.push({
      file, name: file.name || 'file',
      preview: isImageFile(file) ? URL.createObjectURL(file) : '',
    });
  }
  $('attach').value = '';
  renderAttachments();
};
$('message').addEventListener('keydown', event => {
  if (event.key !== 'Enter' || event.shiftKey || event.isComposing) return;
  if (!event.metaKey && !event.ctrlKey) return;
  event.preventDefault();
  void perform(() => sendText(true));
});
document.querySelectorAll('[data-key]').forEach(button => { button.onclick = () => void perform(() => request('key', button.dataset.key)); });
$('reconnect').onclick = $('welcome-reconnect').onclick = () => { stopped = false; revoked = false; reconnectDelay = 500; connect(); };
$('forget').onclick = async () => {
  stopped = true; ++generation; clearTimeout(reconnectTimer); socket?.close(); offline();
  credential = null; revoked = false; bootstrap = null; newDeviceKey = null; selected = null; drafts.clear(); tabsSignature = '';
  selectedStatus = null; tabCount = 0;
  $('keys').hidden = true; $('keys-toggle').setAttribute('aria-expanded', 'false');
  clearAttachments();
  rawOutput = ''; rawMode = false; displayedOutput = null;
  histories.clear(); pendingEarlier = null; earlierFlight = false; searchToken++;
  sessionTabs = []; $('sessions-dialog').close(); $('project-dialog').close(); closeFind();
  $('raw-toggle').setAttribute('aria-pressed', 'false'); $('raw-toggle').textContent = 'Show raw terminal';
  $('session-toolbar').hidden = true; $('brand').hidden = false;
  $('terminal').textContent = ''; $('message').value = ''; $('controls').hidden = true; $('welcome').hidden = false;
  try { await storage('delete'); showError(''); } catch { showError('Could not clear pairing. Clear this site’s data in browser settings.'); }
  updateControls();
};
let scanRun = 0;
function loadJsQR() {
  if (typeof globalThis.jsQR === 'function') return Promise.resolve(globalThis.jsQR);
  return new Promise((resolve, reject) => {
    const script = document.createElement('script');
    script.src = '/jsqr.js';
    script.onload = () => typeof globalThis.jsQR === 'function'
      ? resolve(globalThis.jsQR)
      : reject(new Error('Could not load the scanner.'));
    script.onerror = () => reject(new Error('Could not load the scanner.'));
    document.head.appendChild(script);
  });
}
function stopScan() {
  scanRun++;
  const video = $('scanner-video');
  const stream = video?.srcObject;
  if (stream && typeof stream.getTracks === 'function') {
    for (const track of stream.getTracks()) track.stop();
  }
  if (video) video.srcObject = null;
  const scanner = $('scanner');
  if (scanner) scanner.hidden = true;
}
async function beginPair(pairing) {
  bootstrap = await importKey(pairing.key);
  newDeviceKey = randomKey();
  credential = { room: pairing.room, key: await importKey(newDeviceKey) };
  await storage('put', credential);
  stopped = false; revoked = false;
  reconnectDelay = 500;
  updateControls();
  connect();
}
async function startScan() {
  if (!navigator.mediaDevices?.getUserMedia) {
    $('paste-form').hidden = false;
    showError('This browser cannot open the camera. Paste the pairing link instead.');
    $('pairing-link').focus();
    return;
  }
  showError('');
  const run = ++scanRun;
  let stream;
  try {
    stream = await navigator.mediaDevices.getUserMedia({
      audio: false,
      video: { facingMode: { ideal: 'environment' }, width: { ideal: 1280 }, height: { ideal: 720 } },
    });
  } catch (error) {
    $('paste-form').hidden = false;
    showError(error?.name === 'NotAllowedError'
      ? 'Camera access is off. Paste the pairing link instead.'
      : 'No camera available. Paste the pairing link instead.');
    $('pairing-link').focus();
    return;
  }
  if (run !== scanRun) {
    for (const track of stream.getTracks()) track.stop();
    return;
  }
  const video = $('scanner-video');
  video.setAttribute('playsinline', '');
  video.playsInline = true;
  video.muted = true;
  video.srcObject = stream;
  $('scanner').hidden = false;
  try { await video.play(); } catch { /* frames still arrive if a second play() is rejected */ }
  let jsQR;
  try { jsQR = await loadJsQR(); }
  catch (error) {
    if (run === scanRun) { showError(error.message); stopScan(); }
    return;
  }
  const canvas = document.createElement('canvas');
  const ctx = canvas.getContext('2d', { willReadFrequently: true });
  const tick = () => {
    if (run !== scanRun) return;
    if (video.readyState >= 2 && video.videoWidth) {
      const scale = Math.min(1, 640 / video.videoWidth);
      canvas.width = Math.max(1, Math.floor(video.videoWidth * scale));
      canvas.height = Math.max(1, Math.floor(video.videoHeight * scale));
      ctx.drawImage(video, 0, 0, canvas.width, canvas.height);
      const image = ctx.getImageData(0, 0, canvas.width, canvas.height);
      const code = jsQR(image.data, image.width, image.height);
      if (code?.data) {
        const result = pairingFromText(code.data, location.origin);
        if (result?.room) {
          stopScan();
          beginPair(result).catch(error => showError(error.message));
          return;
        }
        if (result?.error) showError(result.error);
      }
    }
    requestAnimationFrame(tick);
  };
  requestAnimationFrame(tick);
}
if ($('scan')) $('scan').onclick = () => void startScan();
if ($('scanner-cancel')) $('scanner-cancel').onclick = () => stopScan();
if ($('paste-link')) $('paste-link').onclick = async () => {
  $('paste-form').hidden = false;
  $('pairing-link').focus();
  try {
    const text = await navigator.clipboard.readText();
    if (credential && !revoked) return;
    const result = pairingFromText(text, location.origin);
    if (result?.room) { showError(''); await beginPair(result); return; }
    if (result?.error) showError(result.error);
  } catch { /* show the field so the user can paste */ }
  $('paste-form').hidden = false;
  $('pairing-link').focus();
};
if ($('paste-form')) $('paste-form').onsubmit = event => {
  event.preventDefault();
  const result = pairingFromText($('pairing-link').value, location.origin);
  if (result?.room) {
    showError('');
    void beginPair(result).catch(error => showError(error.message));
    return;
  }
  showError(result?.error || 'That is not a Sidereal pairing link.');
};
document.addEventListener('keydown', event => {
  if (event.key === 'Escape' && $('scanner') && !$('scanner').hidden) {
    event.preventDefault(); stopScan(); return;
  }
  const details = $('connection');
  if (event.key === 'Escape' && details.open) { details.open = false; $('connection-toggle').focus(); }
});
document.addEventListener('pointerdown', event => {
  const details = $('connection');
  if (details.open && !details.contains(event.target)) details.open = false;
});
document.addEventListener('visibilitychange', () => {
  if (document.hidden) {
    clearTimeout(pollTimer);
    if ($('scanner') && !$('scanner').hidden) stopScan();
  }
  else if (connected) poll();
  else if (!stopped) connect();
});
async function start() {
  const fragment = new URLSearchParams(location.hash.slice(1));
  const pairing = pairingFromText(location.hash, location.origin);
  history.replaceState(null, '', location.pathname);
  if (!crypto.subtle) throw new Error('Open Sidereal using HTTPS.');
  if (pairing?.room) await beginPair(pairing);
  else if (pairing?.error || fragment.has('room') || fragment.has('key')) {
    throw new Error(pairing?.error || 'Invalid code. Scan a new code in Sigil.');
  } else {
    credential = await storage('get');
    updateControls();
    if (credential) connect();
  }
  if ('serviceWorker' in navigator) navigator.serviceWorker.register('/sw.js').catch(() => {});
}
start().catch(error => showError(error.message));
// A camera scan can reuse the open page and change only its fragment.
window.addEventListener('hashchange', () => { if (location.hash) location.reload(); });
