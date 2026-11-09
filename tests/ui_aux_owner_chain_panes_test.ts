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
  requestAnimationFrame: raf, cancelAnimationFrame: caf, IS_REACT_ACT_ENVIRONMENT: true })) {
  Object.defineProperty(globalThis, key, { value, writable: true, configurable: true });
}
const { createRoot } = await import('react-dom/client');
const { act } = await import('react');
const { Provider } = await import('react-redux');
const { AuxTabContent } = await import('../src/ui/components/auxiliary/AuxTabContent.tsx');
const { OwnerChainAuxPane } = await import('../src/ui/components/taskchain/OwnerChainAuxPane.tsx');
const { resetOwnerChainsForTest } = await import('../src/ui/api/ownerChainsStore.ts');
const { heimdallApi } = await import('../src/ui/api/heimdallApi.ts');

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
  const saved = globalThis.fetch;
  globalThis.fetch = (async (input: any, init: any = {}) => {
    const u = new URL(String(input?.url ?? input), 'http://localhost');
    const ok = (data: unknown) => new Response(JSON.stringify({ data }), { status: 200, headers: { 'Content-Type': 'application/json' } });
    if (u.pathname === '/api/v1/vault/directory') return ok(env.hub.dir());
    if (u.pathname === '/api/v1/owner-local/relay') return ok(await send(JSON.parse(init.body)));
    hubPaths.push(u.pathname);
    return ok({});
  }) as typeof fetch;
  const store = await makeVaultStore();
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
  return { $, click, settle, calls, hubPaths, opened, updated, rekeyed, cleanup, container };
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

test('the Tickets board groups tickets by state, opens tickets as tabs and consumes a one-shot ticket', async () => {
  const ui = await mount({ render: (_env, h) => aux({ type: 'tasks', taskId: 'task_2' }, h) });
  try {
    assert.deepEqual(ui.opened[0], { content: { type: 'ticket', chainId: CHAIN, taskId: 'task_2' }, title: 'Write docs' }, 'the focused ticket opens once');
    assert.deepEqual(ui.updated[0].patch, { taskId: undefined }, 'and the board tab forgets it');
    assert.match(ui.$('owner-chain-board-column-in_progress')!.textContent!, /In progress · 1.*Fix login/s);
    assert.match(ui.$('owner-chain-board-column-ready')!.textContent!, /Ready · 1.*Write docs.*Held/s);
    assert.match(ui.$('owner-chain-board-column-done')!.textContent!, /Done · 1.*Ship/s);
    assert.equal(ui.$('owner-chain-task-detail'), null);
    await ui.click('owner-chain-task-task_3');
    assert.deepEqual(ui.opened.at(-1), { content: { type: 'ticket', chainId: CHAIN, taskId: 'task_3' }, title: 'Ship' });
    assert.equal(ui.opened.length, 2, 'the one-shot ticket is not reopened');
    assertNoHubChainReads(ui.hubPaths);
  } finally {
    await ui.cleanup();
  }
});

test('a ticket tab shows the brief, comments and reviews, goes back to the board and steps prev / next', async () => {
  const ui = await mount({ render: (_env, h) => aux({ type: 'ticket', chainId: CHAIN, taskId: 'task_1' }, h) });
  try {
    assert.equal(ui.$('owner-chain-task-title')!.textContent, 'Fix login');
    assert.match(ui.$('owner-chain-brief')!.textContent!, /Login fails on Safari/);
    assert.match(ui.$('owner-chain-comments')!.textContent!, /inst_worker.*Working on it/s);
    assert.match(ui.$('owner-chain-reviews')!.textContent!, /Changes requested.*agt_reviewer \(security\)/s);
    assert.equal(ui.$('owner-chain-tickets-ticket'), null, 'a ticket tab has no ticket list');
    assert.ok(ui.updated.some((u) => u.title === 'Fix login'), 'the tab is titled after the ticket');

    await ui.click('owner-chain-show-board');
    assert.deepEqual(ui.opened.at(-1)!.content, { type: 'tasks' });
    assert.equal((ui.$('owner-chain-prev-ticket') as HTMLButtonElement).disabled, true, 'the first ticket has no previous');
    await ui.click('owner-chain-next-ticket');
    assert.deepEqual(ui.rekeyed.at(-1), { content: { type: 'ticket', chainId: CHAIN, taskId: 'task_2' }, title: 'Write docs' });
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
    assert.equal(ui.$('owner-chain-task-task_4'), null);
    owner.state.tasks = [...owner.state.tasks, { task_id: 'task_4', title: 'Audit log', revision: '1', priority: 'p2' }];
    await ui.settle(60);
    assert.match(ui.$('owner-chain-task-task_4')!.textContent!, /Audit log/, 'a ticket added on the owner appears without a manual refresh');
  } finally {
    await ui.cleanup();
  }
});
