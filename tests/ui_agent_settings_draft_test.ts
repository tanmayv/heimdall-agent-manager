// Agent settings panel (T6): the draft model (reducer, bridge fallback, diff, Apply
// gate), the ACP copy mapping, the radiogroup keys, and the four sections' markup.
//
// RUN: node --import ./tests/helpers/vaultEndpointHarness.ts --test tests/ui_agent_settings_draft_test.ts

import './helpers/vaultEndpointHarness.ts';
import { test } from 'node:test';
import assert from 'node:assert/strict';
import React, { act } from 'react';
import { JSDOM } from 'jsdom';

const draftMod = () => import('../src/ui/components/agentSettings/agentSettingsDraft.ts');
const copyMod = () => import('../src/ui/components/agentSettings/acpAvailabilityCopy.ts');

const base = { bridgeId: 'brg_a', provider: 'claude', providerProfile: 'claude', model: 'default', transport: 'pty' as const, bypass: true };
const opt = (id: string, extra: Record<string, any> = {}) => ({
  id, provider: extra.provider || id, label: extra.label || id, installed: true, disabledOnBridge: false,
  version: '1.0.0', models: [`${id}-m1`, `${id}-m2`], acp: null, checkedAt: null, ...extra,
});

// ---------------------------------------------------------------- reducer

test('bridge change keeps an installed provider and its model', async () => {
  const { reduceAgentDraft } = await draftMod();
  const next = reduceAgentDraft(base, { type: 'bridge', bridgeId: 'brg_b', providers: [opt('codex'), opt('claude', { models: ['default', 'claude-sonnet-5-5'] })] });
  assert.deepEqual(next, { ...base, bridgeId: 'brg_b' });
});

test('bridge change: provider not installed there -> first installed provider and its first model', async () => {
  const { reduceAgentDraft } = await draftMod();
  const providers = [opt('gemini', { installed: false }), opt('claude', { installed: false }), opt('codex', { models: ['gpt-5', 'gpt-5-mini'] })];
  const next = reduceAgentDraft(base, { type: 'bridge', bridgeId: 'brg_b', providers });
  assert.equal(next.bridgeId, 'brg_b');
  assert.equal(next.provider, 'codex');
  assert.equal(next.providerProfile, 'codex');
  assert.equal(next.model, 'gpt-5');
  assert.equal(next.transport, 'pty');
  assert.equal(next.bypass, true);
});

test('bridge change: installed provider whose model is gone -> that provider\'s first model', async () => {
  const { reduceAgentDraft } = await draftMod();
  const next = reduceAgentDraft({ ...base, model: 'retired' }, { type: 'bridge', bridgeId: 'brg_b', providers: [opt('claude', { models: ['default', 'x'] })] });
  assert.equal(next.model, 'default');
});

test('bridge change with providers still loading keeps the provider; reconcile applies the fallback later', async () => {
  const { reduceAgentDraft, reconcileDraftProviders } = await draftMod();
  const moved = reduceAgentDraft(base, { type: 'bridge', bridgeId: 'brg_b', providers: null });
  assert.deepEqual(moved, { ...base, bridgeId: 'brg_b' });
  const fixed = reconcileDraftProviders(moved, [opt('codex', { models: ['gpt-5'] })]);
  assert.equal(fixed.provider, 'codex');
  assert.equal(fixed.model, 'gpt-5');
  // Nothing installed at all: unchanged (the section says so instead).
  assert.equal(reconcileDraftProviders(moved, [opt('codex', { installed: false })]), moved);
  // Same bridge: no-op returns the same object.
  assert.equal(reduceAgentDraft(base, { type: 'bridge', bridgeId: 'brg_a', providers: [] }), base);
});

