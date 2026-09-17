import test from 'node:test';
import assert from 'node:assert/strict';
import { once } from 'node:events';
import { createSite } from '../server.mjs';

const ZIP = 'https://github.com/gl11tchy/sigil/releases/latest/download/Sigil.zip';
const REMOTE = 'https://remote.sigilapp.dev';
const EMAIL = /[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}/i;

async function setup(t, publicOrigin = 'http://127.0.0.1') {
  const site = createSite({ publicOrigin });
  site.server.listen(0, '127.0.0.1');
  await once(site.server, 'listening');
  const base = `http://127.0.0.1:${site.server.address().port}`;
  t.after(() => site.close());
  return { site, base };
}

async function text(base, path, method = 'GET') {
  const res = await fetch(`${base}${path}`, { method, redirect: 'manual' });
  const body = await res.text();
  return { res, body };
}

function assertSecurityHeaders(res, { https = false, html = false } = {}) {
  const csp = res.headers.get('content-security-policy') || '';
  assert.ok(csp);
  assert.doesNotMatch(csp, /unsafe-inline/);
  assert.match(csp, /default-src 'self'/);
  assert.match(csp, /script-src 'self'/);
  assert.match(csp, /style-src 'self'/);
  assert.match(csp, /img-src 'self'/);
  assert.match(csp, /connect-src 'none'/);
  assert.match(csp, /frame-ancestors 'none'/);
  assert.equal(res.headers.get('referrer-policy'), 'no-referrer');
  assert.equal(res.headers.get('x-content-type-options'), 'nosniff');
  assert.equal(res.headers.get('x-frame-options'), 'DENY');
  if (https) {
    assert.equal(res.headers.get('strict-transport-security'), 'max-age=31536000');
  } else {
    assert.equal(res.headers.get('strict-transport-security'), null);
  }
  if (html) {
    const cache = res.headers.get('cache-control') || '';
    assert.match(cache, /no-store/);
    assert.doesNotMatch(cache, /max-age=31536000/);
  }
}

function assertPublicCopy(html) {
  assert.match(html, /gl11tchy/);
  assert.doesNotMatch(html, /mailto:/i);
  assert.doesNotMatch(html, EMAIL);
  assert.doesNotMatch(html, /<script/i);
  assert.doesNotMatch(html, /\sstyle=/i);
  assert.doesNotMatch(html, /<style[\s>]/i);
  assert.doesNotMatch(html, /fonts\.google/i);
  assert.doesNotMatch(html, /Inter|Fraunces|Space Grotesk/);
  assert.doesNotMatch(html, /username\.sigilapp\.dev|your-subdomain/i);
  assert.doesNotMatch(html, /pair(?:ing)? at https:\/\/sigilapp\.dev/i);
}

test('PUBLIC_ORIGIN must be HTTPS except on loopback', () => {
  assert.throws(() => createSite({ publicOrigin: 'http://example.com' }), /HTTPS origin/);
  assert.throws(() => createSite({ publicOrigin: 'https://sigilapp.dev/' }), /HTTPS origin/);
  assert.doesNotThrow(() => createSite({ publicOrigin: 'http://localhost' }).close());
  assert.doesNotThrow(() => createSite({ publicOrigin: 'https://sigilapp.dev' }).close());
});

test('GET /health returns ok', async t => {
  const { base } = await setup(t);
  const { res, body } = await text(base, '/health');
  assert.equal(res.status, 200);
  assert.equal(body, 'ok');
  assertSecurityHeaders(res);
});

test('GET / is the product page', async t => {
  const { base } = await setup(t);
  const { res, body } = await text(base, '/');
  assert.equal(res.status, 200);
  assert.match(res.headers.get('content-type'), /text\/html/);
  assertSecurityHeaders(res, { html: true });
  assert.equal([...body.matchAll(/<h1[\s>]/g)].length, 1);
  assert.match(body, />Sigil</);
  assert.match(body, /every conversation you have ever had/);
  assert.match(body, new RegExp(`href="${ZIP.replaceAll('/', '\\/')}"`));
  assert.match(body, /<img[^>]+src="\/screenshot\.png"/);
  assert.match(body, /<img[^>]+alt="[^"]{20,}"/);
  assert.match(body, /\/Applications\/Sigil\.app/);
  assert.match(body, /macOS 14/);
  assert.match(body, /Settings/);
  assert.match(body, /Remote/);
  assert.match(body, /scan/i);
  assert.ok(body.includes(REMOTE));
  assert.match(body, /href="\/docs"/);
  assert.match(body, /href="https:\/\/github.com\/gl11tchy\/sigil"/);
  assertPublicCopy(body);
});

test('GET /docs and /docs/ document install and pairing', async t => {
  const { base } = await setup(t);
  const docs = await text(base, '/docs');
  const slash = await text(base, '/docs/');
  for (const { res, body } of [docs, slash]) {
    assert.equal(res.status, 200);
    assert.match(res.headers.get('content-type'), /text\/html/);
    assertSecurityHeaders(res, { html: true });
    assert.equal([...body.matchAll(/<h1[\s>]/g)].length, 1);
    assert.match(body, /\/Applications\/Sigil\.app/);
    assert.match(body, /macOS 14/);
    assert.match(body, /sidebar/i);
    assert.match(body, /search/i);
    assert.match(body, /tab/i);
    assert.match(body, /Settings/);
    assert.match(body, /Remote/);
    assert.ok(body.includes(REMOTE));
    assert.match(body, /localhost/);
    assert.match(body, /off by default/i);
    assert.match(body, /Disconnect/);
    assert.match(body, /revoke/i);
    assert.match(body, /⌘T|Cmd\+T|Command-T/);
    assertPublicCopy(body);
    assert.doesNotMatch(body, /AES-256|IndexedDB|bootstrap secret|Railway/i);
  }
});

test('GET /screenshot.png is the app window', async t => {
  const { base } = await setup(t);
  const res = await fetch(`${base}/screenshot.png`);
  assert.equal(res.status, 200);
  assert.match(res.headers.get('content-type'), /image\/png/);
  const bytes = await res.arrayBuffer();
  assert.ok(bytes.byteLength > 1000);
});

test('relay paths are 404', async t => {
  const { base } = await setup(t);
  for (const [path, method] of [['/rooms', 'GET'], ['/rooms', 'POST'], ['/connect', 'GET'], ['/app.mjs', 'GET'], ['/sw.js', 'GET'], ['/nope', 'GET']]) {
    const { res, body } = await text(base, path, method);
    assert.equal(res.status, 404, `${method} ${path}`);
    assert.doesNotMatch(body, /ok/);
    assertSecurityHeaders(res);
  }
});

test('HTTPS public origin sets HSTS', async t => {
  const { base } = await setup(t, 'https://sigilapp.dev');
  const { res } = await text(base, '/');
  assertSecurityHeaders(res, { https: true, html: true });
});
