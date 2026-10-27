import { test, expect } from '@playwright/test';
import { open, rename, writeFile } from 'node:fs/promises';

const expectedBrowser = '153.0.8010.12';
const sessions = new Map();

test.beforeEach(async ({ browser, page }, info) => {
  if (Object.hasOwn(process.env, 'SIDEREAL_PERF_BASELINE')) {
    throw new Error('Performance threshold bypass is forbidden, including an empty value');
  }
  const phase = process.env.SIGIL_RENDER_PHASE;
  expect(['clean', 'profile']).toContain(phase);
  expect(browser.version()).toBe(expectedBrowser);
  const cdp = await page.context().newCDPSession(page);
  const state = { cdp, cpu: false, trace: false };
  sessions.set(info.testId, state);
  const version = await cdp.send('Browser.getVersion');
  expect(version.product.endsWith('/' + expectedBrowser)).toBe(true);
  await info.attach('hosted-render-identity', {
    body: JSON.stringify({
      phase, profiled: phase === 'profile', acceptanceEligible: phase === 'clean',
      browser: browser.version(), protocol: version,
      node: process.version, source: process.env.SIGIL_RENDER_SOURCE_SHA,
      diagnostic: process.env.SIGIL_RENDER_DIAGNOSTIC_SHA,
    }), contentType: 'application/json',
  });
  if (phase === 'clean') {
    await cdp.detach();
    sessions.delete(info.testId);
    return; // No profiler, trace or timing changes in clean executions.
  }
  // Profile-only timeline boundaries. The original probe still computes every
  // duration; marks occur after each captured value and never qualify acceptance.
  await page.addInitScript(() => {
    let values, reset = 0;
    Object.defineProperty(window, 'outputDurations', {
      configurable: true, enumerable: true,
      get: () => values,
      set: value => {
        values = value;
        const generation = ++reset;
        performance.mark('sigil-render-reset-' + generation);
        Object.defineProperty(value, 'push', {
          configurable: true,
          value(...items) {
            const count = Array.prototype.push.apply(this, items);
            performance.mark('sigil-render-sample-' + generation + '-' + count);
            return count;
          },
        });
      },
    });
  });
  await cdp.send('Profiler.enable');
  await cdp.send('Profiler.setSamplingInterval', { interval: 1000 });
  await cdp.send('Profiler.start');
  state.cpu = true;
  await cdp.send('Tracing.start', {
    categories: 'devtools.timeline,v8,blink.user_timing',
    transferMode: 'ReturnAsStream', streamFormat: 'json',
  });
  state.trace = true;
});

async function retainTrace(cdp, info) {
  let timer;
  let listener;
  const complete = new Promise((resolve, reject) => {
    listener = resolve;
    cdp.once('Tracing.tracingComplete', listener);
    timer = setTimeout(() => reject(new Error('Trace completion exceeded 30 seconds')), 30_000);
  });
  let event;
  try {
    await cdp.send('Tracing.end');
    event = await complete;
  } finally {
    clearTimeout(timer);
    cdp.off('Tracing.tracingComplete', listener);
  }
  if (!event.stream) throw new Error('Missing trace stream');
  const partial = info.outputPath('render.trace.partial.json');
  const final = info.outputPath('render.trace.json');
  const file = await open(partial, 'wx', 0o600);
  let bytes = 0;
  try {
    for (;;) {
      const chunk = await cdp.send('IO.read', { handle: event.stream, size: 1024 * 1024 });
      const data = Buffer.from(chunk.data, chunk.base64Encoded ? 'base64' : 'utf8');
      bytes += data.length;
      if (bytes > 64 * 1024 * 1024) throw new Error('Trace exceeded 64MiB; partial evidence retained');
      await file.writeFile(data);
      if (chunk.eof) break;
    }
  } finally {
    await file.close();
    await cdp.send('IO.close', { handle: event.stream });
  }
  if (!bytes) throw new Error('Empty trace stream');
  await rename(partial, final);
  await info.attach('render-layout-gc-trace', { path: final, contentType: 'application/json' });
  if (event.dataLossOccurred) throw new Error('Trace reported data loss; raw evidence retained');
}

test.afterEach(async ({}, info) => {
  const state = sessions.get(info.testId);
  if (!state) return;
  sessions.delete(info.testId);
  const failures = [];
  try {
    if (state.cpu) {
      try {
        const { profile } = await state.cdp.send('Profiler.stop');
        const bytes = Buffer.from(JSON.stringify(profile));
        if (!bytes.length) throw new Error('Empty CPU profile');
        if (bytes.length > 16 * 1024 * 1024) {
          await writeFile(info.outputPath('render.cpu.partial.json'), bytes.subarray(0, 16 * 1024 * 1024),
            { flag: 'wx', mode: 0o600 });
          throw new Error('CPU profile exceeded 16MiB; partial evidence retained');
        }
        const path = info.outputPath('render.cpuprofile');
        await writeFile(path, bytes, { flag: 'wx', mode: 0o600 });
        await info.attach('render-cpu-profile', { path, contentType: 'application/json' });
      } catch (error) { failures.push('CPU: ' + error.message); }
    }
    if (state.trace) {
      try { await retainTrace(state.cdp, info); }
      catch (error) { failures.push('Trace: ' + error.message); }
    }
  } finally {
    await state.cdp.detach().catch(error => failures.push('Detach: ' + error.message));
  }
  if (failures.length) throw new Error(failures.join('\n'));
});

// Register the original, source-pinned cases unchanged. The exact-title selector
// admits only the existing REA-1194 probe; the driver rejects any other case.
await import('../browser/web-find.spec.mjs');
