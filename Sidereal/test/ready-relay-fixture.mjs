// CI-only proxy around the real relay. All traffic is loopback; APNs is a local capture.
import http from 'node:http';
import { appendFileSync, existsSync, writeFileSync } from 'node:fs';
import WebSocket, { WebSocketServer } from 'ws';
import { createRelay } from '../server.mjs';

const trace = value => appendFileSync(process.env.SIGIL_TEST_TRACE, `${JSON.stringify(value)}\n`);
const relay = createRelay({
  publicOrigin: 'http://localhost:3099',
  apns: {
    async send(request) {
      appendFileSync(process.env.SIGIL_TEST_APNS_CAPTURE, `${JSON.stringify(request)}\n`);
      return { status: 200 };
    },
    close() {},
  },
});
await new Promise(resolve => relay.server.listen(0, '127.0.0.1', resolve));
const innerPort = relay.server.address().port;
let allocations = 0;
const proxy = http.createServer((req, res) => {
  if (req.method === 'POST' && req.url === '/rooms') trace({ allocations: ++allocations });
  const forwarded = http.request({
    hostname: '127.0.0.1', port: innerPort, path: req.url, method: req.method, headers: req.headers,
  }, reply => { res.writeHead(reply.statusCode, reply.headers); reply.pipe(res); });
  forwarded.on('error', () => { res.writeHead(502); res.end(); });
  req.pipe(forwarded);
});
const sockets = new WebSocketServer({ noServer: true });
let hostConnections = 0;
proxy.on('upgrade', (req, socket, head) => sockets.handleUpgrade(req, socket, head, client => {
  const hostIndex = req.url.includes('role=host') ? ++hostConnections : 0;
  const backend = new WebSocket(`ws://127.0.0.1:${innerPort}${req.url}`, {
    headers: {
      ...(req.headers.authorization ? { authorization: req.headers.authorization } : {}),
      ...(req.headers.origin ? { origin: req.headers.origin } : {}),
    },
  });
  const outbound = [];
  let route;
  let forwardedRoute = false;
  let completed = false;
  const deliver = message => { if (client.readyState === WebSocket.OPEN) client.send(message.data, { binary: message.binary }); };
  const release = () => {
    if (hostIndex === 1 && existsSync(process.env.SIGIL_TEST_DROP_HOST)) {
      backend.terminate(); client.terminate(); return;
    }
    if (!route || !existsSync(process.env.SIGIL_TEST_ROUTE_RELEASE)) return;
    deliver(route);
    route = undefined;
    forwardedRoute = true;
  };
  const timer = setInterval(release, 10);
  timer.unref();
  backend.on('open', () => { for (const message of outbound.splice(0)) backend.send(message.data, { binary: message.binary }); });
  client.on('message', (data, binary) => {
    let value;
    try { value = JSON.parse(data.toString()); } catch { value = {}; }
    trace({ fromMac: value.route ? 'route' : value.pushToken ? 'pushToken' : value.push ? 'push' : 'other', beforeRoute: !forwardedRoute });
    if (backend.readyState === WebSocket.OPEN) backend.send(data, { binary }); else outbound.push({ data, binary });
  });
  backend.on('message', (data, binary) => {
    let value;
    try { value = JSON.parse(data.toString()); } catch { value = {}; }
    if (value.route && req.url.includes('role=host') && !existsSync(process.env.SIGIL_TEST_ROUTE_RELEASE)) {
      route = { data, binary };
      trace({ heldHostRoute: true });
      release();
    } else {
      if (value.route) forwardedRoute = true;
      deliver({ data, binary });
    }
  });
  backend.on('close', code => {
    trace({ backendClose: code });
    completed = true;
    clearInterval(timer);
    if (client.readyState === WebSocket.OPEN) client.close(code === 1005 || code === 1006 ? 1011 : code);
  });
  client.on('close', () => { clearInterval(timer); if (!completed) backend.terminate(); });
  client.on('error', () => {});
  backend.on('error', () => {});
}));
proxy.listen(0, '127.0.0.1', () => {
  writeFileSync(process.env.SIGIL_TEST_PORT_FILE, String(proxy.address().port), { mode: 0o600 });
});
process.on('SIGTERM', () => {
  for (const socket of sockets.clients) socket.terminate();
  sockets.close(); proxy.close(); proxy.closeAllConnections(); relay.close();
});
