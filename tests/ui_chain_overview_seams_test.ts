// origin/main's chain overview (ChainOverviewPanel) and chain board
// (TaskChainOverview + CreateTaskModal) render from props and act only through
// their action seams: no Hub hook, no fetch. Members, attention, review votes,
// VCS, terminals; the board's skeleton, error and New ticket flow.
//
// RUN: node --import ./tests/helpers/vaultEndpointHarness.ts --test tests/ui_chain_overview_seams_test.ts

import './helpers/vaultEndpointHarness.ts';
import { test } from 'node:test';
import assert from 'node:assert/strict';
import React, { act } from 'react';
import { JSDOM } from 'jsdom';
import type { TaskWire } from '../src/ui/api/taskWire.ts';

const dom = new JSDOM('<!DOCTYPE html><html><body></body></html>', { url: 'http://localhost/', pretendToBeVisual: true });
const win = dom.window as any;
win.matchMedia = (q: string) => ({ matches: false, media: q, addEventListener() {}, removeEventListener() {}, addListener() {}, removeListener() {} });
for (const [key, value] of Object.entries({ window: win, document: win.document, navigator: win.navigator, HTMLElement: win.HTMLElement, Node: win.Node,
  IS_REACT_ACT_ENVIRONMENT: true, CSS: { escape: (v: string) => v.replace(/[^\w-]/g, (c) => '\\' + c) } })) {
  Object.defineProperty(globalThis, key, { value, writable: true, configurable: true });
}
win.HTMLElement.prototype.scrollIntoView = function scrollIntoView() {};
const { createRoot } = await import('react-dom/client');
const { Provider } = await import('react-redux');
const { makeVaultStore } = await import('./helpers/vaultEndpointHarness.ts');
const { default: ChainOverviewPanel, checklistItems, agentStatusLabel } = await import('../src/ui/components/chat/ChainOverviewPanel.tsx');
const { TaskChainOverview, replacedByMap } = await import('../src/ui/components/taskchain/TaskChainOverview.tsx');
const { createTaskInputError } = await import('../src/ui/components/tasks/CreateTaskModal.tsx');
const store = await makeVaultStore();

function task(id: string, over: Partial<TaskWire> = {}): TaskWire {
  return {
    task_id: id, chain_id: 'chain_1', title: id.toUpperCase(), publish_state: 'published', state: 'ready', kind: 'work', priority: 'p2',
    attempt_no: 0, bridge_id: 'brg_1', brief: null, blocked_on: null, requires_user_approval: false, ready_since: '', leases: [], reviews: [], ...over,
  } as TaskWire;
}
const lease = (holder: string) => ({ lease_id: 'l_' + holder, kind: 'work', holder_instance_id: holder, attempt_no: 1, bridge_id: 'brg_1', granted_at: '', confirmed_at: '', expires_at: '', hard_deadline_at: '', delivery: '' });

async function mount(el: React.ReactElement) {
  // Hub reads would go through fetch: any call fails the test.
  const fetched: string[] = [];
  const saved = globalThis.fetch;
  globalThis.fetch = (async (input: any) => { fetched.push(String(input?.url ?? input)); return new Response('{}'); }) as typeof fetch;
  const container = win.document.createElement('div');
  win.document.body.appendChild(container);
  const root = createRoot(container);
  const settle = async () => { for (let i = 0; i < 10; i++) await act(async () => { await new Promise((r) => setTimeout(r, 2)); }); };
  await act(async () => root.render(React.createElement(Provider, { store }, el)));
  await settle();
  const $ = (id: string) => win.document.querySelector(`[data-debug-id="${id}"]`) as HTMLElement | null;
  const click = async (id: string) => { const n = $(id); assert.ok(n, 'missing ' + id); await act(async () => { n!.click(); }); await settle(); };
  const type = async (id: string, value: string) => {
    const n = $(id) as HTMLInputElement | HTMLTextAreaElement;
    assert.ok(n, 'missing ' + id);
    const setter = Object.getOwnPropertyDescriptor(Object.getPrototypeOf(n), 'value')!.set!;
    await act(async () => { setter.call(n, value); n.dispatchEvent(new win.Event('input', { bubbles: true })); });
  };
  const cleanup = async () => { await act(async () => root.unmount()); container.remove(); globalThis.fetch = saved; };
  return { $, click, type, settle, cleanup, fetched };
}

