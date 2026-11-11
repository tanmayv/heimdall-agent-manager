// R4b: a Bridge-owned chain opens in a normal chain view built from signed
// owner reads (tickets with states, brief/requirements, comments with
// timestamps, submissions, owner and archived reviews), its basic actions are
// signed owner commands, and an offline owner shows the registry metadata with
// an explicit offline state and no raw errors.
//
// RUN: node --import ./tests/helpers/vaultEndpointHarness.ts --test tests/ui_owner_chain_view_test.ts

import './helpers/vaultEndpointHarness.ts';
import { test } from 'node:test';
import assert from 'node:assert/strict';
import React, { act } from 'react';
import { JSDOM } from 'jsdom';
import { fakeOwner, ownerTestSession, type OwnerCall } from './helpers/ownerFakeRelay.ts';
import { decryptVaultText } from '../src/ui/utils/vaultContent.ts';
import { clearKeyringSession } from '../src/ui/utils/vaultKeyringSession.ts';
import type { OwnerChainSummary } from '../src/ui/api/ownerChains.ts';

// React DOM decides its event support (e.g. `input` for onChange) when it is
// first loaded, so the DOM exists before react-dom and the view are imported.
const dom = new JSDOM('<div id="root"></div>', { url: 'https://hub.example.test/', pretendToBeVisual: true });
for (const [key, value] of Object.entries({ window: dom.window, document: dom.window.document, navigator: dom.window.navigator,
  HTMLElement: dom.window.HTMLElement, Node: dom.window.Node, IS_REACT_ACT_ENVIRONMENT: true,
  // jsdom has no CSS namespace; the @ui Select escapes option ids with it.
  CSS: { escape: (v: string) => v.replace(/[^\w-]/g, (c) => '\\' + c) } })) {
  Object.defineProperty(globalThis, key, { value, writable: true, configurable: true });
}
// The @ui Select scrolls its active option into view; jsdom does no layout.
dom.window.HTMLElement.prototype.scrollIntoView = function scrollIntoView() {};
const { createRoot } = await import('react-dom/client');
const { OwnerChainView } = await import('../src/ui/components/taskchain/OwnerChainView.tsx');
const { Provider } = await import('react-redux');
const { makeVaultStore } = await import('./helpers/vaultEndpointHarness.ts');
// The ticket decision block renders vault markdown, which reads the app store.
const store = await makeVaultStore();
// Owner chains open only with the vault unlocked; the ticket tab masks and locks its editors otherwise.
store.dispatch((await import('../src/ui/store/vaultSlice.ts')).keyringInstalled({ currentEpoch: 1 }));
const view = (props: any) => React.createElement(Provider, { store }, React.createElement(OwnerChainView, { bridges: [{ bridge_id: 'brg_b', name: 'riverwood' }], ...props }));

function mountDom() {
  const container = dom.window.document.createElement('div');
  dom.window.document.body.appendChild(container);
  const root = createRoot(container);
  const $ = (id: string) => dom.window.document.querySelector(`[data-debug-id="${id}"]`) as HTMLElement | null;
  const text = () => dom.window.document.body.textContent || '';
  const flush = async () => { for (let i = 0; i < 40; i++) await act(async () => { await new Promise((r) => setTimeout(r, 2)); }); };
  const click = async (id: string) => { const el = $(id); assert.ok(el, 'missing ' + id); await act(async () => { el!.click(); }); await flush(); };
  const type = async (id: string, value: string) => {
    const el = $(id) as HTMLInputElement | HTMLTextAreaElement;
    assert.ok(el, 'missing ' + id);
    const setter = Object.getOwnPropertyDescriptor(Object.getPrototypeOf(el), 'value')!.set!;
    await act(async () => { setter.call(el, value); el.dispatchEvent(new dom.window.Event('input', { bubbles: true })); });
  };
  const restore = async () => {
    await act(async () => root.unmount());
    container.remove();
  };
  // The page shows origin/main's board; a ticket opens in place of it and
  // its "Tickets" breadcrumb returns. A finished ticket is reached through the All filter.
  const openTicket = async (taskId: string) => {
    if ($('ticket-view-breadcrumb-tickets')) await click('ticket-view-breadcrumb-tickets');
    if ($(`task-card-toggle-${taskId}`)) return click(`task-card-toggle-${taskId}`);
    await click('ticket-board-filter-all');
    await click(`ticket-board-finished-row-${taskId}`);
  };
  return { dom, root, $, text, flush, click, type, restore, openTicket };
}

function summary(env: { bridgeId: string; bridgeName: string }, extra: Partial<OwnerChainSummary> = {}): OwnerChainSummary {
  return {
    chainId: 'chain_owned', ownerBridgeId: env.bridgeId, bridgeName: env.bridgeName, online: true,
    title: 'Registry title', description: 'Registry description', sealed: false,
    tasks: [{ taskId: 'task_1', title: 'Fix login' }, { taskId: 'task_2', title: 'Write docs' }],
    projectId: '', projectName: '', migrated: true, ...extra,
  };
}

