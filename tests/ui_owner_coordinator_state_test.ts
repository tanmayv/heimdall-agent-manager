// A chain's coordinator is never shown as "none" while it is unknown. The
// owner registry listing names it for chains whose owner published members on
// the registry row (no owner read at all); older rows are read from the owner
// concurrently with the status reads, showing a loading state until the read
// returns ('' = none) or fails; an offline owner says so.
//
// RUN: node --import ./tests/helpers/vaultEndpointHarness.ts --test tests/ui_owner_coordinator_state_test.ts

import { test } from 'node:test';
import assert from 'node:assert/strict';
import React from 'react';
import { JSDOM } from 'jsdom';
import { fakeOwner, ownerTestSession, registryRow, type OwnerCall } from './helpers/ownerFakeRelay.ts';
import { clearKeyringSession } from '../src/ui/utils/vaultKeyringSession.ts';
import { ownerCoordinatorState, registryCoordinator, type OwnerChainSummary } from '../src/ui/api/ownerChains.ts';

// React DOM fixes its event support when first loaded: build the DOM first.
const dom = new JSDOM('<!DOCTYPE html><html><body></body></html>', { url: 'http://localhost/', pretendToBeVisual: true });
const win = dom.window as any;
win.matchMedia = (q: string) => ({ matches: false, media: q, addEventListener() {}, removeEventListener() {}, addListener() {}, removeListener() {} });
for (const [key, value] of Object.entries({ window: win, document: win.document, navigator: win.navigator, HTMLElement: win.HTMLElement, Node: win.Node, IS_REACT_ACT_ENVIRONMENT: true })) {
  Object.defineProperty(globalThis, key, { value, writable: true, configurable: true });
}
const { createRoot } = await import('react-dom/client');
const { act } = await import('react');
const { ChainCoordinatorPane } = await import('../src/ui/components/mainWorkspace/ChainCoordinatorPane.tsx');
const { OwnerCoordinatorControl } = await import('../src/ui/components/taskchain/OwnerCoordinatorControl.tsx');
const { ownerChainById, ownerChainsSnapshot, refreshOwnerChains, resetOwnerChainsForTest, subscribeOwnerChains } = await import('../src/ui/api/ownerChainsStore.ts');

const base: OwnerChainSummary = {
  chainId: 'c', ownerBridgeId: 'brg', bridgeName: 'Home', online: true, title: 'T', description: '', sealed: false, tasks: [],
  projectId: '', projectName: '', migrated: false,
};

test('the coordinator state: bound, none, loading, failed, offline', () => {
  assert.deepEqual(ownerCoordinatorState({ ...base, coordinatorAgentInstanceId: 'inst_1' }), { kind: 'bound', instanceId: 'inst_1' });
  assert.deepEqual(ownerCoordinatorState({ ...base, coordinatorAgentInstanceId: '' }), { kind: 'none' });
  assert.deepEqual(ownerCoordinatorState(base), { kind: 'loading' }, 'not read yet is never none');
  assert.deepEqual(ownerCoordinatorState({ ...base, coordinatorReadFailed: true }), { kind: 'failed' });
  assert.deepEqual(ownerCoordinatorState({ ...base, online: false }), { kind: 'offline' });
  assert.deepEqual(ownerCoordinatorState({ ...base, online: false, coordinatorAgentInstanceId: 'inst_1' }), { kind: 'bound', instanceId: 'inst_1' }, 'a listed coordinator survives an offline owner');
  assert.deepEqual(ownerCoordinatorState({ ...base, pending: true }), { kind: 'none' });
});

test('the registry row names the coordinator only when it carries valid members', async () => {
  const env = await ownerTestSession();
  try {
    const parse = async (o: Parameters<typeof registryRow>[1]) => JSON.parse((await registryRow(env.session, o)).registry_json);
    assert.equal(registryCoordinator(await parse({ chainId: 'c1', bridgeId: 'brg_home', online: true, coordinator: 'inst_1' })), 'inst_1');
    assert.equal(registryCoordinator(await parse({ chainId: 'c1', bridgeId: 'brg_home', online: true, coordinator: '' })), '', 'members published, none bound');
    assert.equal(registryCoordinator(await parse({ chainId: 'c1', bridgeId: 'brg_home', online: true })), undefined, 'an older row needs an owner read');
    const forged = await parse({ chainId: 'c1', bridgeId: 'brg_home', online: true, coordinator: 'inst_1' });
    forged.coordinator_instance_id = 'inst_other';
    assert.equal(registryCoordinator(forged), undefined, 'a coordinator that is not an enabled member is ignored');
  } finally {
    clearKeyringSession();
  }
});

