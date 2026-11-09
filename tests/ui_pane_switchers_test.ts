import './helpers/vaultEndpointHarness.ts';
import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import React from 'react';
import { blurInactiveMainPaneFocus } from '../src/ui/components/mainWorkspace/paneFocus.ts';

const REPO_ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');

// Agents: a/a2 (chain-1), b (chain-2), coord-3 (coordinator of chain-3), chain-4 has no coordinator.
// chain-5 / chain-6 are coordinated by two instances of ONE durable agent (agt_shared),
// and chain-6's coordinator can be replaced (coord-6x -> coord-6y) via COORDINATORS.
const COORDINATORS: Record<string, string> = { 'chain-5': 'coord-5x', 'chain-6': 'coord-6x' };
const REPLACED: Record<string, string[]> = {};
const CONVERSATIONS: Record<string, any> = {
  'coord-5x': { conversation_id: 'conv-5x', agent_id: 'agt_shared', agent_instance_id: 'coord-5x', chain_id: 'chain-5', project_id: 'p1', title: 'Shared on Five' },
  'coord-6x': { conversation_id: 'conv-6x', agent_id: 'agt_shared', agent_instance_id: 'coord-6x', chain_id: 'chain-6', project_id: 'p1', title: 'Shared on Six' },
  'coord-6y': { conversation_id: 'conv-6y', agent_id: 'agt_shared', agent_instance_id: 'coord-6y', chain_id: 'chain-6', project_id: 'p1', title: 'Replacement on Six' },
  a: { conversation_id: 'conv-a', agent_instance_id: 'a', chain_id: 'chain-1', project_id: 'p1', title: 'Agent A' },
  a2: { conversation_id: 'conv-a2', agent_instance_id: 'a2', chain_id: 'chain-1', project_id: 'p1', title: 'Agent A2' },
  b: { conversation_id: 'conv-b', agent_instance_id: 'b', chain_id: 'chain-2', project_id: 'p1', title: 'Agent B' },
  'coord-3': { conversation_id: 'conv-c3', agent_instance_id: 'coord-3', chain_id: 'chain-3', project_id: 'p1', title: 'Coord 3' },
};
const CHAIN_MEMBERS: Record<string, any[]> = {
  'chain-1': [
    { chain_id: 'chain-1', agent_instance_id: 'a', display_name: 'Agent A', role: 'coordinator' },
    { chain_id: 'chain-1', agent_instance_id: 'a2', display_name: 'Agent A2', role: 'worker' },
  ],
  'chain-2': [
    { chain_id: 'chain-2', agent_instance_id: 'b', display_name: 'Agent B', role: 'coordinator' },
  ],
};
const GROUPS = [
  {
    project_id: 'p1',
    project_name: 'Proj',
    chains: [
      { chain_id: 'chain-2', title: 'Chain Two', status: 'active', coordinator_agent_instance_id: 'b', project_id: 'p1' },
      { chain_id: 'chain-3', title: 'Chain Three', status: 'active', coordinator_agent_instance_id: 'coord-3', project_id: 'p1' },
      { chain_id: 'chain-4', title: 'Chain Four', status: 'active', coordinator_agent_instance_id: '', project_id: 'p1' },
      { chain_id: 'chain-5', title: 'Chain Five', status: 'active', coordinator_agent_instance_id: 'coord-5x', project_id: 'p1' },
      { chain_id: 'chain-6', title: 'Chain Six', status: 'active', coordinator_agent_instance_id: 'coord-6x', project_id: 'p1' },
    ],
  },
];

function json(body: any, ok = true) {
  return {
    ok,
    status: ok ? 200 : 404,
    headers: { get: () => 'application/json' },
    text: async () => JSON.stringify(body),
    json: async () => body,
  } as any;
}

