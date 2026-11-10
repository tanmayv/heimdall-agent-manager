// Owner-local reads map to the ticket wire shape the origin/main ticket
// components render (ownerTaskAdapter): state, brief, reviewers, holds,
// merge, lease holder, reviews of the current attempt and comments.
//
// RUN: node --import ./tests/helpers/vaultEndpointHarness.ts --test tests/ui_owner_task_adapter_test.ts

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { parseOwnerRuntime, type OwnerReview } from '../src/ui/api/ownerChains.ts';
import { ownerRequirementsDoc, ownerTaskWire, ownerTaskWires } from '../src/ui/components/tasks/ownerTaskAdapter.ts';
import { taskHold } from '../src/ui/components/tasks/taskV2Types.ts';
import { leaseClock } from '../src/ui/components/tasks/ticketModel.ts';

const brief = JSON.stringify({ goal: 'Ship it', acceptance: ['a', 'b'], reviewers: ['agt_rev'], requires_user_approval: true, depends_on: ['task_dep'] });
const runtime = (over: Record<string, unknown> = {}) => parseOwnerRuntime({
  revision: '7', state: [['in_review', '2']], requirements: [['3', brief]],
  submission: [['2', 'abc123', '3', 'did it', 'agt_w']], leases: [], attempts: { attempt_no: 2 }, ...over,
});

test('maps an in-review ticket with brief, reviewers, submission and reviews', () => {
  const reviews: OwnerReview[] = [
    { source: 'owner', attempt: '2', verdict: 'approve', reviewer: 'inst_rev', role: '', summary: '', at: '2026-11-10T00:00:00Z', byDevice: false },
    { source: 'owner', attempt: '1', verdict: 'request_changes', reviewer: 'inst_old', role: '', summary: '', at: '', byDevice: false },
    { source: 'owner', attempt: '2', verdict: 'approve', reviewer: 'dev_1', role: '', summary: '', at: '', byDevice: true },
  ];
  const w = ownerTaskWire({
    chainId: 'chain_1', bridgeId: 'brg_1', taskId: 'task_1',
    row: { task_id: 'task_1', title: 'Row title', revision: '7', priority: 'p1' },
    detail: { title: 'Detail title', body: 'Body', priority: 'p0', revision: '7', comments: [
      { operation_id: 'op1', principal_id: 'inst_w', body: 'hello', seq: '1', created_at: '2026-11-10T01:00:00Z' },
    ], truncated: false },
    runtime: runtime(), reviews,
  });
  assert.equal(w.title, 'Detail title');
  assert.equal(w.description, 'Body');
  assert.equal(w.priority, 'p0');
  assert.equal(w.state, 'in_review');
  assert.equal(w.attempt_no, 2);
  assert.equal(w.brief?.goal, 'Ship it');
  assert.deepEqual(w.brief?.acceptance, ['a', 'b']);
  assert.deepEqual(w.brief?.reviewers, ['agt_rev']);
  assert.deepEqual(w.depends_on, ['task_dep']);
  assert.equal(w.requires_user_approval, true);
  assert.equal(w.requirements?.revision, 3);
  assert.equal(w.requirements?.submitted_head, 'abc123');
  assert.equal(w.reviews?.length, 2, 'only the current attempt');
  assert.equal(w.reviews?.[1].reviewer, 'user');
  assert.equal(w.reviews?.[0].reviewer_instance_id, 'inst_rev');
  assert.equal(w.comment_summary?.count, 1);
  assert.equal(w.comment_summary?.last_comment_author_agent_instance_id, 'inst_w');
  assert.deepEqual(w.leases, []);
});

