// Run with the built Hub, Bridge, CLI and dev proxy, plus cached Chromium,
// Puppeteer and PTY host. This fixture launches its own isolated local stack.
import assert from 'node:assert/strict';
import { execFile, spawn } from 'node:child_process';
import { randomBytes } from 'node:crypto';
import fs from 'node:fs/promises';
import http from 'node:http';
import net from 'node:net';
import os from 'node:os';
import path from 'node:path';
import { setTimeout as delay } from 'node:timers/promises';
import { promisify } from 'node:util';
import WebSocket, { WebSocketServer } from 'ws';
import { checkTabStream } from './tabstream_scenario.mjs';
import { hubLogin, SESSION_COOKIE } from './hubOidc.mjs';
import { scrubHeimdallEnv } from './realHomeGuard.mjs';

const exec = promisify(execFile);
const bin = path.resolve(process.env.STREAM_BIN_DIR);
const pty = path.resolve(process.env.STREAM_PTY_HOST);
const chromium = path.resolve(process.env.HEIMDALL_TEST_CHROMIUM);
const viewerChromium = path.resolve(process.env.STREAM_VIEWER_CHROMIUM || chromium);
const puppeteer = (await import(process.env.PUPPETEER_MODULE)).default;
const expiryOnly = process.env.STREAM_E2E_EXPIRY === '1';
scrubHeimdallEnv();
const root = await fs.mkdtemp(path.join(os.tmpdir(), 'heimdall-tabstream-'));
const local = path.join(root, 'local');
const home = path.join(root, 'home');
await fs.mkdir(home);
const env = { ...process.env, HOME: home, XDG_CONFIG_HOME: path.join(home, '.config'),
  HEIMDALL_LOCAL_STATE_ROOT: local, PATH: root + ':' + process.env.PATH };
const launch = (kind, verb, args = []) => exec('bash',
  [ 'scripts/local-' + kind + '.sh', verb, '--name', 'tabstream', ...args ], { env, timeout: 120000 });
const db = path.join(local, 'hubs/tabstream/hub.db');
const sql = async (query, args = []) => JSON.parse((await exec('python3', ['-c',
  'import sqlite3,json,sys; c=sqlite3.connect(sys.argv[1]); r=c.execute(sys.argv[2],json.loads(sys.argv[3])); print(json.dumps(r.fetchall())); c.commit()',
  db, query, JSON.stringify(args)])).stdout);
