// Run with PLAYWRIGHT_MODULE pointing to a separately installed playwright module.
// Starts an isolated Vite server and renders the real AgentChatPane with the Agent
// settings panel against tests/fixtures/agent-settings-panel.tsx (no network).
// Screenshots: $AGENT_PANEL_EVIDENCE/<width>-<state>.png.
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';
import { createServer } from 'vite';

const require = createRequire(import.meta.url);
const { chromium } = require(process.env.PLAYWRIGHT_MODULE || 'playwright');
const root = fileURLToPath(new URL('../../', import.meta.url));
const evidence = process.env.AGENT_PANEL_EVIDENCE || '/tmp/agent-panel-evidence';
await fs.mkdir(evidence, { recursive: true });
const server = await createServer({ root, server: { host: '127.0.0.1', port: 0, strictPort: false } });
await server.listen();
const port = server.httpServer.address().port;
// PLAYWRIGHT_CHROMIUM: an already-downloaded browser when the module's pinned one is missing.
const browser = await chromium.launch({ headless: true, args: ['--no-sandbox'], executablePath: process.env.PLAYWRIGHT_CHROMIUM || undefined });
const failures = [];
const results = [];
const expectedMode = { 1440: 'docked', 1180: 'drawer', 390: 'page' };
try {
  for (const width of [1440, 1180, 390]) {
    for (const state of ['running', 'stopped', 'restarting']) {
      const page = await browser.newPage({ viewport: { width, height: width === 390 ? 844 : 1000 } });
      page.on('pageerror', (e) => failures.push(`${width}/${state}: ${e.message}`));
      await page.route('**/*', (route) => route.request().url().startsWith(`http://127.0.0.1:${port}/`) ? route.continue() : route.abort());
      const q = (id) => page.locator(`[data-debug-id="${id}"]`);
      await page.goto(`http://127.0.0.1:${port}/tests/fixtures/agent-settings-panel.html?state=${state}`);
      await q('conversation-agent-settings-btn').waitFor();
      await q('conversation-agent-settings-btn').click();
      await q('agent-panel-runtime').waitFor();
      const mode = await q('agent-panel').getAttribute('data-mode');
      assert.equal(mode, expectedMode[width], `${width}: mode`);
      const heading = await page.evaluate(() => document.activeElement?.textContent);
      assert.equal(heading, width === 390 ? 'Agent settings' : 'Agent', 'focus on the panel heading');
      const pill = (await q('agent-panel-runtime-status').textContent()).trim();
      assert.equal(pill, { running: 'Running', stopped: 'Stopped', restarting: 'Restarting' }[state]);
      const m = await page.evaluate(() => {
        const panel = document.querySelector('[data-debug-id="agent-panel"]').getBoundingClientRect();
        const small = width => [...document.querySelectorAll('[data-debug-id="agent-panel"] button')]
          .filter((b) => b.offsetParent !== null).map((b) => [b.getAttribute('data-debug-id') || b.textContent.trim(), Math.round(b.getBoundingClientRect().height)
            // The bypass switch's hit target is its ::after, 8px past the track on every side.
            + (b.getAttribute('role') === 'switch' && getComputedStyle(b, '::after').position === 'absolute' ? 16 : 0)])
          .filter(([, h]) => h < 44);
        return { viewport: window.innerWidth, document: document.documentElement.scrollWidth, panelWidth: Math.round(panel.width), small: small() };
      });
      assert.ok(m.document <= m.viewport, `no horizontal scroll ${JSON.stringify(m)}`);
      if (mode === 'docked') assert.ok(m.panelWidth >= 400 && m.panelWidth <= 440, `docked width ${m.panelWidth}`);
      if (mode === 'page') {
        assert.equal(m.panelWidth, width);
        const runtimeSmall = m.small.filter(([id]) => String(id).startsWith('agent-panel'));
        assert.deepEqual(runtimeSmall, [], 'panel controls are >= 44px on mobile');
      }
      await page.screenshot({ path: path.join(evidence, `${width}-${state}.png`) });
      results.push({ width, state, mode, ...m });
      if (mode !== 'docked') {
        await page.keyboard.press('Escape');
        await q('agent-panel').waitFor({ state: 'detached' });
        assert.equal(await page.evaluate(() => document.activeElement?.getAttribute('data-debug-id')), 'conversation-agent-settings-btn', 'focus returns to the gear');
      }
      if (width === 1440 && state === 'running') {
        await q('agent-panel-runtime-more').click();
        await q('agent-panel-runtime-force-stop').click();
        await q('agent-panel-force-stop-dialog').waitFor();
        await page.screenshot({ path: path.join(evidence, `${width}-force-stop-confirm.png`) });
      }
      await page.close();
    }
  }
} finally {
  await browser.close();
  await server.close();
}
assert.deepEqual(failures, []);
console.log(JSON.stringify(results, null, 2));