test('owner chain view renders tickets, brief, comments, submissions and reviews, and signs revision-bound changes', async () => {
  const env = await ownerTestSession();
  const { session } = env;
  const calls: OwnerCall[] = [];
  // The fake owner enforces expected_revision exactly like the real one.
  let chainRev = 7;
  const taskRevs: Record<string, number> = { task_1: 3, task_2: 1 };
  const tasks = [{ task_id: 'task_1', title: 'Fix login', priority: 'p1' }, { task_id: 'task_2', title: 'Write docs', priority: 'p2' }];
  const revisions = { chain: () => String(chainRev), task: (_c: string, t: string) => String(taskRevs[t] ?? 0) };
  // Dependencies come from work.read, three items a page.
  const depItems: any[] = [
    { kind: 'proposal', key: 'p1', accepted_seq: '1', record: { proposal_id: 'p1' } },
    { kind: 'dependency', key: 'dep_old', accepted_seq: '2', record: { dependency_id: 'dep_old', dependent: { kind: 'task', id: 'task_1' }, prerequisite: { kind: 'task', id: 'task_2' }, removed_at: '2026-01-01T00:00:00Z' } },
    { kind: 'scope', key: '1', accepted_seq: '3', record: {} },
    { kind: 'dependency', key: 'dep_1', accepted_seq: '4', record: { dependency_id: 'dep_1', dependent: { kind: 'task', id: 'task_2' }, prerequisite: { kind: 'task', id: 'task_1' }, removed_at: '' } },
  ];
  let comments = [
    { operation_id: 'cmt_legacy', principal_id: 'inst_author', body: 'Imported comment', seq: '1', created_at: '2025-04-03T12:00:00Z' },
  ];
  const send = fakeOwner(session, async (call) => {
    const task = call.command.task_id;
    switch (call.method) {
      case 'chain.read': return { chain_id: 'chain_owned', task_id: '', revision: String(chainRev), title: 'Live chain title', description: 'Live description', defaults_json: '{}',
        items: tasks.map((t) => ({ ...t, revision: String(taskRevs[t.task_id]) })), next_cursor: '' };
      case 'work.read': {
        const offset = Number(String(call.payload.cursor || 'work:0').split(':')[1]);
        const limit = Number(call.payload.limit) === 3 ? 3 : 0;
        const next = limit && offset + 3 < depItems.length ? `work:${offset + 3}` : '';
        return { chain_id: 'chain_owned', publish_state: 'published', status: 'active', work_revision: '1', pending_proposal_id: '', next_cursor: next, items: limit ? depItems.slice(offset, offset + 3) : [], pending_proposal: null };
      }
      case 'work.dependency.add': case 'work.dependency.remove': {
        chainRev++;
        const doc = JSON.parse(await decryptVaultText(call.payload.body_cipher, session.keyring));
        if (call.method === 'work.dependency.add') depItems.push({ kind: 'dependency', key: doc.dependency_id, accepted_seq: String(depItems.length + 1), record: { ...doc, removed_at: '' } });
        else for (const it of depItems) if (it.key === doc.dependency_id) it.record = { ...it.record, removed_at: '2026-11-10T00:00:00Z' };
        return { chain_id: 'chain_owned', task_id: '', revision: String(chainRev) };
      }
      case 'task.create': {
        chainRev++;
        tasks.push({ task_id: call.command.task_id, title: await decryptVaultText(call.payload.title_cipher, session.keyring), priority: 'p2' });
        taskRevs[call.command.task_id] = 1;
        return { chain_id: 'chain_owned', task_id: call.command.task_id, revision: String(chainRev) };
      }
      case 'requirements.edit': case 'review.post': case 'task.hold': case 'task.edit': case 'task.priority': taskRevs[task]++; return { chain_id: 'chain_owned', task_id: task, revision: String(taskRevs[task]) };
      case 'chain.edit': chainRev++; return { chain_id: 'chain_owned', task_id: '', revision: String(chainRev) };
      case 'task.delete': { chainRev++; const i = tasks.findIndex((t) => t.task_id === task); if (i >= 0) tasks.splice(i, 1); return { chain_id: 'chain_owned', task_id: task, revision: String(chainRev) }; }
      case 'chain.complete': chainRev++; return { chain_id: 'chain_owned', task_id: '', revision: String(chainRev) };
      case 'runtime.read': return task === 'task_1'
        ? { revision: String(taskRevs.task_1), fleet: [], leases: [], config: [], requirements: [['2', JSON.stringify({ goal: 'Users can sign in', acceptance: ['SSO works', 'Errors are shown'] })]],
            state: [['in_review', '2', '']], submission: [['2', 'a'.repeat(40), '2', 'Implemented SSO', 'agt_worker']], controls: [],
            attempts: { attempt_no: '2', last_release: '', work_lease_id: '', completeness: 'full' } }
        : { revision: '1', fleet: [], leases: [], config: [], requirements: [], state: [], submission: [], controls: [['held', 'ready', 'waiting', '']],
            attempts: { attempt_no: '0', last_release: '', work_lease_id: '', completeness: 'full' } };
      case 'task.read': return { chain_id: 'chain_owned', task_id: task, revision: String(taskRevs[task]), title: 'Fix login', body: 'Login fails on Safari', priority: 'p1', items: comments, next_cursor: '' };
      case 'migration.archive.read': return { chain_id: 'chain_owned', migration_id: 'mig_1', next_cursor: '', items: [
        { kind: 'review', doc_index: '0', row: '0', record: JSON.stringify({ task_id: 'task_1', attempt_no: 1, role: 'security', reviewer_kind: 'agent', reviewer_agent_id: 'agt_reviewer', verdict: 'request_changes', findings_json: JSON.stringify([{ note: 'Validate the redirect' }]), created_at: '2025-04-02T09:00:00Z' }) },
      ] };
      case 'history.read': return { chain_id: 'chain_owned', next_cursor: '', items: [
        { seq: '40', task_id: 'task_1', ts_ms: String(Date.parse('2026-11-01T10:00:00Z')), actor_kind: 'device', actor_id: session.identity.deviceId, kind: 'review.post', operation_id: 'op_r', completeness: 'full', evidence_bytes: '10' },
        { seq: '41', task_id: 'task_2', ts_ms: '1', actor_kind: 'device', actor_id: 'x', kind: 'review.post', operation_id: 'op_other', completeness: 'full', evidence_bytes: '10' },
      ] };
      case 'history.fetch': {
        assert.equal(call.payload.seq, '40', 'only the selected task’s review evidence is fetched');
        return { seq: '40', offset: '0', next_offset: '', completeness: 'full',
          evidence: JSON.stringify({ command: '{}', payload: JSON.stringify({ requirements_revision: '2', attempt: '1', head: '', verdict: 'approve', summary: 'Looks right' }), content: '', result: '{}' }) };
      }
      case 'submission.read': return { kind: 'submission', chain_id: 'chain_owned', task_id: task, attempt: call.payload.attempt, summary: 'Summary of attempt ' + call.payload.attempt,
        offset: '0', next_offset: '', head: 'b'.repeat(40), requirements_revision: '2', configuration_revision: '1', author_agent_id: 'agt_worker', output: '', native_attempt: '', attempt_completeness: 'full' };
      case 'task.comment': {
        comments = [...comments, { operation_id: call.command.operation_id, principal_id: session.identity.deviceId, body: await decryptVaultText(call.payload.body_cipher, session.keyring), seq: '2', created_at: '2026-11-07T10:00:00Z' }];
        taskRevs[task]++;
        return { chain_id: 'chain_owned', task_id: task, revision: String(taskRevs[task]) };
      }
      default: return { code: 'invalid_scope' };
    }
  }, calls, revisions);
  const ui = mountDom();
  try {
    // The reviewer picker names the Hub's agents.
    const coordinatorApi = { listAgents: async () => [{ agentId: 'agt_sec', name: 'Security' }, { agentId: 'agt_perf', name: 'Performance' }],
      launch: async () => '', status: async () => 'running', restart: async () => undefined };
    await act(async () => ui.root.render(view({ chain: summary(env), send, session: async () => session, coordinatorApi })));
    await ui.flush();
    assert.equal(ui.$('owner-chain-title')!.textContent, 'Live chain title');
    assert.match(ui.$('owner-chain-bridge-state')!.textContent!, /Home Bridge · online/);
    assert.ok(ui.$('owner-chain-owner-badge'));
    // The page is origin/main's chain board (TaskChainOverview) over the owner reads.
    assert.ok(ui.$('taskchain-overview-container') && ui.$('ticket-board-view'), 'the restored board renders');
    assert.match(ui.$('task-card-task_1')!.textContent!, /Fix login/);
    assert.match(ui.$('task-board-section-held')!.textContent!, /Write docs/);

    await ui.openTicket('task_1');
    assert.equal(ui.$('ticket-board-view'), null, 'the ticket opens in place of the board');
    // origin/main's ticket tab (TicketView) over the owner reads.
    assert.equal(ui.$('ticket-view-title')!.textContent, 'Fix login');
    assert.match(ui.$('ticket-view-description')!.textContent!, /Login fails on Safari/, 'the ticket body shows beside its goal');
    assert.match(ui.$('task-requirements-status')!.textContent!, /Rev 2/, 'the requirements card carries the revision');
    assert.match(ui.$('ticket-view-requirements')!.textContent!, /Requirements.*Rev \d.*Users can sign in.*SSO works.*Errors are shown/s, 'origin/main requirements card');
    assert.match(ui.$('ticket-view-state')!.textContent!, /In review/);
    await ui.click('ticket-activity-tab-comments');
    const imported = ui.$('ticket-comment-cmt_legacy')!;
    assert.match(imported.textContent!, /inst_author.*Imported comment/s);
    assert.equal(imported.querySelector('time')!.getAttribute('datetime'), '2025-04-03T12:00:00Z', 'comments keep their timestamps');
    await ui.click('ticket-activity-tab-reviews');
    const reviews = ui.$('ticket-activity-feed-reviews')!.textContent!;
    assert.match(reviews, /You.*Approved.*attempt 1.*Looks right/s, 'owner review from event history');
    assert.match(reviews, /Reviewer.*\(security\).*Changes requested.*attempt 1.*Archived from Hub.*Validate the redirect/s, 'archived migration review');
    // Changes: each attempt's submission, read when the card opens or an attempt is picked.
    await ui.click('ticket-view-changes-toggle');
    assert.ok(ui.$('ticket-view-changes-attempt-1') && ui.$('ticket-view-changes-attempt-2'), 'attempt history');
    assert.match(ui.$('task-details-output')!.textContent!, /Attempt 2.*Worker.*Summary of attempt 2/s, 'the current attempt first');
    await ui.click('ticket-view-changes-attempt-1');
    assert.match(ui.$('task-details-output')!.textContent!, /Attempt 1.*Summary of attempt 1/s);
    assert.ok(ui.$('ticket-view-approve-btn'), 'an in-review ticket offers a verdict (origin/main decision block)');
    assert.ok(!ui.text().includes('{"'), 'no raw JSON is rendered');

    await ui.click('ticket-activity-tab-comments');
    await ui.type('comment-composer-input', 'Please also cover Firefox');
    await ui.click('ticket-view-comment-send-btn');
    const comment = calls.find((c) => c.method === 'task.comment')!;
    assert.equal(comment.command.task_id, 'task_1');
    assert.equal(comment.command.expected_revision, '3', 'the command is bound to the task revision just read');
    assert.equal(await decryptVaultText(comment.payload.body_cipher, session.keyring), 'Please also cover Firefox');
    assert.match(ui.$('ticket-activity-feed-comments')!.textContent!, /You.*Please also cover Firefox/s);
    assert.equal(ui.$('owner-chain-notice')!.textContent, 'Comment added.');

    // As on origin/main, Approve takes no note; the owner payload gets a fixed summary.
    await ui.click('ticket-view-approve-btn');
    const review = calls.find((c) => c.method === 'review.post')!;
    assert.equal(review.command.expected_revision, '4', 'after the comment the task revision moved on');
    assert.deepEqual({ attempt: review.payload.attempt, head: review.payload.head, rr: review.payload.requirements_revision, verdict: review.payload.verdict, summary: review.payload.summary },
      { attempt: '2', head: 'a'.repeat(40), rr: '2', verdict: 'approve', summary: 'Approved.' });

    // Hold asks for a reason (origin/main HoldReasonDialog) and sends it with task.hold.
    await ui.click('ticket-view-hold-btn');
    await ui.type('task-hold-reason-input', 'Waiting for the design');
    await ui.click('task-hold-confirm-btn');
    const hold = calls.filter((c) => c.method === 'task.hold');
    assert.equal(hold.length, 1);
    assert.equal(await decryptVaultText(hold[0].payload.body_cipher, session.keyring), 'Waiting for the design');
    assert.equal(ui.$('owner-chain-error'), null, 'no change was refused as stale');

    // Creating a ticket (origin/main's New ticket modal) is chain-scoped: bound to the chain revision.
    assert.equal(ui.$('owner-chain-status')!.textContent, 'Active');
    await ui.click('ticket-view-breadcrumb-tickets');
    await ui.click('task-board-new-task-btn');
    await ui.type('create-task-title-input', 'Add audit log');
    await ui.click('create-task-submit-btn');
    const created = calls.find((c) => c.method === 'task.create')!;
    assert.ok(created, 'task.create was sent: ' + (ui.$('create-task-error')?.textContent ?? ''));
    assert.equal(created.command.expected_revision, '7');
    assert.match(created.command.task_id, /^task_/);
    assert.equal(calls.filter((c) => c.method === 'requirements.edit').length, 0, 'no brief given: no requirements are written');
    assert.equal(ui.$('owner-chain-error'), null);
    assert.equal(ui.$('owner-chain-notice')!.textContent, 'Ticket created.');
    assert.match(ui.$(`task-card-${created.command.task_id}`)!.textContent!, /Add audit log/);
    assert.equal(ui.$('create-task-modal'), null, 'the modal closes after success');

    // Coordinator-level management: edit the chain, edit a ticket, change its priority.
    await ui.click('owner-chain-edit');
    assert.equal((ui.$('owner-chain-edit-title') as HTMLInputElement).value, 'Live chain title', 'the editor starts from the live title');
    await ui.type('owner-chain-edit-title', 'Renamed chain');
    await ui.type('owner-chain-edit-description', 'New overview');
    await ui.click('owner-chain-edit-save');
    const chainEdit = calls.find((c) => c.method === 'chain.edit')!;
    assert.ok(chainEdit, 'chain.edit was sent: ' + (ui.$('owner-chain-error')?.textContent ?? ''));
    assert.equal(chainEdit.command.expected_revision, '8', 'chain-scoped: bound to the chain revision');
    assert.equal(await decryptVaultText(chainEdit.payload.title_cipher, session.keyring), 'Renamed chain');
    assert.equal(await decryptVaultText(chainEdit.payload.description_cipher, session.keyring), 'New overview');
    assert.equal(ui.$('owner-chain-edit-form'), null, 'the editor closes after success');
    assert.equal(ui.$('owner-chain-notice')!.textContent, 'Chain updated.');

    await ui.openTicket('task_1');
    await ui.click('ticket-view-more-btn');
    await ui.click('ticket-view-edit-details');
    assert.equal((ui.$('task-edit-description') as HTMLTextAreaElement).value, 'Login fails on Safari');
    await ui.type('task-edit-title', 'Fix login on Safari');
    await ui.click('task-edit-save');
    const taskEdit = calls.find((c) => c.method === 'task.edit')!;
    assert.ok(taskEdit, 'task.edit was sent: ' + (ui.$('owner-chain-error')?.textContent ?? ''));
    assert.equal(taskEdit.command.task_id, 'task_1');
    assert.equal(await decryptVaultText(taskEdit.payload.title_cipher, session.keyring), 'Fix login on Safari');
    assert.equal(ui.$('owner-chain-notice')!.textContent, 'Ticket updated.');
    assert.equal(ui.$('task-edit-modal'), null, 'the dialog closes after a save');

    await ui.click('ticket-view-priority-select');
    const p0 = [...ui.dom.window.document.querySelectorAll('[role="option"]')].find((o) => /P0/.test(o.textContent || '')) as HTMLElement | undefined;
    assert.ok(p0, 'the priority menu lists P0');
    await act(async () => { p0!.click(); });
    await ui.flush();
    const priority = calls.find((c) => c.method === 'task.priority')!;
    assert.ok(priority, 'task.priority was sent: ' + (ui.$('owner-chain-error')?.textContent ?? ''));
    assert.equal(priority.payload.priority, 'p0');
    assert.equal(ui.$('owner-chain-error'), null, 'no management change was refused as stale');

    // Dependencies: task_1 waits for nothing (dep_old was removed) and unblocks task_2.
    await ui.flush();
    assert.ok(ui.$('ticket-view-unblocks-task_2'), 'the linked tickets come from the owner dependencies');
    await ui.click('ticket-view-add-dependency-btn');
    assert.equal((ui.$('task-edit-dep-task_2') as HTMLInputElement).checked, false, 'task_1 waits for nothing yet');
    await ui.click('task-edit-dep-task_2');
    await ui.click('task-edit-save');
    const add = calls.find((c) => c.method === 'work.dependency.add')!;
    assert.ok(add, 'work.dependency.add was sent: ' + (ui.$('owner-chain-error')?.textContent ?? ''));
    const addDoc = JSON.parse(await decryptVaultText(add.payload.body_cipher, session.keyring));
    assert.deepEqual({ dependent: addDoc.dependent, prerequisite: addDoc.prerequisite }, { dependent: { kind: 'task', id: 'task_1' }, prerequisite: { kind: 'task', id: 'task_2' } });
    assert.match(addDoc.dependency_id, /^dep_/);
    await ui.flush();
    assert.ok(ui.$('ticket-view-linked-task_2'), 'the ticket now waits for Write docs');
    await ui.click('ticket-view-add-dependency-btn');
    assert.equal((ui.$('task-edit-dep-task_2') as HTMLInputElement).checked, true);
    await ui.click('task-edit-dep-task_2');
    await ui.click('task-edit-save');
    const remove = calls.find((c) => c.method === 'work.dependency.remove')!;
    assert.ok(remove, 'work.dependency.remove was sent');
    assert.equal(JSON.parse(await decryptVaultText(remove.payload.body_cipher, session.keyring)).dependency_id, addDoc.dependency_id);
    await ui.flush();
    assert.equal(ui.$('ticket-view-linked-task_2'), null, 'the removed dependency is gone after the re-read');

    // Requirements: amend goal and acceptance with a reason (origin/main editor).
    await ui.click('ticket-view-change-requirements-btn');
    assert.equal((ui.$('task-requirements-goal') as HTMLTextAreaElement).value, 'Users can sign in', 'the editor starts from the saved brief');
    assert.equal((ui.$('task-requirements-acceptance-1') as HTMLInputElement).value, 'Errors are shown');
    await ui.click('task-requirements-acceptance-add');
    await ui.type('task-requirements-acceptance-2', 'Safari works');
    await ui.type('task-requirements-reason', 'Safari was missing');
    await ui.click('task-requirements-save');
    const reqEdit = calls.find((c) => c.method === 'requirements.edit')!;
    assert.ok(reqEdit, 'requirements.edit was sent: ' + (ui.$('owner-chain-error')?.textContent ?? ''));
    assert.equal(reqEdit.command.task_id, 'task_1');
    assert.equal(reqEdit.payload.requirements_revision, '3', 'names the next requirements revision');
    assert.deepEqual(JSON.parse(await decryptVaultText(reqEdit.payload.body_cipher, session.keyring)), {
      goal: 'Users can sign in', acceptance: ['SSO works', 'Errors are shown', 'Safari works'], requirements_reason: 'Safari was missing',
    });
    assert.equal(ui.$('owner-chain-notice')!.textContent, 'Requirements updated.');
    assert.equal(ui.$('task-requirements-modal'), null, 'the editor closes after a save');

    // Reviewers and your approval are requirements too (origin/main reviewers dialog).
    await ui.click('ticket-view-more-btn');
    await ui.click('ticket-view-edit-reviewers');
    await ui.click('task-edit-reviewer-agt_sec');
    await ui.click('task-edit-reviewer-agt_perf');
    await ui.click('task-edit-user-approval');
    await ui.click('task-edit-save');
    const reviewersEdit = calls.filter((c) => c.method === 'requirements.edit')[1];
    assert.ok(reviewersEdit, 'the reviewers were saved: ' + (ui.$('task-edit-error')?.textContent ?? ''));
    assert.deepEqual(JSON.parse(await decryptVaultText(reviewersEdit.payload.body_cipher, session.keyring)), {
      goal: 'Users can sign in', acceptance: ['SSO works', 'Errors are shown'], reviewers: ['agt_sec', 'agt_perf'], requires_user_approval: true, requirements_reason: 'Changed the reviewers.',
    });

    // The run Bridge: the owner Bridge by default, any account Bridge as a brief pin.
    assert.match(ui.$('ticket-view-bridge-select')!.textContent!, /Home Bridge \(owner, default\)/);
    await ui.click('ticket-view-bridge-select');
    const riverwood = [...ui.dom.window.document.querySelectorAll('[role="option"]')].find((o) => /riverwood/.test(o.textContent || '')) as HTMLElement | undefined;
    assert.ok(riverwood, 'the Bridge menu lists the account Bridges');
    await act(async () => { riverwood!.click(); });
    await ui.flush();
    const pin = calls.filter((c) => c.method === 'requirements.edit')[2];
    assert.ok(pin, 'the run Bridge was saved: ' + (ui.$('owner-chain-error')?.textContent ?? ''));
    const pinned = JSON.parse(await decryptVaultText(pin.payload.body_cipher, session.keyring));
    assert.equal(pinned.run_bridge_id, 'brg_b');
    assert.deepEqual([pinned.goal, pinned.acceptance], ['Users can sign in', ['SSO works', 'Errors are shown']], 'the pin keeps the rest of the brief');

    await ui.click('owner-chain-complete');
    await ui.type('owner-chain-complete-summary', 'Login shipped');
    await ui.click('owner-chain-complete-save');
    const complete = calls.find((c) => c.method === 'chain.complete')!;
    assert.ok(complete, 'chain.complete was sent: ' + (ui.$('owner-chain-error')?.textContent ?? ''));
    assert.equal(complete.command.expected_revision, '11', 'chain-scoped (after the two dependency changes)');
    assert.deepEqual(JSON.parse(await decryptVaultText(complete.payload.body_cipher, session.keyring)), { expected_work_revision: '1', summary: 'Login shipped' }, 'names the work revision from work.read');
    assert.equal(ui.$('owner-chain-notice')!.textContent, 'Chain completed.');

    // An unstarted ticket can be deleted (after a confirm); a started one cannot.
    await ui.click('ticket-view-more-btn');
    assert.equal(ui.$('ticket-view-menu-delete'), null, 'task_1 has attempts: no Delete');
    await ui.openTicket('task_2');
    (ui.dom.window as any).confirm = () => true;
    await ui.click('ticket-view-more-btn');
    await ui.click('ticket-view-menu-delete');
    const del = calls.find((c) => c.method === 'task.delete')!;
    assert.ok(del, 'task.delete was sent: ' + (ui.$('owner-chain-error')?.textContent ?? ''));
    assert.equal(del.command.task_id, 'task_2');
    assert.equal(del.command.expected_revision, String(taskRevs.task_2), 'bound to the ticket revision');
    assert.ok(ui.$('ticket-board-view'), 'the page returns to the board');
    assert.equal(ui.$('task-card-task_2'), null, 'the deleted ticket leaves the board');
    assert.equal(ui.$('owner-chain-error'), null, 'the deleted ticket is not re-read');

    await ui.click('owner-chain-debug-toggle');
    assert.ok(ui.dom.window.document.querySelector('[aria-label="Owner-local tasks"]'), 'the raw console stays reachable behind Advanced/debug');
  } finally {
    await ui.restore();
    clearKeyringSession();
  }
});

