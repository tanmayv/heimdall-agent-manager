// T6 sections (Runs on, Model, Connection, Permissions) in the real AgentChatPane,
// against tests/fixtures/agent-settings-panel.tsx (no network). Run with
// PLAYWRIGHT_MODULE pointing to a separately installed playwright module
// (PLAYWRIGHT_CHROMIUM: an already-downloaded browser when the pinned one is missing).
// Screenshots: $AGENT_PANEL_EVIDENCE/t6-<width>-<case>.png. Viewports are tall so the
// whole panel is in one image, like the design artboards.
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
const browser = await chromium.launch({ headless: true, args: ['--no-sandbox'], executablePath: process.env.PLAYWRIGHT_CHROMIUM || undefined });
const failures = [];
const results = [];
const height = { 1440: 1900, 1180: 1900, 390: 2700 };
const ACP_TEXT = {
  no_recipe: 'Claude Code has no ACP support yet. Use PTY.',
  unsupported_bridge: 'riverwood runs a bridge version without ACP support. Update it to the latest release.',
  adapter_missing: "The Claude Code ACP adapter isn't installed on riverwood.",
  adapter_outdated: "The Claude Code ACP adapter isn't installed on riverwood.",
  adapter_missing_node: "The Claude Code ACP adapter isn't installed on riverwood.",
  adapter_error: "The Claude Code ACP adapter isn't installed on riverwood.",
  not_checked: "ACP hasn't been checked on riverwood.",
};
const ACP_ACTION = { unsupported_bridge: 'Update bridge', adapter_missing: 'Install adapter', adapter_outdated: 'Install adapter',
  adapter_missing_node: 'Install adapter', adapter_error: 'Install adapter', not_checked: 'Check now' };

const cases = [
  ...[1440, 1180, 390].map((width) => ({ width, name: 'normal', acp: 'ready', pickAcp: false })),
  ...Object.keys(ACP_TEXT).map((reason) => ({ width: 1440, name: `acp-${reason}`, acp: reason, pickAcp: true })),
  ...[1180, 390].map((width) => ({ width, name: 'acp-adapter_missing', acp: 'adapter_missing', pickAcp: true })),
  ...[1440, 1180, 390].map((width) => ({ width, name: 'acp-installing', acp: 'installing', pickAcp: true })),
];

try {
  for (const c of cases) {
    const page = await browser.newPage({ viewport: { width: c.width, height: height[c.width] } });
    const label = `${c.width}/${c.name}`;
    page.on('pageerror', (e) => failures.push(`${label}: ${e.message}`));
    await page.route('**/*', (route) => route.request().url().startsWith(`http://127.0.0.1:${port}/`) ? route.continue() : route.abort());
    const q = (id) => page.locator(`[data-debug-id="${id}"]`);
    await page.goto(`http://127.0.0.1:${port}/tests/fixtures/agent-settings-panel.html?state=running&acp=${c.acp}`);
    await q('conversation-agent-settings-btn').waitFor();
    await q('conversation-agent-settings-btn').click();
    for (const id of ['agent-panel-bridge', 'agent-panel-model', 'agent-panel-connection', 'agent-panel-permissions']) await q(id).waitFor();
    await q('agent-panel-model-provider-claude').waitFor();

    // Every list is a radiogroup of role=radio with aria-checked; one checked per group.
    const groups = await page.evaluate(() => [...document.querySelectorAll('[data-debug-id="agent-panel"] [role="radiogroup"]')].map((g) => ({
      radios: g.querySelectorAll('[role="radio"]').length,
      checked: g.querySelectorAll('[role="radio"][aria-checked="true"]').length,
      missing: [...g.querySelectorAll('[role="radio"]')].filter((r) => !['true', 'false'].includes(r.getAttribute('aria-checked'))).length,
    })));
    assert.equal(groups.length, 3, `${label}: bridge, provider and connection radiogroups`);
    for (const g of groups) assert.ok(g.radios > 1 && g.checked === 1 && g.missing === 0, `${label}: ${JSON.stringify(g)}`);
    assert.equal((await q('agent-panel-bridge-count').textContent()).trim(), '3 of 5 connected');
    assert.equal(await q('agent-panel-bridge-option-brg_macbook').getAttribute('aria-disabled'), 'true');
    assert.match(await q('agent-panel-model-provider-gemini').textContent(), /Not installed on riverwood/);
    assert.equal(await q('agent-panel-permissions-toggle').getAttribute('role'), 'switch');

    if (c.pickAcp) {
      await q('agent-panel-connection-acp').click();
      assert.equal(await q('agent-panel-connection-acp').getAttribute('aria-checked'), 'true');
      if (c.acp === 'installing') {
        await q('agent-panel-connection-installing').waitFor();
        assert.match(await q('agent-panel-connection-installing').textContent(), /Installing the ACP adapter on riverwood…/);
      } else {
        const alert = q('agent-panel-connection-acp-alert');
        await alert.waitFor();
        assert.equal(await alert.getAttribute('role'), 'alert');
        assert.match(await alert.textContent(), new RegExp(ACP_TEXT[c.acp].replace(/[.*+?^${}()|[\]\\]/g, '\\$&')));
        const actions = await alert.locator('button').allTextContents();
        assert.deepEqual(actions.map((t) => t.trim()), ACP_ACTION[c.acp] ? [ACP_ACTION[c.acp]] : [], `${label}: fix action`);
      }
      assert.equal((await q('agent-panel-apply-blocked').textContent()).trim(), 'Fix the connection above before applying.');
      assert.equal(await q('agent-panel-legacy-apply-btn').isDisabled(), true, `${label}: Apply disabled`);
      assert.equal(await q('conversation-reconfigure-apply-btn').count(), 0, `${label}: the panel owns Apply (no composer Apply)`);
    }

    const m = await page.evaluate(() => {
      const panel = document.querySelector('[data-debug-id="agent-panel"]').getBoundingClientRect();
      const controls = [...document.querySelectorAll('[data-debug-id="agent-panel"] button, [data-debug-id="agent-panel"] [role="radio"], [data-debug-id="agent-panel"] a')]
        .filter((el) => el.offsetParent !== null)
        .map((el) => {
          const r = el.getBoundingClientRect();
          // The bypass switch's hit target is its ::after (8px past the track on every side).
          const after = getComputedStyle(el, '::after');
          const extra = el.getAttribute('role') === 'switch' && after.position === 'absolute' ? 16 : 0;
          return [el.getAttribute('data-debug-id') || el.textContent.trim().slice(0, 30), Math.round(r.height) + extra];
        });
      return { viewport: window.innerWidth, document: document.documentElement.scrollWidth, panelWidth: Math.round(panel.width), small: controls.filter(([, h]) => h < 44) };
    });
    assert.ok(m.document <= m.viewport, `${label}: no horizontal scroll ${JSON.stringify(m)}`);
    if (c.width === 390) assert.deepEqual(m.small, [], `${label}: panel controls >= 44px on mobile`);
    await page.screenshot({ path: path.join(evidence, `t6-${c.width}-${c.name}.png`) });
    results.push({ case: label, groups: groups.length, ...m, small: m.small.length });
    await page.close();
  }
} finally {
  await browser.close();
  await server.close();
}
assert.deepEqual(failures, []);
console.log(JSON.stringify(results, null, 2));
