// REQ-FLEET-UI-ACTIONS-1: executable unit tests for role-assigned fleet task action buttons.
// REQ-FLEET-PT-3: provider/tier selection logic for the Fleet Management drawer.
// REQ-AUTO-1: no synthetic standard-role Fleet cards or capacity-1 fallback —
// a role is only a fleet entry when persisted or staged via Add Role.
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
import {
  activeTasksByRole,
  changedFleetEntries,
  fleetApplyRequests,
  fleetProviderCapabilities,
  flattenProviderTierDrafts,
  getOriginalFleetCapacity,
  getOriginalProviderTier,
  hasCustomRuntimeOverrides,
  isLiveFleetMember,
  liveInstancesByRole,
  nextTierOnProviderChange,
  providerTierModified,
  restartAffectedEntries,
  seedPerBridgeProviderTierDrafts,
  seedProviderTierDrafts,
  summarizeFleetRestartResults,
  tierOptionsForProvider,
} from '../src/ui/components/tasks/fleetSelection.ts';

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

// -----------------------------------------------------------------------------
// REQ-FLEET-PT-3: provider/tier drafts (Fleet Management drawer)
// -----------------------------------------------------------------------------

const CAPABILITIES = [
  { provider: 'qoder', tiers: ['smart', 'max'] },
  { provider: 'claude', tiers: ['opus', 'sonnet'] },
];

test('seedProviderTierDrafts maps provider/tier from fleet JSON, defaulting missing values to ""', () => {
  const rawFleets = [
    { agent_id: 'agt_worker', capacity: 2, provider: 'qoder', tier: 'max' },
    { agent_id: 'agt_reviewer', capacity: 1 },
    { agentId: 'agt_custom', capacity: 1, provider: '', tier: '' },
  ];
  assert.deepEqual(seedProviderTierDrafts(rawFleets), {
    agt_worker: { provider: 'qoder', tier: 'max' },
    agt_reviewer: { provider: '', tier: '' },
    agt_custom: { provider: '', tier: '' },
  });
  assert.deepEqual(seedProviderTierDrafts([]), {});
});

test('getOriginalProviderTier returns server values for persisted roles and "" for unpersisted roles', () => {
  const rawFleets = [{ agent_id: 'agt_worker', capacity: 2, provider: 'qoder', tier: 'smart' }];
  assert.deepEqual(getOriginalProviderTier(rawFleets, 'agt_worker'), { provider: 'qoder', tier: 'smart' });
  assert.deepEqual(getOriginalProviderTier(rawFleets, 'agt_reviewer'), { provider: '', tier: '' });
});

test('getOriginalFleetCapacity keeps the capacity rule: persisted row or null — no standard-role default', () => {
  const rawFleets = [{ agent_id: 'agt_worker', capacity: 3 }];
  assert.equal(getOriginalFleetCapacity(rawFleets, 'agt_worker'), 3);
  // REQ-AUTO-1: agt_worker/agt_reviewer are no longer special-cased; an
  // unpersisted role of any ID reports null so it only reaches Apply when the
  // user stages it via Add Role.
  assert.equal(getOriginalFleetCapacity([], 'agt_worker'), null);
  assert.equal(getOriginalFleetCapacity(rawFleets, 'agt_reviewer'), null);
  assert.equal(getOriginalFleetCapacity([], 'agt_reviewer'), null);
  assert.equal(getOriginalFleetCapacity(rawFleets, 'agt_other'), null);
});

test('tierOptionsForProvider returns the selected provider tiers and none for "" (Auto)', () => {
  assert.deepEqual(tierOptionsForProvider(CAPABILITIES, 'qoder'), ['smart', 'max']);
  assert.deepEqual(tierOptionsForProvider(CAPABILITIES, 'claude'), ['opus', 'sonnet']);
  assert.deepEqual(tierOptionsForProvider(CAPABILITIES, ''), []);
  assert.deepEqual(tierOptionsForProvider(CAPABILITIES, 'unknown'), []);
});

