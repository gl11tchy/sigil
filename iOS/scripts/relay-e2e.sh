#!/bin/bash
# Run the test binary with the real Sidereal relay on loopback, so the phone's
# pairing, ticket reconnect and sealed commands are proved end to end.
set -euo pipefail

cd "$(dirname "$0")/.."

if [ ! -d ../Sidereal/node_modules/ws ]; then
  (cd ../Sidereal && npm ci --ignore-scripts --omit=dev >/dev/null)
fi

PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()')
(cd ../Sidereal && exec node --input-type=module -e "
  import { createRelay } from './server.mjs';
  const relay = createRelay({ publicOrigin: 'http://localhost:$PORT' });
  relay.server.listen($PORT, '127.0.0.1');
  process.on('SIGTERM', () => { relay.close(); process.exit(0); });
") &
RELAY=$!
trap 'kill $RELAY 2>/dev/null || true' EXIT

for _ in $(seq 1 50); do
  curl -fsS "http://127.0.0.1:$PORT/health" >/dev/null 2>&1 && break
  sleep 0.1
done

if [ "$#" -gt 0 ]; then
  SIGIL_RELAY_PORT=$PORT "$@"
else
  SIGIL_RELAY_PORT=$PORT bash scripts/test.sh
fi
