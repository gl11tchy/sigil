import { defineConfig } from '@playwright/test';
export default defineConfig({
  testDir: './test/browser', fullyParallel: false, workers: 1,
  use: { baseURL: process.env.SIDEREAL_TEST_ORIGIN || 'http://localhost:3099', screenshot: 'only-on-failure' },
  projects: [{ name: 'chromium', use: { browserName: 'chromium' } }, { name: 'webkit', use: { browserName: 'webkit' } }],
  webServer: process.env.SIDEREAL_TEST_ORIGIN ? undefined : {
    command: 'node server.mjs', url: 'http://localhost:3099/health',
    env: { PUBLIC_ORIGIN: 'http://localhost:3099', PORT: '3099' }, reuseExistingServer: false,
  },
});
