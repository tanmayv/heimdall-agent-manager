// T7 staged-changes footer (agent-panel-apply) in the real AgentChatPane, against
// tests/fixtures/agent-settings-panel.tsx (no network). Run with PLAYWRIGHT_MODULE
// pointing to a separately installed playwright module (PLAYWRIGHT_CHROMIUM: an
// already-downloaded browser when the pinned one is missing).
// Screenshots: $AGENT_PANEL_EVIDENCE/t7-<width>-<case>.png.
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
const height = { 1440: 1900, 1180: 1900, 390: 2900 };
const RESTART = 'Restarts the agent with a fresh session. The conversation stays.';
const MID_TURN = "It's mid-turn, so the restart waits for the turn to finish.";

// Each case: fixture state, what to change in the draft, then what the footer must say.
const cases = [
  ...[1440, 1180, 390].map((width) => ({ width, name: 'dirty', state: 'idle', edit: 'model',
    note: RESTART, primary: 'Apply and restart', restartNow: false })),
  { width: 1440, name: 'bridge-move', state: 'idle', edit: 'bridge',
    note: 'Restarts the agent on dawnstar, in /home/tanmay/heimdall-agent-manager, with a fresh session. The conversation stays.',
    primary: 'Apply and restart', restartNow: false },
  ...[1440, 1180, 390].map((width) => ({ width, name: 'mid-turn', state: 'running', edit: 'model',
    note: `${RESTART} ${MID_TURN}`, primary: 'Restart after this turn', restartNow: true })),
  ...[1440, 1180, 390].map((width) => ({ width, name: 'waiting', state: 'waiting', edit: null, status: 'Waiting for the turn to finish…', cancel: true, restartNow: false })),
  ...[1440, 390].map((width) => ({ width, name: 'still-waiting', state: 'still_waiting', edit: null, status: 'Still waiting', cancel: true, restartNow: true })),
  ...[1440, 1180, 390].map((width) => ({ width, name: 'acp-unavailable', state: 'idle', acp: 'adapter_missing', edit: 'acp',
    note: RESTART, primary: 'Apply and restart', disabled: true, blocked: 'Fix the connection above before applying.' })),
  ...[1440, 1180, 390].map((width) => ({ width, name: 'restarting', state: 'idle', edit: 'model', apply: true, status: 'Restarting the agent…' })),
  ...[1440, 1180, 390].map((width) => ({ width, name: 'stopped', state: 'stopped', edit: 'model',
    note: 'Starts the agent with these settings.', primary: 'Apply and start', restartNow: false })),
];

