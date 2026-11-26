import { test } from 'node:test';
import assert from 'node:assert/strict';
import React from 'react';
import { makeVaultStore } from './helpers/vaultEndpointHarness.ts';
import { fleetApplyInput, fleetDraftKey, validFleetDraft, fleetExcludedCounts } from '../src/ui/components/home/fleetDraft.ts';

test('Fleet drafts preserve profile and durable agent identity, canonical override order and removal', () => {
  const runtime = { provider: 'codex', provider_profile: 'work', model: 'm' };
  const draft = { bridge_id: 'b', revision: 4, default_runtime: runtime, overrides: [{ agent_id: 'a', runtime }, { agent_id: 'b', runtime }] };
  assert.equal(fleetDraftKey(draft), fleetDraftKey({ ...draft, overrides: [...draft.overrides].reverse() }));
  assert.notEqual(fleetDraftKey(draft), fleetDraftKey({ ...draft, default_runtime: { ...runtime, provider_profile: 'personal' } }));
  assert.equal(validFleetDraft(draft, [{ provider: 'codex', profile_id: 'work', models: ['m'] }]), true);
  assert.equal(validFleetDraft({ ...draft, overrides: [draft.overrides[0], draft.overrides[0]] }, [{ provider: 'codex', profile_id: 'work', models: ['m'] }]), false);
  assert.deepEqual(fleetApplyInput({ ...draft, overrides: [] }, 'request'), { request_id: 'request', expected_revision: 4, default_runtime: runtime, overrides: [] });
});

test('Chain staffing mutations omit runtime policy and preserve explicit legacy clears', async () => {
  const { taskChainsApi } = await import('../src/ui/api/endpoints/taskChains.ts');
  const { heimdallApi } = await import('../src/ui/api/heimdallApi.ts');
  const store = await makeVaultStore();
  const oldFetch = globalThis.fetch;
  const requests: { path: string; method: string; rawBody: unknown; body: any }[] = [];
  globalThis.fetch = async (input: any, init?: RequestInit) => {
    const body = JSON.parse(String(init?.body || '{}'));
    requests.push({ path: String(input), method: String(init?.method || 'GET'), rawBody: init?.body, body });
    return new Response(JSON.stringify({ data: { agent_id: 'a', capacity: body.capacity || 2, paused: true } }), { status: 200 });
  };
  try {
    await store.dispatch(taskChainsApi.endpoints.updateTaskChainFleet.initiate({ chainId: 'chain', agentId: 'a', capacity: 2, minWarm: 1, idleTtlSeconds: 600, bridgeId: 'b' })).unwrap();
    assert.deepEqual(requests[0].body, { capacity: 2, min_warm: 1, idle_ttl_seconds: 600, bridge_id: 'b' });
    await store.dispatch(taskChainsApi.endpoints.updateTaskChainFleet.initiate({ chainId: 'chain', agentId: 'a', capacity: 2, provider: '', model: '' })).unwrap();
    assert.deepEqual(requests[1].body, { capacity: 2, provider: '', model: '' });
    // REQ-SCHED-2: pause and resume take no body; the whole row is paused.
    const paused = await store.dispatch(taskChainsApi.endpoints.setTaskChainStaffingPaused.initiate({ chainId: 'chain', agentId: 'a', paused: true })).unwrap();
    assert.match(requests[2].path, /\/fleets\/a\/pause$/);
    assert.equal(requests[2].rawBody, undefined);
    assert.equal(paused.paused, true);
    await store.dispatch(taskChainsApi.endpoints.setTaskChainStaffingPaused.initiate({ chainId: 'chain', agentId: 'a', paused: false })).unwrap();
    assert.match(requests[3].path, /\/fleets\/a\/resume$/);
    assert.equal(requests[3].rawBody, undefined);
    // REQ-SCHED-34: chain caps go to the chain PATCH, only the keys given.
    await store.dispatch(taskChainsApi.endpoints.updateTaskChainCaps.initiate({ chainId: 'chain', maxParallel: 4, reviewReserve: 2 })).unwrap();
    assert.match(requests[4].path, /\/task-chains\/chain$/);
    assert.equal(requests[4].method, 'PATCH');
    assert.deepEqual(requests[4].body, { max_parallel: 4, review_reserve: 2 });
    await store.dispatch(taskChainsApi.endpoints.updateTaskChainCaps.initiate({ chainId: 'chain', maxParallel: 0 })).unwrap();
    assert.deepEqual(requests[5].body, { max_parallel: 0 });
    for (const r of requests) assert.equal('roles' in r.body, false);
  } finally { store.dispatch(heimdallApi.util.resetApiState()); globalThis.fetch = oldFetch; }
});

