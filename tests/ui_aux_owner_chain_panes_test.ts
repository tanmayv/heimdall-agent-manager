// The aux Chain overview, Tickets board and ticket tabs of a coordinator
// conversation show its Bridge-owned chain (like the Hub chain panes they
// replace): every read is a signed owner read through the owner relay, never a
// Hub chain endpoint; ticket clicks open ticket tabs, a ticket tab goes back to
// the board and steps prev / next; an offline owner, a locked vault, a chain
// not on any Bridge, no access and an empty chain each show a worded state;
// the panes re-read their owner on an interval.
//
// RUN: node --import ./tests/helpers/vaultEndpointHarness.ts --test tests/ui_aux_owner_chain_panes_test.ts

import { test } from 'node:test';
import assert from 'node:assert/strict';
import React from 'react';
import { JSDOM } from 'jsdom';
import { makeVaultStore } from './helpers/vaultEndpointHarness.ts';
import { fakeOwner, ownerTestSession, registryRow, type OwnerAnswer, type OwnerCall, type OwnerTestEnv } from './helpers/ownerFakeRelay.ts';
import { clearKeyringSession } from '../src/ui/utils/vaultKeyringSession.ts';

// React DOM fixes its event support when first loaded: build the DOM first.
const dom = new JSDOM('<!DOCTYPE html><html><body></body></html>', { url: 'http://localhost/', pretendToBeVisual: true });
const win = dom.window as any;
win.matchMedia = (q: string) => ({ matches: false, media: q, addEventListener() {}, removeEventListener() {}, addListener() {}, removeListener() {} });
const raf = (cb: any) => setTimeout(cb, 0), caf = (id: any) => clearTimeout(id);
win.requestAnimationFrame = raf; win.cancelAnimationFrame = caf;
for (const [key, value] of Object.entries({ window: win, document: win.document, navigator: win.navigator, HTMLElement: win.HTMLElement, Node: win.Node,
  requestAnimationFrame: raf, cancelAnimationFrame: caf, IS_REACT_ACT_ENVIRONMENT: true,
  // jsdom has no CSS namespace; the @ui Select escapes option ids with it.
  CSS: { escape: (v: string) => v.replace(/[^\w-]/g, (c) => '\\' + c) } })) {
  Object.defineProperty(globalThis, key, { value, writable: true, configurable: true });
}
win.HTMLElement.prototype.scrollIntoView = function scrollIntoView() {};
const { createRoot } = await import('react-dom/client');
const { act } = await import('react');
const { Provider } = await import('react-redux');
const { AuxTabContent } = await import('../src/ui/components/auxiliary/AuxTabContent.tsx');
const { OwnerChainAuxPane } = await import('../src/ui/components/taskchain/OwnerChainAuxPane.tsx');
const { resetOwnerChainsForTest } = await import('../src/ui/api/ownerChainsStore.ts');
const { heimdallApi } = await import('../src/ui/api/heimdallApi.ts');
const { keyringInstalled } = await import('../src/ui/store/vaultSlice.ts');

const CHAIN = 'chain_owned';
const runtime = (o: { state?: string; lease?: string; controls?: string[] } = {}) => ({
  revision: '1', fleet: [], leases: o.lease ? [['lease_1', o.lease, '9', '9', '1']] : [], config: [], requirements: [],
  state: o.state ? [[o.state, '1', '']] : [], submission: [], controls: o.controls ? [o.controls] : [],
  attempts: { attempt_no: '0', last_release: '', work_lease_id: '', completeness: 'full' },
});

/** A chain coordinated by inst_coord: Fix login (worked by inst_worker), Write docs (held), Ship (done). */
function chainOwner(tasks = [
  { task_id: 'task_1', title: 'Fix login', revision: '3', priority: 'p1' },
  { task_id: 'task_2', title: 'Write docs', revision: '1', priority: 'p2' },
  { task_id: 'task_3', title: 'Ship', revision: '2', priority: 'p2' },
]) {
  const state = { tasks, title: 'Live chain title' };
  const answer = (call: OwnerCall): OwnerAnswer => {
    const task = call.command.task_id;
    switch (call.method) {
      case 'chain.read': return { chain_id: CHAIN, task_id: '', revision: '7', title: state.title, description: 'Live description', defaults_json: '{}', items: state.tasks, next_cursor: '' };
      case 'work.read': return { chain_id: CHAIN, publish_state: 'published', status: 'active', work_revision: '1', pending_proposal_id: '', next_cursor: '', items: [], pending_proposal: null };
      case 'chain.metadata.read': return { next_cursor: '', items: [
        { kind: 'member', accepted_seq: '3', entity_id: 'inst_worker', enabled: '1', current: '1', body: JSON.stringify({ instance_id: 'inst_worker', agent_id: 'agt_worker', role: 'worker' }) },
        { kind: 'member', accepted_seq: '2', entity_id: 'inst_coord', enabled: '1', current: '1', body: JSON.stringify({ instance_id: 'inst_coord', agent_id: 'agt_coord', role: 'coordinator' }) },
      ] };
      case 'runtime.read':
        return task === 'task_1' ? runtime({ lease: 'inst_worker' })
          : task === 'task_2' ? runtime({ controls: ['held', 'ready', 'waiting', ''] })
          : runtime({ state: 'done' });
      case 'task.read': return { chain_id: CHAIN, task_id: task, revision: '3', title: state.tasks.find((t) => t.task_id === task)?.title ?? '', body: 'Login fails on Safari', priority: 'p1',
        items: [{ operation_id: 'cmt_1', principal_id: 'inst_worker', body: 'Working on it', seq: '1', created_at: '2026-11-01T10:00:00Z' }], next_cursor: '' };
      case 'history.read': return { chain_id: CHAIN, next_cursor: '', items: [] };
      case 'migration.archive.read': return { chain_id: CHAIN, migration_id: 'mig_1', next_cursor: '', items: [
        { kind: 'review', doc_index: '0', row: '0', record: JSON.stringify({ task_id: 'task_1', attempt_no: 1, role: 'security', reviewer_kind: 'agent', reviewer_agent_id: 'agt_reviewer', verdict: 'request_changes', findings_json: '[]', created_at: '2026-11-02T09:00:00Z' }) },
      ] };
      default: return { code: 'invalid_scope' };
    }
  };
  return { state, answer };
}

interface Opened { content: any; title?: string }

