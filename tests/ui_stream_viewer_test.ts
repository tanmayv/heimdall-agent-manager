import assert from 'node:assert/strict';
import test from 'node:test';
import { createFrameAssembler } from '../src/ui/components/streams/streamFrames.ts';
import { clampPan, fitFrame, toggleFit } from '../src/ui/components/streams/streamViewport.ts';
import { streamFailure } from '../src/ui/components/streams/useStreamViewer.ts';
import { createStreamInputPacer, isContinuousInput, type StreamInputEvent } from '../src/ui/components/streams/streamInput.ts';
import { resolveShellRoute } from '../src/ui/components/shell/shellRouting.ts';

const id = '0123456789abcdef0123456789abcdef';
const encoder = new TextEncoder();

function piece(seq: bigint, index: number, count: number, payload: string, streamId = id) {
  const data = encoder.encode(payload);
  const wire = new ArrayBuffer(59 + data.length);
  const bytes = new Uint8Array(wire);
  const header = new DataView(wire);
  bytes.set([4, 0, 0, 32]);
  bytes.set(encoder.encode(streamId), 4);
  header.setBigUint64(36, seq);
  header.setUint16(44, index);
  header.setUint16(46, count);
  bytes[48] = 10;
  bytes.set(encoder.encode('image/jpeg'), 49);
  bytes.set(data, 59);
  return wire;
}

test('reassembles complete matching pieces and never displays an older frame', async () => {
  const push = createFrameAssembler(id);
  const high = (1n << 60n) + 1n;
  assert.equal(push(piece(high, 0, 2, 'a')), undefined);
  assert.equal(push(piece(high, 1, 2, 'wrong', '0'.repeat(32))), undefined);
  const complete = push(piece(high, 1, 2, 'b'));
  assert.equal(complete?.type, 'image/jpeg');
  assert.equal(await complete?.text(), 'ab');
  assert.equal(push(piece(high - 1n, 0, 1, 'older')), undefined);
  assert.equal(await push(piece(high + 1n, 0, 1, 'new'))?.text(), 'new');
});

test('discards a partial frame with missing or out-of-order pieces', async () => {
  const push = createFrameAssembler(id);
  assert.equal(push(piece(1n, 1, 3, 'middle first')), undefined);
  assert.equal(push(piece(1n, 0, 3, 'a')), undefined);
  assert.equal(push(piece(1n, 2, 3, 'c')), undefined);
  assert.equal(push(piece(1n, 1, 3, 'b')), undefined);
  assert.equal(push(piece(2n, 0, 2, 'unfinished')), undefined);
  assert.equal(await push(piece(3n, 0, 1, 'replacement'))?.text(), 'replacement');
  assert.equal(push(piece(2n, 1, 2, 'late tail')), undefined);
});

test('session errors and 404 do not reveal ownership of an unknown stream', () => {
  const notFound = 404;
  const known = { title: 'Example', expires: 500 };
  assert.equal(streamFailure(notFound, undefined, 200), 'unavailable');
  assert.equal(streamFailure(notFound, known, 200), 'ended');
  assert.equal(streamFailure(notFound, known, 500), 'expired');
  assert.equal(streamFailure(401, known, 200), 'unauthorized');
  assert.equal(streamFailure(403, undefined, 200), 'unauthorized');
  assert.equal(streamFailure(undefined, known, 200), 'error');
});

test('shell routing preserves stream deep links', () => {
  assert.equal(resolveShellRoute('/streams/' + id, ''), '/streams/' + id);
});