test('chain caps follow the hub rule: 0 is unlimited, otherwise M >= 2 and 1 <= r <= M - 1', async () => {
  const { chainCapsError, readChainCaps } = await import('../src/ui/api/endpoints/taskChains.ts');
  assert.equal(chainCapsError({ maxParallel: 0, reviewReserve: 0 }), '');
  assert.equal(chainCapsError({ maxParallel: 3, reviewReserve: 1 }), '');
  assert.equal(chainCapsError({ maxParallel: 4, reviewReserve: 3 }), '');
  assert.notEqual(chainCapsError({ maxParallel: 1, reviewReserve: 0 }), '');
  assert.notEqual(chainCapsError({ maxParallel: 3, reviewReserve: 0 }), '');
  assert.notEqual(chainCapsError({ maxParallel: 3, reviewReserve: 3 }), '');
  assert.notEqual(chainCapsError({ maxParallel: 0, reviewReserve: 1 }), '');
  assert.notEqual(chainCapsError({ maxParallel: 2.5, reviewReserve: 1 }), '');
  assert.deepEqual(readChainCaps({ max_parallel: 3, review_reserve: 1 }), { maxParallel: 3, reviewReserve: 1 });
  assert.deepEqual(readChainCaps({}), { maxParallel: 0, reviewReserve: 0 });
});

