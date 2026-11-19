import { test } from 'node:test';
import assert from 'node:assert/strict';
import React, { act, useState } from 'react';
import { renderToStaticMarkup } from 'react-dom/server';
import { AcpAuthInstructions } from '../src/ui/components/chat/AcpAuthInstructions.tsx';
import { JSDOM } from 'jsdom';
import { makeVaultStore } from './helpers/vaultEndpointHarness.ts';

const { providerSetupApi } = await import('../src/ui/components/providers/providerSetupApi.ts');
const { normalizeProviderRuntime, acpDisabledReason, acpAdapterSummary } = await import('../src/ui/components/providers/providerRuntime.ts');
const { default: ProviderRuntimeControl, ACP_INSTALL_WAIT_MS } = await import('../src/ui/components/providers/ProviderRuntimeControl.tsx');
const { heimdallApi } = await import('../src/ui/api/heimdallApi.ts');

const adapter = { installed: true, version: '0.108.0', node_version: 'v22.0.0', state: 'ready', error: null, checked_at: '2026-11-18T00:00:00Z' };
const row = (patch = {}): any => ({ provider: 'claude', profile_id: 'claude', display_name: 'Claude', enabled: true,
  state: 'present', catalog_state: 'active', models: [], ...normalizeProviderRuntime({
    transports: ['pty', 'acp'], default_transport: 'pty', effective_transport: 'pty', acp_adapter: adapter,
  }), ...patch });
const setup = (patch = {}): any => ({ bridge: { bridge_id: 'b', status: 'online' }, discovery: {}, providers: [row()], acp_runtime_supported: true, extension_commands: [], ...patch });
const response = (data: any) => new Response(JSON.stringify({ data }), { status: 200, headers: { 'content-type': 'application/json' } });
const tick = () => new Promise((resolve) => setTimeout(resolve, 20));

test('runtime normalization is PTY-only for old/invalid fields and preserves the supported contract', () => {
  assert.deepEqual(normalizeProviderRuntime({}), { transports: ['pty'], default_transport: 'pty', transport: null, effective_transport: 'pty', acp_adapter: null });
  assert.deepEqual(normalizeProviderRuntime({ transports: ['future'], effective_transport: 'acp', acp_adapter: [] }), normalizeProviderRuntime({}));
  assert.equal(normalizeProviderRuntime({ transports: ['pty'], transport: 'acp' }).transport, null);
  assert.deepEqual(normalizeProviderRuntime(row()).acp_adapter, adapter);
  assert.match(acpDisabledReason(false, adapter as any), /Update this bridge/);
  assert.match(acpDisabledReason(true, { ...adapter, state: 'missing_node' } as any), /Node 22/);
});

test('native runtime status keeps its provider identity and uses native labels', () => {
  const native = normalizeProviderRuntime({ acp_adapter: { ...adapter, provider: 'copilot', runtime_kind: 'native' } }).acp_adapter;
  assert.equal(native?.provider, 'copilot');
  assert.equal(native?.runtime_kind, 'native');
  assert.match(acpAdapterSummary(native), /^ACP native runtime:/);
  assert.match(acpDisabledReason(true, { ...native!, state: 'installing' }), /runtime installation/);
  assert.match(acpDisabledReason(true, { ...native!, state: 'error', error: 'acp_adapter_unsupported_platform' }), /not supported on this platform/);
  assert.equal(normalizeProviderRuntime({ acp_adapter: { ...adapter, runtime_kind: 'unknown' } }).acp_adapter?.runtime_kind, undefined);
});

test('ACP auth renders descriptor guidance and selected profile without a fixed provider command', () => {
  const markup = renderToStaticMarkup(React.createElement(AcpAuthInstructions, {
    profile: 'work', guidance: 'Run copilot login using profile work, then restart this instance.',
  }));
  assert.match(markup, /copilot login using profile work/);
  assert.doesNotMatch(markup, /claude/);
  const fallback = renderToStaticMarkup(React.createElement(AcpAuthInstructions, { profile: 'work' }));
  assert.match(fallback, /profile <code>work/);
  assert.doesNotMatch(fallback, /claude/);
});