async function withDom<T>(hash: string, fn: (dom: any) => Promise<T>): Promise<T> {
  const { JSDOM } = await import('jsdom');
  const dom = new JSDOM('<!DOCTYPE html><html><body><div id="root"></div></body></html>', {
    url: `http://localhost/${hash}`,
  });
  (dom.window.HTMLElement.prototype as any).scrollTo = () => {};
  (dom.window.HTMLElement.prototype as any).scrollIntoView = () => {};
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
  class RO { observe() {} unobserve() {} disconnect() {} }
  const prevEnv = [(globalThis as any).ResizeObserver, (globalThis as any).requestAnimationFrame, (globalThis as any).cancelAnimationFrame];
  (globalThis as any).ResizeObserver = RO;
  (globalThis as any).requestAnimationFrame = (cb: any) => setTimeout(() => cb(Date.now()), 0) as any;
  (globalThis as any).cancelAnimationFrame = (id: any) => clearTimeout(id);
  (dom.window as any).requestAnimationFrame = (globalThis as any).requestAnimationFrame;
  (dom.window as any).cancelAnimationFrame = (globalThis as any).cancelAnimationFrame;
  (dom.window as any).matchMedia = () => ({ matches: false, addEventListener() {}, removeEventListener() {}, addListener() {}, removeListener() {} });
  (globalThis as any).fetch = async (input: any) => {
    const url = String(input?.url ?? input);
    const byInstance = url.match(/\/chats\/by-instance\/([^/?]+)/);
    if (byInstance) {
      const conv = CONVERSATIONS[decodeURIComponent(byInstance[1])];
      return conv ? json({ data: conv }) : json({ error: 'nope' }, false);
    }
    if (/\/agent-instances(\?|$)/.test(url)) return json({ data: [] });
    if (/\/agents(\?|$)/.test(url)) return json({ data: [] });
    if (/\/bridges(\?|$)/.test(url)) return json({ data: [] });
    if (/\/task-chains\/[^/?]+\/fleets(\?|$)/.test(url)) return json({ data: [] });
    const chainConversation = url.match(/\/task-chains\/([^/?]+)\/conversation(?:\?|$)/);
    if (chainConversation) {
      const chainId = decodeURIComponent(chainConversation[1]);
      const summary = GROUPS.flatMap((group) => group.chains).find((chain) => chain.chain_id === chainId);
      const coordinator = COORDINATORS[chainId] || summary?.coordinator_agent_instance_id || (chainId === 'chain-1' ? 'a' : '');
      return json({ data: {
        chain_id: chainId,
        title: summary?.title || (chainId === 'chain-1' ? 'Chain One' : chainId),
        coordinator_agent_instance_id: coordinator,
        conversation_id: CONVERSATIONS[coordinator]?.conversation_id || '',
        replaced_coordinator_instance_ids: REPLACED[chainId] || [],
      } });
    }
    const chainDetail = url.match(/\/task-chains\/([^/?]+)(?:\?|$)/);
    if (chainDetail) {
      const chainId = decodeURIComponent(chainDetail[1]);
      const summary = GROUPS.flatMap((group) => group.chains).find((chain) => chain.chain_id === chainId);
      return json({ data: {
        ...(summary || {}),
        chain_id: chainId,
        title: summary?.title || (chainId === 'chain-1' ? 'Chain One' : chainId),
        coordinator_agent_instance_id: summary?.coordinator_agent_instance_id || (chainId === 'chain-1' ? 'a' : ''),
        members: CHAIN_MEMBERS[chainId] || [],
        tasks: [],
      } });
    }
    if (/\/task-chains(\?|$)/.test(url)) return json({ groups: GROUPS });
    if (/\/templates(\?|$)/.test(url)) return json({ data: [] });
    return json({ data: {} });
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
    (globalThis as any).ResizeObserver = prevEnv[0];
    // A few UI dependencies schedule cleanup one tick after React unmounts.
    // Keep safe timer-backed fallbacks when Node did not provide RAF globals,
    // so that late cleanup cannot call an already-restored undefined function.
    (globalThis as any).requestAnimationFrame = prevEnv[1]
      ?? ((cb: any) => setTimeout(() => cb(Date.now()), 0) as any);
    (globalThis as any).cancelAnimationFrame = prevEnv[2]
      ?? ((id: any) => clearTimeout(id));
  }
}

