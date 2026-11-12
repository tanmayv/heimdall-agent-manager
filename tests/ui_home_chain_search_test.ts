import './helpers/vaultEndpointHarness.ts';
import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import React from 'react';

import {
  filterHomeChains,
  homeChainsFromOwners,
  homeChainsFromSearchHits,
  orderChainsByActivity,
  type HomeChainItem,
} from '../src/ui/components/home/homeChainSearchLogic.ts';

const REPO_ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');

function chain(id: string, extra: Partial<HomeChainItem> = {}): HomeChainItem {
  return { chainId: id, title: `Title ${id}`, status: 'active', updatedAt: '', projectId: '', projectName: '', ...extra };
}

test('home chain local search is vault-safe and matches decrypted titles, ids and project names', () => {
  const items = [
    chain('c1', { title: 'vault:v2:7e57000000000001:e1:abcdef', projectId: 'p1', projectName: 'Apollo' }),
    chain('c2', { title: 'Release train', projectId: 'p1', projectName: 'Apollo' }),
  ];
  assert.deepEqual(filterHomeChains(items, 'vault').map((c) => c.chainId), []);
  assert.deepEqual(filterHomeChains(items, 'secret', { c1: { decryptedTitle: 'Secret plan' } }).map((c) => c.chainId), ['c1']);
  assert.deepEqual(filterHomeChains(items, 'release').map((c) => c.chainId), ['c2']);
  assert.deepEqual(filterHomeChains(items, 'apollo').map((c) => c.chainId), ['c1', 'c2']);
  assert.deepEqual(filterHomeChains(items, 'c2').map((c) => c.chainId), ['c2']);
});

test('owner registry chains become Bridge-owned home rows', () => {
  const rows = homeChainsFromOwners([{
    chainId: 'own', ownerBridgeId: 'brg', bridgeName: 'Home', online: true, title: 'Owned', description: '', sealed: false,
    tasks: [], projectId: '', projectName: '', migrated: false, status: 'completed',
  }]);
  assert.deepEqual(rows, [{
    chainId: 'own', title: 'Owned', status: 'completed', updatedAt: '', projectId: '', projectName: '',
    owner: { bridgeId: 'brg', bridgeName: 'Home', online: true },
  }]);
});

test('bridge search hits get the owner and project name from the loaded list', () => {
  const loaded = [chain('a', { projectId: 'p1', projectName: 'One', owner: { bridgeId: 'brg', bridgeName: 'Home', online: true } })];
  const rows = homeChainsFromSearchHits(
    [
      { chain_id: 'a', project_id: 'p1', status: 'active', updated_at: '2026-01-05', title: 'Alpha', description: '' },
      { chain_id: 'zz', project_id: 'p1', status: 'completed', updated_at: '', title: 'Unknown', description: '' },
    ],
    loaded,
  );
  assert.equal(rows[0].owner?.bridgeName, 'Home');
  assert.equal(rows[0].title, 'Alpha');
  assert.equal(rows[1].owner, undefined);
  assert.equal(rows[1].projectName, 'One');
});

type Fixture = {
  projects?: any[];
  requests?: string[];
  fetch?: (url: string, init: any) => any;
};

function jsonResponse(body: any, status = 200): any {
  return { ok: status < 400, status, headers: { get: () => 'application/json' }, text: async () => JSON.stringify(body), json: async () => body };
}

