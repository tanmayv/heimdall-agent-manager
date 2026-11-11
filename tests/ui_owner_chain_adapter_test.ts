// Owner-local chain reads map to the data props of origin/main's chain
// overview and board (ownerChainAdapter): agent rows, names, the attention
// rule, the create-ticket plan and the agent choices.
//
// RUN: node --import ./tests/helpers/vaultEndpointHarness.ts --test tests/ui_owner_chain_adapter_test.ts

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { parseOwnerRuntime } from '../src/ui/api/ownerChains.ts';
import { ownerTaskWire } from '../src/ui/components/tasks/ownerTaskAdapter.ts';
import {
  agentRuntimeActions, ownerAgentOptions, ownerAttention, ownerCreateTaskPlan, ownerOverviewMembers, ownerTaskNames,
} from '../src/ui/components/tasks/ownerChainAdapter.ts';

const rt = (o: { state?: string; lease?: string; controls?: string[]; brief?: Record<string, unknown> } = {}) => parseOwnerRuntime({
  revision: '1', leases: o.lease ? [['lease_1', o.lease, '9', '9', '1']] : [], requirements: o.brief ? [['1', JSON.stringify(o.brief)]] : [],
  state: o.state ? [[o.state, '1', '']] : [], submission: [], controls: o.controls ? [o.controls] : [], attempts: { attempt_no: '1' },
});
const wire = (taskId: string, runtime: ReturnType<typeof rt>) => ownerTaskWire({ chainId: 'chain_1', bridgeId: 'brg_1', taskId, row: { task_id: taskId, title: taskId.toUpperCase(), revision: '1', priority: 'p2' }, runtime });

test('ownerOverviewMembers lists members, the coordinator and lease holders, coordinator first and removed last', () => {
  const tasks = [wire('task_1', rt({ lease: 'inst_holder' })), wire('task_2', rt({ lease: 'inst_worker' }))];
  const rows = ownerOverviewMembers({
    members: [
      { instanceId: 'inst_gone', agentId: 'agt_old', role: 'worker', enabled: false },
      { instanceId: 'inst_worker', agentId: 'agt_worker', role: 'worker', enabled: true },
    ],
    coordinatorId: 'inst_coord',
    tasks,
    agentNames: { agt_worker: 'Backend worker' },
    agentStatus: { inst_worker: 'running', inst_coord: 'stopped' },
  });
  assert.deepEqual(rows.map((r) => [r.instanceId, r.role, r.name, r.status, r.enabled]), [
    ['inst_coord', 'coordinator', 'inst_coord', 'stopped', true],
    ['inst_worker', 'worker', 'Backend worker', 'running', true],
    ['inst_holder', '', 'inst_holder', '', true],
    ['inst_gone', 'worker', 'inst_gone', '', false],
  ]);
  assert.deepEqual(ownerOverviewMembers({ members: null, tasks: [], agentNames: {}, agentStatus: {} }), [], 'nothing known yet');
});

test('ownerTaskNames names tickets, member instances by their agent and reviewer agent ids', () => {
  const tasks = [wire('task_1', rt())];
  const members = ownerOverviewMembers({ members: [{ instanceId: 'inst_w', agentId: 'agt_w', role: 'worker', enabled: true }], tasks, agentNames: { agt_w: 'Writer', agt_r: 'Reviewer bot' }, agentStatus: {} });
  const names = ownerTaskNames(tasks, members, { agt_w: 'Writer', agt_r: 'Reviewer bot' });
  assert.equal(names.task('task_1'), 'TASK_1');
  assert.equal(names.instance('inst_w'), 'Writer');
  assert.equal(names.participant('agt_r'), 'Reviewer bot');
  assert.equal(names.durableId('inst_w'), 'agt_w');
  assert.equal(names.instance('inst_unknown'), null);
});

test('ownerAttention: your approval gate and an agent blocked on you need you; a hold does not', () => {
  const runtimes = {
    review: rt({ state: 'in_review', brief: { goal: 'g', requires_user_approval: true } }),
    agents: rt({ state: 'in_review', brief: { goal: 'g' } }),
    blocked: rt({ controls: ['blocked', 'ready', 'Which DB?', 'user'] }),
    held: rt({ controls: ['held', 'ready', 'Paused', ''] }),
  };
  const attention = ownerAttention(runtimes);
  const w = Object.fromEntries(Object.entries(runtimes).map(([id, r]) => [id, wire(id, r)]));
  assert.equal(attention.needed(w.review), true);
  assert.equal(attention.reason(w.review), 'Review required by you');
  assert.equal(attention.needed(w.agents), false, 'agent reviewers only: not on you');
  assert.equal(attention.needed(w.blocked), true);
  assert.equal(attention.reason(w.blocked), 'Blocked on you');
  assert.equal(attention.needed(w.held), false);
});

test('ownerCreateTaskPlan: task.create fields, the brief as requirements and deduplicated waits', () => {
  const plan = ownerCreateTaskPlan({
    title: '  Add audit log ', description: ' Log every write ', goal: 'Writes are logged', acceptance: ['One row per write', '  ', 'Viewable'],
    reviewers: ['agt_sec', ' '], requiresUserApproval: true, dependsOn: ['task_1', 'task_1', ' task_2 '],
  });
  assert.deepEqual(plan.task, { title: 'Add audit log', body: 'Log every write' });
  assert.deepEqual(JSON.parse(plan.requirements!), { goal: 'Writes are logged', acceptance: ['One row per write', 'Viewable'], reviewers: ['agt_sec'], requires_user_approval: true });
  assert.deepEqual(plan.dependsOn, ['task_1', 'task_2']);
  const bare = ownerCreateTaskPlan({ title: 'T', description: '', goal: ' ', acceptance: [''], reviewers: [], requiresUserApproval: false, dependsOn: [] });
  assert.equal(bare.requirements, null, 'no brief: no requirements.edit');
  const pinned = ownerCreateTaskPlan({ title: 'T', description: '', goal: 'G', acceptance: [], reviewers: [], requiresUserApproval: false, dependsOn: [], runBridgeId: ' brg_b ' });
  assert.equal(JSON.parse(pinned.requirements!).run_bridge_id, 'brg_b', 'the run Bridge pin goes into the brief');
  const unpinned = ownerCreateTaskPlan({ title: 'T', description: '', goal: 'G', acceptance: [], reviewers: [], requiresUserApproval: false, dependsOn: [], runBridgeId: '' });
  assert.equal('run_bridge_id' in JSON.parse(unpinned.requirements!), false, "'' is the owner Bridge: no pin");
});

test('ownerAgentOptions sorts agents by name; agentRuntimeActions follows the instance status', () => {
  assert.deepEqual(ownerAgentOptions({ agt_b: 'Beta', agt_a: 'Alpha', agt_c: '' }), [
    { value: 'agt_c', label: 'agt_c' }, { value: 'agt_a', label: 'Alpha' }, { value: 'agt_b', label: 'Beta' },
  ], 'an unnamed agent is labelled by its id');
  assert.deepEqual(agentRuntimeActions('ready'), ['stop', 'restart']);
  assert.deepEqual(agentRuntimeActions('failed'), ['start']);
  assert.deepEqual(agentRuntimeActions('stopping'), []);
});
