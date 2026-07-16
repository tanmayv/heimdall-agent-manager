import { createAsyncThunk, createSlice } from '@reduxjs/toolkit';
import * as daemonApi from '../api/daemonApi';
import { tasksApi } from '../api/endpoints/tasks';

const TASK_LOG_RELOAD_DEDUPE_MS = 1500;

function normalizeTask(task: any) {
  return {
    id: task.task_id,
    taskId: task.task_id,
    chainId: task.chain_id || '',
    title: task.title || '',
    description: task.description || '',
    acceptanceCriteria: task.acceptance_criteria || '',
    priority: task.priority || 'normal',
    status: task.status || 'pending',
    assigneeAgentInstanceId: task.assignee_agent_instance_id || '',
    reviewerAgentInstanceId: task.reviewer_agent_instance_id || '',
    coordinatorAgentInstanceId: task.coordinator_agent_instance_id || '',
    dependsOn: task.depends_on || '',
    createdBy: task.created_by || '',
    createdAtUnixMs: Number(task.created_at_unix_ms || 0),
    updatedAtUnixMs: Number(task.updated_at_unix_ms || 0),
    notActionableReason: task.not_actionable_reason || '',
    votes: (task.votes || []).map((v: any) => ({
      reviewerAgentInstanceId: v.reviewer_agent_instance_id,
      approved: Boolean(v.approved),
      comment: v.comment || '',
    })),
    participants: (task.participants || []).map((p: any) => ({
      agentInstanceId: p.agent_instance_id,
      role: p.role,
    })),
    unresolvedCommentCount: Number(task.unresolved_comment_count || 0),
    unresolvedComments: (task.unresolved_comments || []).map(normalizeEvent),
  };
}

function normalizeChain(chain: any) {
  return {
    id: chain.chain_id,
    chainId: chain.chain_id,
    title: chain.title || '',
    description: chain.description || '',
    status: chain.status || 'active',
    projectId: chain.project_id || chain.projectId || '',
    vcsWorkspaceId: chain.vcs_workspace_id || chain.vcsWorkspaceId || '',
    diffBaseSha: chain.diff_base_sha || chain.diffBaseSha || '',
    repoDiffSupported: Boolean(chain.repo_diff_supported || chain.repoDiffSupported),
    teamId: chain.team_id || chain.teamId || '',
    coordinatorAgentInstanceId: chain.coordinator_agent_instance_id || '',
    defaultReviewerAgentInstanceId: chain.default_reviewer_agent_instance_id || '',
    finalSummary: chain.final_summary || '',
    createdAtUnixMs: Number(chain.created_at_unix_ms || 0),
    completedAtUnixMs: Number(chain.completed_at_unix_ms || 0),
    archivePending: Boolean(chain.archive_pending),
    archived: Boolean(chain.archived),
    evaluation: chain.evaluation || 'unreviewed',
  };
}

function normalizeParticipant(participant: any) {
  return {
    taskId: participant.task_id || '',
    chainId: participant.chain_id || '',
    agentInstanceId: participant.agent_instance_id || '',
    role: participant.role || '',
  };
}

function normalizeEvent(event: any) {
  return {
    eventId: event.event_id || '',
    kind: event.kind || '',
    taskId: event.task_id || '',
    chainId: event.chain_id || '',
    status: event.status || '',
    body: event.body || '',
    authorAgentInstanceId: event.author_agent_instance_id || '',
    createdUnixMs: Number(event.created_unix_ms || 0),
    commentId: event.comment_id || '',
  };
}

function getActiveTaskId(payload: any): string {
  if (payload?.taskId) return payload.taskId;
  const params = new URLSearchParams(window.location.search);
  return params.get('taskId') || '';
}

function getActiveChainId(payload: any): string {
  if (payload?.chainId) return payload.chainId;
  const params = new URLSearchParams(window.location.search);
  return params.get('chainId') || '';
}

