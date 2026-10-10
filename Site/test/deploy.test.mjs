import test from 'node:test';
import assert from 'node:assert/strict';
import { execFile, execFileSync } from 'node:child_process';
import { copyFile, cp, mkdir, mkdtemp, readFile, writeFile, rm, symlink } from 'node:fs/promises';
import { dirname, join } from 'node:path';
import { tmpdir } from 'node:os';
import { fileURLToPath } from 'node:url';
import { createServer } from 'node:http';
import { once } from 'node:events';
import { promisify } from 'node:util';

const repo = fileURLToPath(new URL('../../', import.meta.url));
const run = promisify(execFile);
const ids = { project: '11111111-1111-4111-8111-111111111111', environment: '22222222-2222-4222-8222-222222222222', service: '33333333-3333-4333-8333-333333333333' };

async function fixture(t, { target = 'valid', health = 'match', fail } = {}) {
  const scratch = await mkdtemp(join(tmpdir(), 'sigil-deploy-test-'));
  t.after(() => rm(scratch, { recursive: true, force: true }));
  const checkout = join(scratch, 'checkout');
  await mkdir(join(checkout, 'Scripts'), { recursive: true });
  for (const file of ['deploy-site.sh', 'deploy-sidereal.sh', 'deploy-service.mjs']) await copyFile(join(repo, 'Scripts', file), join(checkout, 'Scripts', file));
  for (const service of ['Site', 'Sidereal']) {
    const destination = join(checkout, service);
    await mkdir(destination);
    const manifest = JSON.parse(await readFile(join(repo, service, 'runtime-manifest.json')));
    for (const file of [...manifest.files, 'runtime-manifest.json', ...(service === 'Sidereal' ? ['stamp-revision.mjs'] : [])]) await copyFile(join(repo, service, file), join(destination, file));
    await cp(join(repo, service, 'public'), join(destination, 'public'), { recursive: true });
  }
  const bin = join(scratch, 'bin'), home = join(scratch, 'home');
  await mkdir(bin); await mkdir(home);
  const env = { PATH: `${bin}:${dirname(process.execPath)}:/usr/bin:/bin`, HOME: home, TMPDIR: scratch,
    SIGIL_TEST_ROOT: scratch, SIGIL_DEPLOY_ALLOW_LOOPBACK: '1', SIGIL_DEPLOY_TIMEOUT_SECONDS: '1' };
  const git = (...args) => execFileSync('git', args, { cwd: checkout, env, encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] }).trim();
  git('init', '-b', 'main');
  git('add', '.');
  git('-c', 'user.name=gl11tchy', '-c', 'user.email=211956100+gl11tchy@users.noreply.github.com', 'commit', '-m', 'Synthetic deploy fixture');
  git('remote', 'add', 'origin', checkout); // Fetch is strictly local.
  git('fetch', 'origin', 'main');
  let requests = 0;
  const server = createServer(async (req, res) => {
    requests++;
    assert.equal(req.url, '/health');
    let uploaded;
    try { uploaded = JSON.parse(await readFile(join(scratch, 'capture.json'))); } catch { res.writeHead(503).end(); return; }
    if (health === 'redirect') { res.writeHead(302, { Location: '/unverified' }).end(); return; }
    if (health === 'malformed') { res.writeHead(200, { 'Content-Type': 'application/json' }).end('not JSON'); return; }
    if (health === 'oversized') { res.writeHead(200, { 'Content-Type': 'application/json' }).end(' '.repeat(70000)); return; }
    if (health === 'slow') return;
    const stamp = { ...uploaded.stamp };
    if (health === 'hash') stamp.sourceSHA256 = '0'.repeat(64);
    if (health === 'commit' || (health === 'eventual' && requests === 1)) {
      stamp.gitSHA = '0'.repeat(40); stamp.revision = stamp.gitSHA;
    }
    res.writeHead(200, { 'Content-Type': 'application/json' }).end(JSON.stringify({ status: 'ok', ...stamp }));
  });
  server.listen(0, '127.0.0.1');
  await once(server, 'listening');
  t.after(() => { server.close(); server.closeAllConnections(); });
  const host = `127.0.0.1:${server.address().port}`;
  const config = { ids, host, target, fail };
  await writeFile(join(scratch, 'config.json'), JSON.stringify(config));
  await writeFile(join(bin, 'railway'), `#!/usr/bin/env node
const fs = require('node:fs');
const path = require('node:path');
const { pathToFileURL } = require('node:url');
const root = process.env.SIGIL_TEST_ROOT;
const { ids, host, target, fail } = JSON.parse(fs.readFileSync(path.join(root, 'config.json')));
const args = process.argv.slice(2);
fs.appendFileSync(path.join(root, 'calls.jsonl'), JSON.stringify(args) + '\\n');
if (fail === args[0]) { console.error('SYNTHETIC_TOKEN_MUST_NOT_LEAK'); process.exit(7); }
if (args[0] === 'status') {
  const instance = { serviceId: ids.service };
  if (target === 'instance') instance.serviceId = 'different';
  const environment = { id: ids.environment, canAccess: true, serviceInstances: { edges: [{ node: instance }] } };
  if (target === 'environment') environment.id = 'different';
  if (target === 'access') environment.canAccess = false;
  if (target === 'deleted') environment.deletedAt = '2026-01-01T00:00:00Z';
  const data = { id: ids.project, services: { edges: [{ node: { id: ids.service } }] }, environments: { edges: [{ node: environment }] } };
  if (target === 'project') data.id = 'different';
  if (target === 'service') data.services.edges = [];
  if (target === 'malformed') console.log('not JSON'); else console.log(JSON.stringify(data));
} else if (args[0] === 'domain' && args[1] === 'list') {
  console.log(JSON.stringify({ domains: target === 'domain-shape' ? {} : [{ domain: target === 'domain' ? 'wrong.example' : host }] }));
} else if (args[0] === 'up') {
  (async () => {
    const directory = pathToFileURL(args[1] + '/');
    const { loadRevision } = await import(new URL('revision.mjs', directory));
    const stamp = await loadRevision(directory, { required: true });
    fs.writeFileSync(path.join(root, 'capture.json'), JSON.stringify({ args, files: fs.readdirSync(directory), stamp }));
    console.log(JSON.stringify({ deploymentId: 'synthetic' }));
  })().catch(() => process.exit(2));
} else { process.exit(9); }
`, { mode: 0o700 });
  const args = ['--project', ids.project, '--environment', ids.environment, '--service', ids.service, '--health-url', `http://${host}/health`];
  async function deploy(service = 'site', overrides = {}, extra = [], options = args) {
    try {
      const result = await run('bash', [join(checkout, 'Scripts', `deploy-${service}.sh`), ...options, ...extra], { cwd: checkout, env: { ...env, ...overrides }, timeout: 10000 });
      return { ...result, code: 0 };
    } catch (error) { return { stdout: error.stdout, stderr: error.stderr, code: error.code }; }
  }
  async function calls() {
    try { return (await readFile(join(scratch, 'calls.jsonl'), 'utf8')).trim().split('\n').map(JSON.parse); }
    catch (error) { if (error.code === 'ENOENT') return []; throw error; }
  }
  return { checkout, env, git, deploy, calls, server, args, requests: () => requests,
    capture: async () => JSON.parse(await readFile(join(scratch, 'capture.json'))) };
}

