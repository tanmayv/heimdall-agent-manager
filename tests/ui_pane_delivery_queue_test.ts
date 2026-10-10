import './helpers/vaultEndpointHarness.ts';
import { test } from 'node:test';
import assert from 'node:assert/strict';
import * as xtermModule from '@xterm/xterm';
import { PaneDeliveryQueue, repaintCapturedScreen, splitPaneInput } from '../src/ui/components/shells/paneDeliveryQueue.ts';
import { encryptShellStreamPayload, decryptShellStreamPayload } from '../src/ui/components/shells/useShellStream.ts';

const Terminal = (xtermModule as any).Terminal ?? (xtermModule as any).default.Terminal;
const key = '0123456789abcdef'.repeat(4);
const text = (value: string) => new TextEncoder().encode(value);
const write = (term: any, bytes: Uint8Array): Promise<void> => new Promise(resolve => term.write(bytes, resolve));

test('encrypted output, capture repaint and following plaintext render in wire order', async () => {
  const term = new Terminal({ cols: 80, rows: 24, convertEol: false });
  const queue = new PaneDeliveryQueue(() => assert.fail('queue unexpectedly failed'));
  const oldOutput = await encryptShellStreamPayload('obsolete\r\n', key);
  const capture = await encryptShellStreamPayload('hub α\nbridge β\n\n', key);
  queue.enqueue(oldOutput.length * 2, async () => {
    await new Promise(resolve => setTimeout(resolve, 20));
    await write(term, await decryptShellStreamPayload(oldOutput, key));
  });
  queue.enqueue(capture.length * 2, async () => {
    const bytes = await decryptShellStreamPayload(capture, key);
    await write(term, repaintCapturedScreen(bytes, 1, 8));
  });
  queue.enqueue(20, async () => { await write(term, text(' live')); });
  await queue.whenIdle();
  assert.equal(term.buffer.active.getLine(0).translateToString(true), 'hub α');
  assert.equal(term.buffer.active.getLine(1).translateToString(true), 'bridge β live');
  assert.equal(queue.queuedBytes, 0);
  term.dispose();
});

test('overflow discards queued work and invokes reconnect once', async () => {
  let release!: () => void;
  let recoveries = 0;
  const delivered: string[] = [];
  const queue = new PaneDeliveryQueue(() => recoveries++, 32);
  queue.enqueue(16, async () => { await new Promise<void>(resolve => { release = resolve; }); });
  queue.enqueue(16, async () => { delivered.push('obsolete'); });
  assert.equal(queue.enqueue(1, async () => {}), false);
  assert.equal(queue.enqueue(1, async () => {}), false);
  assert.equal(recoveries, 1);
  assert.equal(queue.queuedBytes, 16, 'in-flight data remains accounted until completion');
  release();
  await queue.whenIdle();
  assert.deepEqual(delivered, []);
  assert.equal(queue.queuedBytes, 0);
  const fresh = new PaneDeliveryQueue(() => assert.fail('fresh queue failed'));
  fresh.enqueue(4, async () => { delivered.push('fresh snapshot'); });
  await fresh.whenIdle();
  assert.deepEqual(delivered, ['fresh snapshot']);
});

test('chunked repaint preserves Unicode and ANSI colors', async () => {
  const term = new Terminal({ cols: 80, rows: 24, convertEol: false });
  const bytes = repaintCapturedScreen(text('\x1b[32mgreen λ\x1b[0m\nnext row'), 1, 8);
  const queue = new PaneDeliveryQueue(() => assert.fail('queue failed'));
  // Split inside a UTF-8 character and inside ANSI sequences, as the wire may do.
  for (let offset = 0; offset < bytes.length; offset += 3) {
    const part = bytes.slice(offset, offset + 3);
    queue.enqueue(part.length, () => write(term, part));
  }
  await queue.whenIdle();
  assert.equal(term.buffer.active.getLine(0).translateToString(true), 'green λ');
  assert.equal(term.buffer.active.getLine(1).translateToString(true), 'next row');
  term.dispose();
});

test('large pasted input is bounded and preserves Unicode at chunk boundaries', () => {
  const original = 'x'.repeat(8191) + '😀' + 'λ'.repeat(80000);
  const parts = splitPaneInput(original);
  assert.equal(parts.join(''), original);
  for (const part of parts) {
    assert.ok(part.length <= 8192);
    assert.ok(Buffer.byteLength(part, 'utf8') < 32 * 1024);
    assert.equal(new TextDecoder().decode(new TextEncoder().encode(part)), part);
  }
});