test('Live Fleet: stale previews, conflict preservation, duplicate/lost Apply, retry and scoped WS freshness', async () => {
  const { JSDOM } = await import('jsdom');
  const dom = new JSDOM('<!doctype html><div id="root"></div>', { url: 'http://localhost/' });
  const win = dom.window as any;
  win.matchMedia = () => ({ matches: false, addEventListener() {}, removeEventListener() {} });
  win.HTMLElement.prototype.scrollIntoView = function () {};
  win.CSS = { escape: (value: string) => value.replace(/[^a-zA-Z0-9_-]/g, (char: string) => String.fromCharCode(92) + char) };
  const keys = ['window', 'document', 'HTMLElement', 'Node', 'KeyboardEvent', 'MouseEvent', 'localStorage', 'CSS'] as const;
  const saved = new Map(keys.map((key) => [key, (globalThis as any)[key]]));
  const savedFetch = globalThis.fetch;
  const savedAct = (globalThis as any).IS_REACT_ACT_ENVIRONMENT;
  for (const key of keys) (globalThis as any)[key] = key === 'window' ? win : key === 'document' ? win.document : win[key];
  (globalThis as any).IS_REACT_ACT_ENVIRONMENT = true;
  const runtime = (model: string) => ({ provider: 'codex', provider_profile: 'work', model });
  let settings = { bridge_id: 'b1', revision: 1, default_runtime: runtime('m1'), overrides: [{ agent_id: 'a', runtime: runtime('m2') }] };
  let application: any;
  const calls: { path: string; body: any }[] = [];
  let holdPreview = true;
  let instanceListFails = false;
  const previews: { body: any; resolve: (response: Response) => void }[] = [];
  let applyMode: 'conflict' | 'lost' | 'success' = 'conflict';
  const response = (data: any, status = 200) => new Response(JSON.stringify({ data }), { status });
  globalThis.fetch = async (input: any, init?: RequestInit) => {
    const path = new URL(String(input?.url ?? input), 'http://localhost').pathname;
    const body = init?.body ? JSON.parse(String(init.body)) : undefined;
    calls.push({ path, body });
    if (path === '/api/v1/bridges') return response([{ bridge_id: 'b1', label: 'First bridge', status: 'online', machine_os: 'Linux' }, { bridge_id: 'b2', label: 'Unavailable bridge', status: 'offline' }]);
    if (path === '/api/v1/agents') return response([{ agent_id: 'a', name: 'Same name', state: 'active' }, { agent_id: 'b', name: 'Same name', state: 'active' }]);
    if (path === '/api/v1/agent-instances') {
      if (instanceListFails) return new Response(JSON.stringify({ error: { message: 'Instance view unavailable' } }), { status: 503 });
      assert.equal(new URL(String(input?.url ?? input), 'http://localhost').searchParams.get('bridge_id'), 'b1');
      return response([
        { agent_instance_id: 'i-ready', bridge_id: 'b1', agent_id: 'a', runtime_status: 'running', ...runtime('m2') },
        { agent_instance_id: 'i-matches', bridge_id: 'b1', agent_id: 'a', runtime_status: 'running', ...runtime('m2') },
        { agent_instance_id: 'i-stopped', bridge_id: 'b1', agent_id: 'b', runtime_status: 'stopped', ...runtime('m2') },
        { agent_instance_id: 'i-other', bridge_id: 'b1', agent_id: 'b', runtime_status: 'running', ...runtime('m1') },
      ]);
    }
    if (path.endsWith('/fleets')) return response([]);
    if (path.includes('/b2/')) return new Response(JSON.stringify({ error: { message: 'Bridge choices unavailable' } }), { status: 503 });
    if (path.endsWith('/provider-status')) return response({ providers: [{ provider: 'codex', profile_id: 'work', label: 'Work', enabled: true, state: 'present', catalog_state: 'active', models: [{ model_id: 'm1', state: 'active' }, { model_id: 'm2', state: 'active' }] }] });
    if (path.endsWith('/launch-defaults')) return response(settings);
    if (path.endsWith('/fleet/preview')) {
      if (holdPreview) return new Promise<Response>((resolve) => previews.push({ body, resolve }));
      return response({ bridge_id: 'b1', expected_revision: body.expected_revision, affected_instances: 1 });
    }
    if (path.endsWith('/fleet/apply')) {
      if (applyMode === 'conflict') {
        settings = { ...settings, revision: 2 };
        return new Response(JSON.stringify({ error: { message: 'Fleet settings revision changed', details: { code: 'fleet_revision_conflict' } } }), { status: 409 });
      }
      settings = { ...settings, revision: 3, default_runtime: body.default_runtime, overrides: body.overrides };
      application = { application_id: 'app', bridge_id: 'b1', request_id: body.request_id, settings_revision: 3, revision: 1, settings_saved: true, cancelled: false, state: 'partial_failure', targets: [
        { agent_instance_id: 'i-ready', agent_id: 'a', state: 'ready', retryable: false },
        { agent_instance_id: 'i-accepted', agent_id: 'a', state: 'restarting', retryable: false },
        { agent_instance_id: 'i-pending', agent_id: 'a', state: 'pending', retryable: false },
        { agent_instance_id: 'i-failed', agent_id: 'b', state: 'failed', error_message: 'Bridge offline', retryable: true },
      ] };
      if (applyMode === 'lost') { applyMode = 'success'; throw new TypeError('Network response lost'); }
      return response(application, 202);
    }
    if (path.endsWith('/retry')) {
      application = { ...application, revision: 2, state: 'restarting', targets: application.targets.map((t: any) => t.state === 'failed' ? { ...t, state: 'restarting', error_message: '' } : t) };
      return response(application, 202);
    }
    if (path.includes('/applications/')) return response(application);
    throw new Error('Unexpected request: ' + path);
  };
  const { act } = await import('react');
  const { createRoot } = await import('react-dom/client');
  const { Provider } = await import('react-redux');
  const { FleetWidget } = await import('../src/ui/components/home/FleetWidget.tsx');
  const { heimdallApi } = await import('../src/ui/api/heimdallApi.ts');
  const { handleUserWsEvent, flushQueuedInvalidations, resetQueuedInvalidations } = await import('../src/ui/api/wsInvalidation.ts');
  const { taskChainsApi } = await import('../src/ui/api/endpoints/taskChains.ts');
  const store = await makeVaultStore();
  const root = createRoot(win.document.getElementById('root'));
  const get = (id: string) => win.document.querySelector('[data-debug-id="' + id + '"]') as HTMLElement;
  const settle = async () => act(async () => { await new Promise((resolve) => setTimeout(resolve, 150)); });
  const click = async (id: string) => { assert.ok(get(id), id); await act(async () => get(id).click()); await settle(); };
  const choose = async (id: string, label: string) => {
    await click(id);
    const option = [...win.document.querySelectorAll('[role="option"]')].find((o: any) => o.textContent === label) as HTMLElement;
    assert.ok(option, label); await act(async () => option.click()); await settle();
  };
  const countCalls = (suffix: string) => calls.filter((c) => c.path.endsWith(suffix)).length;
  try {
    await act(async () => root.render(React.createElement(Provider, { store }, React.createElement(FleetWidget))));
    // Provider-status normalization and the shared identity query complete
    // asynchronously; wait for both bridges rather than one fixed 150ms tick.
    for (let attempt = 0; attempt < 20; attempt += 1) {
      await settle();
      if (get('home-fleet-apply-b1') && /Could not load settings/.test(get('home-widget-fleet').textContent || '')) break;
    }
    assert.match(get('home-widget-fleet').textContent!, /First bridge/);
    assert.match(get('home-widget-fleet').textContent!, /Could not load settings/);
    assert.equal(countCalls('/agents'), 1, 'all bridges share the owner identity query');
    assert.equal((get('home-fleet-apply-b1') as HTMLButtonElement).disabled, true);
    assert.match(get('home-fleet-scope-b1').textContent!, /Checking/);
    await choose('home-fleet-default-b1-model', 'm2');
    assert.equal(previews.length, 2);
    await act(async () => previews[1].resolve(response({ bridge_id: 'b1', expected_revision: 1, affected_instances: 0 })));
    await settle();
    assert.match(get('home-fleet-scope-b1').textContent!, /0 running/);
    await act(async () => previews[0].resolve(response({ bridge_id: 'b1', expected_revision: 1, affected_instances: 99 })));
    await settle();
    assert.doesNotMatch(get('home-fleet-scope-b1').textContent!, /99/);
    holdPreview = false;
    await click('home-fleet-apply-b1');
    assert.match(get('home-fleet-error-b1').textContent!, /revision changed/);
    assert.match(get('home-fleet-default-b1-model').textContent!, /m2/, 'conflict keeps draft');
    assert.match(get('home-fleet-conflict-b1').textContent!, /Reset/);
    const conflictCalls = calls.length;
    await click('home-fleet-expand-b1');
    assert.equal(get('home-fleet-body-b1').getAttribute('aria-hidden'), 'true');
    await click('home-fleet-expand-b1');
    assert.match(get('home-fleet-default-b1-model').textContent!, /m2/);
    assert.match(get('home-fleet-error-b1').textContent!, /revision changed/);
    assert.match(get('home-fleet-conflict-b1').textContent!, /Reset/);
    assert.equal(calls.length, conflictCalls, 'disclosure preserves preview subscription and never mutates settings');
    await click('home-fleet-reset-b1');
    assert.match(get('home-fleet-default-b1-model').textContent!, /m1/);
    await choose('home-fleet-default-b1-model', 'm2');
    applyMode = 'lost';
    const before = countCalls('/fleet/apply');
    await act(async () => { get('home-fleet-apply-b1').click(); get('home-fleet-apply-b1').click(); });
    await settle();
    assert.equal(countCalls('/fleet/apply'), before + 1, 'rapid double-click sends once');
    assert.match(get('home-fleet-scope-b1').textContent!, /unknown/);
    const lost = calls.filter((c) => c.path.endsWith('/fleet/apply')).at(-1)!.body;
    await click('home-fleet-apply-b1');
    assert.deepEqual(calls.filter((c) => c.path.endsWith('/fleet/apply')).at(-1)!.body, lost, 'recovery replays exact request ID/revision/draft');
    assert.match(get('home-fleet-result-b1').textContent!, /Settings saved.*Some agents could not restart/s);
    assert.match(get('home-fleet-target-i-failed').textContent!, /Bridge offline/);
    assert.match(get('home-fleet-target-i-accepted').textContent!, /restarting/);
    assert.match(get('home-fleet-target-i-pending').textContent!, /pending/);
    assert.match(get('home-fleet-excluded-b1').textContent!, /applied revision 3: 1 match applied settings.*1 not running.*1 other excluded/);
    assert.match(get('home-fleet-excluded-b1').textContent!, /not saved server outcomes/);
    // Settings move on after the Apply: counts stay pinned to the revision the
    // application saved (the snapshot recorded at Apply), not current settings.
    settings = { ...settings, revision: 4, default_runtime: runtime('m3'), overrides: [{ agent_id: 'a', runtime: runtime('m3') }] };
    await act(async () => {
      handleUserWsEvent(store.dispatch, { type: 'resource_changed', resource: 'bridge_fleet_settings', resource_id: 'b1', summary: { bridge_id: 'b1', revision: 4 } }, {});
      flushQueuedInvalidations();
    });
    await settle();
    assert.match(get('home-fleet-excluded-b1').textContent!, /applied revision 3: 1 match applied settings.*1 not running.*1 other excluded/);
    assert.doesNotMatch(get('home-fleet-excluded-b1').textContent!, /current settings/);
    assert.match(get('home-fleet-result-b1').textContent!, /1 ready.*1 pending.*1 restarting.*1 failed/);
    assert.doesNotMatch(get('home-fleet-result-b1').textContent!, /All affected agents ready/,
      'HTTP 202 and an accepted restart do not establish runtime readiness');
    instanceListFails = true;
    await click('home-fleet-retry-b1');
    assert.equal(countCalls('/applications/app/retry'), 1);
    assert.match(get('home-fleet-target-i-ready').textContent!, /ready/);
    assert.match(get('home-fleet-excluded-unavailable-b1').textContent!, /Client excluded counts unavailable/);
    assert.equal(get('home-fleet-excluded-b1'), null, 'failed refresh does not label cached counts as current');
    await click('home-fleet-expand-b1');
    assert.equal(get('home-fleet-body-b1').hasAttribute('inert'), true);
    const reads = countCalls('/launch-defaults'), previewReads = countCalls('/fleet/preview');
    await act(async () => handleUserWsEvent(store.dispatch, { type: 'resource_changed', resource: 'agent_instance', resource_id: 'i-failed', change: 'status_changed', summary: { bridge_id: 'b1', runtime_status: 'running' } }, {}));
    await settle();
    assert.equal(countCalls('/launch-defaults'), reads);
    assert.equal(countCalls('/fleet/preview'), previewReads, 'startup causes no Fleet reads');
    application = { ...application, revision: 3, state: 'ready', targets: application.targets.map((t: any) => ({ ...t, state: 'ready' })) };
    await act(async () => {
      handleUserWsEvent(store.dispatch, { type: 'resource_changed', resource: 'bridge_fleet_application', resource_id: 'app', summary: application }, {});
      flushQueuedInvalidations();
    });
    await settle();
    assert.equal(get('home-fleet-expand-b1').getAttribute('aria-expanded'), 'false', 'live results update without opening the panel');
    await click('home-fleet-expand-b1');
    assert.match(get('home-fleet-result-b1').textContent!, /All affected agents ready/);
    assert.equal(countCalls('/launch-defaults'), reads, 'application progress does not reload settings');
    assert.equal(countCalls('/fleet/preview'), previewReads, 'ready event does not refetch preview');
    const chains = ['chain-one', 'chain-two'].map((chainId) => store.dispatch(taskChainsApi.endpoints.getTaskChainFleets.initiate({ chainId })));
    await act(async () => { await Promise.all(chains); });
    const fleetReads = countCalls('/fleets');
    await act(async () => {
      handleUserWsEvent(store.dispatch, { type: 'resource_changed', resource: 'bridge_fleet_settings', resource_id: 'b1', summary: { bridge_id: 'b1', revision: 3 } }, {});
      flushQueuedInvalidations();
    });
    await settle();
    assert.equal(countCalls('/fleets'), fleetReads + 2, 'settings refresh all chain-keyed effective placements');
    chains.forEach((query) => query.unsubscribe());
    // Same display labels remain distinct stable IDs, with duplicates omitted.
    await click('home-fleet-add-override-b1');
    const agentControl = get('home-fleet-override-b1-b-agent');
    assert.ok(agentControl);
    await click('home-fleet-override-b1-b-agent');
    assert.equal(win.document.querySelectorAll('[role="option"]').length, 1);
    await act(async () => win.document.dispatchEvent(new win.KeyboardEvent('keydown', { key: 'Escape', bubbles: true })));
    await settle();
    const sent = lost.overrides[0];
    assert.equal(sent.agent_id, 'a'); assert.equal(sent.runtime.provider_profile, 'work');
  } finally {
    for (const p of previews) p.resolve(response({ bridge_id: 'b1', expected_revision: 1, affected_instances: 0 }));
    await act(async () => root.unmount());
    store.dispatch(heimdallApi.util.resetApiState());
    resetQueuedInvalidations();
    dom.window.close();
    for (const [key, value] of saved) (globalThis as any)[key] = value;
    globalThis.fetch = savedFetch;
    (globalThis as any).IS_REACT_ACT_ENVIRONMENT = savedAct;
  }
});

