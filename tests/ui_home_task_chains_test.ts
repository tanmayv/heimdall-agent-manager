import { makeVaultStore, clearActiveKey, unlockVault, lockVaultFully } from './helpers/vaultEndpointHarness.ts';
import { test } from 'node:test';
import assert from 'node:assert/strict';
import React from 'react';

const row = (id: string, extra: Record<string, unknown> = {}) => ({
  chain_id: id, title: `Chain ${id}`, status: 'active', updated_at: '2026-11-25T12:00:00Z',
  project_name: 'Project ' + id, coordinator_agent_instance_id: '', ...extra,
});
const detail = (id: string, extra: Record<string, unknown> = {}) => ({
  chain_id: id, members: [{ role: 'coordinator', agent_instance_id: 'coord-' + id, display_name: 'Coordinator ' + id, bridge_id: 'bridge' }],
  tasks: [ { task_id: id + '-1', chain_id: id, state: 'done' }, { task_id: id + '-2', chain_id: id, state: 'in_review' }, { task_id: id + '-3', chain_id: id, state: 'in_progress' } ], ...extra,
});

async function withWidget(run: (h: any) => Promise<void>) {
  const { JSDOM } = await import('jsdom');
  const dom = new JSDOM('<div id="root"></div>', { url: 'http://localhost/' });
  const win = dom.window as any;
  win.matchMedia = () => ({ matches: false, addEventListener() {}, removeEventListener() {} });
  win.HTMLElement.prototype.scrollIntoView = () => {};
  const saved = new Map(['window', 'document', 'HTMLElement', 'Node', 'localStorage', 'IS_REACT_ACT_ENVIRONMENT', 'fetch'].map((key) => [key, (globalThis as any)[key]]));
  for (const key of ['window', 'document', 'HTMLElement', 'Node', 'localStorage']) (globalThis as any)[key] = key === 'window' ? win : win[key];
  (globalThis as any).IS_REACT_ACT_ENVIRONMENT = true;
  const { Provider } = await import('react-redux');
  const { createRoot } = await import('react-dom/client');
  const { act } = await import('react');
  const { TaskChainsWidget } = await import('../src/ui/components/home/TaskChainsWidget.tsx');
  const { tasksApi } = await import('../src/ui/api/endpoints/tasks.ts');
  const { heimdallApi } = await import('../src/ui/api/heimdallApi.ts');
  const ws = await import('../src/ui/api/wsInvalidation.ts');
  await clearActiveKey();
  const store = await makeVaultStore({ extraMiddleware: [ws.paneDeferralResetMiddleware] });
  const root = createRoot(win.document.getElementById('root'));
  const state = { rows: [row('a')], details: {} as Record<string, any>, listStatus: 200, failDetails: new Set<string>(), delayTasks: false };
  const requests: { path: string; credentials: string }[] = [];
  const releases: (() => void)[] = [];
  globalThis.fetch = async (input: any, init: any = {}) => {
    const path = new URL(String(input?.url ?? input), 'http://localhost').pathname;
    requests.push({ path: path + (String(input).includes('?') ? '?' + String(input).split('?')[1] : ''), credentials: init.credentials });
    let data: any; let status = 200;
    if (path === '/api/v1/task-chains') { data = state.rows; status = state.listStatus; }
    else if (path === '/api/v1/bridges') data = [{ bridge_id: 'bridge', label: 'dawnstar', status: 'online' }];
    else {
      const [, id, taskId] = path.match(/task-chains\/([^/]+)(?:\/tasks\/([^/]+))?/) || [];
      if (taskId) {
        if (state.delayTasks) await new Promise<void>((resolve) => releases.push(resolve));
        data = { task_id: taskId, chain_id: id, state: 'done' };
      } else { data = state.details[id] || detail(id); status = state.failDetails.has(id) ? 503 : 200; }
    }
    return new Response(JSON.stringify(status < 400 ? { data } : { error: { message: 'Unavailable' } }), { status, headers: { 'Content-Type': 'application/json' } });
  };
  const get = (id: string) => win.document.querySelector(`[data-debug-id="${id}"]`) as HTMLElement;
  const text = () => get('home-widget-chains').textContent || '';
  const settle = async (complete: () => boolean = () => true) => {
    // List completion mounts card queries in the next React commit. Wait for
    // those actual query/render states, rather than one timed act boundary.
    let stable = 0;
    for (let i = 0; i < 200; i++) {
      await act(async () => { await new Promise((resolve) => setTimeout(resolve, 10)); });
      const pending = Object.entries(hStoreQueries()).some(([key, value]: any) => /^(fetchHomeTaskChains|fetchTaskChainDetail|getHomeFleet)\(/.test(key) && value?.status === 'pending');
      const loading = !get('home-widget-chains') || /Loading (ticket progress|task chains)/.test(text());
      stable = !pending && !loading && complete() ? stable + 1 : 0;
      if (stable >= 2) return;
    }
    assert.fail('Widget queries did not settle: ' + text());
  };
  const hStoreQueries = () => store.getState()[heimdallApi.reducerPath]?.queries || {};
  const render = async () => { await act(async () => root.render(React.createElement(Provider, { store }, React.createElement(TaskChainsWidget)))); await settle(); };
  const click = async (id: string) => { assert.ok(get(id), id); await act(async () => get(id).click()); await settle(); };
  const invalidate = async () => { await act(async () => store.dispatch(heimdallApi.util.invalidateTags([{ type: 'ChainList', id: 'ALL' }]))); await settle(); };
  const event = async (payload: any) => { await act(async () => ws.handleUserWsEvent(store.dispatch, payload)); };
  try {
    await run({ state, store, requests, releases, render, settle, get, text, click, invalidate, event, ws, tasksApi, heimdallApi, act, win });
  } finally {
    for (const release of releases) release();
    ws.resetQueuedInvalidations();
    await act(async () => root.unmount());
    store.dispatch(heimdallApi.util.resetApiState());
    await clearActiveKey();
    win.close();
    for (const [key, value] of saved) (globalThis as any)[key] = value;
  }
}

test('Live widget: cookie-auth complete list, active totals/order, visible-only detail subscriptions and synchronous shrink', async () => {
  await withWidget(async (h) => {
    h.state.rows = ['g', 'f', 'e', 'd', 'c', 'b', 'a'].map((id) => row(id));
    h.state.rows.push(row('cancelled', { status: 'cancelled' }), row('completed', { status: 'completed' }), row('archived', { status: 'archived' }));
    h.state.details.a = detail('a', { tasks: [] });
    await h.render();
    assert.match(h.text(), /7 active/);
    assert.deepEqual([...h.win.document.querySelectorAll('.home-chain-title')].map((el: any) => el.textContent), ['Chain a', 'Chain b', 'Chain c']);
    assert.match(h.text(), /0 of 0 tickets done/);
    assert.match(h.text(), /Coordinator b@dawnstar/);
    assert.equal(h.requests.filter((r: any) => /task-chains\/[abc]$/.test(r.path)).length, 3);
    assert.equal(h.requests.filter((r: any) => /task-chains\/[defg]$/.test(r.path)).length, 0);
    assert.equal(h.requests[0].path, '/api/v1/task-chains?flat=1');
    assert.ok(h.requests.every((r: any) => r.credentials === 'include'));
    await h.click('home-chains-next'); await h.click('home-chains-next');
    assert.match(h.text(), /7 of 7/);
    assert.equal(h.requests.filter((r: any) => r.path.includes('?flat=1')).length, 1);
    assert.equal(h.tasksApi.util.selectCachedArgsForQuery(h.store.getState(), 'fetchTaskChainDetail').length, 7);
    // Cached earlier pages remain reusable; only this page retains subscriptions.
    const subs = h.store.dispatch(h.heimdallApi.internalActions.internal_getRTKQSubscriptions());
    const active = ['a', 'b', 'c', 'd', 'e', 'f', 'g'].filter((id) => subs.getSubscriptionCount(`fetchTaskChainDetail({"chainId":"${id}"})`) > 0);
    assert.deepEqual(active, ['g']);
    h.state.rows = [row('b'), row('a')]; await h.invalidate();
    assert.match(h.text(), /2 active/); assert.equal(h.get('home-chains-next'), null);
    assert.equal(h.win.document.querySelectorAll('.home-chain-card').length, 2);
    h.state.rows = []; await h.invalidate(); assert.match(h.text(), /No active task chains/);
    h.state.rows = ['a', 'b', 'c', 'd'].map((id) => row(id)); await h.invalidate();
    assert.match(h.text(), /1–3 of 4/);
  });
});

test('Live widget: errors never become samples/zero progress; retry and absent coordinator are distinct', async () => {
  await withWidget(async (h) => {
    h.state.rows = {} as any; await h.render();
    assert.match(h.text(), /Unable to load task chains/); assert.equal(h.win.document.querySelectorAll('article').length, 0);
    h.state.rows = [row('a')]; h.state.listStatus = 503; await h.click('home-task-chains-retry');
    assert.match(h.text(), /Unable to load task chains/);
    h.state.listStatus = 200; h.state.failDetails.add('a'); await h.click('home-task-chains-retry');
    assert.match(h.text(), /progress and coordinator unavailable/); assert.doesNotMatch(h.text(), /0 of 0/);
    assert.equal(h.get('home-chain-open-a').getAttribute('href'), '#/conversations/chain:a');
    assert.equal(h.get('home-chain-details-a').getAttribute('href'), '#/chains/a');
    h.state.failDetails.clear(); h.state.details.a = detail('a', { members: [] }); await h.click('home-chain-retry-a');
    assert.equal(h.get('home-chain-open-a').getAttribute('href'), '#/chains/a');
    assert.match(h.text(), /1 of 3 tickets done/);
  });
});

test('Live widget: chain-addressed native links resolve membership and follow coordinator replacement', async () => {
  await withWidget(async (h) => {
    await h.render();
    const href = '#/conversations/chain:a';
    assert.equal(h.get('home-chain-open-a').getAttribute('href'), href);
    const modified = new h.win.MouseEvent('click', { bubbles: true, cancelable: true, ctrlKey: true });
    h.get('home-chain-open-a').dispatchEvent(modified); assert.equal(modified.defaultPrevented, false);
    h.state.details.a = detail('a', { members: [{ role: 'coordinator', agent_instance_id: 'replacement', display_name: 'Replacement' }] });
    await h.event({ type: 'resource_changed', resource: 'task_chain', resource_id: 'a', change: 'coordinator_changed' });
    await h.act(async () => h.ws.flushQueuedInvalidations()); await h.settle();
    assert.match(h.text(), /Replacement/); assert.equal(h.get('home-chain-open-a').getAttribute('href'), href);
    assert.doesNotMatch(href, /coord|replacement/);
  });
});

test('Live widget: incomplete collections remain unavailable; explicit empty arrays prove a zero-task chain', async () => {
  await withWidget(async (h) => {
    await h.render();
    const malformed = [
      { chain_id: 'a', members: [] },
      { chain_id: 'a', tasks: [] },
      { chain_id: 'a', members: [], tasks: null },
      { chain_id: 'a', tasks: [], members: null },
      { chain_id: 'a' },
      { chain_id: 'wrong-chain', tasks: [], members: [] },
    ];
    for (const response of malformed) {
      h.state.details.a = response;
      await h.act(async () => h.store.dispatch(h.heimdallApi.util.invalidateTags([{ type: 'Chain', id: 'a' }])));
      await h.settle();
      assert.match(h.text(), /progress and coordinator unavailable/, JSON.stringify(response));
      assert.doesNotMatch(h.text(), /0 of 0/);
      assert.ok(h.get('home-chain-retry-a'));
      assert.equal(h.get('home-chain-open-a').getAttribute('href'), '#/conversations/chain:a');
    }
    h.state.details.a = { chain_id: 'a', tasks: [], members: [] };
    await h.click('home-chain-retry-a');
    assert.match(h.text(), /0 of 0 tickets done/);
    assert.equal(h.get('home-chain-open-a').getAttribute('href'), '#/chains/a');
  });
});

test('Live widget: task WS updates progress/attention, coalesces list bursts and deduplicates task reads', async () => {
  await withWidget(async (h) => {
    h.state.rows = ['a', 'b', 'c', 'd'].map((id) => row(id)); await h.render();
    const initialDetails = h.requests.filter((r: any) => /task-chains\/[^/?]+$/.test(r.path)).length;
    await h.event({ type: 'task_event', chain_id: 'a', task_id: 'a-2', task: { task_id: 'a-2', chain_id: 'a', state: 'done' } });
    await h.settle();
    assert.match(h.get('home-chain-open-a').closest('article').textContent, /2 of 3 tickets done/);
    h.state.rows[0].user_validation_count = 1;
    h.state.delayTasks = true;
    for (let i = 0; i < 10; i++) await h.event({ type: 'resource_changed', resource: 'task', resource_id: 'a-3', change: 'updated', summary: { chain_id: 'a' } });
    await h.act(async () => h.ws.flushQueuedInvalidations()); await h.settle();
    assert.equal(h.requests.filter((r: any) => r.path.endsWith('/tasks/a-3')).length, 1);
    assert.equal(h.tasksApi.endpoints.fetchChainTaskDetail.select({ chainId: 'a', taskId: 'a-3' })(h.store.getState()).status, 'pending');
    // RTK's existing delayed invalidation holds list refreshes while this task
    // request is intentionally blocked. Release it before expecting attention.
    h.state.delayTasks = false;
    await h.act(async () => h.releases.shift()());
    await h.settle(() => {
      const state = h.store.getState();
      const task = h.tasksApi.endpoints.fetchChainTaskDetail.select({ chainId: 'a', taskId: 'a-3' })(state);
      const list = h.tasksApi.endpoints.fetchHomeTaskChains.select()(state);
      return task.status === 'fulfilled' && list.status === 'fulfilled' && list.data?.chains.find((chain: any) => chain.chainId === 'a')?.hasUserValidation;
    });
    assert.equal(h.tasksApi.endpoints.fetchChainTaskDetail.select({ chainId: 'a', taskId: 'a-3' })(h.store.getState()).status, 'fulfilled');
    assert.equal(h.tasksApi.endpoints.fetchHomeTaskChains.select()(h.store.getState()).status, 'fulfilled');
    assert.match(h.get('home-chain-open-a').closest('article').textContent, /Needs review/);
    assert.equal(h.requests.filter((r: any) => r.path.endsWith('/tasks/a-3')).length, 2);
    assert.match(h.get('home-chain-open-a').closest('article').textContent, /3 of 3 tickets done/);
    assert.equal(h.requests.filter((r: any) => /task-chains\/[^/?]+$/.test(r.path)).length, initialDetails);
    assert.equal(h.requests.filter((r: any) => r.path.includes('/task-chains/d')).length, 0);
    // One initial list, one task_event flush, one burst flush; idle does not poll.
    assert.ok(h.requests.filter((r: any) => r.path.includes('?flat=1')).length <= 3);
    const before = h.requests.length; await h.settle(); assert.equal(h.requests.length, before);
  });
});

test('Live widget: vault-safe labels and account cache reset never expose old-owner rows', async () => {
  await withWidget(async (h) => {
    const { keyringFromHex } = await import('./helpers/vaultTestKeyring.ts');
    const { encryptVaultText } = await import('../src/ui/utils/vaultContent.ts');
    const hex = '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';
    const key = await keyringFromHex(hex);
    h.state.rows = [row('a', { title: await encryptVaultText('Private chain', key), project_name: await encryptVaultText('Private project', key) })];
    h.state.details.a = detail('a', { members: [{ role: 'coordinator', agent_instance_id: 'coord', display_name: await encryptVaultText('Private coordinator', key) }] });
    await h.render(); assert.doesNotMatch(h.text(), /vault:v|Private/);
    await h.act(async () => { await unlockVault(h.store, hex); h.store.dispatch(h.heimdallApi.util.resetApiState()); }); await h.settle();
    assert.match(h.text(), /Private chain/); assert.match(h.text(), /Private project/); assert.match(h.text(), /Private coordinator/);
    h.state.rows = [row('new-owner')];
    await h.act(async () => { await lockVaultFully(h.store); });
    assert.doesNotMatch(h.text(), /Private/);
    await h.settle(); assert.match(h.text(), /Chain new-owner/); assert.doesNotMatch(h.text(), /Private|vault:v/);
  });
});
