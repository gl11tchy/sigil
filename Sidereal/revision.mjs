import { createHash } from 'node:crypto';
import { readFile, readdir, lstat } from 'node:fs/promises';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = new URL('./', import.meta.url);

// One manifest drives staging and hashing, including the manifest and build recipe.
// The stamp is excluded because it contains this hash.
export async function runtimeFiles(directory = root) {
  const path = fileURLToPath(directory);
  if (!(await lstat(join(path, 'runtime-manifest.json'))).isFile()) throw new Error('Unsupported service runtime manifest');
  const manifest = JSON.parse(await readFile(join(path, 'runtime-manifest.json'), 'utf8'));
  const validNames = names => Array.isArray(names) && names.length > 0
    && names.every(name => typeof name === 'string' && /^[A-Za-z0-9][A-Za-z0-9._-]*$/.test(name))
    && new Set(names).size === names.length;
  if (manifest?.version !== 1 || !validNames(manifest.files) || !validNames(manifest.directories)
    || !['Dockerfile', 'package.json', 'package-lock.json', 'server.mjs', 'revision.mjs'].every(file => manifest.files.includes(file))
    || manifest.files.includes('revision.json') || manifest.files.includes('runtime-manifest.json')
    || manifest.directories.some(name => manifest.files.includes(name))) {
    throw new Error('Invalid service runtime manifest');
  }
  const files = ['runtime-manifest.json', ...manifest.files];
  async function visit(path) {
    for (const entry of await readdir(join(fileURLToPath(directory), path), { withFileTypes: true })) {
      const name = `${path}/${entry.name}`;
      if (entry.isDirectory()) await visit(name);
      else if (entry.isFile()) files.push(name);
      else throw new Error('Unsupported file in service bundle');
    }
  }
  for (const name of files) {
    if (!(await lstat(join(path, name))).isFile()) throw new Error('Unsupported file in service bundle');
  }
  for (const name of manifest.directories) {
    if (!(await lstat(join(path, name))).isDirectory()) throw new Error('Unsupported directory in service bundle');
    await visit(name);
  }
  return files.sort();
}

export async function sourceHash(directory = root) {
  const files = await runtimeFiles(directory);
  const hash = createHash('sha256');
  for (const file of files) {
    const data = await readFile(join(fileURLToPath(directory), file));
    hash.update(`${file}\0${data.length}\0`);
    hash.update(data);
  }
  return hash.digest('hex');
}

export async function loadRevision(directory = root, { required = false } = {}) {
  let value;
  try { value = JSON.parse(await readFile(new URL('revision.json', directory), 'utf8')); }
  catch (error) {
    if (error.code !== 'ENOENT') throw new Error('Invalid service revision stamp');
    if (required) throw new Error('Missing service revision stamp; stage and stamp before building');
    return { revision: 'development', gitSHA: null, dirty: null, sourceSHA256: null };
  }
  const { revision, gitSHA, dirty, sourceSHA256 } = value || {};
  if (typeof gitSHA !== 'string' || !/^[a-f0-9]{40}$/.test(gitSHA) || typeof dirty !== 'boolean'
    || revision !== `${gitSHA}${dirty ? '-dirty' : ''}`
    || typeof sourceSHA256 !== 'string' || !/^[a-f0-9]{64}$/.test(sourceSHA256)) {
    throw new Error('Invalid service revision stamp');
  }
  if (sourceSHA256 !== await sourceHash(directory)) throw new Error('Service revision stamp is stale; stamp again');
  return { revision, gitSHA, dirty, sourceSHA256 };
}
