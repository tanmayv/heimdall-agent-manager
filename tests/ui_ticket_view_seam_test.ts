// origin/main's ticket tab (TicketView) behind its props seam: it renders a
// TaskWire with the feeds and actions it is given, never reads a Hub task or
// chain endpoint, offers only the actions supplied, and hands each change to
// its actions in the documented shapes (hold reason, comment body, dependency
// set, requirements amendment, attempt to read).
//
// RUN: node --import ./tests/helpers/vaultEndpointHarness.ts --test tests/ui_ticket_view_seam_test.ts

import './helpers/vaultEndpointHarness.ts';
import { test } from 'node:test';
import assert from 'node:assert/strict';
import React, { act } from 'react';
import { JSDOM } from 'jsdom';
import type { TaskWire } from '../src/ui/api/taskWire.ts';

const dom = new JSDOM('<div id="root"></div>', { url: 'https://hub.example.test/', pretendToBeVisual: true });
for (const [key, value] of Object.entries({ window: dom.window, document: dom.window.document, navigator: dom.window.navigator,
  HTMLElement: dom.window.HTMLElement, Node: dom.window.Node, IS_REACT_ACT_ENVIRONMENT: true,
  CSS: { escape: (v: string) => v.replace(/[^\w-]/g, (c) => '\\' + c) } })) {
  Object.defineProperty(globalThis, key, { value, writable: true, configurable: true });
}
dom.window.HTMLElement.prototype.scrollIntoView = function scrollIntoView() {};
const { createRoot } = await import('react-dom/client');
const { Provider } = await import('react-redux');
const { makeVaultStore } = await import('./helpers/vaultEndpointHarness.ts');
const { keyringInstalled } = await import('../src/ui/store/vaultSlice.ts');
const { TicketView } = await import('../src/ui/components/tasks/TicketView.tsx');
const { buildTaskNames } = await import('../src/ui/components/tasks/taskNames.ts');
const { ticketKeys } = await import('../src/ui/components/tasks/ticketModel.ts');

const ticket = (over: Partial<TaskWire> = {}): TaskWire => ({
  task_id: 'task_1', chain_id: 'chain_1', title: 'Fix login', description: 'Login fails on Safari', publish_state: 'published', state: 'ready', kind: 'work',
  priority: 'p1', attempt_no: 2, bridge_id: 'brg_1', brief: { goal: 'Users can sign in', acceptance: ['SSO works'], reviewers: [] }, blocked_on: null,
  requires_user_approval: false, ready_since: '', requirements: { revision: 2, submitted_revision: 0, submitted_head: '', checkpoint_required: false, acknowledgements: [], history: '', history_truncated: false },
  leases: [], reviews: [], ...over,
} as TaskWire);
const other = ticket({ task_id: 'task_2', title: 'Write docs', description: '', attempt_no: 0 });

function harness(props: Record<string, unknown> = {}) {
  const log: { name: string; args: unknown[] }[] = [];
  const spy = <T,>(name: string, result: T) => async (...args: unknown[]) => { log.push({ name, args }); return result; };
  const actions = {
    busy: false, error: '',
    approve: spy('approve', true), requestChanges: spy('requestChanges', true), answer: spy('answer', true), comment: spy('comment', true),
    hold: spy('hold', true), release: spy('release', true), cancel: spy('cancel', true), reopen: spy('reopen', true),
    setPriority: spy('setPriority', ''),
    amendRequirements: spy('amendRequirements', { error: '' }),
    saveEdit: spy('saveEdit', ''),
  };
  const opened: string[] = [];
  const loads: number[] = [];
  const needs: string[] = [];
  const tickets = [ticket(), other];
  const base = {
    chainId: 'chain_1', taskId: 'task_1', task: tickets[0], loading: false, tickets, keys: ticketKeys(tickets), names: buildTaskNames({ tasks: tickets }),
    actions, placement: { bridge: 'Home Bridge', model: '' },
    requirementHistory: { entries: null, onNeed: () => needs.push('history') },
    activity: {
      comments: { items: [{ id: 'c1', author: 'inst_w', body: 'Working on it', at: '2026-11-01T10:00:00Z' }] },
      events: { items: null }, handoffs: { items: [] },
      onOpen: (tab: string) => opened.push(tab),
    },
    changes: { changes: null, onLoad: (n: number) => loads.push(n), attempts: [1, 2] },
    onShowBoard: () => opened.push('board'), onOpenTicket: () => {}, onSwitchTicket: () => {}, onOpenAgent: () => {},
    ...props,
  };
  return { log, actions, opened, loads, needs, props: base };
}