test('Main pane focus changes blur only controls owned by the old pane', async () => {
  await withDom('#/conversations/a+b?focused=a', async (dom) => {
    const doc = dom.window.document;
    doc.body.insertAdjacentHTML('beforeend', `
      <section data-main-pane-id="pane-a"><textarea id="old-pane-input"></textarea></section>
      <section data-main-pane-id="pane-b"><input id="new-pane-input" /></section>
      <input id="outside-workspace" />
    `);
    const oldPaneInput = doc.getElementById('old-pane-input') as HTMLTextAreaElement;
    const newPaneInput = doc.getElementById('new-pane-input') as HTMLInputElement;
    const outsideWorkspace = doc.getElementById('outside-workspace') as HTMLInputElement;

    oldPaneInput.focus();
    assert.equal(doc.activeElement, oldPaneInput);
    assert.equal(blurInactiveMainPaneFocus('pane-b', doc), true);
    assert.notEqual(doc.activeElement, oldPaneInput);

    newPaneInput.focus();
    assert.equal(blurInactiveMainPaneFocus('pane-b', doc), false);
    assert.equal(doc.activeElement, newPaneInput);

    outsideWorkspace.focus();
    assert.equal(blurInactiveMainPaneFocus('pane-a', doc), false);
    assert.equal(doc.activeElement, outsideWorkspace);
  });

  const workspace = fs.readFileSync(
    path.join(REPO_ROOT, 'src/ui/components/mainWorkspace/Workspace.tsx'),
    'utf8',
  );
  assert.match(
    workspace,
    /useEffect\(\(\) => \{\s*blurInactiveMainPaneFocus\(tree\.focusedPaneId\);\s*\}, \[tree\.focusedPaneId\]\);/,
  );
});

async function makeStore() {
  const { configureStore } = await import('@reduxjs/toolkit');
  const { heimdallApi } = await import('../src/ui/api/heimdallApi.ts');
  const { default: vaultReducer } = await import('../src/ui/store/vaultSlice.ts');
  const { default: workspaceLayout } = await import('../src/ui/store/workspaceLayoutSlice.ts');
  const { default: auxPanes } = await import('../src/ui/store/auxPanesSlice.ts');
  const { default: workspaceChrome } = await import('../src/ui/store/workspaceChromeSlice.ts');
  const { default: searchTitle } = await import('../src/ui/store/searchTitleSlice.ts');
  return configureStore({
    reducer: {
      searchTitle,
      vault: vaultReducer,
      workspaceLayout,
      auxPanes,
      workspaceChrome,
      chat: (s: any = { session: { daemonUrl: 'http://127.0.0.1:7777', clientToken: 'tok_test' } }) => s,
      [heimdallApi.reducerPath]: heimdallApi.reducer,
    },
    middleware: (g: any) => g({ serializableCheck: false, immutableCheck: false }).concat(heimdallApi.middleware),
  });
}

async function waitFor(predicate: () => boolean, act: any, ms = 2000) {
  const start = Date.now();
  while (!predicate()) {
    if (Date.now() - start > ms) throw new Error('waitFor timed out');
    await act(async () => {
      await new Promise((r) => setTimeout(r, 25));
    });
  }
}

