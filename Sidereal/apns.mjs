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
export function createAPNs({ key, keyId, teamId, topic, hosts = APNS_HOSTS, now = Date.now,
  requestTimeoutMs = 10000, totalTimeoutMs = 20000, idleTimeoutMs = 600000 } = {}) {
  if (!key || !keyId || !teamId || !topic) return null;
  for (const [value, maximum] of [[requestTimeoutMs, 10000], [totalTimeoutMs, 20000], [idleTimeoutMs, 600000]]) {
    if (!Number.isFinite(value) || value <= 0 || value > maximum) throw new RangeError('Invalid APNs timeout');
  }
  const privateKey = createPrivateKey(key.includes('BEGIN') ? key : Buffer.from(key, 'base64').toString('utf8'));
  let jwt = null, issuedAt = 0;
  const sessions = new Map();
  const connections = new Set();
  let closed = false;

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

  function retire(entry, destroy = false) {
    if (sessions.get(entry.host) === entry) sessions.delete(entry.host);
    entry.retired = true;
    clearTimeout(entry.idle);
    if (destroy) {
      if (!entry.session.destroyed) entry.session.destroy();
    } else if (!entry.session.closed && !entry.session.destroyed) entry.session.close();
  }

  function idle(entry) {
    clearTimeout(entry.idle);
    if (closed || entry.retired || entry.active) return;
    entry.idle = setTimeout(() => retire(entry), idleTimeoutMs);
    entry.idle.unref();
  }

  function session(host) {
    const open = sessions.get(host);
    if (open && !open.retired && !open.session.closed && !open.session.destroyed) return open;
    const next = http2.connect(host);
    const entry = { host, session: next, active: 0, retired: false, idle: null };
    next.on('error', () => retire(entry, true));
    next.on('goaway', () => retire(entry));
    next.on('close', () => {
      if (sessions.get(host) === entry) sessions.delete(host);
      entry.retired = true;
      clearTimeout(entry.idle);
      connections.delete(entry);
    });
    sessions.set(host, entry);
    connections.add(entry);
    idle(entry);
    return entry;
  }

  /**
   * One logical push, at most two attempts before any response. Resolves to
   * `{ status, reason }`; rejects when closed, expired, invalid or unreachable.
   * `pushType` is `alert` or `liveactivity`; the latter uses Apple's topic suffix.
   */
  async function send({ environment, token, payload, pushType, priority = 10, collapseId, expiration = 0 }) {
    if (closed) throw new Error('APNs closed');
    if (!Number.isSafeInteger(expiration) || expiration < 0) throw new RangeError('Invalid APNs expiration');
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
    // Freeze one intent before attempting transport. A timeout is uncertain;
    // its retry must not create new identity, timestamp, collapse key or expiry.
    const payloadBytes = JSON.stringify(payload);
    const deadline = performance.now() + Math.min(totalTimeoutMs, expiration ? expiration * 1000 - now() : Infinity);
    for (let index = 0; index < 2; index++) {
      const remaining = Math.min(deadline - performance.now(), expiration ? expiration * 1000 - now() : Infinity);
      if (closed || remaining <= 0) throw new Error('APNs unreachable');
      const entry = session(host);
      const result = await attempt(entry, headers, payloadBytes, Math.min(requestTimeoutMs, remaining));
      if (result.responded) return { status: result.status, reason: result.reason };
      // Concurrent failures destroy their own connection, never a replacement.
      retire(entry, true);
    }
    throw new Error('APNs unreachable');
  }

  function attempt(entry, headers, payloadBytes, timeout) {
    return new Promise(resolve => {
      let request;
      let status = 0, body = '', responded = false, finished = false;
      clearTimeout(entry.idle);
      entry.active++;
      const finish = () => {
        if (finished) return;
        finished = true;
        clearTimeout(timer);
        entry.active--;
        idle(entry);
        let reason;
        try { reason = JSON.parse(body).reason; } catch {}
        resolve({ responded, status, reason });
      };
      // Absolute timer bounds connect, response and body waiting, even if traffic
      // keeps resetting HTTP/2's own inactivity timeout.
      const timer = setTimeout(() => {
        request?.close(http2.constants.NGHTTP2_CANCEL);
        finish();
      }, timeout);
      try { request = entry.session.request(headers); } catch { finish(); return; }
      request.setEncoding('utf8');
      const response = received => { responded = true; status = Number(received[':status']) || status; };
      request.on('headers', response);
      request.on('response', response);
      request.on('data', chunk => { if (body.length < 512) body += chunk; });
      request.on('error', finish);
      request.on('close', finish);
      request.end(payloadBytes);
    });
  }

  return {
    send,
    bearer,
    close() {
      closed = true;
      sessions.clear();
      for (const entry of connections) retire(entry, true);
    },
  };
}
