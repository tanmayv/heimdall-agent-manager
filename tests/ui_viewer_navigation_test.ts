import assert from 'node:assert/strict';
import test, { type TestContext } from 'node:test';
import { closeViewer } from '../src/ui/utils/viewerBack.ts';

function browser(t: TestContext, previous?: { sameDocument: boolean }) {
  const calls: unknown[] = [];
  const currentEntry = { index: previous ? 1 : 0, sameDocument: true };
  const stub = {
    navigation: { currentEntry, entries: () => previous ? [previous, currentEntry] : [currentEntry] },
    history: {
      back: () => calls.push('back'),
      replaceState: (_state: unknown, _title: string, href: string) => calls.push(href),
    },
    PopStateEvent: Event,
    dispatchEvent: (event: Event) => calls.push(event.type),
  };
  Object.defineProperty(globalThis, 'window', { value: stub, configurable: true });
  t.after(() => Reflect.deleteProperty(globalThis, 'window'));
  return calls;
}

test('both standalone viewers return to the previous app route when present', t => {
  const calls = browser(t, { sameDocument: true });
  closeViewer('#/conversations/inst_worker');
  closeViewer();
  assert.deepEqual(calls, ['back', 'back']);
});

test('a directly opened form replaces its route with the verified agent conversation', t => {
  const calls = browser(t);
  closeViewer('#/conversations/inst_worker');
  assert.deepEqual(calls, ['#/conversations/inst_worker', 'popstate']);
});

test('a stream opened from another document replaces its route with home', t => {
  const calls = browser(t, { sameDocument: false });
  closeViewer();
  assert.deepEqual(calls, ['#/home', 'popstate']);
});