async function mount(o: {
  answer?: (call: OwnerCall) => OwnerAnswer | Promise<OwnerAnswer>;
  online?: boolean;
  registered?: boolean;
  locked?: boolean;
  /** Hub (non-owner) answers by path; the default answers {}. */
  hub?: (path: string, init: any) => unknown;
  render: (env: OwnerTestEnv, h: { opened: Opened[]; updated: any[]; rekeyed: Opened[]; send: (relay: unknown) => Promise<unknown> }) => React.ReactElement;
}) {
  const env = await ownerTestSession('brg_home', 'Home Bridge');
  const calls: OwnerCall[] = [];
  const send = fakeOwner(env.session, o.answer ?? chainOwner().answer, calls);
  const rows = o.registered === false ? [] : [
    await registryRow(env.session, { chainId: CHAIN, bridgeId: 'brg_home', online: o.online ?? true, chainTitle: 'Registry title', coordinator: 'inst_coord' }),
    await registryRow(env.session, { chainId: CHAIN, taskId: 'task_1', bridgeId: 'brg_home', online: o.online ?? true, taskTitle: 'Fix login' }),
    await registryRow(env.session, { chainId: CHAIN, taskId: 'task_2', bridgeId: 'brg_home', online: o.online ?? true, taskTitle: 'Write docs' }),
  ];
  resetOwnerChainsForTest((async () => ({ items: rows, next_cursor: { after_chain: '', after_task: '' }, terminal: true })) as any, send as any);
  if (o.locked) clearKeyringSession();
  const hubPaths: string[] = [];
  const hubCalls: { path: string; method: string; body: any }[] = [];
  const saved = globalThis.fetch;
  globalThis.fetch = (async (input: any, init: any = {}) => {
    const u = new URL(String(input?.url ?? input), 'http://localhost');
    const ok = (data: unknown) => new Response(JSON.stringify({ data }), { status: 200, headers: { 'Content-Type': 'application/json' } });
    if (u.pathname === '/api/v1/vault/directory') return ok(env.hub.dir());
    if (u.pathname === '/api/v1/owner-local/relay') return ok(await send(JSON.parse(init.body)));
    hubPaths.push(u.pathname);
    hubCalls.push({ path: u.pathname, method: String(init.method || 'GET'), body: init.body ? JSON.parse(init.body) : null });
    return ok(o.hub?.(u.pathname, init) ?? {});
  }) as typeof fetch;
  const store = await makeVaultStore();
  // The ticket tab masks and locks its editors while the vault is locked.
  if (!o.locked) store.dispatch(keyringInstalled({ currentEpoch: 1 }));
  const opened: Opened[] = [], updated: any[] = [], rekeyed: Opened[] = [];
  const container = win.document.createElement('div');
  win.document.body.appendChild(container);
  const root = createRoot(container);
  const settle = async (n = 40) => { for (let i = 0; i < n; i += 1) await act(async () => { await new Promise((r) => setTimeout(r, 3)); }); };
  await act(async () => { root.render(React.createElement(Provider, { store }, o.render(env, { opened, updated, rekeyed, send }))); });
  await settle();
  const $ = (id: string) => container.querySelector(`[data-debug-id="${id}"]`) as HTMLElement | null;
  const click = async (id: string) => { const el = $(id); assert.ok(el, 'missing ' + id); await act(async () => { el!.click(); }); await settle(); };
  const cleanup = async () => {
    await act(async () => root.unmount());
    store.dispatch(heimdallApi.util.resetApiState());
    container.remove();
    globalThis.fetch = saved;
    resetOwnerChainsForTest();
    clearKeyringSession();
  };
  return { $, click, settle, calls, hubPaths, hubCalls, opened, updated, rekeyed, cleanup, container };
}

const ctx = (chainId = CHAIN) => ({
  agentInstanceId: 'inst_coord', conversationId: '', title: 'Coordinator', chainId, projectId: '', projectName: '', bridgeId: 'brg_home',
  defaultCwd: '', shellCwdReady: true, projectVcsEnabled: false, projectExplorerAccess: 'disabled' as const, directories: [], members: [],
  participantIds: null, isResolved: true,
});

function aux(content: any, h: { opened: Opened[]; updated: any[]; rekeyed: Opened[] }, chainId = CHAIN) {
  return React.createElement(AuxTabContent, {
    tab: { id: content.type === 'ticket' ? `ticket:${content.taskId}` : content.type, content, title: 'Tab' } as any,
    ctx: ctx(chainId),
    onOpenTab: (c: any, title?: string) => { h.opened.push({ content: c, title }); },
    onUpdateTab: (_id: string, patch: any, title?: string) => { h.updated.push({ patch, title }); },
    onRekeyTab: (_id: string, c: any, title?: string) => { h.rekeyed.push({ content: c, title }); },
  });
}

/** Owner reads only: no Hub chain/task endpoint was asked for chain state. */
function assertNoHubChainReads(paths: string[]) {
  assert.deepEqual(paths.filter((p) => /task-chains|\/tasks|\/chains/.test(p) && !/token-usage/.test(p)), []);
}

test('the Chain overview shows the owner chain: status, ticket states, agents and attention; tickets and agents open', async () => {
  const ui = await mount({ render: (_env, h) => aux({ type: 'chainOverview' }, h) });
  try {
    assert.equal(ui.$('owner-chain-title')!.textContent, 'Live chain title');
    assert.equal(ui.$('owner-chain-status')!.textContent, 'Active');
    assert.match(ui.$('owner-chain-description')!.textContent!, /Live description/);
    assert.equal(ui.$('owner-chain-count-in_progress')!.textContent, 'In progress · 1');
    assert.equal(ui.$('owner-chain-count-ready')!.textContent, 'Ready · 1');
    assert.equal(ui.$('owner-chain-count-done')!.textContent, 'Done · 1');
    assert.match(ui.$('owner-chain-agent-inst_coord')!.textContent!, /inst_coord.*coordinator/s);
    assert.match(ui.$('owner-chain-agent-inst_worker')!.textContent!, /inst_worker.*worker.*on Fix login/s);
    assert.match(ui.$('owner-chain-attention')!.textContent!, /Write docs.*Held/s);
    assert.equal(ui.$('owner-chain-task-detail'), null, 'the overview shows no ticket detail');

    await ui.click('owner-chain-task-task_1');
    assert.deepEqual(ui.opened.at(-1)!.content, { type: 'tasks', taskId: 'task_1' }, 'a ticket opens the board focused on it');
    await ui.click('owner-chain-agent-open-inst_worker');
    assert.deepEqual(ui.opened.at(-1)!.content, { type: 'subagentChat', agentInstanceId: 'inst_worker' }, 'an agent opens its chat in an aux tab');
    assert.ok(ui.calls.some((c) => c.method === 'chain.metadata.read'), 'agents come from the owner member rows');
    assertNoHubChainReads(ui.hubPaths);
  } finally {
    await ui.cleanup();
  }
});

