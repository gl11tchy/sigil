import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, copyFileSync, existsSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { spawnSync } from 'node:child_process';

const helper = new URL('../../Scripts/build-universal.sh', import.meta.url);
// Shell fakes avoid fourteen Python startups per successful build. Their input
// grammar follows lipo's captured CI usage, including input-first -verify_arch.
const swift = `#!/bin/bash
set -euo pipefail
printf swift >> "$SIGIL_TEST_TRACE"
printf '\\t%s' "$@" >> "$SIGIL_TEST_TRACE"
printf '\\n' >> "$SIGIL_TEST_TRACE"
architecture=""; products=""; configuration=""; build_system=""; show=0
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    build) shift ;;
    -c) configuration="$2"; shift 2 ;;
    --build-system) build_system="$2"; shift 2 ;;
    --arch) [[ -z "$architecture" ]] || exit 1; architecture="$2"; shift 2 ;;
    --scratch-path) products="$2/products with spaces"; shift 2 ;;
    --show-bin-path) show=1; shift ;;
    *) exit 1 ;;
  esac
done
[[ "$configuration" == release && "$build_system" == native && -n "$products" ]]
[[ "$architecture" == arm64 || "$architecture" == x86_64 ]]
if [[ "$show" == 1 ]]; then printf '%s\\n' "$products"; exit 0; fi
if [[ "\${SIGIL_TEST_FAIL_ARCH:-}" == "$architecture" ]]; then
  printf 'generated %s compile failure\\n' "$architecture" >&2; exit 42
fi
mkdir -p "$products"
for product in Sigil sigil-mcp; do
  if [[ "\${SIGIL_TEST_MISSING_MCP:-}" == "$architecture" && "$product" == sigil-mcp ]]; then continue; fi
  slice="$architecture"
  if [[ "\${SIGIL_TEST_WRONG_ARCH:-}" == "$architecture" ]]; then slice=arm64; fi
  printf '%s\\nfresh\\n' "$slice" > "$products/$product"
  chmod +x "$products/$product"
done
`;
const lipo = `#!/bin/bash
set -euo pipefail
printf lipo >> "$SIGIL_TEST_TRACE"
printf '\\t%s' "$@" >> "$SIGIL_TEST_TRACE"
printf '\\n' >> "$SIGIL_TEST_TRACE"
case "$1" in
  -create)
    shift; slices=""
    while [[ "$1" != -output ]]; do
      { IFS= read -r part; IFS= read -r freshness; } < "$1"
      [[ "$freshness" == fresh ]]
      slices="\${slices:+$slices }$part"
      shift
    done
    output="$2"
    if [[ "\${SIGIL_TEST_MERGE_FAIL:-}" == "\${output##*/}" ]]; then exit 43; fi
    printf '%s\\nfresh\\n' "$slices" > "$output"
    chmod +x "$output"
    ;;
  -info) printf 'generated lipo info: arm64 x86_64\\n' ;;
  *)
    input="$1"; shift
    if [[ "$1" != -verify_arch ]]; then echo 'expected input before -verify_arch' >&2; exit 64; fi
    shift
    IFS= read -r slices < "$input"
    for architecture in "$@"; do [[ " $slices " == *" $architecture "* ]] || exit 1; done
    ;;
esac
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
  const trace = join(directory, 'trace.tsv');
  // A failed compile must not make stale cached outputs eligible for packaging.
  for (const arch of ['arm64', 'x86_64']) {
    const products = join(root, '.build/universal', arch, 'products with spaces');
    mkdirSync(products, { recursive: true });
    for (const name of ['Sigil', 'sigil-mcp']) {
      writeFileSync(join(products, name), arch + '\nstale\n', { mode: 0o755 });
    }
  }
  return {
    root, output, tools,
    run(extra = {}) {
      return spawnSync('bash', [join(scripts, 'build-universal.sh'), output], {
        cwd: directory, encoding: 'utf8', timeout: 10000,
        env: { ...process.env, PATH: tools + ':' + process.env.PATH, SIGIL_TEST_TRACE: trace, SIGIL_TEST_LIPO: join(tools, 'lipo'), ...extra },
      });
    },
    trace() {
      return readFileSync(trace, 'utf8').trimEnd().split('\n').map(line => {
        const [tool, ...args] = line.split('\t');
        return { tool, args };
      });
    },
  };
}

test('universal builder compiles isolated native slices and joins both executable products', t => {
  const f = fixture(t);
  const result = f.run();
  assert.equal(result.error, undefined);
  assert.equal(result.status, 0, result.stdout + result.stderr);
  for (const product of ['Sigil', 'sigil-mcp']) {
    assert.deepEqual(readFileSync(join(f.output, product), 'utf8').split('\n')[0].split(' '), ['arm64', 'x86_64']);
  }
  const commands = f.trace();
  const builds = commands.filter(x => x.tool === 'swift' && !x.args.includes('--show-bin-path'));
  assert.equal(builds.length, 2);
  assert.deepEqual(builds.map(x => x.args[x.args.indexOf('--arch') + 1]), ['arm64', 'x86_64']);
  const scratch = builds.map(x => x.args[x.args.indexOf('--scratch-path') + 1]);
  assert.notEqual(scratch[0], scratch[1]);
  assert.ok(scratch.every(x => x.startsWith(f.root + '/.build/universal/')));
  const verifies = commands.filter(x => x.tool === 'lipo' && x.args[1] === '-verify_arch');
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
  const release = workflow.split('\n  release:\n')[1];
  assert.match(release, /if: github.event_name == 'push' && github.ref == 'refs\/heads\/main'/);
  assert.match(release, /needs: verify/);
  const build = steps.find(x => x.split('\n')[0] === 'Build release bundle');
  assert.match(build, /lipo "dist\/Sigil.app\/Contents\/MacOS\/\$binary" -verify_arch arm64 x86_64/);
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

test('installer dirty input guard includes original and native-slice dependency checkouts', t => {
  const f = fixture(t);
  const installer = readFileSync(new URL('../../Scripts/install-latest.sh', import.meta.url), 'utf8');
  const guard = installer.match(/^build_inputs_differ_from_head\(\) \{[\s\S]*?^\}/m)?.[0];
  assert.ok(guard);
  // Execute only the pure guard with fake Git, never the installer/build path.
  writeFileSync(join(f.tools, 'git'), '#!/bin/bash\nif [[ -n "${SIGIL_TEST_DIRTY_CHECKOUT:-}" && "${2%/}" == "${SIGIL_TEST_DIRTY_CHECKOUT%/}" ]]; then\n  printf " M generated.swift\\n"\nfi\nexit 0\n', { mode: 0o755 });
  const checkouts = [
    join(f.root, '.build/checkouts/Legacy'),
    join(f.root, '.build/universal/arm64/checkouts/Arm'),
    join(f.root, '.build/universal/x86_64/checkouts/Intel'),
  ];
  for (const path of checkouts) mkdirSync(join(path, '.git'), { recursive: true });
  const results = [...checkouts, ''].map(dirty => {
    const result = spawnSync('bash', ['-c', guard + '\nif build_inputs_differ_from_head; then exit 0; else exit 1; fi'], {
      encoding: 'utf8', timeout: 10000,
      env: { ...process.env, ROOT: f.root, PATH: f.tools + ':' + process.env.PATH, SIGIL_TEST_DIRTY_CHECKOUT: dirty },
    });
    assert.equal(result.error, undefined);
    return result.status;
  });
  assert.deepEqual(results, [0, 0, 0, 1], 'dirty legacy/arm64/x86_64 rejected; clean state accepted');
});
