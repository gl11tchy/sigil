import test from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import { once } from 'node:events';
import { syncBuiltinESMExports } from 'node:module';
import { tmpdir } from 'node:os';
import { pathToFileURL, fileURLToPath } from 'node:url';
import fs, { readFileSync, statSync, utimesSync, writeFileSync, renameSync } from 'node:fs';
import fsp from 'node:fs/promises';
import zlib, { gunzipSync, brotliDecompressSync } from 'node:zlib';

// Count the server's file reads and compressions. The server is a copy in a temporary
// directory, imported after these wrappers are installed, so the real public files are never edited.
const reads = [], compressions = [];
const readFile = fsp.readFile;
fsp.readFile = (path, ...rest) => { reads.push(String(path)); return readFile(path, ...rest); };
for (const name of ['gzip', 'brotliCompress']) {
  const original = zlib[name];
  zlib[name] = (...args) => { compressions.push(name); return original(...args); };
}
syncBuiltinESMExports();

const source = new URL('../', import.meta.url);
// Real path: the module loader resolves /var to /private/var on macOS, and reads are matched by URL.
const root = pathToFileURL(`${fs.realpathSync(fs.mkdtempSync(`${tmpdir()}/sigil-site-cache-`))}/`);
fs.copyFileSync(new URL('server.mjs', source), new URL('server.mjs', root));
fs.cpSync(new URL('public/', source), new URL('public/', root), { recursive: true });
process.on('exit', () => fs.rmSync(root, { recursive: true, force: true }));
const { createSite } = await import(new URL('server.mjs', root));

const CSP = "default-src 'self'; script-src 'none'; style-src 'self'; img-src 'self'; connect-src 'none'; object-src 'none'; base-uri 'none'; frame-ancestors 'none'; form-action 'none'";
const fonts = ['Inter-Regular', 'Inter-Medium', 'Inter-SemiBold', 'JetBrainsMono-Regular', 'JetBrainsMono-Medium'];
// Path, file, and the Content-Type the server sent before this change.
const ASSETS = [
  ['/', 'index.html', 'text/html; charset=utf-8'],
  ['/docs', 'docs/index.html', 'text/html; charset=utf-8'],
  ['/docs/', 'docs/index.html', 'text/html; charset=utf-8'],
  ['/style.css', 'style.css', 'text/css; charset=utf-8'],
  ['/icon.svg', 'icon.svg', 'image/svg+xml; charset=utf-8'],
  ['/screenshot.png', 'screenshot.png', 'image/png'],
  ...fonts.map(name => [`/fonts/${name}.woff2`, `fonts/${name}.woff2`, 'font/woff2']),
  ...['Inter-OFL', 'JetBrainsMono-OFL'].map(name => [`/fonts/${name}.txt`, `fonts/${name}.txt`, 'text/plain; charset=utf-8']),
];
const binary = type => type === 'image/png' || type === 'font/woff2';
const onDisk = file => readFileSync(new URL(`public/${file}`, root));

async function setup(t, publicOrigin = 'http://127.0.0.1') {
  const site = createSite({ publicOrigin });
  site.server.listen(0, '127.0.0.1');
  await once(site.server, 'listening');
  t.after(() => site.close());
  return site.server.address().port;
}

function request(port, path, { method = 'GET', headers = {} } = {}) {
  return new Promise((resolve, reject) => {
    http.request({ host: '127.0.0.1', port, path, method, headers }, res => {
      const chunks = [];
      res.on('data', chunk => chunks.push(chunk));
      res.on('end', () => resolve({ status: res.statusCode, headers: res.headers, body: Buffer.concat(chunks) }));
    }).on('error', reject).end();
  });
}

function decode({ headers, body }) {
  if (headers['content-encoding'] === 'br') return brotliDecompressSync(body);
  if (headers['content-encoding'] === 'gzip') return gunzipSync(body);
  assert.equal(headers['content-encoding'], undefined);
  return body;
}

function assertSecurityHeaders(headers, https = false) {
  assert.equal(headers['content-security-policy'], CSP);
  assert.equal(headers['referrer-policy'], 'no-referrer');
  assert.equal(headers['x-content-type-options'], 'nosniff');
  assert.equal(headers['x-frame-options'], 'DENY');
  assert.equal(headers['strict-transport-security'], https ? 'max-age=31536000' : undefined);
}