test('an offline owner shows registry metadata and an explicit offline state, with no raw error', async () => {
  const env = await ownerTestSession('brg_away', 'Laptop');
  const calls: OwnerCall[] = [];
  const send = fakeOwner(env.session, () => 'offline', calls);
  const ui = mountDom();
  try {
    // Listed offline: nothing is requested from the owner.
    await act(async () => ui.root.render(view({ chain: summary(env, { online: false }), send, session: async () => env.session })));
    await ui.flush();
    assert.equal(calls.length, 0);
    assert.equal(ui.$('owner-chain-offline')!.textContent, 'Owner Bridge Laptop is offline — details and changes unavailable');
    assert.equal(ui.$('owner-chain-title')!.textContent, 'Registry title');
    assert.match(ui.text(), /Fix login/);
    assert.match(ui.text(), /Write docs/);
    assert.equal(ui.$('owner-chain-error'), null);
    assert.equal(ui.$('task-board-new-task-btn'), null, 'no changes are offered offline');

    // Listed online but unreachable: the relay answer becomes the same state.
    await act(async () => ui.root.render(view({ key: 'b', chain: summary(env, { online: true }), send, session: async () => env.session })));
    await ui.flush();
    assert.ok(calls.length > 0);
    assert.equal(ui.$('owner-chain-offline')!.textContent, 'Owner Bridge Laptop is offline — details and changes unavailable');
    assert.equal(ui.$('owner-chain-error'), null);
    assert.ok(!/owner_unavailable/.test(ui.text()), 'the raw code never shows');
  } finally {
    await ui.restore();
    clearKeyringSession();
  }
});