test('provider change resets the model to that provider\'s first model; profiles keep their driver', async () => {
  const { reduceAgentDraft } = await draftMod();
  const providers = [opt('claude'), opt('claude-work', { provider: 'claude', models: ['opus', 'sonnet'] }), opt('gemini', { installed: false })];
  const next = reduceAgentDraft(base, { type: 'provider', id: 'claude-work', providers });
  assert.equal(next.provider, 'claude');
  assert.equal(next.providerProfile, 'claude-work');
  assert.equal(next.model, 'opus');
  // Not installed, unknown, or already selected: unchanged.
  assert.equal(reduceAgentDraft(base, { type: 'provider', id: 'gemini', providers }), base);
  assert.equal(reduceAgentDraft(base, { type: 'provider', id: 'nope', providers }), base);
  assert.equal(reduceAgentDraft(base, { type: 'provider', id: 'claude', providers }), base);
});

test('model, transport, bypass and reset', async () => {
  const { reduceAgentDraft } = await draftMod();
  assert.equal(reduceAgentDraft(base, { type: 'model', model: 'x' }).model, 'x');
  assert.equal(reduceAgentDraft(base, { type: 'transport', transport: 'acp' }).transport, 'acp');
  assert.equal(reduceAgentDraft(base, { type: 'bypass', bypass: false }).bypass, false);
  assert.equal(reduceAgentDraft(base, { type: 'model', model: 'default' }), base);
  const other = { ...base, model: 'y' };
  assert.equal(reduceAgentDraft(other, { type: 'reset', config: base }), base);
});

// ---------------------------------------------------------------- diff

test('diff lists every changed field in panel order with display values', async () => {
  const { draftDiff } = await draftMod();
  assert.deepEqual(draftDiff(base, base), []);
  const draft = { bridgeId: 'brg_b', provider: 'codex', providerProfile: 'codex', model: 'gpt-5', transport: 'acp' as const, bypass: false };
  const labels = { bridgeLabel: (id: string) => ({ brg_a: 'riverwood', brg_b: 'dawnstar' } as any)[id], providerLabel: (c: any) => (c.provider === 'codex' ? 'Codex' : 'Claude Code') };
  assert.deepEqual(draftDiff(base, draft, labels), [
    { field: 'bridge', label: 'Bridge', from: 'riverwood', to: 'dawnstar' },
    { field: 'provider', label: 'Provider', from: 'Claude Code', to: 'Codex' },
    { field: 'model', label: 'Model', from: 'default', to: 'gpt-5' },
    { field: 'connection', label: 'Connection', from: 'PTY', to: 'ACP' },
    { field: 'bypass', label: 'Bypass', from: 'on', to: 'off' },
  ]);
  // A profile switch on the same driver is a provider change.
  assert.deepEqual(draftDiff(base, { ...base, providerProfile: 'claude-work' }).map((c) => c.field), ['provider']);
});

// ---------------------------------------------------------------- Apply gate

test('applyBlockedReason: ACP blocked unless the hub says available for the draft bridge + provider', async () => {
  const { applyBlockedReason, ACP_APPLY_BLOCKED_MESSAGE } = await draftMod();
  const acp = { ...base, transport: 'acp' as const };
  const ready = { available: true, reason: 'ready', fix: null };
  const missing = { available: false, reason: 'adapter_missing', fix: 'install_adapter' };
  assert.equal(applyBlockedReason(base, null), null, 'PTY never blocks');
  assert.equal(applyBlockedReason(acp, [opt('claude', { acp: ready })]), null);
  assert.deepEqual(applyBlockedReason(acp, [opt('claude', { acp: missing })]), { code: 'acp_unavailable', message: ACP_APPLY_BLOCKED_MESSAGE });
  assert.equal(ACP_APPLY_BLOCKED_MESSAGE, 'Fix the connection above before applying.');
  assert.equal(applyBlockedReason(acp, null)?.code, 'acp_unavailable', 'still loading');
  assert.equal(applyBlockedReason(acp, [opt('claude', { acp: null })])?.code, 'acp_unavailable', 'older hub');
  assert.equal(applyBlockedReason(acp, [opt('codex', { acp: ready })])?.code, 'acp_unavailable', 'verdict of another provider');
});

// ---------------------------------------------------------------- ACP copy