for (const service of ['site', 'sidereal']) {
  test(`${service}: verified target uploads one runtime stamp and waits for both identity fields`, async t => {
    const f = await fixture(t);
    await writeFile(join(f.checkout, 'local-secret.env'), 'synthetic unshipped data');
    const result = await f.deploy(service, { SIGIL_ALLOW_DIRTY: '1' });
    assert.equal(result.code, 0, result.stderr);
    assert.match(result.stdout, /Running source identity matches/);
    assert.doesNotMatch(result.stdout, /deployment healthy|deploy successful/i);
    const uploaded = await f.capture();
    assert.equal(uploaded.stamp.gitSHA, f.git('rev-parse', 'HEAD'));
    assert.equal(uploaded.stamp.dirty, true);
    assert.ok(uploaded.files.includes('runtime-manifest.json'));
    assert.ok(!uploaded.files.includes('node_modules') && !uploaded.files.includes('.git') && !uploaded.files.includes('local-secret.env') && !uploaded.files.includes('test'));
    const calls = await f.calls();
    assert.deepEqual(calls.map(args => args[0]), ['status', 'domain', 'up']);
    assert.deepEqual(calls[0], ['status', '--project', ids.project, '--environment', ids.environment, '--json']);
    assert.deepEqual(calls[1], ['domain', 'list', '--project', ids.project, '--environment', ids.environment, '--service', ids.service, '--json']);
    assert.deepEqual(uploaded.args.slice(2), ['--path-as-root', '--project', ids.project, '--environment', ids.environment, '--service', ids.service, '--detach', '--json']);
    assert.ok(f.requests() >= 1);
    await assert.rejects(readFile(join(uploaded.args[1], 'revision.json')), { code: 'ENOENT' });
  });
}

