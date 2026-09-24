import { execFileSync } from 'node:child_process';
import { realpathSync } from 'node:fs';
import { writeFile } from 'node:fs/promises';
import { resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import { sourceHash } from './revision.mjs';

const source = new URL('./', import.meta.url);

export async function stampRevision(directory = source, checkout = source) {
  const git = args => execFileSync('git', args, { cwd: checkout, encoding: 'utf8' }).trim();
  const gitSHA = git(['rev-parse', 'HEAD']);
  if (!/^[a-f0-9]{40}$/.test(gitSHA)) throw new Error('Cannot stamp Sidereal without a Git revision');
  const dirty = git(['status', '--porcelain', '--untracked-files=normal']) !== '';
  const stamp = { revision: `${gitSHA}${dirty ? '-dirty' : ''}`, gitSHA, dirty,
    sourceSHA256: await sourceHash(directory) };
  await writeFile(new URL('revision.json', directory), `${JSON.stringify(stamp, null, 2)}\n`);
  return stamp;
}

// Node resolves the running file's real path; a caller may name it through a
// symlink such as macOS's /tmp, so compare real paths or the stamp silently never runs.
const invokedAs = process.argv[1] && (() => { try { return pathToFileURL(realpathSync(process.argv[1])).href; } catch { return null; } })();
if (invokedAs && import.meta.url === invokedAs) {
  const directory = process.argv[2] ? pathToFileURL(`${resolve(process.argv[2])}/`) : source;
  const stamp = await stampRevision(directory);
  process.stdout.write(`${stamp.revision} ${stamp.sourceSHA256}\n`);
}
