import fs from 'node:fs/promises';
import path from 'node:path';
import assert from 'node:assert/strict';
import WebSocket from 'ws';

const output = process.argv[2] || '/tmp/t8-home-captures';
const widths = (process.argv[3] || '1440,390').split(',').map(Number);
const port = process.env.HOME_CDP_PORT || 9338;
const origin = process.env.HOME_FIXTURE_ORIGIN || 'http://127.0.0.1:5188';
await fs.mkdir(output, { recursive: true });
const tab = await (await fetch(`http://127.0.0.1:${port}/json/new?about:blank`, { method: 'PUT' })).json();
const ws = new WebSocket(tab.webSocketDebuggerUrl);
await new Promise((resolve) => ws.once('open', resolve));
let sequence = 0;
const pending = new Map();
const errors = [];
ws.on('message', (raw) => {
  const message = JSON.parse(raw);
  if (message.id) {
    const request = pending.get(message.id);
    if (request) { pending.delete(message.id); message.error ? request.reject(new Error(JSON.stringify(message.error))) : request.resolve(message.result); }
  }
  if (message.method === 'Runtime.exceptionThrown') errors.push(message.params.exceptionDetails.text + ': ' + (message.params.exceptionDetails.exception?.description || ''));
  if (message.method === 'Log.entryAdded' && message.params.entry.level === 'error') errors.push(message.params.entry.text);
});
const call = (method, params = {}) => new Promise((resolve, reject) => {
  const id = ++sequence; pending.set(id, { resolve, reject }); ws.send(JSON.stringify({ id, method, params }));
  setTimeout(() => { if (pending.has(id)) { pending.delete(id); reject(new Error('CDP timeout: ' + method)); } }, 15000).unref();
});
const evaluate = async (expression) => {
  const result = await call('Runtime.evaluate', { expression, returnByValue: true, awaitPromise: true });
  if (result.exceptionDetails) throw new Error(result.exceptionDetails.exception?.description || result.exceptionDetails.text);
  return result.result.value;
};
const wait = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
const click = (id) => evaluate(`document.querySelector('[data-debug-id="${id}"]').click()`);
async function settle() {
  for (let i = 0; i < 80; i++) {
    if (await evaluate(`Boolean(document.querySelector('[data-debug-id="home-page"]') && document.querySelector('.home-widget-grid[aria-busy="false"]') && !document.querySelector('[aria-busy="true"]'))`)) {
      await evaluate('document.fonts.ready'); await wait(150); return;
    }
    await wait(100);
  }
  console.error(JSON.stringify({errors, html: await evaluate('document.body.innerHTML.slice(0,4000)')}));
  throw new Error('Home fixture failed to settle');
}
async function key(key, code, virtualKey) {
  await call('Input.dispatchKeyEvent', { type: 'keyDown', key, code, windowsVirtualKeyCode: virtualKey, ...(key === 'Enter' ? { text: '\r', unmodifiedText: '\r' } : {}) });
  await call('Input.dispatchKeyEvent', { type: 'keyUp', key, code, windowsVirtualKeyCode: virtualKey });
  await wait(50);
}
await call('Page.bringToFront'); await call('Emulation.setFocusEmulationEnabled', { enabled: true }); await call('Page.enable'); await call('Runtime.enable'); await call('Log.enable');
const reports = [];
try {
  for (const width of widths) {
    await call('Emulation.setDeviceMetricsOverride', { width, height: 1000, deviceScaleFactor: 1, mobile: false });
    for (const state of ['normal', 'edit', 'expanded', 'empty']) {
      await call('Page.navigate', { url: origin + '/tests/fixtures/home-widgets/index.html' + (state === 'empty' ? '?empty' : '') });
      await settle();
      await evaluate('localStorage.clear()');
      await call('Page.reload');
      await settle();
      if (state !== 'empty') {
        // Production Fleet initially expands its first bridge. Normal/edit captures show it collapsed.
        await evaluate(`document.querySelectorAll('[data-debug-id^="home-fleet-expand-"][aria-expanded="true"]').forEach((button) => button.click())`);
        if (state === 'expanded') await click('home-fleet-expand-mock-bridge-0');
      }
      if (state === 'edit') await click('home-layout-edit');
      await wait(100);
      const geometry = await evaluate(`({
        viewport: innerWidth, page: document.documentElement.scrollWidth,
        slots: [...document.querySelectorAll('.home-widget-slot')].filter(el => getComputedStyle(el).display !== 'none').map(el => ({id:el.dataset.debugId,x:el.getBoundingClientRect().x,y:el.getBoundingClientRect().y,width:el.getBoundingClientRect().width,outline:getComputedStyle(el).outline,offset:getComputedStyle(el).outlineOffset})),
        controls: [...document.querySelectorAll('.home-layout-handle,.home-layout-remove,[data-debug-id="home-new-shell"],[data-debug-id="home-new-conversation"]')].map(el => ({id:el.dataset.debugId,width:el.getBoundingClientRect().width,height:el.getBoundingClientRect().height})),
        height: Math.ceil(document.documentElement.scrollHeight)
      })`);
      assert.ok(geometry.page <= width, 'horizontal overflow');
      const file = path.join(output, `home-${width}-${state}.png`);
      const screenshot = await call('Page.captureScreenshot', { format: 'png', captureBeyondViewport: true, clip: { x: 0, y: 0, width, height: Math.max(1000, geometry.height), scale: 1 } });
      await fs.writeFile(file, Buffer.from(screenshot.data, 'base64'));
      reports.push({ width, state, file, geometry });
      if (state === 'edit') {
        // Native Enter opens the handle menu; arrows move focus; Enter activates the action.
        const id = width < 768 ? 'uptime' : 'chains';
        await evaluate(`document.querySelector('[data-debug-id="home-layout-handle-${id}"]').focus()`);
        await key('Enter', 'Enter', 13);
        const focused = await evaluate('document.activeElement.dataset.debugId');
        if (!/^home-layout-(earlier|later)-/.test(focused)) console.error(JSON.stringify({focused, debug: await evaluate("document.activeElement.outerHTML + document.querySelector('[role=menu]')?.outerHTML")}));
        assert.match(focused, /^home-layout-(earlier|later)-/);
        const before = await evaluate(`[...document.querySelectorAll('.home-widget-slot')].map(el=>el.dataset.debugId).join(',')`);
        // First enabled action is earlier on desktop and later on default mobile.
        await key('Enter', 'Enter', 13);
        const after = await evaluate(`[...document.querySelectorAll('.home-widget-slot')].map(el=>el.dataset.debugId).join(',')`);
        assert.notEqual(after, before, 'keyboard-only reorder');
        await wait(600);
        await call('Page.reload'); await settle();
        assert.equal(await evaluate(`[...document.querySelectorAll('.home-widget-slot')].map(el=>el.dataset.debugId).join(',')`), after, 'layout survives reload');
        reports.at(-1).keyboardReorderAndReload = 'PASS';
      }
    }
  }
  assert.deepEqual(errors, [], 'browser console/resource errors');
  await fs.writeFile(path.join(output, 'report.json'), JSON.stringify({ errors, reports }, null, 2));
  console.log(JSON.stringify({ errors, reports }, null, 2));
} finally {
  ws.close();
  await fetch(`http://127.0.0.1:${port}/json/close/${tab.id}`);
}