test('fleetProviderCapabilities maps the live bridge providers payload (name + models) to tiers', () => {
  // Shape GET /bridges/:id/providers actually returns (src/bridge/provider_store.odin
  // bridge_provider_profiles_report_json): provider names under "name", tiers implied
  // by non-empty model slots.
  const payload = {
    bridge_id: 'brg_x',
    default_provider: 'claude',
    default_tier: 'normal',
    providers: [
      { name: 'claude', enabled: true, models: { flag: '--model', cheap: '', normal: 'claude-sonnet', smart: 'claude-opus' } },
      { name: 'codex', enabled: true, models: { flag: '', cheap: '', normal: '', smart: '' } },
      { name: 'disabled-one', enabled: false, models: { normal: 'x' } },
    ],
  };
  assert.deepEqual(fleetProviderCapabilities(payload), [
    { provider: 'claude', tiers: ['normal', 'smart'], defaultTier: undefined },
    { provider: 'codex', tiers: [], defaultTier: undefined },
  ]);
});

test('fleetProviderCapabilities maps the explicit tiers payload shape unchanged', () => {
  // Capability-report / mock shape: {provider, tiers, default_tier}.
  const payload = {
    bridge_id: 'brg_x',
    default_provider: 'qoder',
    default_tier: 'smart',
    providers: [{ provider: 'qoder', tiers: ['smart', 'max'], default_tier: 'smart' }],
  };
  assert.deepEqual(fleetProviderCapabilities(payload), [
    { provider: 'qoder', tiers: ['smart', 'max'], defaultTier: 'smart' },
  ]);
  assert.deepEqual(fleetProviderCapabilities({ providers: [] }), []);
  assert.deepEqual(fleetProviderCapabilities(undefined), []);
});

test('nextTierOnProviderChange keeps a tier the new provider offers, otherwise resets to ""', () => {
  assert.equal(nextTierOnProviderChange('smart', 'qoder', CAPABILITIES), 'smart');
  assert.equal(nextTierOnProviderChange('smart', 'claude', CAPABILITIES), '');
  assert.equal(nextTierOnProviderChange('opus', 'claude', CAPABILITIES), 'opus');
  assert.equal(nextTierOnProviderChange('opus', '', CAPABILITIES), '');
});

test('changedFleetEntries includes Apply payload provider/tier for a provider-only change', () => {
  const rawFleets = [
    { agent_id: 'agt_worker', capacity: 2, provider: '', tier: '' },
    { agent_id: 'agt_reviewer', capacity: 1, provider: '', tier: '' },
  ];
  const fleets = [...rawFleets];
  const entries = changedFleetEntries(
    fleets,
    { agt_worker: 2, agt_reviewer: 1 },
    { agt_worker: { provider: 'qoder', tier: '' }, agt_reviewer: { provider: '', tier: '' } },
    rawFleets,
  );
  assert.deepEqual(entries, [
    { agentId: 'agt_worker', capacity: 2, provider: 'qoder', tier: '' },
  ]);
});

test('changedFleetEntries includes a tier-only change and a capacity+provider change', () => {
  const rawFleets = [
    { agent_id: 'agt_worker', capacity: 2, provider: 'qoder', tier: 'smart' },
    { agent_id: 'agt_reviewer', capacity: 1, provider: '', tier: '' },
  ];
  const entries = changedFleetEntries(
    rawFleets,
    { agt_worker: 2, agt_reviewer: 4 },
    { agt_worker: { provider: 'qoder', tier: 'max' }, agt_reviewer: { provider: 'claude', tier: '' } },
    rawFleets,
  );
  assert.deepEqual(entries, [
    { agentId: 'agt_worker', capacity: 2, provider: 'qoder', tier: 'max' },
    { agentId: 'agt_reviewer', capacity: 4, provider: 'claude', tier: '' },
  ]);
});

