import test from 'node:test';
import assert from 'node:assert/strict';
import { readableOutput as fullReadableOutput, createReadableOutput, commonPrefixLength } from '../public/output.mjs';

// Every existing expected-output fixture also checks incremental/full equivalence
// across unrelated snapshots, without changing the full formatter oracle.
const fixtureReader = createReadableOutput();
function readableOutput(snapshot) {
  const full = fullReadableOutput(snapshot);
  assert.equal(fixtureReader.update(snapshot), full);
  return full;
}

test('REA-1194 checkpoints preserve formatter state across adversarial line and character edits', () => {
  const reader = createReadableOutput();
  const parts = ['\n', '┌────┐\n', '│  A wrapped paragraph with many words\n', '│  continues without a paragraph break\n',
    '\n', '9:46 AM\n', '∴ Thinking... 1s\n', '⠋\n', '| ─ ─ ─ ─ ─ |\n', 'a lowercase continuation\n',
    '  if (ready) {\n', '    send();\n', '  }\n', '🙂 é क्‍ष 日本\n', footer, '\nResult after composer\n'];
  const text = parts.join('');
  for (let length = 0; length <= text.length; length++) assert.equal(reader.update(text.slice(0, length)), fullReadableOutput(text.slice(0, length)));
  for (let at = text.length; at >= 0; at -= 7) {
    const changed = text.slice(0, at) + 'changed\n' + text.slice(at);
    assert.equal(reader.update(changed), fullReadableOutput(changed));
    assert.equal(reader.update(text), fullReadableOutput(text));
  }
  for (const suffix of [footer, '\n'.repeat(100), 'Grok 4.6\nCtrl+x:shortcuts', '\n❯ typed draft\n' + footer, '\nFinal result']) {
    assert.equal(reader.update(text + suffix), fullReadableOutput(text + suffix));
    assert.equal(reader.update(text), fullReadableOutput(text));
  }
  reader.reset();
  assert.equal(reader.update(text), fullReadableOutput(text));
  assert.equal(reader.update(''), '');
});

test('REA-1194 changed tails format bounded lines in a 400KB history and reset safely', () => {
  const reader = createReadableOutput();
  const history = Array.from({ length: 5000 }, (_, index) => `│  Result ${index}: a synthetic paragraph with enough words to retain bubble state. │\n`).join('');
  assert.ok(history.length > 400_000);
  let snapshot = history + '│  Current result has enough words\n│  and continues here\n' + footer;
  assert.equal(reader.update(snapshot), fullReadableOutput(snapshot));
  for (let index = 0; index < 40; index++) {
    snapshot = history + `│  Current result ${index} has enough words\n│  and continues here\n` + footer;
    assert.equal(reader.update(snapshot), fullReadableOutput(snapshot));
    assert.ok(reader.lastWork.parsedLines < 20);
    assert.ok(reader.lastWork.formattedLines < 20);
  }
  for (const at of [4095, 65_536, 200_001]) {
    const changed = snapshot.slice(0, at) + 'changed\n' + snapshot.slice(at);
    assert.equal(reader.update(changed), fullReadableOutput(changed));
    assert.equal(reader.update(snapshot), fullReadableOutput(snapshot));
  }
  for (const next of [snapshot.slice(0, -50), 'prepended\n' + snapshot, snapshot.slice(180), snapshot]) {
    assert.equal(reader.update(next), fullReadableOutput(next));
  }
  for (const next of ['prepended\n' + snapshot, snapshot.slice(180), 'different session\n', snapshot]) {
    assert.equal(reader.update(next, { reset: true }), fullReadableOutput(next));
  }
});

test('REA-1194 native prefix comparisons retain exact UTF16 boundaries', () => {
  const start = 'a'.repeat(4095) + '🙂é';
  assert.equal(commonPrefixLength(start + 'left', start + 'right'), start.length);
  assert.equal(commonPrefixLength(start, start + 'tail'), start.length);
  assert.equal(commonPrefixLength('abc', 'ab'), 2);
});