// TODO(rtkq-migration owner=task-19f69e242e4): home/overview surfaces still use this thunk as a transitional board loader. RTK Query remains the recurring cache authority for migrated task detail/log reads and task mutations.
export const refreshTaskBoard = createAsyncThunk(
  'tasks/refreshTaskBoard',
  async (payload: { createdAfter?: number; createdBefore?: number } | void, { getState }) => {
    const state = getState() as any;
    const { session } = state.chat;
    const selectedChainId = getActiveChainId(payload);
    if (!session.clientToken) return { chains: [], tasks: [], selectedChainId: '', includesSelectedChainTasks: false };

    const args = (payload && typeof payload === 'object') ? payload : {};
    const chainsData = await daemonApi.listTaskChains({
      daemonUrl: session.daemonUrl,
      clientToken: session.clientToken,
      createdAfter: args.createdAfter,
      createdBefore: args.createdBefore,
    });

    const chains = (chainsData.chains ?? []).map(normalizeChain);

    let targetChainId = selectedChainId;
    if (!targetChainId || !chains.some((c: any) => c.chainId === targetChainId)) {
      targetChainId = chains[0]?.chainId || '';
    }

    return {
      chains,
      tasks: [],
      selectedChainId: targetChainId,
      includesSelectedChainTasks: false,
    };
  },
  {
    condition: (payload, { getState }) => {
      const state = (getState() as any).tasks;
      if (state.loading) {
        return false;
      }
    }
  }
);

// TODO(rtkq-migration owner=task-19f69e242e4): component compatibility wrapper for unmigrated chain/task-list surfaces. Do not add follow-up refresh chaining around this thunk; prefer RTKQ hooks or endpoint initiate calls.
export const fetchTasksForChain = createAsyncThunk(
  'tasks/fetchTasksForChain',
  async (chainId: string, { dispatch, getState }) => {
    const { session } = (getState() as any).chat;
    if (!session.clientToken || !chainId) return { chainId, tasks: [] };

    return await (dispatch as any)(tasksApi.endpoints.fetchChainTasks.initiate({ chainId })).unwrap();
  },
  {
    condition: (chainId, { getState }) => {
      if (!chainId) return false;
      return !Boolean((getState() as any).tasks?.tasksLoadingByChainId?.[chainId]);
    },
  },
);


// TODO(rtkq-migration owner=task-19f69e242e4): compatibility wrapper for older task-log open/load-more callers. The authoritative recurring cache for live task logs is tasksApi.fetchTaskLog/fetchTaskLogPage.
export const fetchSelectedTaskLog = createAsyncThunk(
  'tasks/fetchSelectedTaskLog',
  async (payload: string | { taskId?: string; limit?: number; cursor?: number; force?: boolean } | undefined, { dispatch, getState }) => {
    const state = getState() as any;
    const { session } = state.chat;
    const selectedTaskId = typeof payload === 'string' ? payload : (payload?.taskId || getActiveTaskId(null));
    const limit = typeof payload === 'object' && payload?.limit !== undefined ? payload.limit : 50;
    const cursor = typeof payload === 'object' && payload?.cursor !== undefined ? payload.cursor : 0;
    if (!selectedTaskId || !session.clientToken) return { taskId: selectedTaskId, events: [], nextCursor: 0, hasMore: false, total: 0, isAppend: false };
    const result = cursor > 0
      ? await (dispatch as any)(tasksApi.endpoints.fetchTaskLogPage.initiate({ taskId: selectedTaskId, cursor, limit })).unwrap()
      : await (dispatch as any)(tasksApi.endpoints.fetchTaskLog.initiate({ taskId: selectedTaskId, limit })).unwrap();
    return { ...result, taskId: selectedTaskId, isAppend: cursor > 0 };
  },
  {
    condition: (payload: string | { taskId?: string; limit?: number; cursor?: number; force?: boolean } | undefined, { getState }) => {
      const state = getState() as any;
      const selectedTaskId = typeof payload === 'string' ? payload : (payload?.taskId || getActiveTaskId(null));
      const cursor = typeof payload === 'object' && payload?.cursor !== undefined ? payload.cursor : 0;
      const force = typeof payload === 'object' && Boolean(payload?.force);
      if (!selectedTaskId) return false;
      if (cursor > 0 || force) return true;
      if (state.tasks?.taskLogLoadingByTaskId?.[selectedTaskId]) return false;
      const lastLoadedAt = Number(state.tasks?.taskLogLoadedAtByTaskId?.[selectedTaskId] || 0);
      return !lastLoadedAt || Date.now() - lastLoadedAt > TASK_LOG_RELOAD_DEDUPE_MS;
    },
  },
);

