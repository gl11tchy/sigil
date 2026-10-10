import { execFile } from 'node:child_process';
import { copyFile, lstat, mkdir, mkdtemp, readFile, rm } from 'node:fs/promises';
import { realpathSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { performance } from 'node:perf_hooks';
import { promisify } from 'node:util';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { runtimeFiles, loadRevision } from '../Sidereal/revision.mjs';
import { stampRevision } from '../Sidereal/stamp-revision.mjs';

const root = fileURLToPath(new URL('../', import.meta.url));
const run = promisify(execFile);
const services = { site: 'Site', sidereal: 'Sidereal' };

async function command(program, args, { cwd = root, timeout = 60000 } = {}) {
  try {
    return (await run(program, args, { cwd, timeout, encoding: 'utf8', maxBuffer: 2 * 1024 * 1024 })).stdout.trim();
  } catch {
    // CLI errors and output can contain credentials. Do not forward either.
    throw new Error(`${program} ${args[0]} failed or timed out`);
  }
}

async function runtimeInputs(service, checkout) {
  const source = join(checkout, services[service] || '');
  if (!services[service]) throw new Error('Unknown service bundle');
  const inputs = [];
  const allowed = new Set((await command('git', ['ls-files', '-z', '--cached', '--others', '--exclude-standard'], { cwd: checkout })).split('\0'));
  for (const file of await runtimeFiles(pathToFileURL(`${source}/`))) {
    // Both images receive the same loader. Site's checkout adapter is local only.
    const input = file === 'revision.mjs' ? join(checkout, 'Sidereal/revision.mjs') : join(source, file);
    const key = file === 'revision.mjs' ? 'Sidereal/revision.mjs' : `${services[service]}/${file}`;
    if (!allowed.has(key)) throw new Error('Ignored runtime input refused; no upload attempted');
    if (!(await lstat(input)).isFile()) throw new Error('Linked or special runtime input refused; no upload attempted');
    inputs.push({ file, input, data: await readFile(input) });
  }
  return inputs;
}

export async function stageBundle(service, directory, checkout = root) {
  const changed = () => new Error('Checkout runtime inputs changed during staging; no upload attempted');
  const before = await runtimeInputs(service, checkout);
  const target = pathToFileURL(`${directory}/`);
  for (const { file, input, data } of before) {
    const destination = join(directory, file);
    await mkdir(dirname(destination), { recursive: true });
    await copyFile(input, destination);
    if (!data.equals(await readFile(destination))) throw changed();
  }
  const stamp = await stampRevision(target, pathToFileURL(`${checkout}/`));
  await loadRevision(target, { required: true });
  // Re-enumerate untracked public inputs too. Byte comparisons catch persistent
  // edits within an already-dirty checkout; these reads are not a transaction.
  const after = await runtimeInputs(service, checkout);
  if (before.length !== after.length || before.some((value, index) => value.file !== after[index].file
    || !value.data.equals(after[index].data))) throw changed();
  return stamp;
}

function options(args, env) {
  const values = {
    project: env.SIGIL_DEPLOY_PROJECT_ID,
    environment: env.SIGIL_DEPLOY_ENVIRONMENT_ID,
    service: env.SIGIL_DEPLOY_SERVICE_ID,
    'health-url': env.SIGIL_DEPLOY_HEALTH_URL,
  };
  const seen = new Set();
  for (let i = 0; i < args.length; i++) {
    if (args[i] === '--detach') continue; // Upload is always detached, then verified.
    const key = args[i].slice(2);
    if (!args[i].startsWith('--') || !Object.hasOwn(values, key) || seen.has(key)
      || !args[i + 1] || args[i + 1].startsWith('--')) throw new Error('Expected unique --project, --environment, --service and --health-url options');
    seen.add(key);
    values[key] = args[++i];
  }
  for (const key of ['project', 'environment', 'service']) {
    if (typeof values[key] !== 'string' || !/^[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}$/i.test(values[key])) {
      throw new Error(`--${key} must be an explicit Railway ID`);
    }
    values[key] = values[key].toLowerCase();
  }
  let url;
  try { url = new URL(values['health-url']); } catch { throw new Error('--health-url must name the service /health'); }
  const loopback = ['localhost', '127.0.0.1', '[::1]'].includes(url.hostname);
  if (url.username || url.password || url.search || url.hash || url.pathname !== '/health'
    || !(url.protocol === 'https:' || (url.protocol === 'http:' && loopback && env.SIGIL_DEPLOY_ALLOW_LOOPBACK === '1'))
    || (!loopback && url.port)) throw new Error('Health URL must be credential-free HTTPS /health; HTTP loopback requires SIGIL_DEPLOY_ALLOW_LOOPBACK=1');
  const seconds = env.SIGIL_DEPLOY_TIMEOUT_SECONDS ?? '300';
  if (!/^\d+$/.test(seconds) || Number(seconds) < 1 || Number(seconds) > 300) throw new Error('SIGIL_DEPLOY_TIMEOUT_SECONDS must be 1 through 300');
  return { ...values, url, timeout: Number(seconds) * 1000 };
}

function verifyTarget(metadata, target) {
  const environments = metadata?.environments?.edges?.map(edge => edge.node);
  const environment = environments?.find(value => value?.id === target.environment);
  if (metadata?.id !== target.project || metadata.deletedAt || !environment || environment.deletedAt
    || environment.canAccess === false
    || !metadata.services?.edges?.some(edge => edge.node?.id === target.service)
    || !environment.serviceInstances?.edges?.some(edge => edge.node?.serviceId === target.service)) {
    throw new Error('Cannot verify the selected project/environment/service');
  }
}

async function matchesHealth(url, stamp, remaining) {
  try {
    const response = await fetch(url, {
      redirect: 'manual', headers: { 'Cache-Control': 'no-cache' },
      signal: AbortSignal.timeout(Math.max(1, Math.min(10000, Math.ceil(remaining)))),
    });
    if (response.status !== 200 || !response.headers.get('content-type')?.startsWith('application/json')) {
      await response.body?.cancel();
      return false;
    }
    const chunks = [];
    let size = 0;
    for await (const chunk of response.body) {
      size += chunk.length;
      if (size > 65536) return false;
      chunks.push(chunk);
    }
    const value = JSON.parse(Buffer.concat(chunks).toString('utf8'));
    return value?.status === 'ok' && ['revision', 'gitSHA', 'dirty', 'sourceSHA256'].every(key => value[key] === stamp[key]);
  } catch { return false; }
}

export async function deployService(service, args, env = process.env) {
  if (!services[service]) throw new Error('Unknown service bundle');
  const target = options(args, env);
  const git = args => command('git', args);
  await git(['fetch', 'origin', 'main']);
  const head = await git(['rev-parse', '--verify', 'HEAD']);
  const main = await git(['rev-parse', '--verify', 'origin/main']);
  if (main !== await git(['rev-parse', '--verify', 'FETCH_HEAD'])) throw new Error('origin/main did not match the fetched main; no upload attempted');
  const dirty = await git(['status', '--porcelain', '--untracked-files=normal']) !== '';
  if (dirty && env.SIGIL_ALLOW_DIRTY !== '1') throw new Error('Dirty checkout refused; explicit override is SIGIL_ALLOW_DIRTY=1');
  if (head !== main && env.SIGIL_ALLOW_NON_MAIN !== '1') throw new Error('HEAD is not origin/main; explicit override is SIGIL_ALLOW_NON_MAIN=1');
  const scope = ['--project', target.project, '--environment', target.environment];
  let metadata, domains;
  try {
    metadata = JSON.parse(await command('railway', ['status', ...scope, '--json']));
    verifyTarget(metadata, target);
    domains = JSON.parse(await command('railway', ['domain', 'list', ...scope, '--service', target.service, '--json']));
  } catch { throw new Error('Cannot verify selected Railway target and domains; no upload attempted'); }
  if (!Array.isArray(domains?.domains) || !domains.domains.some(value => value?.domain === target.url.host)) {
    throw new Error('Health destination does not belong to the selected service; no upload attempted');
  }

  const directory = await mkdtemp(join(tmpdir(), `sigil-${service}-deploy-`));
  try {
    const stamp = await stageBundle(service, directory);
    if (stamp.gitSHA !== head || stamp.dirty !== dirty || await git(['rev-parse', 'HEAD']) !== head
      || (await git(['status', '--porcelain', '--untracked-files=normal']) !== '') !== dirty) {
      throw new Error('Checkout changed during staging; no upload attempted');
    }
    process.stdout.write(`Staged source ${stamp.revision} ${stamp.sourceSHA256}\n`);
    await command('railway', ['up', directory, '--path-as-root', ...scope, '--service', target.service, '--detach', '--json'], { timeout: 300000 });
    const deadline = performance.now() + target.timeout;
    while (performance.now() < deadline) {
      if (await matchesHealth(target.url, stamp, deadline - performance.now()) && performance.now() < deadline) {
        process.stdout.write('Running source identity matches the upload; operational health is not verified.\n');
        return stamp;
      }
      const remaining = deadline - performance.now();
      if (remaining > 0) await new Promise(resolve => setTimeout(resolve, Math.min(1000, remaining)));
    }
    throw new Error('Uploaded once; running revision/source hash was not verified before the deadline. No second upload attempted');
  } finally { await rm(directory, { recursive: true, force: true }); }
}

const real = path => { try { return realpathSync(path); } catch { return null; } };
if (process.argv[1] && real(process.argv[1]) === real(fileURLToPath(import.meta.url))) {
  try { await deployService(process.argv[2], process.argv.slice(3)); }
  catch (error) { process.stderr.write(`deploy-${process.argv[2]}: ${error.message}\n`); process.exitCode = 1; }
}
