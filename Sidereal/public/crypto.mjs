const encoder = new TextEncoder();
export function randomKey() {
  return [...crypto.getRandomValues(new Uint8Array(32))].map(x => x.toString(16).padStart(2, '0')).join('');
}
export async function importKey(hex) {
  if (!/^[a-f0-9]{64}$/.test(hex)) throw new Error('Invalid pairing key');
  const bytes = Uint8Array.from(hex.match(/../g), x => parseInt(x, 16));
  return crypto.subtle.importKey('raw', bytes, 'AES-GCM', false, ['encrypt', 'decrypt']);
}
export async function seal(value, key, direction) {
  const plaintext = encoder.encode(JSON.stringify(value));
  if (plaintext.length > 65536) throw new Error('Message too large');
  const iv = crypto.getRandomValues(new Uint8Array(12));
  const data = new Uint8Array(await crypto.subtle.encrypt({ name: 'AES-GCM', iv,
    additionalData: encoder.encode(`sigil-remote-v1:${direction}`), tagLength: 128 }, key, plaintext));
  const combined = new Uint8Array(iv.length + data.length);
  combined.set(iv); combined.set(data, iv.length);
  // Avoid spreading large payloads onto the JS call stack.
  return btoa(Array.from(combined, byte => String.fromCharCode(byte)).join(''));
}
export async function open(frame, key, direction) {
  if (typeof frame !== 'string' || frame.length > 100000) throw new Error('Invalid message');
  const bytes = Uint8Array.from(atob(frame), x => x.charCodeAt(0));
  const plain = await crypto.subtle.decrypt({ name: 'AES-GCM', iv: bytes.slice(0, 12),
    additionalData: encoder.encode(`sigil-remote-v1:${direction}`), tagLength: 128 }, key, bytes.slice(12));
  if (plain.byteLength > 65536) throw new Error('Message too large');
  return JSON.parse(new TextDecoder().decode(plain));
}
