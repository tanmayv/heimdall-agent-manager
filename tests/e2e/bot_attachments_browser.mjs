// Browser evidence against actual production components and synthetic Hub data.
// Start Vite, then: node tests/e2e/bot_attachments_browser.mjs BASE_URL EVIDENCE_DIR
// PUPPETEER_MODULE and BROWSER_EXECUTABLE select preinstalled browser tooling.
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import { pathToFileURL } from 'node:url';
const [base, evidence] = process.argv.slice(2);
assert.ok(base && evidence && process.env.PUPPETEER_MODULE && process.env.BROWSER_EXECUTABLE);
const { default: puppeteer } = await import(pathToFileURL(process.env.PUPPETEER_MODULE));
await fs.mkdir(evidence, { recursive: true });
const browser = await puppeteer.launch({ executablePath: process.env.BROWSER_EXECUTABLE, headless: true, args: ['--no-sandbox', '--disable-dev-shm-usage'] });
const page = await browser.newPage(), errors = [];
page.on('pageerror', e => errors.push(e.message));
const q = id => '[data-debug-id="' + id + '"]';
const settle = () => new Promise(resolve => setTimeout(resolve, 400));
async function screenshot(name) {
 await settle();
 assert.equal(await page.evaluate(() => document.documentElement.scrollWidth > innerWidth), false, name + ': no horizontal overflow');
 await page.screenshot({ path: path.join(evidence, name + '.png') });
}
try {
 await page.setViewport({ width: 390, height: 844, deviceScaleFactor: 1 });
 await page.goto(base + '/tests/fixtures/bot-attachments/');
 await page.waitForSelector(q('bot-chat-input'));
 await page.focus(q('bot-chat-input'));
 await screenshot('bot-upload-empty-390');
 const pdf = path.join(evidence, 'brief.pdf');
 await fs.writeFile(pdf, '%PDF-1.4 test fixture');
 await (await page.$(q('bot-chat-upload-input'))).uploadFile(pdf);
 await page.waitForFunction(() => document.querySelector('[data-debug-id="bot-chat-attachments"]')?.textContent.includes('brief.pdf') && !document.querySelector('[data-debug-id="bot-chat-composer-send-btn"]').disabled);
 await screenshot('bot-upload-ready-390');
 // Clipboard files and items contain the same image, as a real screenshot paste does.
 await page.evaluate(() => {
  const png = Uint8Array.from(atob('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII='), c => c.charCodeAt(0));
  const file = new File([png], 'pasted-image.png', { type: 'image/png' });
  const transfer = new DataTransfer(); transfer.items.add(file);
  document.querySelector('[data-debug-id="bot-chat-input"]').dispatchEvent(new ClipboardEvent('paste', { bubbles: true, cancelable: true, clipboardData: transfer }));
 });
 await page.waitForFunction(() => window.botAttachments.artifacts.size === 2 && !document.querySelector('[data-debug-id="bot-chat-composer-send-btn"]').disabled);
 await page.click(q('bot-chat-composer-send-btn'));
 await page.waitForSelector('a[data-debug-id$="art_fixture_1-link"]');
 await page.waitForFunction(() => document.querySelector('[data-debug-id$="art_fixture_1-image"]')?.complete);
 await screenshot('bot-upload-history-390');
 assert.equal(await page.evaluate(() => window.botAttachments.messages[0].body), '');
 assert.equal(await page.evaluate(() => window.botAttachments.messages[0].attachments.length), 2);
 await page.reload(); await page.waitForSelector(q('bot-chat-input'));
 await page.focus(q('bot-chat-input'));
 await page.evaluate(() => { window.botAttachments.failUpload = true; });
 await (await page.$(q('bot-chat-upload-input'))).uploadFile(pdf);
 await page.waitForSelector('[data-debug-id^="bot-chat-upload-retry-"]');
 await screenshot('bot-upload-error-390');
 assert.equal(await page.$eval(q('bot-chat-composer-send-btn'), el => el.disabled), true);
 await page.evaluate(() => { window.botAttachments.failUpload = false; });
 await page.click('[data-debug-id^="bot-chat-upload-retry-"]');
 await page.waitForFunction(() => !document.querySelector('[data-debug-id="bot-chat-composer-send-btn"]').disabled);
 await page.click('[data-debug-id^="bot-chat-upload-remove-"]');
 assert.equal(await page.$(q('bot-chat-attachments')), null);
 assert.deepEqual(errors, []);
 console.log('PASS: 390px picker, paste, attachment-only send, history image/document previews, failure/retry/remove; 4 screenshots; no page errors or horizontal overflow.');
} finally { await browser.close(); }