test('the Tickets board is origin/main\'s board over owner data, opens tickets as tabs and consumes a one-shot ticket', async () => {
  const ui = await mount({ render: (_env, h) => aux({ type: 'tasks', taskId: 'task_2' }, h) });
  try {
    assert.deepEqual(ui.opened[0], { content: { type: 'ticket', chainId: CHAIN, taskId: 'task_2' }, title: 'Write docs' }, 'the focused ticket opens once');
    assert.deepEqual(ui.updated[0].patch, { taskId: undefined }, 'and the board tab forgets it');
    assert.ok(ui.$('ticket-board-view'), 'the restored TicketBoard renders');
    assert.match(ui.$('ticket-board-progress-caption')!.textContent!, /1 of 3 done/);
    assert.match(ui.$('task-board-section-in_progress')!.textContent!, /In progress.*1.*Fix login/s);
    assert.match(ui.$('task-board-section-held')!.textContent!, /Held.*1.*Write docs/s);
    assert.equal(ui.$('task-board-section-finished'), null, 'the Open filter hides finished tickets');
    assert.equal(ui.$('owner-chain-task-detail'), null);

    await ui.click('task-card-toggle-task_1');
    assert.deepEqual(ui.opened.at(-1), { content: { type: 'ticket', chainId: CHAIN, taskId: 'task_1' }, title: 'Fix login' });
    await ui.click('ticket-board-filter-all');
    await ui.click('ticket-board-finished-row-task_3');
    assert.deepEqual(ui.opened.at(-1), { content: { type: 'ticket', chainId: CHAIN, taskId: 'task_3' }, title: 'Ship' });
    assert.equal(ui.opened.length, 3, 'the one-shot ticket is not reopened');

    // A card action runs the owner command against that ticket's revision.
    await ui.click('task-action-release-task_2');
    const release = ui.calls.find((c) => c.method === 'task.release');
    assert.ok(release, 'Release hold on the card sends task.release');
    assert.equal(release!.command.task_id, 'task_2');
    assert.equal(release!.command.expected_revision, '1', 'the card uses the listed revision of its own ticket');
    assertNoHubChainReads(ui.hubPaths);
  } finally {
    await ui.cleanup();
  }
});

test('a ticket tab is origin/main\'s ticket view: description, comments and reviews, back to the board, prev / next', async () => {
  const ui = await mount({ render: (_env, h) => aux({ type: 'ticket', chainId: CHAIN, taskId: 'task_1' }, h) });
  try {
    assert.ok(ui.$('ticket-view-task_1'), 'origin/main TicketView');
    assert.equal(ui.$('ticket-view-title')!.textContent, 'Fix login');
    assert.match(ui.$('ticket-view-description')!.textContent!, /Login fails on Safari/);
    await ui.click('ticket-activity-tab-comments');
    assert.match(ui.$('ticket-activity-feed-comments')!.textContent!, /inst_worker.*Working on it/s);
    await ui.click('ticket-activity-tab-reviews');
    assert.match(ui.$('ticket-activity-feed-reviews')!.textContent!, /Reviewer.*\(security\).*Changes requested.*Archived from Hub/s);
    assert.match(ui.$('ticket-view-agents')!.textContent!, /Assignee · has the lease/, 'the lease holder is in the Agents card');
    assert.equal(ui.$('owner-chain-tickets-ticket'), null, 'a ticket tab has no ticket list');
    assert.ok(ui.updated.some((u) => /Fix login/.test(u.title ?? '')), 'the tab is titled after the ticket');

    await ui.click('ticket-view-breadcrumb-tickets');
    assert.deepEqual(ui.opened.at(-1)!.content, { type: 'tasks' });
    assert.equal((ui.$('ticket-view-prev-btn') as HTMLButtonElement).disabled, true, 'the first ticket has no previous');
    await ui.click('ticket-view-next-btn');
    assert.deepEqual(ui.rekeyed.at(-1)!.content, { type: 'ticket', chainId: CHAIN, taskId: 'task_2' });
    assert.match(ui.rekeyed.at(-1)!.title!, /Write docs/);
    assertNoHubChainReads(ui.hubPaths);
  } finally {
    await ui.cleanup();
  }
});

test('an offline owner shows the registry tickets with an offline state and asks the owner nothing', async () => {
  const ui = await mount({ online: false, render: (_env, h) => aux({ type: 'chainOverview' }, h) });
  try {
    assert.equal(ui.$('owner-chain-offline')!.textContent, 'Owner Bridge Home Bridge is offline — details and changes unavailable');
    assert.equal(ui.$('owner-chain-title')!.textContent, 'Registry title');
    assert.ok(ui.$('owner-chain-task-task_1') && ui.$('owner-chain-task-task_2'), 'registry tickets still list');
    assert.match(ui.$('owner-chain-agents')!.textContent!, /Unavailable while the owner Bridge is offline/);
    assert.equal(ui.calls.length, 0);
    assert.equal(ui.$('owner-chain-error'), null);
  } finally {
    await ui.cleanup();
  }
  const ticket = await mount({ online: false, render: (_env, h) => aux({ type: 'ticket', chainId: CHAIN, taskId: 'task_1' }, h) });
  try {
    assert.ok(ticket.$('owner-chain-offline'));
    assert.equal(ticket.$('owner-chain-task-title'), null);
    assert.equal(ticket.calls.length, 0);
  } finally {
    await ticket.cleanup();
  }
});

test('a chain not on any Bridge, a locked vault, no chain, no access and an empty chain are worded states', async () => {
  const missing = await mount({ registered: false, render: (_env, h) => aux({ type: 'tasks' }, h) });
  try {
    assert.match(missing.$('aux-owner-chain-missing')!.textContent!, /not on any of your Bridges.*Open Task Chains/s);
  } finally { await missing.cleanup(); }

  const locked = await mount({ locked: true, render: (_env, h) => aux({ type: 'chainOverview' }, h) });
  try {
    assert.match(locked.$('aux-owner-chain-locked')!.textContent!, /Unlock the vault/);
  } finally { await locked.cleanup(); }

  const none = await mount({ render: (_env, h) => aux({ type: 'chainOverview' }, h, '') });
  try {
    assert.match(none.$('aux-overview-no-chain')!.textContent!, /not part of a task chain/);
  } finally { await none.cleanup(); }

  const denied = await mount({ answer: () => ({ code: 'invalid_scope' }), render: (_env, h) => aux({ type: 'tasks' }, h) });
  try {
    assert.equal(denied.$('owner-chain-error')!.textContent, 'This device has no access to that chain or task on its owner Bridge.');
  } finally { await denied.cleanup(); }

  const empty = chainOwner([]);
  const blank = await mount({
    answer: (call) => (call.method === 'chain.metadata.read' ? { items: [], next_cursor: '' } : empty.answer(call)),
    render: (_env, h) => aux({ type: 'chainOverview' }, h),
  });
  try {
    assert.ok(blank.$('owner-chain-no-tasks'), 'no tickets yet');
    assert.ok(blank.$('owner-chain-agent-inst_coord'), 'the registry coordinator is still listed');
  } finally { await blank.cleanup(); }
});

