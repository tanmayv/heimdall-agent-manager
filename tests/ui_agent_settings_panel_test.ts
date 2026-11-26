// Agent settings panel (T5): the panel state hook (layout mode, per-user persistence,
// focus handoff, Esc) and the Runtime section (status model and rendering).
//
// RUN: node --import ./tests/helpers/vaultEndpointHarness.ts --test tests/ui_agent_settings_panel_test.ts

import './helpers/vaultEndpointHarness.ts';
import { test } from 'node:test';
import assert from 'node:assert/strict';
import React, { act } from 'react';
import { JSDOM } from 'jsdom';

async function withDom(width: number, run: (ctx: { win: any; doc: Document; render: (el: React.ReactElement) => Promise<void>; setWidth: (w: number) => Promise<void> }) => Promise<void>) {
  const dom = new JSDOM('<!doctype html><div id="root"></div>', { url: 'http://localhost/', pretendToBeVisual: true });
  const win = dom.window as any;
  Object.defineProperty(win, 'innerWidth', { value: width, configurable: true, writable: true });
  win.matchMedia = () => ({ matches: false, addEventListener() {}, removeEventListener() {}, addListener() {}, removeListener() {} });
  win.HTMLElement.prototype.scrollIntoView = () => {};
  const keys = ['window', 'document', 'HTMLElement', 'Node', 'Element', 'KeyboardEvent', 'navigator', 'localStorage', 'IS_REACT_ACT_ENVIRONMENT'];
  const saved = new Map(keys.map((k) => [k, Object.getOwnPropertyDescriptor(globalThis, k)]));
  for (const [k, v] of Object.entries({ window: win, document: win.document, HTMLElement: win.HTMLElement, Node: win.Node, Element: win.Element,
    KeyboardEvent: win.KeyboardEvent, navigator: win.navigator, localStorage: win.localStorage, IS_REACT_ACT_ENVIRONMENT: true })) {
    Object.defineProperty(globalThis, k, { value: v, configurable: true, writable: true });
  }
  const { createRoot } = await import('react-dom/client');
  const root = createRoot(win.document.getElementById('root'));
  try {
    await run({
      win,
      doc: win.document,
      render: async (el) => { await act(async () => root.render(el)); },
      setWidth: async (w) => { win.innerWidth = w; await act(async () => { win.dispatchEvent(new win.Event('resize')); }); },
    });
  } finally {
    await act(async () => root.unmount());
    dom.window.close();
    for (const [k, d] of saved) { if (d) Object.defineProperty(globalThis, k, d); else delete (globalThis as any)[k]; }
  }
}

const q = (doc: Document, id: string) => doc.querySelector(`[data-debug-id="${id}"]`) as HTMLElement | null;
const click = async (el: HTMLElement | null) => { assert.ok(el, 'element exists'); await act(async () => el!.click()); };

// ---------------------------------------------------------------- state hook

test('layout mode: page below 768, drawer below 1280, docked from 1280', async () => {
  const { agentSettingsPanelMode } = await import('../src/ui/components/agentSettings/useAgentSettingsPanelState.ts');
  const { DOCK_MIN } = await import('../src/ui/components/ui/hooks/useViewport.ts');
  assert.equal(DOCK_MIN, 1280);
  assert.equal(agentSettingsPanelMode(390), 'page');
  assert.equal(agentSettingsPanelMode(767), 'page');
  assert.equal(agentSettingsPanelMode(768), 'drawer');
  assert.equal(agentSettingsPanelMode(1180), 'drawer');
  assert.equal(agentSettingsPanelMode(1279), 'drawer');
  assert.equal(agentSettingsPanelMode(1280), 'docked');
  assert.equal(agentSettingsPanelMode(1440), 'docked');
});

