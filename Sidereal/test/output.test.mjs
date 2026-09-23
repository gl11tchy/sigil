import test from 'node:test';
import assert from 'node:assert/strict';
import { readableOutput } from '../public/output.mjs';

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

