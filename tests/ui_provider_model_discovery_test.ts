import { test } from 'node:test';
import assert from 'node:assert/strict';
import React from 'react';
import { makeVaultStore } from './helpers/vaultEndpointHarness.ts';

const { heimdallApi } = await import('../src/ui/api/heimdallApi.ts');
const { normalizeBridgeCapabilities, bridgeSupportApi } = await import('../src/ui/api/endpoints/bridgeSupport.ts');
const { providerSetupApi, refreshBridgeProviderCatalog } = await import('../src/ui/components/providers/providerSetupApi.ts');
const { normalizeModelCatalog, modelCatalogSummary } = await import('../src/ui/components/providers/modelCatalogStatus.ts');
const { resolvedFleetProviderModel } = await import('../src/ui/components/tasks/fleetSelection.ts');

const tick = () => new Promise(resolve => setTimeout(resolve, 30));
function response(data: any, status = 200): any {
  return { ok: status < 400, status, text: async () => JSON.stringify({ data }),
    json: async () => ({ data }), headers: { get: () => 'application/json' } };
}
function provider(models = ['saved-model'], metadata = {}): any {
  return { provider: 'codex', enabled: true, state: 'present', catalog_state: 'active',
    models: models.map(model_id => ({ model_id, label: model_id, state: 'active' })), ...metadata };
}

test('catalog metadata preserves empty results, old-bridge fallback and last-good failure text', () => {
  assert.match(modelCatalogSummary(normalizeModelCatalog({})), /Built-in model list/);
  assert.match(modelCatalogSummary({ models_has_snapshot: true, models_state: 'timeout' }), /keeping the last successful list/);
  assert.doesNotMatch(modelCatalogSummary({ models_has_snapshot: true, models_state: 'success' }), /Built-in|failed/);
  assert.deepEqual(resolvedFleetProviderModel({ provider: 'codex', model: 'saved-unavailable' }, [{ provider: 'codex', models: [] }]),
    { provider: 'codex', model: 'saved-unavailable' });
});

test('setup API preserves provider runtime fields and normalizes legacy rows', async () => {
  const previous = globalThis.fetch;
  const adapter = { installed: true, state: 'ready', version: '0.108.0', node_version: 'v22.0.0', error: null, checked_at: '2026-11-18T00:00:00Z' };
  globalThis.fetch = async () => response({ providers: [provider([], {
    transports: ['pty', 'acp'], default_transport: 'pty', transport: 'acp', effective_transport: 'acp', acp_adapter: adapter,
  }), { ...provider(), provider: 'claude' }] });
  try {
    const result = await providerSetupApi.discover({ bridge: { bridge_id: 'a' }, discovery: {}, providers: [] } as any);
    assert.deepEqual(result.providers[0].transports, ['pty', 'acp']);
    assert.equal(result.providers[0].transport, 'acp');
    assert.equal(result.providers[0].effective_transport, 'acp');
    assert.deepEqual(result.providers[0].acp_adapter, adapter);
    assert.deepEqual(result.providers[1].transports, ['pty']);
    assert.equal(result.providers[1].default_transport, 'pty');
    assert.equal(result.providers[1].effective_transport, 'pty');
    assert.equal(result.providers[1].transport, null);
    assert.equal(result.providers[1].acp_adapter, null);
  } finally { globalThis.fetch = previous; }
});

test('setup detection and enable changes never fetch models; explicit refresh serializes two stages without retry', async () => {
  const previous = globalThis.fetch;
  const calls: any[] = [];
  globalThis.fetch = async (_url, init: any) => { calls.push({ method: init.method, body: JSON.parse(init.body) }); return response({ providers: [provider([])] }); };
  try {
    const current: any = { bridge: { bridge_id: 'a' }, discovery: {}, providers: [provider()] };
    const detected = await providerSetupApi.discover(current);
    assert.deepEqual(calls.map(c => c.body), [{ stage: 'providers' }]);
    assert.deepEqual(detected.providers[0].models, [], 'valid empty lists never reintroduce seeds');
    await providerSetupApi.setEnabled(current, 'codex', true);
    assert.deepEqual(calls.map(c => c.body), [{ stage: 'providers' }, { enabled: true }]);
    calls.length = 0;
    await refreshBridgeProviderCatalog('a');
    assert.deepEqual(calls.map(c => c.body), [{ stage: 'providers' }, { stage: 'models' }]);
    calls.length = 0;
    globalThis.fetch = async (_url, init: any) => {
      calls.push(JSON.parse(init.body));
      if (calls.length === 2) throw new Error('offline');
      return response({});
    };
    await assert.rejects(refreshBridgeProviderCatalog('a'), /offline/);
    assert.equal(calls.length, 2, 'model failures do not retry either stage');
  } finally { globalThis.fetch = previous; }
});

