import { defineConfig } from '@playwright/test';
import normal from './playwright.config.mjs';
import { resolve } from 'node:path';

if (Object.hasOwn(process.env, 'SIDEREAL_PERF_BASELINE') ||
    Object.hasOwn(process.env, 'SIDEREAL_TEST_ORIGIN')) {
  throw new Error('Threshold bypass and external test origins are forbidden');
}
const phase = process.env.SIGIL_RENDER_PHASE;
if (!['clean', 'profile'].includes(phase)) throw new Error('Invalid diagnostic phase');
const root = resolve(process.env.SIGIL_RENDER_PHASE_DIR || '');
if (root !== process.env.SIGIL_RENDER_PHASE_DIR) throw new Error('Missing canonical phase directory');

export default defineConfig({
  ...normal,
  testDir: './test/diagnostics',
  testMatch: 'hosted-render.spec.mjs',
  outputDir: resolve(root, 'test-results'),
  workers: 1,
  retries: 0,
  forbidOnly: true,
  globalTimeout: phase === 'clean' ? 420_000 : 180_000,
  preserveOutput: 'always',
  use: { ...normal.use, trace: 'off' },
  reporter: [['line'], ['./test/diagnostics/render-reporter.mjs']],
});
