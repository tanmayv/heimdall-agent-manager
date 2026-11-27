// Exercise the real CLI/relay against an isolated stack supplied by the fixture.
// Keep synthetic frames in memory even on failure. Only aggregate counts escape.
import assert from 'node:assert/strict';
import { randomBytes } from 'node:crypto';
import { performance } from 'node:perf_hooks';
import { createFrameAssembler } from '../../src/ui/components/streams/streamFrames.ts';

const API = '/api/v1/streams';
const image = 'img[alt="Latest image of the shared tab"]';
const control = 'button[aria-label="Control"]';

async function checkViewerInput(viewer, source, audit, waitFor) {
  const point = async (selector, offset = 0) => {
    const [x, y] = await source.$eval(selector, (node, offset) => {
      const rect = node.getBoundingClientRect();
      return [(rect.left + rect.width / 2 + offset) / innerWidth,
        (rect.top + rect.height / 2) / innerHeight];
    }, offset);
    const box = await viewer.$eval(image, node => {
      const rect = node.getBoundingClientRect();
      return { x: rect.left, y: rect.top, width: rect.width, height: rect.height };
    });
    return [box.x + x * box.width, box.y + y * box.height];
  };
  const actions = () => source.evaluate(() => window.actions);
  const owner = await point('#owner');
  assert.equal(await viewer.$eval(control, button => button.getAttribute('aria-pressed')), 'false');
  await viewer.mouse.click(...owner);
  await viewer.click(control);
  await viewer.waitForSelector(control + '[aria-pressed="true"]');
  await viewer.mouse.click(...owner);
  await waitFor(async () => (await actions()).owner >= 1, 'owner click in source tab');
  assert.equal((await actions()).owner, 1, 'watch-only click was not forwarded');

  await viewer.mouse.click(...await point('#typing'));
  await waitFor(() => source.$eval('#typing', node => document.activeElement === node), 'source input focus');
  await viewer.keyboard.press('a');
  await waitFor(() => source.$eval('#typing', node => node.value === 'a'), 'owner physical key');
  const marker = 'stream-input-' + randomBytes(16).toString('hex');
  audit.input(marker);
  // Model an IME commit as one text frame, so the entire marker can be
  // searched for rather than individual characters from key events.
  await viewer.$eval('textarea[aria-label="Shared tab input"]', (node, text) => {
    node.dispatchEvent(new CompositionEvent('compositionstart', { bubbles: true }));
    node.value = text;
    node.dispatchEvent(new CompositionEvent('compositionend', { bubbles: true, data: text }));
  }, marker);
  await waitFor(() => source.$eval('#typing', (node, expected) => node.value === expected, 'a' + marker),
    'owner composed text in source tab');

  await viewer.mouse.move(...await point('#drag', -70));
  await viewer.mouse.down();
  try {
    await waitFor(() => source.evaluate(() => window.dragHeld()), 'owner drag held in source tab');
    // The simulated agent acts on the same tab using an independent CDP
    // connection while the owner is still holding the pointer down.
    await source.$eval('#agent', node => node.click());
    assert.equal((await actions()).agent, 1);
    await viewer.mouse.move(...await point('#drag', 70), { steps: 5 });
  } finally {
    await viewer.mouse.up();
  }
  await waitFor(async () => (await actions()).drag > 100, 'owner drag delta in source tab');
  await viewer.mouse.wheel({ deltaY: 400 });
  await waitFor(() => source.evaluate(() => scrollY > 0), 'owner wheel scrolled source tab');
}