test('Client excluded counts use loaded bridge instances, deduplicate and never reclassify server targets', () => {
  const saved = { provider: 'codex', provider_profile: 'work', model: 'm2' };
  const settings = { bridge_id: 'b1', revision: 1, default_runtime: saved,
    overrides: [{ agent_id: 'a', runtime: { ...saved, model: 'override' } }] };
  const application = { bridge_id: 'b1', targets: [{ agent_instance_id: 'target' }] } as any;
  const base = { bridge_id: 'b1', agent_id: 'b', runtime_status: 'running', ...saved };
  assert.deepEqual(fleetExcludedCounts([
    { ...base, agent_instance_id: 'target' },
    { ...base, agent_instance_id: 'match' },
    { ...base, agent_instance_id: 'match' },
    { ...base, agent_instance_id: 'stopped', runtime_status: 'stopped' },
    { ...base, agent_instance_id: 'override', agent_id: 'a', model: 'override' },
    { ...base, agent_instance_id: 'profile-mismatch', provider_profile: 'personal' },
    { ...base, agent_instance_id: 'different-bridge', bridge_id: 'b2' },
  ], settings, application), { unchanged: 2, notRunning: 1, other: 1, basis: 'current', revision: 1 });
  assert.deepEqual(application.targets, [{ agent_instance_id: 'target' }]);
});

