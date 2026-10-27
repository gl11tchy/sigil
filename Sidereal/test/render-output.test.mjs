import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import vm from 'node:vm';
import { createReadableOutput, readableOutput } from '../public/output.mjs';

const source = await readFile(new URL('../public/app.mjs', import.meta.url), 'utf8');
function functionSource(start, end) {
  const from = source.indexOf(start), to = source.indexOf(end, from);
  assert.ok(from >= 0 && to > from, `Missing real handler: ${start}`);
  return source.slice(from, to);
}
const render = functionSource('function renderOutput(', '\nfunction renderSessionList()');
const latest = functionSource('function updateLatest()', '\nfunction resizeMessage(');

// Execute the actual handlers. DOM geometry/painting are controlled boundaries;
// expectations below describe visible text, retained selection and scroll intent.
function fixture({ before = 'Alpha\nBeta', after = 'Alpha\nChanged', selection = null,
  find = '', findHidden = true, top = 400, raw = true } = {}) {
  const displayed = raw ? before : readableOutput(before), anchor = {}, outside = {};
  const reader = createReadableOutput();
  reader.update(before);
  const paints = [], appends = [], resets = [];
  let scrollTop = top;
  const terminal = {
    dataset: {}, textContent: displayed, scrollHeight: 1000, clientHeight: 200,
    contains(node) { return node === anchor; },
    get scrollTop() { return scrollTop; },
    set scrollTop(value) { scrollTop = Math.max(0, Math.min(value, this.scrollHeight - this.clientHeight)); },
    append(text) { appends.push(text); this.textContent += text; this.scrollHeight = 1200; },
  };
  const elements = new Map([
    ['terminal', terminal], ['empty-output', { querySelector: () => ({ textContent: '' }) }],
    ['find-bar', { hidden: findHidden }], ['find-query', { value: find }], ['latest', {}],
  ]);
  const state = {
    $: id => elements.get(id), rawMode: raw, rawOutput: after,
    readableFrom: before, readableText: displayed,
    readable: { update(text, options) { resets.push(options.reset); return reader.update(text, options); } },
    displayedOutput: displayed, selected: 'fixture', selectedStatus: 'idle', selectedRunning: true,
    selectedCapabilities: {}, canRestart: false, findIndex: 9, prefixComparisons: 0,
    getSelection: () => selection === null ? null : {
      isCollapsed: selection === 'collapsed', anchorNode: selection === 'outside' ? outside : anchor,
    },
    paintOutput() { paints.push(state.displayedOutput); terminal.textContent = state.displayedOutput; terminal.scrollHeight = 1200; },
  };
  const context = vm.createContext(state);
  vm.runInContext(`
    const nativeStartsWith = String.prototype.startsWith;
    String.prototype.startsWith = function(...args) {
      prefixComparisons++;
      return nativeStartsWith.apply(this, args);
    };
    ${render}
    ${latest}
  `, context);
  return { state, terminal, paints, appends, resets, elements,
    run: (changedSession = false, prepended = false) => state.renderOutput(changedSession, prepended) };
}

for (const [name, before, after] of [
  ['unchanged', 'Alpha\nBeta', 'Alpha\nBeta'], ['append', 'Alpha', 'Alpha\nBeta'],
  ['middle edit', 'Alpha\nBeta', 'AlpXa\nBeta'], ['truncate', 'Alpha\nBeta', 'Alpha'],
  ['prepend', 'Alpha', 'Earlier\nAlpha'], ['clear', 'Alpha', ''],
  ['Unicode rewrite', '🙂 é 👩‍💻', '🙂 è 👩‍🔧'],
]) {
  test(`REA-1194 unselected ${name} preserves text/scroll without a selection-prefix comparison`, () => {
    const f = fixture({ before, after }); f.run();
    assert.equal(f.state.displayedOutput, after);
    assert.equal(f.terminal.textContent, after);
    assert.deepEqual(f.paints, before === after ? [] : [after]);
    assert.deepEqual(f.appends, []);
    assert.equal(f.state.prefixComparisons, 0);
    assert.equal(f.terminal.scrollTop, 400);
    assert.equal(f.elements.get('latest').hidden, false);
  });
}

for (const selection of ['collapsed', 'outside']) {
  test(`REA-1194 ${selection} selection does not suppress a repaint or compare output prefixes`, () => {
    const f = fixture({ selection }); f.run();
    assert.deepEqual(f.paints, ['Alpha\nChanged']);
    assert.equal(f.state.prefixComparisons, 0);
  });
}

