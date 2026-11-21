/**
 * Optional real Chromium regression/evidence runner.
 * PLAYWRIGHT_MODULE=/path/to/playwright/index.mjs node tests/voice-waveforms-browser.mjs
 * Uses installed Playwright headless shell; writes /tmp/voice-waveform-evidence.
 */
import { build } from 'esbuild';
import fs from 'node:fs/promises';
import path from 'node:path';
import assert from 'node:assert/strict';
import postcss from 'postcss';
import tailwindcss from 'tailwindcss';
import { pathToFileURL } from 'node:url';
const out = '/tmp/voice-waveform-evidence';
await fs.mkdir(out, { recursive: true });
const tokens = await fs.readFile('src/ui/tokens.css', 'utf8');
const css = await postcss([tailwindcss({ config: path.resolve('tailwind.config.js') })]).process(tokens + '\n@tailwind base;\n@tailwind components;\n@tailwind utilities;\nbody{margin:0;background:var(--color-canvas);color:var(--color-text-primary);font-family:system-ui}button{cursor:pointer}', { from: undefined });
await fs.writeFile(path.join(out, 'style.css'), css.css);
await fs.writeFile(path.join(out, 'index.html'), '<!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1"><link rel="stylesheet" href="style.css"></head><body><div id="root"></div><script defer src="app.js"></script></body></html>');
await build({ entryPoints: ['tests/fixtures/voice-waveforms.tsx'], bundle: true, format: 'iife', jsx: 'automatic',
  outfile: path.join(out, 'app.js'), define: { 'import.meta.env': '{}' }, alias: { '@ui': path.resolve('src/ui/components/ui') } });
const { chromium } = await import(process.env.PLAYWRIGHT_MODULE || 'playwright');
const browser = await chromium.launch({ executablePath: process.env.CHROMIUM_EXECUTABLE, headless: true, args: ['--no-sandbox', '--autoplay-policy=no-user-gesture-required'] });
const page = await browser.newPage({ viewport: { width: 768, height: 950 }, hasTouch: true });
const errors = [];
page.on('pageerror', (error) => { errors.push(String(error)); console.error(error); });
page.setDefaultTimeout(10000);
await page.goto(pathToFileURL(path.join(out, 'index.html')).href);
const q = (id) => page.locator(`[data-debug-id="${id}"]`);
try {
  await q('fixture-playback').locator('rect').first().waitFor();
  assert.equal(await q('fixture-playback').getAttribute('data-playing'), 'false');
  const heights = await q('fixture-playback').locator('rect').evaluateAll((bars) => bars.map((bar) => Number(bar.getAttribute('height'))));
  assert.ok(Math.min(...heights) === 2 && Math.max(...heights) > 20, 'real decoded silence and changing PCM peaks');
  const seek = q('fixture-playback-seek');
  await seek.focus();
  await page.keyboard.press('End');
  assert.ok(Number(await seek.inputValue()) >= 3.99);
  await page.keyboard.press('Home');
  assert.equal(Number(await seek.inputValue()), 0);
  await page.keyboard.press('ArrowRight');
  assert.ok(Number(await seek.inputValue()) > 0);
  const box = await seek.boundingBox();
  await page.mouse.click(box.x + box.width / 2, box.y + box.height / 2);
  assert.ok(Math.abs(Number(await seek.inputValue()) - 2) < 0.2);
  await page.touchscreen.tap(box.x + box.width / 4, box.y + box.height / 2);
  assert.ok(Math.abs(Number(await seek.inputValue()) - 1) < 0.2, 'touch tap seeks');
  await seek.dispatchEvent('pointercancel', { pointerId: 1 });
  await seek.focus(); await page.keyboard.press('Home');
  assert.equal(Number(await seek.inputValue()), 0, 'seeking remains usable after pointer cancellation');
  await page.mouse.move(box.x + 1, box.y + 20); await page.mouse.down();
  await page.mouse.move(box.x + box.width + 100, box.y + 20); await page.mouse.up();
  assert.ok(Number(await seek.inputValue()) >= 3.99, 'drag release outside clamps to endpoint');

  await q('conversation-record').click();
  await q('bot-chat-record').click();
  await page.waitForFunction(() => window.voiceMetrics['conversation']?.amplitudes.length > 4 && window.voiceMetrics['bot-chat']?.amplitudes.length > 4);
  const quiet = await page.evaluate(() => window.voiceMetrics['conversation'].amplitudes.at(-1));
  await page.evaluate(() => window.setToneLevel(0.8));
  await page.waitForFunction(() => window.voiceMetrics['conversation'].amplitudes.at(-1) > 0.7);
  const loud = await page.evaluate(() => window.voiceMetrics['conversation'].amplitudes.at(-1));
  assert.ok(loud > quiet * 4);
  for (let i = 0; i < 20; i++) {
    await page.evaluate((level) => window.setToneLevel(level), 0.15 + (i % 5) * 0.16);
    await page.waitForTimeout(150);
  }
  for (const width of [320, 768, 1024]) {
    await page.setViewportSize({ width, height: 950 });
    assert.equal(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth), true, `no horizontal overflow at ${width}px`);
    await page.screenshot({ path: path.join(out, `recording-${width}.png`), fullPage: true });
  }
  await q('conversation-voice-stop').click();
  await q('bot-chat-voice-stop').click();
  await q('conversation-voice-preview').locator('rect').first().waitFor();
  await q('bot-chat-voice-preview').locator('rect').first().waitFor();
  await q('conversation-voice-preview-toggle').click();
  await page.waitForFunction(() => document.querySelector('[data-debug-id="conversation-voice-preview"]').dataset.playing === 'true');
  await q('conversation-voice-preview-toggle').click();
  await page.emulateMedia({ reducedMotion: 'reduce' });
  for (const width of [320, 768, 1024]) {
    await page.setViewportSize({ width, height: 950 });
    assert.equal(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth), true);
    await page.screenshot({ path: path.join(out, `playback-${width}.png`), fullPage: true });
  }
  await page.evaluate(() => { document.body.style.zoom = '2'; });
  await page.setViewportSize({ width: 320, height: 950 });
  assert.equal(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth), true, '200% zoom at 320px');
  await page.screenshot({ path: path.join(out, 'playback-320-zoom200.png'), fullPage: true });
  await page.evaluate(() => { document.body.style.zoom = ''; });
  const stats = await page.evaluate(() => ({ requests: window.voiceMetrics.requests, sends: window.voiceMetrics.sends || 0 }));
  assert.equal(stats.requests, 2, 'one stream per recording');
  assert.equal(stats.sends, 0, 'analysis never sends');
  assert.deepEqual(errors, []);
  const result = { result: 'pass', quiet, loud, ...stats, screenshots: 7,
    limits: 'Isolated shared components; synthetic stream; Chromium only, no physical microphone/Safari/VoiceOver or authenticated full-page composer.' };
  await fs.writeFile(path.join(out, 'results.json'), JSON.stringify(result, null, 2));
  console.log(JSON.stringify(result));
} catch (error) { console.log(await page.locator('body').innerText()); await page.screenshot({ path: path.join(out, 'failure.png') }); throw error; } finally { await page.evaluate(() => window.closeToneContexts?.()); await browser.close(); }