test('owner refusals are worded, not raw codes', async () => {
  const { ownerErrorMessage } = await import('../src/ui/api/ownerChains.ts');
  assert.equal(ownerErrorMessage(new Error('stale_revision')), 'The chain changed on its owner Bridge. It has been reloaded; try again.');
  assert.equal(ownerErrorMessage(new Error('some_new_code')), 'The owner Bridge refused the request (some new code).');
  assert.equal(ownerErrorMessage(new Error('{"weird":1}')), 'The owner Bridge request failed. Try again.');
  assert.equal(ownerErrorMessage(new Error('owner_unavailable'), 'Desk'), 'Owner Bridge Desk is offline — details and changes unavailable');
});

test('a completed owner chain shows its status and offers no changes', async () => {
  const env = await ownerTestSession();
  const { session } = env;
  const calls: OwnerCall[] = [];
  const send = fakeOwner(session, (call) => {
    switch (call.method) {
      case 'chain.read': return { chain_id: 'chain_owned', task_id: '', revision: '4', title: 'Done chain', description: '', defaults_json: '{}', items: [{ task_id: 'task_1', title: 'Fix login', revision: '2', priority: 'p2' }], next_cursor: '' };
      case 'work.read': return { chain_id: 'chain_owned', publish_state: 'published', status: 'completed', work_revision: '3', pending_proposal_id: '', next_cursor: '', items: [], pending_proposal: null };
      case 'runtime.read': return { revision: '2', fleet: [], leases: [], config: [], requirements: [], state: [['done', '1', '']], submission: [], controls: [], attempts: { attempt_no: '1', last_release: '', work_lease_id: '', completeness: 'full' } };
      case 'task.read': return { chain_id: 'chain_owned', task_id: 'task_1', revision: '2', title: 'Fix login', body: '', priority: 'p2', items: [], next_cursor: '' };
      case 'history.read': return { chain_id: 'chain_owned', next_cursor: '', items: [] };
      case 'migration.archive.read': return { code: 'invalid_scope' };
      default: return { code: 'invalid_scope' };
    }
  }, calls);
  const ui = mountDom();
  try {
    await act(async () => ui.root.render(view({ chain: summary(env, { migrated: false }), send, session: async () => session })));
    await ui.flush();
    assert.equal(ui.$('owner-chain-status')!.textContent, 'Completed');
    assert.match(ui.$('owner-chain-readonly')!.textContent!, /completed; it is read-only/);
    assert.ok(ui.$('ticket-board-view'));
    assert.equal(ui.$('task-board-new-task-btn'), null, 'a completed chain offers no New ticket');
    await ui.openTicket('task_1');
    assert.equal(ui.$('ticket-view-title')!.textContent, 'Fix login');
    for (const id of ['comment-composer-input', 'ticket-view-quick-actions', 'ticket-view-hold-btn', 'ticket-view-reopen-btn', 'ticket-view-release-btn',
      'ticket-view-change-requirements-btn', 'ticket-view-approve-btn', 'answer-send-btn']) assert.equal(ui.$(id), null, id);
    await ui.click('ticket-view-more-btn');
    for (const id of ['ticket-view-edit-details', 'ticket-view-edit-reviewers', 'ticket-view-menu-delete', 'ticket-view-menu-cancel']) assert.equal(ui.$(id), null, id);
    assert.ok(ui.$('ticket-view-menu-copy_id'), 'Copy ID stays');
    assert.ok(calls.every((c) => c.method.endsWith('.read') || c.method === 'history.read'), 'only reads were sent');
  } finally {
    await ui.restore();
    clearKeyringSession();
  }
});