test('changedFleetEntries detects provider/tier staged on a not-yet-persisted role (Add Role staging)', () => {
  // A role staged through the drawer Add Role flow carries drafts but no
  // persisted row: origCapacity is null, so any staged value reaches Apply.
  const fleets = [{ agent_id: 'agt_custom_dev', capacity: 1, active_count: 0 }];
  const entries = changedFleetEntries(
    fleets,
    { agt_custom_dev: 1 },
    { agt_custom_dev: { provider: 'qoder', tier: 'max' } },
    [],
  );
  assert.deepEqual(entries, [
    { agentId: 'agt_custom_dev', capacity: 1, provider: 'qoder', tier: 'max' },
  ]);
  // The same holds for the former standard-role IDs — no special-casing.
  const standardEntries = changedFleetEntries(
    [{ agent_id: 'agt_worker', capacity: 1, active_count: 0 }],
    { agt_worker: 1 },
    { agt_worker: { provider: 'qoder', tier: 'max' } },
    [],
  );
  assert.deepEqual(standardEntries, [
    { agentId: 'agt_worker', capacity: 1, provider: 'qoder', tier: 'max' },
  ]);
});

test('changedFleetEntries detects a provider/tier-only change on a role with NO capacity draft (staged role)', () => {
  // Live-found case: the drawer no longer seeds synthetic standard-role cards,
  // so a role only appears when persisted or Add-Role-staged. Staging always
  // writes both drafts — but a provider/tier-only draft with no capacity draft
  // must still reach Apply (the upsert creates the fleet row).
  const fleets = [{ agent_id: 'agt_custom_dev', capacity: 1, active_count: 0 }];
  const entries = changedFleetEntries(
    fleets,
    {},
    { agt_custom_dev: { provider: 'claude', tier: 'smart' } },
    [],
  );
  assert.deepEqual(entries, [
    { agentId: 'agt_custom_dev', capacity: 1, provider: 'claude', tier: 'smart' },
  ]);
  // Untouched roles with neither draft stay out.
  const untouched = changedFleetEntries(fleets, {}, {}, []);
  assert.deepEqual(untouched, []);
});

test('changedFleetEntries skips roles whose drafts match the server state', () => {
  const rawFleets = [
    { agent_id: 'agt_worker', capacity: 2, provider: 'qoder', tier: 'smart' },
    { agent_id: 'agt_reviewer', capacity: 1, provider: '', tier: '' },
  ];
  const entries = changedFleetEntries(
    rawFleets,
    { agt_worker: 2, agt_reviewer: 1 },
    { agt_worker: { provider: 'qoder', tier: 'smart' }, agt_reviewer: { provider: '', tier: '' } },
    rawFleets,
  );
  assert.deepEqual(entries, []);
});

test('changedFleetEntries ignores provider/tier diffs when no draft entry exists (capacity-only flow preserved)', () => {
  const rawFleets = [{ agent_id: 'agt_worker', capacity: 2, provider: 'qoder', tier: 'smart' }];
  const entries = changedFleetEntries(
    rawFleets,
    { agt_worker: 5 },
    {},
    rawFleets,
  );
  assert.deepEqual(entries, [
    { agentId: 'agt_worker', capacity: 5, provider: 'qoder', tier: 'smart' },
  ]);
});

// -----------------------------------------------------------------------------
// REQ-RS-3 / REQ-RS-4: confirm-before-restart — affected roles, PUT bodies, summary
//
// The drawer asks before any PUT when a provider/tier edit would leave live
// instances on the old values; "Apply to New Instances Only" is exactly the
// pre-restart request shape. All of that decision logic is pure and covered here.
// -----------------------------------------------------------------------------

const ROLE_MEMBERS = [
  { agent_id: 'agt_worker', agent_instance_id: 'inst_live_1', runtime_status: 'running' },
  { agent_id: 'agt_worker', agent_instance_id: 'inst_live_2', runtimeStatus: 'launching' },
  { agent_id: 'agt_worker', agent_instance_id: 'inst_dead_1', runtime_status: 'stopped' },
  { agent_id: 'agt_reviewer', agent_instance_id: 'inst_live_3', runtime_status: 'idle' },
  { agent_id: 'agt_reviewer', agent_instance_id: 'inst_dead_2', runtime_status: 'failed' },
  { agent_id: 'agt_reviewer', agent_instance_id: 'inst_dead_3', runtime_status: 'terminated' },
];