test('a dirty tree stops before any Railway command unless explicitly allowed', async t => {
  const f = await fixture(t);
  await writeFile(join(f.checkout, 'Site/server.mjs'), '// synthetic edit');
  const result = await f.deploy();
  assert.notEqual(result.code, 0);
  assert.match(result.stderr, /SIGIL_ALLOW_DIRTY=1/);
  assert.deepEqual(await f.calls(), []);
});

test('non-main source requires its independent override', async t => {
  const f = await fixture(t);
  f.git('checkout', '-b', 'synthetic-feature');
  await writeFile(join(f.checkout, 'README.txt'), 'synthetic commit');
  f.git('add', '.');
  f.git('-c', 'user.name=gl11tchy', '-c', 'user.email=211956100+gl11tchy@users.noreply.github.com', 'commit', '-m', 'Synthetic non-main');
  const blocked = await f.deploy();
  assert.notEqual(blocked.code, 0);
  assert.match(blocked.stderr, /SIGIL_ALLOW_NON_MAIN=1/);
  assert.deepEqual(await f.calls(), []);
  assert.equal((await f.deploy('site', { SIGIL_ALLOW_NON_MAIN: '1' })).code, 0);
  assert.equal((await f.capture()).stamp.dirty, false);
});

for (const target of ['project', 'environment', 'service', 'instance', 'access', 'deleted', 'domain', 'domain-shape', 'malformed']) {
  test(`unverified ${target} refuses upload`, async t => {
    const f = await fixture(t, { target });
    assert.notEqual((await f.deploy()).code, 0);
    assert.ok(!(await f.calls()).some(args => args[0] === 'up'));
    assert.equal(f.requests(), 0);
  });
}

for (const health of ['hash', 'commit', 'redirect', 'malformed', 'oversized', 'slow']) {
  test(`${health} health times out without a second upload`, async t => {
    const f = await fixture(t, { health });
    const result = await f.deploy();
    assert.notEqual(result.code, 0);
    assert.match(result.stderr, /Uploaded once/);
    assert.equal((await f.calls()).filter(args => args[0] === 'up').length, 1);
    await assert.rejects(readFile(join((await f.capture()).args[1], 'revision.json')), { code: 'ENOENT' });
  });
}

test('unreachable health fails after exactly one upload', async t => {
  const f = await fixture(t);
  await new Promise(resolve => f.server.close(resolve));
  assert.notEqual((await f.deploy()).code, 0);
  assert.equal((await f.calls()).filter(args => args[0] === 'up').length, 1);
});