test('ACP copy is mapped from acp_availability reason/fix only', async () => {
  const { acpAvailabilityCopy } = await copyMod();
  const names = { provider: 'Claude Code', bridge: 'dawnstar' };
  const v = (reason: string, fix: string | null) => acpAvailabilityCopy({ available: reason === 'ready', reason, fix } as any, names);
  assert.deepEqual(v('ready', null), { kind: 'ready' });
  assert.deepEqual(v('no_recipe', null), { kind: 'problem', text: 'Claude Code has no ACP support yet. Use PTY.', action: null });
  assert.deepEqual(v('unsupported_bridge', 'update_bridge'), {
    kind: 'problem', text: 'dawnstar runs a bridge version without ACP support. Update it to the latest release.',
    action: { fix: 'update_bridge', label: 'Update bridge' },
  });
  for (const reason of ['adapter_missing', 'adapter_outdated', 'adapter_error']) {
    assert.deepEqual(v(reason, 'install_adapter'), {
      kind: 'problem', text: "The Claude Code ACP adapter isn't installed on dawnstar.",
      action: { fix: 'install_adapter', label: 'Install adapter' },
    }, reason);
  }
  // A missing host prerequisite names the tool, not the adapter (G4).
  assert.deepEqual(v('adapter_missing_node', 'install_adapter'), {
    kind: 'problem', text: 'Node.js is missing or too old on dawnstar.', action: { fix: 'install_adapter', label: 'Check again' },
  });
  assert.deepEqual(v('adapter_missing_npm', 'install_adapter'), {
    kind: 'problem', text: 'npm is missing on dawnstar.', action: { fix: 'install_adapter', label: 'Check again' },
  });
  assert.deepEqual(v('installing', null), { kind: 'installing', text: 'Installing the ACP adapter on dawnstar…' });
  assert.deepEqual(v('not_checked', 'check_now'), {
    kind: 'problem', text: "ACP hasn't been checked on dawnstar.", action: { fix: 'check_now', label: 'Check now' }, titled: false,
  });
  // The action follows the hub's fix, never the reason.
  assert.equal(v('adapter_error', null).kind === 'problem' && (v('adapter_error', null) as any).action, null);
  // No verdict (loading / older hub) reads as not checked.
  assert.deepEqual(acpAvailabilityCopy(null, names), {
    kind: 'problem', text: "ACP hasn't been checked on dawnstar.", action: { fix: 'check_now', label: 'Check now' }, titled: false,
  });
});

// ---------------------------------------------------------------- view models

test('bridge rows: connected / offline / no folder, revoked hidden, header count', async () => {
  const { bridgeRowsView } = await draftMod();
  const view = bridgeRowsView({
    bridges: [
      { bridge_id: 'brg_a', label: 'riverwood', machine_os: 'Fedora Atomic', status: 'online' },
      { bridge_id: 'brg_b', label: 'dawnstar', machine_os: 'Linux', status: 'online' },
      { bridge_id: 'brg_c', label: 'mac', status: 'offline' },
      { bridge_id: 'brg_d', label: 'nofolder', status: 'online' },
      { bridge_id: 'brg_r', label: 'gone', status: 'revoked' },
      { bridge_id: 'brg_p', label: 'suspended', status: 'online', plan_disabled_at: '2026-01-01T00:00:00Z' },
    ],
    currentBridgeId: 'brg_a',
    projectId: 'prj',
    bridgePaths: [{ bridge_id: 'brg_b', path: '/home/t/repo' }, { bridge_id: 'brg_c', path: '/Users/t/repo' }],
    currentFolder: '/var/home/t/repo',
  });
  assert.deepEqual(view.rows.map((r) => [r.bridgeId, r.status, r.statusText, r.folder, r.disabled, r.current]), [
    ['brg_a', 'connected', 'Connected · Fedora Atomic', '/var/home/t/repo', false, true],
    ['brg_b', 'connected', 'Connected · Linux', '/home/t/repo', false, false],
    ['brg_c', 'offline', 'Offline', '/Users/t/repo', true, false],
    ['brg_d', 'no_folder', 'No folder for this project', '', true, false],
    ['brg_p', 'offline', 'Offline', '', true, false],
  ]);
  assert.equal(view.header, '3 of 5 connected');
  // The project's default folder serves bridges without their own path; no project = no folder rule.
  const withDefault = bridgeRowsView({ bridges: [{ bridge_id: 'brg_d', status: 'online' }], currentBridgeId: '', projectId: 'prj', bridgePaths: [], defaultPath: '/srv/repo' });
  assert.equal(withDefault.rows[0].status, 'connected');
  assert.equal(withDefault.rows[0].folder, '/srv/repo');
  const noProject = bridgeRowsView({ bridges: [{ bridge_id: 'brg_d', status: 'online' }], currentBridgeId: '', projectId: '', bridgePaths: [] });
  assert.equal(noProject.rows[0].status, 'connected');
  assert.equal(noProject.rows[0].statusText, 'Connected');
});