function taskMutationAuth(session: any, agentToken: string) {
  return {
    agentToken: agentToken?.trim() || '',
    clientInstanceId: session.clientInstanceId,
    clientToken: session.clientToken,
  };
}

export const createTaskFromBoard = createAsyncThunk('tasks/createTaskFromBoard', async (payload: any, { dispatch, getState }) => {
  const { session } = (getState() as any).chat;
  const result = await daemonApi.createTask({ daemonUrl: session.daemonUrl, ...taskMutationAuth(session, payload.agentToken), ...payload });
  return result;
});

export const createChainFromBoard = createAsyncThunk('tasks/createChainFromBoard', async (payload: any, { dispatch, getState }) => {
  const { session } = (getState() as any).chat;
  const result = await daemonApi.createTaskChain({ daemonUrl: session.daemonUrl, ...taskMutationAuth(session, payload.agentToken), ...payload });
  return result;
});

export const addCommentToSelectedTask = createAsyncThunk('tasks/addCommentToSelectedTask', async (payload: any, { dispatch, getState }) => {
  const state = getState() as any;
  const { session } = state.chat;
  const activeTaskId = getActiveTaskId(payload);
  const task = state.tasks.tasksById[activeTaskId];
  return await (dispatch as any)(tasksApi.endpoints.addTaskComment.initiate({ taskId: task.taskId, chainId: task.chainId, body: payload.body, agentToken: payload.agentToken, resolveImmediately: payload.resolveImmediately })).unwrap();
});

export const resolveCommentOnSelectedTask = createAsyncThunk('tasks/resolveCommentOnSelectedTask', async (payload: any, { dispatch, getState }) => {
  const state = getState() as any;
  const activeTaskId = getActiveTaskId(payload);
  const task = state.tasks.tasksById[activeTaskId];
  return await (dispatch as any)(tasksApi.endpoints.resolveTaskComment.initiate({ taskId: task.taskId, chainId: task.chainId, commentId: payload.commentId, agentToken: payload.agentToken })).unwrap();
});

export const updateSelectedTaskStatus = createAsyncThunk('tasks/updateSelectedTaskStatus', async (payload: any, { dispatch, getState }) => {
  const state = getState() as any;
  const activeTaskId = getActiveTaskId(payload);
  const task = state.tasks.tasksById[activeTaskId];
  return await (dispatch as any)(tasksApi.endpoints.setTaskStatus.initiate({ taskId: task.taskId, chainId: task.chainId, status: payload.status, body: payload.body, agentToken: payload.agentToken })).unwrap();
});

export const updateSelectedTaskMetadata = createAsyncThunk('tasks/updateSelectedTaskMetadata', async (payload: any, { dispatch, getState }) => {
  const state = getState() as any;
  const activeTaskId = getActiveTaskId(payload);
  const task = state.tasks.tasksById[activeTaskId];
  await (dispatch as any)(tasksApi.endpoints.updateTask.initiate({ taskId: task.taskId, chainId: task.chainId, title: payload.title, description: payload.description, acceptanceCriteria: payload.acceptanceCriteria, dependsOn: payload.dependsOn, agentToken: payload.agentToken })).unwrap();
  const data = await (dispatch as any)(tasksApi.endpoints.fetchTask.initiate({ taskId: task.taskId })).unwrap();
  return data.task || null;
});

export const assignSelectedTask = createAsyncThunk('tasks/assignSelectedTask', async (payload: any, { dispatch, getState }) => {
  const state = getState() as any;
  const activeTaskId = getActiveTaskId(payload);
  const task = state.tasks.tasksById[activeTaskId];
  return await (dispatch as any)(tasksApi.endpoints.assignTask.initiate({ taskId: task.taskId, chainId: task.chainId, agentInstanceId: payload.agentInstanceId, agentToken: payload.agentToken })).unwrap();
});

