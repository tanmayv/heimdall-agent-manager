import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const read = (path: string) => readFileSync(new URL(`../${path}`, import.meta.url), 'utf8');

test('task UI uses explicit authenticated-user approval controls', () => {
  const create = read('src/ui/components/tasks/CreateTaskModal.tsx');
  const overview = read('src/ui/components/taskchain/TaskChainOverview.tsx');
  const api = read('src/ui/api/endpoints/tasks.ts');

  assert.match(create, /create-task-require-user-approval-checkbox/);
  assert.match(overview, /taskchain-new-task-require-user-approval-checkbox/);
  assert.match(overview, /taskchain-edit-reviewers-require-user-approval-checkbox/);
  const reviewerModal = overview.indexOf('{editingReviewersTask &&');
  const reviewerToggle = overview.indexOf('taskchain-edit-reviewers-require-user-approval-checkbox');
  assert.ok(reviewerModal >= 0 && reviewerToggle > reviewerModal, 'edit toggle must live in the reviewer modal');
  assert.match(overview, /requiresUserApproval: editRequiresUserApproval/);
  assert.match(overview, /taskchain-task-user-reviewer-/);
  assert.match(overview, /taskchain-edit-user-reviewer-chip/);
  assert.doesNotMatch(create, /create-task-reviewer-userid-input/);
  assert.doesNotMatch(overview, /taskchain-add-reviewer-userid-input/);
  assert.match(api, /body\.requires_user_approval = requiresUserApproval/);
});