test('provider options from provider-status rows', async () => {
  const { providerOptionsFromStatus, providerStatusLine, modelOptionLabel, lastCheckedAt, providerVersion } = await draftMod();
  const options = providerOptionsFromStatus({ providers: [
    { provider: 'claude', display_name: 'Claude Code', label: 'Claude Code', state: 'present', enabled: true, catalog_state: 'active', version_text: '2.1.0 (Claude Code)',
      models: [{ model_id: 'default', state: 'active' }, { model_id: 'old', state: 'retired' }], acp_availability: { available: true, reason: 'ready', fix: null }, checked_at: '2026-11-26T14:00:00Z' },
    { provider: 'codex', display_name: 'Codex', state: 'present', enabled: false, catalog_state: 'active', version_text: 'v0.98.0', models: [], checked_at: '2026-11-26T15:00:00Z' },
    { provider: 'gemini', display_name: 'Gemini CLI', state: 'absent', enabled: false, catalog_state: 'active', models: [] },
    { provider: 'kiro', display_name: 'Kiro', state: 'present', enabled: true, catalog_state: 'retired', models: [] },
  ] });
  assert.deepEqual(options.map((o) => [o.id, o.installed, o.version, o.models]), [
    ['claude', true, '2.1.0', ['default']],
    ['codex', false, '0.98.0', []],
    ['gemini', false, '', []],
  ]);
  assert.equal(options[0].acp?.reason, 'ready');
  assert.equal(providerStatusLine(options[0], 'riverwood'), 'Installed · v2.1.0');
  assert.equal(providerStatusLine(options[1], 'riverwood'), 'Not enabled on riverwood');
  assert.equal(providerStatusLine(options[2], 'riverwood'), 'Not installed on riverwood');
  assert.equal(modelOptionLabel('default'), 'default (provider picks)');
  assert.equal(modelOptionLabel('gpt-5'), 'gpt-5');
  assert.equal(lastCheckedAt(options), '2026-11-26T15:00:00Z');
  assert.equal(providerVersion('v1.2.3-beta.1'), '1.2.3-beta.1');
});

test('permissions second line follows the draft', async () => {
  const { permissionsDetail, PERMISSIONS_DESCRIPTION } = await draftMod();
  assert.equal(permissionsDetail({ bypass: true, transport: 'pty' }, 'Claude Code'), 'Turn it off to approve each tool call yourself.');
  assert.equal(permissionsDetail({ bypass: false, transport: 'acp' }, 'Claude Code'), 'Approvals appear in the conversation as they happen.');
  assert.equal(permissionsDetail({ bypass: false, transport: 'pty' }, 'Claude Code'), 'In PTY, approvals show in the terminal. Install the Claude Code extension to approve from chat.');
  assert.equal(PERMISSIONS_DESCRIPTION, "The agent runs tools without asking. New agents use the default set in the agent's settings.");
});