test('docked open state persists per user and tolerates throwing storage', async () => {
  await withDom(1440, async ({ win }) => {
    const mod = await import('../src/ui/components/agentSettings/useAgentSettingsPanelState.ts');
    const { userScopedStorageKey } = await import('../src/ui/utils/clientPersistence.ts');
    assert.equal(mod.readAgentSettingsPanelOpen('alice'), false);
    mod.writeAgentSettingsPanelOpen(true, 'alice');
    assert.equal(win.localStorage.getItem(userScopedStorageKey(mod.AGENT_SETTINGS_PANEL_STORAGE_KEY, 'alice')), '1');
    assert.equal(mod.readAgentSettingsPanelOpen('alice'), true);
    assert.equal(mod.readAgentSettingsPanelOpen('bob'), false, 'another user is unaffected');
    mod.writeAgentSettingsPanelOpen(false, 'alice');
    assert.equal(mod.readAgentSettingsPanelOpen('alice'), false);

    const throwing = { getItem() { throw new Error('denied'); }, setItem() { throw new Error('denied'); }, removeItem() { throw new Error('denied'); } };
    Object.defineProperty(globalThis, 'localStorage', { value: throwing, configurable: true, writable: true });
    assert.equal(mod.readAgentSettingsPanelOpen('alice'), false);
    assert.doesNotThrow(() => mod.writeAgentSettingsPanelOpen(true, 'alice'));
  });
});

function Harness({ withRuntime = false }: { withRuntime?: boolean }) {
  // Loaded lazily by each test (after the DOM globals exist).
  const { useAgentSettingsPanelState, AgentSettingsPanel } = (globalThis as any).__panelModules;
  const state = useAgentSettingsPanelState({ enabled: true });
  return React.createElement('div', null,
    React.createElement('button', { ref: state.gearRef, 'data-debug-id': 'gear', 'aria-expanded': state.open, onClick: state.toggle }, 'Agent settings'),
    React.createElement(AgentSettingsPanel, { state, agentLabel: 'coordinator #41', projectLabel: 'heimdall', runtime: withRuntime ? null : React.createElement('div', { 'data-debug-id': 'runtime-slot' }) }),
  );
}

async function loadPanelModules() {
  const hook = await import('../src/ui/components/agentSettings/useAgentSettingsPanelState.ts');
  const panel = await import('../src/ui/components/agentSettings/AgentSettingsPanel.tsx');
  (globalThis as any).__panelModules = { ...hook, ...panel };
}

test('docked: gear toggles, focus goes to the heading and back to the gear, Esc does not close, state persists', async () => {
  await withDom(1440, async ({ doc, render, win }) => {
    await loadPanelModules();
    await render(React.createElement(Harness));
    assert.equal(q(doc, 'agent-panel'), null, 'closed by default');
    await click(q(doc, 'gear'));
    const panel = q(doc, 'agent-panel')!;
    assert.ok(panel, 'opens');
    assert.equal(panel.tagName, 'ASIDE');
    assert.equal(panel.getAttribute('data-mode'), 'docked');
    const heading = doc.getElementById(panel.getAttribute('aria-labelledby')!)!;
    assert.equal(heading.textContent, 'Agent', 'aside is labelled by the Agent heading');
    assert.equal(doc.activeElement, heading, 'focus moves to the heading');
    assert.equal(q(doc, 'agent-panel-subtitle')!.textContent, 'coordinator #41 · heimdall');
    assert.equal(q(doc, 'gear')!.getAttribute('aria-expanded'), 'true');

    await act(async () => { doc.dispatchEvent(new win.KeyboardEvent('keydown', { key: 'Escape', bubbles: true })); });
    assert.ok(q(doc, 'agent-panel'), 'Esc does not close the docked panel');

    const { readAgentSettingsPanelOpen } = (globalThis as any).__panelModules;
    assert.equal(readAgentSettingsPanelOpen(), true, 'docked open state is persisted');

    await click(q(doc, 'agent-panel-close'));
    assert.equal(q(doc, 'agent-panel'), null);
    assert.equal(doc.activeElement, q(doc, 'gear'), 'focus returns to the gear');
    assert.equal(readAgentSettingsPanelOpen(), false);
  });
});

test('docked: a persisted open panel is restored on mount without stealing focus', async () => {
  await withDom(1440, async ({ doc, render }) => {
    await loadPanelModules();
    (globalThis as any).__panelModules.writeAgentSettingsPanelOpen(true);
    await render(React.createElement(Harness));
    assert.ok(q(doc, 'agent-panel'), 'restored open');
    assert.notEqual(doc.activeElement?.tagName, 'H2');
  });
});