test('fitted frames pan only along the overflowing axis, without exposing empty space', () => {
  const image = { width: 1600, height: 800 };
  const desktop = { width: 1200, height: 400 };
  const phone = { width: 400, height: 700 };
  const wide = fitFrame('fit-width', image, desktop);
  const tall = fitFrame('fit-height', image, phone);
  assert.deepEqual(wide, { width: 1200, height: 600 });
  assert.deepEqual(tall, { width: 1400, height: 700 });
  assert.deepEqual(clampPan({ x: 2000, y: -2000 }, wide, desktop), { x: 0, y: -100 });
  assert.deepEqual(clampPan({ x: 2000, y: -2000 }, tall, phone), { x: 500, y: 0 });
  assert.deepEqual(clampPan({ x: -80, y: -30 }, tall, phone), { x: -80, y: 0 });
  assert.deepEqual(clampPan({ x: -80, y: 30 }, fitFrame('fit-width', image, phone), phone), { x: 0, y: 0 });
});

test('switching either fit mode recenters instead of carrying over the previous pan', () => {
  const initial = { mode: 'fit-width' as const, pan: { x: 0, y: 80 } };
  const next = toggleFit(initial.mode);
  assert.deepEqual(next, { mode: 'fit-height', pan: { x: 0, y: 0 } });
  const moved = { ...next, pan: { x: -250, y: 0 } };
  assert.deepEqual(toggleFit(moved.mode), { mode: 'fit-width', pan: { x: 0, y: 0 } });
});

test('120 Hz hover and wheel traffic leave room for clicks and keys in Hub rolling admission', () => {
  let now = 0;
  const timers = new Map<ReturnType<typeof setTimeout>, { fire: () => void; at: number }>();
  let timerId = 0;
  const buckets = new Map<number, number>();
  const accepted: StreamInputEvent[] = [];
  const pacer = createStreamInputPacer(batch => {
    const index = Math.floor(now / 100);
    const live = [...buckets].filter(([bucket]) => index - bucket < 11);
    const total = live.reduce((count, [, value]) => count + value, 0);
    assert.ok(total + batch.length <= 60, 'Hub would reject the entire batch');
    buckets.set(index, (buckets.get(index) ?? 0) + batch.length);
    accepted.push(...batch);
  }, () => now, (fire, delay) => {
    const id = ++timerId as unknown as ReturnType<typeof setTimeout>;
    timers.set(id, { fire, at: now + delay });
    return id;
  }, id => { timers.delete(id); });
  function advance(until: number) {
    for (;;) {
      const next = [...timers].sort((a, b) => a[1].at - b[1].at)[0];
      if (!next || next[1].at > until) break;
      const [id, { fire, at }] = next;
      timers.delete(id);
      now = at;
      fire();
    }
    now = until;
  }
  const move = (x: number, buttons: number): StreamInputEvent =>
    ({ kind: 'pointer', action: 'move', x, y: 0.5, button: -1, buttons });
  const down: StreamInputEvent = { kind: 'pointer', action: 'down', x: 0.5, y: 0.5, button: 0, buttons: 1 };
  const up: StreamInputEvent = { ...down, action: 'up', buttons: 0 };
  const key: StreamInputEvent = { kind: 'key', action: 'down', key: 'a', code: 'KeyA', modifiers: 0 };
  for (let i = 0; i < 300; i++) {
    advance(i * 1000 / 120);
    if (i < 150) pacer.push(move(i / 300, 0));
    else pacer.push({ kind: 'wheel', x: 0.5, y: 0.5, dx: 0, dy: 1 });
    if (i === 125 || i === 275) {
      pacer.push(down);
      pacer.push(move(0.75, 1));
      pacer.push(up);
      pacer.push(key);
      pacer.push({ ...key, action: 'up' });
    }
  }
  advance(2600);
  const discrete = accepted.filter(event => !isContinuousInput(event));
  assert.deepEqual(discrete, [down, up, key, { ...key, action: 'up' }, down, up, key, { ...key, action: 'up' }]);
  assert.equal(accepted.filter(e => e.kind === 'wheel').reduce((sum, e) => sum + e.dy, 0), 150);
  assert.ok(accepted.filter(isContinuousInput).length < 60, 'continuous traffic is paced');
  const firstDown = accepted.indexOf(down);
  assert.deepEqual(accepted.slice(firstDown, firstDown + 3), [down, move(0.75, 1), up]);
});