test('the panes re-read their owner on an interval and show changes', async () => {
  const owner = chainOwner();
  const ui = await mount({
    answer: owner.answer,
    render: (env, h) => React.createElement(OwnerChainAuxPane, {
      chainId: CHAIN, layout: 'board', refreshMs: 30, onOpenTicket: (taskId: string, title: string) => { h.opened.push({ content: { taskId }, title }); },
      send: h.send, session: async () => env.session,
    }),
  });
  try {
    await ui.click('ticket-board-filter-all');
    assert.equal(ui.$('ticket-board-finished-row-task_4'), null);
    owner.state.tasks = [...owner.state.tasks, { task_id: 'task_4', title: 'Audit log', revision: '1', priority: 'p2' }];
    await ui.settle(60);
    assert.match(ui.$('ticket-board-filter-all')!.textContent!, /All\s*4/);
    assert.match(ui.$('ticket-board-finished-row-task_4')!.textContent!, /Audit log/, 'a ticket added on the owner appears without a manual refresh');
  } finally {
    await ui.cleanup();
  }
});

test('overview agent rows show each instance status and start / stop / restart / remove it', async () => {
  const owner = chainOwner();
  const status: Record<string, string> = { inst_worker: 'running', inst_coord: 'stopped' };
  const ui = await mount({
    answer: (call) => (call.method === 'chain.member.set' ? { chain_id: CHAIN, revision: '8' } : owner.answer(call)),
    hub: (path) => {
      const m = /^\/api\/v1\/agent-instances\/([^/]+)$/.exec(path);
      return m ? { runtime_status: status[m[1]] ?? '' } : {};
    },
    render: (_env, h) => aux({ type: 'chainOverview' }, h),
  });
  try {
    assert.equal(ui.$('owner-chain-agent-status-inst_worker')!.textContent, 'Running');
    assert.equal(ui.$('owner-chain-agent-status-inst_coord')!.textContent, 'Stopped');
    assert.ok(ui.$('owner-chain-agent-stop-inst_worker') && ui.$('owner-chain-agent-restart-inst_worker'));
    assert.equal(ui.$('owner-chain-agent-start-inst_worker'), null, 'a running agent is not offered Start');
    assert.ok(ui.$('owner-chain-agent-start-inst_coord'));
    assert.equal(ui.$('owner-chain-agent-stop-inst_coord'), null);
    assert.equal(ui.$('owner-chain-agent-remove-inst_coord'), null, 'the coordinator is replaced, never removed');

    await ui.click('owner-chain-agent-stop-inst_worker');
    assert.deepEqual(ui.hubCalls.filter((c) => c.method === 'POST').map((c) => c.path), ['/api/v1/agent-instances/inst_worker/stop']);
    assert.equal(ui.$('owner-chain-agent-status-inst_worker')!.textContent, 'Stopping');
    assert.match(ui.$('owner-chain-notice')!.textContent!, /Stopping the agent/);
    await ui.click('owner-chain-agent-start-inst_coord');
    assert.equal(ui.hubCalls.filter((c) => c.method === 'POST').at(-1)!.path, '/api/v1/agent-instances/inst_coord/start');

    win.confirm = () => true;
    await ui.click('owner-chain-agent-remove-inst_worker');
    const set = ui.calls.find((c) => c.method === 'chain.member.set');
    assert.ok(set, 'remove sends chain.member.set');
    assert.deepEqual({ ...set!.payload }, { instance_id: 'inst_worker', agent_id: 'agt_worker', role: 'worker', enabled: '0' });
    assert.equal(set!.command.expected_revision, '7', 'checked against the chain revision');
    assertNoHubChainReads(ui.hubPaths);
  } finally {
    await ui.cleanup();
  }
});

test('agentRuntimeActions offers stop/restart when running, start when stopped or failed, nothing while changing', async () => {
  const { agentRuntimeActions } = await import('../src/ui/components/taskchain/OwnerChainView.tsx');
  assert.deepEqual(agentRuntimeActions('running'), ['stop', 'restart']);
  assert.deepEqual(agentRuntimeActions('stopped'), ['start']);
  assert.deepEqual(agentRuntimeActions('failed'), ['start']);
  assert.deepEqual(agentRuntimeActions('launching'), []);
  assert.deepEqual(agentRuntimeActions(''), []);
});

test('Add agent launches the chosen agent on the owner Bridge, waits until it runs and binds it as a reviewer', async () => {
  const owner = chainOwner();
  const ui = await mount({
    answer: (call) => (call.method === 'chain.member.set' ? { chain_id: CHAIN, revision: '8' } : owner.answer(call)),
    hub: (path, init) => {
      if (path === '/api/v1/agents') return [{ agent_id: 'agt_review', name: 'Security reviewer', slug: 'security' }];
      if (path === '/api/v1/agent-instances' && init.method === 'POST') return { agent_instance_id: 'inst_new' };
      if (path === '/api/v1/agent-instances/inst_new') return { runtime_status: 'running' };
      return {};
    },
    render: (_env, h) => aux({ type: 'chainOverview' }, h),
  });
  try {
    await ui.click('owner-chain-add-agent-open');
    await ui.click('owner-chain-add-agent-role');
    const reviewer = [...win.document.querySelectorAll('[role="option"]')].find((o: any) => /Reviewer/.test(o.textContent || '')) as HTMLElement | undefined;
    assert.ok(reviewer, 'the role menu lists Reviewer');
    await act(async () => { reviewer!.click(); });
    await ui.settle();
    await ui.click('owner-chain-add-agent-launch');
    await ui.settle(80);
    const launch = ui.hubCalls.find((c) => c.path === '/api/v1/agent-instances' && c.method === 'POST');
    assert.deepEqual(launch?.body, { agent_id: 'agt_review', chain_id: CHAIN, bridge_id: 'brg_home' }, 'launched chain-bound on the owner Bridge');
    const set = ui.calls.find((c) => c.method === 'chain.member.set');
    assert.ok(set, 'bound with chain.member.set: ' + (ui.$('owner-chain-add-agent-error')?.textContent ?? ''));
    assert.deepEqual({ ...set!.payload }, { instance_id: 'inst_new', agent_id: 'agt_review', role: 'reviewer', enabled: '1' });
    assert.equal(ui.hubCalls.filter((c) => /\/restart$/.test(c.path)).length, 0, 'a worker or reviewer is not restarted');
    assert.equal(ui.$('owner-chain-notice')!.textContent, 'Added inst_new as reviewer.');
  } finally {
    await ui.cleanup();
  }
});