async function withDom<T>(hash: string, fn: (dom: any) => Promise<T>, fixture: Fixture = {}): Promise<T> {
  const { JSDOM } = await import('jsdom');
  const dom = new JSDOM('<!DOCTYPE html><html><body><div id="root"></div></body></html>', { url: `http://localhost/${hash}` });
  (dom.window.HTMLElement.prototype as any).scrollTo = () => {};
  (dom.window.HTMLElement.prototype as any).scrollIntoView = () => {};
  (dom.window as any).matchMedia = () => ({ matches: false, addEventListener() {}, removeEventListener() {}, addListener() {}, removeListener() {} });
  const prev = {
    window: (globalThis as any).window,
    document: (globalThis as any).document,
    HTMLElement: (globalThis as any).HTMLElement,
    navigator: (globalThis as any).navigator,
    fetch: (globalThis as any).fetch,
    localStorage: (globalThis as any).localStorage,
  };
  (globalThis as any).window = dom.window;
  (globalThis as any).document = dom.window.document;
  (globalThis as any).HTMLElement = dom.window.HTMLElement;
  (globalThis as any).localStorage = dom.window.localStorage;
  Object.defineProperty(globalThis, 'navigator', { value: dom.window.navigator, configurable: true });
  (globalThis as any).IS_REACT_ACT_ENVIRONMENT = true;
  const prevRO = (globalThis as any).ResizeObserver;
  class RO { observe() {} unobserve() {} disconnect() {} }
  (globalThis as any).ResizeObserver = RO;
  (dom.window as any).ResizeObserver = RO;
  const prevRaf = [(globalThis as any).requestAnimationFrame, (globalThis as any).cancelAnimationFrame];
  (globalThis as any).requestAnimationFrame = (cb: any) => setTimeout(() => cb(Date.now()), 0) as any;
  (globalThis as any).cancelAnimationFrame = (id: any) => clearTimeout(id);
  (globalThis as any).fetch = async (input: any, init: any) => {
    const url = String(input?.url ?? input);
    fixture.requests?.push(url);
    const custom = await fixture.fetch?.(url, init);
    if (custom !== undefined) return custom;
    const body = /\/projects(\?|$)/.test(url) ? { data: fixture.projects || [] } : { data: [] };
    return jsonResponse(body);
  };
  try {
    return await fn(dom);
  } finally {
    dom.window.close();
    (globalThis as any).window = prev.window;
    (globalThis as any).document = prev.document;
    (globalThis as any).HTMLElement = prev.HTMLElement;
    (globalThis as any).localStorage = prev.localStorage;
    Object.defineProperty(globalThis, 'navigator', { value: prev.navigator, configurable: true });
    (globalThis as any).fetch = prev.fetch;
    (globalThis as any).ResizeObserver = prevRO;
    (globalThis as any).requestAnimationFrame = prevRaf[0];
    (globalThis as any).cancelAnimationFrame = prevRaf[1];
  }
}

async function makeStore() {
  const { configureStore } = await import('@reduxjs/toolkit');
  const { heimdallApi } = await import('../src/ui/api/heimdallApi.ts');
  const { default: vault } = await import('../src/ui/store/vaultSlice.ts');
  const { default: workspaceLayout } = await import('../src/ui/store/workspaceLayoutSlice.ts');
  const { default: auxPanes } = await import('../src/ui/store/auxPanesSlice.ts');
  const { default: workspaceChrome } = await import('../src/ui/store/workspaceChromeSlice.ts');
  const { default: searchTitle } = await import('../src/ui/store/searchTitleSlice.ts');
  const { vaultCacheInvalidationMiddleware } = await import('../src/ui/api/vaultCacheInvalidation.ts');
  return configureStore({
    reducer: {
      vault,
      workspaceLayout,
      auxPanes,
      workspaceChrome,
      searchTitle,
      chat: (s: any = { session: { daemonUrl: 'http://127.0.0.1:7777', clientToken: 'tok_test' } }) => s,
      [heimdallApi.reducerPath]: heimdallApi.reducer,
    },
    middleware: (g: any) => g({ serializableCheck: false, immutableCheck: false }).concat(vaultCacheInvalidationMiddleware, heimdallApi.middleware),
  });
}

async function waitFor(predicate: () => boolean, act: any, ms = 3000) {
  const start = Date.now();
  while (!predicate()) {
    if (Date.now() - start > ms) throw new Error('waitFor timed out');
    await act(async () => {
      await new Promise((r) => setTimeout(r, 25));
    });
  }
}