test('REA-1194 exact prefixes handle long middle edits, truncation and prepend', () => {
  const text = '0123456789abcdef'.repeat(25_000);
  assert.equal(commonPrefixLength('', text), 0);
  assert.equal(commonPrefixLength(text, ''), 0);
  assert.equal(commonPrefixLength(text, text), text.length);
  assert.equal(commonPrefixLength(text, text + '#'), text.length);
  assert.equal(commonPrefixLength('#' + text, text), 0);
  assert.equal(commonPrefixLength(text, text.slice(1)), 0);
  for (const at of [0, 1, 2, 7, 8, 255, 256, 257, 4095, 4096, 4097, 17_123,
    65_535, 65_536, 65_537, 123_457, 131_071, 131_072, 199_999, 262_143, 262_144, 399_999]) {
    const changed = text.slice(0, at) + '#' + text.slice(at + 1);
    assert.equal(commonPrefixLength(text, changed), at);
    assert.equal(commonPrefixLength(changed, text), at);
    assert.equal(commonPrefixLength(text, text.slice(0, at)), at);
    assert.equal(commonPrefixLength(text.slice(0, at), text), at);
  }
});

test('REA-1194 prefix boundaries match an independent scalar UTF16 oracle', () => {
  const scalar = (left, right) => {
    let at = 0;
    while (at < left.length && at < right.length && left.charCodeAt(at) === right.charCodeAt(at)) at++;
    return at;
  };
  for (const boundary of [1, 2, 3, 4, 7, 8, 15, 16, 255, 256, 4095, 4096,
    65_535, 65_536, 262_143, 262_144]) {
    const prefix = 'x'.repeat(boundary - 1);
    for (const [left, right] of [['', ''], ['a', 'ab'], ['\ud83d\ude00', '\ud83d\ude03'],
      ['e\u0301', 'e\u0300'], ['\ud83d', '\ud83dx'], ['\ude00x', '\ude00y'],
      ['👩‍💻', '👩‍🔧'], ['क्‍ष', 'क्‍त']]) {
      const a = prefix + left, b = prefix + right;
      const expected = scalar(a, b);
      assert.equal(commonPrefixLength(a, b), expected);
      assert.equal(commonPrefixLength(b, a), expected);
    }
  }
});

test('REA-1194 retained states equal full formatting across generated rewrites and chrome boundaries', () => {
  const reader = createReadableOutput();
  const rows = ['', ' ', '│', '┌──┐', '| ─ ─ ─ ─ ─ |', '9:46 AM', '⠋', '⣿ GPU utilization',
    '│  This paragraph has at least five words', '│  a continuation without punctuation', 'result.',
    '    SELECT data FROM table', '🙂 é 👩‍💻 क्‍ष', '❯ unsent draft', 'Grok 4.6', 'Shift+Tab:mode | Ctrl+x:shortcuts'];
  let seed = 1194, snapshot = '';
  const next = max => { seed = (Math.imul(seed, 1664525) + 1013904223) >>> 0; return seed % max; };
  for (let step = 0; step < 1200; step++) {
    const at = next(snapshot.length + 1), inserted = rows[next(rows.length)] + '\n';
    snapshot = step % 5 ? snapshot.slice(0, at) + inserted + snapshot.slice(at) : snapshot.slice(0, at);
    assert.equal(reader.update(snapshot), fullReadableOutput(snapshot), `rewrite ${step}`);
  }
});

test('REA-1194 a long reflowing paragraph retains bounded mutable checkpoints and replays older edits', () => {
  const reader = createReadableOutput();
  const text = '│  This paragraph starts with enough words\n' + '│  a continuation with many more words\n'.repeat(2200);
  assert.equal(reader.update(text), fullReadableOutput(text));
  assert.ok(reader.retainedCheckpointCount <= 4);
  const changed = text.slice(0, 20_000) + '\nNew paragraph.\n' + text.slice(20_000);
  assert.equal(reader.update(changed), fullReadableOutput(changed));
  assert.equal(reader.update(text), fullReadableOutput(text));
  assert.ok(reader.retainedCheckpointCount <= 4);
});

const footer = '\n' + '─'.repeat(70) + '\n│ ❯ Build anything\n                 Grok 4.6\n(xhigh) · always-approve\n\n→:expand | Ctrl+e:collapse thinking | Ctrl+x:shortcuts';

