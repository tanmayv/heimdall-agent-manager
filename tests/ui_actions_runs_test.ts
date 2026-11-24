import './helpers/vaultEndpointHarness.ts';
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { runRowText, runTargetLabel, RUN_REASON_TEXT } from '../src/ui/components/actions/RunHistory.tsx';
const base: any = { not_before: '2026-12-01T09:00:00Z', joined_run_id: 'arun_12345678901234', joined_count: 0, delivery_expires_at: '2026-12-02T09:00:00Z' };
test('all seven run states have the required text', () => {
  assert.equal(runRowText({ ...base, state: 'queued' }), 'Waiting');
  assert.equal(runRowText({ ...base, state: 'deferred' }), 'Deferred until ' + base.not_before);
  assert.equal(runRowText({ ...base, state: 'routed' }, 'Laptop'), 'Sent to Laptop, waiting for it · expires ' + base.delivery_expires_at);
  assert.equal(runRowText({ ...base, state: 'delivered', joined_count: 3 }), 'Delivered · +3 merged');
  assert.equal(runRowText({ ...base, state: 'joined' }), 'Merged into arun_1234567');
  for (const state of ['skipped', 'failed']) for (const [reason, expected] of Object.entries(RUN_REASON_TEXT)) assert.equal(runRowText({ ...base, state, reason }), expected);
});
test('v7 delivery failure reasons have exact wording', () => {
  assert.deepEqual(Object.fromEntries(['bridge_offline', 'no_answer', 'start_failed', 'bridge_too_old', 'no_placement', 'target_missing', 'delivery_failed'].map(k => [k, RUN_REASON_TEXT[k]])), {
    bridge_offline: 'The machine stayed offline', no_answer: 'The machine did not answer', start_failed: 'The agent could not be started on that machine', bridge_too_old: "The machine's bridge needs an update", no_placement: 'No machine matched the rules', target_missing: 'The target no longer exists', delivery_failed: 'The prompt could not be stored',
  });
});

test('Load more sends both fields from the last rendered run', async () => {
  const { JSDOM } = await import('jsdom');
  const React = await import('react');
  const { Provider } = await import('react-redux');
  const { makeVaultStore, installFetchCapture } = await import('./helpers/vaultEndpointHarness.ts');
  const { actionsApi } = await import('../src/ui/api/endpoints/actions.ts');
  // Create the store before installing window so Redux uses its Node timer scheduler.
  const store = await makeVaultStore();
  const dom = new JSDOM('<div id="root"></div>', { url: 'http://localhost/', pretendToBeVisual: true });
  const g = globalThis as any;
  const names = ['window', 'document', 'HTMLElement', 'Node', 'requestAnimationFrame', 'cancelAnimationFrame', 'IS_REACT_ACT_ENVIRONMENT'];
  const previous = new Map(names.map(name => [name, Object.getOwnPropertyDescriptor(g, name)]));
  for (const name of names) Object.defineProperty(g, name, { configurable: true, writable: true, value: name === 'IS_REACT_ACT_ENVIRONMENT' ? true : (dom.window as any)[name] });
  const capture = installFetchCapture();
  let root: any;
  try {
    const { createRoot } = await import('react-dom/client');
    const History = (await import('../src/ui/components/actions/RunHistory.tsx')).default;
    const rows = Array.from({ length: 50 }, (_, i) => ({ ...base, id: 'run_' + (100 - i), state: 'delivered', created_at: '2026-12-01T09:00:00Z', target_instance_id: '', trigger_id: '', event_type: '' }));
    capture.setNextResponse({ data: rows });
    root = createRoot(dom.window.document.getElementById('root')!);
    await React.act(async () => {
      root.render(React.createElement(Provider, { store, children: React.createElement(History, { actionId: 'act_1', catalog: { instances: { byId: new Map() }, bridges: { byId: new Map() } } as any }) }));
      await new Promise(resolve => setTimeout(resolve, 0));
    });
    // RTK query publishes its completed state asynchronously.
    for (let i = 0; i < 20 && !dom.window.document.querySelector('[data-debug-id="action-runs-more"]'); i++) {
      await React.act(async () => { await new Promise(resolve => setTimeout(resolve, 10)); });
    }
    const button = dom.window.document.querySelector('[data-debug-id="action-runs-more"]');
    assert.ok(button);
    capture.setNextResponse({ data: [] });
    await React.act(async () => {
      button.dispatchEvent(new dom.window.MouseEvent('click', { bubbles: true }));
      await new Promise(resolve => setTimeout(resolve, 0));
    });
    const params = new URL(capture.requests.at(-1)!.url, 'http://hub').searchParams;
    assert.equal(params.get('before'), rows[49].created_at);
    assert.equal(params.get('before_id'), rows[49].id);
  } finally {
    await React.act(async () => {
      await Promise.all(store.dispatch(actionsApi.util.getRunningQueriesThunk()));
      if (root) root.unmount();
      store.dispatch(actionsApi.util.resetApiState());
      await new Promise(resolve => setTimeout(resolve, 30));
    });
    dom.window.close();
    for (const [name, descriptor] of previous) {
      if (descriptor) Object.defineProperty(g, name, descriptor);
      else delete g[name];
    }
  }
});

test('run targets resolve bot names by the actual instance and degrade to raw IDs', () => {
  const catalog: any = {
    bots: { all: [{ id: 'bot_1', label: 'Ninjy', instanceId: 'inst_bot' }] },
    instances: { byId: new Map([['inst_agent', { label: 'Reviewer' }]]) },
  };
  assert.equal(runTargetLabel({ target_instance_id: 'inst_bot' }, catalog), 'Bot · Ninjy');
  assert.equal(runTargetLabel({ target_instance_id: 'inst_agent' }, catalog), 'Reviewer');
  assert.equal(runTargetLabel({ target_instance_id: 'inst_old_bot' }, catalog), 'inst_old_bot');
  assert.equal(runTargetLabel({ target_instance_id: '' }, catalog), '');
});