test('new Main pane and Home route keep the launcher but mount no task-chain list or activity cards', async () => {
  for (const pane of [false, true]) {
    await withDom('#/home', async dom => {
      const { createRoot } = await import('react-dom/client');
      const { act } = await import('react');
      const { Provider } = await import('react-redux');
      const { HomePage } = await import('../src/ui/components/home/HomePage.tsx');
      const { heimdallApi } = await import('../src/ui/api/heimdallApi.ts');
      const store = await makeStore();
      const root = createRoot(dom.window.document.getElementById('root')!);
      try {
        await act(async () => root.render(React.createElement(Provider, { store },
          React.createElement(HomePage, pane ? { pane: { onOpenAgent: () => {} } } : {}))));
        assert.ok(dom.window.document.querySelector('[data-debug-id="new-conversation-page"]'));
        assert.ok(!dom.window.document.querySelector('[data-debug-id="home-chain-search"]'));
        assert.ok(dom.window.document.querySelector(`[data-debug-id="${pane ? 'home-page-pane' : 'home-page'}"]`));
        // The Recent issues / Pending actions cards and their panel were removed from Home.
        assert.ok(!dom.window.document.querySelector('[data-debug-id="home-section-buttons"]'));
        assert.ok(!dom.window.document.querySelector('[data-debug-id^="home-tab-"]'));
        assert.ok(!dom.window.document.querySelector('[data-debug-id^="home-panel-"]'));
        assert.ok(!dom.window.document.getElementById('home-activity-panel'));
      } finally {
        await act(async () => { root.unmount(); store.dispatch(heimdallApi.util.resetApiState()); });
      }
    });
  }
});

test('launching from a pane fills that pane instead of navigating', () => {
  const page = fs.readFileSync(path.join(REPO_ROOT, 'src/ui/components/chat/NewConversationPage.tsx'), 'utf8');
  assert.match(page, /if \(onLaunched\) onLaunched\(id\);\s*else \{[^}]*window\.location\.hash/);
  // A coordinator conversation's pane target is its chain (the sidebar's URL).
  assert.match(page, /openLaunched\(chainId \? chainTargetId\(chainId\) : id\)/);
  const home = fs.readFileSync(path.join(REPO_ROOT, 'src/ui/components/home/HomePage.tsx'), 'utf8');
  assert.match(home, /<NewConversationPage embedded launchIntent=\{pane\.launchIntent\} onLaunched=\{pane\.onOpenAgent\}/);
  const ws = fs.readFileSync(path.join(REPO_ROOT, 'src/ui/components/mainWorkspace/Workspace.tsx'), 'utf8');
  assert.match(ws, /onOpenAgent: \(agentInstanceId\) =>\s*dispatch\(assignMainPaneAgent\(\{ paneId, agentInstanceId \}\)\)/);
});

test('sidebar chains are ordered by their coordinator conversation activity, most recent first', () => {
  // Registry order (title order) before any activity is known.
  const items = [
    chain('a', { title: 'Alpha', coordinatorAgentInstanceId: 'inst_a' }),
    chain('b', { title: 'Beta', coordinatorAgentInstanceId: 'inst_b' }),
    chain('c', { title: 'Gamma' }), // no coordinator yet
    chain('d', { title: 'Delta', coordinatorAgentInstanceId: 'inst_d' }),
  ];
  assert.deepEqual(orderChainsByActivity(items, []).map((c) => c.chainId), ['a', 'b', 'c', 'd'], 'no activity keeps the given order');
  const conversations = [
    { agentInstanceId: 'inst_a', lastMessageUnixMs: 1000 },
    { agentInstanceId: 'inst_b', lastMessageUnixMs: 3000 },
    { agentInstanceId: 'inst_d', lastMessageUnixMs: 0, lastMessageAt: '1970-01-01T00:00:02.000Z' },
  ];
  assert.deepEqual(orderChainsByActivity(items, conversations).map((c) => c.chainId), ['b', 'd', 'a', 'c']);
  // New activity on a chain (a new coordinator message) moves it to the top.
  conversations[0] = { agentInstanceId: 'inst_a', lastMessageUnixMs: 5000 };
  assert.deepEqual(orderChainsByActivity(items, conversations).map((c) => c.chainId), ['a', 'b', 'd', 'c']);
  // Several conversations of one instance: the latest counts; input is not mutated.
  const before = items.map((c) => c.chainId);
  assert.deepEqual(orderChainsByActivity(items, [...conversations, { agentInstanceId: 'inst_d', lastMessageUnixMs: 9000 }]).map((c) => c.chainId), ['d', 'a', 'b', 'c']);
  assert.deepEqual(items.map((c) => c.chainId), before);
});
