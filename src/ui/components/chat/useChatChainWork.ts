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
};

// UI-6: loads the bound chain's tasks for an open agent chat and derives the
// Work chip / Review-needed / CurrentTaskStrip data from the SAME cached task
// list (no separate per-conversation current-task endpoint). Returns a stable
// empty state for private/empty chains.
export function useChatChainWork(agentInstanceId: string, chainId: string): ChatChainWork {
  // Trigger fetch of chain tasks + chain detail. RTK Query dedupes/invalidates.
  useFetchChainTasksQuery({ chainId, limit: 100 }, { skip: !chainId });
  useFetchChainQuery({ chainId }, { skip: !chainId });

  const { tasksById } = useSelector(selectTaskCacheProjection);
  const { chainsById } = useSelector(selectChainViewCacheProjection);

  return useMemo<ChatChainWork>(() => {
    if (!chainId) {
      return { chainId: '', chain: null, tasks: [], progress: { total: 0, completed: 0, inProgress: 0, reviewReady: 0 }, reviewNeededTasks: [], currentTask: null, currentRole: null };
    }
    const tasks = chainTasks(tasksById, chainId);
    const chain = (chainsById?.[chainId] || null) as ChainLike | null;
    const progress = deriveChainProgress(tasks);
    const reviewNeededTasks = deriveReviewNeededTasks(tasks);
    const pick = deriveCurrentTask(tasks, agentInstanceId);
    return {
      chainId,
      chain,
      tasks,
      progress,
      reviewNeededTasks,
      currentTask: pick?.task || null,
      currentRole: pick?.role || null,
    };
  }, [chainId, agentInstanceId, tasksById, chainsById]);
}