test('drawer (<1280): Esc and the scrim close it; opening is not persisted', async () => {
  await withDom(1180, async ({ doc, render, win }) => {
    await loadPanelModules();
    await render(React.createElement(Harness));
    await click(q(doc, 'gear'));
    assert.equal(q(doc, 'agent-panel')!.getAttribute('data-mode'), 'drawer');
    assert.equal((globalThis as any).__panelModules.readAgentSettingsPanelOpen(), false, 'drawer open is transient');
    await act(async () => { doc.dispatchEvent(new win.KeyboardEvent('keydown', { key: 'Escape', bubbles: true })); });
    assert.equal(q(doc, 'agent-panel'), null, 'Esc closes the drawer');
    assert.equal(doc.activeElement, q(doc, 'gear'));

    await click(q(doc, 'gear'));
    const scrim = q(doc, 'agent-panel-scrim')!;
    await act(async () => { scrim.dispatchEvent(new win.MouseEvent('mousedown', { bubbles: true })); });
    assert.equal(q(doc, 'agent-panel'), null, 'scrim closes the drawer');
  });
});

test('drawer: a persisted docked preference does not open the drawer on load; widening restores it', async () => {
  await withDom(1180, async ({ doc, render, setWidth }) => {
    await loadPanelModules();
    (globalThis as any).__panelModules.writeAgentSettingsPanelOpen(true);
    await render(React.createElement(Harness));
    assert.equal(q(doc, 'agent-panel'), null);
    await setWidth(1440);
    assert.equal(q(doc, 'agent-panel')?.getAttribute('data-mode'), 'docked');
  });
});

test('mobile page (<768): full-screen page with a 44px back button, Agent settings title and subtitle', async () => {
  await withDom(390, async ({ doc, render }) => {
    await loadPanelModules();
    await render(React.createElement(Harness));
    await click(q(doc, 'gear'));
    const panel = q(doc, 'agent-panel')!;
    assert.equal(panel.getAttribute('data-mode'), 'page');
    assert.match(panel.className, /fixed/);
    const back = q(doc, 'agent-panel-back')!;
    assert.match(back.className, /\bh-11\b/, 'back button is 44px');
    assert.equal(back.getAttribute('aria-label'), 'Back to the conversation');
    const heading = doc.getElementById(panel.getAttribute('aria-labelledby')!)!;
    assert.equal(heading.textContent, 'Agent settings');
    assert.equal(doc.activeElement, heading);
    await click(back);
    assert.equal(q(doc, 'agent-panel'), null);
    assert.equal(doc.activeElement, q(doc, 'gear'));
  });
});

// ---------------------------------------------------------------- runtime model

test('runtime view: running, idle, working with uptime, queued restart', async () => {
  const { runtimeSectionView, formatUptime } = await import('../src/ui/components/agentSettings/RuntimeSection.tsx');
  const now = Date.parse('2026-11-26T12:00:00Z');
  const startedAt = '2026-11-26T09:46:00Z';
  assert.equal(formatUptime(startedAt, now), '2h 14m');
  assert.equal(formatUptime('2026-11-26T11:59:30Z', now), '<1m');
  assert.equal(formatUptime('2026-11-24T10:00:00Z', now), '2d 2h');
  assert.equal(formatUptime('', now), '');
  assert.equal(formatUptime('2026-11-27T00:00:00Z', now), '', 'future start is unknown');

  const working = runtimeSectionView({ runtimeStatus: 'running', activityStatus: 'working', startedAt, now });
  assert.deepEqual(working, { state: 'running', label: 'Running', tone: 'info', detail: 'Working on a turn · up 2h 14m' });
  assert.equal(runtimeSectionView({ runtimeStatus: 'running', activityStatus: 'idle', startedAt, now }).detail, 'Idle · up 2h 14m');
  assert.equal(runtimeSectionView({ runtimeStatus: 'running', activityStatus: 'idle', now }).detail, 'Idle', 'no uptime without started_at');

  // T4 deferred apply: tolerated when present, ignored when absent.
  const queued = runtimeSectionView({ runtimeStatus: 'running', activityStatus: 'working', startedAt, now, operations: [{ phase: 'waiting_for_idle' }] });
  assert.equal(queued.detail, 'Restart queued after this turn');
  assert.equal(runtimeSectionView({ runtimeStatus: 'running', activityStatus: 'working', startedAt, now, operations: [{ phase: 'ready' }] }).detail, 'Working on a turn · up 2h 14m');
  assert.equal(runtimeSectionView({ runtimeStatus: 'running', now, operations: undefined }).state, 'running');
});

