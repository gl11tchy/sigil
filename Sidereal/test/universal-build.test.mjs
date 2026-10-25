import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, copyFileSync, existsSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { spawnSync } from 'node:child_process';

const helper = new URL('../../Scripts/build-universal.sh', import.meta.url);
const swift = `#!/usr/bin/env python3
import json,os,sys
from pathlib import Path
a=sys.argv[1:]
with open(os.environ['SIGIL_TEST_TRACE'],'a') as f:f.write(json.dumps({'tool':'swift','args':a})+'\\n')
assert a[0]=='build' and a.count('--arch')==1
arch=a[a.index('--arch')+1]
assert arch in ['arm64','x86_64']
assert a[a.index('--build-system')+1]=='native'
assert a[a.index('-c')+1]=='release'
products=Path(a[a.index('--scratch-path')+1])/'products with spaces'
if '--show-bin-path' in a:
 print(products)
 sys.exit(0)
if os.environ.get('SIGIL_TEST_FAIL_ARCH')==arch:
 print('generated '+arch+' compile failure',file=sys.stderr)
 sys.exit(42)
products.mkdir(parents=True,exist_ok=True)
for name in ['Sigil','sigil-mcp']:
 if os.environ.get('SIGIL_TEST_MISSING_MCP')==arch and name=='sigil-mcp':continue
 value='arm64' if os.environ.get('SIGIL_TEST_WRONG_ARCH')==arch else arch
 p=products/name;p.write_text(json.dumps({'slices':[value],'product':name,'fresh':True}));p.chmod(0o755)
`;
const lipo = `#!/usr/bin/env python3
import json,os,sys
from pathlib import Path
a=sys.argv[1:]
with open(os.environ['SIGIL_TEST_TRACE'],'a') as f:f.write(json.dumps({'tool':'lipo','args':a})+'\\n')
if a[0]=='-verify_arch':
 data=json.loads(Path(a[-1]).read_text())
 sys.exit(0 if set(a[1:-1])<=set(data['slices']) else 1)
if a[0]=='-create':
 output=Path(a[a.index('-output')+1])
 if os.environ.get('SIGIL_TEST_MERGE_FAIL')==output.name:sys.exit(43)
 data=[json.loads(Path(p).read_text()) for p in a[1:a.index('-output')]]
 assert all(x['fresh'] for x in data)
 output.write_text(json.dumps({'slices':[s for x in data for s in x['slices']],'product':output.name}))
 output.chmod(0o755)
elif a[0]=='-info':print('generated lipo info: arm64 x86_64')
else:raise Exception('unexpected lipo args: '+str(a))
`;

function fixture(t) {
  assert.ok(existsSync(helper), 'native slice builder is missing');
  const directory = mkdtempSync(join(tmpdir(), 'sigil-universal-fixture-'));
  t.after(() => rmSync(directory, { recursive: true, force: true }));
  const root = join(directory, 'worktree with spaces');
  const scripts = join(root, 'Scripts');
  const tools = join(directory, 'fake tools');
  const output = join(directory, 'new products');
  for (const path of [scripts, tools, output]) mkdirSync(path, { recursive: true });
  copyFileSync(helper, join(scripts, 'build-universal.sh'));
  writeFileSync(join(tools, 'swift'), swift, { mode: 0o755 });
  writeFileSync(join(tools, 'lipo'), lipo, { mode: 0o755 });
  writeFileSync(join(tools, 'xcrun'), '#!/bin/bash\n[[ "$*" == "--find lipo" ]] || exit 1\nprintf "%s\\n" "$SIGIL_TEST_LIPO"\n', { mode: 0o755 });
  const trace = join(directory, 'trace.jsonl');
  // A failed compile must not make stale cached outputs eligible for packaging.
  for (const arch of ['arm64', 'x86_64']) {
    const products = join(root, '.build/universal', arch, 'products with spaces');
    mkdirSync(products, { recursive: true });
    for (const name of ['Sigil', 'sigil-mcp']) {
      writeFileSync(join(products, name), JSON.stringify({ slices: [arch], product: name, fresh: false }), { mode: 0o755 });
    }
  }
  return {
    root, output,
    run(extra = {}) {
      return spawnSync('bash', [join(scripts, 'build-universal.sh'), output], {
        cwd: directory, encoding: 'utf8', timeout: 10000,
        env: { ...process.env, PATH: tools + ':' + process.env.PATH, SIGIL_TEST_TRACE: trace, SIGIL_TEST_LIPO: join(tools, 'lipo'), ...extra },
      });
    },
    trace() { return readFileSync(trace, 'utf8').trim().split('\n').map(JSON.parse); },
  };
}

