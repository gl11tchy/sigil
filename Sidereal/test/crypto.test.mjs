import test from 'node:test';
import assert from 'node:assert/strict';
import { seal, open, importKey, randomKey } from '../public/crypto.mjs';

test('AES-GCM round trip rejects tampering, wrong key and reflection', async () => {
  const key = await importKey(randomKey());
  const payload = { challenge: 'fresh', sequence: 1, action: 'state' };
  const frame = await seal(payload, key, 'phone');
  assert.deepEqual(await open(frame, key, 'phone'), payload);
  await assert.rejects(open(frame, key, 'mac'));
  await assert.rejects(open(frame, await importKey(randomKey()), 'phone'));
  const tampered = Buffer.from(frame, 'base64');
  tampered[20] ^= 1;
  await assert.rejects(open(tampered.toString('base64'), key, 'phone'));
  assert.equal(key.extractable, false);
});