test('runtime view: restarting while applying, starting or stopping; stopped reasons', async () => {
  const { runtimeSectionView } = await import('../src/ui/components/agentSettings/RuntimeSection.tsx');
  assert.deepEqual(runtimeSectionView({ runtimeStatus: 'running', operationInFlight: true }), { state: 'restarting', label: 'Restarting', tone: 'info', detail: 'Applying your changes' });
  assert.equal(runtimeSectionView({ runtimeStatus: 'running', restartPending: true }).state, 'restarting');
  assert.equal(runtimeSectionView({ runtimeStatus: 'stopped', operationInFlight: true }).state, 'restarting', 'a bridge move passes through stopped');
  assert.equal(runtimeSectionView({ runtimeStatus: 'starting' }).detail, 'Starting…');
  assert.equal(runtimeSectionView({ runtimeStatus: 'running', startupStatus: 'starting' }).state, 'restarting');
  assert.equal(runtimeSectionView({ runtimeStatus: 'stopping' }).detail, 'Stopping…');

  const stopped = runtimeSectionView({ runtimeStatus: 'stopped', stopReason: 'user_stop' });
  assert.deepEqual(stopped, { state: 'stopped', label: 'Stopped', tone: 'neutral', detail: 'Stopped by you' });
  assert.equal(runtimeSectionView({ runtimeStatus: 'stopped', stopReason: 'coordinator_idle' }).detail, 'Stopped automatically: no user activity');
  assert.equal(runtimeSectionView({ runtimeStatus: 'stopped' }).detail, 'Stopped');
  assert.equal(runtimeSectionView({ runtimeStatus: 'failed' }).detail, 'Stopped after an error');
  assert.equal(runtimeSectionView({ runtimeStatus: '' }).state, 'stopped');
});

test('waiting_for_idle reconfigurations are not coerced to recovery_required', async () => {
  const { default: src } = await import('node:fs').then((fs) => ({ default: fs.readFileSync(new URL('../src/ui/api/endpoints/agents.ts', import.meta.url), 'utf8') }));
  assert.match(src, /phase === 'waiting_for_idle'\) return \{ \.\.\.raw, phase \}/);
});

// ---------------------------------------------------------------- runtime rendering

function runtimeProps(over: Record<string, unknown> = {}) {
  const calls: string[] = [];
  return {
    calls,
    props: {
      view: { state: 'running', label: 'Running', tone: 'info', detail: 'Working on a turn · up 2h 14m' },
      bridgeLabel: 'riverwood',
      provider: 'claude',
      model: 'default',
      transport: 'pty',
      folder: '/var/home/tanmay/heimdall-agent-manager',
      agentLabel: 'coordinator #41',
      onStart: () => calls.push('start'),
      onStop: () => calls.push('stop'),
      onRestart: () => calls.push('restart'),
      onForceStop: () => calls.push('force'),
      ...over,
    } as any,
  };
}

test('Runtime card renders status, config, folder and running actions', async () => {
  await withDom(1440, async ({ doc, render }) => {
    const { RuntimeSection } = await import('../src/ui/components/agentSettings/RuntimeSection.tsx');
    const { props, calls } = runtimeProps();
    await render(React.createElement(RuntimeSection, props));
    assert.ok(q(doc, 'agent-panel-runtime'));
    const pill = q(doc, 'agent-panel-runtime-status')!;
    assert.equal(pill.getAttribute('role'), 'status');
    assert.equal(pill.textContent, 'Running', 'state is in words, not colour alone');
    assert.match(pill.className, /info/);
    assert.equal(q(doc, 'agent-panel-runtime-detail')!.textContent, 'Working on a turn · up 2h 14m');
    assert.equal(q(doc, 'agent-panel-runtime-config')!.textContent, 'riverwood·Claude Code·default·PTY');
    assert.match(q(doc, 'agent-panel-runtime-bridge')!.className, /font-mono/);
    assert.match(q(doc, 'agent-panel-runtime-model')!.className, /font-mono/);
    assert.match(q(doc, 'agent-panel-runtime-folder')!.className, /text-code-sm/);
    assert.equal(q(doc, 'agent-panel-runtime-start'), null);
    await click(q(doc, 'agent-panel-runtime-restart'));
    await click(q(doc, 'agent-panel-runtime-stop'));
    assert.deepEqual(calls, ['restart', 'stop']);
  });
});