test('radiogroup keys skip disabled options and wrap', async () => {
  const { radioKeyTarget, radioTabStop } = await import('../src/ui/components/agentSettings/radioGroup.ts');
  const items = [{ value: 'a' }, { value: 'b', disabled: true }, { value: 'c' }];
  assert.equal(radioKeyTarget(items, 'a', 'ArrowDown'), 'c');
  assert.equal(radioKeyTarget(items, 'c', 'ArrowRight'), 'a');
  assert.equal(radioKeyTarget(items, 'a', 'ArrowUp'), 'c');
  assert.equal(radioKeyTarget(items, 'c', 'Home'), 'a');
  assert.equal(radioKeyTarget(items, 'a', 'End'), 'c');
  assert.equal(radioKeyTarget(items, 'a', 'x'), null);
  assert.equal(radioTabStop(items, 'c'), 'c');
  assert.equal(radioTabStop(items, 'b'), 'a', 'a disabled selection hands the tab stop to the first enabled');
});

// ---------------------------------------------------------------- markup

async function withDom(run: (ctx: { doc: Document; render: (el: React.ReactElement) => Promise<void> }) => Promise<void>) {
  const dom = new JSDOM('<!doctype html><div id="root"></div>', { url: 'http://localhost/', pretendToBeVisual: true });
  const win = dom.window as any;
  win.matchMedia = () => ({ matches: false, addEventListener() {}, removeEventListener() {}, addListener() {}, removeListener() {} });
  const keys = ['window', 'document', 'HTMLElement', 'Node', 'Element', 'KeyboardEvent', 'navigator', 'IS_REACT_ACT_ENVIRONMENT'];
  const saved = new Map(keys.map((k) => [k, Object.getOwnPropertyDescriptor(globalThis, k)]));
  for (const [k, v] of Object.entries({ window: win, document: win.document, HTMLElement: win.HTMLElement, Node: win.Node, Element: win.Element,
    KeyboardEvent: win.KeyboardEvent, navigator: win.navigator, IS_REACT_ACT_ENVIRONMENT: true })) {
    Object.defineProperty(globalThis, k, { value: v, configurable: true, writable: true });
  }
  const { createRoot } = await import('react-dom/client');
  const root = createRoot(win.document.getElementById('root'));
  try {
    await run({ doc: win.document, render: async (el) => { await act(async () => root.render(el)); } });
  } finally {
    await act(async () => root.unmount());
    dom.window.close();
    for (const [k, d] of saved) { if (d) Object.defineProperty(globalThis, k, d); else delete (globalThis as any)[k]; }
  }
}
const q = (doc: Document, id: string) => doc.querySelector(`[data-debug-id="${id}"]`) as HTMLElement | null;

