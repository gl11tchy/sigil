import test from 'node:test';
import assert from 'node:assert/strict';
import { pairingFromText } from '../public/pairing.mjs';

const origin = 'https://remote.sigilapp.dev';
const room = 'ab'.repeat(16);
const key = 'cd'.repeat(32);
const fragment = `room=${room}&key=${key}`;
const ok = { room, key };

const rows = [
  ['a full pairing URL', `${origin}/#${fragment}`, origin, ok],
  ['a pairing URL with a path', `${origin}/ignored/#${fragment}`, origin, ok],
  ['a hash only', `#${fragment}`, origin, ok],
  ['room and key without a hash prefix', fragment, origin, ok],
  ['surrounding whitespace', `  ${origin}/#${fragment}  `, origin, ok],
  ['an empty string', '', origin, null],
  ['a bare origin', origin, origin, null],
  ['query-string secrets', `${origin}/?${fragment}`, origin, null],
  ['a short room', `${origin}/#room=${'ab'.repeat(8)}&key=${key}`, origin, null],
  ['uppercase secrets', `${origin}/#room=${room.toUpperCase()}&key=${key}`, origin, null],
  ['a missing key', `${origin}/#room=${room}`, origin, null],
  ['a javascript URL', `javascript:alert(1)#${fragment}`, origin, null],
  ['another https origin with secrets', `https://evil.example/#${fragment}`, origin,
    { error: 'This code is for a different Sidereal address.' }],
  ['http vs https on the same host', `http://remote.sigilapp.dev/#${fragment}`, origin,
    { error: 'This code is for a different Sidereal address.' }],
  ['another origin without secrets', 'https://evil.example/ok', origin, null],
];

for (const [name, input, base, want] of rows) {
  test(name, () => {
    assert.deepEqual(pairingFromText(input, base), want);
  });
}

test('loopback pairing stays on that origin', () => {
  const local = `http://localhost:3099/#${fragment}`;
  assert.deepEqual(pairingFromText(local, 'http://localhost:3099'), ok);
  assert.deepEqual(
    pairingFromText(local, origin),
    { error: 'This code is for a different Sidereal address.' },
  );
});
