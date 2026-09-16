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
    'Example' + footer.replace('│ ❯ Build anything', '❯ Build anything') + '\nImportant result',
  );
});


test('recognizes a wide-screen composer without mistaking a result for chrome', () => {
  const wide = footer.replace('Build anything\n                 Grok', 'Build anything                 Grok');
  assert.equal(readableOutput('Result\n' + wide), 'Result');
  const withResult = footer.replace('Grok 4.6', 'Important result\nGrok 4.6');
  assert.equal(
    readableOutput('Result' + withResult),
    'Result' + withResult.replace('│ ❯ Build anything', '❯ Build anything'),
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
  assert.equal(readableOutput(padded), '∴ Thinking... 2.7s\n3m28s ↓328k [stop]');
  assert.equal(
    readableOutput('Finished the layout.\n\n' + liveFooter),
    'Finished the layout.\n\n         ∴ Thinking... 2.7s\n3m28s ↓328k [stop]',
  );
});

test('keeps a typed Mac draft in the new composer', () => {
  const draft = '─'.repeat(40) + '\n  | > look at this screenshot\nGrok 4.6 (xhigh) · always-approve\nShift+Tab:mode | Esc:cancel |\nCtrl+x:shortcuts';
  assert.equal(
    readableOutput(draft),
    draft.replaceAll(/[ \t]+$/gm, '').replace('  | > look at this screenshot', '> look at this screenshot'),
  );
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
  assert.equal(
    readableOutput(boxed),
    '> Testing 123\n6:56 PM\n\n♦ user_prompt_submit  [hooks: 1/2]\n\n: Waiting for response... 9.9s\n9.9s ↓318k [stop]',
  );
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
});