test('removes the idle desktop composer and screen padding from the phone reader', () => {
  assert.equal(readableOutput('\n\n└\n┘\n' + '\n'.repeat(25) + footer), '');
  assert.equal(readableOutput('Finished the mobile layout.\n\n' + footer), 'Finished the mobile layout.');
});

test('retains real output, code indentation, and unknown terminal prompts', () => {
  const text = 'Result\n\n  if (ready) {\n    send();\n  }\n\nPermission required: approve?';
  assert.equal(readableOutput(text), text);
  const nested = 'root:\n         nested: value';
  assert.equal(readableOutput(nested), nested);
  assert.equal(readableOutput('Do not remove Ctrl+x:shortcuts from this example.'), 'Do not remove Ctrl+x:shortcuts from this example.');
  assert.equal(readableOutput('─'.repeat(70) + '\n❯ My unsent Mac draft\nCtrl+e:collapse thinking | Ctrl+x:shortcuts'), '─'.repeat(70) + '\n❯ My unsent Mac draft\nCtrl+e:collapse thinking | Ctrl+x:shortcuts');
});

test('keeps content after a footer and only simplifies the final idle composer', () => {
  assert.equal(
    readableOutput('Example' + footer + '\nImportant result'),
    'Example' + footer + '\nImportant result',
  );
});


test('recognizes a wide-screen composer without mistaking a result for chrome', () => {
  const wide = footer.replace('Build anything\n                 Grok', 'Build anything                 Grok');
  assert.equal(readableOutput('Result\n' + wide), 'Result');
  const withResult = footer.replace('Grok 4.6', 'Important result\nGrok 4.6');
  assert.equal(
    readableOutput('Result' + withResult),
    'Result' + withResult,
  );
});

const liveFooter = [
  '█',
  '',
  '         ∴ Thinking... 2.7s',
  '3m28s ↓328k [stop]',
  '',
  '─'.repeat(40),
  '─'.repeat(40),
  '─'.repeat(40),
  '  | >',
  'Grok 4.6 (xhigh) · always-approve',
  '  Shift+Tab:mode | Esc:cancel |',
  'Ctrl+x:shortcuts',
].join('\n');

test('strips the live Grok 4.6 phone composer and space-padded TUI rows', () => {
  const padded = Array.from({ length: 18 }, () => ' '.repeat(120)).join('\n') + '\n' + liveFooter;
  assert.equal(readableOutput(padded), '');
  assert.equal(readableOutput('Finished the layout.\n\n' + liveFooter), 'Finished the layout.');
});

test('keeps a typed Mac draft in the new composer', () => {
  const draft = '─'.repeat(40) + '\n  | > look at this screenshot\nGrok 4.6 (xhigh) · always-approve\nShift+Tab:mode | Esc:cancel |\nCtrl+x:shortcuts';
  assert.equal(readableOutput(draft), draft.replaceAll(/[ \t]+$/gm, ''));
});

