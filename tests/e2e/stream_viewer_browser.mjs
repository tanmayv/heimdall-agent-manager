// Run with VITE_API_BASE=. PUPPETEER_MODULE=/path/to/puppeteer-core.js
// STREAM_CHROMIUM=/path/to/chromium node tests/e2e/stream_viewer_browser.mjs EVIDENCE_DIR
// Real app, styles and WebSocket framing against an isolated synthetic HTTP/WS peer.
import assert from 'node:assert/strict';
import { EventEmitter, once } from 'node:events';
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
const otherId = 'abcdef0123456789abcdef0123456789';
const stream = `/api/v1/streams/${id}`;
const statuses = new Map();
let mode = '';
let pendingMetadata;
let latestSocket;
let connections = 0;
let input = [];
const received = new EventEmitter();
async function waitForInput(predicate) {
  const signal = AbortSignal.timeout(3000);
  while (!predicate(input)) await once(received, 'input', { signal });
}
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
        if (p === prefix + '/api/v1/streams') return respond(res, 200, [
          { stream_id: id, title: 'Release readiness checklist' },
          { stream_id: otherId, title: 'Deployment status' },
        ]);
        if (p === prefix + '/api/v1/streams/' + otherId) {
          return respond(res, 200, { title: 'Deployment status', expires: Date.now() + 60_000 });
        }
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
        sockets.handleUpgrade(req, sock, head, ws => {
          latestSocket = ws;
          connections++;
          ws.on('message', data => {
            const frame = JSON.parse(data.toString());
            assert.equal(frame.type, 'stream_input');
            assert.equal(frame.protocol_version, 1);
            assert.equal(frame.payload.stream_id, id);
            assert.ok(frame.payload.events.length > 0 && frame.payload.events.length <= 32);
            input.push(...frame.payload.events);
            received.emit('input');
          });
        });
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
    input = [];
    const page = await browser.newPage();
    const failures = [];
    page.on('pageerror', error => failures.push(error.message));
    const badResponses = [];
    page.on('response', res => { if (res.status() >= 400) badResponses.push([res.status(), res.url()]); });
    const consoleErrors = [];
    page.on('console', msg => { if (msg.type() === 'error') consoleErrors.push(msg.text()); });
    const phone = width < 500;
    await page.setViewport({ width, height, hasTouch: phone, isMobile: phone });
    await page.setRequestInterception(true);
    page.on('request', req => {
      if (req.url().startsWith(origin + '/') || req.url().startsWith('blob:') || req.url().startsWith('data:')) return req.continue();
      return req.abort();
    });
    await page.evaluateOnNewDocument(() => {
      const revoke = URL.revokeObjectURL;
      window.revokedStreamUrls = [];
      URL.revokeObjectURL = url => { window.revokedStreamUrls.push(url); revoke(url); };
      const bufferedAmount = Object.getOwnPropertyDescriptor(WebSocket.prototype, 'bufferedAmount');
      Object.defineProperty(WebSocket.prototype, 'bufferedAmount', {
        ...bufferedAmount,
        get() { return window.streamInputBackpressure ? 65536 : bufferedAmount.get.call(this); },
      });
      const timers = new Map();
      let timerId = -1;
      const nativeSet = window.setTimeout.bind(window);
      const nativeClear = window.clearTimeout.bind(window);
      const nativeFetch = window.fetch.bind(window);
      let metadataFetches = 0;
      window.fetch = (url, ...args) => {
        if (typeof url === 'string' && /\/api\/v1\/streams\/[a-f0-9]{32}$/.test(url)) metadataFetches++;
        return nativeFetch(url, ...args);
      };
      window.streamMetadataFetches = () => metadataFetches;
      window.setTimeout = (callback, delay, ...args) => {
        // The viewer's frame-idle callback is named in the unminified fixture.
        // Keep connection timeouts and unrelated app timers real.
        if (callback?.name !== 'onIdle' || delay !== 10_000) return nativeSet(callback, delay, ...args);
        const id = timerId--;
        timers.set(id, () => callback(...args));
        return id;
      };
      window.clearTimeout = id => timers.delete(id) || nativeClear(id);
      window.streamPendingTimers = () => timers.size;
      window.advanceStreamTimers = () => {
        const due = [...timers.values()];
        if (due.length !== 1) throw new Error(`Expected one armed stream-idle timeout, got ${due.length}`);
        timers.clear();
        due.forEach(run => run());
      };
    });
    const goto = () => page.goto(origin + prefix + '/#/streams/' + id, { waitUntil: 'domcontentloaded' });
    const capture = async (label, name) => {
      await page.waitForFunction(label => [...document.querySelectorAll('main [role="status"], main [aria-live="polite"]')]
        .some(el => el.textContent.startsWith(label) || el.getAttribute('aria-label') === label), {}, label);
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
      const image = 'img[alt="Latest image of the shared tab"]';
      const sendJpeg = () => {
        const count = Math.ceil(jpg.length / 12288);
        for (let i = 0; i < count; i++) {
          const header = Buffer.alloc(59);
          header.set([4, 0, 0, 32]);
          header.write(id, 4);
          header.writeBigUInt64BE(1n, 36); // A new connection can start at sequence 1.
          header.writeUInt16BE(i, 44);
          header.writeUInt16BE(count, 46);
          header[48] = 10;
          header.write('image/jpeg', 49);
          latestSocket.send(Buffer.concat([header, jpg.subarray(i * 12288, (i + 1) * 12288)]));
        }
      };
      sendJpeg();
      await page.waitForFunction(selector => document.querySelector(selector)?.naturalWidth > 0, {}, image);
      await page.screenshot({ path: path.join(evidence, `${width}-live.png`) });
      const control = 'button[aria-label="Control"]';
      const fit = 'button[aria-label^="Fit width"]';
      const field = 'textarea[aria-label="Shared tab input"]';
      const switcher = 'button[aria-label="Release readiness checklist, switch stream"]';
      const bounds = () => page.$eval(image, el => {
        const { x, y, width, height } = el.getBoundingClientRect();
        return { x, y, width, height };
      });
      // Zoom and pan before entering Control. Compare delivered coordinates
      // with the rendered (and clipped) image, not the viewport dimensions.
      if (phone) {
        await page.tap(control);
        await page.waitForSelector(`${control}[aria-pressed="true"]`);
        await page.focus(control);
        await page.keyboard.press('Escape');
        await page.waitForSelector(`${control}[aria-pressed="false"]`);
      }
      await page.click(fit);
      const initial = await bounds();
      const p = { x: width / 2, y: height / 2 };
      const drag = async (x, y, dx) => {
        if (phone) {
          await page.touchscreen.touchStart(x, y);
          await page.touchscreen.touchMove(x + dx, y);
          await page.touchscreen.touchEnd();
        } else {
          await page.mouse.move(x, y);
          await page.mouse.down();
          await page.mouse.move(x + dx, y);
          await page.mouse.up();
        }
      };
      await drag(p.x, p.y, 64);
      const panned = await bounds();
      assert.ok(panned.x > initial.x);
      assert.deepEqual(input, [], 'watch-mode pan must not send input');

      await page.click(control);
      assert.equal(await page.$eval(control, el => el.getAttribute('aria-pressed')), 'true');
      if (phone) {
        await page.touchscreen.tap(p.x, p.y);
        await drag(p.x, p.y, -40);
        await page.waitForFunction(selector => document.activeElement?.matches(selector), {}, field);
        await page.$eval(field, el => {
          el.dispatchEvent(new CompositionEvent('compositionstart', { bubbles: true }));
          el.value = '入力';
          el.dispatchEvent(new InputEvent('input', { bubbles: true, isComposing: true }));
          el.dispatchEvent(new CompositionEvent('compositionend', { bubbles: true, data: '入力' }));
        });
      } else {
        await drag(p.x, p.y, -40);
        await page.keyboard.press('A');
        await page.mouse.wheel({ deltaY: 112 });
        await waitForInput(events => events.some(event => event.kind === 'wheel' && event.dy === 112));
      }
      // The synthetic peer witnesses input before assertions inspect it.
      if (phone) await waitForInput(events => events.some(event => event.kind === 'text'));
      await page.keyboard.press('Escape');
      await page.waitForFunction(selector => document.querySelector(selector)?.getAttribute('aria-pressed') === 'false', {}, control);
      const actions = input.filter(event => event.kind === 'pointer');
      const down = actions.find(event => event.action === 'down');
      assert.ok(down && Math.abs(down.x - (p.x - panned.x) / panned.width) < 0.001);
      assert.ok(Math.abs(down.y - (p.y - panned.y) / panned.height) < 0.001);
      assert.ok(actions.some(event => event.action === 'move' && event.buttons === 1));
      assert.ok(actions.some(event => event.action === 'up' && event.buttons === 0));
      assert.deepEqual(await bounds(), panned, 'Control drag must not pan the image');
      if (phone) {
        assert.equal(actions.filter(event => event.action === 'down').length, 2, 'touch tap and drag each press the shared tab');
        assert.equal(actions.filter(event => event.action === 'up').length, 2, 'touch tap and drag each release the shared tab');
        assert.deepEqual(input.filter(event => event.kind === 'text'), [{ kind: 'text', text: '入力' }]);
      }
      else {
        assert.ok(input.some(event => event.kind === 'key' && event.action === 'down' && event.code === 'KeyA'));
        assert.ok(input.some(event => event.kind === 'wheel' && event.dy === 112));
      }
      input = [];
      await drag(p.x, p.y, initial.x - panned.x);
      assert.deepEqual(await bounds(), initial);
      assert.deepEqual(input, [], 'Escape restores watch-only panning');
      await page.click('button[aria-label^="Fit height"]');
      await page.click(control);
      await page.waitForSelector(`${control}[aria-pressed="true"]`);
      await page.screenshot({ path: path.join(evidence, `${width}-control.png`) });
      await page.click(control);
      await page.click(switcher);
      await page.waitForFunction(() => document.activeElement?.textContent === 'Deployment status');
      await page.screenshot({ path: path.join(evidence, `${width}-switcher.png`) });
      await page.keyboard.press('Escape');
      await page.waitForSelector(`${switcher}[aria-expanded="false"]`);

      const frameUrl = await page.$eval(image, img => img.src);
      const attached = connections;
      const original = latestSocket;

      // Hold input through an idle reconnect. Even if the socket is congested,
      // its final discrete releases should be sent before the old peer closes.
      input = [];
      await page.evaluate(() => { window.streamInputBackpressure = true; });
      await page.focus(control);
      await page.keyboard.press('Enter');
      await page.mouse.move(p.x, p.y);
      await page.mouse.down();
      await page.mouse.move(p.x + 30, p.y);
      await page.keyboard.down('Shift');

      // Leave the socket open and silent. A transport close must not be what
      // drives this state. Advance only viewer timers, not request/paint clocks.
      await page.evaluate(() => window.advanceStreamTimers());
      await capture('Paused', 'paused');
      await page.waitForFunction(() => window.streamPendingTimers() > 0);
      assert.equal(connections, attached + 1);
      assert.notEqual(latestSocket, original);
      await page.mouse.up();
      await page.keyboard.up('Shift');
      await page.evaluate(() => { window.streamInputBackpressure = false; });
      await waitForInput(events => events.some(event => event.kind === 'key' && event.action === 'up'));
      assert.deepEqual(input.map(({ kind, action }) => [kind, action]), [
        ['pointer', 'down'], ['key', 'down'], ['pointer', 'up'], ['key', 'up'],
      ]);
      assert.equal(await page.$eval(image, img => img.src), frameUrl, 'retain last frame during auto-retry');
      assert.ok(await page.$eval('button[aria-label="Reconnect"]', el => el.classList.contains('bg-surface-raised')));
      const advanceWithoutRetry = async () => {
        const [before, after] = await page.evaluate(() => {
          const before = window.streamMetadataFetches();
          window.advanceStreamTimers();
          return [before, window.streamMetadataFetches()];
        });
        assert.equal(after, before, 'the retry must not fetch metadata again');
        assert.equal(connections, attached + 1, 'there is only one automatic reconnect');
      };
      await advanceWithoutRetry();
      sendJpeg();
      await page.waitForFunction((selector, previous) => {
        const img = document.querySelector(selector);
        return img?.naturalWidth > 0 && img.src !== previous &&
          !document.querySelector('button[aria-label="Reconnect"]').classList.contains('bg-surface-raised');
      }, {}, image, frameUrl);
      await advanceWithoutRetry();
      await capture('Paused', 'paused-after-recovery');
      assert.equal(new URL(page.url()).hash, '#/streams/' + id);
      await page.focus('button[aria-label="Back"]');
      await page.keyboard.press('Tab');
      assert.equal(await page.evaluate(() => document.activeElement?.getAttribute('aria-label')), 'Release readiness checklist, switch stream');
      await page.keyboard.press('Tab');
      assert.equal(await page.evaluate(() => document.activeElement?.getAttribute('aria-label')), 'Reconnect');
      await page.keyboard.press('Enter');
      await page.waitForFunction(() => [...document.querySelectorAll('main [aria-live="polite"]')].some(el => el.textContent === 'Waiting'));
      assert.ok(await page.evaluate(url => window.revokedStreamUrls.includes(url), frameUrl));
      mode = 'ended';
      latestSocket.close();
      await capture('Ended', 'ended');

      for (const [scenario, label] of [
        ['expired', 'Expired'], ['unavailable', 'Unavailable'], ['unauthorized', 'Unauthorized'], ['error', 'Disconnected'],
      ]) {
        mode = scenario;
        await page.reload({ waitUntil: 'domcontentloaded' });
        await capture(label, scenario);
      }

      await page.focus(switcher.replace('Release readiness checklist', 'Shared tab'));
      await page.keyboard.press('Enter');
      await page.waitForFunction(() => document.activeElement?.textContent === 'Deployment status');
      assert.deepEqual(await page.$$eval('[role=menuitem]', rows => rows.map(row => row.textContent)), ['Deployment status']);
      await page.keyboard.press('Enter');
      await page.waitForFunction(id => location.hash === '#/streams/' + id, {}, otherId);
      await page.waitForSelector('button[aria-label="Deployment status, switch stream"]');

      assert.equal(statuses.get('metadata'), prefix + stream);
      assert.equal(statuses.get('ticket'), prefix + '/api/v1/me/ws-ticket');
      assert.equal(statuses.get('view'), prefix + stream + '/view');
      assert.deepEqual(failures, []);
      console.log(`PASS ${width}×${height}: viewer states, one idle reconnect, frame recovery, keyboard reconnect, blob URL cleanup, Control input and stream switching`);
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