const metadata = (instanceId: string) => ({
  items: [{ kind: 'member', accepted_seq: '2', entity_id: instanceId, enabled: '1', current: '1', body: JSON.stringify({ instance_id: instanceId, agent_id: 'agt', role: 'coordinator' }) }],
  next_cursor: '',
});

/**
 * chain_cached and chain_none list their members; chain_old predates them
 * (bound to inst_old on the owner); chain_off predates them and is offline.
 * Status reads wait until released.
 */
async function setup(failOld = false) {
  const env = await ownerTestSession('brg_home', 'Home Bridge');
  const calls: OwnerCall[] = [];
  let release!: () => void;
  const released = new Promise<void>((r) => { release = r; });
  const relay = fakeOwner(env.session, async (call) => {
    if (call.method === 'work.read') { await released; return { chain_id: call.command.chain_id, status: 'active', items: [], next_cursor: '' }; }
    if (call.method === 'chain.metadata.read') return failOld ? { code: 'storage_error' } : metadata('inst_old');
    return { code: 'malformed' };
  }, calls);
  const page = async () => ({
    items: [
      await registryRow(env.session, { chainId: 'chain_cached', bridgeId: 'brg_home', online: true, chainTitle: 'Cached', coordinator: 'inst_cached' }),
      await registryRow(env.session, { chainId: 'chain_none', bridgeId: 'brg_home', online: true, chainTitle: 'None', coordinator: '' }),
      await registryRow(env.session, { chainId: 'chain_old', bridgeId: 'brg_home', online: true, chainTitle: 'Old' }),
      await registryRow(env.session, { chainId: 'chain_off', bridgeId: 'brg_home', online: false, chainTitle: 'Off' }),
    ],
    next_cursor: { after_chain: '', after_task: '' }, terminal: true,
  });
  resetOwnerChainsForTest(page as any, relay as any);
  const snapshots: Record<string, string | undefined>[] = [];
  const unsubscribe = subscribeOwnerChains(() => {
    const s = ownerChainsSnapshot();
    if (s.status === 'ready') snapshots.push(Object.fromEntries(s.chains.map((c) => [c.chainId, c.coordinatorAgentInstanceId])));
  });
  const cleanup = () => { unsubscribe(); resetOwnerChainsForTest(); clearKeyringSession(); };
  return { calls, release, snapshots, cleanup };
}

const until = async (done: () => boolean, label: string) => {
  for (let i = 0; i < 500 && !done(); i += 1) await new Promise((r) => setTimeout(r, 2));
  assert.ok(done(), 'timed out: ' + label);
};

test('the listing names cached coordinators at once; older rows are read concurrently with the status reads', async () => {
  const ui = await setup();
  try {
    const refreshed = refreshOwnerChains();
    await until(() => ui.snapshots.length > 0, 'first listing');
    assert.deepEqual(ui.snapshots[0], { chain_cached: 'inst_cached', chain_none: '', chain_old: undefined, chain_off: undefined },
      'the first render knows the published coordinators and nothing is "none" while unknown');
    assert.deepEqual(['chain_cached', 'chain_none', 'chain_old', 'chain_off'].map((id) => ownerCoordinatorState(ownerChainById(id)).kind),
      ['bound', 'none', 'loading', 'offline']);
    // The status reads are still blocked: the coordinator read does not wait for them.
    await until(() => ownerChainById('chain_old')?.coordinatorAgentInstanceId === 'inst_old', 'concurrent coordinator read');
    assert.equal(ownerChainById('chain_old')?.status, undefined, 'statuses not read yet');
    ui.release();
    await refreshed;
    assert.equal(ownerChainById('chain_old')?.status, 'active');
    const metadataReads = ui.calls.filter((c) => c.method === 'chain.metadata.read').map((c) => c.command.chain_id);
    assert.deepEqual(metadataReads, ['chain_old'], 'only the row without members is read from its owner');
    assert.ok(ui.snapshots.every((s) => s.chain_old !== ''), 'never shown as none before the read');
  } finally {
    ui.cleanup();
  }
});

test('a failed coordinator read ends in a definite failed state', async () => {
  const ui = await setup(true);
  try {
    ui.release();
    await refreshOwnerChains();
    const chain = ownerChainById('chain_old');
    assert.equal(chain?.coordinatorAgentInstanceId, undefined, 'still unknown, so a later on-demand read retries');
    assert.equal(chain?.coordinatorReadFailed, true);
    assert.equal(ownerCoordinatorState(chain).kind, 'failed');
  } finally {
    ui.cleanup();
  }
});