test('addOwnerChainAgent stops on a failed launch and never binds an instance that did not start', async () => {
  const { addOwnerChainAgent } = await import('../src/ui/api/ownerCoordinator.ts');
  const bound: string[] = [];
  await assert.rejects(addOwnerChainAgent({ launch: async () => 'inst_x', status: async () => 'failed', bind: async (id) => { bound.push(id); } }), /agent instance failed before it started/);
  let t = 0;
  await assert.rejects(addOwnerChainAgent({ launch: async () => 'inst_y', status: async () => 'launching', bind: async (id) => { bound.push(id); }, sleep: async () => {}, now: () => (t += 50_000) }), /agent instance did not start in time/);
  await assert.rejects(addOwnerChainAgent({ launch: async () => '', status: async () => 'running', bind: async (id) => { bound.push(id); } }), /not created/);
  assert.deepEqual(bound, []);
});

test('the overview shows chain progress and the latest activity, newest first, with ticket links', async () => {
  const owner = chainOwner();
  const history = [
    { seq: '1', kind: 'task.create', task_id: 'task_1', actor_kind: 'agent', actor_id: 'inst_coord', ts_ms: '1794200000000' },
    { seq: '2', kind: 'registry.prepare', task_id: '', actor_kind: 'bridge', actor_id: 'brg_home', ts_ms: '1794200001000' },
    { seq: '3', kind: 'review.post', task_id: 'task_3', actor_kind: 'agent', actor_id: 'inst_reviewer', ts_ms: '1794200002000' },
  ];
  const ui = await mount({
    answer: (call) => {
      if (call.method !== 'history.read') return owner.answer(call);
      // Two pages, oldest first, like the owner.
      return call.payload.cursor ? { chain_id: CHAIN, next_cursor: '', items: history.slice(2) } : { chain_id: CHAIN, next_cursor: 'c1', items: history.slice(0, 2) };
    },
    render: (_env, h) => aux({ type: 'chainOverview' }, h),
  });
  try {
    assert.match(ui.$('owner-chain-progress')!.getAttribute('aria-label')!, /1 done, 1 in progress or review, 1 ready or waiting/);
    assert.ok(ui.$('owner-chain-progress-caption')!.textContent!.length > 0);
    const rows = [...ui.$('owner-chain-activity')!.querySelectorAll('li')].map((li) => li.getAttribute('data-debug-id'));
    assert.deepEqual(rows, ['owner-chain-activity-3', 'owner-chain-activity-1'], 'newest first; bookkeeping events are left out');
    assert.match(ui.$('owner-chain-activity-3')!.textContent!, /inst_reviewer.*Reviewed.*Ship/s);
    assert.match(ui.$('owner-chain-activity-1')!.textContent!, /inst_coord.*Created.*Fix login/s);
    await ui.click('owner-chain-activity-ticket-1');
    assert.deepEqual(ui.opened.at(-1)!.content, { type: 'tasks', taskId: 'task_1' });
  } finally {
    await ui.cleanup();
  }
});

test('a ticket shows its requirement history on demand: each change decrypted, newest first, with its reason', async () => {
  const { encryptVaultText } = await import('../src/ui/utils/vaultCrypto.ts');
  const owner = chainOwner();
  const edits: Record<string, { revision: string; doc: unknown }> = {
    '4': { revision: '1', doc: { goal: 'Fix login', acceptance: ['Works on Safari'] } },
    '9': { revision: '2', doc: { goal: 'Fix login everywhere', acceptance: ['Works on Safari', 'Works on Firefox'], requirements_reason: 'Firefox fails too' } },
  };
  const ui = await mount({
    answer: async (call) => {
      if (call.method === 'history.read') return { chain_id: CHAIN, next_cursor: '', items: [
        { seq: '4', kind: 'requirements.edit', task_id: 'task_1', actor_kind: 'device', actor_id: 'dev_x', ts_ms: '1794200000000' },
        { seq: '7', kind: 'requirements.edit', task_id: 'task_2', actor_kind: 'device', actor_id: 'dev_x', ts_ms: '1794200001000' },
        { seq: '9', kind: 'requirements.edit', task_id: 'task_1', actor_kind: 'agent', actor_id: 'inst_coord', ts_ms: '1794200002000' },
      ] };
      if (call.method === 'history.fetch') {
        const e = edits[call.payload.seq ?? ''];
        if (!e) return { code: 'not_found' };
        const payload = JSON.stringify({ requirements_revision: e.revision, body_cipher: await encryptVaultText(JSON.stringify(e.doc)) });
        return { evidence: JSON.stringify({ payload }), next_offset: '' };
      }
      return owner.answer(call);
    },
    render: (_env, h) => aux({ type: 'ticket', chainId: CHAIN, taskId: 'task_1' }, h),
  });
  try {
    assert.equal(ui.calls.filter((c) => c.method === 'history.fetch').length, 0, 'nothing is decrypted until asked for');
    await ui.click('ticket-activity-tab-requirements');
    const rows = [...ui.$('task-requirements-history')!.querySelectorAll('li[data-debug-id]')].map((li) => li.getAttribute('data-debug-id'));
    assert.deepEqual(rows, ['ticket-requirement-change-2', 'ticket-requirement-change-1'], 'only this ticket, newest first');
    assert.match(ui.$('ticket-requirement-change-2')!.textContent!, /Rev 2.*Coord.*changed requirements.*Firefox fails too.*Fix login.*Fix login everywhere.*Works on Firefox/s);
    assert.match(ui.$('ticket-requirement-change-1')!.textContent!, /Rev 1.*You.*Works on Safari/s, 'a device edit is the user');
  } finally {
    await ui.cleanup();
  }
});

const FLEET_ROW = {
  provider_profile: '', task_chain_id: CHAIN, agent_id: 'agt_worker', capacity: 2, min_warm: 0, idle_ttl_seconds: 600,
  bridge_models_json: '', provider: 'claude', model: 'opus', roles_json: '["worker"]', bridge_id: '', paused_roles_json: '',
  created_at: '2026-11-01T00:00:00Z', updated_at: '2026-11-01T00:00:00Z',
};