test('transport and install APIs use canonical provider scope and keep profile enablement separate', async () => {
  const previous = globalThis.fetch;
  const calls: any[] = [];
  let selected: string | null = null;
  globalThis.fetch = async (input: any, init: any = {}) => {
    const path = new URL(String(input), 'http://localhost').pathname;
    const body = init.body ? JSON.parse(init.body) : undefined;
    calls.push({ path, method: init.method || 'GET', body });
    if (init.method === 'PUT' && 'transport' in body) selected = body.transport;
    if (path.endsWith('/bridges')) return response({ bridges: [{ bridge_id: 'b', status: 'online' }] });
    if (path.endsWith('/acp-adapter')) return response({ command_id: 'cmd-install', state: 'installing' });
    return response({ acp_runtime_supported: true, providers: [row({ transport: selected, effective_transport: selected || 'pty' }), row({ profile_id: 'work', transport: selected, effective_transport: selected || 'pty' })] });
  };
  try {
    const acp = await providerSetupApi.setTransport(setup(), 'claude', 'acp');
    assert.equal(acp.providers.length, 2, 'refresh keeps all profiles');
    assert.ok(acp.providers.every((p) => p.effective_transport === 'acp'));
    await providerSetupApi.setTransport(acp, 'claude', null);
    await providerSetupApi.installAdapter(acp, 'claude');
    const enabled = await providerSetupApi.setEnabled(acp, 'claude', false, 'work');
    assert.equal(enabled.providers[0].enabled, true);
    assert.equal(enabled.providers[1].enabled, false);
    assert.deepEqual(calls.filter((c) => c.method === 'PUT').map((c) => c.body), [{ transport: 'acp' }, { transport: null }, { enabled: false, profile_id: 'work' }]);
    assert.deepEqual(calls.find((c) => c.method === 'POST'), { path: '/api/v1/bridges/b/providers/claude/acp-adapter', method: 'POST', body: { action: 'install' } });
    assert.equal(calls.filter((c) => c.path.endsWith('/provider-status')).length, 2);
  } finally { globalThis.fetch = previous; }
});

test('bridge picker/status endpoint preserves runtime fields and instance API normalizes its launch snapshot', async () => {
  const { bridgeSupportApi } = await import('../src/ui/api/endpoints/bridgeSupport.ts');
  const { agentsApi } = await import('../src/ui/api/endpoints/agents.ts');
  const store = await makeVaultStore();
  const previous = globalThis.fetch;
  globalThis.fetch = async (input: any) => response(String(input).endsWith('/provider-status')
    ? { providers: [row({ transport: 'acp', effective_transport: 'acp' })], acp_runtime_supported: true }
    : { agent_instance_id: 'i', runtime_transport: 'acp', launch_epoch: 'launch-1' });
  try {
    const providers = await store.dispatch(bridgeSupportApi.endpoints.listBridgeProviders.initiate({ bridgeId: 'b' })).unwrap();
    assert.deepEqual(providers.providers[0].transports, ['pty', 'acp']);
    assert.deepEqual(providers.providers[0].acp_adapter, adapter);
    const data = await store.dispatch(agentsApi.endpoints.fetchAgentInstance.initiate({ instanceId: 'i' })).unwrap();
    assert.equal(data.instance.runtime_transport, 'acp');
    globalThis.fetch = async () => response({ agent_instance_id: 'old' });
    const legacy = await store.dispatch(agentsApi.endpoints.fetchAgentInstance.initiate({ instanceId: 'old' })).unwrap();
    assert.equal(legacy.instance.runtime_transport, 'pty');
  } finally { store.dispatch(heimdallApi.util.resetApiState()); globalThis.fetch = previous; }
});

async function browser() {
  const dom = new JSDOM('<div id="root"></div>', { url: 'http://localhost/', pretendToBeVisual: true });
  const keys = ['window', 'document', 'HTMLElement', 'Node', 'IS_REACT_ACT_ENVIRONMENT'];
  const saved = keys.map((k) => [k, Object.getOwnPropertyDescriptor(globalThis, k)] as const);
  Object.assign(globalThis, { window: dom.window, document: dom.window.document, HTMLElement: dom.window.HTMLElement,
    Node: dom.window.Node, IS_REACT_ACT_ENVIRONMENT: true });
  const { createRoot } = await import('react-dom/client');
  const root = createRoot(dom.window.document.getElementById('root')!);
  return {
    doc: dom.window.document, dom,
    async render(element: any) { await act(async () => { root.render(element); await tick(); }); },
    async click(id: string) { await act(async () => { (dom.window.document.querySelector(`[data-debug-id="${id}"]`) as HTMLElement).click(); await tick(); }); },
    async cleanup() {
      await act(async () => root.unmount());
      for (const [k, descriptor] of saved) { if (descriptor) Object.defineProperty(globalThis, k, descriptor); else delete (globalThis as any)[k]; }
      dom.window.close();
    },
  };
}

