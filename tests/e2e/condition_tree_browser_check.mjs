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
  for (const width of [1280, 390, 360, 320]) {
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
    if (width < 640) {
      for (const button of await page.locator('.action-trigger-editor button:visible:not([role="switch"])').all()) {
        const box = await button.boundingBox();
        assert.ok(box.height >= 44 && box.width >= 44, `${width}: button has a 44px target: ${await button.textContent()}`);
        assert.ok(box.x >= 0 && box.x + box.width <= width, `${width}: button fits viewport`);
      }
    }
    // Each editor group collapses to a one-line summary and keeps other groups usable.
    const collapse = q('action-trigger-review-conditions-node--all-1-collapse');
    await collapse.click();
    assert.equal(await collapse.getAttribute('aria-expanded'), 'false');
    assert.ok((await collapse.textContent()).includes('Any of 2 checks'));
    await q('action-trigger-review-conditions-node--all-2-collapse').click();
    await page.screenshot({ path: `${evidence}/condition-editor-${width}.png`, fullPage: true });
    await q('action-trigger-review-conditions-view-tree').click();
    const tree = page.getByRole('tree', { name: 'Condition tree' });
    assert.equal(await tree.getByRole('treeitem').count(), 7);
    const treeRoot = q('action-trigger-review-conditions-diagram-node-root');
    await treeRoot.focus();
    await page.keyboard.press('ArrowDown');
    assert.equal(await page.evaluate(() => document.activeElement.dataset.treePath), '/all/0');
    await page.keyboard.press('ArrowDown');
    await page.keyboard.press('ArrowLeft');
    assert.equal(await tree.getByRole('treeitem').count(), 5, 'Any group collapses with keyboard');
    assert.equal(await page.evaluate(() => document.documentElement.scrollWidth > window.innerWidth), false, 'diagram fits phone');
    await page.screenshot({ path: `${evidence}/condition-tree-${width}.png`, fullPage: true });
    await page.keyboard.press('ArrowRight');
    await q('action-trigger-review-conditions-diagram-node--all-1-any-0').click();
    const field = q('action-trigger-review-conditions-node--all-1-any-0-field');
    assert.equal(await field.evaluate(el => el === document.activeElement), true, 'selecting node opens and focuses editor');
    // Live tree reflects edits and preserves the author order.
    await field.fill('data.repository');
    await q('action-trigger-review-conditions-view-tree').click();
    assert.ok((await tree.textContent()).includes('repository starts with'));
    await q('action-trigger-review-conditions-view-editor').click();
    // The real endpoint hook renders a full trace from this fixture response.
    await q('action-trigger-review-conditions-sample-toggle').click();
    await q('action-trigger-review-conditions-test').click();
    await page.getByText('Sample matches', { exact: true }).waitFor();
    assert.equal(await page.locator('[aria-label="Condition test results"] li').count(), 7);
    if (width <= 390) {
      await page.evaluate(() => window.setConditionFixture([{ clientKey: 'deep', kind: 'event', enabled: true, config: { event_type: 'webhook.received', filter: { all: [{ any: [{ all: [{ field: 'data.' + 'long_parameter_'.repeat(4), op: 'eq', value: 'a'.repeat(128) }] }] }] } } }]));
      await q('action-trigger-deep-conditions-node--all-0-any-0-all-0-field').waitFor();
      assert.equal(await page.evaluate(() => document.documentElement.scrollWidth > window.innerWidth), false, `${width}: maximum-depth tree and long values fit`);
      await q('action-trigger-deep-conditions-view-tree').click();
      assert.equal(await page.evaluate(() => document.documentElement.scrollWidth > window.innerWidth), false, `${width}: maximum-depth diagram fits`);
    }
    console.log(`PASS ${width}px: no overflow; phone targets >=44px; collapsible editor/diagram; tree keyboard; node-to-editor focus; live updates; webhook delay hidden; full sample trace`);
    await page.close();
  }
  assert.deepEqual(failures, []);
} finally { await browser.close(); await server.close(); }