test('ChainOverviewPanel renders members, ongoing and attention tickets from props and acts through its actions', async () => {
  const ran: string[] = [];
  const reviews: unknown[][] = [];
  const opened: string[] = [];
  const tasks = [
    task('task_1', { state: 'in_progress', priority: 'p1', leases: [lease('inst_w')] }),
    task('task_2', { state: 'in_review', requires_user_approval: true, brief: { goal: 'g', acceptance: ['Works on Safari'] } as any }),
  ];
  const ui = await mount(React.createElement(ChainOverviewPanel, {
    members: [
      { instanceId: 'inst_c', agentId: 'agt_c', name: 'Coordinator', role: 'coordinator', status: 'stopped', enabled: true },
      { instanceId: 'inst_w', agentId: 'agt_w', name: 'Writer', role: 'worker', status: 'running', enabled: true },
      { instanceId: 'inst_old', agentId: 'agt_o', name: 'Old', role: 'worker', status: 'running', enabled: false },
    ],
    tasks,
    actions: {
      busy: false,
      start: async (id: string) => { ran.push('start ' + id); },
      stop: async (id: string) => { ran.push('stop ' + id); },
      remove: async (m: any) => { ran.push('remove ' + m.instanceId); },
      loadDescription: async () => 'Fix Safari login',
      review: async (...args: unknown[]) => { reviews.push(args); return true; },
    },
    vcs: { branch: 'feature/login', files: [{ path: 'src/a.ts', status: 'modified', staged: false, additions: 3, deletions: 1 } as any] },
    tokenUsageSlot: React.createElement('p', { 'data-debug-id': 'usage-slot' }, 'usage'),
    onSelectTask: (id: string) => opened.push('task:' + id),
    onOpenAgentChat: (id: string) => opened.push('chat:' + id),
    onOpenAgentPty: (id: string) => opened.push('pty:' + id),
    onOpenFileDiff: (p: string) => opened.push('diff:' + p),
  }));
  try {
    assert.match(ui.$('chain-overview-agent-row-inst_w')!.textContent!, /Writer.*worker.*Running.*TASK_1/s);
    assert.equal(ui.$('chain-overview-restart-agent-inst_w'), null, 'an action the source does not supply is not offered');
    assert.equal(ui.$('chain-overview-stop-agent-inst_old'), null, 'a removed member has no controls');
    assert.match(ui.$('chain-overview-agent-row-inst_old')!.textContent!, /Removed/);
    assert.equal(ui.$('chain-overview-remove-agent-inst_c'), null, 'the coordinator is never removed');
    await ui.click('chain-overview-stop-agent-inst_w');
    await ui.click('chain-overview-start-agent-inst_c');
    await ui.click('chain-overview-remove-agent-inst_w');
    await ui.click('chain-overview-open-pty-inst_w');
    assert.deepEqual(ran, ['stop inst_w', 'start inst_c', 'remove inst_w']);
    assert.deepEqual(opened, ['pty:inst_w'], 'row controls do not open the chat');
    await ui.click('chain-overview-agent-row-inst_w');
    assert.equal(opened.at(-1), 'chat:inst_w');

    assert.match(ui.$('chain-overview-section-ongoing-tasks')!.textContent!, /Ongoing tasks \(2\)/);
    assert.match(ui.$('chain-overview-attention-task-task_2')!.textContent!, /Review required by you.*TASK_2.*Reviewer: You/s);
    await ui.click('chain-overview-attention-toggle-task_2');
    assert.match(ui.$('chain-overview-attention-review-task_2')!.textContent!, /Acceptance criteria.*Works on Safari/s);
    assert.equal((ui.$('chain-overview-vote-ngtm-task_2') as HTMLButtonElement).disabled, true, 'request changes needs a note');
    await ui.click('chain-overview-vote-lgtm-task_2');
    assert.deepEqual(reviews, [['task_2', 'approve', '']]);
    assert.equal(ui.$('chain-overview-attention-review-task_2'), null, 'the card closes after the vote');

    assert.match(ui.$('chain-overview-section-vcs')!.textContent!, /1 Modified.*0 Staged.*feature\/login.*src\/a\.ts.*\+3.*-1/s);
    await ui.click('chain-overview-vcs-file-src/a.ts');
    assert.equal(opened.at(-1), 'diff:src/a.ts');
    assert.ok(ui.$('usage-slot'));
    assert.equal(ui.$('chain-overview-section-activity'), null, 'no activity slot: no section');
    assert.deepEqual(ui.fetched, [], 'the panel fetches nothing itself');
  } finally {
    await ui.cleanup();
  }
});