test('real endpoint refresh invalidates only its bridge and retains the returned last-good list', async () => {
  const previous = globalThis.fetch;
  const store = await makeVaultStore();
  const calls: string[] = [];
  let refreshed = false;
  globalThis.fetch = async (input: any, init: any = {}) => {
    const url = new URL(String(input), 'http://localhost');
    calls.push((init.method || 'GET') + ' ' + url.pathname);
    if (init.method === 'POST') {
      if (JSON.parse(init.body).stage === 'models') refreshed = true;
      return response({ providers: [] });
    }
    const isA = url.pathname.includes('/a/');
    return response({ providers: [provider(isA ? (refreshed ? ['new-seed-absent-id'] : ['old-a']) : ['only-b'],
      { models_has_snapshot: true, models_source: 'codex_app_server', models_state: refreshed ? 'authentication_required' : 'success' })] });
  };
  const a = store.dispatch(bridgeSupportApi.endpoints.listBridgeProviders.initiate({ bridgeId: 'a' }));
  const b = store.dispatch(bridgeSupportApi.endpoints.listBridgeProviders.initiate({ bridgeId: 'b' }));
  try {
    await Promise.all([a, b]);
    assert.equal(calls.filter(c => c.startsWith('POST')).length, 0);
    await store.dispatch(bridgeSupportApi.endpoints.refreshBridgeModels.initiate({ bridgeId: 'a' })).unwrap();
    await tick();
    const select = (id: string) => bridgeSupportApi.endpoints.listBridgeProviders.select({ bridgeId: id })(store.getState()).data;
    assert.deepEqual(select('a').providers[0].models.map((m: any) => m.model_id), ['new-seed-absent-id']);
    assert.equal(select('a').providers[0].models_state, 'authentication_required');
    assert.deepEqual(select('b').providers[0].models.map((m: any) => m.model_id), ['only-b']);
    assert.equal(calls.filter(c => c === 'GET /api/v1/bridges/b/provider-status').length, 1);
  } finally { a.unsubscribe(); b.unsubscribe(); store.dispatch(heimdallApi.util.resetApiState()); globalThis.fetch = previous; }
});