async function mount(props: Record<string, unknown>) {
  const store = await makeVaultStore();
  store.dispatch(keyringInstalled({ currentEpoch: 1 }));
  const fetched: string[] = [];
  const saved = globalThis.fetch;
  globalThis.fetch = (async (input: any) => { fetched.push(String(input?.url ?? input)); return new Response('{}', { status: 200 }); }) as typeof fetch;
  const container = dom.window.document.createElement('div');
  dom.window.document.body.appendChild(container);
  const root = createRoot(container);
  const flush = async () => { for (let i = 0; i < 10; i++) await act(async () => { await new Promise((r) => setTimeout(r, 2)); }); };
  const render = async (p: Record<string, unknown>) => { await act(async () => root.render(React.createElement(Provider, { store }, React.createElement(TicketView as any, p)))); await flush(); };
  await render(props);
  const $ = (id: string) => dom.window.document.querySelector(`[data-debug-id="${id}"]`) as HTMLElement | null;
  const click = async (id: string) => { const el = $(id); assert.ok(el, 'missing ' + id); await act(async () => { el!.click(); }); await flush(); };
  const type = async (id: string, value: string) => {
    const el = $(id) as HTMLInputElement | HTMLTextAreaElement;
    assert.ok(el, 'missing ' + id);
    const setter = Object.getOwnPropertyDescriptor(Object.getPrototypeOf(el), 'value')!.set!;
    await act(async () => { setter.call(el, value); el.dispatchEvent(new dom.window.Event('input', { bubbles: true })); });
  };
  const cleanup = async () => { await act(async () => root.unmount()); container.remove(); globalThis.fetch = saved; };
  return { $, click, type, render, fetched, cleanup, text: () => container.textContent || '' };
}

test('the ticket tab renders the given ticket and feeds, asks for each feed once, and reads nothing from the Hub', async () => {
  const h = harness();
  const ui = await mount(h.props);
  try {
    assert.equal(ui.$('ticket-view-title')!.textContent, 'Fix login');
    assert.match(ui.$('ticket-view-description')!.textContent!, /Login fails on Safari/);
    assert.match(ui.$('ticket-view-requirements')!.textContent!, /Rev 2.*Users can sign in.*SSO works/s);
    assert.deepEqual(h.opened, ['all'], 'the All feed is asked for when the tab opens');
    assert.match(ui.$('ticket-activity')!.textContent!, /Loading activity/, 'an unread feed says it is loading');
    await ui.click('ticket-activity-tab-comments');
    assert.match(ui.$('ticket-comment-c1')!.textContent!, /inst_w.*Working on it/s);
    await ui.click('ticket-activity-tab-handoffs');
    assert.match(ui.$('ticket-activity-feed-handoffs')!.textContent!, /No handoffs yet/);
    await ui.click('ticket-activity-tab-requirements');
    await ui.click('ticket-activity-tab-all');
    assert.deepEqual(h.opened, ['all', 'comments', 'handoffs', 'requirements'], 'each tab asks once');
    assert.deepEqual(h.needs, ['history'], 'Requirement changes asks for the history');
    assert.equal(ui.$('ticket-activity-tab-reviews'), null, 'no Reviews tab unless a reviews feed is given');
    assert.equal(ui.fetched.length, 0, 'no Hub request: ' + ui.fetched.join(', '));
  } finally { await ui.cleanup(); }
});