test('REA-1194 active selection appends an exact Unicode suffix without repainting', () => {
  const f = fixture({ before: 'Alpha', after: 'Alpha🙂é', selection: 'inside' }); f.run();
  assert.deepEqual(f.appends, ['🙂é']);
  assert.deepEqual(f.paints, []);
  assert.equal(f.state.displayedOutput, 'Alpha🙂é');
  assert.equal(f.terminal.textContent, 'Alpha🙂é');
  assert.equal(f.state.prefixComparisons, 1);
  assert.equal(f.terminal.scrollTop, 400);
});

for (const after of ['AlpXa\nBeta', 'Alpha', 'Earlier\nAlpha\nBeta']) {
  test(`REA-1194 active selection holds a non-append rewrite until release: ${JSON.stringify(after)}`, () => {
    const f = fixture({ after, selection: 'inside' }); f.run();
    assert.equal(f.state.displayedOutput, 'Alpha\nBeta');
    assert.equal(f.terminal.textContent, 'Alpha\nBeta');
    assert.deepEqual(f.appends, []); assert.deepEqual(f.paints, []);
    assert.equal(f.state.prefixComparisons, 1);
    f.state.getSelection = () => null; f.run();
    assert.equal(f.state.displayedOutput, after);
    assert.deepEqual(f.paints, [after]);
    assert.equal(f.state.prefixComparisons, 1);
    assert.equal(f.terminal.scrollTop, 400);
  });
}

test('REA-1194 Find with a query still holds an append during selection', () => {
  const f = fixture({ before: 'Alpha', after: 'Alpha\nBeta', selection: 'inside', find: 'Alpha', findHidden: false });
  f.run();
  assert.equal(f.state.displayedOutput, 'Alpha');
  assert.deepEqual(f.appends, []); assert.deepEqual(f.paints, []);
  assert.equal(f.state.prefixComparisons, 1);
});

test('REA-1194 an empty Find query still permits a selected append', () => {
  const f = fixture({ before: 'Alpha', after: 'Alpha\nBeta', selection: 'inside', findHidden: false }); f.run();
  assert.deepEqual(f.appends, ['\nBeta']);
  assert.equal(f.state.prefixComparisons, 1);
});

test('REA-1194 a reader at the bottom stays at the bottom after repaint', () => {
  const f = fixture({ top: 800 }); f.run();
  assert.equal(f.terminal.scrollTop, 1000);
  assert.equal(f.elements.get('latest').hidden, true);
});

test('REA-1194 explicit prepend bypasses selection and retains the reader offset', () => {
  const f = fixture({ after: 'Earlier\nAlpha\nBeta', selection: 'inside' }); f.run(false, true);
  assert.deepEqual(f.paints, ['Earlier\nAlpha\nBeta']);
  assert.equal(f.terminal.scrollTop, 600);
  assert.equal(f.state.prefixComparisons, 0);
});

test('REA-1194 a session change forces unchanged text to repaint and resets Find/scroll', () => {
  const f = fixture({ after: 'Alpha\nBeta', selection: 'inside' }); f.run(true);
  assert.deepEqual(f.paints, ['Alpha\nBeta']);
  assert.equal(f.state.findIndex, 0);
  assert.equal(f.terminal.scrollTop, 1000);
  assert.equal(f.state.prefixComparisons, 0);
});

test('REA-1194 readable rewrites retain full-formatter equivalence and reset on prepend', () => {
  const before = '│  Earlier output has several words\n│  and continues here\n';
  const after = '│  Earlier output has changed words\n│  and continues here\n';
  const f = fixture({ before, after, raw: false }); f.run();
  assert.equal(f.state.displayedOutput, readableOutput(after));
  assert.deepEqual(f.resets, [false]);
  f.state.rawOutput = 'Earlier heading.\n' + after; f.run(false, true);
  assert.equal(f.state.displayedOutput, readableOutput(f.state.rawOutput));
  assert.deepEqual(f.resets, [false, true]);
  assert.equal(f.state.prefixComparisons, 0);
});

test('REA-1194 the unchanged iOS formatter mirror remains byte-identical', async () => {
  assert.deepEqual(await readFile(new URL('../public/output.mjs', import.meta.url)),
    await readFile(new URL('../../iOS/Sigil/Resources/readable-output.js', import.meta.url)));
});