test('owner reviews come from the newest history, past 200 events, with an explicit cap', async () => {
  const env = await ownerTestSession();
  const { readOwnerReviews } = await import('../src/ui/api/ownerChains.ts');
  // 450 events, oldest first; 30 reviews of task_1 spread through them.
  const events = Array.from({ length: 450 }, (_, i) => ({
    seq: String(i + 1), task_id: i % 15 === 0 ? 'task_1' : 'task_x', ts_ms: String(1_700_000_000_000 + i), actor_kind: 'agent', actor_id: 'agt_r' + i,
    kind: i % 15 === 0 ? 'review.post' : 'lease.claim', operation_id: 'op' + i, completeness: 'full', evidence_bytes: '1',
  }));
  const limits: string[] = [];
  const send = fakeOwner(env.session, (call) => {
    if (call.method === 'history.read') {
      limits.push(call.payload.limit);
      const start = call.payload.cursor ? Number(call.payload.cursor.split(':')[1]) : 0;
      const limit = Number(call.payload.limit);
      const items = events.slice(start, start + limit);
      return { chain_id: 'chain_owned', items, next_cursor: start + limit < events.length ? 'scope:' + (start + limit) : '' };
    }
    if (call.method === 'history.fetch') return { seq: call.payload.seq, offset: '0', next_offset: '', completeness: 'full',
      evidence: JSON.stringify({ payload: JSON.stringify({ attempt: call.payload.seq, verdict: 'approve', summary: 'review at ' + call.payload.seq }) }) };
    return { code: 'invalid_scope' };
  });
  try {
    const all = await readOwnerReviews(env.session, env.bridgeId, 'chain_owned', 'task_1', send);
    assert.deepEqual(limits, ['100', '100', '100', '100', '100'], 'paged to the end, 100 events per page');
    assert.equal(all.reviews.length, 20);
    assert.equal(all.reviews[0].summary, 'review at 436', 'the newest review (event 436) is first');
    assert.equal(all.reviews.at(-1)!.summary, 'review at 151', 'older reviews beyond the latest 20 are dropped');
    assert.equal(all.more, true);
    assert.equal(all.truncated, false);
    limits.length = 0;
    const capped = await readOwnerReviews(env.session, env.bridgeId, 'chain_owned', 'task_1', send, 20, 2);
    assert.equal(limits.length, 2);
    assert.equal(capped.truncated, true, 'a scan stopped by the page cap says so');
    assert.equal(capped.reviews[0].summary, 'review at 196');
  } finally { clearKeyringSession(); }
});

