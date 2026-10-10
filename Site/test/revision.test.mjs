import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, readFile, writeFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';
import { once } from 'node:events';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { stageBundle } from '../../Scripts/deploy-service.mjs';
import { loadRevision, sourceHash, runtimeFiles } from '../../Sidereal/revision.mjs';
import { stampRevision } from '../../Sidereal/stamp-revision.mjs';

const run = promisify(execFile);
const checkout = new URL('../../', import.meta.url);
async function bundle(t) {
  const directory = await mkdtemp(join(tmpdir(), 'site-revision-'));
  t.after(() => rm(directory, { recursive: true, force: true }));
  const url = pathToFileURL(`${directory}/`);
  const stamp = await stageBundle('site', directory);
  return { directory, url, stamp };
}

test('a staged Site starts without Git and serves its exact source identity without caching', async t => {
  const { url, stamp } = await bundle(t);
  assert.deepEqual(await readFile(new URL('revision.mjs', url)), await readFile(new URL('Sidereal/revision.mjs', checkout)));
  const { createSite } = await import(new URL('server.mjs', url));
  const site = createSite({ publicOrigin: 'http://localhost:3099' });
  t.after(() => site.close());
  site.server.listen(0, '127.0.0.1');
  await once(site.server, 'listening');
  const response = await fetch(`http://127.0.0.1:${site.server.address().port}/health`);
  assert.equal(response.status, 200);
  assert.match(response.headers.get('content-type'), /application\/json/);
  assert.equal(response.headers.get('cache-control'), 'no-store');
  assert.deepEqual(await response.json(), { status: 'ok', ...stamp });
});

test('Site production startup refuses an unstamped or malformed bundle', async t => {
  const { directory, url, stamp } = await bundle(t);
  const start = () => run(process.execPath, ['--input-type=module', '-e', `await import(${JSON.stringify(new URL('server.mjs', url).href)})`],
    { env: { HOME: directory, SIGIL_REQUIRE_REVISION: '1' }, timeout: 5000 });
  await rm(new URL('revision.json', url));
  assert.deepEqual(await loadRevision(url), { revision: 'development', gitSHA: null, dirty: null, sourceSHA256: null });
  await assert.rejects(start(), error => /Missing service revision stamp/.test(error.stderr));
  for (const patch of [{ gitSHA: 'unknown' }, { dirty: 'false' }, { revision: 'pretend-clean' }, { sourceSHA256: null }]) {
    await writeFile(new URL('revision.json', url), JSON.stringify({ ...stamp, ...patch }));
    await assert.rejects(start(), error => /Invalid service revision stamp/.test(error.stderr));
  }
});

test('the Site hash covers every staged runtime file, the manifest and the Docker recipe', async t => {
  const { url, stamp } = await bundle(t);
  const files = await runtimeFiles(url);
  assert.ok(files.includes('runtime-manifest.json') && files.includes('Dockerfile') && files.includes('public/index.html'));
  for (const file of files) {
    const target = new URL(file, url);
    const original = await readFile(target);
    await writeFile(target, Buffer.concat([original, Buffer.from('\n')]));
    assert.notEqual(await sourceHash(url), stamp.sourceSHA256, file);
    await assert.rejects(loadRevision(url, { required: true }), /stale/, file);
    await writeFile(target, original);
  }
  assert.deepEqual(await loadRevision(url, { required: true }), stamp);
});

test('manifest changes drive both staged contents and source hashing', async t => {
  const { url, stamp } = await bundle(t);
  await writeFile(new URL('not-shipped.txt', url), 'synthetic unused data');
  assert.equal(await sourceHash(url), stamp.sourceSHA256);
  const manifestURL = new URL('runtime-manifest.json', url);
  const manifest = JSON.parse(await readFile(manifestURL));
  manifest.files.push('not-shipped.txt');
  await writeFile(manifestURL, JSON.stringify(manifest));
  const changed = await stampRevision(url, checkout);
  assert.notEqual(changed.sourceSHA256, stamp.sourceSHA256);
  await writeFile(new URL('not-shipped.txt', url), 'synthetic changed input');
  await assert.rejects(loadRevision(url, { required: true }), /stale/);
  manifest.files.push('../outside');
  await writeFile(manifestURL, JSON.stringify(manifest));
  await assert.rejects(sourceHash(url), /Invalid service runtime manifest/);
});