test('a relaunch summary patches the instance transport from the frozen launch, without reading provider settings', async () => {
  const { agentsApi } = await import('../src/ui/api/endpoints/agents.ts');
  const { handleUserWsEvent, resetQueuedInvalidations } = await import('../src/ui/api/wsInvalidation.ts');
  const store = await makeVaultStore();
  const previous = globalThis.fetch;
  const paths: string[] = [];
  globalThis.fetch = async (input: any) => { paths.push(String(input)); return response({ runtime_transport: 'pty', run_count: 1, updated_at: '2026-11-18T00:00:00Z' }); };
  try {
    await store.dispatch(agentsApi.endpoints.fetchAgentInstance.initiate({ instanceId: 'i' })).unwrap();
    paths.length = 0;
    handleUserWsEvent(store.dispatch, { type: 'resource_changed', resource: 'agent_instance', resource_id: 'i', change: 'status_changed',
      summary: { runtime_status: 'starting', runtime_transport: 'acp', launch_epoch: 'launch-2', run_count: 2, updated_at: '2026-11-18T00:00:01Z' } });
    const instance = agentsApi.endpoints.fetchAgentInstance.select({ instanceId: 'i' })(store.getState()).data!.instance!;
    assert.equal(instance.runtime_transport, 'acp');
    assert.equal(instance.launch_epoch, 'launch-2');
    assert.equal(instance.run_count, 2);
    assert.deepEqual(paths, []);
  } finally { resetQueuedInvalidations(); store.dispatch(heimdallApi.util.resetApiState()); globalThis.fetch = previous; }
});

test('Runtime control saves ACP, resets null, and explains provider/host restrictions', async () => {
  const h = await browser();
  const saved = providerSetupApi.setTransport;
  const saves: any[] = [];
  providerSetupApi.setTransport = async (current, provider, transport) => {
    saves.push({ provider, transport });
    return { ...current, providers: [row({ transport, effective_transport: transport || 'pty' })] };
  };
  function Host() {
    const [current, update] = useState(setup());
    return React.createElement(ProviderRuntimeControl, { setup: current, status: current.providers[0], onChange: update });
  }
  try {
    await h.render(React.createElement(Host));
    const select = h.doc.querySelector('select')!;
    await act(async () => { select.value = 'acp'; select.dispatchEvent(new h.dom.window.Event('change', { bubbles: true })); await tick(); });
    assert.equal(h.doc.querySelector('select')!.value, 'acp');
    await h.click('providers-runtime-reset-claude');
    assert.deepEqual(saves, [{ provider: 'claude', transport: 'acp' }, { provider: 'claude', transport: null }]);
    await h.render(React.createElement(ProviderRuntimeControl, { setup: setup(), status: row({ transports: ['pty'] }), onChange() {} }));
    assert.equal(h.doc.querySelector('select')!.disabled, true);
    assert.match(h.doc.querySelector('select')!.title, /supports only PTY/);
    await h.render(React.createElement(ProviderRuntimeControl, { setup: setup({ acp_runtime_supported: false }), status: row(), onChange() {} }));
    assert.equal((h.doc.querySelector('option[value="acp"]') as HTMLOptionElement).disabled, true);
    assert.match(h.doc.body.textContent || '', /Update this bridge/);
    assert.match(h.doc.body.textContent || '', /0\.108\.0.*v22\.0\.0/);
  } finally { providerSetupApi.setTransport = saved; await h.cleanup(); }
});