test('auxiliary content chords toggle Tasks, Chat overview, and the focused agent PTY', async () => {
  await withDom('#/conversations/a?focused=a', async (dom) => {
    const { createRoot } = await import('react-dom/client');
    const { act } = await import('react');
    const { Provider } = await import('react-redux');
    const { heimdallApi } = await import('../src/ui/api/heimdallApi.ts');
    const { selectAuxPane, selectAuxOpen } = await import('../src/ui/store/auxPanesSlice.ts');
    const { Workspace } = await import('../src/ui/components/mainWorkspace/Workspace.tsx');
    const { ChordHud } = await import('../src/ui/components/shortcuts/ChordHud.tsx');
    const { ShortcutProvider } = await import('../src/ui/services/shortcuts/ShortcutContext.tsx');

    const store = await makeStore();
    const doc = dom.window.document;
    const root = createRoot(doc.getElementById('root')!);
    const treeId = { kind: 'agent' as const, agentInstanceId: 'a' };
    const press = async (...keys: string[]) => {
      await act(async () => {
        for (const key of keys) {
          dom.window.dispatchEvent(new dom.window.KeyboardEvent('keydown', { key, bubbles: true }));
        }
        await new Promise((resolve) => setTimeout(resolve, 40));
      });
    };
    try {
      await act(async () => {
        root.render(React.createElement(
          Provider,
          { store },
          React.createElement(
            ShortcutProvider,
            {},
            React.createElement(React.Fragment, {}, React.createElement(Workspace, {}), React.createElement(ChordHud)),
          ),
        ));
        await new Promise((resolve) => setTimeout(resolve, 40));
      });
      await waitFor(
        () => Boolean(doc.querySelector('[data-debug-id="conversation-thread-title"]')),
        act,
      );
      await waitFor(
        () => selectAuxPane(store.getState(), treeId)?.activeTabId === 'overview',
        act,
      );

      await press('s', 'a');
      let hud = doc.querySelector('[data-debug-id="shortcut-chord-hud"]');
      assert.match(hud?.textContent || '', /Tickets/);
      assert.match(hud?.textContent || '', /Chat overview/);
      assert.match(hud?.textContent || '', /Agent PTY/);
      assert.match(hud?.textContent || '', /esc close/i);
      assert.match(hud?.textContent || '', /enter run current/i);
      assert.equal(hud?.classList.contains('hidden'), false, 'helper is rendered on mobile widths');
      await act(async () => {
        await new Promise((resolve) => setTimeout(resolve, 1_300));
      });
      hud = doc.querySelector('[data-debug-id="shortcut-chord-hud"]');
      assert.ok(hud, 'helper remains visible beyond the former 1200ms timeout');
      await press('t');
      assert.equal(selectAuxPane(store.getState(), treeId)?.activeTabId, 'tasks');
      assert.equal(selectAuxOpen(store.getState()), true);

      await press('s', 'a');
      assert.ok(doc.querySelector('[data-debug-id="shortcut-chord-hud"]'));
      await press('Escape');
      assert.equal(doc.querySelector('[data-debug-id="shortcut-chord-hud"]'), null, 'Escape dismisses the helper');

      await press('s', 'a', 't');
      assert.equal(selectAuxOpen(store.getState()), false, 'same active target closes the dock');

      await press('s', 'a', 'c');
      assert.equal(selectAuxPane(store.getState(), treeId)?.activeTabId, 'overview');
      assert.equal(selectAuxOpen(store.getState()), true);

      // The HUD assertion above verifies that the focused-agent PTY action is
      // registered and enabled. Avoid opening it here: xterm requires browser
      // canvas APIs that jsdom intentionally does not implement.
    } finally {
      await act(async () => root.unmount());
      store.dispatch(heimdallApi.util.resetApiState());
    }
  });
});

test('per-pane agent switcher swaps THAT pane in place (deduped) and the URL/groups follow', async () => {
  await withDom('#/conversations/a+b?focused=b', async (dom) => {
    const { createRoot } = await import('react-dom/client');
    const { act } = await import('react');
    const { Provider } = await import('react-redux');
    const { heimdallApi } = await import('../src/ui/api/heimdallApi.ts');
    const layout = await import('../src/ui/store/workspaceLayoutSlice.ts');
    const { readGroupIndex } = await import('../src/ui/store/splitGroups.ts');
    const { Workspace } = await import('../src/ui/components/mainWorkspace/Workspace.tsx');
    const { ShortcutProvider } = await import('../src/ui/services/shortcuts/ShortcutContext.tsx');

    const store = await makeStore();
    const root = createRoot(dom.window.document.getElementById('root')!);
    const settle = () => new Promise((r) => setTimeout(r, 40));
    try {
      await act(async () => {
        root.render(React.createElement(
          Provider,
          { store },
          React.createElement(ShortcutProvider, {}, React.createElement(Workspace, {})),
        ));
        await settle();
      });
      const aPane = layout.findPaneByAgent(store.getState().workspaceLayout.tree, 'a')!;
      // What AgentChatPane's onSwitchAgent dispatches for pane A.
      await act(async () => {
        store.dispatch(layout.assignMainPaneAgent({ paneId: aPane, agentInstanceId: 'a2' }));
        await settle();
      });
      assert.equal(layout.findPaneByAgent(store.getState().workspaceLayout.tree, 'a2'), aPane);
      assert.equal(layout.selectFocusedMainAgentId(store.getState()), 'a2');
      assert.equal(dom.window.location.hash, '#/conversations/a2+b?focused=a2');
      assert.deepEqual(readGroupIndex(), [['a2', 'b']]);
      // Switching pane A to an agent already in the split focuses it instead.
      await act(async () => {
        store.dispatch(layout.assignMainPaneAgent({ paneId: aPane, agentInstanceId: 'b' }));
        await settle();
      });
      assert.deepEqual(layout.selectMainAgentIds(store.getState()), ['a2', 'b']);
      assert.equal(dom.window.location.hash, '#/conversations/a2+b?focused=b');
    } finally {
      await act(async () => root.unmount());
      store.dispatch(heimdallApi.util.resetApiState());
    }
  });
});

