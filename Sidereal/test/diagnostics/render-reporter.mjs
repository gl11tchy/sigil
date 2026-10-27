import { readFileSync, realpathSync, statSync, writeFileSync } from 'node:fs';
import { isAbsolute, relative, resolve } from 'node:path';

// A bounded report independent of console formatting. Missing reports fail the driver.
export default class RenderReporter {
  records = [];
  errors = [];
  onBegin(_config, suite) { this.discovered = suite.allTests().length; }
  onError(error) { this.errors.push(String(error.message).slice(0, 4000)); }
  onTestEnd(test, result) {
    const attachments = {};
    for (const name of ['400KB-direct-render-durations', 'hosted-render-identity']) {
      const matches = result.attachments.filter(item => item.name === name);
      if (matches.length !== 1) continue;
      const item = matches[0];
      try {
        let body = item.body;
        if (!body && item.path) {
          const root = realpathSync(resolve(process.env.SIGIL_RENDER_PHASE_DIR, 'test-results'));
          const path = realpathSync(item.path), local = relative(root, path);
          if (local.startsWith('..') || isAbsolute(local) || statSync(path).size > 65536) {
            throw new Error('Attachment outside generated results or oversized');
          }
          body = readFileSync(path);
        }
        if (!body || body.length > 65536) throw new Error('Missing or oversized attachment');
        attachments[name] = JSON.parse(body.toString('utf8'));
      } catch (error) { this.errors.push(name + ': ' + error.message); }
    }
    this.records.push({
      title: test.title, location: test.location, project: test.parent.project()?.name,
      repeat: test.repeatEachIndex, retry: result.retry, expected: test.expectedStatus,
      status: result.status, duration: result.duration,
      errors: result.errors.map(error => String(error.message).slice(0, 4000)), attachments,
      artifacts: result.attachments
        .filter(item => ['render-cpu-profile', 'render-layout-gc-trace'].includes(item.name))
        .map(item => ({ name: item.name, path: item.path })),
    });
  }
  onEnd(result) {
    const root = process.env.SIGIL_RENDER_PHASE_DIR;
    writeFileSync(resolve(root, 'cases.json'), JSON.stringify({
      schema: 1, phase: process.env.SIGIL_RENDER_PHASE,
      status: result.status, discovered: this.discovered, errors: this.errors, records: this.records,
    }, null, 2) + '\n', { flag: 'wx', mode: 0o600 });
  }
}
