import { execFileSync } from 'node:child_process';
import { realpathSync } from 'node:fs';
import { writeFile } from 'node:fs/promises';
import { resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { sourceHash } from './revision.mjs';

const source = new URL('./', import.meta.url);

export async function stampRevision(directory = source, checkout = source) {
  const git = args => execFileSync('git', args, { cwd: checkout, encoding: 'utf8' }).trim();
  const gitSHA = git(['rev-parse', 'HEAD']);
  if (!/^[a-f0-9]{40}$/.test(gitSHA)) throw new Error('Cannot stamp a service without a Git revision');
  const dirty = git(['status', '--porcelain', '--untracked-files=normal']) !== '';
  const stamp = { revision: `${gitSHA}${dirty ? '-dirty' : ''}`, gitSHA, dirty,
    sourceSHA256: await sourceHash(directory) };
  await writeFile(new URL('revision.json', directory), `${JSON.stringify(stamp, null, 2)}\n`);
  return stamp;
}

// A caller may name this file through a symlink such as macOS's /tmp, and Node
// may or may not resolve the main module's link itself (--preserve-symlinks-main),
// so both sides are compared as real paths or the stamp silently never runs.
const realHref = path => { try { return pathToFileURL(realpathSync(path)).href; } catch { return null; } };
const invokedAs = process.argv[1] ? realHref(process.argv[1]) : null;
if (invokedAs && realHref(fileURLToPath(import.meta.url)) === invokedAs) {
  const directory = process.argv[2] ? pathToFileURL(`${resolve(process.argv[2])}/`) : source;
  const stamp = await stampRevision(directory);
  process.stdout.write(`${stamp.revision} ${stamp.sourceSHA256}\n`);
}
