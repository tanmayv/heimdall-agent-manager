// Sidebar task chains open the chain's coordinator conversation
// (`/conversations/chain:<id>`, REQ-TV2-7) when the owner chain has a bound
// coordinator (owner member rows), else the chain view. The chain pane renders
// the bound coordinator's chat, reading member rows on demand when the shared
// snapshot has not read them yet.
//
// RUN: node --import ./tests/helpers/vaultEndpointHarness.ts --test tests/ui_sidebar_chain_coordinator_test.ts

import { test } from 'node:test';
import assert from 'node:assert/strict';
import React from 'react';
import { JSDOM } from 'jsdom';
import { makeVaultStore } from './helpers/vaultEndpointHarness.ts';
import { fakeOwner, ownerTestSession, registryRow, type OwnerCall } from './helpers/ownerFakeRelay.ts';
import { clearKeyringSession } from '../src/ui/utils/vaultKeyringSession.ts';

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
const { SidebarTaskChains } = await import('../src/ui/components/shell/SidebarTaskChains.tsx');
const { ChainCoordinatorPane } = await import('../src/ui/components/mainWorkspace/ChainCoordinatorPane.tsx');
const { ownerChainById, resetOwnerChainsForTest } = await import('../src/ui/api/ownerChainsStore.ts');
const { heimdallApi } = await import('../src/ui/api/heimdallApi.ts');

const coordinatorRows = {
  items: [{ kind: 'member', accepted_seq: '2', entity_id: 'inst_coord', enabled: '1', current: '1', body: JSON.stringify({ instance_id: 'inst_coord', agent_id: 'agt_coord', role: 'coordinator' }) }],
  next_cursor: '',
};

/** chain_bound has a bound coordinator, chain_free has none. `failFirstRead` fails each chain's first member-row read. */
async function render(element: (store: unknown) => React.ReactElement, failFirstRead = false) {
  const env = await ownerTestSession('brg_home', 'Home Bridge');
  const calls: OwnerCall[] = [];
  const reads = new Map<string, number>();
  const relay = fakeOwner(env.session, (call) => {
    if (call.method === 'chain.metadata.read') {
      const chainId = call.command.chain_id;
      reads.set(chainId, (reads.get(chainId) ?? 0) + 1);
      if (failFirstRead && reads.get(chainId) === 1) return 'offline';
      return chainId === 'chain_bound' ? coordinatorRows : { items: [], next_cursor: '' };
    }
    return { chain_id: call.command.chain_id, task_id: '', revision: '1', status: 'active' };
  }, calls);
  const page = async () => ({
    items: [
      await registryRow(env.session, { chainId: 'chain_bound', bridgeId: 'brg_home', online: true, chainTitle: 'Bound' }),
      await registryRow(env.session, { chainId: 'chain_free', bridgeId: 'brg_home', online: true, chainTitle: 'Free' }),
    ],
    next_cursor: { after_chain: '', after_task: '' }, terminal: true,
  });
  resetOwnerChainsForTest(page as any, relay as any);
  const store = await makeVaultStore();
  const container = win.document.createElement('div');
  win.document.body.appendChild(container);
  const root = createRoot(container);
  await act(async () => { root.render(React.createElement(Provider, { store } as any, element(store))); });
  const settle = async () => { for (let i = 0; i < 20; i += 1) await act(async () => { await new Promise((r) => setTimeout(r, 10)); }); };
  await settle();
  const $ = (id: string) => container.querySelector(`[data-debug-id="${id}"]`) as HTMLElement | null;
  const cleanup = async () => {
    await act(async () => root.unmount());
    (store as any).dispatch(heimdallApi.util.resetApiState());
    container.remove();
    resetOwnerChainsForTest();
    clearKeyringSession();
    win.location.hash = '';
  };
  return { $, container, settle, reads, cleanup };
}

const click = async (el: HTMLElement) => {
  await act(async () => { el.dispatchEvent(new win.MouseEvent('click', { bubbles: true, cancelable: true, button: 0 })); });
};

test('a sidebar chain links to its coordinator conversation and opens it when a coordinator is bound', async () => {
  const ui = await render(() => React.createElement(SidebarTaskChains, { currentPath: '/conversations/chain:chain_bound' }));
  try {
    const bound = ui.$('sidebar-chain-row-chain_bound') as HTMLAnchorElement;
    const free = ui.$('sidebar-chain-row-chain_free') as HTMLAnchorElement;
    assert.ok(bound && free, 'both owner chains are listed');
    assert.equal(bound.getAttribute('href'), '#/conversations/chain:chain_bound');
    assert.equal(free.getAttribute('href'), '#/conversations/chain:chain_free');
    assert.equal(bound.getAttribute('title'), 'Open coordinator conversation');
    assert.equal(bound.getAttribute('aria-current'), 'page', 'the chain conversation route is the active row');
    assert.equal(free.getAttribute('aria-current'), null);

    await click(bound);
    await ui.settle();
    assert.equal(win.location.hash, '#/conversations/chain:chain_bound', 'a bound coordinator opens its conversation');

    await click(free);
    await ui.settle();
    assert.equal(win.location.hash, '#/chains/chain_free', 'without a coordinator the chain view opens');
  } finally {
    await ui.cleanup();
  }
});

test('a sidebar click reads an unread coordinator on demand before choosing the route', async () => {
  const ui = await render(() => React.createElement(SidebarTaskChains, { currentPath: '/' }), true);
  try {
    assert.equal(ownerChainById('chain_bound')?.coordinatorAgentInstanceId, undefined, 'the snapshot read failed: unknown');
    await click(ui.$('sidebar-chain-row-chain_bound')!);
    await ui.settle();
    assert.equal(win.location.hash, '#/conversations/chain:chain_bound');
    assert.equal(ownerChainById('chain_bound')?.coordinatorAgentInstanceId, 'inst_coord', 'the read is recorded in the snapshot');
  } finally {
    await ui.cleanup();
  }
});

const pane = (chainId: string) => () => React.createElement(ChainCoordinatorPane, {
  chainId,
  children: (coordinatorId: string, title: string) => React.createElement('div', { 'data-debug-id': 'coordinator-chat' }, `${coordinatorId}|${title}`),
});

test('the chain conversation route renders the owner chain’s bound coordinator', async () => {
  const bound = await render(pane('chain_bound'));
  try {
    assert.equal(bound.$('coordinator-chat')?.textContent, 'inst_coord|Bound');
  } finally {
    await bound.cleanup();
  }
  const free = await render(pane('chain_free'));
  try {
    assert.equal(free.$('coordinator-chat'), null);
    assert.match(free.$('chain-pane-no-coordinator')!.textContent!, /no coordinator yet/);
  } finally {
    await free.cleanup();
  }
});

test('the chain pane reads member rows on demand when the snapshot has not', async () => {
  const ui = await render(pane('chain_bound'), true);
  try {
    assert.equal(ui.$('coordinator-chat')?.textContent, 'inst_coord|Bound');
    assert.equal(ui.reads.get('chain_bound'), 2, 'one failed snapshot read, one on-demand read');
  } finally {
    await ui.cleanup();
  }
});
