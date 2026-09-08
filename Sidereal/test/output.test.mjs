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
  assert.equal(readableOutput('Do not remove Ctrl+x:shortcuts from this example.'), 'Do not remove Ctrl+x:shortcuts from this example.');
  assert.equal(readableOutput('─'.repeat(70) + '\n❯ My unsent Mac draft\nCtrl+e:collapse thinking | Ctrl+x:shortcuts'), '─'.repeat(70) + '\n❯ My unsent Mac draft\nCtrl+e:collapse thinking | Ctrl+x:shortcuts');
});

test('keeps content after a footer and only simplifies the final idle composer', () => {
  assert.equal(readableOutput('Example' + footer + '\nImportant result'), 'Example' + footer + '\nImportant result');
});


test('recognizes a wide-screen composer without mistaking a result for chrome', () => {
  const wide = footer.replace('Build anything\n                 Grok', 'Build anything                 Grok');
  assert.equal(readableOutput('Result\n' + wide), 'Result');
  const withResult = footer.replace('Grok 4.6', 'Important result\nGrok 4.6');
  assert.equal(readableOutput('Result' + withResult), 'Result' + withResult);
});
