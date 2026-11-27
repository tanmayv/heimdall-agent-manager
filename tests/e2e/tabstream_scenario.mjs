// Exercise the real CLI/relay against an isolated stack supplied by the fixture.
// Keep synthetic frames in memory even on failure. Only aggregate counts escape.
import assert from 'node:assert/strict';
import { performance } from 'node:perf_hooks';
import { createFrameAssembler } from '../../src/ui/components/streams/streamFrames.ts';

const API = '/api/v1/streams';

export async function checkTabStream({
  cli, ownerRequest, foreignRequest, openViewer, openPage, target, waitForCapture,
  closeTab, waitFor, audit, report, expiryOnly = false,
}) {
  const idFromLink = (link) => {
    const url = new URL(link.trim());
    assert.match(url.hash, /^#\/streams\/[0-9a-f]{32}$/);
    assert.equal(url.search, '');
    assert.equal(url.username, '');
    assert.equal(url.password, '');
    return url.hash.split('/').at(-1);
  };
  const share = async () => {
    const link = await cli(['stream', 'share', '--tab', target]);
    const id = idFromLink(link);
    const route = `${API}/${id}`;
    const owner = await ownerRequest(route);
    assert.equal(owner.status, 200);
    const { data: meta } = await owner.json();
    assert.deepEqual(meta.source, { kind: 'browser_tab', ref: target });
    assert.equal((await foreignRequest(route)).status, 404);
    await audit.register({ id, target, title: meta.title });
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
      const control = await share();
      const controlMs = performance.now() - start;
      await cli(['stream', 'stop', control.id]);
      assert.ok(controlMs < 2000, 'control command responsive during capture');
      await waitFor(() => samples.at(-1)?.arrival - samples[0].arrival >= 5000, 'five seconds of capture');
      const duration = (samples.at(-1).arrival - samples[0].arrival) / 1000;
      const measured = samples.slice(1);
      const fps = measured.length / duration;
      const bytesPerSecond = measured.reduce((sum, sample) => sum + sample.bytes, 0) / duration;
      assert.ok(fps <= 8, 'sustained owner JPEG rate within 8 fps');
      assert.ok(bytesPerSecond <= 1_000_000, 'sustained owner JPEG payload within 1 MB/s');
      report({ frames: samples.length, fps, bytesPerSecond, controlMs });
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
