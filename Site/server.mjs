import http from 'node:http';
import { createHash } from 'node:crypto';
import { readFile, stat } from 'node:fs/promises';
import { pathToFileURL } from 'node:url';
import { promisify } from 'node:util';
import { brotliCompress, gzip } from 'node:zlib';

const assets = new Map([
  ['/', ['index.html', 'text/html']],
  ['/docs', ['docs/index.html', 'text/html']],
  ['/docs/', ['docs/index.html', 'text/html']],
  ['/style.css', ['style.css', 'text/css']],
  ['/icon.svg', ['icon.svg', 'image/svg+xml']],
  ['/screenshot.png', ['screenshot.png', 'image/png']],
  ...['Inter-Regular', 'Inter-Medium', 'Inter-SemiBold', 'JetBrainsMono-Regular', 'JetBrainsMono-Medium']
    .map(name => [`/fonts/${name}.woff2`, [`fonts/${name}.woff2`, 'font/woff2']]),
  ...['Inter-OFL', 'JetBrainsMono-OFL']
    .map(name => [`/fonts/${name}.txt`, [`fonts/${name}.txt`, 'text/plain']]),
]);
const compressors = { br: promisify(brotliCompress), gzip: promisify(gzip) };
const compressible = type => type.startsWith('text/') || type.endsWith('+xml') || type.endsWith('+json');
// The first of br and gzip the client accepts; otherwise the file goes out as it is.
function encoding(header) {
  const accepted = new Map(String(header || '').split(',').map(part => {
    const [name, ...params] = part.toLowerCase().split(';').map(value => value.trim());
    const q = params.find(value => value.startsWith('q='));
    return [name, q ? Number(q.slice(2)) : 1];
  }));
  return ['br', 'gzip'].find(name => accepted.get(name) > 0);
}
// If-None-Match uses the weak comparison: W/"x" matches "x".
const unchanged = (header, etag) => typeof header === 'string' &&
  header.split(',').some(tag => ['*', etag, `W/${etag}`].includes(tag.trim()));

// Each file is read, hashed and compressed once per version on disk. A changed size, mtime,
// ctime or inode reloads it, so a new release is never answered from an old copy.
function publicFiles() {
  const files = new Map();
  return async (name, wanted) => {
    const url = new URL(`public/${name}`, import.meta.url);
    const { size, mtimeMs, ctimeMs, ino } = await stat(url);
    const version = `${size}:${mtimeMs}:${ctimeMs}:${ino}`;
    let file = files.get(name);
    if (file?.version !== version) {
      const identity = readFile(url).then(body => ({ body, etag: `"${createHash('sha256').update(body).digest('base64url')}"` }));
      file = { version, identity, encoded: new Map() };
      files.set(name, file);
    }
    try {
      const plain = await file.identity;
      if (!wanted) return plain;
      if (!file.encoded.has(wanted)) {
        file.encoded.set(wanted, compressors[wanted](plain.body).then(body => body.byteLength < plain.body.byteLength
          ? { body, etag: `${plain.etag.slice(0, -1)}-${wanted}"`, encoding: wanted } : plain));
      }
      return await file.encoded.get(wanted);
    } catch (error) {
      if (files.get(name) === file) files.delete(name);
      throw error;
    }
  };
}

export function createSite({ publicOrigin } = {}) {
  let origin;
  try { origin = new URL(publicOrigin); } catch { origin = null; }
  if (!origin || origin.origin !== publicOrigin || !(origin.protocol === 'https:' ||
      (origin.protocol === 'http:' && ['localhost', '127.0.0.1'].includes(origin.hostname)))) {
    throw new Error('PUBLIC_ORIGIN must be an HTTPS origin (HTTP is allowed only on loopback).');
  }
  const files = publicFiles();
  const server = http.createServer(async (req, res) => {
    res.setHeader('Content-Security-Policy', "default-src 'self'; script-src 'none'; style-src 'self'; img-src 'self'; connect-src 'none'; object-src 'none'; base-uri 'none'; frame-ancestors 'none'; form-action 'none'");
    res.setHeader('Referrer-Policy', 'no-referrer');
    res.setHeader('X-Content-Type-Options', 'nosniff');
    res.setHeader('X-Frame-Options', 'DENY');
    res.setHeader('Cache-Control', 'no-store');
    if (origin.protocol === 'https:') res.setHeader('Strict-Transport-Security', 'max-age=31536000');
    if (!req.url || req.url.length > 2048) { res.writeHead(404).end(); return; }
    // Shared links gain tracking queries, and uptime checks send HEAD; Node omits HEAD bodies.
    const path = req.url.split('?')[0];
    const read = req.method === 'GET' || req.method === 'HEAD';
    if (path === '/health' && read) { res.end('ok'); return; }
    const asset = read && assets.get(path);
    if (!asset) { res.writeHead(404).end(); return; }
    try {
      const compress = compressible(asset[1]);
      const file = await files(asset[0], compress && encoding(req.headers['accept-encoding']));
      const type = asset[1].startsWith('text/') || asset[1] === 'image/svg+xml'
        ? `${asset[1]}; charset=utf-8` : asset[1];
      // Fonts never change under one name; let browsers keep them.
      if (asset[1].startsWith('font/')) res.setHeader('Cache-Control', 'public, max-age=604800, immutable');
      // Everything else is kept but checked on each use, so a new release shows at once.
      else res.setHeader('Cache-Control', 'no-cache');
      res.setHeader('ETag', file.etag);
      if (compress) res.setHeader('Vary', 'Accept-Encoding');
      if (unchanged(req.headers['if-none-match'], file.etag)) { res.writeHead(304).end(); return; }
      if (file.encoding) res.setHeader('Content-Encoding', file.encoding);
      res.writeHead(200, { 'Content-Type': type, 'Content-Length': file.body.byteLength }).end(file.body);
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
