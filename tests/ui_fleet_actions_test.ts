// REQ-FLEET-UI-ACTIONS-1: executable unit tests for role-assigned fleet task action buttons.
//
// RUN: node --test tests/ui_fleet_actions_test.ts

import { test } from 'node:test';
import assert from 'node:assert/strict';

import {
  isRoleAssignedWithoutLiveInstance,
  canStartTask,
  hasLiveNudgeTarget,
  getUnpauseStatus,
} from '../src/ui/components/tasks/TaskCard.ts';

// -----------------------------------------------------------------------------
// isRoleAssignedWithoutLiveInstance
// -----------------------------------------------------------------------------

test('isRoleAssignedWithoutLiveInstance returns true for role-assigned task without bound instance', () => {
  const task = {
    taskId: 'task_001',
    status: 'assigned',
    assigneeRef: { type: 'agent_id', agent_id: 'agt_worker' },
  };
  assert.equal(isRoleAssignedWithoutLiveInstance(task), true);
});

test('isRoleAssignedWithoutLiveInstance returns false for role-assigned task with live bound instance', () => {
  const task = {
    taskId: 'task_002',
    status: 'in_progress',
    assigneeRef: { type: 'agent_instance', agent_id: 'agt_worker', agent_instance_id: 'inst_live_1' },
    assigneeAgentInstanceId: 'inst_live_1',
  };
  const instances = [
    { agent_instance_id: 'inst_live_1', runtime_status: 'running' },
  ];
  assert.equal(isRoleAssignedWithoutLiveInstance(task, instances), false);
});

test('isRoleAssignedWithoutLiveInstance returns true for role-assigned task with stopped/failed bound instance', () => {
  const task = {
    taskId: 'task_003',
    status: 'assigned',
    assigneeRef: { type: 'agent_instance', agent_id: 'agt_worker', agent_instance_id: 'inst_dead_1' },
  };
  const instances = [
    { agent_instance_id: 'inst_dead_1', runtime_status: 'stopped' },
  ];
  assert.equal(isRoleAssignedWithoutLiveInstance(task, instances), true);
});

test('isRoleAssignedWithoutLiveInstance returns false for direct instance-assigned task without agent_id', () => {
  const task = {
    taskId: 'task_004',
    status: 'assigned',
    assigneeRef: { type: 'agent_instance', agent_instance_id: 'inst_manual_1' },
  };
  assert.equal(isRoleAssignedWithoutLiveInstance(task), false);
});

test('isRoleAssignedWithoutLiveInstance returns false for unassigned task', () => {
  const task = {
    taskId: 'task_005',
    status: 'assigned',
    assigneeRef: null,
  };
  assert.equal(isRoleAssignedWithoutLiveInstance(task), false);
});

// -----------------------------------------------------------------------------
// canStartTask (Start button visibility)
// -----------------------------------------------------------------------------

test('canStartTask returns false (hides Start button) for role-assigned task without live instance', () => {
  const task = {
    taskId: 'task_101',
    status: 'queued',
    assigneeRef: { type: 'agent_id', agent_id: 'agt_worker' },
  };
  assert.equal(canStartTask(task), false);
});

test('canStartTask returns true (shows Start button) for task with live bound instance', () => {
  const task = {
    taskId: 'task_102',
    status: 'assigned',
    assigneeRef: { type: 'agent_instance', agent_id: 'agt_worker', agent_instance_id: 'inst_live_2' },
  };
  const instances = [
    { agent_instance_id: 'inst_live_2', runtime_status: 'running' },
  ];
  assert.equal(canStartTask(task, instances), true);
});

// -----------------------------------------------------------------------------
// hasLiveNudgeTarget (Nudge button visibility)
// -----------------------------------------------------------------------------

test('hasLiveNudgeTarget returns false for queued task', () => {
  const task = {
    taskId: 'task_201',
    status: 'queued',
    assigneeRef: { type: 'agent_id', agent_id: 'agt_worker' },
  };
  assert.equal(hasLiveNudgeTarget(task), false);
});

test('hasLiveNudgeTarget returns false for completed or cancelled task', () => {
  const completedTask = { taskId: 'task_202', status: 'completed', assigneeRef: { agent_instance_id: 'inst_1' } };
  const cancelledTask = { taskId: 'task_203', status: 'cancelled', assigneeRef: { agent_instance_id: 'inst_1' } };
  assert.equal(hasLiveNudgeTarget(completedTask), false);
  assert.equal(hasLiveNudgeTarget(cancelledTask), false);
});

test('hasLiveNudgeTarget returns false for in_progress task without bound instance', () => {
  const task = {
    taskId: 'task_204',
    status: 'in_progress',
    assigneeRef: { type: 'agent_id', agent_id: 'agt_worker' },
  };
  assert.equal(hasLiveNudgeTarget(task), false);
});

test('hasLiveNudgeTarget returns true for in_progress task with live bound instance', () => {
  const task = {
    taskId: 'task_205',
    status: 'in_progress',
    assigneeRef: { type: 'agent_instance', agent_instance_id: 'inst_live_3' },
  };
  const instances = [
    { agent_instance_id: 'inst_live_3', runtime_status: 'ready' },
  ];
  assert.equal(hasLiveNudgeTarget(task, instances), true);
});

test('hasLiveNudgeTarget returns false for in_progress task with stopped instance', () => {
  const task = {
    taskId: 'task_206',
    status: 'in_progress',
    assigneeRef: { type: 'agent_instance', agent_instance_id: 'inst_dead_2' },
  };
  const instances = [
    { agent_instance_id: 'inst_dead_2', runtime_status: 'failed' },
  ];
  assert.equal(hasLiveNudgeTarget(task, instances), false);
});

test('hasLiveNudgeTarget in validation checks reviewer instances', () => {
  const taskWithoutReviewerInst = {
    taskId: 'task_207',
    status: 'in_validation',
    reviewerRefs: [{ type: 'agent_id', agent_id: 'agt_reviewer' }],
  };
  assert.equal(hasLiveNudgeTarget(taskWithoutReviewerInst), false);

  const taskWithLiveReviewerInst = {
    taskId: 'task_208',
    status: 'in_validation',
    reviewerRefs: [{ type: 'agent_instance', agent_instance_id: 'inst_rev_1' }],
  };
  const instances = [
    { agent_instance_id: 'inst_rev_1', runtime_status: 'idle' },
  ];
  assert.equal(hasLiveNudgeTarget(taskWithLiveReviewerInst, instances), true);
});

// -----------------------------------------------------------------------------
// getUnpauseStatus (Unpause action target)
// -----------------------------------------------------------------------------

test('getUnpauseStatus returns queued for role-assigned task without live instance', () => {
  const task = {
    taskId: 'task_301',
    status: 'paused',
    assigneeRef: { type: 'agent_id', agent_id: 'agt_worker' },
  };
  assert.equal(getUnpauseStatus(task), 'queued');
});

test('getUnpauseStatus returns in_progress for task with live bound instance', () => {
  const task = {
    taskId: 'task_302',
    status: 'paused',
    assigneeRef: { type: 'agent_instance', agent_id: 'agt_worker', agent_instance_id: 'inst_live_4' },
  };
  const instances = [
    { agent_instance_id: 'inst_live_4', runtime_status: 'running' },
  ];
  assert.equal(getUnpauseStatus(task, instances), 'in_progress');
});