test('tracked installs stop waiting at 150 seconds and Check status recovers terminal results without reinstalling', async () => {
  const h = await browser();
  const originalGet = providerSetupApi.get;
  const originalInstall = providerSetupApi.installAdapter;
  const originalTimeout = globalThis.setTimeout;
  const originalClear = globalThis.clearTimeout;
  const timers = new Map<any, { fn: () => void; ms: number }>();
  let installs = 0;
  let completed = false;
  let current = setup({ providers: [row({ acp_adapter: { ...adapter, installed: false, state: 'missing' } })] });
  function Host() {
    const [value, update] = useState(current);
    return React.createElement(ProviderRuntimeControl, { setup: value, status: value.providers[0], onChange: update });
  }
  providerSetupApi.installAdapter = async () => { installs++; return { command_id: 'cmd-1' }; };
  providerSetupApi.get = async () => setup({ providers: [row({ acp_adapter: { ...adapter, state: completed ? 'ready' : 'installing' } })],
    extension_commands: [{ command_id: 'cmd-1', bridge_id: 'b', provider: 'claude', kind: 'install_acp_adapter', status: completed ? 'succeeded' : 'dispatched', progress_percent: 0 }] });
  try {
    await h.render(React.createElement(Host));
    globalThis.setTimeout = ((fn: () => void, ms: number, ...args: any[]) => {
      if (ms !== 1000 && ms !== ACP_INSTALL_WAIT_MS) return originalTimeout(fn, ms, ...args);
      const id = {}; timers.set(id, { fn, ms }); return id;
    }) as any;
    globalThis.clearTimeout = ((id: any) => { if (!timers.delete(id)) originalClear(id); }) as any;
    await h.click('providers-acp-install-claude');
    assert.equal(installs, 1);
    assert.ok(h.doc.querySelector('progress'));
    const deadline = [...timers.values()].find((v) => v.ms === 150000)!;
    assert.ok(deadline);
    await act(async () => deadline.fn());
    assert.match(h.doc.body.textContent || '', /did not finish within 150 seconds/);
    assert.equal(h.doc.querySelector('progress'), null);
    assert.equal(timers.size, 0, 'timeout cancels automatic polling');
    completed = true;
    await h.click('providers-acp-check-claude');
    assert.equal(installs, 1);
    assert.match(h.doc.body.textContent || '', /Installation: succeeded/);
    assert.match(h.doc.body.textContent || '', /Select ACP/);
    assert.doesNotMatch(h.doc.body.textContent || '', /did not finish/);
  } finally {
    await h.cleanup();
    globalThis.setTimeout = originalTimeout; globalThis.clearTimeout = originalClear;
    providerSetupApi.get = originalGet; providerSetupApi.installAdapter = originalInstall;
  }
});

test('provider settings renders one shared Runtime control for multiple profiles', async () => {
  const h = await browser();
  const { Provider } = await import('react-redux');
  const { default: ProviderProfilesSurface } = await import('../src/ui/components/providers/ProviderProfilesSurface.tsx');
  const previous = globalThis.fetch;
  const store = await makeVaultStore();
  const profiles = ['claude', 'work', 'personal'].map((id) => row({ profile_id: id }));
  globalThis.fetch = async (input: any) => response(String(input).endsWith('/provider-profiles') ? { profiles }
    : String(input).endsWith('/bridges') ? { bridges: [{ bridge_id: 'b', status: 'online' }] }
      : { providers: profiles, acp_runtime_supported: true });
  try {
    await h.render(React.createElement(Provider, { store }, React.createElement(ProviderProfilesSurface, { bridge: { bridge_id: 'b', status: 'online', vault_status: 'locked' } })));
    await act(tick);
    assert.equal(h.doc.querySelectorAll('[data-debug-id="providers-runtime-select-claude"]').length, 1);
    assert.equal(h.doc.querySelectorAll('[data-debug-id^="profile-select-"]').length, 3);
    assert.match(h.doc.body.textContent || '', /Shared by all Claude profiles/);
    assert.equal(h.doc.querySelector('select')!.disabled, true);
  } finally {
    await act(async () => { store.dispatch(heimdallApi.util.resetApiState()); await tick(); });
    await h.cleanup(); globalThis.fetch = previous;
  }
});

test('startup and unknown blockers never offer permission decisions', async () => {
  const { normalizeBlocker, blockerCardView } = await import('../src/ui/components/extension/blockersModel.ts');
  const { AgentBlockerActions, AgentBlockerBody } = await import('../src/ui/components/attention/AgentBlockerCard.tsx');
  const { renderToStaticMarkup } = await import('react-dom/server');
  const { Provider } = await import('react-redux');
  const store = await makeVaultStore();
  try {
    const blocker = normalizeBlocker({ blocker_id: 'auth', kind: 'startup', input: { reason: 'acp_auth_required' } })!;
    assert.equal(blockerCardView(blocker, Date.now()).canDecide, false);
    for (const kind of ['startup', 'unknown']) {
      const item: any = { details: { blocker_kind: kind, input: { reason: 'acp_auth_required' } }, action_refs: { blocker_id: 'auth' } };
      const html = renderToStaticMarkup(React.createElement(Provider, { store }, React.createElement(AgentBlockerActions, { item })));
      assert.doesNotMatch(html, /Allow|Deny|login-open|login-retry|login-cancel/);
      if (kind === 'startup') assert.match(renderToStaticMarkup(React.createElement(AgentBlockerBody, { item })), /Authenticate this provider.*bridge host.*Restart agent/);
    }
  } finally { store.dispatch(heimdallApi.util.resetApiState()); }
});