test('Client excluded counts compare with the applied settings revision, or label current settings', () => {
  const runtime = (model: string) => ({ provider: 'codex', provider_profile: 'work', model });
  const applied = { revision: 3, default_runtime: runtime('m2'), overrides: [] };
  const current = { bridge_id: 'b1', revision: 4, default_runtime: runtime('m3'), overrides: [] };
  const application = { bridge_id: 'b1', settings_revision: 3, targets: [] } as any;
  const instances = [
    { agent_instance_id: 'old', bridge_id: 'b1', agent_id: 'a', runtime_status: 'running', ...runtime('m2') },
    { agent_instance_id: 'new', bridge_id: 'b1', agent_id: 'a', runtime_status: 'running', ...runtime('m3') },
    { agent_instance_id: 'other', bridge_id: 'b1', agent_id: 'a', runtime_status: 'running', ...runtime('m1') },
  ];
  // Snapshot recorded at Apply wins over newer current settings.
  assert.deepEqual(fleetExcludedCounts(instances, current, application, applied),
    { unchanged: 1, notRunning: 0, other: 2, basis: 'applied', revision: 3 });
  // Current settings still at the applied revision count as applied.
  assert.deepEqual(fleetExcludedCounts(instances, { ...current, revision: 3 }, application),
    { unchanged: 1, notRunning: 0, other: 2, basis: 'applied', revision: 3 });
  // A snapshot of another revision is ignored; without the applied revision the
  // counts compare with current settings and say so.
  assert.deepEqual(fleetExcludedCounts(instances, current, application, { ...applied, revision: 2 }),
    { unchanged: 1, notRunning: 0, other: 2, basis: 'current', revision: 4 });
});