test('Runs on: radiogroup rows, Current badge, disabled offline/no-folder rows, selection edits the draft', async () => {
  await withDom(async ({ doc, render }) => {
    const { BridgeSection } = await import('../src/ui/components/agentSettings/BridgeSection.tsx');
    const { bridgeRowsView } = await draftMod();
    const view = bridgeRowsView({
      bridges: [
        { bridge_id: 'brg_a', label: 'riverwood', machine_os: 'Fedora Atomic', status: 'online' },
        { bridge_id: 'brg_b', label: 'dawnstar', status: 'online' },
        { bridge_id: 'brg_c', label: 'mac', status: 'offline' },
      ],
      currentBridgeId: 'brg_a', projectId: 'prj', bridgePaths: [{ bridge_id: 'brg_b', path: '/home/t/repo' }], currentFolder: '/var/home/t/repo',
    });
    const picked: string[] = [];
    await render(React.createElement(BridgeSection, { view, selected: 'brg_a', onSelect: (id: string) => picked.push(id), manageFoldersHref: '#/projects/prj/edit' }));
    const section = q(doc, 'agent-panel-bridge')!;
    assert.ok(section);
    const group = section.querySelector('[role="radiogroup"]')!;
    const radios = Array.from(group.querySelectorAll('[role="radio"]')) as HTMLElement[];
    assert.equal(radios.length, 3);
    assert.deepEqual(radios.map((r) => r.getAttribute('aria-checked')), ['true', 'false', 'false']);
    assert.deepEqual(radios.map((r) => r.tabIndex), [0, -1, -1]);
    assert.ok(radios[0].className.includes('bg-surface-overlay'));
    assert.ok(radios[0].querySelector('.text-accent'), 'gold check on the selected row');
    assert.ok(!radios[1].querySelector('.text-accent'));
    assert.equal(radios[2].getAttribute('aria-disabled'), 'true');
    assert.ok(radios[2].className.includes('opacity-[0.45]'));
    assert.equal(q(doc, 'agent-panel-bridge-current')?.textContent, 'Current');
    assert.equal(q(doc, 'agent-panel-bridge-count')?.textContent, '2 of 3 connected');
    assert.match(section.textContent || '', /Connected · Fedora Atomic/);
    assert.equal(q(doc, 'agent-panel-bridge-manage-folders')?.getAttribute('href'), '#/projects/prj/edit');
    assert.match(q(doc, 'agent-panel-bridge-help')?.textContent || '', /A bridge needs this project's folder to run the agent\./);
    await act(async () => radios[2].click());
    assert.deepEqual(picked, [], 'disabled row does not select');
    await act(async () => radios[1].click());
    assert.deepEqual(picked, ['brg_b']);
    await act(async () => { radios[0].dispatchEvent(new (globalThis as any).KeyboardEvent('keydown', { key: 'ArrowDown', bubbles: true })); });
    assert.deepEqual(picked, ['brg_b', 'brg_b'], 'ArrowDown moves to the next enabled row');
  });
});

test('Model: provider radiogroup scoped to the bridge, model Select labelled, refresh states', async () => {
  await withDom(async ({ doc, render }) => {
    const { ModelSection } = await import('../src/ui/components/agentSettings/ModelSection.tsx');
    const providers = [
      opt('claude', { label: 'Claude Code', version: '2.1.0', models: ['default', 'claude-sonnet-5-5'] }),
      opt('gemini', { label: 'Gemini CLI', installed: false }),
    ];
    const chosen: string[] = [];
    const props = {
      providers, loaded: true, selectedProvider: 'claude', selectedModel: 'default', bridgeLabel: 'riverwood',
      onSelectProvider: (id: string) => chosen.push(id), onSelectModel: () => {}, onRefresh: () => chosen.push('refresh'),
      refreshing: false, checkedAt: '2026-11-26T14:00:00Z',
    };
    await render(React.createElement(ModelSection, props));
    const section = q(doc, 'agent-panel-model')!;
    const radios = Array.from(section.querySelectorAll('[role="radiogroup"] [role="radio"]')) as HTMLElement[];
    assert.deepEqual(radios.map((r) => r.getAttribute('aria-checked')), ['true', 'false']);
    assert.match(radios[0].textContent || '', /Installed · v2\.1\.0/);
    assert.match(radios[1].textContent || '', /Not installed on riverwood/);
    assert.equal(radios[1].getAttribute('aria-disabled'), 'true');
    await act(async () => radios[1].click());
    assert.deepEqual(chosen, []);
    const select = q(doc, 'agent-panel-model-select')!;
    const labelId = select.getAttribute('aria-labelledby')!;
    assert.equal(doc.getElementById(labelId)?.textContent, 'Model for Claude Code on riverwood');
    assert.match(select.textContent || '', /default \(provider picks\)/);
    const refresh = q(doc, 'agent-panel-model-refresh')!;
    assert.match(refresh.textContent || '', /^Refresh · checked /);
    await act(async () => refresh.click());
    assert.deepEqual(chosen, ['refresh']);
    await render(React.createElement(ModelSection, { ...props, refreshing: true }));
    assert.match(q(doc, 'agent-panel-model-refresh')?.textContent || '', /Checking models…/);
  });
});

test('Connection: two radio cards; ACP alert role=alert with the hub fix; installing status row', async () => {
  await withDom(async ({ doc, render }) => {
    const { ConnectionSection } = await import('../src/ui/components/agentSettings/ConnectionSection.tsx');
    const { acpAvailabilityCopy } = await copyMod();
    const events: string[] = [];
    const names = { provider: 'Claude Code', bridge: 'dawnstar' };
    const props = { selected: 'pty' as const, onSelect: (t: string) => events.push(t), onFix: (f: string) => events.push(`fix:${f}`),
      acp: acpAvailabilityCopy({ available: false, reason: 'unsupported_bridge', fix: 'update_bridge' }, names) };
    await render(React.createElement(ConnectionSection, props));
    const section = q(doc, 'agent-panel-connection')!;
    const radios = Array.from(section.querySelectorAll('[role="radio"]')) as HTMLElement[];
    assert.deepEqual(radios.map((r) => r.getAttribute('aria-checked')), ['true', 'false']);
    assert.ok(radios[0].className.includes('border-accent'), 'gold border on the selected card');
    assert.ok(!radios[1].className.includes('border-accent'));
    assert.match(radios[0].textContent || '', /PTYTerminal.*Runs the provider's own terminal UI\. Works with every provider and bridge\./);
    assert.match(radios[1].textContent || '', /ACPStructured.*Messages, tool calls and approvals as native chat\. Supports Send now\./);
    assert.equal(section.querySelector('[role="alert"]'), null, 'PTY shows no ACP alert');
    await act(async () => radios[1].click());
    assert.deepEqual(events, ['acp']);

    await render(React.createElement(ConnectionSection, { ...props, selected: 'acp' }));
    const alert = q(doc, 'agent-panel-connection-acp-alert')!;
    assert.equal(alert.getAttribute('role'), 'alert');
    assert.match(alert.textContent || '', /^ACP isn't available\.\s*dawnstar runs a bridge version without ACP support\. Update it to the latest release\./);
    await act(async () => q(doc, 'agent-panel-connection-fix-update_bridge')!.click());
    assert.deepEqual(events, ['acp', 'fix:update_bridge']);

    await render(React.createElement(ConnectionSection, { ...props, selected: 'acp', acp: acpAvailabilityCopy({ available: false, reason: 'no_recipe', fix: null }, names) }));
    assert.equal(doc.querySelectorAll('[data-debug-id^="agent-panel-connection-fix-"]').length, 0, 'no_recipe has no action');

    await render(React.createElement(ConnectionSection, { ...props, selected: 'acp', acp: acpAvailabilityCopy({ available: false, reason: 'installing', fix: null }, names) }));
    const installing = q(doc, 'agent-panel-connection-installing')!;
    assert.equal(installing.getAttribute('role'), 'status');
    assert.match(installing.textContent || '', /Installing the ACP adapter on dawnstar…/);
    assert.equal(installing.querySelectorAll('[role="status"][aria-label]:not([aria-label=""])').length, 0, 'the spinner adds no second announcement');
    assert.equal(installing.querySelector('[aria-hidden="true"] [role="status"]') !== null, true, 'spinner is decorative');
    assert.equal(doc.querySelector('[role="alert"]'), null);
  });
});

test('Connection: picking ACP scrolls the ACP alert into view; mounting on ACP does not; not_checked has no title', async () => {
  await withDom(async ({ doc, render }) => {
    const { ConnectionSection } = await import('../src/ui/components/agentSettings/ConnectionSection.tsx');
    const { acpAvailabilityCopy } = await copyMod();
    const names = { provider: 'Claude Code', bridge: 'dawnstar' };
    const scrolled: unknown[] = [];
    const view = doc.defaultView as any;
    const original = view.HTMLElement.prototype.scrollIntoView;
    view.HTMLElement.prototype.scrollIntoView = function (this: HTMLElement, arg: unknown) { scrolled.push([this.querySelector('[role="alert"]')?.getAttribute('data-debug-id'), arg]); };
    const tick = () => act(async () => { await new Promise((r) => setTimeout(r, 20)); });
    try {
      const missing = acpAvailabilityCopy({ available: false, reason: 'adapter_missing', fix: 'install_adapter' }, names);
      const props = { onSelect: () => {}, onFix: () => {}, acp: missing };
      // Mounted already on ACP (an ACP instance): no scroll.
      await render(React.createElement(ConnectionSection, { ...props, selected: 'acp' as const }));
      await tick();
      assert.deepEqual(scrolled, [], 'no scroll on mount');
      await render(React.createElement(ConnectionSection, { ...props, selected: 'pty' as const }));
      await tick();
      // The user picks ACP: the alert comes into view (nearest edge, no jump to the top).
      await render(React.createElement(ConnectionSection, { ...props, selected: 'acp' as const }));
      await tick();
      assert.deepEqual(scrolled, [['agent-panel-connection-acp-alert', { block: 'nearest' }]]);
      const alert = q(doc, 'agent-panel-connection-acp-alert')!;
      assert.equal(alert.querySelector('.font-semibold')?.textContent, "ACP isn't available.", 'the Alert title is the lead');
      assert.equal(q(doc, 'agent-panel-connection-acp-alert-text')?.textContent, "The Claude Code ACP adapter isn't installed on dawnstar.");
      // Picking ACP when it can run does not scroll.
      await render(React.createElement(ConnectionSection, { ...props, selected: 'pty' as const, acp: { kind: 'ready' } }));
      await render(React.createElement(ConnectionSection, { ...props, selected: 'acp' as const, acp: { kind: 'ready' } }));
      await tick();
      assert.equal(scrolled.length, 1);
      // not_checked: the reason already names ACP, so no repeated lead.
      await render(React.createElement(ConnectionSection, { ...props, selected: 'acp' as const, acp: acpAvailabilityCopy({ available: false, reason: 'not_checked', fix: 'check_now' }, names) }));
      assert.equal(q(doc, 'agent-panel-connection-acp-alert')!.textContent?.startsWith("ACP hasn't been checked on dawnstar."), true);
    } finally {
      view.HTMLElement.prototype.scrollIntoView = original;
    }
  });
});

test('Permissions: role=switch toggle with the description and the draft-driven line', async () => {
  await withDom(async ({ doc, render }) => {
    const { PermissionsSection } = await import('../src/ui/components/agentSettings/PermissionsSection.tsx');
    const changes: boolean[] = [];
    await render(React.createElement(PermissionsSection, { bypass: true, transport: 'pty', providerLabel: 'Claude Code', onChange: (b: boolean) => changes.push(b) }));
    const toggle = q(doc, 'agent-panel-permissions-toggle')!;
    assert.equal(toggle.getAttribute('role'), 'switch');
    assert.equal(toggle.getAttribute('aria-checked'), 'true');
    assert.ok(toggle.className.includes('bg-accent'), 'gold when on');
    assert.equal(doc.getElementById(toggle.getAttribute('aria-labelledby')!)?.textContent, 'Bypass permissions');
    assert.equal(q(doc, 'agent-panel-permissions-detail')?.textContent, 'Turn it off to approve each tool call yourself.');
    await act(async () => toggle.click());
    assert.deepEqual(changes, [false]);
    await render(React.createElement(PermissionsSection, { bypass: false, transport: 'pty', providerLabel: 'Claude Code', onChange: () => {} }));
    assert.equal(q(doc, 'agent-panel-permissions-toggle')?.getAttribute('aria-checked'), 'false');
    assert.equal(q(doc, 'agent-panel-permissions-detail')?.textContent, 'In PTY, approvals show in the terminal. Install the Claude Code extension to approve from chat.');
    await render(React.createElement(PermissionsSection, { bypass: false, transport: 'acp', providerLabel: 'Claude Code', onChange: () => {} }));
    assert.equal(q(doc, 'agent-panel-permissions-detail')?.textContent, 'Approvals appear in the conversation as they happen.');
  });
});