test('ACP pane reuses attention permission cards: Allow/Deny, failure recovery, instance scoping and stop', async () => {
  const { AcpPermissionBlockers } = await import('../src/ui/components/chat/AcpPermissionBlockers.tsx');
  const { Provider } = await import('react-redux');
  const { createActionScheduler } = await import('../src/ui/services/attention/actionScheduler.ts');
  const { hideKey } = await import('../src/ui/components/attention/attentionModel.ts');
  const store = await makeVaultStore();
  const h = await browser();
  const previous = globalThis.fetch;
  const calls: any[] = [];
  const item = (id: string, instance = 'i', kind = 'permission'): any => ({
    card_id: `blk:${instance}:${id}`, kind: 'agent_blocker', title: 'Permission', status: 'pending',
    context: {}, details: { blocker_kind: kind, tool_name: 'Run command', input: { command: 'pwd' } },
    action_refs: { agent_instance_id: instance, blocker_id: id },
  });
  const items = [item('allow'), item('deny'), item('other', 'other-instance'), item('auth', 'i', 'startup')];
  const scheduler = createActionScheduler({ timers: { now: () => 0, setTimeout: () => 1, clearTimeout: () => {} } });
  let fail = true;
  globalThis.fetch = async (input: any, init: any = {}) => {
    const path = new URL(String(input), 'http://localhost').pathname;
    if (init.method === 'POST') {
      calls.push({ path, body: JSON.parse(init.body) });
      if (path.includes('/deny/') && fail) return new Response(JSON.stringify({ error: { message: 'Try again' } }), { status: 503 });
      return response({ resolved: true, delivered: true });
    }
    return response({ items, counts: { total: 4, agent_blocker: 4 } });
  };
  const render = (runtimeStatus = 'running') => h.render(React.createElement(Provider, { store },
    React.createElement(AcpPermissionBlockers, { agentInstanceId: 'i', visible: true, runtimeStatus, scheduler })));
  try {
    await render(); await act(tick);
    assert.ok(h.doc.querySelector('[data-debug-id="agent-acp-permission-allow"]'));
    assert.ok(h.doc.querySelector('[data-debug-id="attention-blocker-deny-deny"]'));
    assert.equal(h.doc.querySelector('[data-debug-id="agent-acp-permission-other"]'), null);
    assert.equal(h.doc.querySelector('[data-debug-id="agent-acp-permission-auth"]'), null);
    assert.match(h.doc.body.textContent || '', /pwd/);
    await h.click('attention-blocker-allow-allow');
    assert.equal(h.doc.querySelector('[data-debug-id="agent-acp-permission-allow"]'), null);
    assert.ok(scheduler.getSnapshot().hidden.has(hideKey(items[0])));
    await h.click('attention-blocker-deny-deny');
    assert.ok(h.doc.querySelector('[data-debug-id="agent-acp-permission-deny"]'), 'a failed decision restores the prompt');
    assert.ok(h.doc.querySelector('[role="alert"]'));
    fail = false;
    await h.click('attention-blocker-deny-deny');
    assert.equal(h.doc.querySelector('[data-debug-id="agent-acp-permission-deny"]'), null);
    assert.deepEqual(calls, [
      { path: '/api/v1/agent-instances/i/blockers/allow/resolve', body: { decision: 'allow' } },
      { path: '/api/v1/agent-instances/i/blockers/deny/resolve', body: { decision: 'deny' } },
      { path: '/api/v1/agent-instances/i/blockers/deny/resolve', body: { decision: 'deny' } },
    ]);
    await act(async () => scheduler.unsettle(hideKey(items[0])));
    await render('stopped');
    assert.equal(h.doc.querySelector('[data-debug-id^="agent-acp-permission-"]'), null);
  } finally {
    await act(async () => { store.dispatch(heimdallApi.util.resetApiState()); await tick(); });
    await h.cleanup(); globalThis.fetch = previous;
  }
});

test('Runtime control displays Claude binary failures from adapter status', async () => {
  const h = await browser();
  try {
    for (const error of [
      'acp_claude_not_found: No Claude executable resolves in the canonical provider profile',
      'acp_claude_not_runnable: Could not start dynamically linked executable; configure the Claude provider binary for this host',
    ]) {
      const status = row({ acp_adapter: { ...adapter, state: 'error', error } });
      await h.render(React.createElement(ProviderRuntimeControl, {
        setup: setup({ providers: [status] }), status, onChange() {},
      }));
      const panel = h.doc.querySelector('[data-debug-id="providers-acp-status-claude"]');
      assert.ok(panel);
      assert.ok(panel.textContent?.includes(error));
    }
  } finally { await h.cleanup(); }
});
