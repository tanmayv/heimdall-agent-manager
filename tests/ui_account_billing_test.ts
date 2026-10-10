import { test } from 'node:test';
import assert from 'node:assert/strict';
import { JSDOM } from 'jsdom';
import { describeEntitlements } from '../src/ui/utils/accountEntitlements.ts';
import { openPaddleCheckout, clearPaddleCheckoutHandler, validatePortalUrl } from '../src/ui/services/paddleCheckout.ts';

test('user parameters describe custom bridge counts and explicit streaming grants', () => {
  assert.equal(describeEntitlements({ max_bridges: 0, terminal_streaming_enabled: false }), '0 bridges · Terminal streaming not included');
  assert.equal(describeEntitlements({ max_bridges: 1, terminal_streaming_enabled: true }), '1 bridge · Terminal streaming included');
  assert.equal(describeEntitlements({ max_bridges: 12, terminal_streaming_enabled: true }), '12 bridges · Terminal streaming included');
});

test('checkout opens only the server transaction and treats completion as a notification', async () => {
  const dom = new JSDOM('<!doctype html><html><head></head><body></body></html>');
  const oldWindow = globalThis.window;
  const oldDocument = globalThis.document;
  Object.assign(globalThis, { window: dom.window, document: dom.window.document });
  const calls: unknown[] = [];
  let callback: (event: { name: string }) => void = () => {};
  let completed = 0;
  (dom.window as any).Paddle = {
    Environment: { set: (env: string) => calls.push(env) },
    Initialize: (options: any) => { calls.push(options.token); callback = options.eventCallback; },
    Checkout: { open: (options: any) => calls.push(options) },
  };
  try {
    await openPaddleCheckout({ transactionId: 'txn_server123', clientToken: 'test_browser_token', environment: 'sandbox', theme: 'dark', onCompleted: () => completed++ });
    assert.deepEqual(calls, ['sandbox', 'test_browser_token', { transactionId: 'txn_server123', settings: { displayMode: 'overlay', theme: 'dark' } }]);
    callback({ name: 'checkout.loaded' });
    assert.equal(completed, 0);
    callback({ name: 'checkout.completed' });
    assert.equal(completed, 1);
    clearPaddleCheckoutHandler();
    callback({ name: 'checkout.completed' });
    assert.equal(completed, 1, 'closed account panels do not retain callbacks');
    const abort = new AbortController();
    abort.abort();
    const before = calls.length;
    await assert.rejects(openPaddleCheckout({ transactionId: 'txn_server123', clientToken: 'test_browser_token', environment: 'sandbox', theme: 'dark', signal: abort.signal, onCompleted: () => {} }), { name: 'AbortError' });
    assert.equal(calls.length, before, 'switching away from the account cancels a pending checkout');
    await assert.rejects(openPaddleCheckout({ transactionId: 'pri_arbitrary', clientToken: 'test_browser_token', environment: 'sandbox', theme: 'dark', onCompleted: () => {} }), /not configured/);
    await assert.rejects(openPaddleCheckout({ transactionId: 'txn_server123', clientToken: 'live_other', environment: 'live', theme: 'dark', onCompleted: () => {} }), /Refresh the page/);
  } finally {
    Object.assign(globalThis, { window: oldWindow, document: oldDocument });
    dom.window.close();
  }
});

test('portal links reject spoofed origins and non-HTTPS URLs', () => {
  assert.equal(validatePortalUrl('https://customer-portal.paddle.com/cpl_123?token=temporary'), 'https://customer-portal.paddle.com/cpl_123?token=temporary');
  assert.equal(validatePortalUrl('https://sandbox-customer-portal.paddle.com/cpl_123'), 'https://sandbox-customer-portal.paddle.com/cpl_123');
  for (const url of ['javascript:alert(1)', 'https://customer-portal.paddle.com.evil.test/', 'https://customer-portal.paddle.com@evil.test/', 'http://customer-portal.paddle.com/', 'https://user:pass@customer-portal.paddle.com/', 'https://customer-portal.paddle.com:8443/']) {
    assert.throws(() => validatePortalUrl(url));
  }
});