test('mounted picker probes only on Refresh, preserves unavailable selections, and exposes new models', async () => {
  const { JSDOM } = await import('jsdom');
  const { Provider } = await import('react-redux');
  const { createRoot } = await import('react-dom/client');
  const { act } = await import('react');
  const { default: RuntimeConfigurationOptions } = await import('../src/ui/components/chat/RuntimeConfigurationOptions.tsx');
  const dom = new JSDOM('<!doctype html><div id="root"></div>', { url: 'http://localhost/', pretendToBeVisual: true });
  const keys = ['window', 'document', 'HTMLElement', 'Node', 'KeyboardEvent', 'MutationObserver', 'getComputedStyle', 'IS_REACT_ACT_ENVIRONMENT', 'requestAnimationFrame', 'cancelAnimationFrame'];
  const previous: any = Object.fromEntries(keys.map(k => [k, (globalThis as any)[k]]));
  Object.assign(globalThis, { window: dom.window, document: dom.window.document, HTMLElement: dom.window.HTMLElement,
    Node: dom.window.Node, KeyboardEvent: dom.window.KeyboardEvent, MutationObserver: dom.window.MutationObserver,
    getComputedStyle: dom.window.getComputedStyle.bind(dom.window), IS_REACT_ACT_ENVIRONMENT: true,
    requestAnimationFrame: (cb: any) => setTimeout(() => cb(Date.now()), 0), cancelAnimationFrame: (id: any) => clearTimeout(id) });
  (dom.window as any).matchMedia = () => ({ matches: false, addEventListener() {}, removeEventListener() {} });
  dom.window.HTMLElement.prototype.scrollIntoView = () => {};
  // React DOM was loaded by endpoint imports before the document existed and
  // therefore selects its legacy input-event adapter in this headless harness.
  (dom.window.HTMLElement.prototype as any).attachEvent = () => {};
  (dom.window.HTMLElement.prototype as any).detachEvent = () => {};
  dom.window.requestAnimationFrame = globalThis.requestAnimationFrame;
  dom.window.cancelAnimationFrame = globalThis.cancelAnimationFrame;
  const prevFetch = globalThis.fetch;
  const stages: string[] = [];
  let rows = ['saved-model'];
  let configurationWire: any;
  globalThis.fetch = async (_url, init: any = {}) => {
    if (String(_url).endsWith('/reconfigurations')) {
      configurationWire = JSON.parse(init.body);
      return response({ operation_id: 'model-op', phase: 'queued' });
    }
    if (init.method === 'POST') {
      const stage = JSON.parse(init.body).stage; stages.push(stage);
      if (stage === 'models') rows = ['new-seed-absent-id'];
    }
    return response({ providers: [provider(rows, { models_has_snapshot: true, models_state: 'success' })] });
  };
  const store = await makeVaultStore();
  const root = createRoot(dom.window.document.getElementById('root')!);
  const changes: any[] = [];
  const tree = React.createElement(Provider, { store }, React.createElement(RuntimeConfigurationOptions, {
    bridges: [{ bridge_id: 'a', status: 'online', label: 'A', runtime_connected: true }],
    selection: { bridgeId: 'a', provider: 'codex', model: 'saved-model' }, onChange: (v: any) => changes.push(v), debugPrefix: 'models',
  }));
  try {
    await act(async () => { root.render(tree); await tick(); }); await act(tick);
    assert.deepEqual(stages, []);
    const button = dom.window.document.querySelector('[data-debug-id="models-model-refresh-btn"]') as HTMLElement;
    assert.ok(button);
    await act(async () => { button.click(); await tick(); }); await act(tick);
    assert.deepEqual(stages, ['providers', 'models']);
    assert.match(dom.window.document.body.textContent || '', /Selected model is unavailable/);
    assert.deepEqual(changes, [], 'refresh cannot silently change the saved model');
    const trigger = dom.window.document.querySelector('[data-debug-id="models-model-select-codex"]') as HTMLElement;
    await act(async () => { trigger.click(); await tick(); });
    const option = dom.window.document.querySelector('[data-debug-id="models-model-select-codex-option-new-seed-absent-id"]') as HTMLElement;
    assert.ok(option, 'newly discovered model is selectable');
    await act(async () => { option.click(); await tick(); });
    assert.deepEqual(changes, [{ bridgeId: 'a', provider: 'codex', model: 'new-seed-absent-id' }]);
    const { agentsApi } = await import('../src/ui/api/endpoints/agents.ts');
    await act(async () => {
      await store.dispatch(agentsApi.endpoints.applyInstanceConfiguration.initiate({
        instanceId: 'inst-model', bridge_id: changes[0].bridgeId, project_id: '',
        provider: changes[0].provider, model: changes[0].model,
        expected_revision: 0, idempotency_key: 'model-test',
      })).unwrap();
    });
    assert.equal(configurationWire.model, 'new-seed-absent-id', 'selected ID reaches the actual reconfiguration request unchanged');
    const cached = bridgeSupportApi.endpoints.listBridgeProviders.select({ bridgeId: 'a' })(store.getState()).data;
    assert.deepEqual(cached.providers[0].models.map((m: any) => m.model_id), ['new-seed-absent-id']);
    assert.deepEqual(resolvedFleetProviderModel({ provider: 'codex', model: '' }, normalizeBridgeCapabilities(cached)),
      { provider: 'codex', provider_profile: 'codex', model: 'new-seed-absent-id' });

    // Enrollment automatically detects binaries, then waits for the explicitly
    // labelled enable-and-refresh action before requesting any model metadata.
    const { ProviderSetupSurface } = await import('../src/ui/components/providers/ProviderSetupSurface.tsx');
    const enrollmentStages: string[] = [];
    let enabled = false;
    let applied = 0;
    globalThis.fetch = async (input: any, init: any = {}) => {
      const path = new URL(String(input), 'http://localhost').pathname;
      if (path === '/api/v1/bridges') return response({ bridges: [{ bridge_id: 'c', status: 'online', label: 'C' }] });
      if (init.method === 'PUT') enabled = JSON.parse(init.body).enabled;
      if (init.method === 'POST') {
        const stage = JSON.parse(init.body).stage;
        enrollmentStages.push(stage);
        if (stage === 'models') assert.equal(enabled, true, 'enablement is saved before stage two');
      }
      return response({ providers: [{ ...provider(), enabled }] });
    };
    await act(async () => { root.render(React.createElement(Provider, { store }, React.createElement(ProviderSetupSurface, {
      bridgeId: 'c', mode: 'enrollment', variant: 'compact', onApply: () => { applied += 1; },
    }))); await tick(); });
    await act(tick);
    assert.deepEqual(enrollmentStages, ['providers'], 'enrollment mount never probes models');
    const apply = dom.window.document.querySelector('[data-debug-id="provider-setup-apply-btn"]') as HTMLElement;
    assert.match(apply.textContent || '', /refresh models/);
    await act(async () => { apply.click(); await tick(); }); await act(tick);
    assert.deepEqual(enrollmentStages, ['providers', 'models']);
    assert.equal(applied, 1);
  } finally {
    await act(async () => root.unmount());
    store.dispatch(heimdallApi.util.resetApiState());
    // RTK batches subscription synchronization on a 500ms timer, even after unmount.
    // Drain it before restoring the browser globals its notifier captured.
    await act(async () => { await new Promise(resolve => setTimeout(resolve, 600)); });
    globalThis.fetch = prevFetch;
    for (const k of keys) (globalThis as any)[k] = previous[k];
    dom.window.close();
  }
});

