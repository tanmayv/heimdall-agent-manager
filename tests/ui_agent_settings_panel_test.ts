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

async function finishDockedExit(doc: Document, win: any) {
  const shell = q(doc, 'agent-panel-dock-shell');
  assert.ok(shell, 'dock shell exists');
  const ev = new win.Event('transitionend', { bubbles: true });
  Object.defineProperty(ev, 'propertyName', { value: 'width' });
  await act(async () => { shell!.dispatchEvent(ev); });
}

async function finishDrawerExit(doc: Document, win: any) {
  const dialog = q(doc, 'agent-panel-dialog');
  assert.ok(dialog, 'drawer dialog exists while closing');
  const ev = new win.Event('animationend', { bubbles: true });
  await act(async () => { dialog!.dispatchEvent(ev); });
}

test('docked: gear toggles, header is 48px single-row, focus moves, slides out on close, Esc does not close, state persists', async () => {
  await withDom(1440, async ({ doc, render, win }) => {
    await loadPanelModules();
    await render(React.createElement(Harness));
    assert.equal(q(doc, 'agent-panel'), null, 'closed by default');
    const shell = q(doc, 'agent-panel-dock-shell')!;
    assert.equal(shell.getAttribute('data-state'), 'closed');
    assert.ok(shell.className.includes('w-0') && shell.className.includes('transition-[width]'));

    await click(q(doc, 'gear'));
    const panel = q(doc, 'agent-panel')!;
    assert.ok(panel, 'opens');
    assert.equal(panel.tagName, 'ASIDE');
    assert.equal(panel.getAttribute('data-mode'), 'docked');
    assert.equal(shell.getAttribute('data-state'), 'open');
    assert.ok(shell.className.includes('w-[400px]'));

    const header = q(doc, 'agent-panel-header')!;
    assert.ok(header.className.includes('h-12') && header.className.includes('items-center'), 'docked header matches 48px top chrome');
    const heading = doc.getElementById(panel.getAttribute('aria-labelledby')!)!;
    assert.equal(heading.textContent, 'Agent', 'aside is labelled by the Agent heading');
    assert.equal(doc.activeElement, heading, 'focus moves to the heading');
    const subtitle = q(doc, 'agent-panel-subtitle')!;
    assert.equal(subtitle.textContent, 'coordinator #41 · heimdall');
    assert.equal(header.contains(subtitle), false, 'subtitle sits in the body so the header stays 48px');
    assert.equal(q(doc, 'gear')!.getAttribute('aria-expanded'), 'true');

    await act(async () => { doc.dispatchEvent(new win.KeyboardEvent('keydown', { key: 'Escape', bubbles: true })); });
    assert.equal(q(doc, 'agent-panel')!.getAttribute('data-state'), 'open', 'Esc does not close the docked panel');

    const { readAgentSettingsPanelOpen } = (globalThis as any).__panelModules;
    assert.equal(readAgentSettingsPanelOpen(), true, 'docked open state is persisted');

    await click(q(doc, 'agent-panel-close'));
    assert.equal(shell.getAttribute('data-state'), 'closing', 'docked panel animates slide-out before unmounting');
    assert.ok(shell.className.includes('w-0'));
    assert.equal(q(doc, 'agent-panel')!.getAttribute('data-state'), 'closing');
    assert.equal(doc.activeElement, q(doc, 'gear'), 'focus returns to the gear');
    assert.equal(readAgentSettingsPanelOpen(), false);

    await finishDockedExit(doc, win);
    assert.equal(q(doc, 'agent-panel'), null, 'unmounts after width transition ends');
    assert.equal(shell.getAttribute('data-state'), 'closed');
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

test('drawer (<1280): Esc and the scrim close it with slide-out animation; opening is not persisted', async () => {
  await withDom(1180, async ({ doc, render, win }) => {
    await loadPanelModules();
    await render(React.createElement(Harness));
    await click(q(doc, 'gear'));
    assert.equal(q(doc, 'agent-panel')!.getAttribute('data-mode'), 'drawer');
    assert.ok(q(doc, 'agent-panel-header')!.className.includes('h-12'));
    assert.ok(q(doc, 'agent-panel-dialog')!.className.includes('animate-drawer-right-in'));
    assert.equal((globalThis as any).__panelModules.readAgentSettingsPanelOpen(), false, 'drawer open is transient');
    await act(async () => { doc.dispatchEvent(new win.KeyboardEvent('keydown', { key: 'Escape', bubbles: true })); });
    assert.ok(q(doc, 'agent-panel-dialog')!.className.includes('animate-drawer-right-out'), 'drawer plays slide-out animation');
    assert.equal(q(doc, 'agent-panel-dialog')!.parentElement!.getAttribute('data-state'), 'closing');
    assert.equal(doc.activeElement, q(doc, 'gear'));
    await finishDrawerExit(doc, win);
    assert.equal(q(doc, 'agent-panel'), null, 'Esc closes the drawer');

    await click(q(doc, 'gear'));
    const backdrop = q(doc, 'agent-panel-dialog')!.parentElement!;
    await act(async () => { backdrop.dispatchEvent(new win.MouseEvent('mousedown', { bubbles: true })); });
    assert.equal(backdrop.getAttribute('data-state'), 'closing', 'the backdrop starts closing the drawer');
    assert.equal(doc.activeElement, q(doc, 'gear'));
    await finishDrawerExit(doc, win);
    assert.equal(q(doc, 'agent-panel'), null, 'the backdrop unmounts the drawer after exit animation');
  });
});

for (const width of [1180, 390]) {
  test(`${width === 390 ? 'page' : 'drawer'} is modal: role=dialog, aria-modal, and Tab stays inside the panel`, async () => {
    await withDom(width, async ({ doc, render, win }) => {
      // jsdom has no layout; the trap skips elements without an offsetParent.
      Object.defineProperty(win.HTMLElement.prototype, 'offsetParent', { configurable: true, get() { return this.parentNode; } });
      await loadPanelModules();
      const { useAgentSettingsPanelState, AgentSettingsPanel } = (globalThis as any).__panelModules;
      function WithControls() {
        const state = useAgentSettingsPanelState({ enabled: true });
        return React.createElement('div', null,
          React.createElement('button', { ref: state.gearRef, 'data-debug-id': 'gear', onClick: state.toggle }, 'Agent settings'),
          React.createElement('textarea', { 'data-debug-id': 'composer' }),
          React.createElement(AgentSettingsPanel, { state, agentLabel: 'coordinator #41',
            runtime: React.createElement('button', { 'data-debug-id': 'first-control' }, 'Restart'),
            children: React.createElement('button', { 'data-debug-id': 'last-control' }, 'Apply') }),
        );
      }
      await render(React.createElement(WithControls));
      await click(q(doc, 'gear'));
      const dialog = q(doc, 'agent-panel-dialog')!;
      assert.equal(dialog.getAttribute('role'), 'dialog');
      assert.equal(dialog.getAttribute('aria-modal'), 'true');
      assert.ok(dialog.contains(q(doc, 'agent-panel')));
      assert.equal(doc.activeElement?.tagName, 'H2', 'focus starts on the heading');

      const last = q(doc, 'last-control')!;
      last.focus();
      const tab = new win.KeyboardEvent('keydown', { key: 'Tab', bubbles: true, cancelable: true });
      await act(async () => { last.dispatchEvent(tab); });
      assert.equal(tab.defaultPrevented, true, 'Tab from the last control is trapped');
      assert.ok(dialog.contains(doc.activeElement), 'focus stays inside the panel');
      assert.notEqual(doc.activeElement, q(doc, 'composer'));

      const first = doc.activeElement as HTMLElement;
      const back = new win.KeyboardEvent('keydown', { key: 'Tab', shiftKey: true, bubbles: true, cancelable: true });
      await act(async () => { first.dispatchEvent(back); });
      assert.equal(back.defaultPrevented, true, 'Shift+Tab from the first control wraps');
      assert.equal(doc.activeElement, last);

      await act(async () => { doc.dispatchEvent(new win.KeyboardEvent('keydown', { key: 'Escape', bubbles: true })); });
      assert.equal(doc.activeElement, q(doc, 'gear'), 'focus returns to the gear');
      await finishDrawerExit(doc, win);
      assert.equal(q(doc, 'agent-panel'), null);
    });
  });
}

test('docked panel is not modal (an inspector beside the conversation)', async () => {
  await withDom(1440, async ({ doc, render }) => {
    await loadPanelModules();
    await render(React.createElement(Harness));
    await click(q(doc, 'gear'));
    assert.equal(q(doc, 'agent-panel-dialog'), null);
    assert.equal(doc.querySelector('[aria-modal="true"]'), null);
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

test('mobile page (<768): full-screen page with a 44px back button, min-h-14 header, subtitle, and slide-out exit', async () => {
  await withDom(390, async ({ doc, render, win }) => {
    await loadPanelModules();
    await render(React.createElement(Harness));
    await click(q(doc, 'gear'));
    const panel = q(doc, 'agent-panel')!;
    assert.equal(panel.getAttribute('data-mode'), 'page');
    const dialog = q(doc, 'agent-panel-dialog')!;
    assert.match(dialog.className, /!max-w-none/, 'full width');
    assert.ok(dialog.className.includes('animate-drawer-right-in'), 'page slides in from right');
    const header = q(doc, 'agent-panel-header')!;
    assert.ok(header.className.includes('min-h-14'), 'mobile page header stays min-h-14 (56px)');
    assert.equal(header.contains(q(doc, 'agent-panel-subtitle')!), true, 'mobile page keeps subtitle in header');
    const back = q(doc, 'agent-panel-back')!;
    assert.match(back.className, /\bh-11\b/, 'back button is 44px');
    assert.equal(back.getAttribute('aria-label'), 'Back to the conversation');
    const heading = doc.getElementById(panel.getAttribute('aria-labelledby')!)!;
    assert.equal(heading.textContent, 'Agent settings');
    assert.equal(doc.activeElement, heading);
    await click(back);
    assert.ok(q(doc, 'agent-panel-dialog')!.className.includes('animate-drawer-right-out'), 'page slides out to right');
    assert.equal(doc.activeElement, q(doc, 'gear'));
    await finishDrawerExit(doc, win);
    assert.equal(q(doc, 'agent-panel'), null);
  });
});

test('docked: reduced motion unmounts immediately on close and subtitle precedes runtime', async () => {
  await withDom(1440, async ({ doc, render, win }) => {
    win.matchMedia = (query: string) => ({
      matches: query === '(prefers-reduced-motion: reduce)',
      media: query,
      addEventListener() {},
      removeEventListener() {},
    });
    await loadPanelModules();
    await render(React.createElement(Harness));
    await click(q(doc, 'gear'));
    const subtitle = q(doc, 'agent-panel-subtitle')!;
    const runtime = q(doc, 'runtime-slot')!;
    assert.ok(
      Boolean(subtitle.compareDocumentPosition(runtime) & win.Node.DOCUMENT_POSITION_FOLLOWING),
      'subtitle appears above RuntimeSection in panel body',
    );
    await click(q(doc, 'agent-panel-close'));
    assert.equal(q(doc, 'agent-panel'), null, 'reduced motion unmounts docked panel immediately');
    assert.equal(q(doc, 'agent-panel-dock-shell')!.getAttribute('data-state'), 'closed');
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
  const { normalizeInstanceReconfiguration } = await import('../src/ui/api/endpoints/agents.ts');
  // The hub sends the phase as its enum ordinal (waiting_for_idle was appended: 7) or as a string.
  assert.equal(normalizeInstanceReconfiguration({ phase: 'waiting_for_idle' }).phase, 'waiting_for_idle');
  assert.equal(normalizeInstanceReconfiguration({ phase: 7 }).phase, 'waiting_for_idle');
  assert.equal(normalizeInstanceReconfiguration({ phase: 'bogus' }).phase, 'recovery_required');
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
    assert.ok(q(doc, 'agent-panel-runtime-force-stop'));
    let reachedDocument = false;
    const spy = () => { reachedDocument = true; };
    doc.addEventListener('keydown', spy, true);
    await act(async () => { doc.activeElement!.dispatchEvent(new (doc.defaultView as any).KeyboardEvent('keydown', { key: 'Escape', bubbles: true })); });
    doc.removeEventListener('keydown', spy, true);
    assert.equal(q(doc, 'agent-panel-runtime-force-stop'), null, 'Esc closes the menu');
    assert.equal(reachedDocument, false, 'and does not reach a hosting Drawer');
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
