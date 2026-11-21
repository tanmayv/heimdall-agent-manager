import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import { pathToFileURL } from 'node:url';
const { default: puppeteer } = await import(pathToFileURL(process.env.PUPPETEER_MODULE));
const [base, evidence] = process.argv.slice(2);
await fs.mkdir(evidence, { recursive: true });
const browser = await puppeteer.launch({ executablePath: process.env.BROWSER_EXECUTABLE, headless: true, args: ['--no-sandbox', '--disable-dev-shm-usage'] });
try {
 const screenshots = [];
 for (const agent of [true, false]) {
  const page = await browser.newPage();
  const errors = [];
  page.on('pageerror', e => errors.push(e.message));
  await page.setViewport({ width: 390, height: 844, deviceScaleFactor: 1 });
  await page.goto(base + '/tests/fixtures/bot-attachments/?compare' + (agent ? '&agent' : ''));
  const input = agent ? 'conversation-composer-input' : 'bot-chat-input';
  await page.waitForSelector('[data-debug-id="' + input + '"]');
  // Hold the synthetic Hub upload so both screenshots show the same pending state.
  // Fixture fetch is in-process: hold its upload promise before it reaches the Hub stub.
  await page.evaluate(() => {
    const fetch = window.fetch;
    window.fetch = async (input, init) => {
      if (init?.method === 'POST' && new URL(String(input), location.href).pathname.endsWith('/artifacts')) return new Promise(() => {});
      return fetch(input, init);
    };
  });
  const pdf = path.join(evidence, 'brief.pdf');
  await fs.writeFile(pdf, '%PDF-1.4 fixture');
  const picker = agent ? 'conversation-attach-input' : 'bot-chat-upload-input';
  await (await page.$('[data-debug-id="' + picker + '"]')).uploadFile(pdf);
  await page.waitForFunction(() => document.body.textContent.includes('Uploading…'));
  await page.waitForSelector('a[data-debug-id$="art_example-link"]');
  await new Promise(r => setTimeout(r, 1000));
  assert.equal(await page.evaluate(() => document.documentElement.scrollWidth > innerWidth), false);
  assert.deepEqual(errors, []);
  const file = (agent ? 'agent' : 'bot') + '-390.png';
  await page.screenshot({ path: path.join(evidence, file) });
  screenshots.push(await page.screenshot({ encoding: 'base64' }));
  await page.close();
 }
 const combined = await browser.newPage();
 await combined.setViewport({ width: 780, height: 884, deviceScaleFactor: 1 });
 await combined.setContent('<body style="margin:0;background:#161616;color:white;font:16px system-ui"><div style="display:flex"><div style="width:390px"><div style="height:40px;text-align:center;line-height:40px">Agent chat · 390px</div><img width="390" src="data:image/png;base64,' + screenshots[0] + '"></div><div style="width:390px"><div style="height:40px;text-align:center;line-height:40px">Bot chat · 390px</div><img width="390" src="data:image/png;base64,' + screenshots[1] + '"></div></div></body>');
 await combined.screenshot({ path: path.join(evidence, 'composer-comparison-390.png') });
 console.log('PASS: agent and bot at 390px, real components, pending upload and sent document, no overflow or page errors.');
} finally { await browser.close(); }
