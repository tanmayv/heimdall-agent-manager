import { useMemo } from 'react';
import { useSelector } from 'react-redux';
import { useFetchChainTasksQuery } from '../../api/endpoints/tasks';
import { useFetchChainQuery } from '../../api/endpoints/workspace';
import { selectTaskCacheProjection } from '../../api/taskCache';
import { selectChainViewCacheProjection } from '../../api/chainViewCache';
import {
  chainTasks,
  deriveChainProgress,
  deriveCurrentTask,
  deriveReviewNeededTasks,
  taskIdOf,
  type ChainLike,
  type TaskLike,
} from './chainTaskInference';

export type ChatChainWork = {
  chainId: string;
  chain: ChainLike | null;
  tasks: TaskLike[];
  progress: ReturnType<typeof deriveChainProgress>;
  reviewNeededTasks: TaskLike[];
  currentTask: TaskLike | null;
  currentRole: 'assignee' | 'reviewer' | 'coordinator' | 'assigned' | 'observer' | null;
  // currentTaskSource records whether the current task came from the persisted
  // server pointer (CT-8 single source of truth) or a client-side inference
  // fallback (used only when the server pointer is unset / not yet loaded).
  currentTaskSource: 'server' | 'inferred' | null;
};

// mapCurrentTaskRole maps the persisted server role (work|review) onto the UI's
// role vocabulary used by CurrentTaskStrip. Work -> assignee, Review -> reviewer.
function mapCurrentTaskRole(role: string): 'assignee' | 'reviewer' | null {
  const r = String(role || '').toLowerCase();
  if (r === 'work') return 'assignee';
  if (r === 'review') return 'reviewer';
  return null;
}

// UI-6 / CT-8: loads the bound chain's tasks for an open agent chat and resolves
// the Work chip / Review-needed / CurrentTaskStrip data. The CURRENT TASK is read
// from the SERVER-AUTHORITATIVE persisted pointer (currentTaskId + currentTaskRole
// on the agent instance) when available — a single source of truth — and only
// falls back to client-side inference when the server pointer is unset or the task
// is not yet in cache. Returns a stable empty state for private/empty chains.
export function useChatChainWork(
  agentInstanceId: string,
  chainId: string,
  currentTaskId?: string,
  currentTaskRole?: string,
): ChatChainWork {
  // Trigger fetch of chain tasks + chain detail. RTK Query dedupes/invalidates.
  useFetchChainTasksQuery({ chainId, limit: 100 }, { skip: !chainId });
  useFetchChainQuery({ chainId }, { skip: !chainId });

  const { tasksById } = useSelector(selectTaskCacheProjection);
  const { chainsById } = useSelector(selectChainViewCacheProjection);

  return useMemo<ChatChainWork>(() => {
    if (!chainId) {
      return { chainId: '', chain: null, tasks: [], progress: { total: 0, completed: 0, inProgress: 0, reviewReady: 0 }, reviewNeededTasks: [], currentTask: null, currentRole: null, currentTaskSource: null };
    }
    const tasks = chainTasks(tasksById, chainId);
    const chain = (chainsById?.[chainId] || null) as ChainLike | null;
    const progress = deriveChainProgress(tasks);
    const reviewNeededTasks = deriveReviewNeededTasks(tasks);

    // Prefer the persisted server pointer (CT-8). Resolve it to the cached task.
    const serverTaskId = String(currentTaskId || '');
    const serverRole = mapCurrentTaskRole(String(currentTaskRole || ''));
    if (serverTaskId && serverRole) {
      const serverTask = tasks.find((task) => taskIdOf(task) === serverTaskId) || null;
      if (serverTask) {
        return { chainId, chain, tasks, progress, reviewNeededTasks, currentTask: serverTask, currentRole: serverRole, currentTaskSource: 'server' };
      }
    }

    // Fallback: client-side inference (server pointer unset or task not cached).
    const pick = deriveCurrentTask(tasks, agentInstanceId);
    return {
      chainId,
      chain,
      tasks,
      progress,
      reviewNeededTasks,
      currentTask: pick?.task || null,
      currentRole: pick?.role || null,
      currentTaskSource: pick ? 'inferred' : null,
    };
  }, [chainId, agentInstanceId, currentTaskId, currentTaskRole, tasksById, chainsById]);
}
