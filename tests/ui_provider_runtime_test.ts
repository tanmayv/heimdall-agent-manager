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
const VERDICTS: Record<string, [string, string | null]> = { ready: ['ready', null], installing: ['installing', null],
  missing: ['adapter_missing', 'install_adapter'], outdated: ['adapter_outdated', 'install_adapter'], error: ['adapter_error', 'install_adapter'],
  missing_node: ['adapter_missing_node', 'install_adapter'], missing_npm: ['adapter_missing_npm', 'install_adapter'] };
/** Test stand-in for the Hub's classify_acp_availability verdict on an ACP-capable bridge. */
const hubVerdict = (a: any): any => { const [reason, fix] = VERDICTS[a?.state] || ['not_checked', 'check_now']; return { available: reason === 'ready', reason, fix }; };
const UNSUPPORTED_BRIDGE = { available: false, reason: 'unsupported_bridge', fix: 'update_bridge' } as const;
const row = (patch: any = {}): any => {
  const value: any = { provider: 'claude', profile_id: 'claude', display_name: 'Claude', enabled: true,
    state: 'present', catalog_state: 'active', models: [], ...normalizeProviderRuntime({
      transports: ['pty', 'acp'], default_transport: 'pty', effective_transport: 'pty', acp_adapter: adapter,
    }), ...patch };
  if (!('acp_availability' in patch)) value.acp_availability = hubVerdict(value.acp_adapter);
  return value;
};
const setup = (patch = {}): any => ({ bridge: { bridge_id: 'b', status: 'online' }, discovery: {}, providers: [row()], acp_runtime_supported: true, extension_commands: [], ...patch });
const response = (data: any) => new Response(JSON.stringify({ data }), { status: 200, headers: { 'content-type': 'application/json' } });
const tick = () => new Promise((resolve) => setTimeout(resolve, 20));

test('runtime normalization is PTY-only for old/invalid fields and preserves the supported contract', () => {
  assert.deepEqual(normalizeProviderRuntime({}), { transports: ['pty'], default_transport: 'pty', transport: null, effective_transport: 'pty', acp_adapter: null });
  assert.deepEqual(normalizeProviderRuntime({ transports: ['future'], effective_transport: 'acp', acp_adapter: [] }), normalizeProviderRuntime({}));
  assert.equal(normalizeProviderRuntime({ transports: ['pty'], transport: 'acp' }).transport, null);
  assert.deepEqual(normalizeProviderRuntime(row()).acp_adapter, adapter);
  assert.match(acpDisabledReason(UNSUPPORTED_BRIDGE, adapter as any), /Update this bridge/);
  // The verdict decides; the text is the bridge's own message with its install command.
  const node = { ...adapter, state: 'missing_node', install_command: 'sudo dnf install -y nodejs npm',
    error: 'Node.js 22 or newer is required on the bridge host to run the Claude ACP adapter; install it with: sudo dnf install -y nodejs npm' } as any;
  assert.equal(acpDisabledReason(hubVerdict(node), node), node.error);
  assert.equal(normalizeProviderRuntime({ acp_adapter: node }).acp_adapter?.install_command, 'sudo dnf install -y nodejs npm');
  assert.equal(acpDisabledReason(null, node), '', 'no verdict yet reads as not checked');
  assert.equal(acpDisabledReason(hubVerdict(adapter), { ...adapter, state: 'error' } as any), '', 'the Hub verdict wins over the raw state');
});

test('the effective transport is the Hub\'s resolved value, never derived from transport or the default', () => {
  // G7: no fallback to transport || default_transport.
  assert.equal(normalizeProviderRuntime({ transports: ['pty', 'acp'], default_transport: 'pty', transport: 'acp' }).effective_transport, null);
  assert.equal(normalizeProviderRuntime({ transports: ['pty', 'acp'], default_transport: 'acp' }).effective_transport, null);
  assert.equal(normalizeProviderRuntime({ transports: ['pty', 'acp'], default_transport: 'acp', transport: null, effective_transport: 'pty' }).effective_transport, 'pty');
  assert.equal(normalizeProviderRuntime({ transports: ['pty', 'acp'], transport: 'pty', effective_transport: 'acp' }).effective_transport, 'acp');
  assert.equal(normalizeProviderRuntime({ transports: ['pty'], effective_transport: 'acp' }).effective_transport, null, 'unsupported values are dropped');
  assert.equal(normalizeProviderRuntime({ default_transport: 'pty' }).effective_transport, 'pty', 'a Hub without the transport contract is PTY-only');
});

