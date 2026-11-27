// T8 integration QA for the Agent settings panel: the 6x3 screenshot matrix
// (normal, dirty, acp-unavailable, restarting, stopped, mobile) x (1440, 1180, 390)
// plus the accessibility walk and the flag-off path (the old modal), all in the real
// AgentChatPane against tests/fixtures/agent-settings-panel.tsx (no network).
// "mobile" is the full-length panel capture (the whole scrolled panel with staged
// changes and the sticky footer, as in the mobile design PNGs); at 390 it is the
// full-screen page.
// Run with PLAYWRIGHT_MODULE pointing to a separately installed playwright module
// (PLAYWRIGHT_CHROMIUM: an already-downloaded browser when the pinned one is missing).
// Screenshots: $AGENT_PANEL_EVIDENCE/t8-<width>-<state>.png.
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
const WIDTHS = [1440, 1180, 390];
const MODE = { 1440: 'docked', 1180: 'drawer', 390: 'page' };
const SECTIONS = ['agent-panel', 'agent-panel-runtime', 'agent-panel-bridge', 'agent-panel-model', 'agent-panel-connection', 'agent-panel-permissions'];
const failures = [];
const checks = [];
const check = (label, ok, detail = '') => {
  checks.push({ label, ok: Boolean(ok), detail });
  if (!ok) failures.push(`${label}${detail ? `: ${detail}` : ''}`);
};

// state: fixture params, edits to stage, and whether to Apply.
const STATES = {
  normal: { q: 'state=running' },
  dirty: { q: 'state=idle', edit: ['bridge', 'model', 'acp', 'bypass'] },
  'acp-unavailable': { q: 'state=idle&acp=adapter_missing', edit: ['acp'] },
  restarting: { q: 'state=idle', edit: ['model'], apply: true },
  stopped: { q: 'state=stopped', edit: ['model'] },
  mobile: { q: 'state=running&acp=adapter_missing', edit: ['bridge', 'acp', 'bypass'], full: true },
};

async function open(page, query) {
  const q = (id) => page.locator(`[data-debug-id="${id}"]`);
  await page.goto(`http://127.0.0.1:${port}/tests/fixtures/agent-settings-panel.html?${query}`);
  await q('conversation-agent-settings-btn').waitFor();
  await q('conversation-agent-settings-btn').click();
  await q('agent-panel-model-provider-claude').waitFor();
  return q;
}

async function stage(page, q, edits) {
  for (const e of edits) {
    if (e === 'bridge') {
      await q('agent-panel-bridge-option-brg_dawnstar').click();
      await q('agent-panel-model-provider-claude').waitFor();
    }
    if (e === 'model') await q('agent-panel-model-provider-codex').click();
    if (e === 'acp') await q('agent-panel-connection-acp').click();
    if (e === 'bypass') await page.locator('[data-debug-id="agent-panel-permissions"] [role="switch"]').click();
  }
}

function newPage(width, label, height) {
  return browser.newPage({ viewport: { width, height: height ?? (width === 390 ? 844 : 1000) } }).then(async (page) => {
    page.on('pageerror', (e) => failures.push(`${label}: ${e.message}`));
    await page.route('**/*', (route) => route.request().url().startsWith(`http://127.0.0.1:${port}/`) ? route.continue() : route.abort());
    return page;
  });
}

