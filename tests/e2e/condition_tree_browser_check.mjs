// PLAYWRIGHT_MODULE=/path/to/playwright-core/index.mjs CONDITION_TREE_EVIDENCE=/path node tests/e2e/condition_tree_browser_check.mjs
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { createServer } from 'vite';

const { chromium } = await import(process.env.PLAYWRIGHT_MODULE || 'playwright');
const root = fileURLToPath(new URL('../../', import.meta.url));
const evidence = process.env.CONDITION_TREE_EVIDENCE || '/tmp/condition-tree-evidence';
await fs.mkdir(evidence, { recursive: true });
const server = await createServer({ root, server: { host: '127.0.0.1', port: 0, strictPort: false } });
await server.listen();
const port = server.httpServer.address().port;
const browser = await chromium.launch({ headless: true, executablePath: process.env.CHROMIUM_EXECUTABLE, args: ['--no-sandbox'] });
const failures = [];
try {
  for (const width of [1280, 390, 320]) {
    const page = await browser.newPage({ viewport: { width, height: 1000 } });
    page.on('pageerror', e => failures.push(e.message));
    await page.route('**/*', route => route.request().url().startsWith(`http://127.0.0.1:${port}/`) ? route.continue() : route.abort());
    await page.goto(`http://127.0.0.1:${port}/tests/fixtures/condition-tree.html`);
    const q = id => page.locator(`[data-debug-id="${id}"]`);
    await q('action-trigger-review-conditions-node-root-add-check').waitFor();
    assert.equal(await page.getByLabel('Delay (seconds)', { exact: true }).count(), 0, 'webhooks have no delay field');
    assert.equal(await page.evaluate(() => document.documentElement.scrollWidth > window.innerWidth), false, `${width}: no horizontal overflow`);
    for (const field of await page.getByLabel('Condition field', { exact: true }).all()) {
      const box = await field.boundingBox();
      assert.ok(box.x >= 0 && box.x + box.width <= width, `${width}: field fits viewport`);
    }
    // Open and select a group mode using only the keyboard; Escape closes it.
    const mode = q('action-trigger-review-conditions-node--all-1-mode');
    await mode.focus();
    await page.keyboard.press('Enter');
    await page.keyboard.press('Home');
    await page.keyboard.press('ArrowDown');
    await page.keyboard.press('Enter');
    assert.ok((await mode.textContent()).includes('Any of'));
    assert.equal(await mode.evaluate(el => el.matches(':focus-visible')), true);
    const focus = await mode.evaluate(el => {
      const css = getComputedStyle(el); return { shadow: css.boxShadow, outline: css.outlineStyle };
    });
    assert.ok(focus.shadow !== 'none' || focus.outline !== 'none', 'keyboard focus is visible');
    await page.screenshot({ path: `${evidence}/condition-tree-${width}.png`, fullPage: true });
    // The real endpoint hook renders a full trace from this fixture response.
    await q('action-trigger-review-conditions-sample-toggle').click();
    await q('action-trigger-review-conditions-test').click();
    await page.getByText('Sample matches', { exact: true }).waitFor();
    assert.equal(await page.locator('[aria-label="Condition test results"] li').count(), 7);
    console.log(`PASS ${width}px: no overflow; fields fit; keyboard selection/focus; webhook delay hidden; full sample trace`);
    await page.close();
  }
  assert.deepEqual(failures, []);
} finally { await browser.close(); await server.close(); }