test('setup and picker subscriptions share one full status read per bridge and preserve profile identity', async () => {
  const { setupHeimdallApiListeners } = await import('../src/ui/api/heimdallApi.ts');
  const { selectBridgeProvider, selectLaunchableProviderCapabilities } = await import('../src/ui/api/endpoints/bridgeSupport.ts');
  const { modelOptionsForProvider } = await import('../src/ui/components/tasks/fleetSelection.ts');
  const previous = globalThis.fetch;
  const store = await makeVaultStore();
  setupHeimdallApiListeners(store.dispatch);
  const calls: string[] = [];
  let enabled = true;
  const model = (id: string, state = 'active') => ({ model_id: id, label: id, state, resolved_model: 'resolved-' + id, extra: 42 });
  const rows = (bridge: string) => [
    provider([], { profile_id: 'codex', enabled, binary_path: '/bin/codex', models: [model(bridge + '-default'), model('old', 'deprecated'), model('unknown', 'future')] }),
    provider([], { profile_id: 'work', models: [model(bridge + '-work')], acp_adapter: { installed: true, state: 'ready' } }),
    provider([], { profile_id: 'disabled', enabled: false }),
    provider([], { profile_id: 'absent', state: 'absent' }),
    provider([], { profile_id: 'deprecated', catalog_state: 'deprecated' }),
    provider([], { profile_id: 'unknown', catalog_state: 'future' }),
  ];
  globalThis.fetch = async (input: any, init: any = {}) => {
    const path = new URL(String(input), 'https://hub.test').pathname;
    calls.push((init.method || 'GET') + ' ' + path);
    if (path.endsWith('/bridges')) return response({ bridges: ['a', 'b'].map(bridge_id => ({ bridge_id, status: 'online' })) });
    if (init.method === 'PUT') { enabled = JSON.parse(init.body).enabled; return response({}); }
    const id = path.includes('/a/') ? 'a' : 'b';
    return response({ bridge_id: id, providers: rows(id), acp_runtime_supported: true, extension_commands: [], extra: 'retained' });
  };
  const a = store.dispatch(bridgeSupportApi.endpoints.listBridgeProviders.initiate({ bridgeId: 'a' }));
  const b = store.dispatch(bridgeSupportApi.endpoints.listBridgeProviders.initiate({ bridgeId: 'b' }));
  try {
    const [settingsA, settingsB, statusA, statusB] = await Promise.all([
      providerSetupApi.get('a', true), providerSetupApi.get('b', true), a.unwrap(), b.unwrap(),
    ]);
    const count = (id: string) => calls.filter(c => c === 'GET /api/v1/bridges/' + id + '/provider-status').length;
    assert.equal(count('a'), 1);
    assert.equal(count('b'), 1);
    assert.equal(settingsA.providers.length, 6, 'Settings retains disabled, absent and deprecated profiles');
    assert.equal(settingsB.providers.length, 6);
    assert.equal(statusA.extra, 'retained');
    assert.equal(statusA.providers[0].models.length, 3, 'deprecated models remain in the full cache');
    assert.equal(statusA.providers[0].models[0].extra, 42);
    assert.equal(settingsA.providers[0].binary_path, '/bin/codex');
    const launchA = selectLaunchableProviderCapabilities(statusA);
    assert.deepEqual(launchA.map(p => p.profile_id), ['codex', 'work']);
    assert.deepEqual(modelOptionsForProvider(launchA, 'codex', 'work'), ['a-work']);
    assert.deepEqual(modelOptionsForProvider(launchA, 'codex'), ['a-default']);
    assert.deepEqual(selectBridgeProvider(statusB, 'codex', 'work').models.map((m: any) => m.model_id), ['b-work']);
    assert.equal(selectBridgeProvider(statusA, 'codex', 'missing'), undefined);
    await providerSetupApi.get('a', true);
    assert.equal(count('a'), 1, 'repeat Settings read reuses picker cache');
    // Mount the real Settings surface: its extension child must reuse the read
    // already held by the picker, rather than force another GET on mount.
    const { JSDOM } = await import('jsdom');
    const { Provider } = await import('react-redux');
    const { createRoot } = await import('react-dom/client');
    const { act } = await import('react');
    const { ProviderSetupSurface } = await import('../src/ui/components/providers/ProviderSetupSurface.tsx');
    const dom = new JSDOM('<div id="root"></div>', { url: 'http://localhost/', pretendToBeVisual: true });
    const keys = ['window', 'document', 'HTMLElement', 'Node', 'IS_REACT_ACT_ENVIRONMENT'];
    const saved = keys.map(k => [k, Object.getOwnPropertyDescriptor(globalThis, k)] as const);
    Object.assign(globalThis, { window: dom.window, document: dom.window.document, HTMLElement: dom.window.HTMLElement, Node: dom.window.Node, IS_REACT_ACT_ENVIRONMENT: true });
    const root = createRoot(dom.window.document.getElementById('root')!);
    try {
      await act(async () => { root.render(React.createElement(Provider, { store }, React.createElement(ProviderSetupSurface, { bridgeId: 'a', mode: 'settings' }))); await tick(); });
      await act(tick);
      assert.ok(dom.window.document.querySelector('[data-debug-id="provider-setup-card-codex"]'));
      assert.equal(count('a'), 1, 'mounted Settings and extension controls share the picker status read');
    } finally {
      await act(async () => root.unmount());
      dom.window.close();
      for (const [key, descriptor] of saved) { if (descriptor) Object.defineProperty(globalThis, key, descriptor); else delete (globalThis as any)[key]; }
    }

    await providerSetupApi.setEnabled(settingsA, 'codex', false);
    await tick();
    const next = await providerSetupApi.get('a', true);
    assert.equal(next.providers[0].enabled, false);
    assert.equal(count('a'), 2, 'enable change refreshes the shared cache once');
    assert.equal(count('b'), 1, 'other bridge remains cached');
    assert.deepEqual(selectLaunchableProviderCapabilities({ providers: next.providers }).map(p => p.profile_id), ['work']);
    assert.equal(calls.some(c => c.startsWith('POST')), false, 'reading and enabling never probes');
  } finally {
    a.unsubscribe(); b.unsubscribe();
    store.dispatch(heimdallApi.util.resetApiState());
    globalThis.fetch = previous;
  }
});