// H1: the ticket renders without waiting for the review history scan (which may
// page through the whole chain history); reviews load afterwards with their own
// loading state.
test('the ticket renders before the review history scan finishes, then reviews fill in', async () => {
  const env = await ownerTestSession();
  const { session } = env;
  let releaseHistory!: () => void;
  const historyGate = new Promise<void>((resolve) => { releaseHistory = resolve; });
  let historyReads = 0;
  const send = fakeOwner(session, async (call) => {
    const task = call.command.task_id;
    switch (call.method) {
      case 'chain.read': return { chain_id: 'chain_owned', task_id: '', revision: '1', title: 'Live chain title', description: '', defaults_json: '{}',
        items: [{ task_id: 'task_1', title: 'Fix login', priority: 'p1', revision: '1' }], next_cursor: '' };
      case 'work.read': return { chain_id: 'chain_owned', publish_state: 'published', status: 'active', work_revision: '1', pending_proposal_id: '', next_cursor: '', items: [], pending_proposal: null };
      case 'runtime.read': return { revision: '1', fleet: [], leases: [], config: [], requirements: [], state: [['ready', '1', '']], submission: [], controls: [],
        attempts: { attempt_no: '0', last_release: '', work_lease_id: '', completeness: 'full' } };
      case 'task.read': return { chain_id: 'chain_owned', task_id: task, revision: '1', title: 'Fix login', body: 'Login fails on Safari', priority: 'p1', items: [], next_cursor: '' };
      case 'migration.archive.read': return { chain_id: 'chain_owned', migration_id: '', next_cursor: '', items: [] };
      case 'history.read': {
        historyReads++;
        await historyGate;
        return { chain_id: 'chain_owned', next_cursor: '', items: [
          { seq: '5', task_id: 'task_1', ts_ms: '1', actor_kind: 'agent', actor_id: 'agt_reviewer', kind: 'review.post', operation_id: 'op_r', completeness: 'full', evidence_bytes: '10' },
        ] };
      }
      case 'history.fetch': return { seq: '5', offset: '0', next_offset: '', completeness: 'full',
        evidence: JSON.stringify({ payload: JSON.stringify({ attempt: '1', verdict: 'approve', summary: 'Late review' }) }) };
      default: return { code: 'invalid_scope' };
    }
  });
  const ui = mountDom();
  try {
    await act(async () => ui.root.render(view({ chain: summary(env), send, session: async () => session })));
    await ui.flush();
    await ui.openTicket('task_1');
    assert.ok(historyReads > 0, 'the review scan started');
    assert.equal(ui.$('ticket-view-title')!.textContent, 'Fix login', 'the ticket is rendered while reviews are still loading');
    assert.match(ui.$('ticket-view-description')!.textContent!, /Login fails on Safari/);
    await ui.click('ticket-activity-tab-reviews');
    assert.match(ui.$('ticket-activity-feed-reviews')!.textContent!, /Loading reviews…/, 'reviews show a loading state');
    assert.ok(!/No reviews yet/.test(ui.$('ticket-activity-feed-reviews')!.textContent!), 'no empty state while loading');
    releaseHistory();
    await ui.flush();
    assert.ok(!/Loading reviews/.test(ui.$('ticket-activity-feed-reviews')!.textContent!));
    assert.match(ui.$('ticket-activity-feed-reviews')!.textContent!, /Reviewer.*Approved.*Late review/s);
    assert.equal(ui.$('owner-chain-error'), null);
  } finally {
    releaseHistory();
    await ui.restore();
    clearKeyringSession();
  }
});

