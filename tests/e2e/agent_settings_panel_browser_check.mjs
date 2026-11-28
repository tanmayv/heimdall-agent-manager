// Run with PLAYWRIGHT_MODULE pointing to a separately installed playwright module.
// Starts an isolated Vite server and renders the real Workspace with the Agent
// settings panel against tests/fixtures/agent-settings-panel.tsx (no network).
// Screenshots: $AGENT_PANEL_EVIDENCE/<width>-<state>.png.
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';
import { createServer } from 'vite';
import viteConfig from '../../vite.config.js';

const require = createRequire(import.meta.url);
const { chromium } = require(process.env.PLAYWRIGHT_MODULE || 'playwright');
const root = fileURLToPath(new URL('../../', import.meta.url));
const evidence = process.env.AGENT_PANEL_EVIDENCE || await fs.mkdtemp(path.join(os.tmpdir(), 'agent-panel-'));
await fs.mkdir(evidence, { recursive: true });
const server = await createServer({
  ...viteConfig,
  configFile: false,
  root,
  cacheDir: path.join(evidence, '.vite'),
  server: { host: '127.0.0.1', port: 0, hmr: false },
});
await server.listen();
const port = server.httpServer.address().port;
// PLAYWRIGHT_CHROMIUM: an already-downloaded browser when the module's pinned one is missing.
const browser = await chromium.launch({ headless: true, args: ['--no-sandbox'], executablePath: process.env.PLAYWRIGHT_CHROMIUM || undefined });
const failures = [];
const results = [];
const expectedMode = { 1440: 'docked', 1024: 'drawer', 390: 'page' };
try {
  for (const width of [1440, 1024, 390]) {
    for (const state of ['running', 'stopped', 'restarting']) {
      const page = await browser.newPage({ viewport: { width, height: width === 390 ? 844 : 1000 } });
      page.on('pageerror', (e) => failures.push(`${width}/${state}: ${e.message}`));
      await page.route('**/*', (route) => route.request().url().startsWith(`http://127.0.0.1:${port}/`) ? route.continue() : route.abort());
      await page.routeWebSocket('**/*', (socket) => socket.close());
      const q = (id) => page.locator(`[data-debug-id="${id}"]`);
      await page.goto(`http://127.0.0.1:${port}/tests/fixtures/agent-settings-panel.html?state=${state}#/conversations/inst_coord`);
      await q('conversation-agent-settings-btn').waitFor();
      await q('conversation-agent-settings-btn').click();
      await q('agent-panel-runtime').waitFor();
      // Let the 200ms slide-in transition/animation settle before measuring bounding boxes.
      await page.waitForTimeout(260);
      const mode = await q('agent-panel').getAttribute('data-mode');
      assert.equal(mode, expectedMode[width], `${width}: mode`);
      const dismiss = q(mode === 'page' ? 'agent-panel-back' : 'agent-panel-close');
      const box = await dismiss.boundingBox();
      const toggle = await q('workspace-aux-toggle').boundingBox();
      assert.ok(box && toggle, `${width}: both controls have hit areas`);
      assert.ok(
        box.x + box.width <= toggle.x || toggle.x + toggle.width <= box.x ||
        box.y + box.height <= toggle.y || toggle.y + toggle.height <= box.y,
        `${width}: panel dismissal ${JSON.stringify(box)} overlaps side-panel toggle ${JSON.stringify(toggle)}`,
      );
      if (mode !== 'page') {
        const headerBox = await q('agent-panel-header').boundingBox();
        const subtitleBox = await q('agent-panel-subtitle').boundingBox();
        const runtimeBox = await q('agent-panel-runtime').boundingBox();
        assert.ok(headerBox, `${width}: panel header has bounding box`);
        assert.ok(subtitleBox && runtimeBox, `${width}: subtitle and runtime section have bounding boxes`);
        assert.equal(Math.round(headerBox.height), 48, `${width}: panel header height matches 48px top chrome`);
        assert.ok(subtitleBox.height >= 14, `${width}: subtitle should have visible height, got ${JSON.stringify(subtitleBox)}`);
        assert.ok(
          subtitleBox.y >= headerBox.y + headerBox.height - 1 && subtitleBox.y + subtitleBox.height <= runtimeBox.y + 1,
          `${width}: subtitle ${JSON.stringify(subtitleBox)} sits below header ${JSON.stringify(headerBox)} and above runtime ${JSON.stringify(runtimeBox)}`,
        );
        const closeCenterY = box.y + box.height / 2;
        const toggleCenterY = toggle.y + toggle.height / 2;
        assert.ok(
          Math.abs(closeCenterY - toggleCenterY) <= 2,
          `${width}: close center Y (${closeCenterY}) should align with sidebar toggle center Y (${toggleCenterY})`,
        );
      }
      if (mode === 'docked') await q('workspace-aux-toggle').click({ trial: true });
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
      results.push({ width, state, mode, dismiss: box, toggle, ...m });
      const focusedId = () => page.evaluate(() => document.activeElement?.getAttribute('data-debug-id'));
      await dismiss.click();
      await q('agent-panel').waitFor({ state: 'detached' });
      assert.equal(await focusedId(), 'conversation-agent-settings-btn', 'click restores focus to the gear');
      await q('conversation-agent-settings-btn').click();
      await q('agent-panel').waitFor();
      if (mode !== 'docked') {
        await page.keyboard.press('Escape');
        await q('agent-panel').waitFor({ state: 'detached' });
        assert.equal(await focusedId(), 'conversation-agent-settings-btn', 'Escape restores focus to the gear');
      } else {
        await page.keyboard.press('Escape');
        assert.equal(await q('agent-panel').count(), 1, 'Escape leaves the docked panel open');
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
console.log(JSON.stringify({ evidence, results }, null, 2));