test('the overview shows the fleet with agent names; pause and edit write fleet.policy.set', async () => {
  const { decryptVaultText } = await import('../src/ui/utils/vaultCrypto.ts');
  const owner = chainOwner();
  const ui = await mount({
    answer: (call) => {
      if (call.method === 'fleet.policy.read') return { chain_id: CHAIN, revision: '7', next_cursor: '', items: [{ policy: FLEET_ROW, accepted_seq: '5', source_revision: '' }] };
      if (call.method === 'fleet.policy.set') return { chain_id: CHAIN, revision: '8' };
      return owner.answer(call);
    },
    hub: (path) => (path === '/api/v1/agents' ? [{ agent_id: 'agt_worker', name: 'Backend worker' }] : {}),
    render: (_env, h) => aux({ type: 'chainOverview' }, h),
  });
  try {
    const row = ui.$('owner-chain-fleet-agt_worker')!;
    assert.match(row.textContent!, /Backend worker.*agt_worker.*Active.*claude · opus · capacity 2/s);
    assert.match(ui.$('owner-chain-agent-inst_worker')!.textContent!, /Backend worker.*inst_worker/s, 'agent rows show the display name and the instance id');

    await ui.click('owner-chain-fleet-pause-agt_worker');
    let set = ui.calls.filter((c) => c.method === 'fleet.policy.set').at(-1)!;
    assert.equal(set.command.expected_revision, '7', 'checked against the chain revision');
    let doc = JSON.parse(await decryptVaultText(set.payload.body_cipher!));
    assert.equal(doc.paused_roles_json, '["*"]');
    assert.equal(doc.created_at, FLEET_ROW.created_at, 'created_at is kept (the store refuses a new one)');
    assert.equal(Object.keys(doc).length, 14);
    assert.match(ui.$('owner-chain-notice')!.textContent!, /Fleet row paused/);

    await ui.click('owner-chain-fleet-edit-agt_worker');
    const input = (id: string, v: string) => act(async () => {
      const el = ui.$(id)!.querySelector('input') ?? ui.$(id) as HTMLInputElement;
      const setter = Object.getOwnPropertyDescriptor(win.HTMLInputElement.prototype, 'value')!.set!;
      setter.call(el, v); el.dispatchEvent(new win.Event('input', { bubbles: true }));
    });
    await input('owner-chain-fleet-capacity', '0');
    await ui.click('owner-chain-fleet-save');
    assert.match(ui.$('owner-chain-fleet-form-error')!.textContent!, /at least 1/);
    await input('owner-chain-fleet-capacity', '4');
    await input('owner-chain-fleet-model', 'sonnet');
    await ui.click('owner-chain-fleet-save');
    set = ui.calls.filter((c) => c.method === 'fleet.policy.set').at(-1)!;
    doc = JSON.parse(await decryptVaultText(set.payload.body_cipher!));
    assert.deepEqual([doc.capacity, doc.model, doc.provider], [4, 'sonnet', 'claude']);
    assert.equal(ui.$('owner-chain-fleet-form-agt_worker'), null, 'the form closes after a save');
    assertNoHubChainReads(ui.hubPaths);
  } finally {
    await ui.cleanup();
  }
});

test('the board shows the fleet in its fleet slot; an empty fleet says how rows are added', async () => {
  const owner = chainOwner();
  const ui = await mount({
    answer: (call) => (call.method === 'fleet.policy.read' ? { chain_id: CHAIN, revision: '7', next_cursor: '', items: [] } : owner.answer(call)),
    render: (_env, h) => aux({ type: 'tasks' }, h),
  });
  try {
    assert.ok(ui.$('owner-chain-no-fleet'), 'empty fleet state');
  } finally {
    await ui.cleanup();
  }
});

test('ownerFleetPolicyDocument and parseOwnerFleetPolicy round-trip a row and pause/resume it', async () => {
  const { ownerFleetPolicyDocument, parseOwnerFleetPolicy } = await import('../src/ui/api/ownerChains.ts');
  const row = parseOwnerFleetPolicy({ ...FLEET_ROW, paused_roles_json: '["*"]' })!;
  assert.equal(row.paused, true);
  assert.deepEqual(row.roles, ['worker']);
  const now = new Date('2026-11-10T05:00:00.123Z');
  const resumed = JSON.parse(ownerFleetPolicyDocument(row, { paused: false }, now));
  assert.deepEqual(resumed, { ...FLEET_ROW, updated_at: '2026-11-10T05:00:00Z' });
  const cleared = JSON.parse(ownerFleetPolicyDocument({ ...row, document: { ...row.document, provider_profile: 'p' } }, { provider: ' ' }, now));
  assert.deepEqual([cleared.provider, cleared.provider_profile], ['', ''], 'a profile needs a provider');
  assert.throws(() => ownerFleetPolicyDocument(row, { capacity: 1.5 }, now), /at least 1/);
  assert.equal(parseOwnerFleetPolicy({}), null);
});