test('fixed top-right cluster: one side-panel toggle (+ update badge) stays top-right with the dock open; content reserves its space', async () => {
  await withDom('#/conversations/a+b?focused=a', async (dom) => {
    const { createRoot } = await import('react-dom/client');
    const { act } = await import('react');
    const { Provider } = await import('react-redux');
    const { heimdallApi } = await import('../src/ui/api/heimdallApi.ts');
    const layout = await import('../src/ui/store/workspaceLayoutSlice.ts');
    const { Workspace } = await import('../src/ui/components/mainWorkspace/Workspace.tsx');
    const { ShortcutProvider } = await import('../src/ui/services/shortcuts/ShortcutContext.tsx');
    const store = await makeStore();
    const doc = dom.window.document;
    const root = createRoot(doc.getElementById('root')!);
    const el = (id: string) => React.createElement('span', { 'data-debug-id': id });
    try {
      await act(async () => {
        root.render(
          React.createElement(
            Provider,
            { store },
            React.createElement(ShortcutProvider, {}, React.createElement(Workspace, {
              leading: el('left-spacer'),
              leadingWidth: 84,
              trailing: el('update-badge'),
            })),
          ),
        );
        await new Promise((r) => setTimeout(r, 40));
      });
      await waitFor(() => doc.querySelectorAll('[data-debug-id="conversation-agent-crumb"]').length === 2, act);
      const tree = store.getState().workspaceLayout.tree;
      const aFrame = doc.querySelector(`[data-debug-id="main-pane-frame-${layout.findPaneByAgent(tree, 'a')}"]`)!; // left
      const bFrame = doc.querySelector(`[data-debug-id="main-pane-frame-${layout.findPaneByAgent(tree, 'b')}"]`)!; // right
      assert.equal(doc.querySelector('[data-debug-id="workspace-top-bar"]'), null, 'no extra header bar');
      const cluster = doc.querySelector('[data-debug-id="workspace-top-right-cluster"]')!;
      const toggles = doc.querySelectorAll('[data-debug-id="workspace-aux-toggle"]');
      assert.equal(toggles.length, 1, 'exactly one side-panel toggle');
      assert.ok(cluster.contains(toggles[0]));
      assert.equal(cluster.lastElementChild, toggles[0], 'toggle is right-most');
      assert.ok(cluster.querySelector('[data-debug-id="update-badge"]'), 'update badge sits in the top-right cluster, left of the toggle');
      assert.equal(doc.querySelectorAll('[data-debug-id="conversation-right-panel-toggle-btn"]').length, 0);
      // The top-left pane reserves the fixed top-left cluster; the top-right pane reserves the top-right cluster.
      assert.ok(aFrame.querySelector('[data-debug-id="conversation-header-leading"] [data-debug-id="left-spacer"]'));
      assert.ok(bFrame.querySelector('[data-debug-id="conversation-thread-header"] [data-debug-id="workspace-top-right-spacer"]'));
      assert.equal(aFrame.querySelector('[data-debug-id="workspace-top-right-spacer"]'), null);

      await act(async () => {
        (toggles[0] as any).click();
        await new Promise((r) => setTimeout(r, 60));
      });
      await waitFor(() => doc.querySelector('[data-debug-id="aux-dock"]')?.getAttribute('data-aux-shown') === 'true', act);
      const dock = doc.querySelector('[data-debug-id="aux-dock"]')!;
      assert.ok(dock, 'toggle opens the side panel');
      assert.equal(dock.getAttribute('data-aux-tree'), 'agent:a', 'for the focused pane');
      assert.equal(dock.getAttribute('data-aux-shown'), 'true', 'slid open');
      // Still ONE toggle, still in the fixed top-right cluster (not in Main, not in the dock).
      assert.equal(doc.querySelectorAll('[data-debug-id="workspace-aux-toggle"]').length, 1);
      assert.ok(cluster.contains(doc.querySelector('[data-debug-id="workspace-aux-toggle"]')));
      assert.equal(dock.contains(cluster), false);
      // Now the aux tab strip reserves the cluster; the top-right Main pane no longer does.
      const strip = dock.querySelector('[data-debug-id^="aux-tab-strip-"]') as any;
      assert.ok(parseFloat(strip.style.paddingRight) > 0, 'aux strip reserves the top-right cluster');
      assert.equal(strip.style.paddingLeft, '', 'restored aux does not reserve the shell cluster');
      assert.equal(bFrame.querySelector('[data-debug-id="workspace-top-right-spacer"]'), null);
      assert.equal(doc.querySelector('[data-debug-id^="aux-close-dock-btn-"]'), null, 'no second close control on desktop');

      await act(async () => {
        (doc.querySelector('[data-debug-id^="aux-maximize-btn-"]') as any).click();
        await new Promise((r) => setTimeout(r, 20));
      });
      assert.equal(parseFloat(strip.style.paddingLeft), 84, 'maximized aux reserves the fixed top-left cluster');
      assert.ok(doc.querySelector('[data-debug-id="workspace-main"]')!.className.includes('hidden'));
      assert.ok(parseFloat(strip.style.paddingRight) > 0, 'maximized aux still reserves the top-right cluster');

      await act(async () => {
        (doc.querySelector('[data-debug-id^="aux-maximize-btn-"]') as any).click();
        await new Promise((r) => setTimeout(r, 20));
      });
      assert.equal(strip.style.paddingLeft, '', 'restoring aux removes the top-left reservation');

      // Close animates: the dock slides shut, then unmounts.
      await act(async () => {
        (doc.querySelector('[data-debug-id="workspace-aux-toggle"]') as any).click();
        await new Promise((r) => setTimeout(r, 20));
      });
      assert.equal(doc.querySelector('[data-debug-id="aux-dock"]')!.getAttribute('data-aux-shown'), 'false', 'sliding closed');
      await act(async () => {
        await new Promise((r) => setTimeout(r, 250));
      });
      assert.equal(doc.querySelector('[data-debug-id="aux-dock"]'), null, 'unmounted after the animation');

      // A focused new-chat pane has no side panel: the toggle is disabled.
      await act(async () => {
        store.dispatch(layout.splitMainPane({ targetPaneId: layout.findPaneByAgent(store.getState().workspaceLayout.tree, 'b')!, direction: 'right' }));
        await new Promise((r) => setTimeout(r, 40));
      });
      const t = doc.querySelectorAll('[data-debug-id="workspace-aux-toggle"]');
      assert.equal(t.length, 1);
      assert.equal((t[0] as any).disabled, true);
      // New panes animate in.
      assert.ok(doc.querySelector(`[data-debug-id="main-pane-frame-${store.getState().workspaceLayout.tree.focusedPaneId}"]`)!.className.includes('heimdall-pane-enter'));
    } finally {
      await act(async () => root.unmount());
      store.dispatch(heimdallApi.util.resetApiState());
    }
  });
});