test('TaskChainOverview shows a skeleton, an error, and creates a ticket through its create seam', async () => {
  const props = { chainId: 'chain_1', tasks: [] as TaskWire[], keys: new Map<string, string>(), actionsFor: () => ({ busy: false, error: '', hold: async () => true, release: async () => true, cancel: async () => true, reopen: async () => true }), onOpenTicket: () => {}, onEditTicket: () => {} };
  let ui = await mount(React.createElement(TaskChainOverview, { ...props, loading: true }));
  try { assert.ok(ui.$('task-board-skeleton')); } finally { await ui.cleanup(); }
  ui = await mount(React.createElement(TaskChainOverview, { ...props, error: 'Owner refused' }));
  try { assert.match(ui.$('taskchain-error')!.textContent!, /Failed to load task chain: Owner refused/); } finally { await ui.cleanup(); }

  const created: any[] = [];
  const opened: unknown[][] = [];
  let answer = 'Owner refused the ticket';
  ui = await mount(React.createElement(TaskChainOverview, {
    ...props,
    tasks: [task('task_1', { title: 'Fix login' })],
    keys: new Map([['task_1', 'T-1']]),
    hideTitleBar: true,
    onOpenTicket: (...args: unknown[]) => { opened.push(args); },
    create: { agentOptions: [{ value: 'agt_sec', label: 'Security' }], create: async (input: any) => { created.push(input); return answer; } },
  }));
  try {
    assert.ok(!/Mixed work/.test(ui.$('taskchain-overview-container')!.textContent!), 'hideTitleBar');
    await ui.click('task-card-toggle-task_1');
    assert.deepEqual(opened.at(-1)!.slice(0, 2), ['task_1', 'T-1 Fix login']);
    await ui.click('task-board-new-task-btn');
    await ui.click('create-task-submit-btn');
    assert.equal(ui.$('create-task-error')!.textContent, 'Please enter a ticket title.');
    await ui.type('create-task-title-input', 'Add audit log');
    await ui.type('create-task-goal-input', 'Writes are logged');
    await ui.type('create-task-acceptance-input', 'One row per write\nViewable');
    await ui.click('create-task-require-user-approval-checkbox');
    await ui.click('create-task-depends-on-task_1');
    await ui.click('create-task-submit-btn');
    assert.equal(ui.$('create-task-error')!.textContent, 'Owner refused the ticket', 'a refusal stays in the modal');
    answer = '';
    await ui.click('create-task-submit-btn');
    assert.equal(ui.$('create-task-modal'), null, 'the modal closes once created');
    assert.deepEqual(created.at(-1), {
      title: 'Add audit log', description: '', goal: 'Writes are logged', acceptance: ['One row per write', 'Viewable'], reviewers: [], requiresUserApproval: true, dependsOn: ['task_1'],
    });
    assert.deepEqual(ui.fetched, []);
  } finally {
    await ui.cleanup();
  }
});

test('the seams\' pure helpers: checklist lines, status words, replacement links, create validation', () => {
  assert.deepEqual(checklistItems('Intro\n- [x] done\n[ ] open\n* not a box'), [{ checked: true, text: 'done' }, { checked: false, text: 'open' }]);
  assert.equal(agentStatusLabel('launching'), 'Starting');
  assert.equal(agentStatusLabel(''), '');
  const replaced = (preview: string) => task('task_1', { comment_summary: { count: 1, last_comment_at: '', last_comment_author_agent_instance_id: '', last_comment_preview: preview } });
  assert.deepEqual(replacedByMap([replaced('Replaced by ticket task_9 (T-9).'), task('task_2')]), { task_1: 'task_9' });
  assert.deepEqual(replacedByMap([replaced('Just a comment')]), {});
  const base = { title: 'T', description: '', goal: '', acceptance: [], reviewers: [], requiresUserApproval: false, dependsOn: [] };
  assert.equal(createTaskInputError(base), '');
  assert.match(createTaskInputError({ ...base, goal: 'x'.repeat(2001) }), /goal exceeds 2000/);
  assert.match(createTaskInputError({ ...base, acceptance: Array.from({ length: 21 }, () => 'a') }), /at most 20/);
  assert.match(createTaskInputError({ ...base, acceptance: ['x'.repeat(201)] }), /exceeds 200/);
});