test('the ticket tab restores origin/main decision block: hold release, answer a blocker, request changes', async () => {
  const owner = chainOwner();
  let taskRevision = 3;
  const ui = await mount({
    answer: (call) => {
      const task = call.command.task_id;
      if (call.method === 'runtime.read' && task === 'task_1') return { ...runtime(), controls: [['blocked', 'ready', 'Which OAuth provider?', 'human']] };
      if (call.method === 'runtime.read' && task === 'task_3') return { ...runtime({ state: 'in_review' }), submission: [['1', 'b'.repeat(40), '1', 'Shipped the build', 'agt_worker']] };
      if (call.method === 'task.read') return { ...(owner.answer(call) as any), revision: String(taskRevision) };
      if (['task.comment', 'task.resolve', 'task.release', 'review.post'].includes(call.method)) { taskRevision += 1; return { chain_id: CHAIN, task_id: task, revision: String(taskRevision) }; }
      return owner.answer(call);
    },
    render: (_env, h) => aux({ type: 'ticket', chainId: CHAIN, taskId: 'task_2' }, h),
  });
  try {
    assert.ok(ui.$('task-hold-block'), 'a held ticket shows the hold card');
    await ui.click('task-hold-release-btn');
    assert.ok(ui.calls.some((c) => c.method === 'task.release' && c.command.task_id === 'task_2'));
  } finally {
    await ui.cleanup();
  }

  const typeInto = async (h: Awaited<ReturnType<typeof mount>>, id: string, v: string) => act(async () => {
    const el = h.$(id) as HTMLTextAreaElement;
    Object.getOwnPropertyDescriptor(win.HTMLTextAreaElement.prototype, 'value')!.set!.call(el, v);
    el.dispatchEvent(new win.Event('input', { bubbles: true }));
  });
  const blocked = await mount({
    answer: (call) => {
      const task = call.command.task_id;
      if (call.method === 'runtime.read' && task === 'task_1') return { ...runtime(), controls: [['blocked', 'ready', 'Which OAuth provider?', 'human']] };
      if (call.method === 'task.read') return { ...(owner.answer(call) as any), revision: String(taskRevision) };
      if (call.method === 'task.comment' || call.method === 'task.resolve') { taskRevision += 1; return { chain_id: CHAIN, task_id: task, revision: String(taskRevision) }; }
      return owner.answer(call);
    },
    render: (_env, h) => aux({ type: 'ticket', chainId: CHAIN, taskId: 'task_1' }, h),
  });
  try {
    assert.match(blocked.$('answer-blocker-block')!.textContent!, /Your answer.*Which OAuth provider\?/s);
    assert.equal((blocked.$('answer-send-btn') as HTMLButtonElement).disabled, true, 'an empty answer is not sent');
    await typeInto(blocked, 'answer-composer-input', 'Use Google');
    await blocked.click('answer-send-btn');
    const comment = blocked.calls.find((c) => c.method === 'task.comment')!;
    const resolve = blocked.calls.find((c) => c.method === 'task.resolve')!;
    assert.ok(comment && resolve, 'the answer is a comment, then task.resolve');
    assert.ok(blocked.calls.indexOf(comment) < blocked.calls.indexOf(resolve));
    assert.equal(Number(resolve.command.expected_revision), Number(comment.command.expected_revision) + 1, 'resolve is bound to the revision after the comment');
  } finally {
    await blocked.cleanup();
  }

  const review = await mount({
    answer: (call) => {
      if (call.method === 'runtime.read' && call.command.task_id === 'task_3') return { ...runtime({ state: 'in_review' }), submission: [['1', 'b'.repeat(40), '1', 'Shipped the build', 'agt_worker']] };
      if (call.method === 'review.post') return { chain_id: CHAIN, task_id: 'task_3', revision: '4' };
      return owner.answer(call);
    },
    render: (_env, h) => aux({ type: 'ticket', chainId: CHAIN, taskId: 'task_3' }, h),
  });
  try {
    const block = review.$('your-review-block')!;
    assert.match(block.textContent!, /Your review.*head bbbbbbb/s);
    assert.equal((review.$('ticket-view-request-changes-btn') as HTMLButtonElement).disabled, true, 'request changes needs a note');
    await typeInto(review, 'your-review-composer-input', 'Add a changelog entry');
    assert.equal((review.$('ticket-view-approve-btn') as HTMLButtonElement).disabled, true, 'approve sends no note, so it waits while one is typed');
    await review.click('ticket-view-request-changes-btn');
    const post = review.calls.find((c) => c.method === 'review.post')!;
    assert.deepEqual({ verdict: post.payload.verdict, attempt: post.payload.attempt, head: post.payload.head }, { verdict: 'request_changes', attempt: '1', head: 'b'.repeat(40) });
  } finally {
    await review.cleanup();
  }
});

test('the board card Edit menu opens the ticket tab with the requirements editor open, once', async () => {
  const board = await mount({ render: (_env, h) => aux({ type: 'tasks' }, h) });
  try {
    await board.click('task-card-more-task_1');
    await board.click('task-card-edit-requirements-task_1');
    assert.deepEqual(board.opened.at(-1)!.content, { type: 'ticket', chainId: CHAIN, taskId: 'task_1', focus: 'edit_requirements' });
  } finally {
    await board.cleanup();
  }
  const ticket = await mount({ render: (_env, h) => aux({ type: 'ticket', chainId: CHAIN, taskId: 'task_1', focus: 'edit_requirements' }, h) });
  try {
    // The editor is a modal (rendered outside the pane).
    assert.ok(win.document.querySelector('[data-debug-id="task-requirements-editor"]'), 'the requirements editor is open');
    assert.ok(ticket.updated.some((u) => u.patch?.focus === null), 'the one-shot focus is consumed');
  } finally {
    await ticket.cleanup();
  }
});

test('the board card Edit › reviewers opens the ticket tab with origin/main reviewers dialog open', async () => {
  // task_1 is being worked on (its people are locked); task_2 is waiting.
  const board = await mount({ render: (_env, h) => aux({ type: 'tasks' }, h) });
  try {
    await board.click('task-card-more-task_2');
    await board.click('task-card-edit-reviewers-task_2');
    assert.deepEqual(board.opened.at(-1)!.content, { type: 'ticket', chainId: CHAIN, taskId: 'task_2', focus: 'edit_reviewers' });
  } finally {
    await board.cleanup();
  }
  const ticket = await mount({ render: (_env, h) => aux({ type: 'ticket', chainId: CHAIN, taskId: 'task_2', focus: 'edit_reviewers' }, h) });
  try {
    assert.ok(win.document.querySelector('[data-debug-id="task-edit-user-approval"]'), 'the reviewers dialog is open');
    assert.ok(ticket.updated.some((u) => u.patch?.focus === null), 'the one-shot focus is consumed');
  } finally {
    await ticket.cleanup();
  }
});

test('the ticket shows origin/main requirements card; Changes diffs the latest edit from the owner history', async () => {
  const { encryptVaultText } = await import('../src/ui/utils/vaultCrypto.ts');
  const owner = chainOwner();
  const edits: Record<string, { revision: string; doc: unknown }> = {
    '4': { revision: '1', doc: { goal: 'Fix login', acceptance: ['Works on Safari'] } },
    '9': { revision: '2', doc: { goal: 'Fix login everywhere', acceptance: ['Works on Safari', 'Works on Firefox'], requirements_reason: 'Firefox fails too' } },
  };
  const ui = await mount({
    answer: async (call) => {
      if (call.method === 'runtime.read' && call.command.task_id === 'task_1') {
        return { ...runtime(), requirements: [['2', JSON.stringify({ goal: 'Fix login everywhere', acceptance: ['Works on Safari', 'Works on Firefox'] })]] };
      }
      if (call.method === 'history.read') return { chain_id: CHAIN, next_cursor: '', items: [
        { seq: '4', kind: 'requirements.edit', task_id: 'task_1', actor_kind: 'device', actor_id: 'dev_x', ts_ms: '1794200000000' },
        { seq: '9', kind: 'requirements.edit', task_id: 'task_1', actor_kind: 'agent', actor_id: 'inst_coord', ts_ms: '1794200002000' },
      ] };
      if (call.method === 'history.fetch') {
        const e = edits[call.payload.seq ?? ''];
        const payload = JSON.stringify({ requirements_revision: e.revision, body_cipher: await encryptVaultText(JSON.stringify(e.doc)) });
        return { evidence: JSON.stringify({ payload }), next_offset: '' };
      }
      return owner.answer(call);
    },
    render: (_env, h) => aux({ type: 'ticket', chainId: CHAIN, taskId: 'task_1' }, h),
  });
  try {
    const card = ui.$('ticket-view-requirements')!;
    assert.match(card.textContent!, /Requirements.*Rev 2.*Fix login everywhere.*Works on Firefox/s);
    assert.ok(ui.$('ticket-view-requirements-change-btn'), 'Change requirements lives on the card');
    await ui.click('ticket-view-requirements-changes');
    await ui.settle();
    const diff = ui.$('ticket-view-requirements-diff')!;
    assert.match(diff.textContent!, /Since rev 1.*Fix login.*Fix login everywhere.*Add.*Works on Firefox/s);
  } finally {
    await ui.cleanup();
  }
});