test('adapter runtime status uses adapter labels; the removed native kind is dropped', () => {
  const copilot = normalizeProviderRuntime({ acp_adapter: { ...adapter, provider: 'copilot', runtime_kind: 'native' } }).acp_adapter;
  assert.equal(copilot?.provider, 'copilot');
  assert.equal(copilot?.runtime_kind, undefined);
  assert.match(acpAdapterSummary(copilot), /^ACP adapter:/);
  assert.match(acpDisabledReason(hubVerdict({ state: 'installing' }), { ...copilot!, state: 'installing' }), /adapter installation/);
  assert.match(acpDisabledReason(hubVerdict({ state: 'error' }), { ...copilot!, state: 'error', error: 'acp_adapter_unsupported_platform' }), /not supported on this platform/);
  assert.equal(normalizeProviderRuntime({ acp_adapter: { ...adapter, runtime_kind: 'unknown' } }).acp_adapter?.runtime_kind, undefined);
});

test('missing npm and a failed npm install show the bridge command and redacted npm output', async () => {
  const npm = { ...adapter, installed: false, version: null, state: 'missing_npm', install_command: 'sudo apt-get install -y npm',
    error: 'npm is required on the bridge host to install the Claude ACP adapter; install it with: sudo apt-get install -y npm' };
  const failed = { ...adapter, installed: false, version: null, state: 'error', error: 'acp_adapter_install_failed',
    diagnostic: 'npm error code E404\nnpm error 404 Not Found - GET https://***@registry.npmjs.org/x' };
  const h = await browser();
  try {
    let status = row({ acp_adapter: normalizeProviderRuntime({ acp_adapter: npm }).acp_adapter });
    assert.equal(status.acp_availability.reason, 'adapter_missing_npm');
    await h.render(React.createElement(ProviderRuntimeControl, { setup: setup({ providers: [status] }), status, onChange() {} }));
    assert.equal(h.doc.querySelector('[data-debug-id="providers-acp-install-command-claude"]')?.textContent, 'sudo apt-get install -y npm');
    assert.equal((h.doc.querySelector('option[value="acp"]') as HTMLOptionElement).disabled, true);
    assert.match(h.doc.body.textContent || '', /npm is required on the bridge host/);
    // The message and its command are shown once, not repeated.
    assert.equal((h.doc.body.textContent || '').split('sudo apt-get install -y npm').length - 1, 1);
    assert.equal((h.doc.body.textContent || '').split('npm is required on the bridge host').length - 1, 1);
    assert.equal(h.doc.querySelector('[data-debug-id="providers-acp-install-claude"]')?.textContent, 'Re-check', 'the action re-detects after the user installs npm');
    status = row({ acp_adapter: normalizeProviderRuntime({ acp_adapter: failed }).acp_adapter });
    await h.render(React.createElement(ProviderRuntimeControl, { setup: setup({ providers: [status] }), status, onChange() {} }));
    assert.equal(h.doc.querySelector('[data-debug-id="providers-acp-diagnostic-claude"]')?.textContent, failed.diagnostic);
    assert.equal(h.doc.querySelector('[data-debug-id="providers-acp-install-command-claude"]'), null);
  } finally { await h.cleanup(); }
});

