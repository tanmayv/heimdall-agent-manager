// UI-6: pure client-side inference for the task chain bound to an open agent chat.
// The current-task strip, review-needed chip, and Work tab are all derived from the
// SAME cached task list loaded via `GET /api/v1/task-chains/{chain_id}?expand=tasks`.
// No separate per-conversation "current task" endpoint is required (design doc §4A).

export const USER_REVIEWER_IDS = new Set(['user_proxy', 'operator@local']);

// Statuses that should not count toward chain progress / active task lists.
export const CHAIN_PROGRESS_EXCLUDED_STATUSES = new Set(['cancelled', 'archived', 'abandoned']);

export type TaskLike = {
  taskId?: string;
  task_id?: string;
  title?: string;
  status?: string;
  chainId?: string;
  chain_id?: string;
  assigneeAgentInstanceId?: string;
  assignee_agent_instance_id?: string;
  reviewerAgentInstanceId?: string;
  reviewer_agent_instance_id?: string;
  coordinatorAgentInstanceId?: string;
  coordinator_agent_instance_id?: string;
  description?: string;
  participants?: Array<{ agentInstanceId?: string; role?: string }>;
  createdAtUnixMs?: number;
  created_at_unix_ms?: number;
  updatedAtUnixMs?: number;
  updated_at_unix_ms?: number;
  dependsOn?: string | string[];
  depends_on?: string | string[];
};

export type ChainLike = {
  chainId?: string;
  chain_id?: string;
  title?: string;
  status?: string;
  kind?: string;
  coordinatorAgentInstanceId?: string;
  coordinator_agent_instance_id?: string;
  defaultReviewerAgentInstanceId?: string;
  default_reviewer_agent_instance_id?: string;
};

export function taskIdOf(task: TaskLike | null | undefined): string {
  return String(task?.taskId || task?.task_id || '');
}

export function chainIdOfTask(task: TaskLike | null | undefined): string {
  return String(task?.chainId || task?.chain_id || '');
}

export function taskStatusOf(task: TaskLike | null | undefined): string {
  return String(task?.status || '');
}

export function taskAssigneeOf(task: TaskLike | null | undefined): string {
  return String(task?.assigneeAgentInstanceId || task?.assignee_agent_instance_id || '');
}

export function taskReviewerOf(task: TaskLike | null | undefined): string {
  return String(task?.reviewerAgentInstanceId || task?.reviewer_agent_instance_id || '');
}

export function taskCreatedMs(task: TaskLike | null | undefined): number {
  return Number(task?.createdAtUnixMs || task?.created_at_unix_ms || task?.updatedAtUnixMs || task?.updated_at_unix_ms || 0);
}

// Is the current user/operator an effective reviewer for this task?
export function isUserEffectiveReviewer(task: TaskLike | null | undefined): boolean {
  if (!task) return false;
  if (USER_REVIEWER_IDS.has(taskReviewerOf(task))) return true;
  return (task.participants || []).some(
    (p) => USER_REVIEWER_IDS.has(String(p?.agentInstanceId || '')) && (p?.role === 'lgtm_required' || p?.role === 'lgtm_optional'),
  );
}

// Is this agent instance an effective reviewer for this task?
export function isInstanceEffectiveReviewer(task: TaskLike | null | undefined, agentInstanceId: string): boolean {
  if (!task || !agentInstanceId) return false;
  if (taskReviewerOf(task) === agentInstanceId) return true;
  return (task.participants || []).some((p) => String(p?.agentInstanceId || '') === agentInstanceId && (p?.role === 'lgtm_required' || p?.role === 'lgtm_optional'));
}

export function isInstanceCoordinatorOf(chain: ChainLike | null | undefined, agentInstanceId: string): boolean {
  if (!chain || !agentInstanceId) return false;
  return String(chain?.coordinatorAgentInstanceId || chain?.coordinator_agent_instance_id || '') === agentInstanceId;
}