export async function checkTabStream({
  cli, ownerRequest, foreignRequest, openViewer, openPage, target, waitForCapture,
  closeTab, waitFor, audit, report, alternate, source, expiryOnly = false,
}) {
  const idFromLink = (link) => {
    const url = new URL(link.trim());
    assert.match(url.hash, /^#\/streams\/[0-9a-f]{32}$/);
    assert.equal(url.search, '');
    assert.equal(url.username, '');
    assert.equal(url.password, '');
    return url.hash.split('/').at(-1);
  };
  const share = async (tab = target) => {
    const link = await cli(['stream', 'share', '--tab', tab]);
    const id = idFromLink(link);
    const route = `${API}/${id}`;
    const owner = await ownerRequest(route);
    assert.equal(owner.status, 200);
    const { data: meta } = await owner.json();
    assert.deepEqual(meta.source, { kind: 'browser_tab', ref: tab });
    assert.equal((await foreignRequest(route)).status, 404);
    await audit.register({ id, target: tab, title: meta.title });
    return { id, route, link: link.trim(), meta };
  };
  const initial = await share();
  if (expiryOnly) {
    // Use an isolated Bridge build with a short registration TTL. The same
    // unmodified Hub and viewer enforce the actual registration timestamp.
    const remaining = initial.meta.expires - Date.now();
    assert.ok(remaining > 0 && remaining <= 15_000, 'short TTL fixture, not a normal share');
    const expiryViewer = await openViewer(initial.id, 'owner');
    assert.equal(expiryViewer.status, 101);
    const expiresAssemble = createFrameAssembler(initial.id);
    let received = false;
    expiryViewer.onBinary(async buffer => {
      const frame = expiresAssemble(buffer);
      if (!frame) return;
      await audit.frame(new Uint8Array(await frame.arrayBuffer()));
      received = true;
    });
    const page = await openPage(initial.link);
    try {
      await page.waitForImage();
      await waitFor(() => received, 'frames before expiry');
      await waitFor(() => Date.now() >= initial.meta.expires, 'registration deadline');
      await waitFor(async () => (await ownerRequest(initial.route)).status === 404, 'expired metadata denied');
      await page.waitForExpired();
      assert.equal((await openViewer(initial.id, 'owner')).status, 404);
      await waitForCapture('Page.stopScreencast');
    } finally {
      await page.close();
      await expiryViewer.close();
    }
    await audit.finish();
    return;
  }
  const denied = await openViewer(initial.id, 'foreign');
  assert.equal(denied.status, 404);
  const viewer = await openViewer(initial.id, 'owner');
  assert.equal(viewer.status, 101);
  const assemble = createFrameAssembler(initial.id);
  const samples = [];
  viewer.onBinary(async (buffer) => {
    const arrival = performance.now();
    const frame = assemble(buffer);
    if (frame) {
      samples.push({ arrival, bytes: frame.size });
      await audit.frame(new Uint8Array(await frame.arrayBuffer()));
    }
  });

  try {
    await waitForCapture('Page.startScreencast');
    await waitFor(() => samples.length >= 2, 'owner received live frames');
    const page = await openPage(initial.link);
    try {
      await page.waitForImage();
      const start = performance.now();
      const repeat = await share();
      const controlMs = performance.now() - start;
      assert.equal(repeat.id, initial.id, 'same target reuses its live stream');
      assert.ok(controlMs < 2000, 'CLI responsive during capture');
      await waitFor(() => samples.at(-1)?.arrival - samples[0].arrival >= 5000, 'five seconds of capture');
      const duration = (samples.at(-1).arrival - samples[0].arrival) / 1000;
      const measured = samples.slice(1);
      const fps = measured.length / duration;
      const bytesPerSecond = measured.reduce((sum, sample) => sum + sample.bytes, 0) / duration;
      assert.ok(fps <= 8, 'sustained owner JPEG rate within 8 fps');
      assert.ok(bytesPerSecond <= 1_000_000, 'sustained owner JPEG payload within 1 MB/s');
      report({ frames: samples.length, fps, bytesPerSecond, controlMs });
      await checkViewerInput(page.page, source, audit, waitFor);
      const second = await share(alternate.target);
      assert.equal(second.meta.title, alternate.title);
      const initialFrame = await page.page.$eval(image, img => img.src);
      await page.page.click('button[aria-label$=", switch stream"]');
      await page.page.waitForFunction(title => [...document.querySelectorAll('[role="menuitem"]')]
        .some(item => item.textContent === title), {}, alternate.title);
      assert.deepEqual(await page.page.$$eval('[role="menuitem"]', items => items.map(item => item.textContent)),
        [alternate.title], 'switcher lists the other live stream only');
      await page.page.evaluate(title => [...document.querySelectorAll('[role="menuitem"]')]
        .find(item => item.textContent === title).click(), alternate.title);
      await page.page.waitForFunction(id => location.hash === '#/streams/' + id, {}, second.id);
      await page.page.waitForSelector('button[aria-label="' + alternate.title + ', switch stream"]');
      await waitForCapture('Page.startScreencast', alternate.target);
      await page.page.waitForFunction((selector, initialFrame) => {
        const frame = document.querySelector(selector);
        return frame?.naturalWidth > 0 && frame.src !== initialFrame;
      }, {}, image, initialFrame);
      await page.waitForImage();
      assert.equal(await page.page.$eval(control, button => button.getAttribute('aria-pressed')), 'false');
      await cli(['stream', 'stop', second.id]);
    } finally {
      await page.close();
    }
  } finally {
    await viewer.close();
  }
  await waitForCapture('Page.stopScreencast');
  assert.equal((await ownerRequest(initial.route)).status, 200, 'last viewer detach preserves share');
  await cli(['stream', 'stop', initial.id]);
  await waitFor(async () => (await ownerRequest(initial.route)).status === 404, 'explicit stop removes route');

  const closing = await share();
  const closingPage = await openPage(closing.link);
  try {
    await closingPage.waitForImage();
    await closeTab();
    await waitFor(async () => (await ownerRequest(closing.route)).status === 404, 'tab close removes route');
    await closingPage.waitForEnded();
  } finally {
    await closingPage.close();
  }
  await audit.finish();
}
