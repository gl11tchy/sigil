import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';

const fixture = fileURLToPath(new URL('fixtures/ci-release-fixture.py', import.meta.url));
const helper = fileURLToPath(new URL('../../Scripts/ci-release.py', import.meta.url));

function run(t, scenario) {
  const root = mkdtempSync(join(tmpdir(), 'sigil-ci-release-'));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  const bin = join(root, 'bin');
  mkdirSync(bin);
  // A mistaken escape from the in-memory GitHub seam must never reach the network.
  const command = scenario === 'transport'
    ? '#!/bin/sh\nexec python3 "$SIGIL_GH_FIXTURE_PROGRAM" --github "$@"\n'
    : '#!/bin/sh\necho unexpected-real-GitHub-call >&2\nexit 91\n';
  writeFileSync(join(bin, 'gh'), command, { mode: 0o755 });
  const result = spawnSync('python3', [fixture, helper, root, scenario], {
    encoding: 'utf8', timeout: 10000,
    env: { PATH: bin + ':' + process.env.PATH, HOME: root, GH_CONFIG_DIR: join(root, 'gh'),
      GH_TOKEN: 'generated-fixture-only', PYTHONDONTWRITEBYTECODE: '1',
      SIGIL_GH_FIXTURE_PROGRAM: fixture, SIGIL_GH_STATE: join(root, 'github.json') },
  });
  assert.equal(result.error, undefined);
  assert.equal(result.status, 0, result.stdout + result.stderr);
  const output = JSON.parse(result.stdout);
  // Compare entire prior records, including assets, and every prior tag mapping.
  assert.deepEqual(
    output.releaseStateAfter.items.filter(item =>
      output.releaseStateBefore.items.some(prior => prior.tag_name === item.tag_name)),
    output.releaseStateBefore.items,
  );
  for (const [tag, sha] of Object.entries(output.releaseStateBefore.tags)) {
    assert.deepEqual(output.releaseStateAfter.tags[tag], sha, 'retained tag: ' + tag);
  }
  return output;
}

test('records and publishes only the generated verified ZIP', t => {
  const result = run(t, 'fresh');
  assert.equal(result.ok, true, result.error);
  assert.equal(result.tag, 'build-709.1');
  assert.equal(result.created, 1);
  assert.deepEqual(result.writes, ['create:build-709.1']);
  assert.match(result.notes, /Source ZIP SHA256: [a-f0-9]{64}/);
});

test('the real gh adapter publishes and rechecks through an offline generated CLI', t => {
  const result = run(t, 'transport');
  assert.equal(result.ok, true, result.error);
  assert.equal(result.tag, 'build-709.1');
  assert.equal(result.created, 1);
  assert.deepEqual(result.writes, ['create:build-709.1']);
  assert.ok(result.apiCalls.some(path => path.includes('/releases?per_page=100&page=1')));
  assert.ok(result.apiCalls.some(path => path.includes('/git/matching-refs/tags/build-709.1')));
});

test('a replacement workflow publishes after the last legacy release', t => {
  const result = run(t, 'workflow-counter-reset');
  assert.equal(result.ok, true, result.error);
  assert.equal(result.tag, 'build-709.1');
  assert.deepEqual(result.writes, ['create:build-709.1']);
  assert.deepEqual(result.remaining, ['build-709.1', 'build-697.1']);
});

for (const scenario of ['rerun', 'release-only-rerun']) {
  test(scenario + ' verifies the existing bytes and metadata without another publication', t => {
    const result = run(t, scenario);
    assert.equal(result.ok, true, result.error);
    assert.equal(result.tag, 'build-709.1');
    assert.equal(result.created, 1);
    assert.deepEqual(result.writes, []);
  });
}

test('rerunning verification gets a new attempt artifact/tag, then release reruns stay stable', t => {
  const result = run(t, 'verification-rerun');
  assert.equal(result.ok, true, result.error);
  assert.equal(result.tag, 'build-709.2');
  assert.equal(result.created, 2);
  assert.deepEqual(result.writes, ['create:build-709.2']);
  assert.deepEqual(result.remaining, ['build-709.2', 'build-709.1']);
});

for (const scenario of ['older-producer-rerun', 'older-existing-rerun',
  'numeric-newer-attempt', 'newer-run-release']) {
  test(scenario + ' preserves newer and older release state without mutation', t => {
    const result = run(t, scenario);
    assert.equal(result.ok, false);
    assert.match(result.error, /newer build release/);
    assert.deepEqual(result.writes, []);
    assert.equal(result.preserved, true);
    if (scenario === 'older-existing-rerun') {
      assert.deepEqual(result.remaining, ['build-709.2', 'build-709.1']);
    }
  });
}

test('publication preserves a newer release that appears after the initial listing', t => {
  const result = run(t, 'newer-after-create');
  assert.equal(result.ok, true, result.error);
  assert.deepEqual(result.writes, ['create:build-709.1']);
  assert.deepEqual(result.remaining, ['build-709.10', 'build-709.1']);
  assert.deepEqual(result.releaseStateAfter.items[0], result.concurrentRelease);
  assert.equal(result.releaseStateAfter.tags['build-709.10'], 'a'.repeat(40));
});

for (const scenario of [
  'tampered-zip', 'wrong-output-hash', 'wrong-output-size', 'wrong-source',
  'wrong-run', 'wrong-repository', 'future-attempt', 'malformed-manifest',
  'manual-event', 'pull-request-event', 'wrong-ref', 'stale-main',
  'edited-notes', 'wrong-asset-digest', 'missing-asset-digest', 'draft-collision',
  'tag-collision', 'read-failure',
]) {
  test(scenario + ' is rejected before any new GitHub mutation', t => {
    const result = run(t, scenario);
    assert.equal(result.ok, false);
    assert.ok(result.error);
    assert.deepEqual(result.writes, []);
  });
}

test('an uncertain create is read back and accepted only when complete, without a second create', t => {
  const result = run(t, 'uncertain-complete');
  assert.equal(result.ok, true, result.error);
  assert.equal(result.created, 1);
  assert.deepEqual(result.writes, ['create:build-709.1']);
});

test('an uncertain partial draft is preserved and fails instead of retrying or deleting it', t => {
  const result = run(t, 'uncertain-partial');
  assert.equal(result.ok, false);
  assert.match(result.error, /uncertain|draft|incomplete/i);
  assert.equal(result.created, 1);
  assert.deepEqual(result.writes, ['create:build-709.1']);
});

test('verified publication retains older builds, attempts, latest and manual release/tag state', t => {
  const result = run(t, 'prune');
  assert.equal(result.ok, true, result.error);
  assert.deepEqual(result.writes, ['create:build-709.1']);
  assert.deepEqual(result.remaining, [
    'build-709.1', 'build-708.1', 'build-708.9', 'latest', 'manual-owner-release',
  ]);
  assert.ok(result.remaining.includes('manual-owner-release'));
  assert.equal(result.releaseStateAfter.tags['manual-tag-only'], 'c'.repeat(40));
});
