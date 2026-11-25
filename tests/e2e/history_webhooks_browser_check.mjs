import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { createServer } from 'vite';
const { chromium } = await import(process.env.PLAYWRIGHT_MODULE || 'playwright');
const evidence = process.env.HISTORY_WEBHOOKS_EVIDENCE;
await fs.mkdir(evidence, { recursive: true });
const server = await createServer({ root: fileURLToPath(new URL('../../', import.meta.url)), server: { host: '127.0.0.1', port: 0 } });
await server.listen();
const browser = await chromium.launch({ headless: true, executablePath: process.env.CHROMIUM_EXECUTABLE, args: ['--no-sandbox'] });
const errors = [];
try {
  for (const width of [1280, 390, 360, 320]) {
    const page = await browser.newPage({ viewport: { width, height: 1000 } });
    page.on('pageerror', error => errors.push(error.message));
    await page.goto('http://127.0.0.1:' + server.httpServer.address().port + '/tests/fixtures/history-webhooks.html');
    const q = id => page.locator('[data-debug-id="' + id + '"]');
    await q('action-run-expand-review').waitFor();
    assert.equal(await page.locator('details[open]').count(), 0, 'real Runs rows start closed');
    await page.screenshot({ path: evidence + '/history-closed-' + width + '.png', fullPage: true });
    await q('action-run-expand-review').focus();
    await page.keyboard.press('Enter');
    await q('action-run-expand-edited').click();
    await page.getByRole('tree').first().waitFor();
    assert.equal(await page.locator('details[open]').getByRole('treeitem').count(), 7);
    assert.ok(await page.getByText('saw: "docs-site"', { exact: true }).count());
    assert.ok(await page.getByText('Rule edited since this run', { exact: true }).count());
    const root = q('action-run-trace-review-node-root');
    await root.focus();
    await page.keyboard.press('ArrowDown');
    assert.equal(await page.evaluate(() => document.activeElement.dataset.treePath), '/all/0');
    assert.equal(await page.evaluate(() => document.activeElement.matches(':focus-visible')), true);
    await page.keyboard.press('ArrowDown');
    await page.keyboard.press('ArrowLeft');
    assert.equal(await page.locator('details[open]').getByRole('treeitem').count(), 5);
    await page.keyboard.press('ArrowRight');
    assert.equal(await page.evaluate(() => document.documentElement.scrollWidth > innerWidth), false, width + ': fits viewport');
    await page.screenshot({ path: evidence + '/history-' + width + '.png', fullPage: true });
    await q('webhook-name').fill('Review webhook');
    await q('webhook-create').focus();
    await page.keyboard.press('Enter');
    await q('webhook-token').waitFor();
    assert.equal(await q('webhook-token').inputValue(), 'example-only-token');
    assert.equal(await page.evaluate(() => document.activeElement.id), 'webhook-secret-title');
    assert.equal(await page.evaluate(() => document.documentElement.scrollWidth > innerWidth), false, width + ': credentials fit viewport');
    if (width < 640) for (const button of await page.locator('.webhooks-section button:visible').all()) {
      const box = await button.boundingBox(); assert.ok(box.height >= 44 && box.width >= 44);
    }
    await page.screenshot({ path: evidence + '/webhooks-' + width + '.png', fullPage: true });
    page.on('dialog', dialog => dialog.accept());
    await q('webhook-secret-dismiss').click();
    assert.equal(await q('webhook-token').count(), 0);
    await q('webhook-rotate-wh_ci').click();
    await q('webhook-rotate-confirm').click();
    await q('webhook-token').waitFor();
    await page.reload();
    await q('webhook-name').waitFor();
    assert.equal(await q('webhook-token').count(), 0, 'reload never replays secret');
    console.log('PASS ' + width + ': trace, seen values, edited fallback, keyboard navigation/focus, no overflow, credential creation/dismiss/rotate/reload, phone targets');
    await page.close();
  }
  assert.deepEqual(errors, []);
} finally { await browser.close(); await server.close(); }