// Tasks belonging to a specific chain.
export function chainTasks(tasksById: Record<string, any>, chainId: string): TaskLike[] {
  if (!chainId || !tasksById) return [];
  return Object.values(tasksById)
    .filter((task: any) => chainIdOfTask(task) === chainId)
    .filter(Boolean);
}

// Tasks needing the user's review in this chain: review_ready + user is effective reviewer.
// Ordered oldest-first (oldest is the one the review chip opens).
export function deriveReviewNeededTasks(tasks: TaskLike[]): TaskLike[] {
  return tasks
    .filter((task) => taskStatusOf(task) === 'review_ready' && isUserEffectiveReviewer(task))
    .sort((a, b) => taskCreatedMs(a) - taskCreatedMs(b));
}

export type CurrentTaskPick = {
  task: TaskLike;
  role: 'assignee' | 'reviewer' | 'coordinator' | 'assigned' | 'observer';
};

// Derive the single current actionable task for an agent instance, following the
// design-doc selection order:
//   1. task where effective assignee is this instance and status is in_progress
//   2. else task where this instance is effective reviewer and status is review_ready
//   3. else next assigned/unblocked task for this instance
//   4. else null
export function deriveCurrentTask(tasks: TaskLike[], agentInstanceId: string): CurrentTaskPick | null {
  if (!agentInstanceId || !tasks.length) return null;

  // 1. in_progress assigned to this instance
  const inProgressAssigned = tasks.find(
    (task) => taskAssigneeOf(task) === agentInstanceId && taskStatusOf(task) === 'in_progress',
  );
  if (inProgressAssigned) return { task: inProgressAssigned, role: 'assignee' };

  // 2. review_ready where this instance is effective reviewer
  const reviewing = tasks.find(
    (task) => taskStatusOf(task) === 'review_ready' && isInstanceEffectiveReviewer(task, agentInstanceId),
  );
  if (reviewing) return { task: reviewing, role: 'reviewer' };

  // 3. next assigned/unblocked task for this instance (active statuses)
  const activeStatuses = new Set(['in_progress', 'review_ready', 'queued', 'ready', 'planning', 'blocked']);
  const queued = tasks
    .filter((task) => taskAssigneeOf(task) === agentInstanceId && activeStatuses.has(taskStatusOf(task)))
    .sort((a, b) => assignmentRank(taskStatusOf(a)) - assignmentRank(taskStatusOf(b)) || taskCreatedMs(a) - taskCreatedMs(b));
  if (queued.length > 0) return { task: queued[0], role: 'assigned' };

  return null;
}

function assignmentRank(status: string): number {
  if (status === 'in_progress') return 0;
  if (status === 'blocked') return 1;
  if (status === 'review_ready') return 2;
  if (status === 'queued' || status === 'ready' || status === 'planning') return 3;
  return 4;
}

export type ChainProgressInfo = {
  total: number;
  completed: number;
  inProgress: number;
  reviewReady: number;
};

export function deriveChainProgress(tasks: TaskLike[]): ChainProgressInfo {
  const live = tasks.filter((task) => !CHAIN_PROGRESS_EXCLUDED_STATUSES.has(taskStatusOf(task)));
  return {
    total: live.length,
    completed: live.filter((task) => taskStatusOf(task) === 'approved' || taskStatusOf(task) === 'completed' || taskStatusOf(task) === 'done').length,
    inProgress: live.filter((task) => taskStatusOf(task) === 'in_progress').length,
    reviewReady: live.filter((task) => taskStatusOf(task) === 'review_ready').length,
  };
}

// Role label for the current actor relative to a task.
export function taskRoleLabel(task: TaskLike, agentInstanceId: string, chain?: ChainLike | null): 'assignee' | 'reviewer' | 'coordinator' | 'observer' {
  if (chain && isInstanceCoordinatorOf(chain, agentInstanceId)) return 'coordinator';
  if (taskAssigneeOf(task) === agentInstanceId) return 'assignee';
  if (isInstanceEffectiveReviewer(task, agentInstanceId) || isUserEffectiveReviewer(task)) return 'reviewer';
  return 'observer';
}