test('universal builder compiles isolated native slices and joins both executable products', t => {
  const f = fixture(t);
  const result = f.run();
  assert.equal(result.error, undefined);
  assert.equal(result.status, 0, result.stdout + result.stderr);
  for (const product of ['Sigil', 'sigil-mcp']) {
    assert.deepEqual(JSON.parse(readFileSync(join(f.output, product), 'utf8')).slices, ['arm64', 'x86_64']);
  }
  const commands = f.trace();
  const builds = commands.filter(x => x.tool === 'swift' && !x.args.includes('--show-bin-path'));
  assert.equal(builds.length, 2);
  assert.deepEqual(builds.map(x => x.args[x.args.indexOf('--arch') + 1]), ['arm64', 'x86_64']);
  const scratch = builds.map(x => x.args[x.args.indexOf('--scratch-path') + 1]);
  assert.notEqual(scratch[0], scratch[1]);
  assert.ok(scratch.every(x => x.startsWith(f.root + '/.build/universal/')));
  const verifies = commands.filter(x => x.tool === 'lipo' && x.args[0] === '-verify_arch');
  assert.equal(verifies.filter(x => x.args.includes('arm64') && x.args.includes('x86_64')).length, 2);
});

for (const [name, environment, expected] of [
  ['second architecture compile failure', { SIGIL_TEST_FAIL_ARCH: 'x86_64' }, 42],
  ['missing second-architecture MCP output', { SIGIL_TEST_MISSING_MCP: 'x86_64' }, 1],
  ['wrong architecture despite a successful compile', { SIGIL_TEST_WRONG_ARCH: 'x86_64' }, 1],
  ['MCP merge failure after Sigil merged', { SIGIL_TEST_MERGE_FAIL: 'sigil-mcp' }, 43],
]) {
  test('universal builder fails closed on ' + name, t => {
    const f = fixture(t);
    const result = f.run(environment);
    assert.equal(result.error, undefined);
    assert.equal(result.status, expected, result.stdout + result.stderr);
    assert.equal(existsSync(join(f.output, 'Sigil')), false);
    assert.equal(existsSync(join(f.output, 'sigil-mcp')), false);
    if (environment.SIGIL_TEST_FAIL_ARCH) {
      assert.match(result.stderr, /generated x86_64 compile failure/);
      for (const product of ['Sigil', 'sigil-mcp']) {
        assert.equal(existsSync(join(f.root, '.build/universal/x86_64/products with spaces', product)), false);
      }
    }
    if (environment.SIGIL_TEST_MISSING_MCP) assert.match(result.stderr, /missing sigil-mcp output \(x86_64\)/);
  });
}

test('universal builder does not overwrite existing products', t => {
  const f = fixture(t);
  const preserved = join(f.output, 'Sigil');
  writeFileSync(preserved, 'preserve me');
  const result = f.run();
  assert.equal(result.status, 1);
  assert.equal(readFileSync(preserved, 'utf8'), 'preserve me');
});

test('CI requires universal bundles before merge and keeps publication main-push-only', () => {
  const workflow = readFileSync(new URL('../../.github/workflows/ci.yml', import.meta.url), 'utf8');
  assert.doesNotMatch(workflow, /SIGIL_ALLOW_THIN/);
  const steps = workflow.split('\n      - name: ').slice(1);
  for (const name of ['Build release bundle', 'Smoke-launch release bundle', 'Zip the app']) {
    const step = steps.find(x => x.split('\n')[0] === name);
    assert.ok(step);
    assert.doesNotMatch(step, /\n        if:/);
  }
  const publish = steps.find(x => x.split('\n')[0] === 'Publish latest GitHub Release');
  assert.match(publish, /if: github.event_name == 'push' && github.ref == 'refs\/heads\/main'/);
  const build = steps.find(x => x.split('\n')[0] === 'Build release bundle');
  assert.match(build, /lipo -verify_arch arm64 x86_64 "dist\/Sigil.app\/Contents\/MacOS\/\$binary"/);
  assert.match(readFileSync(new URL('../../Scripts/build-app.sh', import.meta.url), 'utf8'), /"\$SCRIPT_DIR\/build-universal.sh"/);
});

test('architecture copy names both slices and separates Intel execution from CI verification', () => {
  for (const path of ['../../Site/public/index.html', '../../Site/public/docs/index.html']) {
    const html = readFileSync(new URL(path, import.meta.url), 'utf8');
    assert.match(html, /universal zip includes Apple silicon and Intel executables/);
    assert.doesNotMatch(html, /not a universal binary/);
  }
  const readme = readFileSync(new URL('../../README.md', import.meta.url), 'utf8');
  assert.match(readme, /execution on Intel hardware is not verified/);
  assert.match(readme, /CI does not enable this fallback/);
});