const boxed = [
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

test('strips a boxed Grok 4.6 composer while a turn is waiting', () => {
  assert.equal(readableOutput(boxed), '> Testing 123');
});

test('keeps a trailing table box and does not treat Grok in a sentence as chrome', () => {
  const table = 'Table:\n┌────┐\n│ data │\n└────┘';
  assert.equal(readableOutput(table), table);
  const about = 'Grok 4.6 is the newest model.\n\n' + boxed.slice(boxed.indexOf('┌'));
  assert.equal(readableOutput(about), 'Grok 4.6 is the newest model.');
});

test('still strips a boxed composer after a greater-than in the last result line', () => {
  const text = 'comparison: x > y\n\n' + boxed.slice(boxed.indexOf('┌'));
  assert.equal(readableOutput(text), 'comparison: x > y');
});

test('does not reflow code, a lone clock, or indented SQL', () => {
  assert.equal(readableOutput('const first = 1\ncontinue'), 'const first = 1\ncontinue');
  assert.equal(readableOutput('9:46 AM'), '9:46 AM');
  assert.equal(
    readableOutput('    SELECT first column FROM table'),
    '    SELECT first column FROM table',
  );
});

test('phone transcript is the messages, not TUI chrome or wrap artifacts', () => {
  const raw = [
    '          That stopped check was the hung',
    'run I killed. The later full check',
    'already     9:46 AM',
    '          passed, and the connect fix is',
    'live.',
    '',
    '        ◆ stop  [hooks: 1/2]',
    '',
    '      Worked for 23s',
    '',
    '        ◆ user_prompt_submit  [hooks: 1/2]',
    '        ◆ Thought for 1.5s',
    '',
    '      Same as the last one: a hung check',
    'I already stopped. Ignore it.',
    '9:46 AM',
  ].join('\n');
  assert.equal(
    readableOutput(raw),
    'That stopped check was the hung run I killed. The later full check already passed, and the connect fix is live.\n\nSame as the last one: a hung check\nI already stopped. Ignore it.',
  );
});

const iphoneSafariDump = [
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

test('strips the live iPhone idle composer that shows - grok instead of Build anything', () => {
  assert.equal(
    readableOutput(iphoneSafariDump),
    [
      '1. Delete the Sidereal icon.',
      '',
      '2. Open Safari. It should still say Connected.',
      '',
      '3. Share → Add to Home Screen.',
      '',
      '4. If iPhone shows Open as Web App, turn that off.',
    ].join('\n'),
  );
  assert.equal(
    readableOutput('Finished the layout.\n\n│  | > - grok\nGrok 4.6 (xhigh) · always-approve\nShift+Tab:mode | Ctrl+x:shortcuts'),
    'Finished the layout.',
  );
});

test('keeps a transcript line that is only - grok before the idle composer', () => {
  const raw = [
    'The process name is',
    '- grok',
    `╭${'─'.repeat(62)}╮`,
    '│  | >                                                         │',
    `╰${'─'.repeat(62)}╯`,
    ' Grok 4.6 (xhigh) · always-approve',
    ' Shift+Tab:mode | Ctrl+x:shortcuts',
  ].join('\n');
  assert.equal(readableOutput(raw), 'The process name is\n- grok');
});

const liveIphoneTranscript = [
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

test('live iPhone transcript is the messages, not hooks, pipes, or wrap breaks', () => {
  assert.equal(
    readableOutput(liveIphoneTranscript),
    [
      '🙋 NEED YOU — Close the Safari tab on the phone, then open remote.sigilapp.dev again.',
      'The boxed Grok footer is stripped on the live host. Safari on iPhone keeps the old page until that tab is gone.',
      '',
      '> Done',
      '',
      '✅ DONE — That was the last step. You should see the four steps, not the boxed Grok footer.',
    ].join('\n'),
  );
});

test('keeps real sentences, tables, commands, and trailing pipes that are not TUI chrome', () => {
  assert.equal(
    readableOutput('The task completed in 2 seconds.\n◆ my actual note'),
    'The task completed in 2 seconds.\n◆ my actual note',
  );
  assert.equal(
    readableOutput('Table:\n│ Name | Status | Owner │\n│ data │'),
    'Table:\n│ Name | Status | Owner │\n│ data │',
  );
  assert.equal(
    readableOutput('│  Hello from the phone.                                                       │'),
    'Hello from the phone.',
  );
  assert.equal(
    readableOutput('│  npm test --test-name-pattern live  │\n│  git status --short --branch  │'),
    'npm test --test-name-pattern live\ngit status --short --branch',
  );
  assert.equal(
    readableOutput('Build finished  7:24 PM |'),
    'Build finished  7:24 PM |',
  );
});

test('strips TUI tree gutters so phone code is not a column of pipes', () => {
  const tree = [
    '|     1 const CACHE = \'sidereal-shell-v7\';',
    '|',
    '|     2 const SHELL = [\'/\', \'/app.mjs\'];',
    '|          pre_tool_use',
  ].join('\n');
  assert.equal(
    readableOutput(tree),
    "1 const CACHE = 'sidereal-shell-v7';\n\n2 const SHELL = ['/', '/app.mjs'];\npre_tool_use",
  );
  const table = 'Table:\n┌────┐\n│ data │\n└────┘';
  assert.equal(readableOutput(table), table);
  assert.equal(readableOutput('| "idle"\n| grep needle'), '| "idle"\n| grep needle');
});

test('strips the live iPhone working dump: braille tofu, gutters, and thinking footer', () => {
  const dump = [
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
  assert.equal(
    readableOutput(dump),
    [
      '...',
      'icons.',
      '• Folder and recent chats stay right where they are.',
      '• When Grok Build is chosen, the model picker and effort slider drop in below it—nothing fancy, just two simple rows.',
    ].join('\n'),
  );
});

test('strips braille spinners prefixed onto thinking and status rows', () => {
  const dump = [
    'Hello from the phone.',
    '⠹ Thinking… 16s',
    '⣾ 5m42s ↓130k [stop]',
    '█',
    '\uFFFD',
  ].join('\n');
  assert.equal(readableOutput(dump), 'Hello from the phone.');
});

test('unwraps a one-space unicode gutter and a short padded TUI row', () => {
  assert.equal(readableOutput('│ • Folder and recent chats stay right where they are.'), '• Folder and recent chats stay right where they are.');
  assert.equal(
    readableOutput('│  icons.                                                                 │'),
    'icons.',
  );
});

test('keeps padded single-column table cells', () => {
  const table = 'Table:\n┌────────┐\n│ OK     │\n└────────┘';
  assert.equal(readableOutput(table), table);
});

test('keeps list and status markers that are not spinner chrome', () => {
  assert.equal(readableOutput('● passed'), '● passed');
  assert.equal(readableOutput('○ pending\n■ blocked\n▪ queued'), '○ pending\n■ blocked\n▪ queued');
  assert.equal(readableOutput('⣿ GPU utilization'), '⣿ GPU utilization');
});

test('keeps content rows that start with Run or Stop after a pipe or bullet', () => {
  const table = '| Action | Command |\n| Run tests | npm test |\n| Stop server | Ctrl+C |';
  assert.equal(readableOutput(table), table);
  assert.equal(readableOutput('│ Run tests │ npm test │'), '│ Run tests │ npm test │');
  assert.equal(readableOutput('● Run the migration before you deploy.'), '● Run the migration before you deploy.');
  assert.equal(readableOutput('10 ↓ rows were dropped'), '10 ↓ rows were dropped');
});

test('keeps documentation that mentions a stop control', () => {
  assert.equal(
    readableOutput('Use the ↓ control labeled [stop]'),
    'Use the ↓ control labeled [stop]',
  );
});

const liveNewChatDump = [
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

test('strips a live new-chat iPhone dump: tofu, gutters, thinking, truncated composer', () => {
  assert.equal(
    readableOutput(liveNewChatDump),
    'The text on the left side should now align properly without indentation.',
  );
  assert.equal(
    readableOutput(liveNewChatDump.replaceAll('⠹', '■')),
    'The text on the left side should now align properly without indentation.',
  );
});

test('joins wraps when the spinner shares a row with an empty gutter', () => {
  assert.equal(
    readableOutput([
      '⠹ │  The text on the left side should now',
      '⠹ │',
      '⠹ │  align properly without indentation.',
    ].join('\n')),
    'The text on the left side should now align properly without indentation.',
  );
});

test('empty pipe gutters still separate bullets', () => {
  assert.equal(
    readableOutput([
      '|  • First bullet with enough words here',
      '|',
      '|  • Second bullet with enough words too',
    ].join('\n')),
    '• First bullet with enough words here\n\n• Second bullet with enough words too',
  );
});

test('peels a spinner glued onto a gutter line without dropping GPU status markers', () => {
  assert.equal(
    readableOutput('⠹ │  The text on the left side should now align properly without indentation.'),
    'The text on the left side should now align properly without indentation.',
  );
  assert.equal(readableOutput('⣿ GPU utilization'), '⣿ GPU utilization');
});

test('strips a composer whose Ctrl+x hint was truncated by a narrow phone terminal', () => {
  const dump = [
    'Hello from the phone.',
    '╭──────────────────────────────────────╮',
    '│ ❯',
    '│      Grok 4.7 (xhigh) · always-approve',
    '╰──────────────────────────────────────╯',
    'Shift+Tab:mode | Esc:cancel | Ctrl+x:',
  ].join('\n');
  assert.equal(readableOutput(dump), 'Hello from the phone.');
});