test('isLiveFleetMember treats every non-terminal runtime status as live', () => {
  for (const status of ['running', 'ready', 'idle', 'launching', '']) {
    assert.equal(isLiveFleetMember({ runtime_status: status }), true);
  }
  for (const status of ['stopped', 'failed', 'terminated', 'Stopped']) {
    assert.equal(isLiveFleetMember({ runtime_status: status }), false);
  }
  // camelCase field and a missing status behave like the drawer's inline predicate always did.
  assert.equal(isLiveFleetMember({ runtimeStatus: 'failed' }), false);
  assert.equal(isLiveFleetMember({}), true);
});

test('liveInstancesByRole groups live members per role and drops terminal/role-less rows', () => {
  const grouped = liveInstancesByRole([
    ...ROLE_MEMBERS,
    { agent_instance_id: 'inst_orphan', runtime_status: 'running' },
  ]);
  assert.deepEqual(Object.keys(grouped).sort(), ['agt_reviewer', 'agt_worker']);
  assert.deepEqual(grouped.agt_worker.map((m) => m.agent_instance_id), ['inst_live_1', 'inst_live_2']);
  assert.deepEqual(grouped.agt_reviewer.map((m) => m.agent_instance_id), ['inst_live_3']);
  assert.deepEqual(liveInstancesByRole([]), {});
});

test('activeTasksByRole counts active tasks per role via assignee ref and bound instance', () => {
  const tasks = [
    { status: 'in_progress', assigneeRef: { agent_id: 'agt_worker' } },
    { status: 'queued', assigneeRef: { agent_id: 'agt_worker' } },
    { status: 'in_validation', assigneeRef: { agent_id: 'agt_reviewer' } },
    { status: 'completed', assigneeRef: { agent_id: 'agt_worker' } },
    { status: 'cancelled', assigneeRef: { agent_id: 'agt_reviewer' } },
    { status: 'in_progress', assigneeRef: null, assigneeAgentInstanceId: 'inst_live_3' },
  ];
  const grouped = activeTasksByRole(tasks, ROLE_MEMBERS);
  assert.equal((grouped.agt_worker || []).length, 2);
  assert.equal((grouped.agt_reviewer || []).length, 2);
});

test('activeTasksByRole counts a task for both its assignee role and its bound instance role', () => {
  const task = {
    status: 'in_progress',
    assigneeRef: { agent_id: 'agt_worker' },
    assigneeAgentInstanceId: 'inst_live_3',
  };
  const grouped = activeTasksByRole([task], ROLE_MEMBERS);
  assert.deepEqual(grouped.agt_worker, [task]);
  assert.deepEqual(grouped.agt_reviewer, [task]);
  assert.deepEqual(activeTasksByRole([], ROLE_MEMBERS), {});
});

test('providerTierModified compares drafts against the persisted row ("" included)', () => {
  const rawFleets = [{ agent_id: 'agt_worker', capacity: 1, provider: 'qoder', tier: 'smart' }];
  assert.equal(providerTierModified(rawFleets, 'agt_worker', { agt_worker: { provider: 'qoder', tier: 'max' } }), true);
  assert.equal(providerTierModified(rawFleets, 'agt_worker', { agt_worker: { provider: 'claude', tier: 'smart' } }), true);
  assert.equal(providerTierModified(rawFleets, 'agt_worker', { agt_worker: { provider: 'qoder', tier: 'smart' } }), false);
  // Clearing back to Auto is still a change: live instances carry the old values.
  assert.equal(providerTierModified(rawFleets, 'agt_worker', { agt_worker: { provider: '', tier: '' } }), true);
  // Untouched roles have no draft at all.
  assert.equal(providerTierModified(rawFleets, 'agt_reviewer', {}), false);
  // A not-yet-persisted role inherits ''/'' as its original.
  assert.equal(providerTierModified([], 'agt_worker', { agt_worker: { provider: 'qoder', tier: '' } }), true);
  assert.equal(providerTierModified([], 'agt_worker', { agt_worker: { provider: '', tier: '' } }), false);
});