test('lease holder, hold, merge and done states', () => {
  const working = ownerTaskWire({ chainId: 'c', bridgeId: 'b', taskId: 't', runtime: runtime({ state: [['ready', '1']], leases: [['lease_1', 'inst_w']] }) });
  assert.equal(working.state, 'in_progress');
  assert.equal(working.leases?.[0].holder_instance_id, 'inst_w');
  assert.equal(working.leases?.[0].expires_at, '', 'no stated expiry without lease timing');

  const timed = ownerTaskWire({ chainId: 'c', bridgeId: 'b', taskId: 't', runtime: runtime({ state: [['ready', '1']], leases: [['lease_9', 'inst_w', '1794200000000', '1794203600000', '1']] }) });
  assert.equal(timed.leases?.[0].lease_id, 'lease_9');
  assert.equal(timed.leases?.[0].expires_at, new Date(1794200000000).toISOString());
  assert.equal(timed.leases?.[0].hard_deadline_at, new Date(1794203600000).toISOString());
  const clock = leaseClock(timed, 1794200000000 - 5 * 60_000);
  assert.equal(clock?.leftMs, 5 * 60_000, 'the board countdown uses the owner expiry');
  assert.equal(clock?.hardLeftMs, 65 * 60_000);

  const held = ownerTaskWire({ chainId: 'c', bridgeId: 'b', taskId: 't', runtime: runtime({ state: [['ready', '1']], controls: [['held', '', 'paused by user', '']] }) });
  assert.equal(taskHold(held)?.reason, 'paused by user');

  const merging = ownerTaskWire({ chainId: 'c', bridgeId: 'b', taskId: 't', runtime: runtime({ state: [['merge_blocked', '2']] }) });
  assert.equal(merging.state, 'in_review');
  assert.equal(merging.merge?.state, 'conflict');

  const done = ownerTaskWire({ chainId: 'c', bridgeId: 'b', taskId: 't', runtime: runtime({ state: [['done', '2']] }) });
  assert.equal(done.state, 'done');
  assert.deepEqual(done.merge, { state: 'merged', head: 'abc123' });

  const cancelled = ownerTaskWire({ chainId: 'c', bridgeId: 'b', taskId: 't', runtime: runtime({ controls: [['cancelled', '', '', '']] }) });
  assert.equal(cancelled.state, 'cancelled');
});

test('rows without a runtime render as ready with listing data', () => {
  const [w] = ownerTaskWires('c', 'b', [{ task_id: 't1', title: 'One', revision: '1', priority: 'p3' }], {});
  assert.equal(w.title, 'One');
  assert.equal(w.priority, 'p3');
  assert.equal(w.state, 'ready');
  assert.equal(w.brief, null);
  assert.equal(w.requires_user_approval, false);
});

test('ownerRequirementsDoc replaces the edited brief fields and keeps the rest verbatim', () => {
  const raw = JSON.stringify({ goal: 'Old', acceptance: ['a'], assignee: 'agt_w', depends_on: ['task_0'], reviewers: ['agt_old'], requires_user_approval: true, requirements_reason: 'previous note' });
  const next = JSON.parse(ownerRequirementsDoc(raw, { goal: ' New goal ', acceptance: ['one', ' ', 'two '], reviewers: ['agt_a', 'agt_b', 'agt_a', ''], requiresUserApproval: false, reason: ' tightened ' }));
  assert.deepEqual(next, { goal: 'New goal', acceptance: ['one', 'two'], assignee: 'agt_w', depends_on: ['task_0'], reviewers: ['agt_a', 'agt_b'], requirements_reason: 'tightened' });
  const bare = JSON.parse(ownerRequirementsDoc('', { goal: 'G', acceptance: [], reviewers: [], requiresUserApproval: true, reason: '' }));
  assert.deepEqual(bare, { goal: 'G', acceptance: [], requires_user_approval: true }, 'no reviewers key, no stale reason, the gate flag only when set');
});

