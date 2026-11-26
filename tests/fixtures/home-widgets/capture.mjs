import fs from 'node:fs/promises';
import path from 'node:path';
import assert from 'node:assert/strict';
import WebSocket from 'ws';

const output = process.argv[2] || '/tmp/t8-home-captures';
const widths = (process.argv[3] || '1440,390').split(',').map(Number);
const height = Number(process.env.HOME_FIXTURE_HEIGHT || 1000);
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
    await call('Emulation.setDeviceMetricsOverride', { width, height, deviceScaleFactor: 1, mobile: false });
    for (const state of width < 768 ? ['normal', 'edit', 'add-sheet', 'reordered', 'expanded', 'draft', 'applying', 'partial-failure', 'empty'] : ['normal', 'edit', 'expanded', 'draft', 'applying', 'partial-failure', 'empty']) {
      await call('Emulation.setDeviceMetricsOverride', { width, height, deviceScaleFactor: 1, mobile: false });
      await call('Page.navigate', { url: origin + '/tests/fixtures/home-widgets/index.html' + (state === 'empty' ? '?empty' : '?fleet-state=' + state) });
      await settle();
      await evaluate('localStorage.clear()');
      await call('Page.reload');
      await settle();
      await evaluate('window.scrollTo(0, 0)');
      if (state !== 'empty') {
        // Production Fleet initially expands its first bridge. Normal/edit captures show it collapsed.
        await evaluate(`document.querySelectorAll('[data-debug-id^="home-fleet-expand-"][aria-expanded="true"]').forEach((button) => button.click())`);
        if (['expanded', 'draft', 'applying', 'partial-failure'].includes(state)) await click('home-fleet-expand-mock-bridge-0');
        if (state === 'draft') {
          await click('home-fleet-default-mock-bridge-0-provider');
          await evaluate(`[...document.querySelectorAll('[role="option"]')].find((node) => node.textContent === 'Codex').click()`);
          await wait(150);
          assert.equal(await evaluate(`document.querySelector('[data-debug-id="home-fleet-apply-mock-bridge-0"]').disabled`), false);
        }
      }
      if (['edit', 'add-sheet', 'reordered'].includes(state)) await click('home-layout-edit');
      if (state === 'add-sheet') {
        await click('home-layout-add-menu');
        await evaluate(`Promise.all([...document.querySelector('[data-debug-id="home-layout-add-sheet"]').parentElement.getAnimations({subtree:true})].filter(a => a.effect.getTiming().iterations !== Infinity).map(a => a.finished.catch(() => {})))`);
        const sheet = await evaluate(`(() => {
          const sheet = document.querySelector('[data-debug-id="home-layout-add-sheet"]');
          const rect = sheet.getBoundingClientRect();
          return { x: rect.x, right: rect.right, y: rect.y, bottom: rect.bottom, height: rect.height,
            focused: sheet.contains(document.activeElement),
            rows: [...sheet.querySelectorAll('[role="menuitemcheckbox"]')].map(el => ({id: el.dataset.debugId, height: el.getBoundingClientRect().height, width: el.getBoundingClientRect().width,
              checked: el.getAttribute('aria-checked'), feedback: el.matches(':hover,:focus-visible'), background: getComputedStyle(el).backgroundColor})) };
        })()`);
        assert.ok(sheet.x >= 0 && sheet.right <= width && sheet.y >= 0 && sheet.bottom <= height + 1, 'sheet inside visible viewport: ' + JSON.stringify(sheet));
        assert.ok(sheet.height <= height * .8 + 1, 'sheet caps visible height');
        assert.equal(sheet.focused, true);
        assert.equal(sheet.rows.length, 3);
        assert.ok(sheet.rows.every(row => row.height >= 44));
        assert.ok(sheet.rows.every(row => row.feedback || row.background === 'rgba(0, 0, 0, 0)'), 'idle checked rows have no persistent fill');
        assert.ok(sheet.rows.every(row => row.checked === 'true'), 'checked indicators retained');
        // The final option must be reachable even on short screens.
        await evaluate(`document.querySelector('[data-debug-id="home-layout-toggle-fleet"]').scrollIntoView({block:'nearest'})`);
        assert.ok(await evaluate(`(() => { const r = document.querySelector('[data-debug-id="home-layout-toggle-fleet"]').getBoundingClientRect(); return r.y >= 0 && r.bottom <= innerHeight; })()`));
      }
      if (state === 'reordered') {
        await evaluate(`document.querySelector('[data-debug-id="home-layout-down-uptime"]').focus()`);
        await key('Enter', 'Enter', 13);
        assert.equal(await evaluate('document.activeElement.dataset.debugId'), 'home-layout-down-uptime');
      }
      await wait(100);
      const geometry = await evaluate(`({
        viewport: innerWidth, page: document.documentElement.scrollWidth,
        slots: [...document.querySelectorAll('.home-widget-slot')].filter(el => getComputedStyle(el).display !== 'none').map(el => ({id:el.dataset.debugId,x:el.getBoundingClientRect().x,y:el.getBoundingClientRect().y,width:el.getBoundingClientRect().width,outline:getComputedStyle(el).outline,offset:getComputedStyle(el).outlineOffset})),
        controls: [...document.querySelectorAll('.home-layout-handle,.home-layout-arrows button,.home-layout-options,.home-layout-remove,[data-debug-id="home-new-shell"],[data-debug-id="home-new-conversation"]')].map(el => ({id:el.dataset.debugId,width:el.getBoundingClientRect().width,height:el.getBoundingClientRect().height})),
        height: Math.ceil(document.documentElement.scrollHeight)
      })`);
      assert.ok(geometry.page <= width, 'horizontal overflow');
      if (width < 768) assert.ok(geometry.controls.every(control => control.width >= 44 && control.height >= 44), '44px mobile controls');
      const file = path.join(output, `home-${width}-${state}.png`);
      const screenshot = await call('Page.captureScreenshot', { format: 'png', captureBeyondViewport: state !== 'add-sheet', clip: { x: 0, y: 0, width, height: state === 'add-sheet' ? height : Math.max(height, geometry.height), scale: 1 } });
      await fs.writeFile(file, Buffer.from(screenshot.data, 'base64'));
      reports.push({ width, state, file, geometry });
      if (state === 'normal') {
        const link = 'home-chain-open-mock-chain-0';
        const href = '#/conversations/chain:mock-chain-0';
        assert.equal(await evaluate(`document.querySelector('[data-debug-id="${link}"]').getAttribute('href')`), href);
        const rect = await evaluate(`(() => { const el = document.querySelector('[data-debug-id="${link}"]'); el.scrollIntoView({block:'center'}); const r = el.getBoundingClientRect(); return {x:r.x+r.width/2,y:r.y+r.height/2}; })()`);
        await call('Input.dispatchMouseEvent', {type:'mousePressed', ...rect, button:'left', clickCount:1});
        await call('Input.dispatchMouseEvent', {type:'mouseReleased', ...rect, button:'left', clickCount:1});
        assert.equal(await evaluate('location.hash'), href);
        await evaluate(`history.replaceState(null, '', location.pathname + location.search); document.querySelector('[data-debug-id="${link}"]').focus()`);
        await key('Enter', 'Enter', 13);
        assert.equal(await evaluate('location.hash'), href);
        await evaluate(`history.replaceState(null, '', location.pathname + location.search)`);
        const beforeTabs = new Set((await (await fetch(`http://127.0.0.1:${port}/json/list`)).json()).map(tab => tab.id));
        await call('Input.dispatchMouseEvent', {type:'mousePressed', ...rect, button:'left', modifiers:2, clickCount:1});
        await call('Input.dispatchMouseEvent', {type:'mouseReleased', ...rect, button:'left', modifiers:2, clickCount:1});
        await wait(400);
        const opened = (await (await fetch(`http://127.0.0.1:${port}/json/list`)).json()).find(tab => !beforeTabs.has(tab.id) && tab.url.endsWith(href));
        assert.ok(opened, 'Ctrl+click opens the chain-addressed destination in another tab');
        await call('Target.closeTarget', {targetId:opened.id});
        await call('Page.bringToFront');
        reports.at(-1).chainNavigation = { mouse: 'PASS', keyboard: 'PASS', nativeNewTab: 'PASS', href, boundary: 'isolated Home fixture; shell conversation routing covered by integration tests' };
      }
      if (state === 'add-sheet') {
        await key('Escape', 'Escape', 27);
        assert.equal(await evaluate('document.activeElement.dataset.debugId'), 'home-layout-add-menu');
        assert.equal(await evaluate('document.body.style.overflow'), '');
        await wait(350);
        await click('home-layout-add-menu'); await wait(350);
        await call('Input.dispatchMouseEvent', {type:'mousePressed', x:5, y:5, button:'left', clickCount:1});
        await call('Input.dispatchMouseEvent', {type:'mouseReleased', x:5, y:5, button:'left', clickCount:1});
        assert.equal(await evaluate(`document.querySelector('[data-debug-id="home-layout-add-menu"]').getAttribute('aria-expanded')`), 'false');
        reports.at(-1).sheetViewportScrollDismissal = 'PASS';
      }
      if (state === 'edit') {
        // Native Enter opens the handle menu; arrows move focus; Enter activates the action.
        const id = width < 768 ? 'uptime' : 'chains';
        if (width < 768) {
          assert.equal(await evaluate(`Boolean(document.querySelector('[draggable="true"]'))`), false);
          assert.equal(await evaluate(`document.querySelector('[data-debug-id="home-layout-up-uptime"]').disabled`), true);
          assert.equal(await evaluate(`document.querySelector('[data-debug-id="home-layout-down-fleet"]').disabled`), true);
          await evaluate(`document.querySelector('[data-debug-id="home-layout-down-${id}"]').focus()`);
        } else {
          await evaluate(`document.querySelector('[data-debug-id="home-layout-handle-${id}"]').focus()`);
          await key('Enter', 'Enter', 13);
          assert.match(await evaluate('document.activeElement.dataset.debugId'), /^home-layout-(earlier|later)-/);
        }
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
