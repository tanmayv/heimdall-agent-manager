import assert from 'node:assert/strict';
import test from 'node:test';
import { createFrameAssembler } from '../src/ui/components/streams/streamFrames.ts';
import { streamFailure } from '../src/ui/components/streams/useStreamViewer.ts';
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