export const addParticipantToSelectedTask = createAsyncThunk('tasks/addParticipantToSelectedTask', async (payload: any, { dispatch, getState }) => {
  const state = getState() as any;
  const activeTaskId = getActiveTaskId(payload);
  const task = state.tasks.tasksById[activeTaskId];
  return await (dispatch as any)(tasksApi.endpoints.addTaskParticipant.initiate({ taskId: task.taskId, chainId: task.chainId, agentInstanceId: payload.agentInstanceId, role: payload.role, agentToken: payload.agentToken })).unwrap();
});

export const removeParticipantFromSelectedTask = createAsyncThunk('tasks/removeParticipantFromSelectedTask', async (payload: any, { dispatch, getState }) => {
  const state = getState() as any;
  const activeTaskId = getActiveTaskId(payload);
  const task = state.tasks.tasksById[activeTaskId];
  return await (dispatch as any)(tasksApi.endpoints.removeTaskParticipant.initiate({ taskId: task.taskId, chainId: task.chainId, agentInstanceId: payload.agentInstanceId, role: payload.role, agentToken: payload.agentToken })).unwrap();
});

export const voteOnSelectedTask = createAsyncThunk('tasks/voteOnSelectedTask', async (payload: any, { dispatch, getState }) => {
  const state = getState() as any;
  const activeTaskId = getActiveTaskId(payload);
  const task = state.tasks.tasksById[activeTaskId];
  return await (dispatch as any)(tasksApi.endpoints.voteTask.initiate({ taskId: task.taskId, chainId: task.chainId, approved: payload.approved, comment: payload.comment || 'Voted from UI.', agentToken: payload.agentToken })).unwrap();
});

export const voteOnAttentionTask = createAsyncThunk('tasks/voteOnAttentionTask', async (payload: { taskId: string; chainId: string; approved: boolean; comment?: string }, { dispatch }) => {
  await (dispatch as any)(tasksApi.endpoints.voteTask.initiate({
    taskId: payload.taskId,
    chainId: payload.chainId,
    approved: payload.approved,
    comment: payload.comment || (payload.approved ? 'Approved from Needs attention.' : 'Rejected from Needs attention.'),
  })).unwrap();
  return { taskId: payload.taskId, chainId: payload.chainId, approved: payload.approved };
});

export const nudgeSelectedTask = createAsyncThunk('tasks/nudgeSelectedTask', async (payload: any, { dispatch, getState }) => {
  const state = getState() as any;
  const activeTaskId = getActiveTaskId(payload);
  const task = state.tasks.tasksById[activeTaskId];
  return await (dispatch as any)(tasksApi.endpoints.nudgeTask.initiate({ taskId: task.taskId, chainId: task.chainId, body: payload.body, interrupt: payload.interrupt, agentToken: payload.agentToken })).unwrap();
});

export const updateSelectedChainMetadata = createAsyncThunk('tasks/updateSelectedChainMetadata', async (payload: any, { dispatch, getState }) => {
  const state = getState() as any;
  const { session } = state.chat;
  const chainId = getActiveChainId(payload);
  await daemonApi.updateTaskChain({ daemonUrl: session.daemonUrl, ...taskMutationAuth(session, payload.agentToken), chainId, title: payload.title, description: payload.description, coordinatorAgentInstanceId: payload.coordinatorAgentInstanceId, defaultReviewerAgentInstanceId: payload.defaultReviewerAgentInstanceId, finalSummary: payload.finalSummary });
});

export const updateSelectedChainStatus = createAsyncThunk('tasks/updateSelectedChainStatus', async (payload: any, { dispatch, getState }) => {
  const state = getState() as any;
  const { session } = state.chat;
  const chainId = getActiveChainId(payload);
  await daemonApi.updateTaskChainStatus({ daemonUrl: session.daemonUrl, ...taskMutationAuth(session, payload.agentToken), chainId, status: payload.status, finalSummary: payload.finalSummary });
});

export const fetchUnreviewedChains = createAsyncThunk(
  'tasks/fetchUnreviewedChains',
  async (_, { getState }) => {
    const { session } = (getState() as any).chat;
    if (!session.clientToken) return [];
    const data = await daemonApi.listUnreviewedTaskChains({
      daemonUrl: session.daemonUrl,
      clientToken: session.clientToken,
    });
    return (data.chains ?? []).map(normalizeChain);
  }
);