const servedReads = () => reads.filter(path => path.startsWith(`${root}public/`)).length;
test('the read counter sees the server', async t => {
  const port = await setup(t);
  const before = servedReads();
  await request(port, '/icon.svg');
  assert.equal(servedReads() - before, 1);
});


test('every asset serves the same bytes and type as before, in each encoding', async t => {
  const port = await setup(t);
  for (const [path, file, type] of ASSETS) {
    for (const accept of [undefined, 'identity', 'gzip', 'br', 'gzip, deflate, br']) {
      const res = await request(port, path, { headers: accept ? { 'Accept-Encoding': accept } : {} });
      assert.equal(res.status, 200, `${path} ${accept}`);
      assert.equal(res.headers['content-type'], type, path);
      assert.equal(Number(res.headers['content-length']), res.body.byteLength, path);
      assert.deepEqual(decode(res), onDisk(file), `${path} ${accept}`);
      assertSecurityHeaders(res.headers);
    }
  }
});

test('an ETag round trip answers 304 with no body and the same headers', async t => {
  const port = await setup(t, 'https://sigilapp.dev');
  for (const [path, , type] of ASSETS) {
    for (const accept of [undefined, 'gzip', 'br']) {
      const headers = accept ? { 'Accept-Encoding': accept } : {};
      const first = await request(port, path, { headers });
      assert.match(first.headers.etag, /^"[A-Za-z0-9_-]{43}(-br|-gzip)?"$/, path);
      const cache = type === 'font/woff2' ? 'public, max-age=604800, immutable' : 'no-cache';
      assert.equal(first.headers['cache-control'], cache, path);
      for (const tag of [first.headers.etag, `W/${first.headers.etag}`, `"other", ${first.headers.etag}`, '*']) {
        const again = await request(port, path, { headers: { ...headers, 'If-None-Match': tag } });
        assert.equal(again.status, 304, `${path} ${tag}`);
        assert.equal(again.body.byteLength, 0);
        assert.equal(again.headers.etag, first.headers.etag);
        assert.equal(again.headers['cache-control'], cache);
        assert.equal(again.headers.vary, first.headers.vary);
        assertSecurityHeaders(again.headers, true);
      }
      const other = await request(port, path, { headers: { ...headers, 'If-None-Match': '"audit"' } });
      assert.equal(other.status, 200, path);
      assert.equal(other.headers.etag, first.headers.etag);
    }
  }
});

test('text is compressed only when the client accepts it, and binary files never are', async t => {
  const port = await setup(t);
  const cases = [
    [undefined, undefined], ['identity', undefined], ['gzip', 'gzip'], ['br', 'br'], ['gzip, br', 'br'],
    ['gzip;q=0.5, br;q=0', 'gzip'], ['br;q=0, gzip;q=0', undefined], ['deflate', undefined], ['GZIP', 'gzip'],
  ];
  for (const [path, , type] of ASSETS) {
    const tags = new Set();
    for (const [accept, expected] of cases) {
      const res = await request(port, path, { headers: accept ? { 'Accept-Encoding': accept } : {} });
      assert.equal(res.headers['content-encoding'], binary(type) ? undefined : expected, `${path} ${accept}`);
      assert.equal(res.headers.vary, binary(type) ? undefined : 'Accept-Encoding', path);
      tags.add(res.headers.etag);
    }
    // One strong validator per representation.
    assert.equal(tags.size, binary(type) ? 1 : 3, path);
  }
  const plain = await request(port, '/style.css');
  const packed = await request(port, '/style.css', { headers: { 'Accept-Encoding': 'br' } });
  assert.ok(packed.body.byteLength < plain.body.byteLength / 2);
  // A gzip validator does not validate the Brotli copy.
  const gzip = await request(port, '/style.css', { headers: { 'Accept-Encoding': 'gzip' } });
  const cross = await request(port, '/style.css', { headers: { 'Accept-Encoding': 'br', 'If-None-Match': gzip.headers.etag } });
  assert.equal(cross.status, 200);
  assert.equal(cross.headers['content-encoding'], 'br');
});

