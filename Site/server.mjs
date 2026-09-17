import http from 'node:http';
import { readFile } from 'node:fs/promises';
import { pathToFileURL } from 'node:url';

const assets = new Map([
  ['/', ['index.html', 'text/html']],
  ['/docs', ['docs/index.html', 'text/html']],
  ['/docs/', ['docs/index.html', 'text/html']],
  ['/style.css', ['style.css', 'text/css']],
  ['/icon.svg', ['icon.svg', 'image/svg+xml']],
  ['/screenshot.png', ['screenshot.png', 'image/png']],
]);

export function createSite({ publicOrigin } = {}) {
  const origin = new URL(publicOrigin);
  if (origin.origin !== publicOrigin || !(origin.protocol === 'https:' ||
      (origin.protocol === 'http:' && ['localhost', '127.0.0.1'].includes(origin.hostname)))) {
    throw new Error('PUBLIC_ORIGIN must be an HTTPS origin (HTTP is allowed only on loopback).');
  }
  const server = http.createServer(async (req, res) => {
    res.setHeader('Content-Security-Policy', "default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self'; connect-src 'none'; object-src 'none'; base-uri 'none'; frame-ancestors 'none'; form-action 'none'");
    res.setHeader('Referrer-Policy', 'no-referrer');
    res.setHeader('X-Content-Type-Options', 'nosniff');
    res.setHeader('X-Frame-Options', 'DENY');
    res.setHeader('Cache-Control', 'no-store');
    if (origin.protocol === 'https:') res.setHeader('Strict-Transport-Security', 'max-age=31536000');
    if (!req.url || req.url.length > 2048) { res.writeHead(404).end(); return; }
    if (req.url === '/health' && req.method === 'GET') { res.end('ok'); return; }
    const asset = req.method === 'GET' && assets.get(req.url);
    if (!asset) { res.writeHead(404).end(); return; }
    try {
      const data = await readFile(new URL(`public/${asset[0]}`, import.meta.url));
      const type = asset[1].startsWith('text/') || asset[1] === 'image/svg+xml'
        ? `${asset[1]}; charset=utf-8` : asset[1];
      res.writeHead(200, { 'Content-Type': type, 'Content-Length': data.byteLength }).end(data);
    } catch { res.writeHead(500).end(); }
  });
  server.requestTimeout = 10000;
  server.headersTimeout = 10000;
  server.maxConnections = 300;
  return { server, close() {
    server.close();
    server.closeAllConnections();
  } };
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const site = createSite({ publicOrigin: process.env.PUBLIC_ORIGIN });
  site.server.listen(Number(process.env.PORT || 3000), '0.0.0.0');
  process.on('SIGTERM', () => site.close());
  process.on('SIGINT', () => site.close());
}
