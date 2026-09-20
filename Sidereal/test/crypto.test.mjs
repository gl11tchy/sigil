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


test('sealing identical plaintext uses a fresh nonce and produces distinct frames', async () => {
  const key = await importKey(randomKey());
  const payload = { challenge: 'fresh', sequence: 1, action: 'state' };
  const first = await seal(payload, key, 'phone');
  const second = await seal(payload, key, 'phone');
  assert.notEqual(first, second);
  assert.notDeepEqual(Buffer.from(first, 'base64').subarray(0, 12), Buffer.from(second, 'base64').subarray(0, 12));
  assert.deepEqual(await open(first, key, 'phone'), payload);
  assert.deepEqual(await open(second, key, 'phone'), payload);
});

test('plaintext limits apply on both seal and open, including UTF-8 bytes', async () => {
  const key = await importKey(randomKey());
  const boundary = 'a'.repeat(65534); // JSON quotes occupy two bytes.
  assert.equal(await open(await seal(boundary, key, 'phone'), key, 'phone'), boundary);
  await assert.rejects(seal(boundary + 'a', key, 'phone'), /Message too large/);
  await assert.rejects(seal('é'.repeat(32768), key, 'phone'), /Message too large/);
  // Bypass seal's size check to prove the receiving boundary independently.
  const iv = crypto.getRandomValues(new Uint8Array(12));
  const cipher = await crypto.subtle.encrypt({ name: 'AES-GCM', iv,
    additionalData: new TextEncoder().encode('sigil-remote-v1:phone'), tagLength: 128 },
    key, new TextEncoder().encode(JSON.stringify(boundary + 'a')));
  const oversized = Buffer.concat([Buffer.from(iv), Buffer.from(cipher)]).toString('base64');
  assert.ok(oversized.length < 100000);
  await assert.rejects(open(oversized, key, 'phone'), /Message too large/);
});

test('oversized and malformed frames are rejected', async () => {
  const key = await importKey(randomKey());
  await assert.rejects(open('a'.repeat(100001), key, 'phone'), /Invalid message/);
  for (const frame of [null, {}, '', 'not base64!', Buffer.alloc(27).toString('base64')]) {
    await assert.rejects(open(frame, key, 'phone'));
  }
});
