// Run with VITE_API_BASE=. PUPPETEER_MODULE=/path/to/puppeteer-core.js
// STREAM_CHROMIUM=/path/to/chromium node tests/e2e/stream_viewer_browser.mjs EVIDENCE_DIR
// Real app, styles and WebSocket framing against an isolated synthetic HTTP/WS peer.
import assert from 'node:assert/strict';
import { mkdir } from 'node:fs/promises';
import path from 'node:path';
import { pathToFileURL } from 'node:url';
import { createServer } from 'vite';
import { WebSocketServer } from 'ws';

assert.ok(process.env.PUPPETEER_MODULE && process.env.STREAM_CHROMIUM && process.argv[2]);
const evidence = path.resolve(process.argv[2]);
await mkdir(evidence, { recursive: true });
const prefix = '/api/v1/preview/sh_fixture';
const id = '0123456789abcdef0123456789abcdef';
const stream = `/api/v1/streams/${id}`;
const statuses = new Map();
let mode = '';
let pendingMetadata;
let latestSocket;
const sockets = new WebSocketServer({ noServer: true });
const respond = (res, status, data) => {
  res.writeHead(status, { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' });
  res.end(JSON.stringify({ data }));
};
const server = await createServer({
  cacheDir: path.join(evidence, 'vite-cache'),
  server: { host: '127.0.0.1', port: 0 },
  optimizeDeps: { noDiscovery: true, include: ['react', 'react-dom/client', 'react-redux', '@reduxjs/toolkit', 'qrcode-generator'] },
  logLevel: 'warn',
  plugins: [{
    name: 'stream-review-fixture',
    enforce: 'pre',
    configResolved(config) { config.server.proxy = undefined; },
    transform(source, file) {
      if (!file.endsWith('/src/ui/components/shell/AppShell.tsx')) return;
      assert.ok(source.includes('return <AuthGate />;'));
      return source.replace('return <AuthGate />;',
        'return <AuthenticatedShell user={{ user_id: "review-fixture", display_name: "Review Fixture" }} />;');
    },
    configureServer(vite) {
      vite.middlewares.use((req, res, next) => {
        const p = new URL(req.url, 'http://fixture.invalid').pathname;
        if (p === prefix + '/') { req.url = '/'; return next(); }
        if (p === prefix + stream) {
          statuses.set('metadata', p);
          const payload = { title: 'Release readiness checklist', expires: Date.now() + (mode === 'expired' ? -1 : 60_000) };
          const status = ({ unauthorized: 401, unavailable: 404, error: 503, ended: 404 })[mode] || 200;
          if (mode === 'loading') {
            pendingMetadata = () => respond(res, status, payload);
            return;
          }
          return respond(res, status, payload);
        }
        if (p === prefix + '/api/v1/me/ws-ticket' && req.method === 'POST') {
          statuses.set('ticket', p);
          return respond(res, 200, { ticket: 'synthetic-ticket' });
        }
        if (p.startsWith(prefix + '/api/') || p === '/posthog-config.json') return respond(res, 200, []);
        // Vite's document-relative paths load these asset routes under the document prefix.
        if (p.startsWith(prefix + '/')) req.url = req.url.slice(prefix.length);
        next();
      });
      vite.httpServer.on('upgrade', (req, sock, head) => {
        const url = new URL(req.url, 'http://fixture.invalid');
        if (url.pathname === prefix + '/api/v1/user-ws') {
          sockets.handleUpgrade(req, sock, head, () => {});
          return;
        }
        if (url.pathname !== prefix + stream + '/view') return;
        assert.equal(url.searchParams.get('ticket'), 'synthetic-ticket');
        statuses.set('view', url.pathname);
        sockets.handleUpgrade(req, sock, head, ws => { latestSocket = ws; });
      });
    },
  }],
});
let browser;
try {
  await server.listen();
  const origin = `http://127.0.0.1:${server.httpServer.address().port}`;
  const { default: puppeteer } = await import(pathToFileURL(process.env.PUPPETEER_MODULE).href);
  browser = await puppeteer.launch({ executablePath: process.env.STREAM_CHROMIUM, headless: true,
    args: ['--no-sandbox', '--disable-dev-shm-usage', '--disable-background-networking'] });
  for (const [width, height] of [[1440, 900], [390, 780]]) {
    const page = await browser.newPage();
    const failures = [];
    page.on('pageerror', error => failures.push(error.message));
    const badResponses = [];
    page.on('response', res => { if (res.status() >= 400) badResponses.push([res.status(), res.url()]); });
    const consoleErrors = [];
    page.on('console', msg => { if (msg.type() === 'error') consoleErrors.push(msg.text()); });
    await page.setViewport({ width, height });
    await page.setRequestInterception(true);
    page.on('request', req => {
      if (req.url().startsWith(origin + '/') || req.url().startsWith('blob:') || req.url().startsWith('data:')) return req.continue();
      return req.abort();
    });
    await page.evaluateOnNewDocument(() => {
      const revoke = URL.revokeObjectURL;
      window.revokedStreamUrls = [];
      URL.revokeObjectURL = url => { window.revokedStreamUrls.push(url); revoke(url); };
    });
    const goto = () => page.goto(origin + prefix + '/#/streams/' + id, { waitUntil: 'domcontentloaded' });
    const capture = async (label, name) => {
      await page.waitForFunction(label => [...document.querySelectorAll('main [role="status"]')]
        .some(el => el.textContent.startsWith(label)), {}, label);
      assert.ok(await page.$eval('main', el => el.scrollWidth <= el.clientWidth), `${name} fits at ${width}`);
      await page.screenshot({ path: path.join(evidence, `${width}-${name}.png`) });
    };
    try {
      mode = 'loading';
      pendingMetadata = undefined;
      await goto();
      await capture('Connecting', 'connecting');
      assert.ok(pendingMetadata);
      mode = '';
      pendingMetadata();
      await capture('Waiting', 'waiting');

      const jpg = Buffer.from(await page.evaluate(() => {
        const canvas = document.createElement('canvas');
        canvas.width = 740;
        canvas.height = 420;
        const ctx = canvas.getContext('2d');
        ctx.fillStyle = '#f2eee5'; ctx.fillRect(0, 0, 740, 420);
        ctx.fillStyle = '#252525'; ctx.font = 'bold 36px serif'; ctx.fillText('Release readiness', 54, 83);
        ctx.font = '21px sans-serif'; ctx.fillText('Synthetic shared tab · review fixture', 54, 126);
        ctx.fillStyle = '#476444';
        for (const [i, item] of ['Build verified', 'Review requested', 'Deployment not started'].entries()) {
          ctx.fillRect(58, 181 + i * 53, 14, 14); ctx.fillText(item, 89, 195 + i * 53);
        }
        return canvas.toDataURL('image/jpeg', 0.55).split(',')[1];
      }), 'base64');
      const count = Math.ceil(jpg.length / 12288);
      for (let i = 0; i < count; i++) {
        const header = Buffer.alloc(59);
        header.set([4, 0, 0, 32]);
        header.write(id, 4);
        header.writeBigUInt64BE(1n, 36);
        header.writeUInt16BE(i, 44);
        header.writeUInt16BE(count, 46);
        header[48] = 10;
        header.write('image/jpeg', 49);
        latestSocket.send(Buffer.concat([header, jpg.subarray(i * 12288, (i + 1) * 12288)]));
      }
      await page.waitForFunction(() => document.querySelector('img[alt="Latest image of the shared tab"]')?.naturalWidth > 0);
      await capture('Live', 'live');
      const frameUrl = await page.$eval('img[alt="Latest image of the shared tab"]', img => img.src);
      latestSocket.close();
      await capture('Paused', 'paused');
      await page.keyboard.press('Tab');
      assert.equal(await page.evaluate(() => document.activeElement?.textContent.trim()), 'Skip to content');
      await page.keyboard.press('Enter');
      assert.equal(await page.evaluate(() => document.activeElement?.id), 'main-content');
      assert.equal(new URL(page.url()).hash, '#/streams/' + id);
      for (let i = 0; i < 4; i++) {
        await page.keyboard.press('Tab');
        if (await page.evaluate(() => document.activeElement?.textContent.trim() === 'Reconnect')) break;
      }
      assert.equal(await page.evaluate(() => document.activeElement?.textContent.trim()), 'Reconnect');
      await page.keyboard.press('Enter');
      await page.waitForFunction(() => document.querySelector('main [role="status"]')?.textContent.startsWith('Waiting'));
      assert.ok(await page.evaluate(url => window.revokedStreamUrls.includes(url), frameUrl));
      mode = 'ended';
      latestSocket.close();
      await capture('Ended', 'ended');

      for (const [scenario, label] of [
        ['expired', 'Expired'], ['unavailable', 'Unavailable'], ['unauthorized', 'Access required'], ['error', 'Connection error'],
      ]) {
        mode = scenario;
        await page.reload({ waitUntil: 'domcontentloaded' });
        await capture(label, scenario);
      }

      assert.equal(statuses.get('metadata'), prefix + stream);
      assert.equal(statuses.get('ticket'), prefix + '/api/v1/me/ws-ticket');
      assert.equal(statuses.get('view'), prefix + stream + '/view');
      assert.deepEqual(failures, []);
      console.log(`PASS ${width}×${height}: 9 states, prefix routing, decoded JPEG, keyboard reconnect and blob URL cleanup`);
    } catch (error) {
      console.error({ failures, badResponses, consoleErrors, body: (await page.$eval('body', el => el.innerText)).slice(0, 700) });
      throw error;
    } finally { await page.close(); }
  }
} finally {
  if (browser) await browser.close();
  for (const socket of sockets.clients) socket.terminate();
  sockets.close();
  await server.close();
}