// A review scan that fails (here the owner Bridge goes offline mid-scan) never
// leaves "Loading reviews…" behind: when the owner is back, the ticket shows a
// worded reviews error instead of a stuck loading state.
test('a failed review scan clears the reviews loading state', async () => {
  const env = await ownerTestSession('brg_flaky', 'Desk');
  const { session } = env;
  let historyOffline = true;
  const send = fakeOwner(session, async (call) => {
    const task = call.command.task_id;
    switch (call.method) {
      case 'chain.read': return { chain_id: 'chain_owned', task_id: '', revision: '1', title: 'Live chain title', description: '', defaults_json: '{}',
        items: [{ task_id: 'task_1', title: 'Fix login', priority: 'p1', revision: '1' }], next_cursor: '' };
      case 'work.read': return { chain_id: 'chain_owned', publish_state: 'published', status: 'active', work_revision: '1', pending_proposal_id: '', next_cursor: '', items: [], pending_proposal: null };
      case 'runtime.read': return { revision: '1', fleet: [], leases: [], config: [], requirements: [], state: [['ready', '1', '']], submission: [], controls: [],
        attempts: { attempt_no: '0', last_release: '', work_lease_id: '', completeness: 'full' } };
      case 'task.read': return { chain_id: 'chain_owned', task_id: task, revision: '1', title: 'Fix login', body: 'Login fails on Safari', priority: 'p1', items: [], next_cursor: '' };
      case 'migration.archive.read': return { chain_id: 'chain_owned', migration_id: '', next_cursor: '', items: [] };
      case 'history.read': return historyOffline ? 'offline' : { chain_id: 'chain_owned', next_cursor: '', items: [] };
      default: return { code: 'invalid_scope' };
    }
  });
  const ui = mountDom();
  const render = (online: boolean) => act(async () => ui.root.render(view({ chain: summary(env, { online }), send, session: async () => session })));
  try {
    await render(true);
    await ui.flush();
    await ui.openTicket('task_1');
    assert.ok(ui.$('owner-chain-offline'), 'the scan failure switches the view offline');
    historyOffline = false;
    await render(false);
    await ui.flush();
    await render(true);
    await ui.flush();
    assert.equal(ui.$('owner-chain-offline'), null, 'the owner is back');
    assert.equal(ui.$('ticket-view-title')!.textContent, 'Fix login');
    await ui.click('ticket-activity-tab-reviews');
    assert.ok(!/Loading reviews/.test(ui.$('ticket-activity-feed-reviews')!.textContent!), 'no stuck "Loading reviews…"');
    assert.match(ui.$('ticket-activity-feed-reviews')!.textContent!, /Owner Bridge Desk is offline/);
    assert.ok(!/owner_unavailable/.test(ui.text()), 'the raw code never shows');
  } finally {
    await ui.restore();
    clearKeyringSession();
  }
});

// R2-1/R3-1: a ticket whose brief requires the user's approval says so and
// offers the device-signed verdict; an agent's relay "on behalf of the user"
// does not clear the notice, the user's own device approval does.
test('a ticket waiting on the user shows a notice until a device-signed approval exists', async () => {
  const env = await ownerTestSession();
  const { session } = env;
  let deviceApproved = false;
  const calls: OwnerCall[] = [];
  const send = fakeOwner(session, async (call) => {
    calls.push(call);
    const task = call.command.task_id;
    switch (call.method) {
      case 'chain.read': return { chain_id: 'chain_owned', task_id: '', revision: '1', title: 'Live chain title', description: '', defaults_json: '{}',
        items: [{ task_id: 'task_1', title: 'Fix login', priority: 'p1', revision: '3' }], next_cursor: '' };
      case 'work.read': return { chain_id: 'chain_owned', publish_state: 'published', status: 'active', work_revision: '1', pending_proposal_id: '', next_cursor: '', items: [], pending_proposal: null };
      case 'runtime.read': return { revision: '3', fleet: [], leases: [], config: [],
        requirements: [['1', JSON.stringify({ goal: 'Fix it', acceptance: ['Works'], requires_user_approval: true })]],
        state: [[deviceApproved ? 'done' : 'in_review', '1', '']], submission: [['1', '', '1', 'Fixed', 'agt_worker']], controls: [],
        attempts: { attempt_no: '1', last_release: '', work_lease_id: '', completeness: 'full' } };
      case 'task.read': return { chain_id: 'chain_owned', task_id: task, revision: '3', title: 'Fix login', body: '', priority: 'p1', items: [], next_cursor: '' };
      case 'migration.archive.read': return { chain_id: 'chain_owned', migration_id: '', next_cursor: '', items: [] };
      case 'history.read': return { chain_id: 'chain_owned', next_cursor: '', items: [
        { seq: '7', task_id: 'task_1', ts_ms: '1', actor_kind: 'agent', actor_id: 'inst_coordinator', kind: 'review.post', operation_id: 'op_relay', completeness: 'full', evidence_bytes: '10' },
      ] };
      case 'history.fetch': return { seq: '7', offset: '0', next_offset: '', completeness: 'full',
        evidence: JSON.stringify({ payload: JSON.stringify({ attempt: '1', verdict: 'approve', summary: 'User said LGTM in chat' }) }) };
      case 'review.post': deviceApproved = true; return { chain_id: 'chain_owned', task_id: task, revision: '4' };
      default: return { code: 'invalid_scope' };
    }
  });
  const ui = mountDom();
  try {
    await act(async () => ui.root.render(view({ chain: summary(env), send, session: async () => session })));
    await ui.flush();
    assert.ok(ui.$('task-card-ask-task_1'), 'the board card flags the ticket');
    await ui.openTicket('task_1');
    await ui.click('ticket-activity-tab-reviews');
    assert.match(ui.$('ticket-activity-feed-reviews')!.textContent!, /An agent.*Approved.*User said LGTM/s, 'the agent relay is listed');
    assert.match(ui.$('your-review-block')?.textContent ?? '', /Your review/, 'an agent relay does not clear the ask');
    assert.ok(ui.$('ticket-view-approve-btn') && ui.$('ticket-view-request-changes-btn'), 'the device-signed verdict is offered');
    await ui.click('ticket-view-approve-btn');
    const review = calls.find((c) => c.method === 'review.post');
    assert.ok(review, 'review.post was sent: ' + (ui.$('owner-chain-error')?.textContent ?? ''));
    assert.equal(review!.payload.verdict, 'approve');
    assert.equal(review!.command.principal_id, session.identity.deviceId, 'the verdict is signed by this device');
    assert.equal(ui.$('your-review-block'), null, 'the ask clears once the gate settles');
    await ui.click('ticket-view-breadcrumb-tickets');
    assert.equal(ui.$('task-card-ask-task_1'), null, 'the board no longer asks');
  } finally {
    await ui.restore();
    clearKeyringSession();
  }
});