test('the ticket tab feeds: events, handoffs, reviews and comments in the TicketActivity shapes', async () => {
  const { ownerTicketEvents, ownerTicketEventText, ownerActorKind, ownerHandoffItems, ownerReviewItems, ownerCommentItems } = await import('../src/ui/components/tasks/ownerTaskAdapter.ts');
  assert.equal(ownerActorKind('device'), 'user', 'a device is the user');
  assert.equal(ownerActorKind('agent'), 'agent');
  assert.equal(ownerActorKind(''), 'agent');
  assert.equal(ownerTicketEventText('task.comment'), 'commented');
  assert.equal(ownerTicketEventText('some.new.kind'), 'some.new.kind', 'an unknown kind shows as itself');

  const events = ownerTicketEvents([
    { seq: '9', kind: 'lease.submit', taskId: 'task_1', actorKind: 'agent', actorId: 'inst_w', at: '2026-11-10T01:00:00.000Z' },
    { seq: '3', kind: 'task.hold', taskId: 'task_1', actorKind: 'device', actorId: 'dev_1', at: '' },
  ]);
  assert.deepEqual(events.map((e) => [e.id, e.actorKind, e.text, e.tsMs]), [
    ['9', 'agent', 'submitted for review', Date.parse('2026-11-10T01:00:00.000Z')],
    ['3', 'user', 'held the ticket', 0],
  ]);
  assert.equal((events[0].raw as any).kind, 'lease.submit', 'Raw events keep the record as read');

  const handoffs = ownerHandoffItems([
    { seq: '11', kind: 'lease.submit', summary: 'Done', nextSteps: '', waitingOn: '', head: 'c'.repeat(40), requirementsRevision: '2', actorId: 'inst_w', at: '2026-11-10T02:00:00Z' },
    { seq: '8', kind: 'lease.block', summary: 'Need id', nextSteps: 'Ask', waitingOn: 'human', head: '', requirementsRevision: '2', actorId: 'inst_w', at: '' },
  ]);
  assert.deepEqual(handoffs.map((h) => [h.id, h.label, h.tone, h.waitingOn, h.nextSteps]), [['11', 'Submitted', 'success', '', ''], ['8', 'Blocked', 'warning', 'human', 'Ask']]);

  const reviews = ownerReviewItems([
    { source: 'owner', attempt: '2', verdict: 'approve', reviewer: 'dev_1', role: '', summary: 'LGTM', at: '2026-11-10T00:00:00Z', byDevice: true },
    { source: 'archived', attempt: '1', verdict: 'request_changes', reviewer: 'agt_rev', role: 'security', summary: 'Fix', at: '', byDevice: false },
  ]);
  assert.deepEqual(reviews.map((r) => [r.id, r.actorKind, r.actorId, r.archived, r.role]), [['owner-0', 'user', 'user', false, ''], ['archived-1', 'agent', 'agt_rev', true, 'security']]);

  const comments = ownerCommentItems([
    { operation_id: 'op1', principal_id: 'inst_w', body: 'first', seq: '1', created_at: '2026-11-10T00:00:00Z' },
    { operation_id: '', principal_id: 'dev_1', body: 'second', seq: '2', created_at: '2026-11-10T01:00:00Z' },
  ], (p) => (p === 'dev_1' ? 'You' : p));
  assert.deepEqual(comments, [
    { id: 'dev_1:2', author: 'You', body: 'second', at: '2026-11-10T01:00:00Z' },
    { id: 'op1', author: 'inst_w', body: 'first', at: '2026-11-10T00:00:00Z' },
  ], 'newest first, each with its author label');
});

test('owner dependencies: what a ticket waits for, and the edits that make it wait for a new set', async () => {
  const { ownerPrerequisites, ownerDependencyChanges } = await import('../src/ui/components/tasks/ownerTaskAdapter.ts');
  const deps = [
    { dependencyId: 'dep_a', dependent: 'task_1', prerequisite: 'task_2' },
    { dependencyId: 'dep_b', dependent: 'task_1', prerequisite: 'task_3' },
    { dependencyId: 'dep_c', dependent: 'task_4', prerequisite: 'task_1' },
  ];
  assert.deepEqual(ownerPrerequisites('task_1', deps), ['task_2', 'task_3']);
  assert.deepEqual(ownerPrerequisites('task_4', deps), ['task_1']);
  assert.deepEqual(ownerDependencyChanges('task_1', deps, ['task_3', 'task_5']), { add: ['task_5'], remove: ['dep_a'] });
  assert.deepEqual(ownerDependencyChanges('task_1', deps, ['task_2', 'task_3']), { add: [], remove: [] }, 'no change sends nothing');
  assert.deepEqual(ownerDependencyChanges('task_1', deps, ['task_1', '']), { add: [], remove: ['dep_a', 'dep_b'] }, 'a ticket never waits for itself');
});

test('readOwnerTaskActivity keeps only that ticket\'s events, newest first, without bookkeeping', async () => {
  const { fakeOwner, ownerTestSession } = await import('./helpers/ownerFakeRelay.ts');
  const { readOwnerTaskActivity } = await import('../src/ui/api/ownerChains.ts');
  const { clearKeyringSession } = await import('../src/ui/utils/vaultKeyringSession.ts');
  const env = await ownerTestSession();
  const items = [
    { seq: '1', task_id: 'task_1', kind: 'task.create', actor_kind: 'device', actor_id: 'd', ts_ms: '1' },
    { seq: '2', task_id: 'task_2', kind: 'task.comment', actor_kind: 'agent', actor_id: 'i', ts_ms: '2' },
    { seq: '3', task_id: 'task_1', kind: 'source.delivery', actor_kind: 'agent', actor_id: 'i', ts_ms: '3' },
    { seq: '4', task_id: 'task_1', kind: 'task.comment', actor_kind: 'agent', actor_id: 'i', ts_ms: '4' },
  ];
  const send = fakeOwner(env.session, (call) => (call.method === 'history.read' ? { chain_id: 'chain_1', next_cursor: '', items } : { code: 'invalid_scope' }));
  try {
    const r = await readOwnerTaskActivity(env.session, env.bridgeId, 'chain_1', 'task_1', send);
    assert.deepEqual(r.events.map((e) => e.seq), ['4', '1']);
    assert.equal(r.truncated, false);
  } finally { clearKeyringSession(); }
});