test('restartAffectedEntries: provider/tier change + live instance prompts; capacity-only or zero live does not', () => {
  const rawFleets = [
    { agent_id: 'agt_worker', capacity: 2, provider: '', tier: '' },
    { agent_id: 'agt_reviewer', capacity: 1, provider: '', tier: '' },
  ];
  const liveCounts = { agt_worker: 2, agt_reviewer: 0 };

  // Provider change on a role with live instances -> the one role to confirm.
  const providerDrafts = { agt_worker: { provider: 'qoder', tier: '' } };
  const providerEntries = changedFleetEntries(rawFleets, { agt_worker: 2, agt_reviewer: 1 }, providerDrafts, rawFleets);
  assert.deepEqual(restartAffectedEntries(providerEntries, rawFleets, providerDrafts, liveCounts), [
    { agentId: 'agt_worker', capacity: 2, provider: 'qoder', tier: '' },
  ]);

  // Same change, zero live instances -> nothing to confirm, direct apply.
  assert.deepEqual(restartAffectedEntries(providerEntries, rawFleets, providerDrafts, { agt_worker: 0 }), []);

  // Capacity-only change on a role WITH live instances -> never a restart prompt.
  const capacityEntries = changedFleetEntries(rawFleets, { agt_worker: 5, agt_reviewer: 1 }, {}, rawFleets);
  assert.deepEqual(capacityEntries, [
    { agentId: 'agt_worker', capacity: 5, provider: '', tier: '' },
  ]);
  assert.deepEqual(restartAffectedEntries(capacityEntries, rawFleets, {}, liveCounts), []);

  // Tier-only change on a live role -> prompt.
  const tierDrafts = { agt_worker: { provider: '', tier: 'smart' } };
  const tierEntries = changedFleetEntries(rawFleets, { agt_worker: 2, agt_reviewer: 1 }, tierDrafts, rawFleets);
  assert.deepEqual(restartAffectedEntries(tierEntries, rawFleets, tierDrafts, liveCounts), [
    { agentId: 'agt_worker', capacity: 2, provider: '', tier: 'smart' },
  ]);
});

test('fleetApplyRequests flags affected roles only; unaffected bodies keep the pre-restart shape', () => {
  const entries = [
    { agentId: 'agt_worker', capacity: 2, provider: 'qoder', tier: '' },
    { agentId: 'agt_reviewer', capacity: 3, provider: 'claude', tier: 'smart' },
  ];
  const restartNow = fleetApplyRequests(entries, [entries[0]]);
  assert.deepEqual(restartNow, [
    { agentId: 'agt_worker', capacity: 2, provider: 'qoder', tier: '', restartLiveInstances: true },
    { agentId: 'agt_reviewer', capacity: 3, provider: 'claude', tier: 'smart' },
  ]);
  assert.equal('restartLiveInstances' in restartNow[1], false);

  // "Apply to New Instances Only" (no affected roles) -> no flag key anywhere,
  // i.e. the request objects equal today's payloads.
  const newInstancesOnly = fleetApplyRequests(entries, []);
  assert.deepEqual(newInstancesOnly, [
    { agentId: 'agt_worker', capacity: 2, provider: 'qoder', tier: '' },
    { agentId: 'agt_reviewer', capacity: 3, provider: 'claude', tier: 'smart' },
  ]);
  assert.equal(JSON.stringify(newInstancesOnly).includes('restart'), false);
  assert.deepEqual(fleetApplyRequests([], []), []);
});