test('ownerRequirementHistoryEntries pairs each change with the previous one', async () => {
  const { ownerRequirementHistoryEntries } = await import('../src/ui/components/tasks/ownerTaskAdapter.ts');
  const base = { reason: '', actorId: 'x', readable: true };
  const entries = ownerRequirementHistoryEntries([
    { ...base, seq: '9', revision: '2', goal: 'B', acceptance: ['b'], actorKind: 'device', at: '2026-11-10T00:00:00Z' },
    { ...base, seq: '4', revision: '1', goal: 'A', acceptance: ['a'], actorKind: 'agent', at: '' },
  ]);
  assert.deepEqual(entries.map((e) => [e.revision, e.actorKind, e.before.goal, e.after.goal, e.eventId]), [[2, 'user', 'A', 'B', 9], [1, 'agent', '', 'A', 4]]);
  assert.equal(entries[0].tsMs, Date.parse('2026-11-10T00:00:00Z'));
});

test('a ticket shows its handoffs on demand: summary, next steps, waiting on and head, newest first', async () => {
  const owner = chainOwner();
  const payloads: Record<string, unknown> = {
    '5': { requirements_revision: '1', summary: 'Half done; OAuth flow works', next_steps: 'Wire the Safari fix' },
    '8': { requirements_revision: '1', summary: 'Need the client id', next_steps: '', waiting_on: 'human' },
    '11': { requirements_revision: '1', summary: 'Login fixed everywhere', head: 'c'.repeat(40) },
  };
  const ui = await mount({
    answer: (call) => {
      if (call.method === 'runtime.read' && call.command.task_id === 'task_1') return { ...runtime({ lease: 'inst_worker' }), attempts: { attempt_no: '2', last_release: '', work_lease_id: '', completeness: 'full' } };
      if (call.method === 'history.read') return { chain_id: CHAIN, next_cursor: '', items: [
        { seq: '5', kind: 'lease.handoff', task_id: 'task_1', actor_kind: 'agent', actor_id: 'inst_worker', ts_ms: '1794200000000' },
        { seq: '6', kind: 'lease.handoff', task_id: 'task_2', actor_kind: 'agent', actor_id: 'inst_worker', ts_ms: '1794200000500' },
        { seq: '7', kind: 'task.comment', task_id: 'task_1', actor_kind: 'agent', actor_id: 'inst_worker', ts_ms: '1794200000600' },
        { seq: '8', kind: 'lease.block', task_id: 'task_1', actor_kind: 'agent', actor_id: 'inst_worker', ts_ms: '1794200001000' },
        { seq: '11', kind: 'lease.submit', task_id: 'task_1', actor_kind: 'agent', actor_id: 'inst_worker', ts_ms: '1794200002000' },
      ] };
      if (call.method === 'history.fetch') return { evidence: JSON.stringify({ payload: JSON.stringify(payloads[call.payload.seq ?? ''] ?? {}) }), next_offset: '' };
      return owner.answer(call);
    },
    render: (_env, h) => aux({ type: 'ticket', chainId: CHAIN, taskId: 'task_1' }, h),
  });
  try {
    assert.equal(ui.calls.filter((c) => c.method === 'history.fetch').length, 0, 'nothing is scanned until asked');
    await ui.click('ticket-activity-tab-handoffs');
    const rows = [...ui.$('ticket-activity-feed-handoffs')!.querySelectorAll('li[data-debug-id]')].map((li) => li.getAttribute('data-debug-id'));
    assert.deepEqual(rows, ['ticket-handoff-11', 'ticket-handoff-8', 'ticket-handoff-5'], 'this ticket only, newest first');
    assert.match(ui.$('ticket-handoff-11')!.textContent!, /Worker.*Submitted.*cccccccccccc.*Login fixed everywhere/s);
    assert.match(ui.$('ticket-handoff-8')!.textContent!, /Blocked.*Need the client id.*Waiting on human/s);
    assert.match(ui.$('ticket-handoff-5')!.textContent!, /Handed off.*Half done.*Next steps.*Wire the Safari fix/s);
    // The All feed lists every event of this ticket, described.
    await ui.click('ticket-activity-tab-all');
    assert.match(ui.$('ticket-activity-feed-all')!.textContent!, /Worker.*submitted for review.*Worker.*blocked the ticket.*Worker.*commented.*Worker.*handed the ticket off/s);
    assert.ok(!/Write docs/.test(ui.$('ticket-activity-feed-all')!.textContent!), 'other tickets\' events stay out');
  } finally {
    await ui.cleanup();
  }
});

test('the ticket shows origin/main linked tickets from the owner dependencies: what it waits for and unblocks', async () => {
  const owner = chainOwner();
  const ui = await mount({
    answer: (call) => (call.method === 'work.read'
      ? { chain_id: CHAIN, publish_state: 'published', status: 'active', work_revision: '1', pending_proposal_id: '', next_cursor: '', pending_proposal: null,
        items: [
          { kind: 'dependency', key: 'dep_1', accepted_seq: '2', record: { dependency_id: 'dep_1', dependent: { kind: 'task', id: 'task_1' }, prerequisite: { kind: 'task', id: 'task_3' }, removed_at: '' } },
          { kind: 'dependency', key: 'dep_2', accepted_seq: '3', record: { dependency_id: 'dep_2', dependent: { kind: 'task', id: 'task_2' }, prerequisite: { kind: 'task', id: 'task_1' }, removed_at: '' } },
        ] }
      : owner.answer(call)),
    render: (_env, h) => aux({ type: 'ticket', chainId: CHAIN, taskId: 'task_1' }, h),
  });
  try {
    const linked = ui.$('ticket-view-linked');
    assert.ok(linked, 'linked tickets card');
    assert.match(linked!.textContent!, /Waits for.*Ship.*Done.*Unblocks.*Write docs/s);
    assert.ok(ui.$('ticket-view-unblocks-task_2'));
  } finally {
    await ui.cleanup();
  }
});
