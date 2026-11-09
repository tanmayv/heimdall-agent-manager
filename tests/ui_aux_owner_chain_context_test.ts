// Chain panes for a coordinator conversation: the aux context's chain comes
// from the conversation/instance chain_id (chain-bound launches), and falls
// back to the owner chain whose bound coordinator is the instance (a
// coordinator launched without chain_id). The launcher's Chain overview and
// Tickets cards are enabled only with a chain.
//
// RUN: node --import ./tests/helpers/vaultEndpointHarness.ts --test tests/ui_aux_owner_chain_context_test.ts

import { test } from 'node:test';
import assert from 'node:assert/strict';
import React from 'react';
import { JSDOM } from 'jsdom';
import { makeVaultStore } from './helpers/vaultEndpointHarness.ts';
import { fakeOwner, ownerTestSession, registryRow } from './helpers/ownerFakeRelay.ts';
import { clearKeyringSession } from '../src/ui/utils/vaultKeyringSession.ts';
import type { OwnerChainSummary } from '../src/ui/api/ownerChains.ts';

// React DOM fixes its event support when first loaded: build the DOM first.
const dom = new JSDOM('<!DOCTYPE html><html><body></body></html>', { url: 'http://localhost/', pretendToBeVisual: true });
const win = dom.window as any;
win.matchMedia = (q: string) => ({ matches: false, media: q, addEventListener() {}, removeEventListener() {}, addListener() {}, removeListener() {} });
const raf = (cb: any) => setTimeout(cb, 0), caf = (id: any) => clearTimeout(id);
win.requestAnimationFrame = raf; win.cancelAnimationFrame = caf;
for (const [key, value] of Object.entries({ window: win, document: win.document, navigator: win.navigator, HTMLElement: win.HTMLElement, Node: win.Node,
  requestAnimationFrame: raf, cancelAnimationFrame: caf, IS_REACT_ACT_ENVIRONMENT: true })) {
  Object.defineProperty(globalThis, key, { value, writable: true, configurable: true });
}
const { createRoot } = await import('react-dom/client');
const { act } = await import('react');
const { Provider } = await import('react-redux');
const { useAgentAuxContext, ownerChainIdForCoordinator } = await import('../src/ui/components/auxiliary/useAgentAuxContext.ts');
const { AuxNewTabLauncher } = await import('../src/ui/components/auxiliary/AuxNewTabLauncher.tsx');
const { resetOwnerChainsForTest } = await import('../src/ui/api/ownerChainsStore.ts');
const { heimdallApi } = await import('../src/ui/api/heimdallApi.ts');

const summary = (chainId: string, coordinatorAgentInstanceId?: string): OwnerChainSummary => ({
  chainId, ownerBridgeId: 'brg_home', bridgeName: 'Home', online: true, title: chainId, description: '', sealed: false, tasks: [],
  projectId: '', projectName: '', migrated: false, coordinatorAgentInstanceId,
});

test('the owner chain of a bound coordinator instance', () => {
  const chains = [summary('chain_a', 'inst_a'), summary('chain_b'), summary('chain_c', 'inst_c')];
  assert.equal(ownerChainIdForCoordinator(chains, 'inst_c'), 'chain_c');
  assert.equal(ownerChainIdForCoordinator(chains, 'inst_worker'), '', 'not a bound coordinator');
  assert.equal(ownerChainIdForCoordinator(chains, ''), '', 'no instance');
  assert.equal(ownerChainIdForCoordinator([summary('chain_x')], ''), '', 'an unbound chain never matches an empty id');
});

async function renderLauncher(instances: Record<string, Record<string, unknown>>, agentInstanceId: string) {
  const env = await ownerTestSession('brg_home', 'Home Bridge');
  // chain_owned is bound to inst_coord (its member row); the registry lists it online.
  const relay = fakeOwner(env.session, (call) => {
    if (call.method === 'chain.metadata.read') {
      return {
        items: [{ kind: 'member', accepted_seq: '2', entity_id: 'inst_coord', enabled: '1', current: '1', body: JSON.stringify({ instance_id: 'inst_coord', agent_id: 'agt_coord', role: 'coordinator' }) }],
        next_cursor: '',
      };
    }
    return { chain_id: call.command.chain_id, task_id: '', revision: '1', status: 'active' };
  });
  const page = async () => ({
    items: [await registryRow(env.session, { chainId: 'chain_owned', bridgeId: 'brg_home', online: true })],
    next_cursor: { after_chain: '', after_task: '' }, terminal: true,
  });
  resetOwnerChainsForTest(page as any, relay as any);
  const saved = globalThis.fetch;
  globalThis.fetch = (async (input: any) => {
    const u = new URL(String(input?.url ?? input), 'http://localhost');
    const instance = /\/agent-instances\/([^/]+)$/.exec(u.pathname)?.[1];
    const data = instance ? (instances[decodeURIComponent(instance)] ?? {}) : {};
    return new Response(JSON.stringify({ data }), { status: 200, headers: { 'Content-Type': 'application/json' } });
  }) as typeof fetch;
  const store = await makeVaultStore();
  const contexts: string[] = [];
  function Probe() {
    const ctx = useAgentAuxContext(agentInstanceId);
    contexts.push(ctx.chainId);
    return React.createElement(AuxNewTabLauncher, { treeKey: 't', ownerAgentId: agentInstanceId, chainId: ctx.chainId, onSelect: () => {} });
  }
  const container = win.document.createElement('div');
  win.document.body.appendChild(container);
  const root = createRoot(container);
  await act(async () => { root.render(React.createElement(Provider, { store }, React.createElement(Probe))); });
  const settle = async () => { for (let i = 0; i < 20; i += 1) await act(async () => { await new Promise((r) => setTimeout(r, 10)); }); };
  await settle();
  const card = (kind: string) => container.querySelector(`[data-debug-id="aux-launcher-card-${kind}"]`) as HTMLButtonElement | null;
  const cleanup = async () => {
    await act(async () => root.unmount());
    // Drops the cached queries and their expiry timers (the process can then exit).
    store.dispatch(heimdallApi.util.resetApiState());
    container.remove();
    globalThis.fetch = saved;
    resetOwnerChainsForTest();
    clearKeyringSession();
  };
  return { card, contexts, cleanup };
}

test('a bound coordinator without chain_id gets Chain overview and Tickets from its owner chain', async () => {
  const ui = await renderLauncher({ inst_coord: { agent_instance_id: 'inst_coord', agent_id: 'agt_coord' } }, 'inst_coord');
  try {
    assert.equal(ui.contexts.at(-1), 'chain_owned', 'the chain is the owner chain the instance coordinates');
    assert.equal(ui.card('chainOverview')!.disabled, false);
    assert.equal(ui.card('tasks')!.disabled, false);
  } finally {
    await ui.cleanup();
  }
});

test('a chain-bound launch carries its chain_id; an unbound instance has no chain panes', async () => {
  const bound = await renderLauncher({ inst_bound: { agent_instance_id: 'inst_bound', chain_id: 'chain_launch' } }, 'inst_bound');
  try {
    assert.equal(bound.contexts.at(-1), 'chain_launch', 'instance.chain_id wins');
    assert.equal(bound.card('chainOverview')!.disabled, false);
  } finally {
    await bound.cleanup();
  }
  const solo = await renderLauncher({ inst_solo: { agent_instance_id: 'inst_solo' } }, 'inst_solo');
  try {
    assert.equal(solo.contexts.at(-1), '');
    assert.equal(solo.card('chainOverview')!.disabled, true);
    assert.equal(solo.card('tasks')!.disabled, true);
  } finally {
    await solo.cleanup();
  }
});
