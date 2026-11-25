// Real-browser REQ-HOME-SHEET-1..6 checks against the isolated Home fixture.
import fs from 'node:fs/promises';
import path from 'node:path';
import assert from 'node:assert/strict';
import WebSocket from 'ws';

const output = process.argv[2];
assert.ok(output, 'provide an evidence output directory');
const port = process.env.HOME_CDP_PORT || 9342;
const origin = process.env.HOME_FIXTURE_ORIGIN || 'http://127.0.0.1:5192';
// Refuse reuse before creating a browser page, including after an ambiguous launch.
await fs.mkdir(output);
await fs.writeFile(path.join(output, 'capture-start.json'), JSON.stringify({
  startedAt: new Date().toISOString(), pid: process.pid, output, port, origin,
  sha: process.env.HOME_CAPTURE_SHA, tree: process.env.HOME_CAPTURE_TREE,
}, null, 2));
const tab = await (await fetch(`http://127.0.0.1:${port}/json/new?about:blank`, { method: 'PUT' })).json();
const ws = new WebSocket(tab.webSocketDebuggerUrl);
await new Promise(resolve => ws.once('open', resolve));
let sequence = 0;
const pending = new Map(), errors = [], reports = [];
ws.on('message', raw => {
  const message = JSON.parse(raw);
  if (message.id && pending.has(message.id)) {
    const request = pending.get(message.id); pending.delete(message.id);
    message.error ? request.reject(new Error(JSON.stringify(message.error))) : request.resolve(message.result);
  }
  if (message.method === 'Runtime.exceptionThrown') errors.push(message.params.exceptionDetails.exception?.description || message.params.exceptionDetails.text);
});
const call = (method, params = {}) => new Promise((resolve, reject) => {
  const id = ++sequence; pending.set(id, { resolve, reject }); ws.send(JSON.stringify({ id, method, params }));
  setTimeout(() => { if (pending.delete(id)) reject(new Error('CDP timeout: ' + method)); }, 15000).unref();
});
const evaluate = async expression => {
  const result = await call('Runtime.evaluate', { expression, returnByValue: true, awaitPromise: true });
  if (result.exceptionDetails) throw new Error(result.exceptionDetails.exception?.description || result.exceptionDetails.text);
  return result.result.value;
};
const wait = ms => new Promise(resolve => setTimeout(resolve, ms));
const expectState = async (expression, message) => {
  const deadline = Date.now() + 3000;
  while (Date.now() < deadline) {
    if (await evaluate(expression)) return;
    await wait(25);
  }
  assert.equal(await evaluate(expression), true, message);
};
const sel = id => `[data-debug-id="${id}"]`;
const el = id => `document.querySelector(${JSON.stringify(sel(id))})`;
// Let scrolling paint before measuring native input coordinates, then prove the
// visible hit target is the intended control. Never retry a dispatched action.
const pointerTarget = async selector => {
  const state = await evaluate(`(async () => { const e=document.querySelector(${JSON.stringify(selector)}); if (!e) throw new Error('Missing control: ' + ${JSON.stringify(selector)}); e.scrollIntoView({block:'center',behavior:'instant'}); await new Promise(resolve=>requestAnimationFrame(()=>requestAnimationFrame(resolve))); const r=e.getBoundingClientRect(), x=r.x+r.width/2, y=r.y+r.height/2, hit=document.elementFromPoint(x,y); return {x,y,hit:e.contains(hit),width:r.width,height:r.height,disabled:e.matches(':disabled')}; })()`);
  assert.ok(state.width > 0 && state.height > 0 && !state.disabled && state.hit, `visible enabled pointer target: ${selector}`);
  return { x: state.x, y: state.y };
};
const clickSelector = async selector => {
  const point = await pointerTarget(selector);
  await call('Input.dispatchMouseEvent', { type: 'mouseMoved', ...point });
  await call('Input.dispatchMouseEvent', { type: 'mousePressed', ...point, button: 'left', clickCount: 1 });
  await call('Input.dispatchMouseEvent', { type: 'mouseReleased', ...point, button: 'left', clickCount: 1 });
  await wait(350);
};
const click = id => clickSelector(sel(id));
// Deliberate parent-driven cleanup while a modal blocks background pointer input.
const activate = async id => { await evaluate(`${el(id)}.click()`); await wait(350); };
const expand = async target => {
  const id = 'home-fleet-expand-mock-bridge-0';
  if (await evaluate(`${el(id)}.getAttribute('aria-expanded')`) !== String(target)) await (target ? click(id) : activate(id));
  assert.equal(await evaluate(`${el(id)}.getAttribute('aria-expanded')`), String(target), 'required disclosure state');
};
const key = async (key, code, virtualKey) => {
  await call('Input.dispatchKeyEvent', { type: 'keyDown', key, code, windowsVirtualKeyCode: virtualKey, ...(key === 'Enter' ? { text: '\r' } : {}) });
  await call('Input.dispatchKeyEvent', { type: 'keyUp', key, code, windowsVirtualKeyCode: virtualKey });
  await wait(350);
};
const escape = () => key('Escape', 'Escape', 27);
const metrics = width => call('Emulation.setDeviceMetricsOverride', { width, height: 900, deviceScaleFactor: 1, mobile: false });
const mutations = () => evaluate('window.__fleetFixtureRequests.filter(r => /\\/(apply|retry)$/.test(r.path))');
const clean = async () => {
  assert.equal(await evaluate('document.querySelectorAll("[role=dialog], [role=listbox]").length'), 0, 'no orphan presentations');
  assert.equal(await evaluate('document.body.style.overflow'), '', 'background scroll released');
};
async function screenshot(name) {
  const shot = await call('Page.captureScreenshot', { format: 'png' });
  const file = path.join(output, name + '.png'); await fs.writeFile(file, Buffer.from(shot.data, 'base64')); return file;
}
async function inspect(narrow, label) {
  const state = await evaluate(`(() => {
    const list = document.querySelector('[role=listbox]'), dialog = list?.closest('[role=dialog]');
    const panel = dialog || list, r = panel.getBoundingClientRect(), active = list.getAttribute('aria-activedescendant');
    return { lists: document.querySelectorAll('[role=listbox]').length, dialogs: document.querySelectorAll('[role=dialog]').length,
      inDialog: !!dialog, modal: dialog?.getAttribute('aria-modal'), name: dialog?.getAttribute('aria-label') || document.getElementById(dialog?.getAttribute('aria-labelledby'))?.textContent,
      focused: panel.contains(document.activeElement), active: active ? document.getElementById(active)?.textContent : null,
      x:r.x, right:r.right, y:r.y, bottom:r.bottom, height:r.height,
      rows: [...list.querySelectorAll('[role=option]')].map(o => ({ height:o.getBoundingClientRect().height, selected:o.getAttribute('aria-selected'), disabled:o.getAttribute('aria-disabled'), text:o.textContent })),
      overflow: panel.scrollWidth > panel.clientWidth, bodyLock: document.body.style.overflow };
  })()`);
  assert.equal(state.lists, 1); assert.equal(state.inDialog, narrow);
  if (narrow) {
    assert.equal(state.dialogs, 1); assert.equal(state.modal, 'true'); assert.equal(state.focused, true);
    assert.ok(state.name.includes(label)); assert.equal(state.bodyLock, 'hidden');
    assert.ok(state.x >= 0 && state.right <= await evaluate('innerWidth') + 1);
    assert.ok(state.y >= 0 && state.bottom <= 901 && state.height <= 721);
    assert.ok(state.rows.every(row => row.height >= 44), '44px choice targets');
    assert.equal(state.overflow, false, 'long labels wrap inside the sheet');
  } else assert.equal(state.dialogs, 0);
  return state;
}
async function choose(label) {
  const id = await evaluate(`[...document.querySelectorAll('[role=listbox] [role=option]')].find(o => o.textContent === ${JSON.stringify(label)})?.id`);
  assert.ok(id, `choice exists: ${label}`);
  await clickSelector(`[id=${JSON.stringify(id)}]`);
}
async function touch(selector) {
  const point = await pointerTarget(selector);
  await call('Emulation.setTouchEmulationEnabled', { enabled: true });
  await call('Input.dispatchTouchEvent', { type: 'touchStart', touchPoints: [point] });
  await call('Input.dispatchTouchEvent', { type: 'touchEnd', touchPoints: [] });
  await wait(350);
  await call('Emulation.setTouchEmulationEnabled', { enabled: false });
}
await call('Page.enable'); await call('Runtime.enable'); await call('Page.bringToFront');
await call('Emulation.setFocusEmulationEnabled', { enabled: true });
// Each width mounts a fresh HomeLayoutSession. Reset its backing store before
// application scripts load, so a version loaded by Home is never deleted later.
await call('Page.addScriptToEvaluateOnNewDocument', { source: 'localStorage.clear();' });
try {
  for (const width of [320, 390, 767, 768, 1440]) {
    const narrow = width < 768, report = { width, checks: [], files: [] };
    reports.push(report); await metrics(width);
    await call('Emulation.setEmulatedMedia', { features: [{ name: 'prefers-reduced-motion', value: 'no-preference' }] });
    await call('Page.navigate', { url: `${origin}/tests/fixtures/home-widgets/index.html?sheet-probes=1&probe=${Date.now()}` });
    let ready = false;
    for (let i = 0; i < 120; i++) {
      if (await evaluate(`!!${el('home-fleet-default-mock-bridge-0-provider')}`)) { ready = true; break; }
      await wait(100);
    }
    assert.ok(ready, 'fixture loaded'); await wait(500);
    assert.equal(await evaluate("localStorage.getItem('heimdall:home-layout:home-visual-fixture')"), null, 'layout storage reset before fixture mount');
    assert.equal(await evaluate(`!!${el('home-layout-slot-chains')} && !${el('home-layout-add-chains')}`), true, 'initial widget is visible');
    assert.equal(await evaluate(`${el('home-layout-edit')}.getAttribute('aria-pressed')`), 'false', 'initial layout editing is closed');
    await clean();
    report.checks.push('isolated layout storage before mount');
    const base = 'home-fleet-default-mock-bridge-0';
    await click(base + '-provider'); report.defaultChoice = await inspect(narrow, 'default provider');
    report.files.push(await screenshot(`sheets-${width}-provider`));
    if (!narrow) assert.equal(await evaluate('document.activeElement.dataset.debugId'), base + '-provider', 'desktop keyboard owner is the trigger');
    await key('End', 'End', 35); await key('Enter', 'Enter', 13);
    // Custom labels require the user's unlocked vault. This isolated fixture
    // intentionally exercises the canonical profile-id fallback instead.
    assert.equal(await evaluate(`${el(base + '-provider')}.textContent`), 'second-profile');
    assert.match(await evaluate(`${el(base + '-model')}.textContent`), /profile-model-0/, 'profile identity resets model');
    await click(base + '-model'); await inspect(narrow, 'default model');
    if (narrow) await touch('[role=listbox] [role=option]:last-child'); else await choose('profile-model-39');
    assert.match(await evaluate(`${el(base + '-model')}.textContent`), /profile-model-39/);
    report.checks.push('default provider/profile identity and model reset', 'default model long-list selection', ...(narrow ? ['native touch selection'] : []));
    await expand(true);
    for (const suffix of ['agent', 'provider', 'model']) {
      const id = 'home-fleet-override-mock-bridge-0-mock-worker-' + suffix;
      await click(id); await inspect(narrow, suffix === 'agent' ? 'override agent' : `override ${suffix}`);
      await escape(); assert.equal(await evaluate('document.activeElement.dataset.debugId'), id);
    }
    await click('home-fleet-override-mock-bridge-0-mock-worker-model');
    await expand(false); await clean();
    assert.equal(await evaluate('document.activeElement.dataset.debugId'), 'home-fleet-expand-mock-bridge-0');
    await expand(true); await click(base + '-model'); await expand(false); await clean();
    assert.match(await evaluate(`${el(base + '-model')}.textContent`), /profile-model-39/);
    report.checks.push('all override categories', 'Escape focus/no mutation', 'collapse clears default and override overlays; draft retained');
    await click(base + '-provider'); await metrics(narrow ? 768 : 767); await wait(400); await clean();
    await metrics(width); await wait(100); await click(base + '-provider'); await escape();
    report.checks.push('open breakpoint crossing cleanup');
    await click('home-layout-edit');
    await click(narrow ? 'home-layout-options-chains' : 'home-layout-handle-chains');
    assert.equal(await evaluate('!!document.querySelector("[role=dialog]")'), narrow);
    if (narrow) {
      const heights = await evaluate('[...document.querySelectorAll("[role=dialog] [role=menuitem]")].map(e=>e.getBoundingClientRect().height)');
      assert.ok(heights.every(h => h >= 44));
      report.files.push(await screenshot(`sheets-${width}-actions`));
    }
    await click('home-layout-menu-remove-chains'); await clean();
    await expectState(`!${el('home-layout-slot-chains')} && !!${el('home-layout-add-chains')}`, 'remove action hides widget and exposes re-add control');
    if (narrow) assert.equal(await evaluate('document.activeElement.dataset.debugId'), 'home-layout-edit');
    await click('home-layout-add-chains');
    await click('home-layout-add-menu');
    await click('home-layout-toggle-chains');
    if (narrow) {
      assert.equal(await evaluate(`${el('home-layout-add-menu')}.getAttribute('aria-expanded')`), 'true');
      assert.equal(await evaluate(`${el('home-layout-toggle-chains')}.getAttribute('aria-checked')`), 'false');
      await click('home-layout-toggle-chains'); await escape();
    } else {
      await expectState(`${el('home-layout-add-menu')}.getAttribute('aria-expanded') === 'false' && !${el('home-layout-slot-chains')}`, 'desktop toggle hides widget and closes menu');
      await click('home-layout-add-menu');
      await expectState(`${el('home-layout-toggle-chains')}?.getAttribute('aria-checked') === 'false'`, 'desktop reopened menu reflects hidden widget');
      await click('home-layout-toggle-chains');
      await expectState(`!!${el('home-layout-handle-chains')} && ${el('home-layout-add-menu')}.getAttribute('aria-expanded') === 'false'`, 'desktop toggle restores widget and closes menu');
    }
    await click(narrow ? 'home-layout-options-chains' : 'home-layout-handle-chains');
    await activate('home-layout-edit'); await clean();
    await click(base + '-model'); await activate('home-layout-edit'); await clean();
    assert.match(await evaluate(`${el(base + '-model')}.textContent`), /profile-model-39/);
    await click('home-layout-edit');
    report.checks.push('widget removal focus', 'widget action edit completion', 'Fleet edit completion retains draft', 'Add-widget mobile multi-toggle / desktop preserved');
    await click('home-probe-unavailable'); report.unavailable = await inspect(narrow, 'Unavailable saved choice');
    assert.equal(report.unavailable.rows[0].selected, 'true'); assert.equal(report.unavailable.rows[0].disabled, 'true');
    await evaluate('document.querySelector("[role=listbox] [aria-disabled=true]").click()');
    assert.equal(await evaluate(`${el('home-probe-value')}.textContent`), 'missing');
    await key('End', 'End', 35);
    if (narrow) {
      const active = await evaluate(`(() => { const l=document.querySelector('[role=listbox]'), a=document.getElementById(l.getAttribute('aria-activedescendant')), r=a.getBoundingClientRect(); return {y:r.y,bottom:r.bottom}; })()`);
      assert.ok(active.y >= 0 && active.bottom <= 901, 'last long-label row reachable');
      report.files.push(await screenshot(`sheets-${width}-long-options`));
      await key('Tab', 'Tab', 9);
      assert.equal(await evaluate('!!document.activeElement.closest("[role=dialog]")'), true, 'Tab remains in sheet');
    }
    await escape();
    for (const probe of ['empty', 'disabled']) {
      await click('home-probe-' + probe); const state = await inspect(narrow, probe === 'empty' ? 'Empty choices' : 'Only unavailable choices');
      if (narrow) assert.equal(state.active, null);
      await key('Enter', 'Enter', 13); assert.equal(await evaluate(`${el('home-probe-value')}.textContent`), 'missing'); await escape();
    }
    if (narrow) {
      await call('Emulation.setEmulatedMedia', { features: [{ name: 'prefers-reduced-motion', value: 'reduce' }] });
      await click(base + '-model');
      assert.ok(parseFloat(await evaluate(`getComputedStyle(${el(base + '-model-sheet')}).animationDuration`)) <= .01, 'reduced motion');
      await evaluate("document.documentElement.style.setProperty('--app-viewport-height', '460px')");
      report.keyboard = await evaluate(`(() => {
        const panel=${el(base + '-model-sheet')}, overlay=panel.parentElement, root=getComputedStyle(document.documentElement);
        const box=e=>{const s=getComputedStyle(e);return {rect:e.getBoundingClientRect().toJSON(),height:s.height,maxHeight:s.maxHeight,top:s.top,transform:s.transform,animationDuration:s.animationDuration,animations:e.getAnimations().map(a=>({playState:a.playState,currentTime:a.currentTime,timing:a.effect?.getComputedTiming()}))}};
        return {panel:box(panel),overlay:box(overlay),visibility:document.visibilityState,focused:document.hasFocus(),scrollY,
          innerWidth,innerHeight,visualViewport:visualViewport&&{height:visualViewport.height,offsetTop:visualViewport.offsetTop,scale:visualViewport.scale},
          variables:Object.fromEntries(['--app-viewport-height','--app-viewport-offset-top','--app-viewport-bottom-offset'].map(k=>[k,{inline:document.documentElement.style.getPropertyValue(k),computed:root.getPropertyValue(k)}]))};
      })()`);
      assert.ok(report.keyboard.panel.rect.bottom <= 461, 'sheet follows visible-height variable used for software keyboard');
      await escape(); await evaluate("document.documentElement.style.removeProperty('--app-viewport-height')");
      await click(base + '-model');
      await evaluate(`(() => { const d=document.querySelector('[role=dialog]'); d.parentElement.dispatchEvent(new MouseEvent('mousedown',{bubbles:true})); })()`);
      await wait(350); await clean();
    }
    report.checks.push('disabled/unavailable/empty choices', 'long-label overflow and last-row reachability', ...(narrow ? ['Tab focus trap', 'reduced motion', 'visible keyboard-height cap', 'backdrop dismissal'] : []));
    assert.deepEqual(await mutations(), [], 'no Apply or retry from any choice/lifecycle action');
    await click(base + '-model'); await evaluate("window.__homeFixtureRender('other-account')"); await wait(500); await clean();
    await click(base + '-model'); await evaluate('window.__homeFixtureRender(null)'); await wait(350); await clean();
    report.checks.push('account switch cleanup', 'route unmount cleanup', 'no Apply/retry requests');
  }
  assert.deepEqual(errors, [], 'browser runtime errors');
  await fs.writeFile(path.join(output, 'sheets-report.json'), JSON.stringify({ result: 'PASS', errors, reports }, null, 2));
  console.log(JSON.stringify({ result: 'PASS', widths: reports.map(({ width, checks }) => ({ width, checks })), output }, null, 2));
} catch (error) {
  await fs.writeFile(path.join(output, 'sheets-failure.json'), JSON.stringify({ error: String(error), errors, reports, html: await evaluate('document.body.innerHTML.slice(-8000)') }, null, 2));
  throw error;
} finally {
  ws.close(); await fetch(`http://127.0.0.1:${port}/json/close/${tab.id}`);
}
