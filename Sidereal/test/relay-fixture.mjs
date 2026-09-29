// Native integration fixture. It binds only loopback and writes no credentials.
import { writeFileSync, appendFileSync } from 'node:fs';
import { createRelay } from '../server.mjs';
// With SIGIL_TEST_APNS_CAPTURE set, pushes are appended there as JSON lines instead of going to Apple.
const capture = process.env.SIGIL_TEST_APNS_CAPTURE;
const apns = capture
  ? { async send(request) { appendFileSync(capture, `${JSON.stringify(request)}\n`); return { status: 200 }; }, close() {} }
  : null;
const relay = createRelay({ publicOrigin: 'http://localhost:3099', apns });
relay.server.listen(0, '127.0.0.1', () => {
  writeFileSync(process.env.SIGIL_TEST_PORT_FILE, String(relay.server.address().port), { mode: 0o600 });
});
process.on('SIGTERM', () => relay.close());