const ports = await Promise.all(Array.from({length: 6}, () => new Promise((resolve, reject) => {
  const server = net.createServer();
  server.once('error', reject);
  server.listen(0, '127.0.0.1', () => resolve(server));
})));
const [hubPort, proxyPort, uiPort, oidcPort, bridgePort, agentPort] = ports.map(server => String(server.address().port));
await Promise.all(ports.map(server => new Promise(resolve => server.close(resolve))));
const hub = 'http://127.0.0.1:' + hubPort;
const origin = 'http://127.0.0.1:' + uiPort;
const proxy = 'http://127.0.0.1:' + proxyPort;
const headers = user => ({ 'X-Dev-User': user, 'Content-Type': 'application/json', Origin: origin });
const request = (user, route, options) => fetch(proxy + route, {
  ...options, headers: headers(user), signal: AbortSignal.timeout(3000),
});
const ownerRequest = (route, options) => request('tanmay', route, options);
const foreignRequest = (route, options) => request('paid', route, options);
const api = async (route, method = 'GET', body) => {
  const response = await ownerRequest('/api/v1' + route, { method, body: body && JSON.stringify(body) });
  assert.ok(response.ok, method + ' ' + route + ' returned ' + response.status);
  return (await response.json()).data;
};
const waitFor = async (predicate, label, ms = 15000) => {
  for (const deadline = Date.now() + ms; Date.now() < deadline;) {
    const value = await predicate();
    if (value) return value;
    await delay(30);
  }
  throw new Error('Timed out waiting for ' + label);
};
const clients = new Set();
let bridge, instance, capture, viewerBrowser, cdpProxy, cdpServer, eventTap, vite;
const captureMethods = [];
let unpreparedCaptureStarts = 0;
const needles = [];
const fixtureTitle = 'Synthetic tabstream ' + randomBytes(16).toString('hex');
const dbSchema = () => sql("SELECT name,sql FROM sqlite_master ORDER BY name");
let initialSchema;
try {
  await launch('hub', 'start', ['--hub-port', hubPort, '--proxy-port', proxyPort,
    '--ui-port', uiPort, '--oidc-port', oidcPort, '--user', 'tanmay',
    '--no-ui', '--no-plan-limits', '--bin-dir', bin]);
  const agentEnvPath = path.join(root, 'agent-env.json');
  const provider = path.join(root, 'tabstream-provider');
  await fs.writeFile(provider, '#!/usr/bin/env python3\n'
    + 'import json, os, sys, subprocess, signal\n'
    + 'if "--version" in sys.argv:\n print("codex-cli 0.162.0"); sys.exit()\n'
    + 'if "plugin" in sys.argv:\n print(\'{"installed":[],"available":[]}\'); sys.exit()\n'
    + 'if not os.environ.get("HEIMDALL_AGENT_INSTANCE_ID"): sys.exit(2)\n'
    + 'p = ' + JSON.stringify(agentEnvPath) + '\n'
    + 'with open(p+".new","w") as f: json.dump({k:v for k,v in os.environ.items() if k.startswith("HEIMDALL_")}, f)\n'
    + 'os.rename(p+".new",p)\n'
    + 'subprocess.run([' + JSON.stringify(path.join(bin, 'ham-ctl')) + ', "start-success"],check=True)\n'
    + 'while True: signal.pause()\n', { mode: 0o700 });
  await sql("UPDATE provider_catalog SET binary=?, base_args='[]', yolo_args='[]', ask_args='[]', extension='{}' WHERE provider='codex'", [path.basename(provider)]);
  await sql("UPDATE provider_catalog_meta SET catalog_etag='tabstream-synthetic-provider'");
  await launch('bridge', 'start', ['--hub', 'tabstream', '--auto-enroll', '--port', bridgePort,
    '--local-endpoint-port', agentPort, '--bin-dir', bin, '--pty-host-bin', pty]);
  [bridge] = await api('/bridges');
  assert.ok(bridge?.bridge_id);
  await api('/bridges/' + bridge.bridge_id + '/providers/discover', 'POST', {});
  await api('/bridges/' + bridge.bridge_id + '/providers/codex', 'PUT', { enabled: true });
  const agent = await api('/agents', 'POST', { name: 'Synthetic tabstream fixture', slug: 'tabstream-fixture', instructions: 'Isolated test fixture' });
  const chain = await api('/task-chains', 'POST', { title: 'Synthetic tabstream fixture' });
  const [[model]] = await sql("SELECT model_id FROM provider_models WHERE provider='codex' AND state='active' ORDER BY rank LIMIT 1");
  instance = await api('/agent-instances', 'POST', { agent_id: agent.agent_id, bridge_id: bridge.bridge_id,
    provider: 'codex', model, chain_id: chain.chain_id, display_name: 'Synthetic tabstream source' });
  const agentEnv = await waitFor(async () => {
    try { return JSON.parse(await fs.readFile(agentEnvPath, 'utf8')); }
    catch (error) { if (error.code !== 'ENOENT') throw error; }
  }, 'fixture agent start');
  await waitFor(async () => (await api('/agent-instances/' + instance.agent_instance_id)).runtime_status === 'running', 'agent readiness');
  const cli = async args => (await exec(path.join(bin, 'ham-ctl'), args,
    { env: { ...env, ...agentEnv }, timeout: 8000 })).stdout;

  // Real Chromium paints continuously. The loopback CDP tap records command
  // names only and relays both ways, so detach must reach the real source.
  const profile = agentEnv.HEIMDALL_BROWSER_PROFILE_DIR;
  assert.equal(typeof profile, 'string', 'spawned fixture receives browser profile');
  const canonicalRoot = await fs.realpath(root);
  assert.ok(profile.startsWith(canonicalRoot + path.sep), 'browser profile belongs to fixture stack (empty=' + (profile === '') + ')');
  const fixture = path.join(root, 'fixture.html');
  await fs.writeFile(fixture, '<title>' + fixtureTitle + '</title><canvas width="1280" height="800"></canvas>'
    + '<style>body{margin:0;overflow:hidden}</style><script>'
    + 'const c=document.querySelector("canvas").getContext("2d");function draw(t){'
    + 'for(let y=0;y<800;y+=12)for(let x=0;x<1280;x+=12){'
    + 'c.fillStyle="hsl("+((x*57+y*37+t)%360)+" 100% 50%)";c.fillRect(x,y,12,12)}requestAnimationFrame(draw)}requestAnimationFrame(draw)</script>');
  capture = spawn(chromium, ['--headless=new', '--enable-automation', '--no-sandbox',
    '--disable-background-networking', '--no-first-run', '--remote-debugging-port=0',
    '--window-size=1280,800', '--user-data-dir=' + profile, 'file://' + fixture], { env, stdio: 'ignore' });
  const portFile = path.join(profile, 'DevToolsActivePort');
  const rawPort = await waitFor(async () => {
    try { return await fs.readFile(portFile, 'utf8'); }
    catch (error) { if (error.code !== 'ENOENT') throw error; }
  }, 'Chromium DevTools port');
  const [realPort, wsPath] = rawPort.trim().split('\n');
  const realCdp = 'http://127.0.0.1:' + realPort;
  const target = await waitFor(async () => (await (await fetch(realCdp + '/json/list')).json())
    .find(t => t.type === 'page' && t.title === fixtureTitle)?.id, 'animated CDP tab');
  const captureBrowser = await puppeteer.connect({
    browserWSEndpoint: 'ws://127.0.0.1:' + realPort + wsPath,
    defaultViewport: null,
  });
  try {
    const source = (await captureBrowser.pages()).find(p => p.url() === 'file://' + fixture);
    assert.ok(source, 'headless source page');
    const foreground = await captureBrowser.newPage();
    await foreground.bringToFront();
    assert.equal(await source.evaluate(() => document.hasFocus()), false, 'source begins unfocused');
  } finally {
    await captureBrowser.disconnect();
  }
  cdpProxy = new WebSocketServer({ noServer: true });
  cdpServer = http.createServer((req, res) => {
    if (req.url !== '/json/version') return res.writeHead(404).end();
    res.setHeader('Content-Type', 'application/json');
    res.end(JSON.stringify({ webSocketDebuggerUrl: 'ws://127.0.0.1:' + cdpServer.address().port + wsPath }));
  });
  cdpServer.on('upgrade', (req, socket, head) => {
    if (req.url !== wsPath) return socket.destroy();
    cdpProxy.handleUpgrade(req, socket, head, downstream => {
      const upstream = new WebSocket('ws://127.0.0.1:' + realPort + wsPath);
      const enabledPages = new Set();
      const focusedPages = new Set();
      downstream.on('message', bytes => {
        const { method, sessionId, params } = JSON.parse(bytes.toString());
        if (sessionId && method === 'Page.enable') enabledPages.add(sessionId);
        if (sessionId && method === 'Emulation.setFocusEmulationEnabled' && params?.enabled === true
          && enabledPages.has(sessionId)) focusedPages.add(sessionId);
        if (method === 'Page.startScreencast' && !focusedPages.has(sessionId)) unpreparedCaptureStarts += 1;
        if (method === 'Page.startScreencast' || method === 'Page.stopScreencast') captureMethods.push(method);
        if (upstream.readyState === WebSocket.OPEN) upstream.send(bytes, {binary: false});
        else upstream.once('open', () => upstream.send(bytes, {binary: false}));
      });
      upstream.on('message', bytes => {
        if (downstream.readyState === WebSocket.OPEN) downstream.send(bytes, {binary: false});
      });
      downstream.on('close', () => upstream.terminate());
      upstream.on('close', () => downstream.terminate());
      upstream.on('error', () => downstream.terminate());
      downstream.on('error', () => upstream.terminate());
    });
  });
  await new Promise(resolve => cdpServer.listen(0, '127.0.0.1', resolve));
  await fs.writeFile(portFile, cdpServer.address().port + '\n' + wsPath + '\n');
  const openViewer = async (id, user) => {
    const ticketRes = await request(user === 'owner' ? 'tanmay' : 'paid',
      '/api/v1/me/ws-ticket', { method: 'POST', body: '{}' });
    assert.equal(ticketRes.status, 200);
    const { data: { ticket } } = await ticketRes.json();
    const socket = new WebSocket(hub.replace('http:', 'ws:') + '/api/v1/streams/' + id + '/view?ticket=' + encodeURIComponent(ticket), { origin });
    clients.add(socket);
    socket.on('error', () => {});
    const status = await new Promise((resolve, reject) => {
      socket.once('open', () => resolve(101));
      socket.once('unexpected-response', (_req, res) => {
        res.resume();
        resolve(res.statusCode);
      });
      socket.once('error', reject);
    });
    return {
      status,
      onBinary: fn => socket.on('message', (data, binary) => {
        if (binary) fn(Uint8Array.from(data).buffer);
      }),
      close: async () => {
        if (socket.readyState === WebSocket.CLOSED) return;
        const closed = new Promise(resolve => socket.once('close', resolve));
        socket.close();
        await closed;
      },
    };
  };
  process.env.HEIMDALL_DEV_PROXY_URL = proxy;
  const { createServer } = await import('vite');
  vite = await createServer({
    cacheDir: path.join(root, 'vite-cache'),
    server: { host: '127.0.0.1', port: Number(uiPort), strictPort: true },
    optimizeDeps: { noDiscovery: true, include: ['react', 'react-dom/client', 'react-redux', '@reduxjs/toolkit', 'qrcode-generator'] },
    logLevel: 'warn',
    plugins: [{
      name: 'stream-e2e-shell-fixture',
      enforce: 'pre',
      // The vault onboarding UI is not under test. Actual stream HTTP and
      // WebSocket authentication still use an owner session from the real Hub.
      transform(source, file) {
        if (!file.endsWith('/src/ui/components/shell/AppShell.tsx')) return;
        assert.ok(source.includes('return <AuthGate />;'));
        return source.replace('return <AuthGate />;',
          'return <AuthenticatedShell user={{ user_id: "tanmay", display_name: "Fixture owner" }} />;');
      },
    }],
  });
  await vite.listen();
  viewerBrowser = await puppeteer.launch({executablePath: viewerChromium, headless: true,
    args: ['--no-sandbox', '--disable-background-networking'], userDataDir: path.join(root, 'viewer')});
  const session = await hubLogin(hub, 'tanmay');
  await viewerBrowser.defaultBrowserContext().setCookie({
    name: SESSION_COOKIE, value: session, url: origin + '/', secure: true, httpOnly: true,
  });
  const openPage = async (link) => {
    const page = await viewerBrowser.newPage();
    const statuses = [];
    const errors = [];
    page.on('response', response => {
      const requestUrl = new URL(response.url());
      if (requestUrl.pathname.startsWith('/api/v1/streams/')) statuses.push(response.status());
    });
    page.on('pageerror', error => { errors.push(error.name); });
    await page.setRequestInterception(true);
    page.on('request', request => {
      if (request.url().startsWith(origin + '/') || /^(blob|data):/.test(request.url())) return request.continue();
      return request.abort();
    });
    assert.equal(new URL(link).origin, origin, 'owner link uses the configured UI origin');
    await page.goto(link, {waitUntil: 'domcontentloaded'});
    return {
      async waitForImage() {
        try {
          await page.waitForFunction(() =>
            [...document.images].some(img => img.alt === 'Latest image of the shared tab' && img.naturalWidth > 0));
        } catch (error) {
          throw new Error('Viewer image missing (stream HTTP ' + statuses.join(',') + ', page errors ' + errors.join(',') + ')', {cause: error});
        }
      },
      waitForEnded: () => page.waitForFunction(() => document.body.innerText.includes('The shared tab is no longer streaming')),
      waitForExpired: () => page.waitForFunction(() => [...document.querySelectorAll('[role=status]')]
        .some(node => node.textContent.startsWith('Expired'))),
      waitForUnavailable: () => page.waitForFunction(() => document.body.innerText.includes('Stream not found')),
      close: () => page.close(),
    };
  };
  if (expiryOnly) {
    // Wait for Vite's cold module graph before starting the 15s timer.
    const warmup = await openPage(origin + '/#/streams/' + '0'.repeat(32));
    try { await warmup.waitForUnavailable(); }
    finally { await warmup.close(); }
  }
  const listed = JSON.parse(await cli(['stream', 'list', '--sources', 'tabs']));
  assert.equal(listed.ok, true);
  assert.ok(JSON.stringify(listed.data).includes(target), 'real CLI list includes live target');
  initialSchema = await dbSchema();
  const natsDir = path.join(local, 'hubs/tabstream/nats');
  const portsFile = (await fs.readdir(natsDir)).find(name => name.endsWith('.ports'));
  const natsUrl = new URL(JSON.parse(await fs.readFile(path.join(natsDir, portsFile), 'utf8')).nats[0]);
  assert.equal(natsUrl.hostname, '127.0.0.1');
  const busTraffic = [];
  let busBytes = 0;
  let overflow = false;
  let pongs = 0;
  let protocolTail = '';
  let busError;
  eventTap = net.createConnection(Number(natsUrl.port), natsUrl.hostname);
  eventTap.on('error', error => { busError = error; });
  eventTap.on('data', chunk => {
    busBytes += chunk.length;
    if (busBytes <= 16 * 1024 * 1024) busTraffic.push(chunk);
    else overflow = true;
    // Keep the final partial protocol line across TCP chunk boundaries.
    const lines = (protocolTail + chunk.toString('latin1')).split('\r\n');
    protocolTail = lines.pop();
    pongs += lines.filter(line => line === 'PONG').length;
  });
  eventTap.write('CONNECT {"verbose":false}\r\nSUB > 1\r\nPING\r\n');
  const waitForPong = count => waitFor(() => {
    if (busError) throw busError;
    return pongs >= count;
  }, 'event-bus monitor flush');
  await waitForPong(1);
  const canary = 'tabstream-audit-positive-' + randomBytes(16).toString('hex');
  eventTap.write('PUB tabstream_audit.canary ' + canary.length + '\r\n' + canary + '\r\n');
  await waitFor(() => Buffer.concat(busTraffic).includes(canary), 'event-bus monitor positive control');
  const walk = async (dir) => (await Promise.all((await fs.readdir(dir, {withFileTypes: true}))
    .map(async entry => {
      const file = path.join(dir, entry.name);
      return entry.isDirectory() ? walk(file) : entry.isFile() ? file : [];
    }))).flat();
  const audit = {
    register({id, target, title}) {
      for (const value of [id, target, title]) needles.push(Buffer.from(value));
    },
    frame(bytes) {
      // Exclude the JPEG header, which Chromium can reuse across images.
      const midpoint = Math.floor(bytes.length / 6) * 3;
      const signature = Buffer.from(bytes.subarray(midpoint, midpoint + 48));
      assert.equal(signature.length, 48);
      needles.push(signature, Buffer.from(signature.toString('base64')));
    },
    async finish() {
      assert.equal(unpreparedCaptureStarts, 0, 'every screencast enables Page then focus emulation on its own session');
      eventTap.write('PING\r\n');
      await waitForPong(2);
      assert.equal(overflow, false, 'event monitor remained within its memory limit');
      const observed = Buffer.concat(busTraffic);
      assert.ok(observed.includes(canary), 'event monitor saw its canary');
      for (const needle of needles) assert.equal(observed.includes(needle), false, 'stream data in event bus');
      assert.deepEqual(await dbSchema(), initialSchema);
      const files = await walk(local);
      for (const file of files.filter(file => /(?:hub\.db(?:-wal|-shm)?$|nats.*(?:store|jetstream)|\.log$)/.test(file))) {
        const raw = await fs.readFile(file);
        for (const needle of needles) assert.equal(raw.includes(needle), false,
          'stream identifier, title, target, or JPEG signature in ' + path.relative(local, file));
      }
    },
  };
  await checkTabStream({cli, ownerRequest, foreignRequest, openViewer, openPage, target, audit, waitFor, expiryOnly,
    waitForCapture: method => waitFor(() => captureMethods.includes(method), method),
    closeTab: async () => assert.equal((await fetch(realCdp + '/json/close/' + target)).status, 200),
    report: stats => console.log(JSON.stringify(stats)),
  });
  if (expiryOnly) console.log('PASS real short-TTL share expiry, owner viewer closure, denial and persistence audit');
  else console.log('PASS real CLI share, owner/non-owner relay, viewer page, rate/control, detach, stop, tab close and persistence scan');
} finally {
  eventTap?.destroy();
  for (const client of clients) client.terminate();
  await viewerBrowser?.close();
  await vite?.close();
  for (const client of cdpProxy?.clients ?? []) client.terminate();
  cdpServer?.close();
  capture?.kill();
  if (instance) await api('/agent-instances/' + instance.agent_instance_id + '/stop', 'POST', {}).catch(() => {});
  for (const kind of ['bridge', 'hub']) await launch(kind, 'stop').catch(() => {});
  if (bridge) await exec(pty, ['--socket', '/tmp/heimdall-bridge-local/pty-host-' + bridge.bridge_id + '.sock', 'stop']).catch(() => {});
  await fs.rm(root, {recursive: true, force: true});
}
