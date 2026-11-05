#!/bin/bash
# Run the test binary with the real Sidereal relay on loopback, so the phone's
# pairing, ticket reconnect and sealed commands are proved end to end.
set -euo pipefail

cd "$(dirname "$0")/.."

if [ ! -d ../Sidereal/node_modules/ws ]; then
  (cd ../Sidereal && npm ci --ignore-scripts --omit=dev >/dev/null)
fi

SIGIL_TEST_RELAY_COUNT=1
if [ "${1:-}" = "scripts/native-test.sh" ]; then
  # Partition serial native cases over a bounded pool of fresh relays. Keep
  # per-source limits and five-minute disconnected-room grace unchanged.
  SIGIL_TEST_RELAY_COUNT=8
fi
SIGIL_TEST_RELAY_PORTS=$(python3 - "$SIGIL_TEST_RELAY_COUNT" <<'PY'
import socket, sys
sockets = []
for _ in range(int(sys.argv[1])):
    item = socket.socket()
    item.bind(("127.0.0.1", 0))
    sockets.append(item)
print(",".join(str(item.getsockname()[1]) for item in sockets))
for item in sockets:
    item.close()
PY
)
PORT=${SIGIL_TEST_RELAY_PORTS%%,*}
(cd ../Sidereal && exec node --input-type=module -e "
  import { createRelay } from './server.mjs';
  const relays = '$SIGIL_TEST_RELAY_PORTS'.split(',').map(port => {
    const relay = createRelay({ publicOrigin: 'http://localhost:' + port });
    relay.server.listen(Number(port), '127.0.0.1');
    return relay;
  });
  process.on('SIGTERM', () => { for (const relay of relays) relay.close(); process.exit(0); });
") &
RELAY=$!
trap 'kill $RELAY 2>/dev/null || true' EXIT

IFS=, read -r -a SIGIL_TEST_PORT_LIST <<< "$SIGIL_TEST_RELAY_PORTS"
for SIGIL_TEST_PORT in "${SIGIL_TEST_PORT_LIST[@]}"; do
  for _ in $(seq 1 50); do
    curl -fsS "http://127.0.0.1:$SIGIL_TEST_PORT/health" >/dev/null 2>&1 && break
    sleep 0.1
  done
  curl -fsS "http://127.0.0.1:$SIGIL_TEST_PORT/health" >/dev/null
done

if [ "$#" -gt 0 ]; then
  SIGIL_RELAY_PORT=$PORT SIGIL_RELAY_PORTS=$SIGIL_TEST_RELAY_PORTS "$@"
else
  SIGIL_RELAY_PORT=$PORT bash scripts/test.sh
fi
