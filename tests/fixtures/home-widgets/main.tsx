import React, { useState } from 'react';
import { createRoot } from 'react-dom/client';
import { Provider } from 'react-redux';
import { configureStore } from '@reduxjs/toolkit';
import { heimdallApi } from '../../../src/ui/api/heimdallApi';
import vault from '../../../src/ui/store/vaultSlice';
import HomePage, { HomeDashboard } from '../../../src/ui/components/home/HomePage';
import { AuthUserProvider } from '../../../src/ui/components/auth/AuthUserContext';
import ActivityWidget from '../../../src/ui/components/home/ActivityWidget';
import TaskChainsWidget from '../../../src/ui/components/home/TaskChainsWidget';
import UptimeWidget from '../../../src/ui/components/home/UptimeWidget';
import FleetWidget from '../../../src/ui/components/home/FleetWidget';
import { HomeSelect } from '../../../src/ui/components/home/HomeSelect';
import { fleetFixture, mockActivity, MOCK_PROVIDERS, chainsFixture, chainDetailFixture } from '../../../src/ui/components/home/homeWidgetFixtures';
import { summarizeActivity, fleetFromWire } from '../../../src/ui/components/home/widgetData';
import { setExpectedUserId } from '../../../src/ui/utils/expectedUser';
import '../../../src/ui/styles.css';

