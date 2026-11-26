import { test } from 'node:test';
import assert from 'node:assert/strict';
import React from 'react';
import './ui_bridge_fleet_test.ts';
import './ui_home_task_chains_test.ts';
import { makeVaultStore } from './helpers/vaultEndpointHarness.ts';
import {
  activeWidgetChains, activityLevel, chainProgress, chainWidgetPage, summarizeActivity, activityFromWire, uptimeFromWire, fleetFromWire,
} from '../src/ui/components/home/widgetData.ts';
import { loadMockFleet, mockActivity, mockUptime, activityFixture, uptimeFixture, fleetFixture } from '../src/ui/components/home/homeWidgetFixtures.ts';

test('Activity fixture covers 53 Sunday–Saturday weeks and reproduces the design summary', () => {
  const data = mockActivity('tasks_completed', new Date(2026, 10, 25, 12));
  assert.equal(data.days.length, 371);
  assert.equal(new Date(data.days[0].date + 'T12:00:00').getDay(), 0);
  assert.equal(new Date(data.days[370].date + 'T12:00:00').getDay(), 6);
  assert.deepEqual([data.summary.total, data.summary.best.value, data.summary.activeDays, data.summary.streakDays], [834, 17, 149, 7]);
  assert.equal(data.summary.best.date, '2026-11-16');
  assert.ok(data.days.filter((day) => day.future).every((day) => day.value === 0));
  assert.equal(mockActivity('active_chains').summary.total, undefined);
  assert.ok(typeof mockActivity('active_chains').summary.average === 'number');
});
test('Activity honors supplied level edges and handles zero history', () => {
  assert.deepEqual([0, 2, 4, 5, 9, 10, 13, 14, 30].map((value) => activityLevel(value, [0, 4, 9, 13, 18])), [0, 1, 1, 2, 2, 3, 3, 4, 4]);
  assert.deepEqual(summarizeActivity([{ date: '2026-11-25', value: 0 }], 'counter'), {
    total: 0, best: { date: '2026-11-25', value: 0 }, activeDays: 0, streakDays: 0,
  });
});
test('Chains exclude terminal states, sort by activity, page three and clamp after shrink', () => {
  const rows = Array.from({ length: 9 }, (_, index) => ({
    chainId: 'chain-' + index, status: index === 8 ? 'completed' : index === 7 ? 'archived' : 'active', updatedAt: '2026-11-' + (10 + index),
  })) as any;
  const active = activeWidgetChains(rows);
  assert.equal(active.length, 7);
  assert.deepEqual(chainWidgetPage(active, 0).rows.map((row) => row.chainId), ['chain-6', 'chain-5', 'chain-4']);
  assert.equal(chainWidgetPage(active, 1).rows.length, 3);
  assert.equal(chainWidgetPage(active, 99).rows.length, 1);
  assert.equal(chainWidgetPage(active.slice(0, 2), 99).index, 0);
  assert.equal(chainWidgetPage([], 9).start, 0);
  assert.deepEqual(chainProgress([{ state: 'done' }, { state: 'in_review' }, { state: 'in_progress' }, { state: 'ready' }]), { total: 4, done: 1, review: 1, progress: 1 });
});
test('Mock uptime includes thirty dated bars and fleet fixtures are fresh per load', async () => {
  const data = mockUptime(new Date(2026, 10, 25));
  assert.equal(data.bridges.length, 3);
  assert.ok(data.bridges.every((bridge) => bridge.days.length === 30));
  assert.equal(data.bridges[0].days[23].date, '2026-11-19');
  assert.equal(data.bridges[0].days[23].downSeconds, 2280);
  const first = await loadMockFleet(new AbortController().signal);
  first[0].overrides.length = 0;
  assert.equal((await loadMockFleet(new AbortController().signal))[0].overrides.length, 2);
});

