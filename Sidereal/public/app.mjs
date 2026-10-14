import { importKey, randomKey, seal, open } from './crypto.mjs';
import { createReadableOutput, commonPrefixLength } from './output.mjs';
import { pairingFromText } from './pairing.mjs';
const $ = id => document.getElementById(id);
const STATUS_LABELS = { working: 'Working', starting: 'Starting…', idle: 'Ready', exited: 'Session ended', unknown: 'Status unknown', waitingForApproval: 'Needs approval', interrupted: 'Stopped', failed: 'Failed', disconnected: 'Disconnected' };
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
// Set by each Mac handshake; only the first state after one can show a restarted Mac.
let freshHandshake = false;
const histories = new Map();
let pendingEarlier = null, earlierFlight = false, searchToken = 0;
let providerChoice = '', providerProblems = new Map();
let newOptions = null, newProjects = [], projectTarget = null, worktreeChoice = null, canUseSessionOps = false;
let newFlight = null;
let newSheetEpoch = 0;
let findIndex = 0, findMatches = [], displayedOutput = null;
let rawOutput = '', rawMode = false;
let credential, bootstrap, newDeviceKey, replacingMemory, socket, challenge, clientNonce, sequence = 0, selected;
let selectedStatus = null, selectedRunning, selectedCapabilities, currentPrompt = null, promptSignature = null, tabCount = 0;
let connected = false, busy = false, selectingSession = false, stopped = false, revoked = false, unsaved = false, reconnectTimer, pollTimer, connectTimer, generation = 0;
let commandEpoch = 0, queuedCommands = 0, reconnectDelay = 500;
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
  const ended = selectedRunning === false || selectedStatus === 'exited';
  document.querySelectorAll('#controls button, #controls textarea, #session-toolbar button, #session-toolbar select').forEach(element => {
    // Never disable a focused editor while a command is pending: it closes the phone keyboard.
    if (element.id === 'message') { element.disabled = !selected; element.readOnly = Boolean(selectingSession); return; }
    if (['keys-toggle', 'latest', 'find-toggle', 'find-close', 'find-next', 'find-previous', 'sessions-toggle'].includes(element.id)) { element.disabled = false; return; }
    if (element.id === 'restart') { element.disabled = disabled || !ended; return; }
    if (element.id === 'new') { element.disabled = disabled; return; }
    if (element.id === 'tabs') { element.disabled = disabled || tabCount === 0; return; }
    if (element.id === 'stop' || element.id === 'interrupt') {
      element.disabled = !connected || !selected || ended || Boolean(selectingSession); return;
    }
    // Keys queue behind each other, but never land between a send's files and its Enter.
    if (element.dataset.key) { element.disabled = disabled || !selected || ended; return; }
    element.disabled = disabled || !selected || ended;
  });
  $('send').disabled = disabled || !selected || ended || !($('message').value.trim() || attachmentsFor().length);
  $('stop').hidden = !['working', 'unknown', 'waitingForApproval'].includes(selectedStatus) || ended;
  $('restart').hidden = !ended || !canRestart || selectedCapabilities?.resume === false;
  $('copy-output').hidden = !selected;
  $('sessions-toggle').hidden = !connected;
  $('session-status').textContent = !connected ? 'Reconnecting…' : (STATUS_LABELS[selectedStatus] || 'No session');
  $('session-status').dataset.state = connected ? selectedStatus || '' : 'offline';
  if (document.body) document.body.dataset.connected = String(connected && !$('controls').hidden);
  // An ended session already says so in the bar above, and Send is off.
  const composeStatus = selectingSession ? 'Switching…' : busy ? 'Sending…' : !connected && selected ? 'Offline · draft kept' : '';
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
  updateNewControls();
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
  if (selectingSession) $('tabs').value = selected || '';
  selectingSession = false;
  connected = false;
  commandEpoch++;
  $('status').textContent = $('status-live').textContent = message;
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
    // Streamed output takes this path on every poll; keep the newest text under the cap.
    if (bucket.history.length > 400_000) bucket.history = bucket.history.slice(-400_000);
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
function takeGraphemes(text, count) {
  const out = [];
  for (const { segment } of new Intl.Segmenter().segment(text)) {
    if (out.length === count) break;
    out.push(segment);
  }
  return out.join('');
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
function sameConversation(left, right) {
  return left?.sessionID && right?.sessionID && left.sessionID === right.sessionID
    && left.provider === right.provider && typeof left.cwd === 'string' && left.cwd === right.cwd;
}
function renderInteraction(prompt) {
  if (prompt != null && (typeof prompt.id !== 'string' || typeof prompt.question !== 'string'
    || !['menu', 'yesNo'].includes(prompt.style) || !Array.isArray(prompt.choices)
    || prompt.choices.length > 9 || JSON.stringify(prompt).length > 16000
    || prompt.choices.some(c => typeof c.label !== 'string' || typeof c.key !== 'string'
      || !/^(?:[1-9]|y|n|yes|no)$/.test(c.key)))) throw new Error('Invalid terminal interaction');
  currentPrompt = prompt ?? null;
  const signature = JSON.stringify([selected, currentPrompt]);
  if (signature === promptSignature) return;
  promptSignature = signature;
  $('interaction').hidden = !prompt;
  if (!prompt) { $('interaction-choices').replaceChildren(); return; }
  const verified = prompt.verified === true && selectedCapabilities?.structuredApproval === true;
  $('interaction-heading').textContent = verified ? 'Approval' : 'Terminal controls';
  $('interaction-warning').hidden = verified;
  $('interaction-operation').textContent = prompt.operation ?? '';
  $('interaction-operation').hidden = !prompt.operation;
  $('interaction-question').textContent = prompt.question;
  const target = selected;
  $('interaction-choices').replaceChildren(...prompt.choices.map(choice => {
    const button = document.createElement('button');
    button.type = 'button'; button.textContent = choice.label;
    button.onclick = () => void perform(async () => {
      if (selected !== target || currentPrompt?.id !== prompt.id) throw new Error('The terminal changed. Check it before sending.');
      const current = generation, epoch = commandEpoch;
      if (verified) await request('answer', choice.key, target, false, { name: prompt.id });
      else {
        await request('key', choice.key, target);
        if (prompt.style === 'yesNo') { requireConnection(current, epoch); await request('key', 'enter', target); }
      }
    });
    return button;
  }));
}
function render(state) {
  if (!state || !Array.isArray(state.tabs) || state.tabs.length > 100 || typeof state.terminal !== 'string') throw new Error('Invalid Mac response');
  if (state.tabsTruncated !== undefined && typeof state.tabsTruncated !== 'boolean') throw new Error('Invalid Mac response');
  const nextSelected = state.selectedTabID ?? null;
  const ids = new Set();
  for (const tab of state.tabs) {
    if (!tab || typeof tab.id !== 'string' || !tab.id || typeof tab.title !== 'string'
      || !['starting', 'working', 'idle', 'exited', 'unknown', 'waitingForApproval', 'interrupted', 'failed', 'disconnected'].includes(tab.status) || ids.has(tab.id)) {
      throw new Error('Invalid Mac response');
    }
    ids.add(tab.id);
  }
  if (nextSelected !== null && (typeof nextSelected !== 'string' || !ids.has(nextSelected))) {
    throw new Error('Invalid Mac response');
  }
  const allTabsNew = freshHandshake && sessionTabs.length > 0 && !sessionTabs.some(tab => ids.has(tab.id));
  freshHandshake = false;
  const previousTab = sessionTabs.find(tab => tab.id === selected);
  sessionTabs = state.tabs;
  canRestart = Array.isArray(state.capabilities) && state.capabilities.includes('restart');
  canUseSessionOps = Array.isArray(state.capabilities) && state.capabilities.includes('sessionOps');
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
      && sameConversation(previousTab, state.tabs.find(tab => tab.id === nextSelected))
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
  const selectedTab = state.tabs.find(tab => tab.id === selected);
  selectedStatus = selectedTab?.status ?? null;
  selectedRunning = selectedTab?.processRunning;
  selectedCapabilities = selectedTab?.capabilities;
  renderInteraction(state.prompt);
  tabCount = state.tabs.length;
  if (completeTabList) for (const id of histories.keys()) if (!ids.has(id)) histories.delete(id);
  for (const id of drafts.keys()) { if (completeTabList && !ids.has(id)) drafts.delete(id); }
  for (const id of attachmentDrafts.keys()) {
    if (completeTabList && !ids.has(id)) {
      for (const item of attachmentDrafts.get(id) || []) if (item.preview) URL.revokeObjectURL(item.preview);
      attachmentDrafts.delete(id);
    }
  }
  const signature = JSON.stringify(state.tabs);
  if (signature !== tabsSignature) {
    const tabs = state.tabs.map(tab => {
      const option = document.createElement('option');
      option.value = tab.id;
      const suffix = tab.status === 'exited' ? ' · Ended' : '';
      option.textContent = tab.title + suffix;
      return option;
    });
    if (!tabs.length) { const empty = document.createElement('option'); empty.value = ''; empty.textContent = 'No open sessions'; tabs.push(empty); }
    $('tabs').replaceChildren(...tabs); tabsSignature = signature;
  }
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
// Polls usually return the same text; format it again only when it changes.
let readableFrom = null, readableText = '';
const readable = createReadableOutput();
function renderOutput(changedSession = false, prepended = false) {
  const terminal = $('terminal');
  const atBottom = terminal.scrollHeight - terminal.scrollTop - terminal.clientHeight < 60;
  const fromEnd = terminal.scrollHeight - terminal.scrollTop;
  if (!rawMode && readableFrom !== rawOutput) {
    readableText = readable.update(rawOutput, { reset: changedSession || prepended }); readableFrom = rawOutput;
  }
  const output = rawMode ? rawOutput : readableText;
  $('empty-output').hidden = Boolean(output);
  const ended = Boolean(selected) && (selectedRunning === false || selectedStatus === 'exited');
  $('empty-output').querySelector('h2').textContent = ended ? (selectedStatus === 'failed' ? 'Session failed' : 'Session ended') : selectedStatus === 'unknown' ? 'Status unknown' : selectedStatus === 'working' ? 'Working…' : selectedStatus === 'starting' ? 'Starting session…' : selected ? 'Ready when you are.' : 'No open sessions.';
  $('empty-output').querySelector('p').textContent = ended ? (selectedCapabilities?.resume === false ? (selectedCapabilities.history ? 'Open this conversation from Chats.' : 'Choose New to start another session.') : canRestart ? 'Resume this conversation.' : 'Restart this session in Sigil on your Mac.') : selectedStatus === 'working' || selectedStatus === 'starting' ? 'Output will appear here.' : selected ? 'Send a message to this session.' : 'Choose New to start a session.';
  terminal.dataset.raw = String(rawMode);
  if (displayedOutput !== output || changedSession) {
    // A repaint replaces the text and drops a selection the reader is making. Append
    // new text after it, and hold any other repaint until the selection ends.
    const selection = changedSession || prepended ? null : globalThis.getSelection?.();
    const selecting = Boolean(selection && !selection.isCollapsed && terminal.contains(selection.anchorNode));
    const extending = Boolean(displayedOutput) && output.startsWith(displayedOutput)
      && ($('find-bar').hidden || !$('find-query').value);
    if (selecting && !extending) { updateLatest(); return; }
    if (selecting) terminal.append(output.slice(displayedOutput.length));
    displayedOutput = output;
    if (changedSession) findIndex = 0;
    if (!selecting) paintOutput();
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
    status.textContent = STATUS_LABELS[tab.status] ?? 'Status unknown';
    button.append(title, status);
    button.onclick = () => {
      if (!connected || busy) return;
      void perform(async () => {
        if (!await changeSession('select', undefined, tab.id)) return;
        if ($('sessions-dialog').open) { $('sessions-dialog').close(); $('sessions-toggle').focus(); }
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
  if (!query || !$('sessions-dialog').open) { dropWaitingSearch(); renderSaved([]); return; }
  renderSaved([], { pending: true });
  // The Mac reads 200 characters, and text over 8 KB drops the connection.
  request('chats', utf8Limited(takeGraphemes(query, 200), 8192)).then(reply => {
    if (reply.stale || token !== searchToken || $('session-search').value.trim() !== query) return;
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
      safe.push({ id: chat.id, title: chat.title, folder: chat.folder, provider: chat.provider });
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
        if (!await changeSession('open', folderPath, undefined, { name: id, ...(chat.provider ? { provider: chat.provider } : {}) })) return;
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
const validPath = path => typeof path === 'string' && path.startsWith('/') && path.length <= 4_096 && !/[\u0000-\u001F\u007F]/.test(path);
function projectRecord(project) {
  if (!project || typeof project.name !== 'string' || !project.name || project.name.length > 96 || !validPath(project.folder)) return null;
  return { name: project.name, folder: project.folder, repository: project.repository === true,
    ...(typeof project.worktreeDefault === 'boolean' ? { worktreeDefault: project.worktreeDefault } : {}) };
}
function folderName(value) {
  const name = value.trim();
  return name && new TextEncoder().encode(name).length <= 80 && !name.startsWith('.') && !/[/:\p{Cc}\p{Cf}]/u.test(name) ? name : null;
}
function selectedProvider() { return newOptions?.providers.find(provider => provider.id === $('provider').value); }
function allowsWorktree() { return canUseSessionOps && newOptions && projectTarget?.repository === true; }
function defaultWorktree() { return projectTarget?.worktreeDefault ?? newOptions?.startsInWorktree ?? true; }
function pendingNew() {
  const attempt = credential?.pendingNew;
  if (!attempt) return null;
  // Invalid stored markers still block creation; never interpret corruption as a resolved result.
  return attempt && typeof attempt === 'object' && ['new', 'createProject'].includes(attempt.action)
    && (attempt.folder === undefined || validPath(attempt.folder)) ? attempt : { action: 'unknown' };
}
function showNewOutcome() {
  const attempt = pendingNew();
  const notice = $('new-outcome');
  notice.hidden = !attempt;
  notice.textContent = !attempt ? '' : newFlight ? newFlight.dispatched
    ? 'Waiting for the Mac. Closing this sheet will not cancel the request.' : 'Preparing the request. Closing this sheet will not cancel it.'
    : attempt.action === 'createProject'
      ? `The project result is unknown: ${attempt.folder}. Check projects to look for that exact folder. New creation and session starts stay blocked until it is found.`
      : `The session start result is unknown${attempt.folder ? ` for ${attempt.folder}` : ''}. Open Sigil on your Mac and inspect its tabs and worktrees. Start sessions there while this result is unresolved; this phone will not retry it.`;
  $('project-check').hidden = !attempt || attempt.action !== 'createProject' || Boolean(newFlight);
}
function updateNewControls() {
  const locked = !connected || busy || Boolean(pendingNew());
  const provider = selectedProvider();
  const takesModel = provider?.takesModel === true;
  $('model-field').hidden = $('effort-field').hidden = !takesModel;
  const choiceProblem = takesModel && (!newOptions.models.includes($('new-model').value)
    || !newOptions.efforts.some(effort => effort.id === $('new-effort').value));
  const problem = providerProblem() || (newOptions?.providers.length && !provider ? 'Choose a CLI from the Mac’s list.'
    : choiceProblem ? 'The Mac did not advertise a model and effort to use.' : '');
  $('provider-problem').textContent = problem;
  $('provider-problem').hidden = !problem;
  for (const id of ['provider', 'new-model', 'new-effort', 'new-worktree', 'project-name', 'project-location']) $(id).disabled = locked;
  for (const button of Array.from($('project-list').children || [])) {
    button.disabled = locked || (button.dataset.more !== 'true' && Boolean(problem));
    if (button.dataset.more !== 'true') button.setAttribute('aria-pressed', String(button.dataset.folder === projectTarget?.folder));
  }
  $('worktree-field').hidden = !allowsWorktree();
  $('new-worktree').checked = worktreeChoice ?? defaultWorktree();
  $('worktree-detail').hidden = !projectTarget;
  $('worktree-detail').textContent = allowsWorktree()
    ? $('new-worktree').checked ? 'A fresh checkout on its own branch, as the Mac does.' : 'Start in the selected project folder.'
    : 'The Mac applies its worktree default for this folder.';
  $('project-start').hidden = !newOptions;
  $('project-start').disabled = locked || !projectTarget || Boolean(problem);
  $('project-add').hidden = !canUseSessionOps || !newOptions?.locations.length;
  $('project-add').disabled = locked;
  $('project-create').disabled = locked || !folderName($('project-name').value)
    || !newOptions?.locations.some(location => location.folder === $('project-location').value);
  $('project-back').disabled = Boolean(newFlight);
  $('project-check').disabled = !connected || busy;
  showNewOutcome();
}
function chooseProject(project) {
  if (!connected || busy || pendingNew() || providerProblem()) return;
  projectTarget = project;
  worktreeChoice = null;
  updateNewControls();
  // Older Macs keep the existing one-tap project flow and apply their own defaults.
  if (!newOptions) void perform(() => startProject());
}
async function settleNew(attempt) {
  const owner = credential;
  if (owner?.pendingNew !== attempt) return;
  delete owner.pendingNew;
  try { await storage('put', owner); }
  catch {
    owner.pendingNew = attempt;
    throw new Error('Could not save the result. New remains blocked; inspect Sigil on your Mac.');
  }
}
async function newCommand(action, text, extra = {}) {
  if (pendingNew()) throw new Error('A previous result is still unknown. Inspect Sigil on your Mac before starting again.');
  const attempt = { action, ...(text ? { folder: action === 'createProject' ? `${text.replace(/\/$/, '')}/${extra.name}` : text } : {}) };
  const owner = credential;
  const flight = newFlight = { attempt, dispatched: false };
  owner.pendingNew = attempt;
  updateNewControls();
  try {
    // A reload must not turn a lost reply into permission to create a duplicate.
    try { await storage('put', owner); } catch { throw new Error('Could not save the pending request. Nothing was sent.'); }
    if (credential !== owner) throw new Error('The paired Mac changed. Nothing was sent.');
    const reply = await request(action, text, undefined, false, extra);
    if (action === 'createProject' && projectRecord(reply.project)?.folder !== attempt.folder) {
      throw new Error('The Mac returned an unexpected project. Check projects before trying again.');
    }
    await settleNew(attempt);
    return reply;
  } catch (error) {
    // A verified failure or a request never sent is conclusive. Connection failures are not.
    if (!flight.dispatched || error.verifiedReply) await settleNew(attempt);
    throw error;
  } finally {
    if (newFlight === flight) newFlight = null;
    updateNewControls();
  }
}
async function startProject() {
  if (pendingNew() || !projectTarget || providerProblem()) return;
  if (newOptions?.providers.length && !selectedProvider()) return;
  const extra = providerField();
  if (selectedProvider()?.takesModel && (!newOptions.models.includes(extra.model)
    || !newOptions.efforts.some(effort => effort.id === extra.effort))) return;
  await newCommand('new', projectTarget.folder || undefined, extra);
  $('project-dialog').close();
}
async function findProject(folder) {
  const owner = credential, current = generation;
  // Authoritative project pages, bounded to 400 rows. Absence is never proof of failure.
  for (let index = 0; index < 400; index += 40) {
    const reply = await request('projects', undefined, undefined, false, { index });
    if (credential !== owner || generation !== current) throw new Error('The connection changed. Check projects again after reconnecting.');
    const projects = (Array.isArray(reply.projects) ? reply.projects : []).slice(0, 40).map(projectRecord).filter(Boolean);
    const found = projects.find(project => project.folder === folder);
    if (found) return found;
    if (reply.projectsTruncated !== true && projects.length < 40) break;
    if (!projects.length) break;
  }
  return null;
}
async function reconcileProject() {
  const attempt = pendingNew();
  if (attempt?.action !== 'createProject') return;
  const sheet = newSheetEpoch;
  const project = await findProject(attempt.folder);
  if (!project) throw new Error('That exact folder is not in the Mac’s project list. The result stays unknown; inspect the folder in Sigil on your Mac.');
  await settleNew(attempt);
  if (sheet !== newSheetEpoch || !$('project-dialog').open) return;
  renderProjects([project]);
  projectTarget = project;
  $('new-project-form').hidden = true; $('new-choices').hidden = false;
  updateNewControls();
}
function renderProjects(projects, offset = 0, truncated = false) {
  const safe = (Array.isArray(projects) ? projects : []).slice(0, 40).map(projectRecord).filter(Boolean);
  newProjects = offset === 0 ? safe : [...newProjects, ...safe];
  const list = $('project-list');
  const kept = offset === 0 ? [] : Array.from(list.children || []).filter(button => button.dataset.more !== 'true');
  const buttons = safe.map(project => {
    const button = projectButton(project.name, project.folder, () => chooseProject(project));
    button.dataset.folder = project.folder;
    return button;
  });
  if (safe.length > 0 && (safe.length === 40 || truncated)) {
    const next = offset + safe.length;
    const more = projectButton('More projects', 'Show the next folders', () => {
      if (!connected || busy || pendingNew()) return;
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
      chooseProject({ name: 'Current folder', folder: '' });
    }));
  }
  list.replaceChildren(...kept, ...buttons);
  const empty = $('project-empty');
  if (empty) empty.hidden = list.children.length > 0;
  if (newOptions && !projectTarget) projectTarget = safe[0] || { name: 'Current folder', folder: '' };
  updateNewControls();
  if (!$('project-dialog').open) $('project-dialog').showModal();
}
// The CLIs the Mac offers. A Mac from before the choice sends none, and New starts its default.
function renderProviders(options) {
  const providers = [];
  for (const provider of (Array.isArray(options?.providers) ? options.providers : []).slice(0, 20)) {
    if (!provider || typeof provider.id !== 'string' || typeof provider.name !== 'string') continue;
    if (!/^[a-zA-Z0-9_-]{1,32}$/.test(provider.id) || !provider.name || provider.name.length > 96 || /[\u0000-\u001F\u007F]/.test(provider.name)) continue;
    const problem = typeof provider.problem === 'string' ? provider.problem.slice(0, 300) : '';
    providers.push({ id: provider.id, name: provider.name, problem, takesModel: provider.takesModel === true });
  }
  const models = [...new Set((Array.isArray(options?.models) ? options.models : []).slice(0, 100)
    .filter(model => typeof model === 'string' && new TextEncoder().encode(model).length <= 64 && !model.startsWith('-') && !/[\s\u0000-\u001F\u007F]/.test(model)))];
  const efforts = (Array.isArray(options?.efforts) ? options.efforts : []).slice(0, 20)
    .filter(effort => effort && typeof effort.id === 'string' && /^[a-zA-Z0-9_-]{0,32}$/.test(effort.id)
      && typeof effort.name === 'string' && effort.name.length <= 96 && !/[\u0000-\u001F\u007F]/.test(effort.name));
  const locations = (Array.isArray(options?.locations) ? options.locations : []).slice(0, 8).map(projectRecord).filter(Boolean);
  newOptions = options && typeof options === 'object' && !Array.isArray(options) ? { providers, models, efforts, locations,
    ...(typeof options.startsInWorktree === 'boolean' ? { startsInWorktree: options.startsInWorktree } : {}) } : null;
  providerProblems = new Map(providers.map(provider => [provider.id, provider.problem]));
  $('provider').replaceChildren(...providers.map(provider => {
    const option = document.createElement('option');
    option.value = provider.id;
    option.textContent = provider.name;
    return option;
  }));
  // Keep this page's last choice; otherwise the CLI the Mac's New Session sheet opens on.
  const fallback = typeof options?.provider === 'string' ? options.provider : '';
  $('provider').value = [providerChoice, fallback].find(id => providerProblems.has(id)) || providers[0]?.id || '';
  $('provider-field').hidden = providers.length === 0;
  function choices(id, values, chosen) {
    $(id).replaceChildren(...values.map(value => {
      const option = document.createElement('option'); option.value = value.id; option.textContent = value.name || 'CLI default'; return option;
    }));
    $(id).value = values.some(value => value.id === chosen) ? chosen : values[0]?.id ?? '';
  }
  choices('new-model', models.map(model => ({ id: model, name: model })), options?.model);
  choices('new-effort', efforts, options?.effort);
  choices('project-location', locations.map(location => ({ id: location.folder, name: location.name })), locations[0]?.folder);
  updateNewControls();
}
function providerField() {
  const provider = selectedProvider();
  return { ...(provider ? { provider: provider.id } : {}),
    ...(provider?.takesModel ? { model: $('new-model').value, effort: $('new-effort').value } : {}),
    ...(allowsWorktree() ? { worktree: worktreeChoice ?? defaultWorktree() } : {}) };
}
function providerProblem() {
  return $('provider-field').hidden ? '' : providerProblems.get($('provider').value) || '';
}
function showProviderProblem() {
  updateNewControls();
}
// Find keeps every match as text offsets and highlights only the matches in view. A mark per
// match made each keystroke rebuild and lay out the whole history.
const findHighlight = globalThis.CSS?.highlights && typeof Highlight === 'function'
  ? { match: new Highlight(), current: new Highlight() } : null;
if (findHighlight) findHighlight.current.priority = 1;
// WebKit paints all text slower while any highlight is registered, even an empty one: marking every
// match on 14 long lines of Japanese took 89 ms against 70. So only a highlight with ranges is.
function registerHighlights() {
  for (const [name, highlight] of [['find-match', findHighlight.match], ['find-current', findHighlight.current]]) {
    if (!highlight.size) CSS.highlights.delete(name);
    else if (!CSS.highlights.has(name)) CSS.highlights.set(name, highlight);
  }
}
// The output is painted as text nodes of at most findChunk characters: in WebKit, a range's box
// costs about a microsecond per character of non-ASCII text its node has on that line, and a node
// wider than about 66,000 px on one line gives empty boxes, so Find neither scrolls nor stops at
// findCap. The paint cost of a range grows with its offset inside its node. WebKit also repaints every
// highlighted range for each line it paints, so at most findCap matches out of view are highlighted.
// The nodes go in blocks of about findBlock characters of whole lines: WebKit lays out all the text
// of a block again for each mark it gains or loses, 33 ms for 300,000 characters in one.
const findChunk = 256, findCap = 500, findBlock = 1024;
// A change to any highlight paints every highlighted range in view again. In WebKit that costs a
// tenth to half a millisecond a range over right-to-left or complex scripts, CJK or emoji, against a
// twentieth over Latin, Greek or Cyrillic, so there matches on blocks with such text are marked instead.
// WebKit breaks the glyph of a grapheme cluster that a mark splits, so a mark takes in whole clusters.
// Chromium paints highlights over every script as fast, and paints the marks of dense CJK in view slower.
const findComplex = globalThis.navigator?.vendor === 'Apple Computer, Inc.' ? /[\u0300-\u036f\u0590-\u1fff\u2e80-\uffff]/ : null;
const findClusters = globalThis.Intl?.Segmenter ? new Intl.Segmenter(undefined, { granularity: 'grapheme' }) : null;
// One range measures every box, and highlights hold static ranges: WebKit updates each live range
// on every change to the text until it is collected.
const findScratch = document.createRange?.() ?? null;
// findNodes: findText painted as one text node per chunk, from each of findStarts. findBlocks: the first
// chunk of each block, and findBlockNodes the elements of all blocks but the last. findSplits maps a
// chunk with marks to the nodes in its place, their text as pieces ({ node, start } in findText), its
// marks and the match indices each shows, and a key of the marked offsets. findShown: the shown match
// indices, chosen at the scroll offsets findBand[0] and findBand[1]; they hold every match in view
// until a scroll of over findBand[2] screens. findMarks maps each marked index to its marks.
let findText = null, findStarts = [], findNodes = [], findBlocks = [], findBlockNodes = [], findSplits = new Map();
let findShown = null, findBand = null, findMarks = new Map(), findMarked = -1, findFrame = 0, findComplexBlocks = new Map();
function paintOutput() {
  const output = displayedOutput || '';
  const query = $('find-bar').hidden ? '' : $('find-query').value;
  const terminal = $('terminal'), last = findNodes.length - 1;
  findMatches = [];
  if (query) {
    // Escaped literal search preserves source offsets even for Unicode case folding.
    const pattern = new RegExp(query.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'), 'giu');
    for (const match of output.matchAll(pattern)) findMatches.push({ start: match.index, end: match.index + match[0].length });
    findIndex = Math.min(findIndex, Math.max(0, findMatches.length - 1));
  }
  // A new query alone keeps the laid-out text, and its marks until the frame that shows the new
  // matches: only the chunks whose marks change are painted again.
  if (findText !== output || terminal.firstChild !== (findBlockNodes[0] ?? findSplits.get(0)?.nodes[0] ?? findNodes[0] ?? null)
    || terminal.lastChild !== (findSplits.get(last)?.nodes.slice(-1)[0] ?? findNodes[last] ?? null)) paintText(output);
  else if (!findMatches.length) markMatches([]);
  findShown = null; findMarks = new Map(); findMarked = -1;
  findHighlight?.match.clear();
  updateFind(false);
  if (findMatches.length) showMatchesSoon();
}
function updateFind(scroll = true) {
  const current = findMatches.length ? findIndex : -1;
  // Only the old and the new current match change. A marked current match is filled by its marks.
  if (findHighlight) {
    findHighlight.current.clear();
    if (current >= 0 && !findMarks.has(current)) findHighlight.current.add(findStatic(current));
    registerHighlights();
  }
  for (const mark of findMarks.get(findMarked) ?? []) mark.dataset.current = 'false';
  for (const mark of findMarks.get(current) ?? []) mark.dataset.current = 'true';
  findMarked = current;
  $('find-count').textContent = !$('find-query').value ? '' : findMatches.length ? `${findIndex + 1} of ${findMatches.length}` : 'No matches';
  $('find-next').disabled = $('find-previous').disabled = !findMatches.length;
  if (scroll && current >= 0) scrollToMatch(current);
}
// Chunks end after a newline where one is near, and a chunk inside a longer line ends with that line,
// so the line can be a block of its own. A longer line is split after a space that no mark
// or joiner follows, or between two ASCII characters, which never join into one glyph. Text with
// neither, as in CJK, is split where a grapheme cluster starts. So the text lays out as one node would.
const findJoins = /[\p{M}\p{Grapheme_Extend}\p{Emoji_Modifier}\u200d\u0e33\u0eb3]/uy;
function chunkStarts(output) {
  const starts = [0], ascii = at => output.charCodeAt(at) >= 32 && output.charCodeAt(at) < 127;
  const spaced = at => { findJoins.lastIndex = at; return output[at - 1] === ' ' && !findJoins.test(output); };
  let start = 0, line = output.indexOf('\n');
  while (output.length - start > findChunk || (start && output[start - 1] !== '\n' && line >= 0)) {
    let end = start;
    while (line >= 0 && line < start + findChunk && (end === start || !start || output[start - 1] === '\n')) { end = line + 1; line = output.indexOf('\n', end); }
    for (let at = start + findChunk; end === start && at > start; at--) if (spaced(at)) end = at;
    for (let at = start + findChunk; end === start && at > start; at--) if (ascii(at - 1) && ascii(at)) end = at;
    // Every chunk starts a cluster, so the clusters from `start` are those of the whole text.
    if (end === start && globalThis.Intl?.Segmenter) {
      end = start + new Intl.Segmenter(undefined, { granularity: 'grapheme' })
        .segment(output.slice(start, start + findChunk + 2)).containing(findChunk).index;
    }
    for (let at = start + findChunk + 1; end === start && at < output.length; at++) if (output[at - 1] === '\n' || (ascii(at - 1) && ascii(at))) end = at;
    if (end === start || end >= output.length) break;
    starts.push(end); start = end;
  }
  return starts;
}
// Paint the output as one text node per chunk, with no marks, in blocks of whole lines. A block ends
// where a line starts findBlock characters or more into it, and before a line over findBlock long.
function paintText(output) {
  const terminal = $('terminal');
  let keptBlocks = 0, keptChunks = 0, from = 0;
  if (findText && output && findBlocks.length) {
    const shared = commonPrefixLength(findText, output);
    // Rebuild the block containing the preceding chunk too: a changed newline,
    // word or combining mark can change the last chunk's deterministic boundary.
    const chunk = Math.max(0, findChunkAt(shared) - 1);
    while (keptBlocks + 1 < findBlocks.length && findBlocks[keptBlocks + 1] <= chunk) keptBlocks++;
    if (findBlockNodes.slice(0, keptBlocks).some((node, index) => terminal.childNodes[index] !== node)) keptBlocks = 0;
    keptChunks = findBlocks[keptBlocks]; from = findStarts[keptChunks];
  }
  // Marks can split text nodes inside retained blocks. Restore those nodes before
  // replacing the suffix, then the normal Find path recomputes its visible marks.
  markMatches([]);
  findText = output;
  findStarts = findStarts.slice(0, keptChunks).concat(chunkStarts(output.slice(from)).map(start => start + from));
  findNodes = findNodes.slice(0, keptChunks).concat(output ? findStarts.slice(keptChunks).map((start, index) =>
    document.createTextNode(output.slice(start, findStarts[keptChunks + index + 1] ?? output.length))) : []);
  const retainedBlocks = findBlocks.slice(0, keptBlocks), retainedNodes = findBlockNodes.slice(0, keptBlocks);
  findSplits = new Map(); findBlocks = findNodes.length ? [0] : []; findComplexBlocks = new Map();
  if (findNodes.length) findBlocks = retainedBlocks.concat(keptChunks);
  for (let chunk = keptChunks + 1; chunk < findStarts.length; chunk++) {
    const start = findStarts[chunk];
    if (output[start - 1] !== '\n') continue;
    const end = output.indexOf('\n', start);
    if (start - findStarts[findBlocks.at(-1)] >= findBlock || (end < 0 ? output.length : end) - start > findBlock) findBlocks.push(chunk);
  }
  // The last block is painted in the terminal itself, after the others: WebKit copies a selection
  // that ends after a block element with one more line.
  findBlockNodes = retainedNodes.concat(findBlocks.slice(keptBlocks, -1).map((chunk, index) => {
    const block = document.createElement('span');
    block.append(...findNodes.slice(chunk, findBlocks[keptBlocks + index + 1]));
    return block;
  }));
  if (!keptBlocks) terminal.replaceChildren(...findBlockNodes, ...findNodes.slice(findBlocks.at(-1) ?? 0));
  else {
    while (terminal.childNodes.length > keptBlocks) terminal.lastChild.remove();
    terminal.append(...findBlockNodes.slice(keptBlocks), ...findNodes.slice(findBlocks.at(-1) ?? 0));
  }
}
// Whether the matches on a block are marked in WebKit: it has complex text.
function findMarkable(block) {
  if (!findComplexBlocks.has(block)) {
    const from = findStarts[findBlocks[block]], to = findStarts[findBlocks[block + 1]] ?? findText.length;
    findComplexBlocks.set(block, findComplex.test(findText.slice(from, to)));
  }
  return findComplexBlocks.get(block);
}
// The matches on the block of match `index`, as [first, end, block], when WebKit marks them all at
// once: the block has complex text and is over twice findBlock long, so one line, laid out again
// whenever its marks change. So a scroll or Next along the line changes no marks. Otherwise null.
function findWhole(index) {
  if (!findHighlight || !findComplex) return null;
  const chunk = findChunkAt(findMatches[index].start);
  let block = 0, high = findBlocks.length - 1;
  while (block < high) { const middle = (block + high + 1) >> 1; if (findBlocks[middle] <= chunk) block = middle; else high = middle - 1; }
  const from = findStarts[findBlocks[block]], to = findStarts[findBlocks[block + 1]] ?? findText.length;
  if (to - from <= 2 * findBlock || !findMarkable(block)) return null;
  const first = offset => {
    let low = 0, high = findMatches.length;
    while (low < high) { const middle = (low + high) >> 1; if (findMatches[middle].start < offset) low = middle + 1; else high = middle; }
    return low;
  };
  return [first(from), first(to), block];
}
// The spans to mark in a chunk for its matches in `indices`, as [start, end, indices] in findText. In
// WebKit a span takes in the whole grapheme clusters at its ends, and spans that then overlap are one.
function markSpans(chunk, indices) {
  const from = findStarts[chunk], to = findStarts[chunk + 1] ?? findText.length, spans = [];
  let clusters = null;
  // Two characters under U+0300 are never one cluster, but for a carriage return and line feed.
  const whole = (at, end) => {
    if (!findComplex || !findClusters || at <= from || at >= to || Math.max(findText.charCodeAt(at - 1), findText.charCodeAt(at)) < 0x300) return at;
    clusters ??= findClusters.segment(findText.slice(from, to));
    const { index, segment } = clusters.containing(at - from);
    return from + (end && from + index < at ? index + segment.length : index);
  };
  for (const index of indices) {
    const start = whole(Math.max(findMatches[index].start, from), false), end = whole(Math.min(findMatches[index].end, to), true);
    const last = spans.at(-1);
    if (last && start < last[1]) { last[1] = Math.max(last[1], end); last[2].push(index); }
    else spans.push([start, end, [index]]);
  }
  return spans;
}
// Mark the matches in `shown`, an ascending index list, and no others. Only the chunks whose marked
// offsets change are painted again, and a selection in them is put back on the same text.
function markMatches(shown) {
  const wanted = new Map();
  for (const index of shown) {
    const { start, end } = findMatches[index];
    for (let chunk = findChunkAt(start); findStarts[chunk] < end; chunk++) {
      if (!wanted.has(chunk)) wanted.set(chunk, []);
      wanted.get(chunk).push(index);
    }
  }
  const changes = [];
  for (const chunk of findSplits.keys()) if (!wanted.has(chunk)) changes.push([chunk]);
  for (const [chunk, indices] of wanted) {
    const split = findSplits.get(chunk), spans = markSpans(chunk, indices), key = spans.map(([start, end]) => `${start},${end}`).join(' ');
    if (split?.key === key) split.owners = spans.map(span => span[2]); else changes.push([chunk, spans, key]);
  }
  const putBack = changes.length ? keepSelection() : null;
  for (const [chunk, spans, key] of changes) {
    const old = findSplits.get(chunk)?.nodes ?? [findNodes[chunk]], fragment = document.createDocumentFragment();
    findSplits.delete(chunk);
    if (!spans) fragment.append(findNodes[chunk]);
    else {
      const split = { key, owners: spans.map(span => span[2]), nodes: [], pieces: [], marks: [] };
      let cursor = findStarts[chunk];
      const text = stop => {
        if (stop <= cursor) return;
        const node = document.createTextNode(findText.slice(cursor, stop));
        split.nodes.push(node); split.pieces.push({ node, start: cursor }); cursor = stop;
      };
      for (const [start, end] of spans) {
        const mark = document.createElement('mark');
        text(start);
        mark.textContent = findText.slice(start, end);
        split.nodes.push(mark); split.pieces.push({ node: mark.firstChild, start }); split.marks.push(mark);
        cursor = end;
      }
      text(findStarts[chunk + 1] ?? findText.length);
      for (const node of split.nodes) fragment.append(node);
      findSplits.set(chunk, split);
    }
    old[0].replaceWith(fragment);
    for (const node of old.slice(1)) node.remove();
  }
  putBack?.();
  findMarks = new Map();
  for (const { owners, marks } of findSplits.values()) {
    marks.forEach((mark, at) => {
      const current = String(owners[at].includes(findIndex));
      if (mark.dataset.current !== current) mark.dataset.current = current;
      for (const index of owners[at]) {
        if (!findMarks.has(index)) findMarks.set(index, []);
        findMarks.get(index).push(mark);
      }
    });
  }
  findMarked = findMatches.length ? findIndex : -1;
  return changes.length > 0;
}
// The selection's ends in the terminal as offsets in findText, and a function that puts them back
// on the text nodes painted since.
function keepSelection() {
  const selection = globalThis.getSelection?.(), terminal = $('terminal');
  if (!selection || selection.isCollapsed || !findScratch) return null;
  const { anchorNode, anchorOffset, focusNode, focusOffset } = selection;
  const offset = (node, at) => {
    if (!terminal.contains(node)) return null;
    findScratch.setStart(terminal, 0); findScratch.setEnd(node, at);
    return findScratch.toString().length;
  };
  const anchor = offset(anchorNode, anchorOffset), focus = offset(focusNode, focusOffset);
  if (anchor === null && focus === null) return null;
  return () => selection.setBaseAndExtent(...(anchor === null ? [anchorNode, anchorOffset] : findPoint(anchor, false)),
    ...(focus === null ? [focusNode, focusOffset] : findPoint(focus, false)));
}
// The chunk with a place in findText: the last that starts at or before it, or before it for the
// end of a range.
function findChunkAt(offset, end = false) {
  let low = 0, high = findStarts.length - 1;
  while (low < high) {
    const middle = (low + high + 1) >> 1, start = findStarts[middle];
    if (end ? start < offset : start <= offset) low = middle; else high = middle - 1;
  }
  return low;
}
// The painted text node and offset at a place in findText, found in the same way.
function findPoint(offset, end) {
  const chunk = findChunkAt(offset, end);
  const pieces = findSplits.get(chunk)?.pieces ?? [{ node: findNodes[chunk], start: findStarts[chunk] }];
  let piece = pieces[0];
  for (const next of pieces) if (end ? next.start < offset : next.start <= offset) piece = next;
  return [piece.node, offset - piece.start];
}
// The box of one match, or from its start to the end of match `last`.
function findBox(index, last = index) {
  if (!findScratch || !findNodes.length) return null;
  findScratch.setStart(...findPoint(findMatches[index].start, false));
  findScratch.setEnd(...findPoint(findMatches[last].end, true));
  return findScratch.getBoundingClientRect();
}
function findStatic(index) {
  const [startContainer, startOffset] = findPoint(findMatches[index].start, false);
  const [endContainer, endOffset] = findPoint(findMatches[index].end, true);
  return new StaticRange({ startContainer, startOffset, endContainer, endOffset });
}
// Like scrollIntoView({ block: 'center' }) on the match, inside the terminal only.
function scrollToMatch(index) {
  const box = findBox(index);
  if (!box) return;
  const terminal = $('terminal'), frame = terminal.getBoundingClientRect();
  const top = frame.top + terminal.clientTop, left = frame.left + terminal.clientLeft;
  terminal.scrollTop += box.top + box.height / 2 - (top + terminal.clientHeight / 2);
  if (box.left < left) terminal.scrollLeft -= left - box.left;
  else if (box.right > left + terminal.clientWidth) terminal.scrollLeft += Math.min(box.left - left, box.right - left - terminal.clientWidth);
}
function showMatchesSoon() {
  if (!findFrame) findFrame = globalThis.requestAnimationFrame?.(showVisibleMatches) ?? 0;
}
// Highlight every match in view and those up to a quarter screen around it, so a smaller scroll
// keeps them. Past findCap matches out of view, only the nearest are kept, for a shorter scroll.
function showVisibleMatches() {
  findFrame = 0;
  const terminal = $('terminal'), height = terminal.clientHeight, width = terminal.clientWidth;
  if (!findMatches.length || !height) return;
  const scroll = [terminal.scrollTop, terminal.scrollLeft];
  if (findShown && Math.abs(scroll[0] - findBand[0]) <= findBand[2] * height && Math.abs(scroll[1] - findBand[1]) <= findBand[2] * width) return;
  const frame = terminal.getBoundingClientRect();
  const top = frame.top + terminal.clientTop, bottom = top + height;
  const left = frame.left + terminal.clientLeft, right = left + width;
  // Matches are in document order, so their boxes run top to bottom. A match on a line marked whole
  // is measured by its line: a range over complex text that no mark splits costs up to a millisecond.
  // The last block is in the terminal itself, so it runs from the one before to the end.
  const box = index => {
    const block = findWhole(index)?.[2];
    if (block === undefined) return findBox(index);
    if (block < findBlockNodes.length) return findBlockNodes[block].getBoundingClientRect();
    return { top: findBlockNodes.at(-1)?.getBoundingClientRect().bottom ?? -Infinity, bottom: Infinity };
  };
  const first = (low, high, test) => {
    while (low < high) {
      const middle = (low + high) >> 1;
      if (test(box(middle))) high = middle; else low = middle + 1;
    }
    return low;
  };
  // Raw output does not wrap, so a line wider than the view also needs the columns in view.
  const wide = terminal.scrollWidth > width;
  // The matches that meet the view grown by `margin` screens on each side.
  const near = margin => {
    const shown = [], y = margin * height, x = margin * width;
    const from = first(0, findMatches.length, box => box.bottom > top - y);
    const to = first(from, findMatches.length, box => box.top >= bottom + y);
    for (let index = from; index < to;) {
      let next = to;
      if (wide) {
        const end = findText.indexOf('\n', findMatches[index].start);
        for (let low = index + 1; end >= 0 && low < next;) {
          const middle = (low + next) >> 1;
          if (findMatches[middle].start > end) next = middle; else low = middle + 1;
        }
        // Right-to-left text runs backwards on a line, so a span of its matches is left out only
        // when the box around all of it is out of the columns, and shown whole when inside them.
        const columns = (low, high) => {
          const box = findBox(low, high - 1);
          if (box.right <= left - x || box.left >= right + x) return;
          if (high - low > 1 && (box.left < left - x || box.right > right + x)) {
            const middle = (low + high) >> 1;
            columns(low, middle); columns(middle, high);
          } else for (let at = low; at < high; at++) shown.push(at);
        };
        // Measuring columns on a long line of complex text costs more than marking all of it.
        if (findWhole(index)) for (let at = index; at < next; at++) shown.push(at); else columns(index, next);
      } else for (let at = index; at < next; at++) shown.push(at);
      index = next;
    }
    return shown;
  };
  const view = near(0);
  let shown = near(1 / 4), margin = 1 / 4;
  const kept = new Set(view.concat(shown.filter(index => findWhole(index))));
  if (shown.length - kept.size > findCap) {
    // Keep the findCap matches out of view nearest to it, in screens on either axis, and those on a line
    // marked whole. A scroll shorter than the nearest one left out still has every match in view highlighted.
    const distance = index => {
      const box = findBox(index);
      return Math.max((top - box.bottom) / height, (box.top - bottom) / height, (left - box.right) / width, (box.left - right) / width);
    };
    const out = shown.filter(index => !kept.has(index)).map(index => [distance(index), index]).sort((a, b) => a[0] - b[0]);
    margin = out[findCap][0];
    shown = [...kept].concat(out.slice(0, findCap).map(([, index]) => index)).sort((a, b) => a - b);
  }
  // Without highlights every match is marked, and in WebKit each on a block of complex text.
  const marked = [], lit = [];
  for (let at = 0, block = 0; at < shown.length; at++) {
    const chunk = findChunkAt(findMatches[shown[at]].start);
    while (findBlocks[block + 1] <= chunk) block++;
    const whole = findWhole(shown[at]);
    if (!whole) (!findHighlight || (findComplex && findMarkable(block)) ? marked : lit).push(shown[at]);
    else {
      for (let index = whole[0]; index < whole[1]; index++) marked.push(index);
      while (shown[at + 1] < whole[1]) at++;
    }
  }
  findHighlight?.match.clear();
  const changed = markMatches(marked);
  for (const index of lit) findHighlight.match.add(findStatic(index));
  if (findHighlight) registerHighlights();
  // The current match is on new nodes.
  if (changed && findHighlight) updateFind(false);
  findShown = shown; findBand = [...scroll, margin];
}
// A new width or font wraps the text again under the same scroll offset.
function refindVisible() {
  findShown = null;
  if (findMatches.length) showMatchesSoon();
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
$('sessions-dialog').addEventListener('close', () => { dropWaitingSearch(); if (!$('sessions-toggle').hidden) $('sessions-toggle').focus(); });
$('session-search').oninput = searchSaved;
$('find-toggle').onclick = () => {
  $('find-bar').hidden = false; $('find-toggle').setAttribute('aria-expanded', 'true');
  $('find-query').focus(); paintOutput();
};
$('find-query').oninput = () => { findIndex = 0; paintOutput(); updateFind(); };
$('terminal').addEventListener('scroll', () => { if (findMatches.length) showMatchesSoon(); });
// The observer also keeps refindVisible alive: WebKit drops a listener on document.fonts once
// nothing else holds its function.
if (globalThis.ResizeObserver) new ResizeObserver(refindVisible).observe($('terminal'));
document.fonts?.addEventListener?.('loadingdone', refindVisible);
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

// The saved search that has not been sent yet.
let waitingSearch = null;
// A cleared box or a closed sheet ends the query; skip it at its turn.
function dropWaitingSearch() { if (waitingSearch) waitingSearch.stale = true; waitingSearch = null; }
function request(action, text, tabID = selected, pairing = false, extra = {}) {
  if (!connected && !pairing && action !== 'state') return Promise.reject(new Error('Not connected.'));
  if (action !== 'chats') return enqueue(() => transmit(action, text, tabID, pairing, extra));
  // Typing can outrun the Mac. Last in line, the waiting search takes the newest query;
  // behind a later command it is skipped at its turn. Its callers see a stale token.
  const waiting = waitingSearch;
  if (waiting?.tail === outgoing && waiting.generation === generation && waiting.epoch === commandEpoch) {
    Object.assign(waiting, { text, tabID });
    return waiting.reply;
  }
  if (waiting) waiting.stale = true;
  const search = waitingSearch = { text, tabID, generation, epoch: commandEpoch };
  search.reply = enqueue(async () => {
    if (waitingSearch === search) waitingSearch = null;
    return search.stale ? { stale: true } : transmit(action, search.text, search.tabID, pairing, extra);
  });
  search.tail = outgoing;
  return search.reply;
}
async function enqueue(send) {
  if (queuedCommands >= 32) throw new Error('Too many pending commands. Wait for the Mac.');
  queuedCommands++;
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
    return await send();
  } finally { queuedCommands--; release(); }
}
async function transmit(action, text, tabID, pairing, extra = {}) {
  if (!socket || socket.readyState !== WebSocket.OPEN || !challenge || (!connected && !pairing && action !== 'state')) throw new Error('Not connected.');
  const ws = socket, current = generation, epoch = commandEpoch, seq = ++sequence;
  const message = { challenge, clientNonce, sequence: seq, action, ...(tabID ? { tabID } : {}), ...(text !== undefined ? { text } : {}), ...extra };
  const data = await seal(message, pairing ? bootstrap : credential.key, 'phone');
  if (current !== generation || epoch !== commandEpoch || ws.readyState !== WebSocket.OPEN) throw new Error('Connection lost.');
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => {
      if (current !== generation || epoch !== commandEpoch || socket !== ws) return;
      pending.delete(seq);
      reject(new Error('No response. Check the terminal before sending again.'));
      commandEpoch++;
      ws.close();
    }, 10000);
    pending.set(seq, { resolve, reject, timer, action, tabID });
    const flight = newFlight?.attempt.action === action && ['new', 'createProject'].includes(action) ? newFlight : null;
    if (flight) flight.dispatched = true;
    ws.send(JSON.stringify({ data }));
    if (flight) updateNewControls();
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
        offline('Connecting…');
        for (const item of pending.values()) {
          clearTimeout(item.timer);
          item.reject(new Error('Connection changed. Check the terminal before sending again.'));
        }
        pending.clear();
        challenge = frame.hello;
        clientNonce = randomKey();
        sequence = 0;
        freshHandshake = true;
        const authorizationEpoch = commandEpoch;
        const authorization = bootstrap ? request('pair', newDeviceKey, undefined, true) : request('state');
        authorization.then(() => {
          if (current !== generation || authorizationEpoch !== commandEpoch) return;
          bootstrap = null; newDeviceKey = null;
          if (replacingMemory) {
            for (const list of replacingMemory.attachments.values()) for (const item of list) if (item.preview) URL.revokeObjectURL(item.preview);
            replacingMemory = null;
          }
          if (unsaved) { unsaved = false; storage('put', credential).catch(error => showError(error.message)); }
          reconnectDelay = 500;
          clearTimeout(connectTimer);
          connected = true; busy = false;
          $('status').textContent = $('status-live').textContent = 'Connected'; $('status').dataset.connected = 'true';
          showError(''); updateControls(); poll();
        }).catch(error => {
          if (current !== generation || authorizationEpoch !== commandEpoch) return;
          if (replacingMemory) {
            const saved = replacingMemory; replacingMemory = null;
            credential = saved.credential; bootstrap = null; newDeviceKey = null; unsaved = false; stopped = false;
            for (const [key, value] of saved.drafts) drafts.set(key, value);
            for (const [key, value] of saved.attachments) attachmentDrafts.set(key, value);
            for (const [key, value] of saved.histories) histories.set(key, value);
            sessionTabs = saved.tabs; selected = saved.selected; $('message').value = saved.message;
            connect();
          }
          showError(error.message);
        });
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
        if (!reply.clientNonce) {
          const error = new Error('Update Sigil on your Mac to reconnect securely.');
          stopped = true;
          for (const item of pending.values()) { clearTimeout(item.timer); item.reject(error); }
          pending.clear();
          throw error;
        }
        if (reply.clientNonce !== clientNonce) return;
        const item = pending.get(reply.sequence);
        if (!item) return;
        if (reply.challenge !== challenge) return; // A delayed reply from an earlier Mac epoch.
        if (reply.ok !== true) {
          pending.delete(reply.sequence); clearTimeout(item.timer);
          const error = new Error(reply.error || 'The Mac could not complete this action.');
          error.verifiedReply = true;
          item.reject(error);
          return;
        }
        if (typeof reply.ticket === 'string' && /^[a-f0-9]{64}$/.test(reply.ticket)
            && reply.ticket !== credential.ticket) {
          credential.ticket = reply.ticket;
          try { await storage('put', credential); } catch { /* keep the in-memory ticket */ }
        }
        if (current !== generation || reply.clientNonce !== clientNonce || reply.challenge !== challenge
          || socket !== ws || ws.readyState !== WebSocket.OPEN) return;
        if (item.action === 'earlier') pendingEarlier = {
          tabID: item.tabID, slice: typeof reply.earlier === 'string' ? reply.earlier : '',
        };
        if (reply.state) {
          // Restart replaces the Mac tab ID. Move drafts before pruning closed tabs.
          const next = reply.restartedTabID;
          const originalTab = sessionTabs.find(tab => tab.id === item.tabID);
          const restartedTab = reply.state.tabs?.find(tab => tab.id === next) ?? reply.restartedSession;
          const movedRestart = item.action === 'restart' && typeof next === 'string'
            && next.length > 0 && next.length <= 64 && next !== item.tabID
            && sameConversation(originalTab, restartedTab);
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
    }).catch(error => { if (current === generation) { showError(error.message?.startsWith('Update Sigil') ? error.message : 'Could not verify the connection.'); ws.close(); } });
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
// The displayed picker can change before the Mac confirms its selection. Keep
// the old draft readable and focused, but do not accept edits for an uncertain target.
async function changeSession(action, text, tabID, extra = {}) {
  const current = generation, epoch = commandEpoch;
  const selection = selectingSession = { current, epoch };
  updateControls();
  try {
    await request(action, text, tabID, false, extra);
    return current === generation && epoch === commandEpoch;
  } catch (error) {
    if (current === generation && epoch === commandEpoch) throw error;
    return false;
  } finally {
    // A timed-out socket may still be closing. Release only this selection's
    // editor guard; never unlock a newer connection's pending selection.
    if (selectingSession === selection) {
      selectingSession = false; $('tabs').value = selected || ''; updateControls();
    }
  }
}
async function perform(work) {
  if (!connected || busy) return;
  const current = generation, epoch = commandEpoch;
  busy = true; updateControls(); showError('');
  try { await work(); }
  catch (error) { showError(error.message); $('tabs').value = selected || ''; }
  finally { if (generation === current && commandEpoch === epoch) { busy = false; updateControls(); } }
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
function requireConnection(current, epoch) {
  if (current !== generation || epoch !== commandEpoch || !connected) {
    throw new Error('Connection changed. Check the terminal before sending again.');
  }
}
async function uploadFile(payload, tabID, current = generation, epoch = commandEpoch) {
  const transfer = randomKey().slice(0, 32);
  const count = Math.max(1, Math.ceil(payload.bytes.length / CHUNK));
  for (let index = 0; index < count; index++) {
    const piece = payload.bytes.subarray(index * CHUNK, index * CHUNK + CHUNK);
    // The relay closes a socket over 30 frames/s, and the Mac replies once per chunk.
    const wait = lastChunkAt + 50 - Date.now();
    if (wait > 0) await new Promise(resolve => setTimeout(resolve, wait));
    requireConnection(current, epoch);
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
  // Check the text as sent: after attachments it gains a leading space.
  const payload = files.length ? ` ${text}` : text;
  if (new TextEncoder().encode(payload).length > 8192) { showError('Keep the message under 8 KB.'); return; }
  const target = selected, current = generation, epoch = commandEpoch;
  // Size-check every file before the Mac pastes any of them into the prompt.
  const payloads = [];
  for (const item of files) {
    payloads.push(await prepareFile(item.file));
    requireConnection(current, epoch);
  }
  for (const [index, item] of files.entries()) {
    await uploadFile(payloads[index], target, current, epoch);
    requireConnection(current, epoch);
    // The Mac has pasted this file, so a retry must not send it again.
    const list = attachmentDrafts.get(target);
    const at = list ? list.indexOf(item) : -1;
    if (at >= 0) { list.splice(at, 1); if (item.preview) URL.revokeObjectURL(item.preview); }
    if (selected === target) renderAttachments();
  }
  requireConnection(current, epoch);
  if (text.trim()) await request('input', payload, target);
  requireConnection(current, epoch);
  if (submit) {
    await new Promise(resolve => setTimeout(resolve, 100));
    requireConnection(current, epoch);
    await request('key', 'enter', target);
  }
  requireConnection(current, epoch);
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
function resizeMessage(atBottom) {
  const terminal = $('terminal');
  const scrollTop = terminal.scrollTop;
  atBottom ??= terminal.scrollHeight - terminal.scrollTop - terminal.clientHeight < 60;
  const message = $('message');
  message.style.height = 'auto';
  message.style.height = `${message.scrollHeight + 2}px`;
  terminal.scrollTop = atBottom ? terminal.scrollHeight : scrollTop;
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
  resizeMessage(atBottom);
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
$('tabs').onchange = () => void perform(() => changeSession('select', undefined, $('tabs').value));
$('new').onclick = () => void perform(async () => {
  projectTarget = null; worktreeChoice = null;
  const sheet = ++newSheetEpoch;
  $('new-project-form').hidden = true; $('new-choices').hidden = false;
  let reply;
  try { reply = await request('projects'); } catch (error) {
    // A Mac without the project list starts New in its current folder.
    if (error.message !== 'Unknown action.') throw error;
    if (pendingNew()) {
      renderProviders(null); renderProjects([]); return;
    }
    await newCommand('new');
    return;
  }
  let options;
  try { options = (await request('options')).options; } catch (error) {
    if (error.message !== 'Unknown action.') throw error;
  }
  renderProviders(options);
  if (sheet !== newSheetEpoch) return;
  renderProjects(reply.projects, 0, reply.projectsTruncated === true);
});
$('provider').onchange = () => { providerChoice = $('provider').value; showProviderProblem(); };
$('new-model').onchange = $('new-effort').onchange = () => updateNewControls();
$('new-worktree').onchange = () => { worktreeChoice = $('new-worktree').checked; updateNewControls(); };
$('project-start').onclick = () => void perform(() => startProject());
$('project-add').onclick = () => {
  if (!connected || busy || pendingNew() || !canUseSessionOps || !newOptions?.locations.length) return;
  $('new-choices').hidden = true; $('new-project-form').hidden = false;
  $('project-name').value = ''; updateNewControls(); $('project-name').focus();
};
$('project-back').onclick = () => {
  if (newFlight) return;
  $('new-project-form').hidden = true; $('new-choices').hidden = false; $('project-add').focus();
};
$('project-name').oninput = $('project-location').onchange = () => updateNewControls();
$('new-project-form').onsubmit = event => {
  event.preventDefault();
  const name = folderName($('project-name').value), location = newOptions?.locations.find(item => item.folder === $('project-location').value);
  if (!connected || busy || pendingNew() || !canUseSessionOps || !name || !location) return;
  const sheet = newSheetEpoch;
  void perform(async () => {
    const reply = await newCommand('createProject', location.folder, { name });
    const project = await findProject(reply.project.folder);
    if (sheet !== newSheetEpoch || !$('project-dialog').open) return;
    // Use authoritative repository metadata before offering a worktree for the new folder.
    renderProjects(project ? [project, ...newProjects.filter(item => item.folder !== project.folder)] : [reply.project, ...newProjects]);
    projectTarget = project || projectRecord(reply.project);
    worktreeChoice = null;
    $('new-project-form').hidden = true; $('new-choices').hidden = false; updateNewControls();
    $('project-start').focus();
  });
};
$('project-check').onclick = () => void perform(() => reconcileProject());
$('project-cancel').onclick = () => $('project-dialog').close();
$('project-dialog').addEventListener('close', () => { ++newSheetEpoch; if (!$('new').disabled) $('new').focus(); });
async function interrupt() {
  if (!connected || !selected || selectingSession) return;
  try { await request('key', 'interrupt'); }
  catch (error) { showError(error.message); }
}
$('interrupt').onclick = interrupt;
$('stop').onclick = interrupt;
$('restart').onclick = () => void perform(() => request('restart'));
$('attach-toggle').onclick = () => $('attach').click();
$('attach').onchange = () => {
  const list = attachmentsFor();
  let tooBig = false, overLimit = false;
  for (const file of $('attach').files) {
    // Photos are compressed before upload; other files must already fit.
    if (!isImageFile(file) && file.size > MAX_REMOTE_BYTES) { tooBig = true; continue; }
    if (list.length >= 16) { overLimit = true; continue; }
    list.push({
      file, name: file.name || 'file',
      preview: isImageFile(file) ? URL.createObjectURL(file) : '',
    });
  }
  const problems = [tooBig && 'Keep files under 4 MB.', overLimit && 'Up to 16 files per message. The rest were not added.'];
  if (tooBig || overLimit) showError(problems.filter(Boolean).join(' '));
  $('attach').value = '';
  renderAttachments();
};
$('message').addEventListener('keydown', event => {
  if (event.key !== 'Enter' || event.shiftKey || event.isComposing) return;
  if (!event.metaKey && !event.ctrlKey) return;
  event.preventDefault();
  void perform(() => sendText(true));
});
// request() already sends in order, so a quick tap is queued instead of dropped.
document.querySelectorAll('[data-key]').forEach(button => { button.onclick = () => request('key', button.dataset.key).catch(error => showError(error.message)); });
$('reconnect').onclick = $('welcome-reconnect').onclick = () => { stopped = false; revoked = false; reconnectDelay = 500; connect(); };
// Forgetting cannot be undone from the phone, so it asks first.
$('forget').onclick = () => {
  $('connection').open = false;
  $('forget-dialog').returnValue = '';
  $('forget-dialog').showModal();
};
$('forget-dialog').addEventListener('close', () => { if ($('forget-dialog').returnValue === 'forget') void forget(); });
async function forget() {
  stopped = true; ++generation; clearTimeout(reconnectTimer); socket?.close(); offline();
  credential = null; revoked = false; unsaved = false; bootstrap = null; newDeviceKey = null; selected = null; drafts.clear(); tabsSignature = '';
  selectedStatus = null; tabCount = 0;
  $('keys').hidden = true; $('keys-toggle').setAttribute('aria-expanded', 'false');
  clearAttachments();
  rawOutput = ''; rawMode = false; displayedOutput = null; readableFrom = null; readableText = '';
  readable.reset();
  histories.clear(); pendingEarlier = null; earlierFlight = false; searchToken++;
  sessionTabs = []; $('sessions-dialog').close(); $('project-dialog').close(); closeFind();
  $('raw-toggle').setAttribute('aria-pressed', 'false'); $('raw-toggle').textContent = 'Show raw terminal';
  $('session-toolbar').hidden = true; $('brand').hidden = false;
  $('terminal').textContent = ''; $('message').value = ''; $('controls').hidden = true; $('welcome').hidden = false;
  try { await storage('delete'); showError(''); } catch { showError('Could not clear pairing. Clear this site’s data in browser settings.'); }
  updateControls();
}
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
  // Pairing credentials are not replaced on disk until this Mac authenticates.
  // Contents from the previous Mac must not share an ID namespace with this one.
  if (credential && !replacingMemory) replacingMemory = {
    credential, drafts: new Map(drafts), attachments: new Map(attachmentDrafts), histories: new Map(histories),
    tabs: sessionTabs, selected, message: $('message').value,
  };
  drafts.clear(); attachmentDrafts.clear(); histories.clear(); sessionTabs = [];
  selected = null; selectedStatus = null; selectedRunning = undefined; selectedCapabilities = undefined;
  currentPrompt = null; promptSignature = null; tabsSignature = ''; rawOutput = ''; displayedOutput = null;
  readable.reset(); readableFrom = null; readableText = '';
  pendingEarlier = null; earlierFlight = false; searchToken++;
  $('message').value = ''; $('terminal').textContent = ''; $('interaction').hidden = true;
  renderAttachments();
  bootstrap = await importKey(pairing.key);
  newDeviceKey = randomKey();
  credential = { room: pairing.room, key: await importKey(newDeviceKey) };
  // Keep the stored pairing until the Mac accepts this one.
  unsaved = true;
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
  $('scanner-error').hidden = true;
  $('scanner-error').textContent = '';
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
        if (result?.error) {
          // #error sits under the full-screen scanner. Show the reason on the scanner only.
          if ($('scanner-error').textContent !== result.error) $('scanner-error').textContent = result.error;
          $('scanner-error').hidden = false;
        }
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
function confirmReplace() {
  const dialog = $('replace-dialog');
  dialog.returnValue = '';
  dialog.showModal();
  return new Promise(resolve => dialog.addEventListener('close', () => resolve(dialog.returnValue === 'replace'), { once: true }));
}
async function start() {
  const fragment = new URLSearchParams(location.hash.slice(1));
  const pairing = pairingFromText(location.hash, location.origin);
  history.replaceState(null, '', location.pathname);
  if (!crypto.subtle) throw new Error('Open Sidereal using HTTPS.');
  if (pairing?.room) {
    // A link must not silently replace a working pairing.
    const saved = await storage('get');
    if (!saved || await confirmReplace()) await beginPair(pairing);
    else { credential = saved; updateControls(); connect(); }
  } else if (pairing?.error || fragment.has('room') || fragment.has('key')) {
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