test('Check status re-detects the one provider on the bridge before reading status', async () => {
  const previous = globalThis.fetch;
  const calls: any[] = [];
  globalThis.fetch = async (input: any, init: any = {}) => {
    const path = new URL(String(input), 'http://localhost').pathname;
    calls.push({ path, method: init.method || 'GET', body: init.body ? JSON.parse(init.body) : undefined });
    if (path.endsWith('/bridges')) return response({ bridges: [{ bridge_id: 'b', status: 'online' }] });
    return response({ acp_runtime_supported: true, providers: [row()] });
  };
  try {
    await providerSetupApi.redetect(setup(), 'claude');
    assert.deepEqual(calls.find((c) => c.method === 'POST'), { path: '/api/v1/bridges/b/providers/discover', method: 'POST', body: { stage: 'providers', providers: ['claude'] } });
    assert.ok(calls.some((c) => c.path.endsWith('/provider-status')));
    calls.length = 0;
    await providerSetupApi.redetect(setup({ bridge: { bridge_id: 'b', status: 'offline' } }), 'claude');
    assert.equal(calls.filter((c) => c.method === 'POST').length, 0, 'an offline bridge is only re-read');
  } finally { globalThis.fetch = previous; }
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

test('transport saves are per profile; install stays provider-wide and enablement separate', async () => {
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
    await providerSetupApi.setTransport(acp, 'claude', 'pty', 'work');
    await providerSetupApi.setTransport(acp, 'claude', 'acp', 'claude');
    await providerSetupApi.installAdapter(acp, 'claude');
    const enabled = await providerSetupApi.setEnabled(acp, 'claude', false, 'work');
    assert.equal(enabled.providers[0].enabled, true);
    assert.equal(enabled.providers[1].enabled, false);
    assert.deepEqual(calls.filter((c) => c.method === 'PUT').map((c) => c.body), [{ transport: 'acp' }, { transport: null },
      { transport: 'pty', profile_id: 'work' }, { transport: 'acp' }, { enabled: false, profile_id: 'work' }]);
    assert.deepEqual(calls.find((c) => c.method === 'POST'), { path: '/api/v1/bridges/b/providers/claude/acp-adapter', method: 'POST', body: { action: 'install' } });
    assert.equal(calls.filter((c) => c.path.endsWith('/provider-status')).length, 4);
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
  providerSetupApi.setTransport = async (current, provider, transport, profileId) => {
    saves.push({ provider, transport, profileId });
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
    assert.deepEqual(saves, [{ provider: 'claude', transport: 'acp', profileId: 'claude' }, { provider: 'claude', transport: null, profileId: 'claude' }]);
    await h.render(React.createElement(ProviderRuntimeControl, { setup: setup(), status: row({ transports: ['pty'] }), onChange() {} }));
    assert.equal(h.doc.querySelector('select')!.disabled, true);
    assert.match(h.doc.querySelector('select')!.title, /supports only PTY/);
    await h.render(React.createElement(ProviderRuntimeControl, { setup: setup({ acp_runtime_supported: false }), status: row({ acp_availability: UNSUPPORTED_BRIDGE }), onChange() {} }));
    assert.equal((h.doc.querySelector('option[value="acp"]') as HTMLOptionElement).disabled, true);
    assert.match(h.doc.body.textContent || '', /Update this bridge/);
    assert.match(h.doc.body.textContent || '', /0\.108\.0.*v22\.0\.0/);
  } finally { providerSetupApi.setTransport = saved; await h.cleanup(); }
});

test('tracked installs stop waiting at 150 seconds and Check status recovers terminal results without reinstalling', async () => {
  const h = await browser();
  const originalGet = providerSetupApi.get;
  const originalInstall = providerSetupApi.installAdapter;
  const originalRedetect = providerSetupApi.redetect;
  const redetected: string[] = [];
  providerSetupApi.redetect = async (current, provider) => { redetected.push(provider); return providerSetupApi.get(current.bridge.bridge_id, true, true); };
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
    assert.deepEqual(redetected, ['claude']);
    assert.match(h.doc.body.textContent || '', /Installation: succeeded/);
    assert.match(h.doc.body.textContent || '', /Select ACP/);
    assert.doesNotMatch(h.doc.body.textContent || '', /did not finish/);
  } finally {
    await h.cleanup();
    globalThis.setTimeout = originalTimeout; globalThis.clearTimeout = originalClear;
    providerSetupApi.get = originalGet; providerSetupApi.installAdapter = originalInstall; providerSetupApi.redetect = originalRedetect;
  }
});

test('provider settings renders one Runtime selector per profile with its resolved value', async () => {
  const h = await browser();
  const { Provider } = await import('react-redux');
  const { default: ProviderProfilesSurface } = await import('../src/ui/components/providers/ProviderProfilesSurface.tsx');
  const previous = globalThis.fetch;
  const store = await makeVaultStore();
  const profiles = [row({ profile_id: 'claude' }), row({ profile_id: 'work', transport: 'acp', effective_transport: 'acp' }), row({ profile_id: 'personal' })];
  globalThis.fetch = async (input: any) => response(String(input).endsWith('/provider-profiles') ? { profiles }
    : String(input).endsWith('/bridges') ? { bridges: [{ bridge_id: 'b', status: 'online' }] }
      : { providers: profiles, acp_runtime_supported: true });
  try {
    await h.render(React.createElement(Provider, { store }, React.createElement(ProviderProfilesSurface, { bridge: { bridge_id: 'b', status: 'online', vault_status: 'locked' } })));
    await act(tick);
    const value = (id: string) => (h.doc.querySelector(`[data-debug-id="providers-runtime-select-${id}"]`) as HTMLSelectElement | null)?.value;
    assert.equal(value('claude'), 'pty');
    assert.equal(value('claude-work'), 'acp');
    assert.equal(value('claude-personal'), 'pty');
    assert.equal(h.doc.querySelectorAll('[data-debug-id^="providers-runtime-select-"]').length, 3);
    assert.equal(h.doc.querySelectorAll('[data-debug-id="providers-acp-check-claude"]').length, 1, 'the adapter block is provider-wide');
    assert.equal(h.doc.querySelectorAll('[data-debug-id^="profile-select-"]').length, 3);
    assert.match(h.doc.body.textContent || '', /Chosen per Claude profile/);
    assert.equal(h.doc.querySelector('select')!.disabled, true);
  } finally {
    await act(async () => { store.dispatch(heimdallApi.util.resetApiState()); await tick(); });
    await h.cleanup(); globalThis.fetch = previous;
  }
});

test('a profile selector saves that profile only and uses that profile\'s ACP verdict', async () => {
  const h = await browser();
  const saved = providerSetupApi.setTransport;
  const saves: any[] = [];
  const missing = { available: false, reason: 'adapter_missing', fix: 'install_adapter' };
  const rows = (work: string | null) => [row({ label: 'Default' }),
    row({ profile_id: 'work', label: 'Work', transport: work, effective_transport: work || 'pty' }),
    row({ profile_id: 'home', label: 'Home', acp_availability: missing, acp_adapter: { ...adapter, runtime_kind: 'system' } })];
  providerSetupApi.setTransport = async (current, provider, transport, profileId) => {
    saves.push({ provider, transport, profileId });
    return { ...current, providers: rows(profileId === 'work' ? transport : null) };
  };
  function Host() {
    const [current, update] = useState(setup({ providers: rows(null) }));
    return React.createElement(ProviderRuntimeControl, { setup: current, status: current.providers[0], profiles: current.providers, onChange: update });
  }
  try {
    await h.render(React.createElement(Host));
    const select = (id: string) => h.doc.querySelector(`[data-debug-id="providers-runtime-select-${id}"]`) as HTMLSelectElement;
    await act(async () => { select('claude-work').value = 'acp'; select('claude-work').dispatchEvent(new h.dom.window.Event('change', { bubbles: true })); await tick(); });
    assert.deepEqual(saves, [{ provider: 'claude', transport: 'acp', profileId: 'work' }]);
    assert.equal(select('claude-work').value, 'acp');
    assert.equal(select('claude').value, 'pty', 'the default profile keeps its own value');
    // Each profile's ACP option follows that profile's Hub verdict.
    assert.equal((select('claude').querySelector('option[value="acp"]') as HTMLOptionElement).disabled, false);
    assert.equal((select('claude-home').querySelector('option[value="acp"]') as HTMLOptionElement).disabled, true);
    assert.ok(h.doc.querySelector('[data-debug-id="providers-runtime-profile-acp-claude-home"]'));
    await h.click('providers-runtime-reset-claude-work');
    assert.deepEqual(saves[1], { provider: 'claude', transport: null, profileId: 'work' });
    // No resolved value from the Hub: the selector says so instead of guessing.
    await h.render(React.createElement(ProviderRuntimeControl, { setup: setup(), status: row({ transport: 'acp', effective_transport: null }), onChange() {} }));
    assert.equal((h.doc.querySelector('select') as HTMLSelectElement).value, '');
    assert.match(h.doc.querySelector('select')!.textContent || '', /Unknown/);
  } finally { providerSetupApi.setTransport = saved; await h.cleanup(); }
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

test('detect-only system CLI status uses Re-check, never Node or install wording', async () => {
  const kiroAdapter = { installed: false, version: '3.4.0', node_version: null, state: 'outdated', provider: 'kiro', runtime_kind: 'system',
    error: 'acp_kiro_outdated: The selected Kiro executable is older than the minimum supported version 3.5.0; upgrade it on the bridge host', checked_at: '2026-11-21T00:00:00Z' };
  const system = normalizeProviderRuntime({ transports: ['acp'], default_transport: 'acp', effective_transport: 'acp', acp_adapter: kiroAdapter });
  assert.deepEqual(system.transports, ['acp']);
  assert.equal(system.effective_transport, 'acp');
  assert.equal(system.acp_adapter?.runtime_kind, 'system');
  assert.equal(acpAdapterSummary(system.acp_adapter), 'ACP system CLI: outdated · Version: 3.4.0');
  const reason = (a: any) => acpDisabledReason(hubVerdict(a), a);
  assert.match(reason(system.acp_adapter), /older than the minimum supported version 3\.5\.0/);
  assert.match(reason({ ...system.acp_adapter!, state: 'missing', error: null }), /Install the CLI on the bridge host/);
  assert.equal(reason({ ...system.acp_adapter!, state: 'ready', error: null }), '');
  assert.doesNotMatch(reason({ ...system.acp_adapter!, state: 'missing_node', error: null }), /Node/);
  const h = await browser();
  try {
    const status = row({ provider: 'kiro', profile_id: 'kiro', display_name: 'Kiro', ...system });
    await h.render(React.createElement(ProviderRuntimeControl, { setup: setup({ providers: [status] }), status, onChange() {} }));
    const button = h.doc.querySelector('[data-debug-id="providers-acp-install-kiro"]');
    assert.equal(button?.textContent, 'Re-check');
    assert.match(h.doc.querySelector('select')!.title, /supports only ACP/);
    const text = h.doc.body.textContent || '';
    assert.doesNotMatch(text, /Node|Install adapter|Install runtime/);
    assert.match(text, /ACP system CLI: outdated/);
  } finally { await h.cleanup(); }
});

test('OpenCode is detect-only and exposes no PTY transport', async () => {
  const runtime = normalizeProviderRuntime({ transports: ['acp'], default_transport: 'acp', effective_transport: 'acp', acp_adapter: {
    ...adapter, provider: 'opencode', profile: 'opencode', runtime_kind: 'system', node_version: null,
    version: '1.19.5', installed: false, state: 'outdated', error: null,
  } });
  const h = await browser();
  try {
    const status = row({ provider: 'opencode', profile_id: 'opencode', display_name: 'OpenCode', acp_runtime_kind: 'system', ...runtime });
    await h.render(React.createElement(ProviderRuntimeControl, { setup: setup({ providers: [status] }), status, onChange() {} }));
    assert.equal(h.doc.querySelector('[data-debug-id="providers-acp-install-opencode"]')?.textContent, 'Re-check');
    assert.deepEqual(Array.from(h.doc.querySelectorAll('select option')).map(option => (option as HTMLOptionElement).value), ['acp']);
    const unchecked = { ...status, acp_adapter: null };
    await h.render(React.createElement(ProviderRuntimeControl, { setup: setup({ providers: [unchecked] }), status: unchecked, onChange() {} }));
    assert.equal(h.doc.querySelector('[data-debug-id="providers-acp-install-opencode"]')?.textContent, 'Re-check');
    // The wording follows descriptor data, never the provider id (G9).
    const adapterKind = { ...unchecked, acp_runtime_kind: 'adapter' };
    await h.render(React.createElement(ProviderRuntimeControl, { setup: setup({ providers: [adapterKind] }), status: adapterKind, onChange() {} }));
    assert.equal(h.doc.querySelector('[data-debug-id="providers-acp-install-opencode"]')?.textContent, 'Install adapter');

  } finally { await h.cleanup(); }
});

test('Codex app-server is an opt-in system runtime with PTY reset and Re-check', async () => {
  const runtime = normalizeProviderRuntime({ transports: ['pty', 'acp'], default_transport: 'pty', effective_transport: 'pty', acp_adapter: {
    ...adapter, provider: 'codex', profile: 'codex', runtime_kind: 'system', protocol: 'codex_app_server', version: '0.162.0', node_version: null,
    state: 'error', error: 'ACP initialize probe is required for the selected profile; use Re-check',
  } });
  assert.equal(runtime.effective_transport, 'pty');
  assert.equal(acpAdapterSummary(runtime.acp_adapter), 'App-server runtime: error · Version: 0.162.0');
  // The label follows the reported protocol, not the provider id.
  assert.equal(acpAdapterSummary({ ...runtime.acp_adapter!, protocol: 'acp' }), 'ACP system CLI: error · Version: 0.162.0');
  const h = await browser();
  const oldInstall = providerSetupApi.installAdapter;
  const oldSet = providerSetupApi.setTransport;
  const oldGet = providerSetupApi.get;
  const calls: unknown[][] = [];
  try {
    let status = row({ provider: 'codex', profile_id: 'codex', display_name: 'Codex', ...runtime });
    const data = setup({ providers: [status] });
    providerSetupApi.installAdapter = async (_setup, provider) => {
      calls.push(['check', provider]);
      return { command_id: 'codex-check', state: 'installing' } as any;
    };
    providerSetupApi.get = async () => setup({ providers: [status], extension_commands: [
      { command_id: 'codex-check', provider: 'codex', kind: 'install_acp_adapter', status: 'succeeded', message: '', progress_percent: 100 },
    ] });
    await h.render(React.createElement(ProviderRuntimeControl, { setup: data, status, onChange() {} }));
    const select = h.doc.querySelector('select')!;
    assert.equal(select.value, 'pty');
    assert.equal(select.querySelector('option[value="acp"]')?.textContent, 'ACP (Codex app-server)');
    assert.equal((select.querySelector('option[value="acp"]') as HTMLOptionElement).disabled, true);
    assert.equal(h.doc.querySelector('[data-debug-id="providers-acp-install-codex"]')?.textContent, 'Re-check');
    assert.doesNotMatch(h.doc.body.textContent || '', /Node|Install adapter|Install runtime/);
    await act(async () => { (h.doc.querySelector('[data-debug-id="providers-acp-install-codex"]') as HTMLElement).click(); await tick(); });
    assert.deepEqual(calls, [['check', 'codex']]);
    status = { ...status, acp_adapter: { ...status.acp_adapter, state: 'ready', error: null }, acp_availability: hubVerdict({ state: 'ready' }) };
    providerSetupApi.setTransport = async (_setup, provider, transport) => {
      calls.push(['transport', provider, transport]);
      return setup({ providers: [{ ...status, transport, effective_transport: transport || 'pty' }] });
    };
    await h.render(React.createElement(ProviderRuntimeControl, { setup: setup({ providers: [status] }), status, onChange() {} }));
    await act(async () => {
      const ready = h.doc.querySelector('select')!;
      ready.value = 'acp'; ready.dispatchEvent(new h.dom.window.Event('change', { bubbles: true })); await tick();
    });
    status = { ...status, transport: 'acp', effective_transport: 'acp' };
    await h.render(React.createElement(ProviderRuntimeControl, { setup: setup({ providers: [status] }), status, onChange() {} }));
    await act(async () => { (h.doc.querySelector('[data-debug-id="providers-runtime-reset-codex"]') as HTMLElement).click(); await tick(); });
    assert.deepEqual(calls.slice(1), [['transport', 'codex', 'acp'], ['transport', 'codex', null]]);
  } finally {
    providerSetupApi.installAdapter = oldInstall; providerSetupApi.setTransport = oldSet; providerSetupApi.get = oldGet;
    await h.cleanup();
  }
});

test('T2: provider-status rows carry the Hub ACP availability verdict unchanged, null from an older Hub', async () => {
  const { normalizeAcpAvailability, normalizeProviderStatus } = await import('../src/ui/api/endpoints/bridgeSupport.ts');
  assert.deepEqual(normalizeAcpAvailability({ available: true, reason: 'ready', fix: null }), { available: true, reason: 'ready', fix: null });
  assert.deepEqual(normalizeAcpAvailability({ available: false, reason: 'unsupported_bridge', fix: 'update_bridge' }),
    { available: false, reason: 'unsupported_bridge', fix: 'update_bridge' });
  assert.equal(normalizeAcpAvailability(undefined), null);
  assert.equal(normalizeAcpAvailability({ available: true, reason: 'future' }), null);
  // available is only true for the ready reason; unknown fixes collapse to null.
  assert.deepEqual(normalizeAcpAvailability({ available: true, reason: 'installing', fix: 'reboot' }), { available: false, reason: 'installing', fix: null });
  const status = await normalizeProviderStatus({ bridge_id: 'b', providers: [
    { provider: 'claude', display_name: 'Claude', acp_availability: { available: false, reason: 'adapter_missing', fix: 'install_adapter' } },
    { provider: 'codex', display_name: 'Codex' },
  ] });
  assert.deepEqual(status.providers[0].acp_availability, { available: false, reason: 'adapter_missing', fix: 'install_adapter' });
  assert.equal(status.providers[1].acp_availability, null);
});
