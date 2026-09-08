// Native integration fixture. It binds only loopback and writes no credentials.
import { writeFileSync } from 'node:fs';
import { createRelay } from '../server.mjs';
const relay = createRelay({ publicOrigin: 'http://localhost:3099' });
relay.server.listen(0, '127.0.0.1', () => {
  writeFileSync(process.env.SIGIL_TEST_PORT_FILE, String(relay.server.address().port), { mode: 0o600 });
});
process.on('SIGTERM', () => relay.close());