try {
  for (const c of cases) {
    const page = await browser.newPage({ viewport: { width: c.width, height: height[c.width] } });
    const label = `${c.width}/${c.name}`;
    page.on('pageerror', (e) => failures.push(`${label}: ${e.message}`));
    await page.route('**/*', (route) => route.request().url().startsWith(`http://127.0.0.1:${port}/`) ? route.continue() : route.abort());
    const q = (id) => page.locator(`[data-debug-id="${id}"]`);
    await page.goto(`http://127.0.0.1:${port}/tests/fixtures/agent-settings-panel.html?state=${c.state}&acp=${c.acp || 'ready'}`);
    await q('conversation-agent-settings-btn').waitFor();
    await q('conversation-agent-settings-btn').click();
    await q('agent-panel-model-provider-claude').waitFor();
    if (!c.edit && !c.status) assert.equal(await q('agent-panel-apply').count(), 0, `${label}: no footer without changes`);

    if (c.edit === 'model') await q('agent-panel-model-provider-codex').click();
    if (c.edit === 'bridge') {
      await q('agent-panel-bridge-option-brg_dawnstar').click();
      await q('agent-panel-model-provider-claude').waitFor();
    }
    if (c.edit === 'acp') await q('agent-panel-connection-acp').click();

    const footer = q('agent-panel-apply');
    await footer.waitFor();
    if (c.edit) {
      const chips = await q('agent-panel-apply-chip').allTextContents();
      assert.ok(chips.length >= 1, `${label}: one chip per change`);
      const arrow = await q('agent-panel-apply-chip').first().locator('[aria-hidden="true"]').textContent();
      assert.equal(arrow, '→');
      assert.equal(await q('agent-panel-apply-chip').first().locator('.sr-only').textContent(), 'to');
    }
    if (c.apply) {
      await q('agent-panel-apply-btn').click();
      await q('agent-panel-apply-status').waitFor();
      const posted = await page.evaluate(() => window.__reconfigurations);
      assert.equal(posted.length, 1, `${label}: one reconfiguration`);
      for (const key of ['bridge_id', 'project_id', 'provider', 'provider_profile', 'model', 'runtime_transport', 'permission_mode', 'expected_revision', 'idempotency_key', 'apply']) {
        assert.ok(key in posted[0], `${label}: request has ${key}`);
      }
      assert.equal(posted[0].apply, 'now');
      assert.equal(posted[0].expected_revision, 7);
      await page.locator('[data-debug-id="agent-panel-runtime-status"]', { hasText: 'Restarting' }).waitFor();
    }
    if (c.note) assert.equal((await q('agent-panel-apply-note').textContent()).trim(), c.note, `${label}: note`);
    if (c.status) assert.equal((await q('agent-panel-apply-status').textContent()).trim(), c.status, `${label}: status`);
    if (c.primary) {
      assert.equal((await q('agent-panel-apply-btn').textContent()).trim(), c.primary, `${label}: primary`);
      assert.equal(await q('agent-panel-apply-btn').isDisabled(), Boolean(c.disabled), `${label}: primary disabled`);
      assert.equal(await q('agent-panel-apply-discard').count(), 1, `${label}: Discard`);
    }
    if (c.blocked) assert.equal((await q('agent-panel-apply-blocked').textContent()).trim(), c.blocked);
    if (c.restartNow !== undefined) assert.equal(await q('agent-panel-apply-restart-now').count(), c.restartNow ? 1 : 0, `${label}: Restart now`);
    if (c.cancel) assert.equal(await q('agent-panel-apply-cancel').count(), 1, `${label}: Cancel`);
    assert.equal(await q('conversation-reconfigure-apply-btn').count(), 0, `${label}: no composer Apply with the flag on`);

    const m = await page.evaluate(() => {
      const buttons = [...document.querySelectorAll('[data-debug-id="agent-panel-apply"] button')].filter((el) => el.offsetParent !== null)
        .map((el) => { const r = el.getBoundingClientRect(); return { id: el.getAttribute('data-debug-id'), w: Math.round(r.width), h: Math.round(r.height) }; });
      return { viewport: window.innerWidth, document: document.documentElement.scrollWidth, buttons };
    });
    assert.ok(m.document <= m.viewport, `${label}: no horizontal scroll ${JSON.stringify(m)}`);
    if (c.width === 390) {
      for (const b of m.buttons) assert.ok(b.h >= 44, `${label}: ${b.id} >= 44px (${b.h})`);
      const discard = m.buttons.find((b) => b.id === 'agent-panel-apply-discard');
      const primary = m.buttons.find((b) => b.id === 'agent-panel-apply-btn');
      if (discard && primary) assert.ok(primary.w > discard.w * 1.7, `${label}: Apply 2 parts, Discard 1 (${primary.w} vs ${discard.w})`);
    }
    await footer.scrollIntoViewIfNeeded();
    await page.screenshot({ path: path.join(evidence, `t7-${c.width}-${c.name}.png`) });
    results.push({ case: label, viewport: m.viewport, document: m.document, buttons: m.buttons.map((b) => `${b.id}:${b.w}x${b.h}`).join(' ') });
    await page.close();
  }
} finally {
  await browser.close();
  await server.close();
}
assert.deepEqual(failures, []);
console.log(JSON.stringify(results, null, 2));