test('Widget DOM: metrics, readouts, independent failures, overrides, tooltips and endpoint-hook chain paging', async () => {
  const { JSDOM } = await import('jsdom');
  const dom = new JSDOM('<!doctype html><html><body><div id="root"></div></body></html>', { url: 'http://localhost/' });
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
  globalThis.fetch = async (input: any) => {
    const url = String(input?.url ?? input);
    let data: any = {};
    if (url.includes('/task-chains?')) data = Array.from({ length: 9 }, (_, index) => ({
      chain_id: 'chain-' + index, title: 'Chain ' + index, status: index === 8 ? 'completed' : index === 7 ? 'archived' : 'active',
      updated_at: '2026-11-' + (10 + index), task_count: 4, completed_task_count: 1,
    }));
    else if (/\/task-chains\/chain-\d/.test(url)) data = { chain_id: url.match(/\/task-chains\/(chain-\d+)/)![1], members: [], tasks: [{ task_id: 'a', state: 'done' }, { task_id: 'b', state: 'in_review' }, { task_id: 'c', state: 'in_progress' }, { task_id: 'd', state: 'ready' }] };
    const text = JSON.stringify({ data });
    return { ok: true, status: 200, headers: { get: () => 'application/json' }, json: async () => JSON.parse(text), text: async () => text } as any;
  };
  const { Provider } = await import('react-redux');
  const { createRoot } = await import('react-dom/client');
  const { act } = await import('react');
  const { ActivityWidget } = await import('../src/ui/components/home/ActivityWidget.tsx');
  const { UptimeWidget } = await import('../src/ui/components/home/UptimeWidget.tsx');
  const { FleetWidget } = await import('../src/ui/components/home/FleetWidget.tsx');
  const { TaskChainsWidget } = await import('../src/ui/components/home/TaskChainsWidget.tsx');
  const { HomeHeader } = await import('../src/ui/components/home/HomePage.tsx');
  const { heimdallApi } = await import('../src/ui/api/heimdallApi.ts');
  const store = await makeVaultStore();
  const root = createRoot(win.document.getElementById('root'));
  const doc = win.document;
  const get = (id: string) => doc.querySelector('[data-debug-id="' + id + '"]') as HTMLElement;
  const settle = async () => act(async () => { await new Promise((resolve) => setTimeout(resolve, 80)); });
  const render = async (children: React.ReactNode) => {
    await act(async () => root.render(React.createElement(Provider, { store }, children)));
    await settle();
  };
  const click = async (id: string) => { assert.ok(get(id), id); await act(async () => get(id).click()); await settle(); };
  try {
    let edits = 0;
    await render(React.createElement(React.Fragment, null,
      React.createElement(HomeHeader, { editing: false, onEdit: () => edits++ }),
      React.createElement(ActivityWidget), React.createElement(UptimeWidget), React.createElement(FleetWidget, { resource: { status: 'ready', data: fleetFromWire(fleetFixture()) } }), React.createElement(TaskChainsWidget),
    ));
    assert.equal(get('home-new-shell').getAttribute('href'), '#/new?intent=shell');
    assert.equal(get('home-new-conversation').getAttribute('href'), '#/new?intent=agent');
    await click('home-layout-edit'); assert.equal(edits, 1);
    assert.match(get('home-widget-activity').textContent!, /834/);
    assert.equal(get('home-activity-heatmap').querySelectorAll('rect').length, 371);
    await click('home-activity-metric-active-chains');
    assert.equal(get('home-activity-metric-active-chains').getAttribute('aria-pressed'), 'true');
    assert.match(get('home-widget-activity').textContent!, /Daily average/);
    const readout = () => get('home-widget-activity').querySelector('[aria-live]')!.textContent;
    const before = readout();
    await act(async () => get('home-activity-heatmap').dispatchEvent(new win.KeyboardEvent('keydown', { key: 'ArrowLeft', bubbles: true })));
    assert.notEqual(readout(), before);
    assert.match(get('home-widget-uptime').textContent!, /98.79%/);
    const bar = doc.querySelector('.home-uptime-partial')!;
    assert.match(bar.getAttribute('aria-label')!, /Down 38m/);
    assert.equal(bar.getAttribute('tabindex'), '0');
    assert.equal(doc.querySelectorAll('.home-uptime-bar').length, 90);
    const fleet = get('home-widget-fleet');
    assert.equal(fleet.querySelectorAll('.home-fleet-override').length, 2);
    await click('home-fleet-remove-mock-bridge-0-mock-worker');
    assert.equal(fleet.querySelectorAll('.home-fleet-override').length, 1);
    await click('home-fleet-add-override-mock-bridge-0');
    assert.equal(fleet.querySelectorAll('.home-fleet-override').length, 2);
    await click('home-fleet-default-mock-bridge-0-provider');
    const codex = [...doc.querySelectorAll('[role="option"]')].find((node: any) => node.textContent === 'Codex') as HTMLElement;
    assert.ok(codex); await act(async () => codex.click());
    assert.match(get('home-fleet-default-mock-bridge-0-model').textContent!, /gpt-6.1-sol/);
    await click('home-fleet-expand-mock-bridge-1');
    const secondBridgeToggle = get('home-fleet-expand-mock-bridge-1');
    const secondBridgePanel = doc.getElementById(secondBridgeToggle.getAttribute('aria-controls')!);
    assert.ok(secondBridgePanel, 'bridge toggle controls its complete disclosure panel');
    assert.equal(secondBridgeToggle.getAttribute('aria-expanded'), 'true');
    assert.equal(secondBridgePanel.getAttribute('aria-hidden'), 'false');
    assert.equal(secondBridgePanel.hasAttribute('inert'), false);
    assert.match(secondBridgePanel.textContent!, /No overrides/);
    assert.equal(get('home-widget-chains').querySelectorAll('article').length, 3);
    assert.match(get('home-widget-chains').textContent!, /7 active/);
    assert.match(get('home-widget-chains').querySelector('article')!.textContent!, /Running/);
    assert.match(get('home-widget-chains').textContent!, /1–3 of 7/);
    assert.match(get('home-widget-chains').querySelector('.home-chain-progress')!.getAttribute('aria-label')!, /1 of 4 tickets done, 1 in review, 1 in progress/);
    await click('home-chains-next'); assert.match(get('home-widget-chains').textContent!, /4–6 of 7/);
    await click('home-chains-next'); assert.equal(get('home-widget-chains').querySelectorAll('article').length, 1);
    assert.equal((get('home-chains-next') as HTMLButtonElement).disabled, true);
    assert.match(get('home-widget-chains').textContent!, /7 of 7/);

    await render(React.createElement(React.Fragment, null,
      React.createElement(ActivityWidget, { resource: { status: 'error', message: 'Activity unavailable' } }),
      React.createElement(UptimeWidget),
      React.createElement(FleetWidget, { resource: { status: 'loading' } }),
      React.createElement(TaskChainsWidget, { resource: { status: 'ready', data: [] } }),
    ));
    assert.match(get('home-widget-activity').textContent!, /Activity unavailable/);
    assert.match(get('home-widget-uptime').textContent!, /98.79%/);
    assert.match(get('home-widget-fleet').textContent!, /Loading fleet/);
    assert.match(get('home-widget-chains').textContent!, /No active task chains/);

    const zero = mockActivity('tasks_completed');
    zero.days.forEach((day) => { day.value = 0; }); zero.summary = summarizeActivity(zero.days, 'counter');
    await render(React.createElement(React.Fragment, null,
      React.createElement(ActivityWidget, { resource: { status: 'ready', data: zero } }),
      React.createElement(UptimeWidget, { resource: { status: 'ready', data: { connected: 0, total: 0, uptimePercent: 0, bridges: [] } } }),
      React.createElement(FleetWidget, { resource: { status: 'ready', data: [] } }),
    ));
    assert.match(get('home-widget-activity').textContent!, /No activity yet/);
    assert.equal(get('home-widget-activity').querySelectorAll('rect.home-heat-level-0').length, 371);
    assert.match(get('home-widget-uptime').textContent!, /No bridges yet/);
    assert.match(get('home-widget-fleet').textContent!, /No bridges yet/);

    let attempts = 0;
    await render(React.createElement(FleetWidget, { load: async () => { if (++attempts === 1) throw new Error('Fleet unavailable'); return []; } }));
    assert.match(get('home-widget-fleet').textContent!, /Fleet unavailable/);
    await click('home-fleet-retry');
    assert.match(get('home-widget-fleet').textContent!, /No bridges yet/);
    assert.equal(attempts, 2);
    await render(React.createElement(TaskChainsWidget, { resource: { status: 'ready', data: [{ chainId: 'one', title: 'Only chain', status: 'active', updatedAt: '' }] as any } }));
    assert.equal(get('home-chains-next'), null);
  } finally {
    await act(async () => root.unmount());
    store.dispatch(heimdallApi.util.resetApiState());
    dom.window.close();
    for (const [key, value] of saved) (globalThis as any)[key] = value;
    globalThis.fetch = savedFetch;
    (globalThis as any).IS_REACT_ACT_ENVIRONMENT = savedAct;
  }
});

test('Wire-shaped fixtures round-trip sparse days, summary names and bridge settings through response adapters', () => {
  const today = new Date(2026, 10, 25, 12);
  const activity = activityFixture('tasks_completed', today);
  assert.ok(activity.days.length < 371);
  assert.equal(activity.summary.active_days, 149);
  assert.equal(activityFromWire(activity).summary.total, 834);
  const uptime = uptimeFixture(today);
  assert.equal(uptime.fleet.uptime_pct, 98.79);
  assert.equal(uptime.bridges[0].days.length, 1);
  assert.equal(uptimeFromWire(uptime, today).bridges[0].days.length, 30);
  const fleet = fleetFixture();
  assert.equal(fleet.defaults['mock-bridge-0'].provider, 'claude');
  assert.equal(fleet.overrides['mock-bridge-0'][0].agent_id, 'mock-worker');
  assert.equal(fleetFromWire(fleet)[0].overrides[0].agent, 'Worker');
});