test('a rollout may answer with the previous revision before the uploaded identity appears', async t => {
  const f = await fixture(t, { health: 'eventual' });
  const result = await f.deploy('site', { SIGIL_DEPLOY_TIMEOUT_SECONDS: '3' });
  assert.equal(result.code, 0, result.stderr);
  assert.equal(f.requests(), 2);
  assert.equal((await f.calls()).filter(args => args[0] === 'up').length, 1);
});

test('CLI failure does not expose its output or upload again', async t => {
  const f = await fixture(t, { fail: 'status' });
  const result = await f.deploy();
  assert.notEqual(result.code, 0);
  assert.doesNotMatch(`${result.stdout}${result.stderr}`, /SYNTHETIC_TOKEN_MUST_NOT_LEAK/);
  assert.ok(!(await f.calls()).some(args => args[0] === 'up'));
});

test('an upload failure is not retried and never begins health verification', async t => {
  const f = await fixture(t, { fail: 'up' });
  const result = await f.deploy();
  assert.notEqual(result.code, 0);
  assert.doesNotMatch(`${result.stdout}${result.stderr}`, /SYNTHETIC_TOKEN_MUST_NOT_LEAK/);
  const uploads = (await f.calls()).filter(args => args[0] === 'up');
  assert.equal(uploads.length, 1);
  assert.equal(f.requests(), 0);
  await assert.rejects(readFile(join(uploads[0][1], 'revision.json')), { code: 'ENOENT' });
});

test('unsafe URL/options/deadline overrides stop before provider access', async t => {
  const f = await fixture(t);
  for (const extra of [['--other', 'value'], ['--project', ids.project]]) {
    assert.notEqual((await f.deploy('site', {}, extra)).code, 0);
  }
  for (const url of ['https://user:SYNTHETIC_TOKEN_MUST_NOT_LEAK@example.com/health', 'https://example.com/health?token=SYNTHETIC_TOKEN_MUST_NOT_LEAK',
    'https://example.com/health#fragment', 'https://example.com/', 'http://example.com/health', 'https://example.com:8443/health']) {
    const result = await f.deploy('site', {}, [], [...f.args.slice(0, -1), url]);
    assert.notEqual(result.code, 0);
    assert.match(result.stderr, /Health URL/);
    assert.doesNotMatch(`${result.stdout}${result.stderr}`, /SYNTHETIC_TOKEN_MUST_NOT_LEAK/);
  }
  for (const value of ['0', '301', 'not-a-number']) assert.notEqual((await f.deploy('site', { SIGIL_DEPLOY_TIMEOUT_SECONDS: value })).code, 0);
  assert.notEqual((await f.deploy('site', { SIGIL_DEPLOY_ALLOW_LOOPBACK: '0' })).code, 0);
  assert.deepEqual(await f.calls(), []);
});

test('ignored runtime inputs are never uploaded, even with dirty override', async t => {
  const f = await fixture(t);
  await writeFile(join(f.checkout, '.gitignore'), 'Site/public/private.env\n');
  await writeFile(join(f.checkout, 'Site/public/private.env'), 'synthetic ignored credential');
  assert.notEqual((await f.deploy('site', { SIGIL_ALLOW_DIRTY: '1' })).code, 0);
  assert.ok(!(await f.calls()).some(args => args[0] === 'up'));
});

for (const file of ['Site/public/linked.env', 'Site/runtime-manifest.json', 'Sidereal/revision.mjs']) {
  test(`linked runtime input ${file} is refused before upload`, async t => {
    const f = await fixture(t);
    const target = join(f.checkout, file);
    // The target is another generated fixture file; never read a personal file.
    const original = file.endsWith('linked.env') ? join(f.checkout, 'Site/server.mjs') : target;
    const destination = join(f.checkout, 'synthetic-linked-input');
    await copyFile(original, destination);
    await rm(target, { force: true });
    await symlink(destination, target);
    assert.notEqual((await f.deploy('site', { SIGIL_ALLOW_DIRTY: '1' })).code, 0);
    assert.ok(!(await f.calls()).some(args => args[0] === 'up'));
  });
}
