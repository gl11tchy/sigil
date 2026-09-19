const ROOM = /^[a-f0-9]{32}$/;
const KEY = /^[a-f0-9]{64}$/;

function fragmentSecrets(url) {
  const fragment = new URLSearchParams(url.hash.startsWith('#') ? url.hash.slice(1) : url.hash);
  const room = fragment.get('room');
  const key = fragment.get('key');
  if (!ROOM.test(room || '') || !KEY.test(key || '')) return null;
  return { room, key };
}

export function pairingFromText(text, origin) {
  const raw = String(text ?? '').trim();
  if (!raw) return null;
  const expected = new URL(origin).origin;
  const absolute = /^[a-z][a-z0-9+.-]*:/i.test(raw);
  let url;
  try {
    url = absolute ? new URL(raw) : new URL(raw.startsWith('#') ? raw : `#${raw}`, expected);
  } catch {
    return null;
  }
  const secrets = fragmentSecrets(url);
  if (absolute) {
    if (url.protocol !== 'http:' && url.protocol !== 'https:') return null;
    if (url.origin !== expected) {
      return secrets ? { error: 'This code is for a different Sidereal address.' } : null;
    }
  }
  return secrets;
}