test('split view: only the FOCUSED pane shows a close ✕; it closes that pane and the URL follows', async () => {
  await withDom('#/conversations/a+b?focused=b', async (dom) => {
    const { createRoot } = await import('react-dom/client');
    const { act } = await import('react');
    const { Provider } = await import('react-redux');
    const { heimdallApi } = await import('../src/ui/api/heimdallApi.ts');
    const layout = await import('../src/ui/store/workspaceLayoutSlice.ts');
    const { Workspace } = await import('../src/ui/components/mainWorkspace/Workspace.tsx');
    const { ShortcutProvider } = await import('../src/ui/services/shortcuts/ShortcutContext.tsx');
    const store = await makeStore();
    const doc = dom.window.document;
    const root = createRoot(doc.getElementById('root')!);
    try {
      await act(async () => {
        root.render(React.createElement(
          Provider,
          { store },
          React.createElement(ShortcutProvider, {}, React.createElement(Workspace, {})),
        ));
        await new Promise((r) => setTimeout(r, 40));
      });
      await waitFor(() => doc.querySelectorAll('[data-debug-id="conversation-agent-crumb"]').length === 2, act);
      const bPane = layout.findPaneByAgent(store.getState().workspaceLayout.tree, 'b')!;
      const closes = doc.querySelectorAll('[data-debug-id="conversation-close-pane-btn"]');
      assert.equal(closes.length, 1, 'one ✕, on the focused pane only');
      assert.ok(doc.querySelector(`[data-debug-id="main-pane-frame-${bPane}"]`)!.contains(closes[0]));
      await act(async () => {
        (closes[0] as any).click();
        await new Promise((r) => setTimeout(r, 20));
      });
      assert.equal(doc.querySelector(`[data-debug-id="main-pane-frame-${bPane}"]`)!.getAttribute('data-main-pane-closing'), 'true', 'pane animates out first');
      await act(async () => {
        await new Promise((r) => setTimeout(r, 250));
      });
      assert.deepEqual(layout.selectMainAgentIds(store.getState()), ['a']);
      assert.equal(dom.window.location.hash, '#/conversations/a');
      assert.equal(doc.querySelectorAll('[data-debug-id="conversation-close-pane-btn"]').length, 0, 'no ✕ in single view');
    } finally {
      await act(async () => root.unmount());
      store.dispatch(heimdallApi.util.resetApiState());
    }
  });
});

