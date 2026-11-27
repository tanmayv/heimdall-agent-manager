// Agent settings panel (T7): the staged-changes footer and the Apply flow
// (useApplyAgentSettings.ts, ApplyFooter.tsx).
//
// RUN: node --import ./tests/helpers/vaultEndpointHarness.ts --test tests/ui_agent_settings_apply_test.ts

import './helpers/vaultEndpointHarness.ts';
import { test } from 'node:test';
import assert from 'node:assert/strict';
import React, { act } from 'react';
import { JSDOM } from 'jsdom';

async function withDom(run: (ctx: { doc: Document; render: (el: React.ReactElement) => Promise<void> }) => Promise<void>) {
  const dom = new JSDOM('<!doctype html><div id="root"></div>', { url: 'http://localhost/', pretendToBeVisual: true });
  const win = dom.window as any;
  win.matchMedia = () => ({ matches: false, addEventListener() {}, removeEventListener() {}, addListener() {}, removeListener() {} });
  const keys = ['window', 'document', 'HTMLElement', 'Node', 'Element', 'navigator', 'IS_REACT_ACT_ENVIRONMENT'];
  const saved = new Map(keys.map((k) => [k, Object.getOwnPropertyDescriptor(globalThis, k)]));
  for (const [k, v] of Object.entries({ window: win, document: win.document, HTMLElement: win.HTMLElement, Node: win.Node, Element: win.Element,
    navigator: win.navigator, IS_REACT_ACT_ENVIRONMENT: true })) {
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
const click = async (el: HTMLElement | null) => { assert.ok(el, 'element exists'); await act(async () => el!.click()); };

const mod = () => import('../src/ui/components/agentSettings/useApplyAgentSettings.ts');

const CURRENT = { bridgeId: 'riverwood', provider: 'claude', providerProfile: 'claude', model: 'opus', transport: 'pty' as const, bypass: false };

function op(overrides: Record<string, unknown> = {}): any {
  return {
    operation_id: 'op1', agent_instance_id: 'i1', conversation_id: 'c1', idempotency_key: 'k-op1', phase: 'prepared',
    source: {}, destination: {}, source_stopped: false, destination_committed: false, failure_code: '', failure_message: '',
    revision: 1, ...overrides,
  };
}

// ---------------------------------------------------------------- pure helpers

test('buildApplyRequest sends the full destination, always including project_id, transport and permission mode', async () => {
  const { buildApplyRequest } = await mod();
  const body = buildApplyRequest({
    instanceId: 'i1', projectId: 'p1', revision: 7, apply: 'after_turn',
    draft: { ...CURRENT, bridgeId: 'dawnstar', providerProfile: '', transport: 'acp', bypass: true },
  });
  assert.deepEqual(body, {
    instanceId: 'i1', bridge_id: 'dawnstar', project_id: 'p1', provider: 'claude', provider_profile: 'claude',
    model: 'opus', runtime_transport: 'acp', permission_mode: 'yolo', expected_revision: 7, apply: 'after_turn',
  });
  // Unchanged fields are resent too (bypass off -> 'ask', pty).
  const same = buildApplyRequest({ instanceId: 'i1', projectId: '', revision: 0, apply: 'now', draft: CURRENT });
  assert.equal(same.project_id, '');
  assert.equal(same.runtime_transport, 'pty');
  assert.equal(same.permission_mode, 'ask');
  assert.equal(same.apply, 'now');
});

function viewInput(overrides: Record<string, unknown> = {}): any {
  return {
    changes: [{ field: 'model', label: 'Model', from: 'opus', to: 'sonnet' }],
    flow: { phase: 'idle', error: '', conflict: [], waitingSince: '', queued: [] },
    midTurn: false, stopped: false, destinationBridge: 'riverwood', destinationFolder: '', blockedMessage: '', issues: [],
    busy: false, now: Date.parse('2026-11-26T12:00:00Z'), ...overrides,
  };
}

test('footer view: hidden when the draft equals the current configuration', async () => {
  const { applyFooterView } = await mod();
  assert.equal(applyFooterView(viewInput({ changes: [] })).visible, false);
});

test('footer view: normal, bridge move, mid-turn and stopped copy and buttons', async () => {
  const { applyFooterView, FOOTER_COPY } = await mod();
  const normal = applyFooterView(viewInput());
  assert.equal(normal.note, 'Restarts the agent with a fresh session. The conversation stays.');
  assert.equal(normal.primary?.label, 'Apply and restart');
  assert.equal(normal.primary?.disabled, false);
  assert.equal(normal.restartNow, null);
  assert.ok(normal.discard);

  const move = applyFooterView(viewInput({
    changes: [{ field: 'bridge', label: 'Bridge', from: 'riverwood', to: 'dawnstar' }],
    destinationBridge: 'dawnstar', destinationFolder: '~/src/app',
  }));
  assert.equal(move.note, 'Restarts the agent on dawnstar, in ~/src/app, with a fresh session. The conversation stays.');

  const mid = applyFooterView(viewInput({ midTurn: true }));
  assert.equal(mid.note, `${FOOTER_COPY.restart} It's mid-turn, so the restart waits for the turn to finish.`);
  assert.equal(mid.primary?.label, 'Restart after this turn');
  assert.equal(mid.primary?.kind, 'after_turn');
  assert.ok(mid.restartNow, 'mid-turn offers a ghost Restart now');

  const stopped = applyFooterView(viewInput({ stopped: true, midTurn: false }));
  assert.equal(stopped.note, 'Starts the agent with these settings.');
  assert.equal(stopped.primary?.label, 'Apply and start');
  assert.equal(stopped.restartNow, null);
});

test('footer view: ACP block and destination issues disable Apply', async () => {
  const { applyFooterView } = await mod();
  const blocked = applyFooterView(viewInput({ blockedMessage: 'Fix the connection above before applying.' }));
  assert.equal(blocked.primary?.disabled, true);
  assert.equal(blocked.blocked, 'Fix the connection above before applying.');
  assert.equal(blocked.discard?.disabled, false, 'Discard stays available');
  const issues = applyFooterView(viewInput({ issues: ['Destination bridge is not connected.'] }));
  assert.equal(issues.primary?.disabled, true);
});

test('footer view: waiting, still waiting after 30 min, restarting, conflict, failure, recovery', async () => {
  const { applyFooterView } = await mod();
  const now = Date.parse('2026-11-26T12:00:00Z');
  const waiting = applyFooterView(viewInput({ flow: { phase: 'waiting', error: '', conflict: [], waitingSince: '2026-11-26T11:45:00Z', queued: [] }, now }));
  assert.equal(waiting.status, 'Waiting for the turn to finish…');
  assert.ok(waiting.cancel);
  assert.equal(waiting.restartNow, null);
  assert.equal(waiting.primary, null);

  const still = applyFooterView(viewInput({ flow: { phase: 'waiting', error: '', conflict: [], waitingSince: '2026-11-26T11:30:00Z', queued: [] }, now }));
  assert.equal(still.status, 'Still waiting');
  assert.ok(still.restartNow);
  assert.ok(still.cancel);

  const restarting = applyFooterView(viewInput({ flow: { phase: 'restarting', error: '', conflict: [], waitingSince: '', queued: [] } }));
  assert.equal(restarting.status, 'Restarting the agent…');
  assert.equal(restarting.primary, null);

  const conflict = applyFooterView(viewInput({ flow: { phase: 'conflict', error: '', waitingSince: '',
    conflict: [{ field: 'model', label: 'Model', from: 'opus', to: 'haiku' }] } }));
  assert.equal(conflict.conflict, 'Changed since you opened: Model opus → haiku.');
  assert.ok(conflict.primary && !conflict.primary.disabled, 'the draft can be applied again');

  const failed = applyFooterView(viewInput({ flow: { phase: 'failed', error: 'bridge refused', conflict: [], waitingSince: '', queued: [] } }));
  assert.equal(failed.error, 'bridge refused');
  assert.equal(failed.primary?.label, 'Apply and restart');

  const recovery = applyFooterView(viewInput({ changes: [], flow: { phase: 'recovery', error: '', conflict: [], waitingSince: '', queued: [] } }));
  assert.equal(recovery.visible, true);
  assert.equal(recovery.primary?.kind, 'retry');
});

// ---------------------------------------------------------------- hook

type Calls = { reconfigure: any[]; retry: any[]; cancel: any[]; refetch: number; accepted: any[] };

async function hookHarness(render: (el: React.ReactElement) => Promise<void>) {
  const { useApplyAgentSettings } = await mod();
  const calls: Calls = { reconfigure: [], retry: [], cancel: [], refetch: 0, accepted: [] };
  const replies: { reconfigure: any[]; retry: any[]; cancel: any[] } = { reconfigure: [], retry: [], cancel: [] };
  let api: any = null;
  let props: any = {
    instanceId: 'i1', projectId: 'p1', current: CURRENT, draft: { ...CURRENT, model: 'sonnet' }, revision: 3,
    launchEpoch: 'e1', running: true, midTurn: false, operation: null,
  };
  function Harness(p: any) {
    api = useApplyAgentSettings({
      ...p,
      reconfigure: async (args: any) => { calls.reconfigure.push(args); return replies.reconfigure.shift(); },
      retry: async (args: any) => { calls.retry.push(args); return replies.retry.shift(); },
      cancel: async (args: any) => { calls.cancel.push(args); return replies.cancel.shift(); },
      refetchInstance: () => { calls.refetch += 1; },
      onAccepted: (o: any) => calls.accepted.push(o),
    });
    return null;
  }
  const update = async (next: Record<string, unknown> = {}) => { props = { ...props, ...next }; await render(React.createElement(Harness, props)); };
  await update();
  return { calls, replies, update, get api() { return api; } };
}

const accepted = (data: any) => ({ status: 'accepted', data, message: 'Configuration change requested.' });
const failed = (httpStatus: number | undefined, message: string) => ({ status: 'failed', error: new Error(message), message, httpStatus });

test('hook: success sends apply now with the full destination and stays Restarting until a new launch_epoch runs', async () => {
  await withDom(async ({ render }) => {
    const h = await hookHarness(render);
    h.replies.reconfigure.push(accepted(op()));
    await act(async () => { await h.api.apply(); });
    const sent = h.calls.reconfigure[0];
    assert.equal(sent.apply, 'now');
    assert.equal(sent.project_id, 'p1');
    assert.equal(sent.runtime_transport, 'pty');
    assert.equal(sent.permission_mode, 'ask');
    assert.equal(sent.expected_revision, 3);
    assert.equal(sent.model, 'sonnet');
    assert.ok(sent.idempotency_key);
    assert.equal(h.calls.accepted.length, 1);
    await h.update({ operation: op() });
    assert.equal(h.api.state.phase, 'restarting');
    // Ready, but the instance still reports the old launch: keep Restarting.
    await h.update({ operation: op({ phase: 'ready', revision: 4 }), running: false });
    assert.equal(h.api.state.phase, 'restarting');
    await h.update({ running: true, launchEpoch: 'e1' });
    assert.equal(h.api.state.phase, 'restarting');
    await h.update({ running: true, launchEpoch: 'e2', current: { ...CURRENT, model: 'sonnet' } });
    assert.equal(h.api.state.phase, 'idle');
  });
});

test('hook: 409 refetches the instance, keeps the draft and lists what changed since opening', async () => {
  await withDom(async ({ render }) => {
    const h = await hookHarness(render);
    h.replies.reconfigure.push(failed(409, 'configuration changed'));
    await act(async () => { await h.api.apply(); });
    assert.equal(h.calls.refetch, 1);
    // The refetched instance changed its transport under us; the draft (model) is kept.
    await h.update({ current: { ...CURRENT, transport: 'acp' }, draft: { ...CURRENT, transport: 'acp', model: 'sonnet' }, revision: 4 });
    assert.equal(h.api.state.phase, 'conflict');
    assert.deepEqual(h.api.state.conflict.map((c: any) => [c.field, c.from, c.to]), [['connection', 'PTY', 'ACP']]);
    assert.deepEqual(h.api.changes.map((c: any) => c.field), ['model']);
    // Applying again uses the new revision.
    h.replies.reconfigure.push(accepted(op({ operation_id: 'op2' })));
    await act(async () => { await h.api.apply(); });
    assert.equal(h.calls.reconfigure[1].expected_revision, 4);
    assert.equal(h.calls.reconfigure[1].runtime_transport, 'acp');
  });
});

test('hook: a failure shows the hub error and keeps the draft; only ambiguous failures replay the key', async () => {
  await withDom(async ({ render }) => {
    const h = await hookHarness(render);
    h.replies.reconfigure.push(failed(503, 'hub unavailable'));
    await act(async () => { await h.api.apply(); });
    assert.equal(h.api.state.phase, 'failed');
    assert.equal(h.api.state.error, 'hub unavailable');
    h.replies.reconfigure.push(failed(400, 'unknown model'));
    await act(async () => { await h.api.apply(); });
    assert.equal(h.calls.reconfigure[1].idempotency_key, h.calls.reconfigure[0].idempotency_key, '5xx replays the same intent');
    assert.equal(h.api.state.error, 'unknown model');
    assert.equal(h.api.changes.length, 1, 'draft kept');
    h.replies.reconfigure.push(failed(400, 'unknown model'));
    await act(async () => { await h.api.apply(); });
    assert.notEqual(h.calls.reconfigure[2].idempotency_key, h.calls.reconfigure[1].idempotency_key, 'a definite refusal starts a new intent');
    await act(async () => { h.api.clear(); });
    await h.update();
    assert.equal(h.api.state.phase, 'idle');
  });
});

test('hook: an accepted operation that fails later shows its failure and keeps the draft', async () => {
  await withDom(async ({ render }) => {
    const h = await hookHarness(render);
    h.replies.reconfigure.push(accepted(op()));
    await act(async () => { await h.api.apply(); });
    await h.update({ operation: op({ phase: 'failed', failure_code: 'launch_failed', failure_message: 'claude not found', revision: 3 }) });
    await h.update();
    assert.equal(h.api.state.phase, 'failed');
    assert.equal(h.api.state.error, 'claude not found');
    assert.equal(h.api.changes.length, 1);
  });
});

test('hook: mid-turn queues after_turn; waiting offers Cancel and Restart now supersedes with apply now', async () => {
  await withDom(async ({ render }) => {
    const h = await hookHarness(render);
    await h.update({ midTurn: true });
    h.replies.reconfigure.push(accepted(op({ phase: 'waiting_for_idle', apply: 'after_turn', waiting_since: '2026-11-26T11:00:00Z' })));
    await act(async () => { await h.api.apply(); });
    assert.equal(h.calls.reconfigure[0].apply, 'after_turn');
    await h.update({ operation: op({ phase: 'waiting_for_idle', waiting_since: '2026-11-26T11:00:00Z', revision: 2 }) });
    assert.equal(h.api.state.phase, 'waiting');
    assert.equal(h.api.state.waitingSince, '2026-11-26T11:00:00Z');

    h.replies.cancel.push(accepted(op({ phase: 'failed', failure_code: 'cancelled', revision: 3 })));
    await act(async () => { await h.api.cancelWaiting(); });
    assert.deepEqual(h.calls.cancel[0], { instanceId: 'i1', idempotency_key: 'k-op1', expected_operation_revision: 2 });
    await h.update({ operation: op({ phase: 'failed', failure_code: 'cancelled', revision: 3 }) });
    assert.equal(h.api.state.phase, 'idle', 'cancelled: back to the dirty draft');
    assert.equal(h.api.changes.length, 1);

    // Queue again, then Restart now: apply 'now' with a NEW key.
    h.replies.reconfigure.push(accepted(op({ operation_id: 'op2', idempotency_key: 'k-op2', phase: 'waiting_for_idle' })));
    await act(async () => { await h.api.apply(); });
    await h.update({ operation: op({ operation_id: 'op2', idempotency_key: 'k-op2', phase: 'waiting_for_idle' }) });
    h.replies.reconfigure.push(accepted(op({ operation_id: 'op3', phase: 'prepared' })));
    await act(async () => { await h.api.restartNow(); });
    const now = h.calls.reconfigure[2];
    assert.equal(now.apply, 'now');
    assert.notEqual(now.idempotency_key, h.calls.reconfigure[1].idempotency_key);
    await h.update({ operation: op({ operation_id: 'op3', phase: 'stopping' }), midTurn: false });
    assert.equal(h.api.state.phase, 'restarting');
  });
});

test('hook: stopped agent applies now and finishes when it runs on a launch epoch', async () => {
  await withDom(async ({ render }) => {
    const h = await hookHarness(render);
    await h.update({ running: false, launchEpoch: '' });
    h.replies.reconfigure.push(accepted(op()));
    await act(async () => { await h.api.apply(); });
    assert.equal(h.calls.reconfigure[0].apply, 'now');
    await h.update({ operation: op({ phase: 'launching' }) });
    assert.equal(h.api.state.phase, 'restarting');
    await h.update({ operation: op({ phase: 'ready' }), running: true, launchEpoch: 'e9' });
    assert.equal(h.api.state.phase, 'idle');
  });
});

test('hook: recovery_required retries the operation through the retry endpoint', async () => {
  await withDom(async ({ render }) => {
    const h = await hookHarness(render);
    await h.update({ operation: op({ phase: 'recovery_required', revision: 5 }) });
    assert.equal(h.api.state.phase, 'recovery');
    h.replies.retry.push(accepted(op({ phase: 'launching', revision: 6 })));
    await act(async () => { await h.api.retry(); });
    assert.deepEqual(h.calls.retry[0], { instanceId: 'i1', idempotency_key: 'k-op1', expected_operation_revision: 5 });
    assert.equal(h.calls.reconfigure.length, 0);
    await h.update({ operation: op({ phase: 'launching', revision: 6 }) });
    assert.equal(h.api.state.phase, 'restarting');
  });
});

// ---------------------------------------------------------------- footer render

test('ApplyFooter renders chips with mono values, a hidden arrow and an sr-only "to"', async () => {
  await withDom(async ({ doc, render }) => {
    const { applyFooterView } = await mod();
    const { ApplyFooter } = await import('../src/ui/components/agentSettings/ApplyFooter.tsx');
    const calls: string[] = [];
    const handlers = { onApply: () => calls.push('apply'), onRestartNow: () => calls.push('now'), onCancel: () => calls.push('cancel'), onDiscard: () => calls.push('discard') };
    await render(React.createElement(ApplyFooter, {
      view: applyFooterView(viewInput({ changes: [{ field: 'bridge', label: 'Bridge', from: 'riverwood', to: 'dawnstar' }], destinationBridge: 'dawnstar' })),
      ...handlers,
    }));
    const footer = q(doc, 'agent-panel-apply');
    assert.ok(footer);
    const chip = q(doc, 'agent-panel-apply-chip')!;
    assert.match(chip.className, /rounded-\[var\(--radius-sm\)\]/, 'chips use radius-sm, not the pill radius');
    assert.doesNotMatch(chip.className, /rounded-full/);
    // The status region is mounted (empty) before anything happens, so its text changes are announced.
    assert.equal(q(doc, 'agent-panel-apply-status')!.getAttribute('role'), 'status');
    assert.equal(q(doc, 'agent-panel-apply-status')!.textContent, '');
    assert.equal(chip.textContent, 'Bridgeriverwood→todawnstar');
    assert.equal(chip.querySelectorAll('code').length, 2);
    assert.equal(chip.querySelector('[aria-hidden="true"]')?.textContent, '→');
    assert.equal(chip.querySelector('.sr-only')?.textContent, 'to');
    assert.match(q(doc, 'agent-panel-apply-note')!.textContent || '', /^Restarts the agent on dawnstar with a fresh session/);
    assert.equal(q(doc, 'agent-panel-apply-btn')!.textContent, 'Apply and restart');
    await click(q(doc, 'agent-panel-apply-discard'));
    await click(q(doc, 'agent-panel-apply-btn'));
    assert.deepEqual(calls, ['discard', 'apply']);

    // Mid-turn on touch: Restart now, then Discard 1 part + primary 2 parts, 44px.
    await render(React.createElement(ApplyFooter, { view: applyFooterView(viewInput({ midTurn: true })), touch: true, ...handlers }));
    assert.equal(q(doc, 'agent-panel-apply-btn')!.textContent, 'Restart after this turn');
    assert.match(q(doc, 'agent-panel-apply-btn')!.className, /col-span-2/);
    assert.match(q(doc, 'agent-panel-apply-btn')!.className, /min-h-11/);
    assert.match(q(doc, 'agent-panel-apply-discard')!.className, /col-span-1/);
    await click(q(doc, 'agent-panel-apply-restart-now'));
    assert.equal(calls.at(-1), 'now');

    // Blocked.
    await render(React.createElement(ApplyFooter, { view: applyFooterView(viewInput({ blockedMessage: 'Fix the connection above before applying.' })), ...handlers }));
    assert.equal((q(doc, 'agent-panel-apply-btn') as HTMLButtonElement).disabled, true);
    assert.equal(q(doc, 'agent-panel-apply-blocked')!.textContent, 'Fix the connection above before applying.');
    assert.equal(q(doc, 'agent-panel-apply-btn')!.getAttribute('aria-describedby'), q(doc, 'agent-panel-apply-blocked')!.id, 'disabled Apply is tied to its reason');

    // Waiting -> Cancel; still waiting -> Restart now too.
    await render(React.createElement(ApplyFooter, { view: applyFooterView(viewInput({ flow: { phase: 'waiting', error: '', conflict: [], waitingSince: '2026-11-26T10:00:00Z', queued: [] } })), ...handlers }));
    assert.equal(q(doc, 'agent-panel-apply-status')!.textContent, 'Still waiting');
    assert.equal(q(doc, 'agent-panel-apply-btn'), null);
    assert.equal(q(doc, 'agent-panel-apply-cancel')!.getAttribute('aria-label'), 'Cancel restart');
    await click(q(doc, 'agent-panel-apply-cancel'));
    await click(q(doc, 'agent-panel-apply-restart-now'));
    assert.deepEqual(calls.slice(-2), ['cancel', 'now']);

    // Failure and conflict alerts.
    await render(React.createElement(ApplyFooter, { view: applyFooterView(viewInput({ flow: { phase: 'failed', error: 'bridge refused', conflict: [], waitingSince: '', queued: [] } })), ...handlers }));
    assert.equal(q(doc, 'agent-panel-apply-error')!.getAttribute('role'), 'alert');
    assert.match(q(doc, 'agent-panel-apply-error')!.textContent || '', /bridge refused/);

    // Clean draft: nothing rendered.
    await render(React.createElement(ApplyFooter, { view: applyFooterView(viewInput({ changes: [] })), ...handlers }));
    assert.equal(q(doc, 'agent-panel-apply'), null);
  });
});

test('ApplyFooter: focus moves to the status line when the focused primary button unmounts', async () => {
  await withDom(async ({ doc, render }) => {
    const { applyFooterView } = await mod();
    const { ApplyFooter } = await import('../src/ui/components/agentSettings/ApplyFooter.tsx');
    const noop = { onApply() {}, onRestartNow() {}, onCancel() {}, onDiscard() {} };
    await render(React.createElement(ApplyFooter, { view: applyFooterView(viewInput()), ...noop }));
    const status = q(doc, 'agent-panel-apply-status')!;
    q(doc, 'agent-panel-apply-btn')!.focus();
    assert.equal(doc.activeElement, q(doc, 'agent-panel-apply-btn'));
    await render(React.createElement(ApplyFooter, { view: applyFooterView(viewInput({ flow: { phase: 'restarting', error: '', conflict: [], waitingSince: '', queued: [] } })), ...noop }));
    assert.equal(q(doc, 'agent-panel-apply-status'), status, 'the same live region, only its text changed');
    assert.equal(status.textContent, 'Restarting the agent…');
    assert.equal(doc.activeElement, status, 'focus is not lost to <body>');
  });
});

test('waiting with no staged draft shows what the queued operation changes', async () => {
  const { applyFooterView, configFromDestination } = await mod();
  assert.deepEqual(configFromDestination({ provider: 'codex', model: 'gpt-5', runtime_transport_override: 'acp', permission_mode: 'yolo' } as any, CURRENT),
    { bridgeId: 'riverwood', provider: 'codex', providerProfile: 'codex', model: 'gpt-5', transport: 'acp', bypass: true });
  await withDom(async ({ render }) => {
    const h = await hookHarness(render);
    await h.update({ draft: CURRENT, operation: op({ phase: 'waiting_for_idle', waiting_since: '2026-11-26T11:00:00Z',
      destination: { bridge_id: 'riverwood', provider: 'claude', provider_profile: 'claude', model: 'haiku' } }) });
    assert.equal(h.api.state.phase, 'waiting');
    assert.deepEqual(h.api.state.queued.map((c: any) => [c.field, c.from, c.to]), [['model', 'opus', 'haiku']]);
    const view = applyFooterView(viewInput({ changes: [], flow: h.api.state }));
    assert.deepEqual(view.chips.map((c: any) => c.to), ['haiku']);
  });
});

test('Restart now on a queued change re-sends the queued destination, not the (clean) draft', async () => {
  await withDom(async ({ render }) => {
    const h = await hookHarness(render);
    const queued = op({ phase: 'waiting_for_idle', idempotency_key: 'k-queued', revision: 2, waiting_since: '2026-11-26T10:00:00Z',
      destination: { bridge_id: 'dawnstar', project_id: 'p2', provider: 'codex', provider_profile: 'codex', model: 'gpt-5',
        runtime_transport_override: 'acp', permission_mode: 'yolo' } });
    // After a reload the draft equals the current configuration.
    await h.update({ draft: CURRENT, operation: queued });
    assert.equal(h.api.state.phase, 'waiting');
    h.replies.reconfigure.push(accepted(op({ operation_id: 'op_now', phase: 'prepared' })));
    await act(async () => { await h.api.restartNow(); });
    const sent = h.calls.reconfigure[0];
    assert.deepEqual(
      { bridge_id: sent.bridge_id, project_id: sent.project_id, provider: sent.provider, provider_profile: sent.provider_profile, model: sent.model,
        runtime_transport: sent.runtime_transport, permission_mode: sent.permission_mode, apply: sent.apply, expected_revision: sent.expected_revision },
      { bridge_id: 'dawnstar', project_id: 'p2', provider: 'codex', provider_profile: 'codex', model: 'gpt-5',
        runtime_transport: 'acp', permission_mode: 'yolo', apply: 'now', expected_revision: 3 });
    assert.notEqual(sent.idempotency_key, 'k-queued', 'a new key supersedes the queued operation');

    // With a different draft staged, the waiting chips still show what is queued.
    const { applyFooterView } = await mod();
    await h.update({ draft: { ...CURRENT, model: 'haiku' }, operation: queued });
    const view = applyFooterView(viewInput({ changes: h.api.changes, flow: h.api.state }));
    assert.deepEqual(view.chips.map((c: any) => c.field), ['bridge', 'provider', 'model', 'connection', 'bypass']);
    assert.ok(!view.chips.some((c: any) => c.to === 'haiku'));
  });
});

test('a 409 with no visible change shows the hub message, not "changed since you opened"', async () => {
  const { applyFooterView, conflictMessage } = await mod();
  assert.equal(conflictMessage([], 'A configuration change is already queued after this turn.'), 'A configuration change is already queued after this turn.');
  assert.match(conflictMessage([{ field: 'model', label: 'Model', from: 'a', to: 'b' } as any], 'ignored'), /^Changed since you opened: Model a → b\.$/);
  await withDom(async ({ render }) => {
    const h = await hookHarness(render);
    h.replies.reconfigure.push(failed(409, 'Idempotency key already belongs to another configuration.'));
    await act(async () => { await h.api.apply(); });
    await h.update();
    assert.equal(h.api.state.phase, 'conflict');
    const view = applyFooterView(viewInput({ changes: h.api.changes, flow: h.api.state }));
    assert.equal(view.conflict, 'Idempotency key already belongs to another configuration.');
  });
});
