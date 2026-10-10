import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, mkdir, copyFile, cp, readFile, writeFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { pathToFileURL } from 'node:url';
import { execFileSync } from 'node:child_process';
import { once } from 'node:events';
import { loadRevision, sourceHash } from '../revision.mjs';
import { stampRevision } from '../stamp-revision.mjs';
import { stageBundle } from '../../Scripts/deploy-service.mjs';

const root = new URL('../', import.meta.url);
async function bundle(t) {
  const path = await mkdtemp(`${tmpdir()}/sidereal-revision-`);
  t.after(() => rm(path, { recursive: true, force: true }));
  const target = pathToFileURL(`${path}/`);
  for (const file of ['Dockerfile', 'package.json', 'package-lock.json', 'server.mjs', 'apns.mjs', 'revision.mjs', 'runtime-manifest.json']) {
    await copyFile(new URL(file, root), new URL(file, target));
  }
  await cp(new URL('public/', root), new URL('public/', target), { recursive: true });
  return target;
}

test('local uploads carry the Git SHA, dirty state, and a hash of the shipped runtime', async t => {
  const target = await bundle(t);
  const stamped = await stampRevision(target, root);
  assert.equal(stamped.gitSHA, execFileSync('git', ['rev-parse', 'HEAD'], { cwd: root, encoding: 'utf8' }).trim());
  const dirty = execFileSync('git', ['status', '--porcelain', '--untracked-files=normal'], { cwd: root, encoding: 'utf8' }).trim() !== '';
  assert.equal(stamped.dirty, dirty);
  assert.equal(stamped.revision, `${stamped.gitSHA}${dirty ? '-dirty' : ''}`);
  assert.equal(stamped.sourceSHA256, await sourceHash(target));
  assert.deepEqual(await loadRevision(target, { required: true }), stamped);
});

test('an unstamped development checkout is explicit; production requires a stamp', async t => {
  const target = await bundle(t);
  assert.deepEqual(await loadRevision(target), { revision: 'development', gitSHA: null, dirty: null, sourceSHA256: null });
  await assert.rejects(loadRevision(target, { required: true }), /stamp/);
});

test('a stale stamp fails closed after runtime changes but ignores files outside the bundle', async t => {
  const target = await bundle(t);
  await stampRevision(target, root);
  await mkdir(new URL('test/', target));
  await writeFile(new URL('test/not-shipped.mjs', target), '// test only');
  await loadRevision(target, { required: true });
  await writeFile(new URL('public/app.mjs', target), '// changed since upload was stamped');
  await assert.rejects(loadRevision(target, { required: true }), /stale/);
});

test('malformed revision metadata is rejected instead of claiming a verified build', async t => {
  const target = await bundle(t);
  const stamped = await stampRevision(target, root);
  for (const patch of [{ gitSHA: 'not-a-sha' }, { dirty: 'false' }, { revision: 'pretend-clean' }, { sourceSHA256: 'x' }]) {
    await writeFile(new URL('revision.json', target), JSON.stringify({ ...stamped, ...patch }));
    await assert.rejects(loadRevision(target), /Invalid/);
  }
});

test('a copied bundle with no Git metadata exposes its exact stamp on health', async t => {
  const target = await bundle(t);
  const stamped = await stampRevision(target, root);
  // This is the image's runtime layout, not the source checkout.
  await cp(new URL('node_modules/ws/', root), new URL('node_modules/ws/', target), { recursive: true });
  const { createRelay } = await import(new URL('server.mjs', target));
  const relay = createRelay({ publicOrigin: 'http://localhost:3099' });
  t.after(() => relay.close());
  relay.server.listen(0, '127.0.0.1');
  await once(relay.server, 'listening');
  const response = await fetch(`http://127.0.0.1:${relay.server.address().port}/health`);
  assert.equal(response.status, 200);
  assert.match(response.headers.get('content-type'), /application\/json/);
  assert.equal(response.headers.get('cache-control'), 'no-store');
  assert.deepEqual(await response.json(), { status: 'ok', ...stamped });
  assert.deepEqual(JSON.parse(await readFile(new URL('revision.json', target))), stamped);
});

test('the shared stager copies only a freshly stamped runtime bundle', async t => {
  const path = await mkdtemp(`${tmpdir()}/sidereal-deploy-test-`);
  t.after(() => rm(path, { recursive: true, force: true }));
  const stamped = await stageBundle('sidereal', path);
  const { readdir } = await import('node:fs/promises');
  assert.deepEqual((await readdir(path)).sort(), ['Dockerfile', 'apns.mjs', 'package-lock.json', 'package.json', 'public', 'revision.json', 'revision.mjs', 'runtime-manifest.json', 'server.mjs']);
  assert.deepEqual(await loadRevision(pathToFileURL(`${path}/`), { required: true }), stamped);
  assert.equal(stamped.sourceSHA256, await sourceHash(root));
});


test('Dockerfile-only changes invalidate the stamp and distinguish same-revision uploads', async t => {
  const target = await bundle(t);
  const first = await stampRevision(target, root);
  const dockerfile = new URL('Dockerfile', target);
  await writeFile(dockerfile, (await readFile(dockerfile, 'utf8')).replace('ENV PORT=3000', 'ENV PORT=4000'));
  await assert.rejects(loadRevision(target, { required: true }), /stale/);
  const second = await stampRevision(target, root);
  assert.equal(first.revision, second.revision);
  assert.notEqual(first.sourceSHA256, second.sourceSHA256);
  assert.deepEqual(await loadRevision(target, { required: true }), second);
});

test('the stamp runs when the script is named through a symlink, as macOS names /tmp', async t => {
  const { mkdtempSync, symlinkSync, existsSync, readFileSync, rmSync } = await import('node:fs');
  const { tmpdir } = await import('node:os');
  const { join, dirname } = await import('node:path');
  const { fileURLToPath } = await import('node:url');
  const { execFileSync } = await import('node:child_process');
  const here = dirname(fileURLToPath(import.meta.url));
  const scratch = mkdtempSync(join(tmpdir(), 'sidereal-symlink-'));
  t.after(() => rmSync(scratch, { recursive: true, force: true }));
  const link = join(scratch, 'sidereal-link');
  symlinkSync(join(here, '..'), link);
  const target = join(scratch, 'bundle');
  execFileSync('mkdir', ['-p', target]);
  for (const file of ['Dockerfile', 'package.json', 'package-lock.json', 'server.mjs', 'apns.mjs', 'revision.mjs', 'runtime-manifest.json']) {
    execFileSync('cp', [join(here, '..', file), join(target, file)]);
  }
  execFileSync('cp', ['-R', join(here, '..', 'public'), join(target, 'public')]);
  const out = execFileSync('node', [join(link, 'stamp-revision.mjs'), target], { encoding: 'utf8' });
  assert.match(out, /^[a-f0-9]{40}(-dirty)? [a-f0-9]{64}\n$/);
  // With the main module's link preserved, both sides still meet on the real path.
  const preserved = execFileSync('node', ['--preserve-symlinks-main', join(link, 'stamp-revision.mjs'), target], { encoding: 'utf8' });
  assert.match(preserved, /^[a-f0-9]{40}(-dirty)? [a-f0-9]{64}\n$/);
  assert.ok(existsSync(join(target, 'revision.json')));
  assert.equal(JSON.parse(readFileSync(join(target, 'revision.json'), 'utf8')).gitSHA.length, 40);
});
