// Native integration fixture. It binds only loopback and writes no credentials.
import { writeFileSync, appendFileSync, readFileSync } from 'node:fs';
import { createRelay } from '../server.mjs';
// With SIGIL_TEST_APNS_CAPTURE set, pushes are appended there as JSON lines instead of going to Apple.
const capture = process.env.SIGIL_TEST_APNS_CAPTURE;
const apns = capture
  ? { async send(request) { appendFileSync(capture, `${JSON.stringify(request)}\n`); return { status: 200 }; }, close() {} }
  : null;
const relay = createRelay({ publicOrigin: 'http://localhost:3099', apns });
// A native test can wait for the old host transport to close without sleeps or
// inspecting processes. Record only a count marker, never headers or tickets.
if (process.env.SIGIL_TEST_HOST_CLOSE_CAPTURE) relay.server.prependListener('upgrade', (req, socket) => {
  if (new URL(req.url, 'http://localhost').searchParams.get('role') !== 'host') return;
  socket.once('close', () => appendFileSync(process.env.SIGIL_TEST_HOST_CLOSE_CAPTURE, 'closed\n', { mode: 0o600 }));
});
// Native tests can deny allocation and later restore this same generated relay.
// This is a fixture-only file, not a production environment setting.
if (process.env.SIGIL_TEST_ALLOCATION_STATUS) {
  const handler = relay.server.listeners('request')[0];
  relay.server.removeListener('request', handler);
  relay.server.on('request', (req, res) => {
    const status = Number(readFileSync(process.env.SIGIL_TEST_ALLOCATION_STATUS, 'utf8'));
    if (req.method === 'POST' && req.url === '/rooms' && [429, 503].includes(status)) {
      res.writeHead(status).end(); return;
    }
    return handler(req, res);
  });
}
// Capture only generated room IDs, never host credentials. The native test can
// check the exact collapse namespace after the initial QR room is retired.
if (process.env.SIGIL_TEST_ROOM_CAPTURE) relay.server.prependListener('request', (req, res) => {
  if (req.method !== 'POST' || req.url !== '/rooms') return;
  const end = res.end;
  res.end = function(...args) {
    if (res.statusCode === 201) {
      const { room } = JSON.parse(String(args[0]));
      appendFileSync(process.env.SIGIL_TEST_ROOM_CAPTURE, `${room}\n`, { mode: 0o600 });
    }
    return end.apply(this, args);
  };
});
relay.server.listen(0, '127.0.0.1', () => {
  writeFileSync(process.env.SIGIL_TEST_PORT_FILE, String(relay.server.address().port), { mode: 0o600 });
});
process.on('SIGTERM', () => relay.close());
