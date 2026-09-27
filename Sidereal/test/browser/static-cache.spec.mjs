import { test, expect } from '@playwright/test';
import http from 'node:http';
import { once } from 'node:events';
import { tmpdir } from 'node:os';
import { pathToFileURL } from 'node:url';
import fs from 'node:fs';

// A private copy of the relay and its public files, so a new deployment can be simulated
// by editing files on disk. The real public directory is never edited.
function bundle() {
  const source = new URL('../../', import.meta.url);
  const root = pathToFileURL(`${fs.realpathSync(fs.mkdtempSync(`${tmpdir()}/sidereal-sw-`))}/`);
  for (const file of ['package.json', 'server.mjs', 'apns.mjs', 'revision.mjs']) {
    fs.copyFileSync(new URL(file, source), new URL(file, root));
  }
  fs.cpSync(new URL('public/', source), new URL('public/', root), { recursive: true });
  fs.cpSync(new URL('node_modules/ws/', source), new URL('node_modules/ws/', root), { recursive: true });
  return root;
}

async function start(root, port, log) {
  const { createRelay } = await import(new URL('server.mjs', root));
  const relay = createRelay({ publicOrigin: `http://127.0.0.1:${port}` });
  relay.server.on('request', (req, res) => res.on('finish', () => log.push([req.url, res.statusCode])));
  relay.server.listen(port, '127.0.0.1');
  await once(relay.server, 'listening');
  return relay;
}

const controlled = page => page.evaluate(async () => {
  await navigator.serviceWorker.ready;
  if (!navigator.serviceWorker.controller) {
    await new Promise(resolve => navigator.serviceWorker.addEventListener('controllerchange', resolve, { once: true }));
  }
});
const served = page => page.evaluate(() => fetch('/app.mjs').then(res => res.text()));

// A persistent profile, as on a phone: a fresh test context has no disk cache in WebKit.
test('return visits revalidate, a new deployment loads at once, and the offline copy still opens', async ({ playwright, browserName }) => {
  const root = bundle();
  const profile = fs.mkdtempSync(`${tmpdir()}/sidereal-sw-profile-`);
  const probe = http.createServer().listen(0, '127.0.0.1');
  await once(probe, 'listening');
  const port = probe.address().port;
  await new Promise(resolve => probe.close(resolve));
  const base = `http://127.0.0.1:${port}/`;
  const log = [];
  let relay = await start(root, port, log);
  const context = await playwright[browserName].launchPersistentContext(profile);
  try {
    const page = context.pages()[0] || await context.newPage();
    await page.goto(base);
    await expect(page.locator('#welcome')).toBeVisible();
    await controlled(page);

    await test.step('a return visit sends no unchanged file body again', async () => {
      log.length = 0;
      await page.goto(base);
      await expect(page.locator('#welcome')).toBeVisible();
      expect(log).toContainEqual(['/app.mjs', 304]);
      // WebKit always refetches the top-level page; every other file must revalidate.
      expect(log.filter(([path, status]) => status === 200 && path !== '/')).toEqual([]);
    });

    await test.step('with the relay unreachable the cached shell still opens', async () => {
      relay.close();
      await page.reload();
      await expect(page.locator('#welcome')).toBeVisible();
      expect(await served(page)).toContain('serviceWorker');
    });

    await test.step('a new deployment\'s app.mjs and sw.js are picked up on the next online visit', async () => {
      fs.appendFileSync(new URL('public/app.mjs', root), '\n// deployment two\n');
      const worker = new URL('public/sw.js', root);
      const script = fs.readFileSync(worker, 'utf8');
      fs.writeFileSync(worker, script.replace(/sidereal-shell-v\d+/, 'sidereal-shell-deployment-two'));
      relay = await start(root, port, log);
      log.length = 0;
      await page.goto(base);
      await expect(page.locator('#welcome')).toBeVisible();
      expect(log).toContainEqual(['/app.mjs', 200]);
      expect(await served(page)).toContain('// deployment two');
      await expect.poll(() => page.evaluate(() => caches.keys()), { timeout: 15000 }).toEqual(['sidereal-shell-deployment-two']);
      relay.close();
      await page.reload();
      await expect(page.locator('#welcome')).toBeVisible();
      expect(await served(page)).toContain('// deployment two');
    });
  } finally {
    await context.close();
    relay.close();
    fs.rmSync(profile, { recursive: true, force: true });
    fs.rmSync(root, { recursive: true, force: true });
  }
});
