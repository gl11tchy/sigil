// Local adapter; staging copies the shared implementation as revision.mjs.
import { loadRevision as load, sourceHash as hash } from '../Sidereal/revision.mjs';
const root = new URL('./', import.meta.url);
export const loadRevision = (directory = root, options) => load(directory, options);
export const sourceHash = (directory = root) => hash(directory);