try {
  // 1) Screenshot matrix + per-cell layout checks.
  for (const width of WIDTHS) {
    for (const [name, s] of Object.entries(STATES)) {
      const label = `${width}/${name}`;
      const page = await newPage(width, label);
      const q = await open(page, s.q);
      check(`${label} mode`, (await q('agent-panel').getAttribute('data-mode')) === MODE[width]);
      if (s.edit) await stage(page, q, s.edit);
      if (s.apply) {
        await q('agent-panel-apply-btn').click();
        await page.locator('[data-debug-id="agent-panel-runtime-status"]', { hasText: 'Restarting' }).waitFor();
      }
      if (name === 'acp-unavailable' || name === 'mobile') {
        const alert = q('agent-panel-connection-acp-alert');
        await alert.waitFor({ timeout: 5000 }).catch(() => {});
        check(`${label} ACP alert role=alert`, (await alert.getAttribute('role')) === 'alert');
        check(`${label} Apply disabled`, await q('agent-panel-apply-btn').isDisabled());
        // Picking ACP brings the alert (reason + fix) fully into view above the sticky footer.
        await page.waitForTimeout(300);
        const r = await page.evaluate(() => {
          const a = document.querySelector('[data-debug-id="agent-panel-connection-acp-alert"]').getBoundingClientRect();
          const f = document.querySelector('[data-debug-id="agent-panel-apply"]').getBoundingClientRect();
          const h = document.querySelector('[data-debug-id="agent-panel"] header, [data-debug-id="agent-panel"] > :first-child').getBoundingClientRect();
          return { alertTop: Math.round(a.top), alertBottom: Math.round(a.bottom), footerTop: Math.round(f.top), headerBottom: Math.round(h.bottom) };
        });
        check(`${label} ACP alert fully visible above the footer`, r.alertBottom <= r.footerTop && r.alertTop >= r.headerBottom, JSON.stringify(r));
      }
      if (name === 'restarting') {
        // The status lives in the Runtime card: capture the panel scrolled to the top.
        await page.evaluate(() => {
          const scroller = [...document.querySelectorAll('[data-debug-id="agent-panel"] *')].find((el) => /(auto|scroll)/.test(getComputedStyle(el).overflowY));
          if (scroller) scroller.scrollTop = 0;
        });
        check(`${label} Runtime pill in view`, await q('agent-panel-runtime-status').isVisible() && await page.evaluate(() => {
          const p = document.querySelector('[data-debug-id="agent-panel-runtime-status"]').getBoundingClientRect();
          return p.top >= 0 && p.bottom <= window.innerHeight;
        }));
      }
      if (name === 'stopped') check(`${label} Apply and start`, (await q('agent-panel-apply-btn').textContent()).trim() === 'Apply and start');
      if (name === 'restarting') check(`${label} pill Restarting`, (await q('agent-panel-runtime-status').textContent()).includes('Restarting'));
      if (s.edit && !s.apply) check(`${label} footer visible`, await q('agent-panel-apply').isVisible());
      if (s.edit?.includes('bypass')) check(`${label} bypass switch off`, (await q('agent-panel-permissions-toggle').getAttribute('aria-checked')) === 'false');
      const m = await page.evaluate(() => {
        const vis = (el) => el.offsetParent !== null || getComputedStyle(el).position === 'fixed';
        const small = [...document.querySelectorAll('[data-debug-id="agent-panel"] button, [data-debug-id="agent-panel"] [role="radio"], [data-debug-id="agent-panel"] select, [data-debug-id="agent-panel"] a')]
          .filter(vis).map((el) => {
            const r = el.getBoundingClientRect();
            const pad = el.getAttribute('role') === 'switch' && getComputedStyle(el, '::after').position === 'absolute' ? 16 : 0;
            return [el.getAttribute('data-debug-id') || el.getAttribute('aria-label') || el.textContent.trim().slice(0, 30), Math.round(r.height) + pad];
          }).filter(([, h]) => h < 44);
        return { viewport: window.innerWidth, document: document.documentElement.scrollWidth, small };
      });
      check(`${label} no horizontal scroll`, m.document <= m.viewport, JSON.stringify(m));
      if (width === 390) check(`${label} 44px targets`, m.small.length === 0, JSON.stringify(m.small));
      const shot = path.join(evidence, `t8-${width}-${name}.png`);
      if (s.full) {
        // Grow the viewport to the panel's scroll height so the whole panel is in one image.
        const full = await page.evaluate(() => {
          const scroller = [...document.querySelectorAll('[data-debug-id="agent-panel"] *')].find((el) => el.scrollHeight > el.clientHeight + 4 && /(auto|scroll)/.test(getComputedStyle(el).overflowY));
          return scroller ? scroller.scrollHeight - scroller.clientHeight : 0;
        });
        await page.setViewportSize({ width, height: (width === 390 ? 844 : 1000) + full + 40 });
        await page.waitForTimeout(150);
      }
      // Let transitions (the switch's track/knob, footer entrance) settle before capturing.
      await page.waitForTimeout(400);
      await page.screenshot({ path: shot });
      await page.close();
    }
  }

  // 2) Accessibility walk, per width.
  for (const width of WIDTHS) {
    const label = `${width}/a11y`;
    const page = await newPage(width, label);
    const q = await open(page, 'state=idle&acp=adapter_missing');
    const panel = q('agent-panel');
    const mode = await panel.getAttribute('data-mode');
    // data-debug-ids on the panel and each section.
    for (const id of SECTIONS) check(`${label} ${id}`, (await q(id).count()) === 1);
    // Landmark: docked = aside labelled by its heading; drawer/page = dialog labelled.
    const landmark = await page.evaluate(() => {
      const el = document.querySelector('[data-debug-id="agent-panel"]');
      const host = el.closest('[role="dialog"]') || el;
      const by = host.getAttribute('aria-labelledby');
      return { tag: el.tagName.toLowerCase(), role: host.getAttribute('role'), modal: host.getAttribute('aria-modal'), name: by ? document.getElementById(by)?.textContent : host.getAttribute('aria-label') };
    });
    if (mode === 'docked') check(`${label} aside labelled`, landmark.tag === 'aside' && landmark.name === 'Agent', JSON.stringify(landmark));
    else check(`${label} dialog labelled`, landmark.role === 'dialog' && landmark.modal === 'true' && Boolean(landmark.name), JSON.stringify(landmark));
    // Focus on the heading after open.
    const focused = await page.evaluate(() => document.activeElement?.textContent);
    check(`${label} focus on heading`, focused === (mode === 'page' ? 'Agent settings' : 'Agent'), String(focused));
    // Status pill role=status.
    check(`${label} pill role=status`, (await q('agent-panel-runtime-status').getAttribute('role')) === 'status');
    // Gear aria-expanded.
    check(`${label} gear aria-expanded`, (await q('conversation-agent-settings-btn').getAttribute('aria-expanded')) === 'true');
    // Radiogroups: roving tabindex + arrow keys move selection and focus, skipping disabled rows.
    for (const group of ['bridge', 'model', 'connection']) {
      const radios = page.locator(`[data-debug-id="agent-panel-${group}"] [role="radio"]`);
      const n = await radios.count();
      const tabStops = await page.evaluate((g) => [...document.querySelectorAll(`[data-debug-id="agent-panel-${g}"] [role="radio"]`)].filter((r) => r.tabIndex === 0).length, group);
      check(`${label} ${group} one tab stop`, tabStops === 1, `${tabStops} of ${n}`);
      const checkedBefore = await page.evaluate((g) => document.querySelector(`[data-debug-id="agent-panel-${g}"] [role="radio"][aria-checked="true"]`)?.getAttribute('data-debug-id'), group);
      await page.locator(`[data-debug-id="agent-panel-${group}"] [role="radio"][tabindex="0"]`).focus();
      await page.keyboard.press('ArrowDown');
      const after = await page.evaluate((g) => ({
        checked: document.querySelector(`[data-debug-id="agent-panel-${g}"] [role="radio"][aria-checked="true"]`)?.getAttribute('data-debug-id'),
        focus: document.activeElement?.getAttribute('data-debug-id'),
        disabled: document.activeElement?.getAttribute('aria-disabled'),
      }), group);
      check(`${label} ${group} ArrowDown moves selection`, after.checked && after.checked !== checkedBefore && after.focus === after.checked && after.disabled !== 'true', JSON.stringify({ checkedBefore, ...after }));
      await page.keyboard.press('ArrowUp');
      const back = await page.evaluate((g) => document.querySelector(`[data-debug-id="agent-panel-${g}"] [role="radio"][aria-checked="true"]`)?.getAttribute('data-debug-id'), group);
      check(`${label} ${group} ArrowUp moves back`, back === checkedBefore, String(back));
    }
    // Bypass is a switch.
    const sw = page.locator('[data-debug-id="agent-panel-permissions"] [role="switch"]');
    check(`${label} bypass role=switch`, (await sw.count()) === 1 && (await sw.getAttribute('aria-checked')) !== null);
    // Footer chips: arrow aria-hidden, sr-only "to".
    await q('agent-panel-connection-acp').click();
    const chip = q('agent-panel-apply-chip').first();
    check(`${label} chip arrow aria-hidden`, (await chip.locator('[aria-hidden="true"]').textContent()) === '→');
    check(`${label} chip sr-only to`, (await chip.locator('.sr-only').textContent()) === 'to');
    check(`${label} ACP alert role=alert`, (await q('agent-panel-connection-acp-alert').getAttribute('role')) === 'alert');
    // Esc: closes drawer/page and returns focus to the gear; docked stays open.
    await page.locator('[data-debug-id="agent-panel"] h2, [data-debug-id="agent-panel"] [tabindex="-1"]').first().focus();
    await page.keyboard.press('Escape');
    await page.waitForTimeout(150);
    if (mode === 'docked') {
      check(`${label} Esc keeps docked panel`, (await q('agent-panel').count()) === 1);
      await q('agent-panel-close').click().catch(() => page.locator('[data-debug-id="agent-panel"] button[aria-label="Close"]').click());
    }
    await q('agent-panel').waitFor({ state: 'detached', timeout: 3000 }).catch(() => {});
    check(`${label} closed`, (await q('agent-panel').count()) === 0);
    const gearFocused = await page.evaluate(() => document.activeElement?.getAttribute('data-debug-id'));
    check(`${label} focus returns to gear`, gearFocused === 'conversation-agent-settings-btn', String(gearFocused));
    check(`${label} gear aria-expanded false`, (await q('conversation-agent-settings-btn').getAttribute('aria-expanded')) === 'false');
    await page.close();
  }

  // 3) Flag off: no gear, no panel; the old modal opens from the overflow menu and applies.
  for (const width of [1440, 390]) {
    const label = `${width}/flag-off`;
    const page = await newPage(width, label);
    const q = (id) => page.locator(`[data-debug-id="${id}"]`);
    await page.goto(`http://127.0.0.1:${port}/tests/fixtures/agent-settings-panel.html?state=idle&flag=off`);
    await q('conversation-thread-overflow-menu-btn').waitFor();
    await page.waitForTimeout(300);
    check(`${label} no gear`, (await q('conversation-agent-settings-btn').count()) === 0);
    check(`${label} no panel`, (await q('agent-panel').count()) === 0);
    await q('conversation-thread-overflow-menu-btn').click();
    await q('conversation-thread-settings-action').click();
    await q('conversation-runtime-modal').waitFor();
    const modal = q('conversation-runtime-modal');
    // Stage a bridge move through the modal's bridge cards.
    await modal.getByText('dawnstar', { exact: true }).click();
    const changed = (await modal.textContent()).includes('Restarts the agent');
    check(`${label} modal stages a bridge move`, changed);
    await page.waitForTimeout(200);
    await page.screenshot({ path: path.join(evidence, `t8-${width}-flag-off-modal.png`) });
    const apply = q('conversation-runtime-modal-apply-btn');
    check(`${label} modal Apply enabled`, !(await apply.isDisabled()));
    await apply.click();
    await page.waitForFunction(() => (window.__reconfigurations || []).length === 1, null, { timeout: 5000 }).catch(() => {});
    const posted = await page.evaluate(() => window.__reconfigurations || []);
    check(`${label} modal Apply posts one reconfiguration`, posted.length === 1 && posted[0].bridge_id === 'brg_dawnstar' && posted[0].expected_revision === 7, JSON.stringify(posted));
    await page.close();
  }
} finally {
  await browser.close();
  await server.close();
}
console.log(JSON.stringify(checks, null, 1));
console.log(`checks: ${checks.filter((c) => c.ok).length}/${checks.length} pass`);
assert.deepEqual(failures, []);
