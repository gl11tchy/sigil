import { createHash } from 'node:crypto';
import { readFile, readdir } from 'node:fs/promises';

const root = new URL('./', import.meta.url);

// Runtime files and the build recipe copied into the image. Excludes the stamp itself.
export async function sourceHash(directory = root) {
  const files = ['Dockerfile', 'package.json', 'package-lock.json', 'server.mjs', 'revision.mjs'];
  async function visit(path) {
    for (const entry of await readdir(new URL(path, directory), { withFileTypes: true })) {
      const name = `${path}${entry.name}`;
      if (entry.isDirectory()) await visit(`${name}/`);
      else if (entry.isFile()) files.push(name);
      else throw new Error('Unsupported file in Sidereal bundle');
    }
  }
  await visit('public/');
  const hash = createHash('sha256');
  for (const file of files.sort()) {
    const data = await readFile(new URL(file, directory));
    hash.update(`${file}\0${data.length}\0`);
    hash.update(data);
  }
  return hash.digest('hex');
}

export async function loadRevision(directory = root, { required = false } = {}) {
  let value;
  try { value = JSON.parse(await readFile(new URL('revision.json', directory), 'utf8')); }
  catch (error) {
    if (error.code !== 'ENOENT') throw new Error('Invalid Sidereal revision stamp');
    if (required) throw new Error('Missing Sidereal revision stamp; run npm run stamp before building');
    return { revision: 'development', gitSHA: null, dirty: null, sourceSHA256: null };
  }
  const { revision, gitSHA, dirty, sourceSHA256 } = value || {};
  if (typeof gitSHA !== 'string' || !/^[a-f0-9]{40}$/.test(gitSHA) || typeof dirty !== 'boolean'
    || revision !== `${gitSHA}${dirty ? '-dirty' : ''}`
    || typeof sourceSHA256 !== 'string' || !/^[a-f0-9]{64}$/.test(sourceSHA256)) {
    throw new Error('Invalid Sidereal revision stamp');
  }
  if (sourceSHA256 !== await sourceHash(directory)) throw new Error('Sidereal revision stamp is stale; run npm run stamp again');
  return { revision, gitSHA, dirty, sourceSHA256 };
}
