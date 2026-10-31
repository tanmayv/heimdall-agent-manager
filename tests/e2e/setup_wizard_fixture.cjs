// Run with Electron and SETUP_WIZARD_FIXTURE_URL pointing at the local dev fixture.
// No real native operations or API requests are permitted by this runner.
const { app, BrowserWindow, session } = require('electron');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const target = new URL(process.env.SETUP_WIZARD_FIXTURE_URL || 'http://127.0.0.1:5173/setup-wizard-demo.html');
assert.ok(['127.0.0.1', 'localhost'].includes(target.hostname), 'fixture must use a local dev server');
assert.ok(target.pathname.endsWith('/setup-wizard-demo.html'));
const output = process.env.SETUP_WIZARD_EVIDENCE_DIR;
const results = [];
let win;
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
const js = (source) => win.webContents.executeJavaScript(source, true);
const selector = (id) => `[data-debug-id="${id}"]`;
async function wait(id) {
  for (let n = 0; n < 300; n++) {
    if (await js(`Boolean(document.querySelector(${JSON.stringify(selector(id))}))`)) return;
    await sleep(50);
  }
  throw new Error(`Missing ${id}: ${await js('document.body.innerText')}`);
}
async function click(id) {
  await wait(id);
  await js(`document.querySelector(${JSON.stringify(selector(id))}).click()`);
}
async function exists(id) {
  return js(`Boolean(document.querySelector(${JSON.stringify(selector(id))}))`);
}
async function load(scenario) {
  const url = new URL(target);
  url.searchParams.set('scenario', scenario);
  await win.loadURL(url.href);
  await wait('setup-wizard-page');
}
async function record(name) {
  if (output) {
    // DOM assertions can finish before Chromium paints the new React commit.
    await sleep(100);
    fs.mkdirSync(output, { recursive: true });
    fs.writeFileSync(path.join(output, name + '.png'), (await win.webContents.capturePage()).toPNG());
  }
  results.push(name);
  console.log('PASS ' + name);
}
async function projects(empty) {
  await click('setup-machine-continue-btn');
  await wait('provider-setup-apply-btn');
  await record('agents');
  await click('provider-setup-apply-btn');
  await wait(empty ? 'setup-projects-empty' : 'setup-projects-list');
  await record(empty ? 'projects-empty' : 'projects-found');
}
async function identity(scenario) {
  await load(scenario);
  await click('setup-install-btn');
  await wait('setup-identity-approve-btn');
}

app.whenReady().then(async () => {
  // Defense in depth: the renderer guard must absorb every API request. Block
  // anything that escapes it, and all external origins, before it reaches a hub.
  session.defaultSession.webRequest.onBeforeRequest((details, callback) => {
    const url = new URL(details.url);
    callback({ cancel: url.origin !== target.origin || url.pathname.includes('/api/v1/') });
  });
  win = new BrowserWindow({ width: 1120, height: 700, show: false, webPreferences: { nodeIntegration: false, contextIsolation: true, offscreen: true, backgroundThrottling: false } });
  try {
    await load('fresh');
    await wait('setup-install-btn');
    await record('fresh-machine');
    await load('config-retry');
    await click('setup-detect-retry-btn');
    await wait('setup-install-btn');
    await record('config-retry');
    for (const scenario of ['connected', 'update', 'no-artifact']) {
      await load(scenario);
      await wait('setup-machine-continue-btn');
      assert.equal(await exists('setup-machine-update-btn'), scenario === 'update');
      await record(scenario);
    }
    await projects(false);
    // Real layout verification at short desktop and narrow mobile sizes.
    for (const [width, height] of [[1000, 360], [390, 360]]) {
      win.setContentSize(width, height);
      await sleep(100);
      const layout = await js(`(() => {
        const pane = document.querySelector('[data-debug-id="setup-pane"]');
        const rail = document.querySelector('[data-debug-id="setup-rail"]');
        const railTop = rail.getBoundingClientRect().top;
        pane.scrollTop = pane.scrollHeight;
        return { paneScrolls: pane.scrollTop > 0, railFixed: railTop === rail.getBoundingClientRect().top,
          hidden: getComputedStyle(rail).display === 'none', step: pane.innerText.includes('Step 5 of 5'),
          pageScrolls: document.documentElement.scrollHeight > innerHeight };
      })()`);
      assert.equal(layout.paneScrolls, true, JSON.stringify(layout));
      assert.equal(layout.railFixed, true);
      assert.equal(layout.hidden, width < 768);
      assert.equal(layout.pageScrolls, false);
      if (width < 768) assert.equal(layout.step, true);
      await record(`scroll-${width}x${height}`);
    }
    win.setContentSize(1120, 700);
    await load('empty-projects');
    await projects(true);
    await click('setup-projects-continue-btn');
    assert.equal(await js('location.hash'), '#/conversations/new');
    assert.equal(await js('localStorage.getItem("ninjy.setup.done.usr_fixture")'), '1');
    assert.equal(await js('localStorage.getItem("ninjy.setup.done.someone_else")'), null);
    await record('finish-user-keyed');
    await load('connected');
    await js('localStorage.removeItem("ninjy.setup.done.usr_fixture")');
    await click('setup-skip-btn');
    assert.equal(await js('location.hash'), '#/home');
    assert.equal(await js('localStorage.getItem("ninjy.setup.done.usr_fixture")'), '1');
    await record('skip');
    await load('install-fails');
    await click('setup-install-btn');
    await wait('setup-install-failed');
    await record('install-failure');
    await click('setup-install-retry-btn');
    await wait('setup-install-cancel-btn');
    assert.equal(await exists('setup-install-failed'), false);
    await wait('setup-install-failed');
    await record('install-retry');
    await identity('fresh');
    assert.equal(await js('document.querySelector("[data-debug-id=setup-identity-new-radio]").checked'), true);
    await record('new-with-room');
    await identity('reuse-hint');
    await wait('setup-identity-reuse-warning');
    assert.equal(await js('document.querySelector("[data-debug-id=setup-identity-reuse-radio-brg_fixture_2]").checked'), true);
    await record('reuse');
    // A replacement request must hide the old review even when its lookup fails.
    await js(`import(performance.getEntriesByType('resource').find(e => e.name.includes('/src/ui/bridge/desktopBridgeSession.ts')).name).then(m => m.openApprovalForCode('AAAA-BBBB-CCCC-DD'))`);
    await wait('setup-identity-waiting');
    assert.equal(await exists('setup-identity-approve-btn'), false);
    await wait('setup-identity-lookup-error');
    assert.equal(await exists('setup-identity-approve-btn'), false);
    await record('reissued-code-clears-review');
    await click('setup-identity-back-btn');
    await click('setup-install-identity-btn');
    await wait('setup-identity-approve-btn');
    await wait('setup-identity-reuse-warning');
    await record('identity-back-and-retry');
    await identity('full-plan');
    assert.equal(await js('document.querySelector("[data-debug-id=setup-identity-approve-btn]").disabled'), true);
    await click('setup-identity-new-radio');
    await click('setup-identity-sunset-brg_fixture_2');
    await wait('setup-identity-sunset-warning');
    assert.equal(await js('document.querySelector("[data-debug-id=setup-identity-approve-btn]").disabled'), false);
    await record('plan-limit-sunset');
    // The fixture has no device signer: refusal must be visible, without a real write.
    await click('setup-identity-approve-btn');
    await wait('setup-identity-error');
    await record('approval-without-signer-refused');
    console.log(JSON.stringify({ passed: results.length, results }));
    app.exit(0);
  } catch (error) {
    console.error(error);
    app.exit(1);
  }
});
