// Real browser clients -> Vite proxy -> production HTTP/auth/service -> SQLite.
// Requires a compiled tests/fixtures/home-layout-hub binary and Nix Chromium.
import fs from 'node:fs/promises';
import path from 'node:path';
import assert from 'node:assert/strict';
import { spawn, execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { once } from 'node:events';
import WebSocket from 'ws';

const output = path.resolve(process.argv[2] || '');
assert.ok(process.argv[2] && process.env.HOME_HUB_BINARY && process.env.HOME_CHROMIUM, 'output, HOME_HUB_BINARY and HOME_CHROMIUM required');
await fs.mkdir(output); // Never reuse evidence or a browser profile.
const uiPort = Number(process.env.HOME_UI_PORT || 5196), hubPort = Number(process.env.HOME_HUB_PORT || 5197);
const cdpPort = Number(process.env.HOME_CDP_PORT || 9346), origin = `http://127.0.0.1:${uiPort}`;
const started = { startedAt: new Date().toISOString(), pid: process.pid, output, origin, uiPort, hubPort, cdpPort,
  sha: process.env.HOME_CAPTURE_SHA, tree: process.env.HOME_CAPTURE_TREE, binary: process.env.HOME_HUB_BINARY };
const git = (...args) => execFileSync('git', args, { encoding: 'utf8' }).trim();
started.actualSha = git('rev-parse', 'HEAD'); started.actualTree = git('rev-parse', 'HEAD^{tree}');
started.dirty = git('status', '--porcelain') !== '';
if (!process.env.HOME_CAPTURE_DEVELOPMENT) {
  assert.equal(started.sha, started.actualSha); assert.equal(started.tree, started.actualTree);
  assert.equal(started.dirty, false, 'final browser evidence requires a clean checkout');
}
started.binarySha256 = createHash('sha256').update(await fs.readFile(started.binary)).digest('hex');
started.lockSha256 = createHash('sha256').update(await fs.readFile('package-lock.json')).digest('hex');
await fs.writeFile(path.join(output, 'capture-start.json'), JSON.stringify(started, null, 2));
const reports = [], children = [], sockets = [], errors = [];
const wait = ms => new Promise(resolve => setTimeout(resolve, ms));
function start(command, args, name, env = process.env) {
  const child = spawn(command, args, { env, stdio: ['ignore', 'pipe', 'pipe'] });
  const log = [];
  child.stdout.on('data', data => log.push(data)); child.stderr.on('data', data => log.push(data));
  child.on('error', error => errors.push(`${name}: ${error.message}`));
  children.push({ child, log, name }); return child;
}
async function stop(child) {
  if (child.exitCode !== null || child.signalCode !== null) return;
  child.kill('SIGTERM');
  await Promise.race([once(child, 'exit'), wait(3000).then(() => child.kill('SIGKILL'))]);
}
async function ready(url, child) {
  const deadline = Date.now() + 30000;
  while (Date.now() < deadline) {
    assert.equal(child.exitCode, null, `server exited before ready: ${url}`);
    try { await fetch(url, { signal: AbortSignal.timeout(500) }); return; } catch { await wait(100); }
  }
  throw new Error('Server readiness timeout: ' + url);
}
function connect(url) {
  const socket = new WebSocket(url), pending = new Map(); let sequence = 0;
  sockets.push(socket);
  socket.on('message', raw => {
    const msg = JSON.parse(raw);
    if (msg.id && pending.has(msg.id)) {
      const { resolve, reject } = pending.get(msg.id); pending.delete(msg.id);
      msg.error ? reject(new Error(JSON.stringify(msg.error))) : resolve(msg.result);
    }
    if (msg.method === 'Runtime.exceptionThrown') errors.push(msg.params.exceptionDetails.exception?.description || msg.params.exceptionDetails.text);
  });
  return {
    opened: once(socket, 'open'),
    call: (method, params = {}) => new Promise((resolve, reject) => {
      const id = ++sequence; pending.set(id, { resolve, reject }); socket.send(JSON.stringify({ id, method, params }));
      setTimeout(() => { if (pending.delete(id)) reject(new Error('CDP timeout: ' + method)); }, 15000).unref();
    }),
  };
}
async function browserClient(browser, user = 'layout_browser', width = 1440) {
  const { browserContextId } = await browser.call('Target.createBrowserContext');
  const { targetId } = await browser.call('Target.createTarget', { url: 'about:blank', browserContextId });
  const tabs = await (await fetch(`http://127.0.0.1:${cdpPort}/json/list`)).json();
  const client = connect(tabs.find(tab => tab.id === targetId).webSocketDebuggerUrl);
  await client.opened;
  const call = client.call;
  const evaluate = async expression => {
    const result = await call('Runtime.evaluate', { expression, returnByValue: true, awaitPromise: true });
    if (result.exceptionDetails) throw new Error(result.exceptionDetails.exception?.description || result.exceptionDetails.text);
    return result.result.value;
  };
  const until = async (expression, label) => {
    const deadline = Date.now() + 10000;
    while (Date.now() < deadline) { if (await evaluate(expression)) return; await wait(25); }
    throw new Error('Browser condition failed: ' + label);
  };
  await call('Runtime.enable'); await call('Page.enable'); await call('Network.enable');
  const metrics = async value => call('Emulation.setDeviceMetricsOverride', { width: value, height: 1000, deviceScaleFactor: 1, mobile: false });
  await metrics(width);
  await call('Page.navigate', { url: `${origin}/tests/fixtures/home-widgets/?real-layout&layout-user=${user}` });
  await until('window.__homeFixtureUser && document.querySelector("[data-debug-id=home-layout-edit]")?.disabled === false', 'layout loaded and editable');
  const api = (method = 'GET', layout, expectedUser) => evaluate(`(async()=>{
    const r=await fetch('/api/v1/me/home-layout',{method:${JSON.stringify(method)},headers:{'X-Heimdall-Expected-User':${JSON.stringify(expectedUser)} || window.__homeFixtureUser,
      ${layout ? `'Content-Type':'application/json','If-Match':${JSON.stringify('"' + layout.version + '"')}` : ''}},${layout ? `body:${JSON.stringify(JSON.stringify(layout))},` : ''}credentials:'include'});
    return {status:r.status,etag:r.headers.get('ETag'),body:await r.json()}; })()`);
  const click = async (id, touch = false) => {
    const point = await evaluate(`(async()=>{const e=document.querySelector('[data-debug-id=${id}]'); if(!e) throw new Error('Missing ${id}');
      e.scrollIntoView({block:'center',behavior:'instant'}); await new Promise(r=>requestAnimationFrame(()=>requestAnimationFrame(r)));
      const b=e.getBoundingClientRect(),x=b.x+b.width/2,y=b.y+b.height/2; return {x,y,width:b.width,height:b.height,hit:e.contains(document.elementFromPoint(x,y)),disabled:e.disabled};})()`);
    assert.ok(point.hit && !point.disabled, 'native target ' + id);
    const { x, y } = point;
    if (touch) {
      assert.ok(point.height >= 44 && point.width >= 44, '44px touch target');
      await call('Input.dispatchTouchEvent', { type: 'touchStart', touchPoints: [{ x, y }] });
      await call('Input.dispatchTouchEvent', { type: 'touchEnd', touchPoints: [] });
    } else {
      await call('Input.dispatchMouseEvent', { type: 'mousePressed', x, y, button: 'left', clickCount: 1 });
      await call('Input.dispatchMouseEvent', { type: 'mouseReleased', x, y, button: 'left', clickCount: 1 });
    }
  };
  const screenshot = async name => {
    await evaluate('scrollTo(0,0)');
    const { contentSize } = await call('Page.getLayoutMetrics');
    const shot = await call('Page.captureScreenshot', { format: 'png', captureBeyondViewport: true,
      clip: { x: 0, y: 0, width: contentSize.width, height: contentSize.height, scale: 1 } });
    await fs.writeFile(path.join(output, name + '.png'), Buffer.from(shot.data, 'base64'));
  };
  return { call, evaluate, until, api, click, metrics, screenshot,
    order: () => evaluate('[...document.querySelectorAll(".home-widget-slot")].map(e=>e.dataset.debugId.replace("home-layout-slot-",""))') };
}
let hub;
const startHub = async () => {
  hub = start(process.env.HOME_HUB_BINARY, [path.join(output, 'hub.sqlite'), String(hubPort), origin], 'hub-' + children.length);
  await ready(`http://127.0.0.1:${hubPort}/api/v1/me/home-layout`, hub);
};
try {
  await startHub();
  const vite = start(process.execPath, ['node_modules/vite/bin/vite.js', '--config', 'tests/fixtures/home-widgets/vite.integration.config.mjs'], 'vite', {
    ...process.env, HOME_UI_PORT: String(uiPort), HOME_HUB_ORIGIN: `http://127.0.0.1:${hubPort}`, HOME_VITE_CACHE: path.join(output, 'vite-cache'),
  });
  await ready(origin + '/tests/fixtures/home-widgets/main.tsx', vite);
  const chrome = start(process.env.HOME_CHROMIUM, ['--headless=new', '--no-sandbox', '--disable-gpu', '--password-store=basic', '--use-mock-keychain',
    '--remote-debugging-address=127.0.0.1', `--remote-debugging-port=${cdpPort}`, `--user-data-dir=${path.join(output, 'chromium-profile')}`, 'about:blank'], 'chromium');
  await ready(`http://127.0.0.1:${cdpPort}/json/version`, chrome);
  const version = await (await fetch(`http://127.0.0.1:${cdpPort}/json/version`)).json();
  const browser = connect(version.webSocketDebuggerUrl); await browser.opened;
  const a = await browserClient(browser), b = await browserClient(browser);
  const initial = await a.api(); assert.equal(initial.body.data.version, 0); assert.deepEqual(await b.api(), initial);
  reports.push({ check: 'independent browser contexts / shared account / default GET', version: 0 });
  await a.click('home-layout-edit');
  await a.click('home-layout-handle-chains');
  await a.until('!!document.querySelector("[data-debug-id=home-layout-later-chains]")', 'desktop widget menu');
  await a.click('home-layout-later-chains');
  // Poll the real API for the debounce completion, not a fixed save delay.
  let desktop;
  for (let i = 0; i < 100; i++) { desktop = await a.api(); if (desktop.body.data.version === 1) break; await wait(25); }
  assert.equal(desktop.status, 200); assert.equal(desktop.etag, '"1"');
  assert.deepEqual(desktop.body.data.widgets.map(w => w.id), ['activity', 'uptime', 'chains', 'fleet']);
  await b.evaluate('window.dispatchEvent(new Event("focus"))');
  await b.until('document.querySelectorAll(".home-widget-slot")[1]?.dataset.debugId === "home-layout-slot-uptime"', 'second client focus refresh');
  assert.deepEqual(await b.order(), await a.order());
  await a.screenshot('desktop-1440-saved');
  reports.push({ check: 'native desktop reorder / real saved GET / focus refresh', saved: desktop });
  await b.metrics(390); await b.call('Emulation.setTouchEmulationEnabled', { enabled: true });
  await b.click('home-layout-edit', true);
  await b.click('home-layout-down-uptime', true);
  let mobile;
  for (let i = 0; i < 100; i++) { mobile = await b.api(); if (mobile.body.data.version === 2) break; await wait(25); }
  assert.equal(mobile.body.data.version, 2);
  assert.deepEqual(mobile.body.data.widgets.map(w => w.id), desktop.body.data.widgets.map(w => w.id));
  assert.deepEqual(await b.order(), ['chains', 'uptime', 'fleet']);
  assert.equal(mobile.body.data.widgets.find(w => w.id === 'chains').options.mobile_order, 0);
  await b.screenshot('mobile-390-saved-edit');
  await b.click('home-layout-add-menu', true);
  await b.until('!!document.querySelector("[data-debug-id=home-layout-add-sheet]")', 'mobile add bottom sheet');
  await b.evaluate('Promise.all(document.getAnimations().filter(a=>a.effect.getTiming().iterations!==Infinity).map(a=>a.finished.catch(()=>{})))');
  await b.screenshot('mobile-390-add-sheet');
  await b.call('Input.dispatchKeyEvent', { type: 'keyDown', key: 'Escape', code: 'Escape', windowsVirtualKeyCode: 27 });
  await b.call('Input.dispatchKeyEvent', { type: 'keyUp', key: 'Escape', code: 'Escape', windowsVirtualKeyCode: 27 });
  await b.until('!document.querySelector("[data-debug-id=home-layout-add-sheet]")', 'Escape closes sheet');
  reports.push({ check: 'native 44px touch reorder / independent desktop and mobile order / Activity omitted / keyboard sheet close', saved: mobile });

  // A stale browser write cannot overwrite the current row.
  const stale = await a.api('PUT', desktop.body.data);
  assert.equal(stale.status, 409); assert.equal(stale.body.error.code, 'conflict');
  assert.deepEqual((await a.api()).body.data, mobile.body.data);
  await stop(hub); await startHub();
  assert.deepEqual((await a.api()).body.data, mobile.body.data, 'same persisted session and layout after process restart / DB reopen / migration replay');
  reports.push({ check: 'stale 409 preserves row / actual process restart and DB reopen', staleStatus: stale.status, version: mobile.body.data.version });

  await b.call('Network.emulateNetworkConditions', { offline: true, latency: 0, downloadThroughput: -1, uploadThroughput: -1 });
  await b.click('home-layout-down-chains', true);
  await b.until('document.querySelector("[data-debug-id=home-layout-error]")?.textContent.includes("could not be saved")', 'offline truthful failure');
  assert.deepEqual(await b.order(), ['chains', 'uptime', 'fleet'], 'offline rollback');
  assert.deepEqual((await a.api()).body.data, mobile.body.data);
  await b.screenshot('mobile-390-offline-rollback');
  await b.call('Network.emulateNetworkConditions', { offline: false, latency: 0, downloadThroughput: -1, uploadThroughput: -1 });
  await b.evaluate('window.dispatchEvent(new Event("online"))');
  await b.until('!document.querySelector("[data-debug-id=home-layout-error]")', 'online reload recovery');
  reports.push({ check: 'real browser offline save failure / rollback / online recovery', version: (await b.api()).body.data.version });

  // A failure exits edit mode while canEdit is false. Re-enter explicitly after
  // successful recovery, just as a person using the page must do.
  await b.until('document.querySelector("[data-debug-id=home-layout-edit]")?.disabled === false', 'editing available after recovery');
  assert.equal(await b.evaluate('document.querySelector("[data-debug-id=home-layout-edit]").getAttribute("aria-pressed")'), 'false');
  await b.click('home-layout-edit', true);
  const remoteEdit = structuredClone(mobile.body.data);
  remoteEdit.widgets.find(w => w.id === 'fleet').hidden = true;
  assert.equal((await a.api('PUT', remoteEdit)).body.data.version, 3);
  await b.click('home-layout-down-chains', true);
  await b.until('document.querySelector("[data-debug-id=home-layout-error]")?.textContent.includes("changed elsewhere")', 'real stale-save conflict feedback');
  await b.evaluate('window.dispatchEvent(new Event("focus"))');
  assert.deepEqual(await b.order(), ['chains', 'uptime', 'fleet'], 'conflict rolls back and retains last confirmed layout');
  await b.screenshot('mobile-390-conflict');
  await b.click('home-layout-reload', true);
  await b.until('!document.querySelector("[data-debug-id=home-layout-error]") && !document.querySelector("[data-debug-id=home-layout-slot-fleet]")', 'explicit reload reads winner');
  reports.push({ check: 'real UI stale-write rollback / conflict retained on focus / explicit reload', version: (await b.api()).body.data.version });

  // Fresh independent clients exercise adapter import against the real store.
  const c = await browserClient(browser, 'layout_import'), d = await browserClient(browser, 'layout_import');
  for (const [client, width] of [[c, 1], [d, 2]]) {
    await client.evaluate(`(async()=>{
      window.__homeFixtureRender(null); await new Promise(r=>setTimeout(r,0));
      window.tools=await import('/src/ui/components/home/serverHomeLayoutAdapter.ts');
      window.identity=await import('/src/ui/utils/expectedUser.ts');
      window.backup=JSON.stringify({version:47,widgets:[{id:'fleet',width:${width},hidden:false,options:{mobile_order:0,custom:{source:'backup'}}}]});
      localStorage.setItem('heimdall:home-layout:'+encodeURIComponent(window.__homeFixtureUser),window.backup);
      const original=window.fetch; window.importStatuses=[];
      window.fetch=async(...args)=>{const r=await original(...args); if(String(args[0]).includes('/me/home-layout')){
        window.importStatuses.push(r.status); if((args[1]?.method||'GET')==='GET' && !window.heldOnce){window.heldOnce=true;await new Promise(resolve=>window.releaseImport=resolve);}}
        return r;};
      window.adapter=tools.createServerHomeLayoutAdapter();
      window.importPromise=adapter.load(window.__homeFixtureUser).then(value=>window.imported=value);
    })()`);
  }
  await c.until('!!window.releaseImport', 'first version0 GET held'); await d.until('!!window.releaseImport', 'second version0 GET held');
  await Promise.all([c.evaluate('window.releaseImport()'), d.evaluate('window.releaseImport()')]);
  await c.until('!!window.imported', 'first importer settled'); await d.until('!!window.imported', 'second importer settled');
  const imported = await c.evaluate('window.imported');
  assert.equal(imported.version, 1); assert.deepEqual(await d.evaluate('window.imported'), imported);
  const statuses = [...await c.evaluate('window.importStatuses'), ...await d.evaluate('window.importStatuses')];
  assert.equal(statuses.filter(s => s === 409).length, 1, 'exactly one conditional import loses');
  for (const client of [c, d]) assert.equal(await client.evaluate("localStorage.getItem('heimdall:home-layout:'+encodeURIComponent(window.__homeFixtureUser))===window.backup"), true);
  reports.push({ check: 'real conditional import race / loser reads winner / backups retained', imported, statuses });

  // Hold an actual adapter write before transmission; activate B's real cookie.
  // Do not update expectedUser yet: this deliberately reaches the server guard.
  // Bypass only the fixture visual boundary. Auth, cookies and guard remain
  // production paths; native fetch is captured before that boundary is installed.
  await c.evaluate(`window.__nativeLayoutFetch=window.__homeFixtureNativeFetch;
    window.fetch=async(...args)=>{if(args[1]?.method==='PUT') await new Promise(r=>window.releaseWrite=r);return window.__nativeLayoutFetch(...args);};
    window.oldUser=window.__homeFixtureUser;
    window.pendingSave=adapter.save(window.oldUser,window.imported,1).then(value=>({value}),error=>({status:error.status,code:error.code})); void 0;`);
  await c.until('!!window.releaseWrite', 'queued PUT held before network');
  const switched = await c.evaluate(`(async()=>{const r=await window.__nativeLayoutFetch('/api/v1/_fixture/login?user=layout_other',{method:'POST'}); return (await r.json()).data.user_id;})()`);
  await c.evaluate('window.releaseWrite()');
  assert.deepEqual(await c.evaluate('window.pendingSave'), { status: 409, code: 'account_mismatch' });
  const other = await c.api('GET', undefined, switched); assert.equal(other.body.data.version, 0);
  assert.deepEqual((await d.api()).body.data, imported);
  reports.push({ check: 'queued real adapter PUT with switched cookie / production account guard / account isolation', otherVersion: 0 });

  // A successful real GET held after receipt must also be rejected when the UI
  // account generation changes A->B->A before its continuation resumes.
  await d.evaluate(`window.__nativeLayoutFetch=window.__homeFixtureNativeFetch;
    window.fetch=async(...args)=>{const response=await window.__nativeLayoutFetch(...args);await new Promise(r=>window.releaseResponse=r);return response;};
    window.delayedRead=adapter.load(window.__homeFixtureUser).then(value=>({value}),error=>({code:error.code})); void 0;`);
  await d.until('!!window.releaseResponse', 'real GET response held');
  await d.evaluate(`identity.setExpectedUserId('temporary-other-account');identity.setExpectedUserId(window.__homeFixtureUser);window.releaseResponse();`);
  assert.deepEqual(await d.evaluate('window.delayedRead'), { code: 'account_mismatch' });
  reports.push({ check: 'real GET delayed response / A-to-B-to-A generation fence' });
  assert.deepEqual(errors, []);
  const report = { ...started, chromium: version.Browser, finishedAt: new Date().toISOString(), reports, errors };
  await fs.writeFile(path.join(output, 'report.json'), JSON.stringify(report, null, 2));
  const gallery = path.join(output, 'gallery'); await fs.mkdir(gallery);
  const shots = (await fs.readdir(output)).filter(name => name.endsWith('.png'));
  for (const name of [...shots, 'report.json', 'capture-start.json']) await fs.copyFile(path.join(output, name), path.join(gallery, name));
  await fs.writeFile(path.join(gallery, 'index.html'), `<!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Home layout integration</title>
    <style>body{font:16px system-ui;max-width:1100px;margin:auto;padding:24px;color:#222}img{max-width:100%;border:1px solid #ccc}code{overflow-wrap:anywhere}figure{margin:24px 0}</style>
    <h1>Home layout integration</h1><p>Independent browser contexts share the production Home HTTP handler and SQLite store. Other widget data is mocked. Isolated test login replaces OIDC completion.</p>
    <p>Commit <code>${started.actualSha}</code>, tree <code>${started.actualTree}</code>. ${reports.length} scenario groups passed. <a href="report.json">Full results and wire revisions</a> · <a href="capture-start.json">Capture provenance</a>.</p>
    <ul>${reports.map(item => `<li>${item.check}</li>`).join('')}</ul>${shots.map(name => `<figure><figcaption>${name.replaceAll('-', ' ')}</figcaption><a href="${name}"><img src="${name}" alt="${name}"></a></figure>`).join('')}</html>`);
  console.log(JSON.stringify({ passed: reports.length, failed: 0, output, errors }));
} catch (error) {
  await fs.writeFile(path.join(output, 'failure.json'), JSON.stringify({ ...started, reports, errors, error: error.stack }, null, 2));
  throw error;
} finally {
  for (const socket of sockets) socket.close();
  for (const { child } of children.toReversed()) await stop(child);
  for (const { log, name } of children) await fs.writeFile(path.join(output, name + '.log'), Buffer.concat(log));
}