test('actions go to the seam: hold with a reason, a comment without attachments, the attempt to read', async () => {
  const h = harness();
  const ui = await mount(h.props);
  try {
    await ui.click('ticket-view-hold-btn');
    await ui.type('task-hold-reason-input', 'Design first');
    await ui.click('task-hold-confirm-btn');
    assert.deepEqual(h.log.find((l) => l.name === 'hold')!.args, ['Design first']);

    assert.ok(!/Attach/.test(ui.$('comment-composer')!.textContent!), 'no upload: no Attach');
    await ui.type('comment-composer-input', 'Looks good');
    await ui.click('ticket-view-comment-send-btn');
    assert.deepEqual(h.log.find((l) => l.name === 'comment')!.args, ['Looks good']);

    await ui.click('ticket-view-changes-toggle');
    assert.deepEqual(h.loads, [2], 'the current attempt is read when Changes opens');
    await ui.click('ticket-view-changes-attempt-1');
    assert.deepEqual(h.loads, [2, 1]);
    await ui.render({ ...h.props, changes: { ...(h.props.changes as object), changes: { attempt: 1, files: [], output: 'First try', head: 'abc1234def', author: 'Worker' } } });
    assert.match(ui.$('task-details-output')!.textContent!, /Attempt 1.*Worker.*abc1234def.*First try/s);

    await ui.click('ticket-view-more-btn');
    for (const id of ['ticket-view-menu-recheck', 'ticket-view-edit-bridge', 'ticket-view-menu-delete']) assert.equal(ui.$(id), null, `${id} is not offered without its action`);
    assert.ok(ui.$('ticket-view-edit-assignee') && ui.$('ticket-view-edit-reviewers') && ui.$('ticket-view-edit-deps'), 'the default editors');
    assert.equal(ui.fetched.length, 0);
  } finally { await ui.cleanup(); }
});

test('editors save through the seam: dependencies as a set, requirements as an amendment, a conflict keeps the draft', async () => {
  const h = harness({ editFields: ['deps'] });
  let amendResult: { error: string; conflict?: boolean } = { error: 'The requirements changed.', conflict: true };
  h.props.actions = { ...h.actions, amendRequirements: async (a: unknown) => { h.log.push({ name: 'amend', args: [a] }); return amendResult; } };
  const ui = await mount(h.props);
  try {
    await ui.click('ticket-view-more-btn');
    assert.equal(ui.$('ticket-view-edit-assignee'), null, 'only the given editors are offered');
    await ui.click('ticket-view-edit-deps');
    await ui.click('task-edit-dep-task_2');
    await ui.click('task-edit-save');
    assert.deepEqual(h.log.find((l) => l.name === 'saveEdit')!.args, [{ field: 'deps', dependsOn: ['task_2'] }]);
    assert.equal(ui.$('task-edit-modal'), null, 'the dialog closes once saved');

    await ui.click('ticket-view-change-requirements-btn');
    await ui.type('task-requirements-acceptance-0', 'SSO works on Safari');
    await ui.type('task-requirements-reason', 'Safari');
    await ui.click('task-requirements-save');
    assert.deepEqual(h.log.find((l) => l.name === 'amend')!.args, [{ goal: 'Users can sign in', acceptance: ['SSO works on Safari'], reason: 'Safari', baseRevision: 2, goalChanged: false }]);
    // (origin/main uses task-requirements-status for both the card's Rev badge and the editor's status line.)
    const statuses = [...dom.window.document.querySelectorAll('[data-debug-id="task-requirements-status"]')].map((el) => el.textContent).join(' | ');
    assert.match(statuses, /Someone changed these requirements/, 'a conflict keeps the editor open with the draft');
    assert.equal((ui.$('task-requirements-acceptance-0') as HTMLInputElement).value, 'SSO works on Safari', 'the draft stays');
    amendResult = { error: '' };
  } finally { await ui.cleanup(); }
});

test('read-only: no changes are offered; an edit focus opens its editor once', async () => {
  const h = harness({ readOnly: true });
  const ui = await mount(h.props);
  try {
    for (const id of ['ticket-view-quick-actions', 'comment-composer', 'ticket-view-hold-btn', 'ticket-view-change-requirements-btn']) assert.equal(ui.$(id), null, id);
    assert.equal((ui.$('ticket-view-state-btn') as HTMLButtonElement).disabled, true, 'no state changes');
  } finally { await ui.cleanup(); }

  let consumed = 0;
  const focused = harness({ editFocus: 'reviewers', onEditFocusConsumed: () => { consumed += 1; }, agents: [{ agentId: 'agt_sec', name: 'Security' }] });
  const ui2 = await mount(focused.props);
  try {
    assert.ok(ui2.$('task-edit-reviewer-agt_sec'), 'the reviewers editor is open');
    assert.equal(consumed, 1);
    await ui2.click('task-edit-reviewer-agt_sec');
    await ui2.click('task-edit-save');
    assert.deepEqual(focused.log.find((l) => l.name === 'saveEdit')!.args, [{ field: 'reviewers', reviewers: ['agt_sec'], reviewRoles: [], requiresUserApproval: false }]);
  } finally { await ui2.cleanup(); }
});
