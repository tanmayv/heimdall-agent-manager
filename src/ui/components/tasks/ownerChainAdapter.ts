// Owner-local chain reads → the data props of origin/main's chain overview
// (ChainOverviewPanel) and chain board (TaskChainOverview, CreateTaskModal).
// Bridge-owned chains have no Hub chain endpoints: members come from the owner
// member rows (chain.metadata.read), agent names and instance statuses from
// the Hub agents API, tickets from ownerTaskAdapter. This module only maps;
// it never reads or writes.

import type { TaskWire } from '../../api/taskWire';
import type { OwnerChainMember } from '../../api/ownerCoordinator';
import { ownerAwaitingUser, type OwnerRuntime } from '../../api/ownerChains';
import { blockedOnYou } from './taskActions';
import { buildTaskNames, type TaskNames } from './taskNames';
import { ownerRequirementsDoc } from './ownerTaskAdapter';

/** One agent row of the chain overview. */
export interface ChainOverviewMember {
  instanceId: string;
  /** Durable agent id ('' when only the lease names the instance). */
  agentId: string;
  /** Display name: the agent's name, else the instance id. */
  name: string;
  /** coordinator | worker | reviewer | '' (a lease holder that is not a member). */
  role: string;
  /** Hub instance runtime_status ('' while unknown). */
  status: string;
  /** False once the member row was disabled (removed from the chain). */
  enabled: boolean;
}

export interface OwnerOverviewMemberSource {
  /** chain.metadata.read member rows; null while not read. */
  members: OwnerChainMember[] | null;
  coordinatorId?: string;
  /** The board wires: a live lease holder that is not a member still gets a row. */
  tasks: readonly TaskWire[];
  /** Hub agent id -> display name. */
  agentNames: Record<string, string>;
  /** Hub instance id -> runtime_status. */
  agentStatus: Record<string, string>;
}

/**
 * The overview's agent rows: every member row, the coordinator (even before
 * its member row is read) and every live lease holder, coordinator first,
 * removed members last.
 */
export function ownerOverviewMembers(src: OwnerOverviewMemberSource): ChainOverviewMember[] {
  const rows = new Map<string, Omit<ChainOverviewMember, 'name' | 'status'>>();
  for (const m of src.members ?? []) rows.set(m.instanceId, { instanceId: m.instanceId, agentId: m.agentId, role: m.role, enabled: m.enabled });
  if (src.coordinatorId && !rows.has(src.coordinatorId)) {
    rows.set(src.coordinatorId, { instanceId: src.coordinatorId, agentId: '', role: 'coordinator', enabled: true });
  }
  for (const t of src.tasks) {
    for (const lease of t.leases ?? []) {
      const holder = String(lease?.holder_instance_id || '');
      if (holder && !rows.has(holder)) rows.set(holder, { instanceId: holder, agentId: '', role: '', enabled: true });
    }
  }
  return [...rows.values()]
    .map((r) => ({ ...r, name: (r.agentId && src.agentNames[r.agentId]) || r.instanceId, status: src.agentStatus[r.instanceId] ?? '' }))
    .sort((a, b) => Number(b.role === 'coordinator') - Number(a.role === 'coordinator') || Number(b.enabled) - Number(a.enabled));
}

/** The chain's names resolver (tickets, members, Hub agent names). */
export function ownerTaskNames(tasks: readonly TaskWire[], members: readonly ChainOverviewMember[], agentNames: Record<string, string>): TaskNames {
  return buildTaskNames({
    tasks: tasks.map((t) => ({ task_id: t.task_id, title: t.title })),
    members: members.map((m) => ({ agentInstanceId: m.instanceId, agentId: m.agentId, displayName: m.name !== m.instanceId ? m.name : '' })),
    identities: Object.entries(agentNames).map(([agentId, name]) => ({ agent_id: agentId, name })),
  });
}

/** Which runtime controls an agent row offers for its instance status. */
export function agentRuntimeActions(status: string): ('start' | 'stop' | 'restart')[] {
  if (status === 'running' || status === 'idle' || status === 'ready') return ['stop', 'restart'];
  if (status === 'stopped' || status === 'failed') return ['start'];
  return [];
}

/** The overview's "Attention needed" rule for an owner ticket, and its reason. */
export interface ChainOverviewAttention {
  needed: (task: TaskWire) => boolean;
  reason: (task: TaskWire) => string;
}

/**
 * Owner tickets need you when their review waits on your approval (the owner
 * gate: in review, requires_user_approval, no device-signed approval of the
 * attempt) or when an agent blocked on you. The board wires carry no reviews,
 * so the runtime decides the review gate.
 */
export function ownerAttention(runtimes: Record<string, OwnerRuntime | undefined>): ChainOverviewAttention {
  const awaiting = (t: TaskWire) => {
    const rt = runtimes[t.task_id];
    return Boolean(rt && ownerAwaitingUser(rt));
  };
  return {
    needed: (t) => awaiting(t) || (Boolean(t.blocked) && blockedOnYou(t)),
    reason: (t) => (awaiting(t) ? 'Review required by you' : 'Blocked on you'),
  };
}

/** Hub agent id -> name as the create modal's agent choices. */
export function ownerAgentOptions(agentNames: Record<string, string>): { value: string; label: string }[] {
  return Object.entries(agentNames)
    .map(([value, label]) => ({ value, label: label || value }))
    .sort((a, b) => a.label.localeCompare(b.label));
}

/** What the New ticket modal collects (origin/main's CreateTaskModal, owner fields). */
export interface CreateTaskInput {
  title: string;
  description: string;
  goal: string;
  acceptance: string[];
  /** Reviewer agent ids. */
  reviewers: string[];
  requiresUserApproval: boolean;
  /** Task ids the new ticket waits for. */
  dependsOn: string[];
  /** The run Bridge pin ('' or absent: the owner Bridge). */
  runBridgeId?: string;
}

/** The owner commands that create one ticket: task.create, then its brief and its waits. */
export interface OwnerCreateTaskPlan {
  task: { title: string; body: string };
  /** requirements.edit body (revision 1), or null when nothing of the brief was given. */
  requirements: string | null;
  dependsOn: string[];
}

export function ownerCreateTaskPlan(input: CreateTaskInput): OwnerCreateTaskPlan {
  const acceptance = input.acceptance.map((a) => a.trim()).filter(Boolean);
  const reviewers = input.reviewers.map((r) => r.trim()).filter(Boolean);
  const runBridgeId = input.runBridgeId?.trim() || '';
  const hasBrief = Boolean(input.goal.trim()) || acceptance.length > 0 || reviewers.length > 0 || input.requiresUserApproval || Boolean(runBridgeId);
  const brief = hasBrief ? ownerRequirementsDoc('', { goal: input.goal, acceptance, reviewers, requiresUserApproval: input.requiresUserApproval, reason: '' }) : null;
  return {
    task: { title: input.title.trim(), body: input.description.trim() },
    requirements: brief && runBridgeId ? JSON.stringify({ ...JSON.parse(brief), run_bridge_id: runBridgeId }) : brief,
    dependsOn: [...new Set(input.dependsOn.map((d) => d.trim()).filter(Boolean))],
  };
}