test('summarizeFleetRestartResults maps per-role restart counts and flattens failures', () => {
  const summary = summarizeFleetRestartResults([
    { agentId: 'agt_worker', restarted_instance_ids: ['inst_a', 'inst_b'], restart_failures: [] },
    {
      agentId: 'agt_reviewer',
      restarted_instance_ids: [],
      restart_failures: [{ instance_id: 'inst_c', message: 'launch failed: model missing' }],
    },
  ]);
  assert.deepEqual(summary.restartedByRole, [
    { agentId: 'agt_worker', count: 2 },
    { agentId: 'agt_reviewer', count: 0 },
  ]);
  assert.deepEqual(summary.failures, [
    { instance_id: 'inst_c', message: 'launch failed: model missing' },
  ]);
});

test('summarizeFleetRestartResults tolerates flag-less responses and missing fields', () => {
  const summary = summarizeFleetRestartResults([
    { agentId: 'agt_worker' },
    { agentId: 'agt_reviewer', restarted_instance_ids: ['inst_z'] },
  ]);
  assert.deepEqual(summary.restartedByRole, [{ agentId: 'agt_reviewer', count: 1 }]);
  assert.deepEqual(summary.failures, []);
  assert.deepEqual(summarizeFleetRestartResults([]), {
    restartedByRole: [],
    failures: [],
  });
});

test('drawer decision end-to-end: only the role with a live instance gets the restart flag', () => {
  const rawFleets = [
    { agent_id: 'agt_worker', capacity: 1, provider: '', tier: '' },
    { agent_id: 'agt_reviewer', capacity: 1, provider: '', tier: '' },
  ];
  const drafts = {
    agt_worker: { provider: 'claude', tier: 'smart' },
    agt_reviewer: { provider: 'claude', tier: 'smart' },
  };
  const members = [
    { agent_id: 'agt_worker', agent_instance_id: 'inst_live_1', runtime_status: 'running' },
    { agent_id: 'agt_reviewer', agent_instance_id: 'inst_dead_1', runtime_status: 'stopped' },
  ];
  const liveByRole = liveInstancesByRole(members);
  const liveCounts: Record<string, number> = {};
  for (const [agentId, list] of Object.entries(liveByRole)) liveCounts[agentId] = list.length;

  const entries = changedFleetEntries(
    rawFleets,
    { agt_worker: 1, agt_reviewer: 1 },
    drafts,
    rawFleets,
  );
  const affected = restartAffectedEntries(entries, rawFleets, drafts, liveCounts);
  assert.deepEqual(affected.map((e) => e.agentId), ['agt_worker']);

  const requests = fleetApplyRequests(entries, affected);
  assert.deepEqual(
    requests.map((r) => [r.agentId, r.restartLiveInstances === true]),
    [
      ['agt_worker', true],
      ['agt_reviewer', false],
    ],
  );
});

test('tier options derived from a live bridge payload drive tier selection end-to-end', () => {
  const livePayload = {
    bridge_id: 'brg_x',
    default_provider: 'claude',
    default_tier: 'normal',
    providers: [
      { name: 'claude', enabled: true, models: { flag: '--model', cheap: '', normal: 'claude-sonnet', smart: 'claude-opus' } },
      { name: 'codex', enabled: true, models: { flag: '', cheap: '', normal: 'gpt-5-codex', smart: '' } },
    ],
  };
  const caps = fleetProviderCapabilities(livePayload);
  // Provider selected from the live names; tiers follow the selected provider.
  assert.deepEqual(tierOptionsForProvider(caps, 'claude'), ['normal', 'smart']);
  assert.deepEqual(tierOptionsForProvider(caps, 'codex'), ['normal']);
  // A tier from one provider is reset when switching to a provider without it.
  assert.equal(nextTierOnProviderChange('smart', 'codex', caps), '');
  assert.equal(nextTierOnProviderChange('normal', 'codex', caps), 'normal');
});

// -----------------------------------------------------------------------------
// REQ-FLEET-UI-EXPANDABLE-1 & REQ-FLEET-PER-BRIDGE-1: per-bridge runtime config
// -----------------------------------------------------------------------------