async function mount(element: React.ReactElement) {
  const container = win.document.createElement('div');
  win.document.body.appendChild(container);
  const root = createRoot(container);
  await act(async () => { root.render(element); });
  const settle = async () => { for (let i = 0; i < 20; i += 1) await act(async () => { await new Promise((r) => setTimeout(r, 5)); }); };
  const $ = (id: string) => container.querySelector(`[data-debug-id="${id}"]`) as HTMLElement | null;
  const unmount = async () => { await act(async () => root.unmount()); container.remove(); };
  return { $, settle, unmount, rerender: async (next: React.ReactElement) => act(async () => { root.render(next); }) };
}

test('the chain view control shows a lookup, never "No coordinator" or Start, until the coordinator is known', async () => {
  const props = { chainId: 'c', ownerBridgeId: 'brg', bind: async () => {}, onBound: () => {} };
  const ui = await mount(React.createElement(OwnerCoordinatorControl, { ...props, coordinatorId: undefined }));
  try {
    assert.equal(ui.$('owner-chain-coordinator-loading')?.textContent, 'Looking up coordinator…');
    assert.equal(ui.$('owner-chain-start-coordinator'), null, 'no Start coordinator while unknown');
    assert.doesNotMatch(ui.$('owner-chain-coordinator')!.textContent!, /No coordinator/);
    await ui.rerender(React.createElement(OwnerCoordinatorControl, { ...props, coordinatorId: '' }));
    assert.equal(ui.$('owner-chain-coordinator-none')?.textContent, 'No coordinator');
    assert.equal(ui.$('owner-chain-start-coordinator')?.textContent, 'Start coordinator');
    await ui.rerender(React.createElement(OwnerCoordinatorControl, { ...props, coordinatorId: 'inst_1' }));
    assert.equal(ui.$('owner-chain-coordinator-id')?.textContent, 'Coordinator: inst_1');
    assert.equal(ui.$('owner-chain-start-coordinator')?.textContent, 'Replace coordinator');
    await ui.rerender(React.createElement(OwnerCoordinatorControl, { ...props, coordinatorId: undefined, lookupFailed: true }));
    assert.ok(ui.$('owner-chain-coordinator-unknown'), 'a failed lookup is a definite state');
    assert.equal(ui.$('owner-chain-start-coordinator')?.textContent, 'Start coordinator');
  } finally {
    await ui.unmount();
  }
});

const pane = (chainId: string) => React.createElement(ChainCoordinatorPane, {
  chainId,
  children: (coordinatorId: string) => React.createElement('div', { 'data-debug-id': 'coordinator-chat' }, coordinatorId),
});

test('the chain pane: cached coordinator at once, lookup for older rows, offline and failed states', async () => {
  const ui = await setup();
  try {
    const refreshed = refreshOwnerChains();
    await until(() => ui.snapshots.length > 0, 'first listing');
    const cached = await mount(pane('chain_cached'));
    assert.equal(cached.$('coordinator-chat')?.textContent, 'inst_cached', 'no owner read before the chat opens');
    await cached.unmount();
    const none = await mount(pane('chain_none'));
    assert.equal(none.$('chain-pane-no-coordinator')?.dataset.coordinatorState, 'none');
    assert.match(none.$('chain-pane-no-coordinator')!.textContent!, /no coordinator yet/);
    await none.unmount();
    const off = await mount(pane('chain_off'));
    assert.equal(off.$('chain-pane-no-coordinator')?.dataset.coordinatorState, 'offline');
    assert.match(off.$('chain-pane-no-coordinator')!.textContent!, /owner Bridge Home Bridge is offline/);
    await off.unmount();
    ui.release();
    await refreshed;
    const old = await mount(pane('chain_old'));
    await old.settle();
    assert.equal(old.$('coordinator-chat')?.textContent, 'inst_old');
    await old.unmount();
  } finally {
    ui.cleanup();
  }
  const failing = await setup(true);
  try {
    failing.release();
    await refreshOwnerChains();
    const view = await mount(pane('chain_old'));
    assert.equal(view.$('chain-pane-no-coordinator')?.dataset.coordinatorState, 'loading', 'the pane retries a failed read once');
    await view.settle();
    assert.equal(view.$('chain-pane-no-coordinator')?.dataset.coordinatorState, 'failed');
    assert.match(view.$('chain-pane-no-coordinator')!.textContent!, /could not be looked up/);
    await view.unmount();
  } finally {
    failing.cleanup();
  }
});