export const evaluateTaskChain = createAsyncThunk(
  'tasks/evaluateTaskChain',
  async (payload: { chainId: string; evaluation: 'good' | 'bad' }, { getState }) => {
    const { session } = (getState() as any).chat;
    await daemonApi.evaluateTaskChain({
      daemonUrl: session.daemonUrl,
      clientInstanceId: session.clientInstanceId,
      clientToken: session.clientToken,
      chainId: payload.chainId,
      evaluation: payload.evaluation,
    });
    return { chainId: payload.chainId, evaluation: payload.evaluation };
  }
);

const initialState = {
  chainsById: {},
  tasksById: {},
  chainTaskIds: {},
  participantsByTaskId: {},
  expandedChainIds: {},
  taskLogsByTaskId: {},
  taskLogCursorByTaskId: {},
  taskLogHasMoreByTaskId: {},
  taskLogTotalByTaskId: {},
  taskLogLoadingByTaskId: {},
  taskLogLoadedAtByTaskId: {},
  tasksLoadingByChainId: {},
  loading: false,
  error: '',
  lastTaskEvent: null,
  unreviewedChains: [] as any[],
};

function sortTaskIds(taskIds: string[], tasksById: any) {
  return taskIds.sort((left, right) => {
    const leftTask = tasksById[left];
    const rightTask = tasksById[right];
    return (rightTask?.updatedAtUnixMs || 0) - (leftTask?.updatedAtUnixMs || 0);
  });
}