test('workspace chords split, cycle, maximize, close, and remain shielded while typing', async () => {
  await withDom('#/conversations/a?focused=a', async (dom) => {
    const { createRoot } = await import('react-dom/client');
    const { act } = await import('react');
    const { Provider } = await import('react-redux');
    const { heimdallApi } = await import('../src/ui/api/heimdallApi.ts');
    const layout = await import('../src/ui/store/workspaceLayoutSlice.ts');
    const { Workspace } = await import('../src/ui/components/mainWorkspace/Workspace.tsx');
    const { ShortcutProvider } = await import('../src/ui/services/shortcuts/ShortcutContext.tsx');
    const store = await makeStore();
    const root = createRoot(dom.window.document.getElementById('root')!);
    const settle = (ms = 50) => new Promise((resolve) => setTimeout(resolve, ms));
    const pressSequence = async (keys: readonly string[], target: EventTarget = dom.window) => {
      await act(async () => {
        for (const key of keys) {
          target.dispatchEvent(new dom.window.KeyboardEvent('keydown', { key, bubbles: true }));
        }
        await settle();
      });
    };
    const pressChord = (first: string, second: string, target: EventTarget = dom.window) => (
      pressSequence([first, second], target)
    );

    try {
      await act(async () => {
        root.render(React.createElement(
          Provider,
          { store },
          React.createElement(ShortcutProvider, {}, React.createElement(Workspace, {})),
        ));
        await settle();
      });

      await pressSequence(['s', 'n', 'c', 'v']);
      assert.equal(layout.selectMainPaneIds(store.getState()).length, 2, 's n c v splits right into the launcher');

      await pressSequence(['s', 'n', 'c', 'h']);
      assert.equal(layout.selectMainPaneIds(store.getState()).length, 3, 's n c h splits down into the launcher');

      const paneIds = layout.selectMainPaneIds(store.getState());
      const [leftPane, topRightPane, bottomRightPane] = paneIds;
      await pressChord('s', 'k');
      assert.equal(layout.selectMainTree(store.getState()).focusedPaneId, topRightPane, 's k focuses the pane above');
      await pressChord('s', 'h');
      assert.equal(layout.selectMainTree(store.getState()).focusedPaneId, leftPane, 's h focuses the pane left');
      await pressChord('s', 'l');
      assert.equal(layout.selectMainTree(store.getState()).focusedPaneId, topRightPane, 's l focuses the nearest pane right');
      await pressChord('s', 'j');
      assert.equal(layout.selectMainTree(store.getState()).focusedPaneId, bottomRightPane, 's j focuses the pane below');

      await waitFor(() => Boolean(dom.window.document.querySelector('[data-debug-id="new-convo-composer-input"]')), act);
      await pressChord('s', 'i');
      assert.equal(
        dom.window.document.activeElement?.getAttribute('data-debug-id'),
        'new-convo-composer-input',
        's i focuses the active pane input',
      );
      const composerInput = dom.window.document.activeElement as HTMLElement;
      await pressChord('s', 'm', composerInput);
      assert.equal(layout.selectMainTree(store.getState()).maximizedPaneId, null, 'typing shield blocks pane chords');
      await act(async () => {
        composerInput.dispatchEvent(new dom.window.KeyboardEvent('keydown', {
          key: 'Alt',
          altKey: true,
          ctrlKey: true,
          bubbles: true,
        }));
        await settle();
      });
      await pressChord('s', 'm', composerInput);
      assert.equal(
        layout.selectMainTree(store.getState()).maximizedPaneId,
        bottomRightPane,
        'Ctrl+Alt routes the next input chord through the manager',
      );
      await act(async () => (dom.window.document.activeElement as HTMLElement)?.blur());
      await pressChord('s', 'm');
      assert.equal(layout.selectMainTree(store.getState()).maximizedPaneId, null);

      await pressChord('s', 'h');
      assert.equal(layout.selectMainTree(store.getState()).focusedPaneId, leftPane);

      const workspace = dom.window.document.querySelector('[data-debug-id="workspace"]')!;
      const auxWasOpen = workspace.getAttribute('data-aux-open');
      await pressSequence(['s', 'a', 'Enter']);
      assert.notEqual(workspace.getAttribute('data-aux-open'), auxWasOpen, 's a toggles the focused agent aux pane');

      const beforeCycle = layout.selectMainTree(store.getState());
      const expectedNext = paneIds[(paneIds.indexOf(beforeCycle.focusedPaneId) + 1) % paneIds.length];
      await pressChord('s', 'w');
      assert.equal(layout.selectMainTree(store.getState()).focusedPaneId, expectedNext, 's w focuses next pane');

      await pressChord('s', 'm');
      assert.equal(layout.selectMainTree(store.getState()).maximizedPaneId, expectedNext, 's m maximizes focus');
      await pressChord('s', 'm');
      assert.equal(layout.selectMainTree(store.getState()).maximizedPaneId, null, 's m restores layout');

      await pressChord('s', 'x');
      await act(async () => settle(250));
      assert.equal(layout.selectMainPaneIds(store.getState()).length, 2, 's x closes focus in a split');
      await pressChord('s', 'x');
      await act(async () => settle(250));
      assert.equal(layout.selectMainPaneIds(store.getState()).length, 1);
      await pressChord('s', 'x');
      await act(async () => settle(250));
      assert.equal(layout.selectMainPaneIds(store.getState()).length, 1, 's x leaves the sole pane intact');
      await pressSequence(['s', 'n', 'c', 'Enter']);
      assert.equal(
        layout.selectFocusedMainAgentId(store.getState()),
        layout.NEW_PANE_AGENT_ID,
        's n c Enter replaces the focused pane with the new-conversation launcher',
      );

    } finally {
      await act(async () => root.unmount());
      store.dispatch(heimdallApi.util.resetApiState());
    }
  });
});