test('seedPerBridgeProviderTierDrafts maps per-bridge provider/tier for active bridges', () => {
  const rawFleets = [
    { agent_id: 'agt_worker', capacity: 2, provider: 'claude', tier: 'smart' },
    { agent_id: 'agt_reviewer', capacity: 1, provider: '', tier: '' },
  ];
  const bridges = [
    { bridge_id: 'brg_alpha', label: 'alpha' },
    { bridge_id: 'brg_beta', label: 'beta' },
  ];
  const drafts = seedPerBridgeProviderTierDrafts(rawFleets, bridges, 'brg_alpha');
  assert.deepEqual(drafts, {
    agt_worker: {
      brg_alpha: { provider: 'claude', tier: 'smart' },
      brg_beta: { provider: '', tier: '' },
    },
    agt_reviewer: {
      brg_alpha: { provider: '', tier: '' },
      brg_beta: { provider: '', tier: '' },
    },
  });
});

test('hasCustomRuntimeOverrides detects custom provider or tier overrides', () => {
  assert.equal(hasCustomRuntimeOverrides({ brg_1: { provider: 'claude', tier: '' } }), true);
  assert.equal(hasCustomRuntimeOverrides({ brg_1: { provider: '', tier: 'smart' } }), true);
  assert.equal(hasCustomRuntimeOverrides({ brg_1: { provider: '', tier: '' } }), false);
  assert.equal(hasCustomRuntimeOverrides(undefined), false);
});

test('flattenProviderTierDrafts prioritizes preferred bridge and detects overrides', () => {
  const drafts = {
    agt_worker: {
      brg_1: { provider: 'qoder', tier: 'normal' },
      brg_2: { provider: 'claude', tier: 'smart' },
    },
    agt_reviewer: {
      brg_1: { provider: '', tier: '' },
      brg_2: { provider: 'gemini', tier: 'pro' },
    },
  };
  const flat = flattenProviderTierDrafts(drafts, 'brg_1');
  assert.deepEqual(flat, {
    agt_worker: { provider: 'qoder', tier: 'normal' },
    agt_reviewer: { provider: 'gemini', tier: 'pro' },
  });
});

test('changedFleetEntries detects changes from per-bridge drafts', () => {
  const rawFleets = [
    { agent_id: 'agt_worker', capacity: 2, provider: '', tier: '' },
  ];
  const perBridgeDrafts = {
    agt_worker: {
      brg_main: { provider: 'claude', tier: 'opus' },
    },
  };
  const entries = changedFleetEntries(
    rawFleets,
    { agt_worker: 2 },
    perBridgeDrafts,
    rawFleets,
    'brg_main',
  );
  assert.deepEqual(entries, [
    { agentId: 'agt_worker', capacity: 2, provider: 'claude', tier: 'opus' },
  ]);
});

test('REQ-FLEET-UI-EXPANDABLE-1 & REQ-FLEET-PER-BRIDGE-1: drawer markup contains accordion and bridge rows', () => {
  const drawerSource = readRepo('src/ui/components/tasks/FleetManagementDrawer.tsx');
  // Expandable trigger with required debug id
  assert.match(drawerSource, /data-debug-id=\{`fleet-runtime-expand-btn-\$\{agentId\}`\}/);
  // Bridge row panel with required debug id
  assert.match(drawerSource, /data-debug-id=\{`fleet-bridge-runtime-row-\$\{agentId\}-\$\{bId\}`\}/);
  // State for tracking expansion
  assert.match(drawerSource, /expandedRuntimeRoles/);
  // Configure Runtime text
  assert.match(drawerSource, /Configure Runtime/);
  // useListBridgesQuery usage
  assert.match(drawerSource, /useListBridgesQuery/);
});

// -----------------------------------------------------------------------------
// REQ-TB-5: per-task bridge pin — select default, create submit, change/clear
// -----------------------------------------------------------------------------

import {
  TASK_BRIDGE_INHERIT_LABEL,
  taskBridgeOptions,
  taskCreateBridgeFields,
  taskPatchBridgeFields,
  taskBridgeDisplay,
} from '../src/ui/utils/taskBridgePin.ts';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

