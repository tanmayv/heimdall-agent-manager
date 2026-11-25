// Focused real-browser disclosure/motion regression. Start the isolated Vite
// fixture and a headless Chromium CDP endpoint, then run this file with Node.
import fs from 'node:fs/promises';
import path from 'node:path';
import assert from 'node:assert/strict';
import WebSocket from 'ws';

const output = process.argv[2] || '/tmp/fleet-disclosure-captures';
const port = process.env.HOME_CDP_PORT || 9341;
const origin = process.env.HOME_FIXTURE_ORIGIN || 'http://127.0.0.1:5191';
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
  if (message.method === 'Runtime.exceptionThrown') errors.push(message.params.exceptionDetails.exception?.description || message.params.exceptionDetails.text);
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
const first = 'mock-bridge-0';
const selector = (id) => `[data-debug-id="${id}"]`;
const click = (id) => evaluate(`document.querySelector(${JSON.stringify(selector(id))}).click()`);
const body = `document.querySelector('${selector('home-fleet-body-' + first)}')`;
const toggle = `document.querySelector('${selector('home-fleet-expand-' + first)}')`;
async function navigate(state, hash = '') {
  // A fresh document is required: changing only the hash keeps this standalone
  // fixture mounted (the production app router is deliberately outside it).
  await call('Page.navigate', { url: `${origin}/tests/fixtures/home-widgets/index.html?fleet-state=${state}&probe=${Date.now()}${hash}` });
  for (let i = 0; i < 120; i++) {
    if (await evaluate(`Boolean(${body} && document.querySelector('${selector('home-fleet-' + (state === 'status-error' ? 'error' : 'result') + '-' + first)}'))`)) {
      await evaluate('document.fonts.ready'); await wait(300); return;
    }
    await wait(100);
  }
  throw new Error('Fleet fixture did not settle: ' + JSON.stringify({ state, errors, html: await evaluate('document.body.innerHTML.slice(0,3000)') }));
}
async function key(key, code, virtualKey) {
  await call('Input.dispatchKeyEvent', { type: 'keyDown', key, code, windowsVirtualKeyCode: virtualKey, ...(key === 'Enter' ? { text: '\r', unmodifiedText: '\r' } : {}) });
  await call('Input.dispatchKeyEvent', { type: 'keyUp', key, code, windowsVirtualKeyCode: virtualKey });
}
const geometry = () => evaluate(`(() => {
  const panel = ${body}, bridge = panel.parentElement, header = bridge.querySelector('.home-fleet-bridge-header');
  return { height: panel.getBoundingClientRect().height, contentHeight: panel.firstElementChild.scrollHeight,
    expanded: ${toggle}.getAttribute('aria-expanded'), hidden: panel.getAttribute('aria-hidden'), inert: panel.inert,
    visibility: getComputedStyle(panel).visibility, panelId: panel.id, controls: ${toggle}.getAttribute('aria-controls'),
    bridgeHeight: bridge.getBoundingClientRect().height, headerHeight: header.getBoundingClientRect().height,
    viewport: innerWidth, pageWidth: document.documentElement.scrollWidth };
})()`);
async function capture(width, state) {
  await evaluate('window.scrollTo(0,0)');
  const height = await evaluate('Math.ceil(document.documentElement.scrollHeight)');
  const result = await call('Page.captureScreenshot', { format: 'png', captureBeyondViewport: true, clip: { x: 0, y: 0, width, height, scale: 1 } });
  const file = path.join(output, `fleet-${width}-${state}.png`);
  await fs.writeFile(file, Buffer.from(result.data, 'base64'));
  const clip = await evaluate(`(() => { const r = document.querySelector('${selector('home-widget-fleet')}').getBoundingClientRect(); return { x: r.x + scrollX, y: r.y + scrollY, width: r.width, height: r.height, scale: 1 }; })()`);
  const detail = await call('Page.captureScreenshot', { format: 'png', captureBeyondViewport: true, clip });
  await fs.writeFile(file.replace('.png', '-detail.png'), Buffer.from(detail.data, 'base64'));
  return file;
}
// Sample real layout on animation frames; no fake timers or DOM-only motion assertion.
const motion = (reverse = false) => evaluate(`new Promise((resolve) => {
  const panel = ${body}, button = ${toggle}, samples = [], start = performance.now();
  const reversals = ${JSON.stringify(reverse ? [45, 80, 115] : [])};
  let nextReversal = 0;
  button.click();
  const frame = (now) => {
    samples.push({ ms: now - start, height: panel.getBoundingClientRect().height });
    if (nextReversal < reversals.length && now - start >= reversals[nextReversal]) { button.click(); nextReversal++; }
    if (now - start < 450) requestAnimationFrame(frame); else resolve(samples);
  };
  requestAnimationFrame(frame);
})`);
const mutations = () => evaluate(`window.__fleetFixtureRequests.filter(r => r.path.endsWith('/apply') || r.path.endsWith('/retry'))`);
const reports = [];
await call('Page.enable'); await call('Runtime.enable'); await call('Page.bringToFront');
await call('Emulation.setFocusEmulationEnabled', { enabled: true });
try {
  for (const width of [1440, 390]) {
    await call('Emulation.setDeviceMetricsOverride', { width, height: 1000, deviceScaleFactor: 1, mobile: width < 768 });
    await call('Emulation.setEmulatedMedia', { features: [{ name: 'prefers-reduced-motion', value: 'no-preference' }] });
    await navigate('partial-failure');
    const initial = await geometry();
    assert.equal(initial.expanded, 'true');
    assert.equal(initial.controls, initial.panelId);
    assert.ok(Math.abs(initial.height - initial.contentHeight) <= 1, 'expanded wrapping result content is not clipped');
    assert.ok(initial.pageWidth <= width, 'no horizontal overflow');
    const other = await evaluate(`(() => { const panel = [...document.querySelectorAll('.home-fleet-body')][1]; return { height: panel.getBoundingClientRect().height, inert: panel.inert, hidden: panel.getAttribute('aria-hidden') }; })()`);
    assert.deepEqual(other, { height: 0, inert: true, hidden: 'true' }, 'second bridge initially fully collapsed');
    const originalResult = await evaluate(`document.querySelector('${selector('home-fleet-result-' + first)}').textContent`);
    const beforeMutations = await mutations();
    const expandedFile = await capture(width, 'expanded-result');
    // Change a real draft value, then keep it through every following toggle.
    await click(`home-fleet-default-${first}-provider`);
    await evaluate(`[...document.querySelectorAll('[role="option"]')].find(el => el.textContent === 'Codex').click()`);
    const draft = await evaluate(`document.querySelector('${selector('home-fleet-default-' + first + '-provider')}').textContent`);
    const closing = await motion();
    const collapsed = await geometry();
    assert.equal(collapsed.height, 0);
    assert.equal(collapsed.bridgeHeight, collapsed.headerHeight, 'no footer border or residual body gap');
    assert.equal(collapsed.inert, true); assert.equal(collapsed.hidden, 'true');
    assert.equal(collapsed.visibility, 'hidden');
    assert.ok(closing.some(s => s.height > 1 && s.height < initial.height - 1), 'visible closing motion');
    // Native browser focus refuses an inert descendant and native Tab skips it.
    await evaluate(`${toggle}.focus(); ${body}.querySelector('button').focus()`);
    assert.equal(await evaluate('document.activeElement.dataset.debugId'), 'home-fleet-expand-' + first);
    await key('Tab', 'Tab', 9);
    assert.equal(await evaluate(`${body}.contains(document.activeElement)`), false);
    const ax = await call('Accessibility.getFullAXTree');
    assert.equal(ax.nodes.some(n => !n.ignored && n.role?.value === 'button' && n.name?.value === 'Retry failed restarts'), false, 'hidden retry absent from accessibility tree');
    const collapsedFile = await capture(width, 'collapsed-draft');
    const opening = await motion();
    assert.ok(opening.some(s => s.height > 1 && s.height < initial.height - 1), 'visible opening motion');
    const reversal = await motion(true); // close/open/close/open while still moving
    const reopened = await geometry();
    assert.equal(reopened.expanded, 'true');
    assert.ok(Math.abs(reopened.height - reopened.contentHeight) <= 1);
    assert.ok(reversal.some((s, i) => i > 0 && s.height < reversal[i - 1].height - .1), 'reversal shrinks first');
    assert.ok(reversal.some((s, i) => i > 0 && s.height > reversal[i - 1].height + .1), 'reversal grows afterwards');
    assert.equal(await evaluate(`document.querySelector('${selector('home-fleet-default-' + first + '-provider')}').textContent`), draft);
    assert.equal(await evaluate(`document.querySelector('${selector('home-fleet-result-' + first)}').textContent`), originalResult);
    // Programmatic collapse with focus in an open portalled Select.
    const override = await evaluate(`${body}.querySelector('[role="combobox"]').dataset.debugId`);
    await click(override); await evaluate(`document.querySelector('${selector(override)}').focus()`);
    await click('home-fleet-expand-' + first);
    assert.equal(await evaluate('document.activeElement.dataset.debugId'), 'home-fleet-expand-' + first);
    assert.equal(await evaluate(`Boolean(document.querySelector('[role="listbox"]'))`), false);
    await wait(250);
    await key('Enter', 'Enter', 13); await wait(250);
    assert.equal((await geometry()).expanded, 'true', 'native Enter opens');
    await key(' ', 'Space', 32); await wait(250);
    assert.equal((await geometry()).expanded, 'false', 'native Space closes');
    if (width < 768) {
      await call('Emulation.setTouchEmulationEnabled', { enabled: true });
      const target = await evaluate(`(() => { ${toggle}.scrollIntoView({block:'center'}); const r = ${toggle}.getBoundingClientRect(); return {x:r.x+r.width/2,y:r.y+r.height/2,width:r.width,height:r.height}; })()`);
      assert.ok(target.height >= 44 && target.width >= 44, 'touch target');
      await call('Input.dispatchTouchEvent', { type: 'touchStart', touchPoints: [{ x: target.x, y: target.y }] });
      await call('Input.dispatchTouchEvent', { type: 'touchEnd', touchPoints: [] });
      await wait(300);
      assert.equal((await geometry()).expanded, 'true', 'native touch opens');
      await call('Emulation.setTouchEmulationEnabled', { enabled: false });
    } else { await click('home-fleet-expand-' + first); await wait(250); }
    await call('Emulation.setEmulatedMedia', { features: [{ name: 'prefers-reduced-motion', value: 'reduce' }] });
    const reducedClose = await motion();
    assert.ok(reducedClose.every(s => s.height === 0), 'reduced motion closes immediately');
    const reducedOpen = await motion();
    const reducedFull = (await geometry()).height;
    assert.ok(reducedOpen.every(s => Math.abs(s.height - reducedFull) <= 1), 'reduced motion opens immediately');
    assert.deepEqual(await mutations(), beforeMutations, 'toggles never Apply or retry');
    reports.push({ width, initial, other, collapsed, reopened, closing, opening, reversal, reducedClose, reducedOpen, expandedFile, collapsedFile,
      checks: ['zero residual space', 'bidirectional real frame motion', 'rapid reversal', 'draft/result retained', 'no mutations', 'inert/Tab/AX', 'portalled Select cleared', 'focus return', 'native Enter/Space', ...(width < 768 ? ['native touch/44px'] : []), 'reduced motion'] });
    await navigate('partial-failure', '#/?widget=fleet&bridge=mock-bridge-1&agent=mock-worker');
    assert.equal(await evaluate(`document.querySelector('${selector('home-fleet-expand-mock-bridge-1')}').getAttribute('aria-expanded')`), 'true');
    assert.equal(await evaluate(`document.activeElement.closest('.home-fleet-bridge')?.dataset.debugId`), 'home-fleet-bridge-mock-bridge-1');
    reports.at(-1).deepLink = await evaluate('document.activeElement.dataset.debugId');
    await navigate('partial-failure', '#/?widget=fleet&bridge=mock-bridge-0&agent=mock-worker');
    assert.equal(await evaluate('document.activeElement.dataset.debugId'), 'home-fleet-override-mock-bridge-0-mock-worker-agent', 'deep link focuses the requested agent control');
    reports.at(-1).agentDeepLink = await evaluate('document.activeElement.dataset.debugId');
    await navigate('status-error');
    const error = await evaluate(`document.querySelector('${selector('home-fleet-error-' + first)}').textContent`);
    await click('home-fleet-expand-' + first); await wait(250);
    assert.equal((await geometry()).height, 0);
    await click('home-fleet-expand-' + first); await wait(250);
    assert.equal(await evaluate(`document.querySelector('${selector('home-fleet-error-' + first)}').textContent`), error);
    reports.at(-1).retainedErrorFile = await capture(width, 'reopened-error');
  }
  assert.deepEqual(errors, [], 'browser runtime errors');
  await fs.writeFile(path.join(output, 'fleet-report.json'), JSON.stringify({ errors, reports }, null, 2));
  console.log(JSON.stringify({ result: 'PASS', widths: reports.map(r => ({ width: r.width, checks: r.checks, expandedFile: r.expandedFile, collapsedFile: r.collapsedFile, retainedErrorFile: r.retainedErrorFile, deepLink: r.deepLink })), output }, null, 2));
} finally {
  ws.close();
  await fetch(`http://127.0.0.1:${port}/json/close/${tab.id}`);
}