test('start coordinator on an imported chain launches on the owner Bridge, waits until running, then binds role=coordinator', async () => {
  const env = await ownerTestSession();
  const { session } = env;
  const calls: OwnerCall[] = [];
  let chainRev = 3;
  const revisions = { chain: () => String(chainRev), task: () => '1' };
  const send = fakeOwner(session, async (call) => {
    switch (call.method) {
      case 'chain.read': return { chain_id: 'chain_owned', task_id: '', revision: String(chainRev), title: 'Imported chain', description: '', defaults_json: '{}', items: [], next_cursor: '' };
      case 'work.read': return { chain_id: 'chain_owned', publish_state: 'published', status: 'active', work_revision: '1', pending_proposal_id: '', next_cursor: '', items: [], pending_proposal: null };
      case 'chain.member.set': chainRev++; return { chain_id: 'chain_owned', revision: String(chainRev) };
      case 'chain.metadata.read': return { chain_id: 'chain_owned', items: [], next_cursor: '' };
      default: return { code: 'invalid_scope' };
    }
  }, calls, revisions);
  const hub: string[] = [];
  let statusReads = 0;
  const coordinatorApi = {
    listAgents: async () => [{ agentId: 'agt_coord', name: 'Coordinator agent' }],
    launch: async (input: { agentId: string; chainId: string; bridgeId: string }) => { hub.push(`launch:${input.agentId}:${input.chainId}:${input.bridgeId}`); return 'inst_coord'; },
    status: async (id: string) => { hub.push('status:' + id); statusReads += 1; return 'running'; },
    restart: async (id: string) => { hub.push('restart:' + id); },
  };
  const ui = mountDom();
  try {
    await act(async () => ui.root.render(view({ chain: summary(env, { tasks: [] }), send, session: async () => session, coordinatorApi })));
    await ui.flush();
    assert.match(ui.$('owner-chain-coordinator')!.textContent!, /No coordinator/);
    await ui.click('owner-chain-start-coordinator');
    // The @ui Select mirrors its value to a hidden input named after the field.
    assert.equal((ui.$('owner-chain-coordinator')!.querySelector('input[name="coordinator_agent"]') as HTMLInputElement).value, 'agt_coord');
    await ui.click('owner-chain-coordinator-launch');
    assert.deepEqual(hub, [`launch:agt_coord:chain_owned:${env.bridgeId}`, 'status:inst_coord', 'restart:inst_coord', 'status:inst_coord'], 'launched on the owner Bridge, bound, then relaunched as coordinator');
    assert.equal(statusReads, 2);
    const bind = calls.find((c) => c.method === 'chain.member.set');
    assert.equal(calls.filter((c) => c.method === 'chain.member.set').length, 1, 'no previous coordinator to demote');
    assert.ok(bind, 'chain.member.set was sent: ' + (ui.$('owner-chain-coordinator-error')?.textContent ?? ''));
    assert.deepEqual({ instance: bind!.payload.instance_id, agent: bind!.payload.agent_id, role: bind!.payload.role, enabled: bind!.payload.enabled },
      { instance: 'inst_coord', agent: 'agt_coord', role: 'coordinator', enabled: '1' });
    assert.equal(bind!.command.expected_revision, '3', 'bound against the chain revision read right before');
    assert.equal(ui.$('owner-chain-coordinator-id')!.textContent, 'Coordinator: inst_coord');
    assert.ok(ui.$('owner-chain-start-coordinator')!.textContent!.includes('Replace coordinator'));
  } finally {
    await ui.restore();
    clearKeyringSession();
  }
});

test('replacing a coordinator binds the new instance and then disables the previous one', async () => {
  const env = await ownerTestSession();
  const { session } = env;
  const calls: OwnerCall[] = [];
  let chainRev = 3;
  const revisions = { chain: () => String(chainRev), task: () => '1' };
  const send = fakeOwner(session, async (call) => {
    switch (call.method) {
      case 'chain.read': return { chain_id: 'chain_owned', task_id: '', revision: String(chainRev), title: 'Imported chain', description: '', defaults_json: '{}', items: [], next_cursor: '' };
      case 'work.read': return { chain_id: 'chain_owned', publish_state: 'published', status: 'active', work_revision: '1', pending_proposal_id: '', next_cursor: '', items: [], pending_proposal: null };
      case 'chain.member.set': chainRev++; return { chain_id: 'chain_owned', revision: String(chainRev) };
      case 'chain.metadata.read': return { chain_id: 'chain_owned', next_cursor: '', items: [
        { kind: 'member', entity_id: 'inst_old', accepted_seq: '9', current: '1', enabled: '1', body: JSON.stringify({ instance_id: 'inst_old', agent_id: 'agt_old', role: 'coordinator' }) },
      ] };
      default: return { code: 'invalid_scope' };
    }
  }, calls, revisions);
  const hub: string[] = [];
  let statusReads = 0;
  const coordinatorApi = {
    listAgents: async () => [{ agentId: 'agt_coord', name: 'Coordinator agent' }],
    launch: async (input: { agentId: string; chainId: string; bridgeId: string }) => { hub.push(`launch:${input.agentId}:${input.chainId}:${input.bridgeId}`); return 'inst_coord'; },
    status: async (id: string) => { hub.push('status:' + id); statusReads += 1; return 'running'; },
    restart: async (id: string) => { hub.push('restart:' + id); },
  };
  const ui = mountDom();
  try {
    await act(async () => ui.root.render(view({ chain: summary(env, { tasks: [] }), send, session: async () => session, coordinatorApi })));
    await ui.flush();
    await ui.click('owner-chain-start-coordinator');
    await ui.click('owner-chain-coordinator-launch');
    const sets = calls.filter((c) => c.method === 'chain.member.set');
    assert.equal(sets.length, 2, 'bind new, then demote old: ' + (ui.$('owner-chain-coordinator-error')?.textContent ?? ''));
    assert.deepEqual({ instance: sets[0].payload.instance_id, role: sets[0].payload.role, enabled: sets[0].payload.enabled }, { instance: 'inst_coord', role: 'coordinator', enabled: '1' });
    assert.deepEqual({ instance: sets[1].payload.instance_id, agent: sets[1].payload.agent_id, role: sets[1].payload.role, enabled: sets[1].payload.enabled },
      { instance: 'inst_old', agent: 'agt_old', role: 'coordinator', enabled: '0' });
    assert.equal(sets[1].command.expected_revision, '4', 'demoted against the revision after the new bind');
    assert.equal(statusReads, 2);
  } finally {
    await ui.restore();
    clearKeyringSession();
  }
});