test('HEAD sends the GET headers without a body and without reading the file again', async t => {
  const port = await setup(t);
  for (const [path] of ASSETS) {
    for (const accept of [undefined, 'gzip', 'br']) {
      const headers = accept ? { 'Accept-Encoding': accept } : {};
      const get = await request(port, path, { headers });
      const before = servedReads();
      const head = await request(port, path, { method: 'HEAD', headers });
      assert.equal(servedReads(), before, `HEAD ${path} read the file`);
      assert.equal(head.status, 200);
      assert.equal(head.body.byteLength, 0);
      for (const name of ['content-type', 'content-length', 'content-encoding', 'etag', 'vary', 'cache-control', 'content-security-policy']) {
        assert.equal(head.headers[name], get.headers[name], `HEAD ${path} ${name}`);
      }
      const conditional = await request(port, path, { method: 'HEAD', headers: { ...headers, 'If-None-Match': get.headers.etag } });
      assert.equal(conditional.status, 304);
    }
  }
});

test('repeat requests reuse one read and one compression per file version', async t => {
  const port = await setup(t);
  const start = servedReads(), compressed = compressions.length;
  // Concurrent first requests share the same read.
  await Promise.all(Array.from({ length: 10 }, () => request(port, '/style.css', { headers: { 'Accept-Encoding': 'br' } })));
  for (let i = 0; i < 20; i++) {
    for (const accept of [undefined, 'gzip', 'br']) {
      const res = await request(port, '/style.css', { headers: accept ? { 'Accept-Encoding': accept } : {} });
      await request(port, '/style.css', { method: 'HEAD', headers: accept ? { 'Accept-Encoding': accept } : {} });
      await request(port, '/style.css', { headers: { 'Accept-Encoding': accept || '', 'If-None-Match': res.headers.etag } });
    }
    await request(port, '/screenshot.png');
    await request(port, '/screenshot.png', { method: 'HEAD' });
  }
  assert.equal(servedReads() - start, 2, 'one read each for style.css and screenshot.png');
  assert.deepEqual(compressions.slice(compressed).sort(), ['brotliCompress', 'gzip']);
});

test('a changed file gets a new ETag and a fresh body at once', async t => {
  const port = await setup(t);
  const file = fileURLToPath(new URL('public/style.css', root));
  const original = readFileSync(file);
  t.after(() => writeFileSync(file, original));
  const before = {};
  for (const accept of ['identity', 'gzip', 'br']) {
    before[accept] = await request(port, '/style.css', { headers: { 'Accept-Encoding': accept } });
  }
  // Same size and the old mtime: only the content, ctime and (for the rename) inode differ.
  const edits = [
    () => { const { mtime } = statSync(file); writeFileSync(file, Buffer.from(original).fill(0x20, 0, 8)); utimesSync(file, mtime, mtime); },
    () => { const { mtime } = statSync(file); writeFileSync(`${file}.new`, Buffer.from(original).fill(0x0a, 0, 8)); utimesSync(`${file}.new`, mtime, mtime); renameSync(`${file}.new`, file); },
  ];
  for (const edit of edits) {
    edit();
    const expected = readFileSync(file);
    assert.equal(expected.byteLength, original.byteLength);
    for (const accept of ['identity', 'gzip', 'br']) {
      const stale = before[accept].headers.etag;
      const res = await request(port, '/style.css', { headers: { 'Accept-Encoding': accept, 'If-None-Match': stale } });
      assert.equal(res.status, 200, accept);
      assert.notEqual(res.headers.etag, stale);
      assert.deepEqual(decode(res), expected);
      before[accept] = res;
    }
  }
});

test('health and unknown paths stay no-store with the same security headers', async t => {
  const port = await setup(t, 'https://sigilapp.dev');
  for (const [path, method, status] of [['/health', 'GET', 200], ['/health', 'HEAD', 200], ['/nope', 'GET', 404], ['/', 'POST', 404], ['/app.mjs', 'GET', 404]]) {
    const res = await request(port, path, { method, headers: { 'Accept-Encoding': 'gzip, br', 'If-None-Match': '*' } });
    assert.equal(res.status, status, `${method} ${path}`);
    assert.equal(res.headers['cache-control'], 'no-store');
    assert.equal(res.headers.etag, undefined);
    assert.equal(res.headers['content-encoding'], undefined);
    assertSecurityHeaders(res.headers, true);
  }
});
