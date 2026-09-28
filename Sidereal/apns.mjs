// Apple Push Notification service over HTTP/2 with a token (ES256) key. No
// dependency: Node's http2 and crypto do the whole job. The relay never logs a
// device token or a payload; a failure is a status code and nothing else.
import http2 from 'node:http2';
import { createPrivateKey, sign } from 'node:crypto';

const base64url = value => Buffer.from(value).toString('base64url');

export const APNS_HOSTS = {
  production: 'https://api.push.apple.com',
  development: 'https://api.sandbox.push.apple.com',
};

/**
 * Returns null when any of the four settings is missing: the relay then runs
 * without push, as it did before.
 */
export function createAPNs({ key, keyId, teamId, topic, hosts = APNS_HOSTS, now = Date.now } = {}) {
  if (!key || !keyId || !teamId || !topic) return null;
  const privateKey = createPrivateKey(key.includes('BEGIN') ? key : Buffer.from(key, 'base64').toString('utf8'));
  let jwt = null, issuedAt = 0;
  const sessions = new Map();

  // Apple accepts a token for an hour; refresh a little early and never faster than every 20 minutes.
  function bearer() {
    if (jwt && now() - issuedAt < 50 * 60 * 1000) return jwt;
    const header = base64url(JSON.stringify({ alg: 'ES256', kid: keyId }));
    const claims = base64url(JSON.stringify({ iss: teamId, iat: Math.floor(now() / 1000) }));
    const signature = sign('sha256', Buffer.from(`${header}.${claims}`), { key: privateKey, dsaEncoding: 'ieee-p1363' });
    jwt = `${header}.${claims}.${signature.toString('base64url')}`;
    issuedAt = now();
    return jwt;
  }

  function session(host) {
    const open = sessions.get(host);
    if (open && !open.closed && !open.destroyed) return open;
    const next = http2.connect(host);
    next.on('error', () => {});
    next.on('close', () => { if (sessions.get(host) === next) sessions.delete(host); });
    sessions.set(host, next);
    return next;
  }

  /**
   * One push. Resolves to `{ status, reason }`; rejects only when the connection fails.
   * `pushType` is `alert` or `liveactivity`; the latter uses Apple's topic suffix.
   */
  function send({ environment, token, payload, pushType, priority = 10, collapseId, expiration = 0 }) {
    const host = hosts[environment] || hosts.production;
    const headers = {
      ':method': 'POST',
      ':path': `/3/device/${token}`,
      authorization: `bearer ${bearer()}`,
      'apns-topic': pushType === 'liveactivity' ? `${topic}.push-type.liveactivity` : topic,
      'apns-push-type': pushType,
      'apns-priority': String(priority),
      'apns-expiration': String(expiration),
      'content-type': 'application/json',
    };
    if (collapseId) headers['apns-collapse-id'] = collapseId;
    return new Promise((resolve, reject) => {
      let request;
      try { request = session(host).request(headers); } catch (error) { reject(error); return; }
      let status = 0, body = '';
      request.setEncoding('utf8');
      request.setTimeout(10000, () => request.close(http2.constants.NGHTTP2_CANCEL));
      request.on('response', received => { status = Number(received[':status']) || 0; });
      request.on('data', chunk => { if (body.length < 512) body += chunk; });
      request.on('error', reject);
      request.on('close', () => {
        let reason;
        try { reason = JSON.parse(body).reason; } catch { reason = undefined; }
        resolve({ status, reason });
      });
      request.end(JSON.stringify(payload));
    });
  }

  return {
    send,
    bearer,
    close() { for (const open of sessions.values()) open.close(); sessions.clear(); },
  };
}