const REPO_ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const readRepo = (rel: string) => readFileSync(path.join(REPO_ROOT, rel), 'utf-8');

const PIN_BRIDGES = [
  { bridge_id: 'brg_alpha', label: 'alpha host', status: 'online' },
  { bridge_id: 'brg_beta', machine_hostname: 'beta.example', status: 'online' },
  { bridge_id: 'brg_gone', label: 'retired host', status: 'revoked' },
];

test('taskBridgeOptions defaults to Inherit and lists the owner bridges (revoked excluded)', () => {
  const options = taskBridgeOptions(PIN_BRIDGES);
  assert.deepEqual(options, [
    { value: '', label: TASK_BRIDGE_INHERIT_LABEL },
    { value: 'brg_alpha', label: 'alpha host' },
    { value: 'brg_beta', label: 'beta.example' },
  ]);
  // An empty bridge list still offers the inherit default — the modal never pins.
  assert.deepEqual(taskBridgeOptions([]), [{ value: '', label: TASK_BRIDGE_INHERIT_LABEL }]);
});

test('create submit: default create sends no bridge_id, an override pins the chosen bridge', () => {
  // Default (inherit) create — the hub treats absent and '' alike, so the key is
  // simply omitted.
  assert.deepEqual(taskCreateBridgeFields(''), {});
  assert.deepEqual(taskCreateBridgeFields(undefined), {});
  // A concrete bridge is forwarded verbatim.
  assert.deepEqual(taskCreateBridgeFields('brg_alpha'), { bridge_id: 'brg_alpha' });
});

test('change/clear submit: the presence-checked PATCH always carries bridge_id', () => {
  // Change: repin to a concrete bridge.
  assert.deepEqual(taskPatchBridgeFields('brg_beta'), { bridge_id: 'brg_beta' });
  // Clear: '' is the explicit clear-to-inherit signal (must NOT be dropped).
  assert.deepEqual(taskPatchBridgeFields(''), { bridge_id: '' });
});

test('taskBridgeDisplay resolves the pin name and marks inherit', () => {
  // Pinned: name resolved from the /bridges list.
  assert.deepEqual(taskBridgeDisplay('brg_alpha', PIN_BRIDGES), { label: 'alpha host', inherited: false });
  // Unknown id (e.g. revoked/foreign pin): falls back to the raw id, never blank.
  assert.deepEqual(taskBridgeDisplay('brg_other', PIN_BRIDGES), { label: 'brg_other', inherited: false });
  // No pin: inherited.
  assert.deepEqual(taskBridgeDisplay('', PIN_BRIDGES), { label: '', inherited: true });
  assert.deepEqual(taskBridgeDisplay(undefined, PIN_BRIDGES), { label: '', inherited: true });
});

test('REQ-TB-5 wiring: create modals, task detail, and the tasks API all carry the bridge pin', () => {
  const createModal = readRepo('src/ui/components/tasks/CreateTaskModal.tsx');
  const overview = readRepo('src/ui/components/taskchain/TaskChainOverview.tsx');
  const tasksApi = readRepo('src/ui/api/endpoints/tasks.ts');

  // Both create paths submit the selected bridge through the RTK arg.
  assert.match(createModal, /create-task-bridge-select/);
  assert.match(createModal, /bridgeId,/);
  assert.match(overview, /taskchain-new-task-bridge-select/);
  assert.match(overview, /bridgeId: newTaskBridgeId/);

  // Task detail shows the pin and PATCHes changes through updateTaskDetail.
  assert.match(overview, /taskchain-task-bridge-\$\{taskId\}/);
  assert.match(overview, /taskchain-edit-bridge-select/);
  assert.match(overview, /bridgeId: editBridgeId/);

  // The API layer serializes via the presence-aware helpers and normalizes the
  // pin onto the task shape.
  assert.match(tasksApi, /taskCreateBridgeFields\(bridgeId\)/);
  assert.match(tasksApi, /taskPatchBridgeFields\(bridgeId\)/);
  assert.match(tasksApi, /bridgeId: String\(task\.bridge_id/);
});