test('Runtime card: stopped shows Start only; restarting disables Restart/Stop and shows a spinner', async () => {
  await withDom(1440, async ({ doc, render }) => {
    const { RuntimeSection } = await import('../src/ui/components/agentSettings/RuntimeSection.tsx');
    const stopped = runtimeProps({ view: { state: 'stopped', label: 'Stopped', tone: 'neutral', detail: 'Stopped by you' }, transport: 'acp' });
    await render(React.createElement(RuntimeSection, stopped.props));
    assert.equal(q(doc, 'agent-panel-runtime-status')!.textContent, 'Stopped');
    assert.match(q(doc, 'agent-panel-runtime-status')!.className, /neutral|text-muted|bg-neutral/);
    assert.equal(q(doc, 'agent-panel-runtime-detail')!.textContent, 'Stopped by you');
    assert.equal(q(doc, 'agent-panel-runtime-transport')!.textContent, 'ACP');
    assert.equal(q(doc, 'agent-panel-runtime-restart'), null);
    assert.equal(q(doc, 'agent-panel-runtime-stop'), null);
    assert.ok(q(doc, 'agent-panel-runtime-more'), 'Force stop stays reachable while a stop is unconfirmed');
    await render(React.createElement(RuntimeSection, { ...stopped.props, forceStopDisabled: true }));
    assert.equal(q(doc, 'agent-panel-runtime-more'), null, 'no … menu when there is nothing to force stop');
    await click(q(doc, 'agent-panel-runtime-start'));
    assert.deepEqual(stopped.calls, ['start']);

    const restarting = runtimeProps({ view: { state: 'restarting', label: 'Restarting', tone: 'info', detail: 'Applying your changes' } });
    await render(React.createElement(RuntimeSection, restarting.props));
    assert.equal(q(doc, 'agent-panel-runtime-status')!.textContent, 'Restarting');
    assert.ok(q(doc, 'agent-panel-runtime-status')!.querySelector('.motion-safe\\:animate-spin'), 'spinner');
    assert.equal((q(doc, 'agent-panel-runtime-restart') as HTMLButtonElement).disabled, true);
    assert.equal((q(doc, 'agent-panel-runtime-stop') as HTMLButtonElement).disabled, true);
  });
});

test('Force stop sits in the … menu with its note and is confirmed in a dialog', async () => {
  await withDom(1440, async ({ doc, render }) => {
    const { RuntimeSection } = await import('../src/ui/components/agentSettings/RuntimeSection.tsx');
    const { props, calls } = runtimeProps();
    await render(React.createElement(RuntimeSection, props));
    assert.equal(q(doc, 'agent-panel-runtime-force-stop'), null, 'hidden until the menu opens');
    await click(q(doc, 'agent-panel-runtime-more'));
    const item = q(doc, 'agent-panel-runtime-force-stop')!;
    assert.match(item.textContent || '', /Force stop/);
    assert.match(item.textContent || '', /Kills the process now\. The current turn is lost\./);
    assert.match(item.className, /text-danger/);
    await click(item);
    assert.deepEqual(calls, [], 'nothing happens before confirmation');
    const dialog = q(doc, 'agent-panel-force-stop-dialog')!;
    assert.equal(dialog.getAttribute('role'), 'dialog');
    await click(q(doc, 'agent-panel-force-stop-cancel'));
    assert.equal(q(doc, 'agent-panel-force-stop-dialog'), null);
    assert.deepEqual(calls, []);

    await click(q(doc, 'agent-panel-runtime-more'));
    await click(q(doc, 'agent-panel-runtime-force-stop'));
    await click(q(doc, 'agent-panel-force-stop-confirm'));
    assert.deepEqual(calls, ['force']);
  });
});