const taskSlice = createSlice({
  name: 'tasks',
  initialState,
  reducers: {
    toggleChainExpanded(state: any, action) {
      const chainId = action.payload;
      if (!chainId) return;
      state.expandedChainIds[chainId] = !state.expandedChainIds[chainId];
    },
    taskEventReceived(state: any, action) {
      state.lastTaskEvent = action.payload;
      const payload = action.payload;
      if (payload) {
        if (payload.event === 'Chain_Completed' && payload.chain) {
          const normalized = normalizeChain(payload.chain);
          if (!state.unreviewedChains.some((c: any) => c.chainId === normalized.chainId)) {
            state.unreviewedChains.push(normalized);
          }
        } else if (payload.event === 'Chain_Evaluated') {
          state.unreviewedChains = state.unreviewedChains.filter((c: any) => c.chainId !== payload.chain_id);
        }
      }
    },
    updateTaskStateDirectly(state: any, action) {
      const task = action.payload;
      if (!task) return;
      const normalized = normalizeTask(task);
      state.tasksById[normalized.taskId] = normalized;
      
      const chainId = normalized.chainId || 'standalone';
      if (!state.chainTaskIds[chainId]) {
        state.chainTaskIds[chainId] = [];
      }
      if (!state.chainTaskIds[chainId].includes(normalized.taskId)) {
        state.chainTaskIds[chainId].push(normalized.taskId);
      }
      state.chainTaskIds[chainId] = sortTaskIds(state.chainTaskIds[chainId], state.tasksById);
    },
    updateChainStateDirectly(state: any, action) {
      const chain = action.payload;
      if (!chain) return;
      const normalized = normalizeChain(chain);
      state.chainsById[normalized.chainId] = normalized;
    },
  },
  extraReducers: (builder) => {
    builder
      .addCase(refreshTaskBoard.pending, (state: any) => {
        state.loading = true;
        state.error = '';
      })
      .addCase(refreshTaskBoard.fulfilled, (state: any, action) => {
        state.loading = false;
        state.error = '';
        const chainsById: any = {};
        const tasksById: any = { ...state.tasksById }; // Preserve existing tasks in memory
        const chainTaskIds: any = { ...state.chainTaskIds }; // Preserve existing mappings

        action.payload.chains.forEach((chain: any) => {
          chainsById[chain.chainId] = chain;
          if (!chainTaskIds[chain.chainId]) chainTaskIds[chain.chainId] = [];
        });

        const targetChainId = action.payload.selectedChainId;
        if (targetChainId && action.payload.includesSelectedChainTasks) {
          chainTaskIds[targetChainId] = [];
          action.payload.tasks.forEach((task: any) => {
            tasksById[task.taskId] = task;
            chainTaskIds[targetChainId].push(task.taskId);
          });
          chainTaskIds[targetChainId] = sortTaskIds(chainTaskIds[targetChainId], tasksById);
        }

        state.chainsById = chainsById;
        state.tasksById = tasksById;
        state.chainTaskIds = chainTaskIds;
      })
      .addCase(refreshTaskBoard.rejected, (state: any, action) => {
        state.loading = false;
        state.error = action.error.message || 'Failed to load tasks';
      })
      .addCase(fetchTasksForChain.pending, (state: any, action) => {
        if (action.meta.arg) state.tasksLoadingByChainId[action.meta.arg] = true;
      })
      .addCase(fetchTasksForChain.rejected, (state: any, action) => {
        if (action.meta.arg) state.tasksLoadingByChainId[action.meta.arg] = false;
      })
      .addCase(fetchSelectedTaskLog.pending, (state: any, action) => {
        const arg: any = action.meta.arg;
        const taskId = typeof arg === 'string' ? arg : (arg?.taskId || getActiveTaskId(null));
        if (taskId) state.taskLogLoadingByTaskId[taskId] = true;
      })
      .addCase(fetchSelectedTaskLog.fulfilled, (state: any, action) => {
        const { taskId, events, nextCursor, hasMore, total, isAppend } = action.payload;
        if (taskId) {
          state.taskLogLoadingByTaskId[taskId] = false;
          if (isAppend) {
            const byId = new Map<string, any>();
            for (const event of [...(state.taskLogsByTaskId[taskId] || []), ...(events || [])]) {
              byId.set(event.eventId || `${event.kind}-${event.createdUnixMs}-${event.body}`, event);
            }
            state.taskLogsByTaskId[taskId] = Array.from(byId.values()).sort((left: any, right: any) => Number(left.createdUnixMs || 0) - Number(right.createdUnixMs || 0));
          } else {
            state.taskLogsByTaskId[taskId] = events;
          }
          state.taskLogCursorByTaskId[taskId] = nextCursor;
          state.taskLogHasMoreByTaskId[taskId] = hasMore || nextCursor > 0;
          state.taskLogTotalByTaskId[taskId] = total;
          if (!isAppend) state.taskLogLoadedAtByTaskId[taskId] = Date.now();
        }
      })
      .addCase(fetchSelectedTaskLog.rejected, (state: any, action) => {
        const arg: any = action.meta.arg;
        const taskId = typeof arg === 'string' ? arg : (arg?.taskId || getActiveTaskId(null));
        if (taskId) state.taskLogLoadingByTaskId[taskId] = false;
        state.error = action.error.message || 'Failed to load task log';
      })
      .addCase(fetchTasksForChain.fulfilled, (state: any, action) => {
        const { chainId, tasks } = action.payload;
        if (!chainId) return;
        state.tasksLoadingByChainId[chainId] = false;
        
        tasks.forEach((task: any) => {
          state.tasksById[task.taskId] = task;
        });
        
        state.chainTaskIds[chainId] = tasks.map((t: any) => t.taskId);
        state.chainTaskIds[chainId] = sortTaskIds(state.chainTaskIds[chainId], state.tasksById);
      })
      .addCase(updateSelectedTaskMetadata.fulfilled, (state: any, action) => {
        const task = action.payload;
        if (!task) return;
        state.tasksById[task.taskId] = task;
        if (task.chainId && state.chainTaskIds[task.chainId]) {
          state.chainTaskIds[task.chainId] = sortTaskIds(state.chainTaskIds[task.chainId], state.tasksById);
        }
      })
      .addCase(fetchUnreviewedChains.fulfilled, (state: any, action) => {
        state.unreviewedChains = action.payload;
      })
      .addCase(evaluateTaskChain.fulfilled, (state: any, action) => {
        const { chainId } = action.payload;
        state.unreviewedChains = state.unreviewedChains.filter((c: any) => c.chainId !== chainId);
      });
  },
});

export const { toggleChainExpanded, taskEventReceived, updateTaskStateDirectly, updateChainStateDirectly } = taskSlice.actions;
export default taskSlice.reducer;
