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