const store = configureStore({ reducer: { vault, [heimdallApi.reducerPath]: heimdallApi.reducer }, middleware: (getDefault) => getDefault({ serializableCheck: false }).concat(heimdallApi.middleware) });
const params = new URLSearchParams(location.search);
// Isolated API boundary: screenshots exercise the production Fleet/chain UI without
// contacting a Hub or restarting a live instance.
const fixtureFleet = fleetFromWire(fleetFixture());
const fleetState = params.get('fleet-state') || 'normal';
setExpectedUserId('home-visual-fixture');
for (const bridge of fixtureFleet) {
  sessionStorage.removeItem(`heimdall:fleet:home-visual-fixture:${bridge.id}`);
}
if (fleetState === 'applying' || fleetState === 'partial-failure' || fleetState === 'status-error') {
  sessionStorage.setItem('heimdall:fleet:home-visual-fixture:mock-bridge-0', JSON.stringify({ applicationId: 'fixture-application' }));
}
const nativeFetch = window.fetch.bind(window);
const fixtureRequests: { path: string; method: string }[] = [];
(window as any).__fleetFixtureRequests = fixtureRequests;
window.fetch = async (input, init) => {
  const url = new URL(String(input instanceof Request ? input.url : input), location.href);
  if (!url.pathname.startsWith('/api/v1/')) return nativeFetch(input, init);
  const path = url.pathname;
  fixtureRequests.push({ path, method: init?.method || (input instanceof Request ? input.method : 'GET') });
  const bridge = fixtureFleet.find((b) => path.includes('/' + b.id + '/')) || fixtureFleet[0];
  let data: any;
  if (path === '/api/v1/task-chains') data = [0, 1, 2].flatMap((page) => chainsFixture(page).chains);
  else if (path.startsWith('/api/v1/task-chains/')) {
    const id = decodeURIComponent(path.split('/')[4]);
    const detail = chainDetailFixture(id);
    data = { ...detail, members: detail.members.map((member) => ({ ...member, agent_instance_id: 'fixture-coordinator-' + id })), tasks: detail.tasks.map((task, i) => ({ ...task, task_id: id + '-task-' + i, chain_id: id })) };
  }
  else if (path === '/api/v1/bridges') data = fleetFixture().bridges;
  else if (path === '/api/v1/agents') data = [...new Map(fixtureFleet.flatMap((b) => b.availableAgents || []).map((a) => [a.agent_id, { ...a, state: 'active' }])).values()];
  else if (path.endsWith('/provider-status')) data = { providers: [
    ...MOCK_PROVIDERS.map((p) => ({ provider: p.id, profile_id: p.id, display_name: p.label, enabled: true, state: 'present', catalog_state: 'active', models: p.models.map((m) => ({ model_id: m, state: 'active' })) })),
    ...(params.has('sheet-probes') ? [{ provider: 'codex', profile_id: 'second-profile', display_name: 'Second Codex profile with a long account name for narrow screens', enabled: true, state: 'present', catalog_state: 'active', models: Array.from({ length: 40 }, (_, i) => ({ model_id: `profile-model-${i}`, state: 'active' })) }] : []),
  ] };
  else if (path.endsWith('/launch-defaults')) data = { bridge_id: bridge.id, revision: 1, default_runtime: { provider: bridge.provider, provider_profile: bridge.provider, model: bridge.model }, overrides: bridge.overrides.map((o) => ({ agent_id: o.id, runtime: { provider: o.provider, provider_profile: o.provider, model: o.model } })) };
  else if (path.endsWith('/preview')) data = { bridge_id: bridge.id, expected_revision: JSON.parse(String(init?.body)).expected_revision, affected_instances: 3 };
  else if (path.includes('/applications/') && fleetState === 'status-error') return new Response(JSON.stringify({ error: { message: 'Controlled result refresh failure. Your saved settings are retained.' } }), { status: 503 });
  else if (path.includes('/applications/')) data = {
    application_id: 'fixture-application', bridge_id: bridge.id, settings_revision: 1, revision: 1, settings_saved: true, cancelled: false,
    state: fleetState === 'applying' ? 'restarting' : 'partial_failure',
    targets: ['mock-worker', 'mock-reviewer', 'mock-coordinator'].map((id, index) => ({
      agent_id: id, agent_instance_id: 'fixture-' + id, state: fleetState === 'applying' ? 'restarting' : index === 2 ? 'failed' : 'ready',
      error_message: fleetState === 'partial-failure' && index === 2 ? 'Bridge disconnected before restart. Retry when it reconnects.' : '', retryable: true,
    })),
  };
  else return new Response(JSON.stringify({ error: { message: 'Fixture route unavailable' } }), { status: 404 });
  return new Response(JSON.stringify({ data }), { status: 200, headers: { 'Content-Type': 'application/json' } });
};
const zero = mockActivity('tasks_completed');
zero.days.forEach((day) => { day.value = 0; });
zero.summary = summarizeActivity(zero.days, 'counter');
document.body.style.margin = '0';
document.body.style.background = 'var(--color-canvas)';
const style = document.createElement('style');
style.textContent = 'html{scrollbar-width:none}html,body,#root{height:auto;max-height:none;min-height:100vh;overflow:visible}body{position:static;inset:auto}.fixture-shell{display:grid;grid-template-columns:260px minmax(0,1fr);min-height:100vh}.fixture-sidebar{background:var(--color-surface);border-right:1px solid var(--color-border-subtle);padding:24px;color:var(--color-text-primary)}.fixture-main{padding:24px 16px}@media(max-width:767px){.fixture-shell{display:block}.fixture-sidebar{display:none}.fixture-main{padding:0}}';
document.head.append(style);
function SheetProbes() {
  const [value, setValue] = useState('missing');
  return <section aria-label="Choice edge fixtures" style={{ padding: 16 }}>
    <HomeSelect value={value} onChange={setValue} aria-label="Unavailable saved choice" data-debug-id="home-probe-unavailable"
      options={[{ value: 'missing', label: 'Saved choice (unavailable)', disabled: true }, { value: 'blocked', label: 'Disabled choice', disabled: true }, ...Array.from({ length: 45 }, (_, i) => ({ value: `choice-${i}`, label: `Choice ${i} with a very long label ${'unbroken'.repeat(12)}` }))]} />
    <output data-debug-id="home-probe-value">{value}</output>
    <HomeSelect value="" onChange={setValue} aria-label="Empty choices" data-debug-id="home-probe-empty" options={[]} />
    <HomeSelect value="blocked" onChange={setValue} aria-label="Only unavailable choices" data-debug-id="home-probe-disabled"
      options={[{ value: 'blocked', label: 'Unavailable choice', disabled: true }]} />
  </section>;
}
const fixtureRoot = createRoot(document.getElementById('root')!);
function renderFixture(user: string | null = 'home-visual-fixture') {
  fixtureRoot.render(user === null ? null : <Provider store={store}><div className="fixture-shell"><aside className="fixture-sidebar">Ninjy</aside><main className="fixture-main">
  <AuthUserProvider value={{ user_id: user }}>
    {params.has('empty') ? <HomeDashboard userId="home-visual-fixture" widgets={{
      activity: <ActivityWidget resource={{ status: 'ready', data: zero }} />,
      chains: <TaskChainsWidget resource={{ status: 'ready', data: [] }} />,
      uptime: <UptimeWidget resource={{ status: 'ready', data: { connected: 0, total: 0, uptimePercent: 0, bridges: [] } }} />,
      fleet: <FleetWidget resource={{ status: 'ready', data: [] }} />,
    }} /> : <HomePage />}
  </AuthUserProvider>
  {params.has('sheet-probes') && <SheetProbes />}
</main></div></Provider>);
}
(window as any).__homeFixtureRender = renderFixture;
renderFixture();
