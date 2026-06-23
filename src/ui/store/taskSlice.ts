import { createAsyncThunk, createSlice } from '@reduxjs/toolkit';
import * as daemonApi from '../api/daemonApi';

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
    votes: (task.votes || []).map((v: any) => ({
      reviewerAgentInstanceId: v.reviewer_agent_instance_id,
      approved: Boolean(v.approved),
      comment: v.comment || '',
    })),
    participants: (task.participants || []).map((p: any) => ({
      agentInstanceId: p.agent_instance_id,
      role: p.role,
    })),
  };
}

function normalizeChain(chain: any) {
  return {
    id: chain.chain_id,
    chainId: chain.chain_id,
    title: chain.title || '',
    description: chain.description || '',
    status: chain.status || 'active',
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

export const refreshTaskBoard = createAsyncThunk(
  'tasks/refreshTaskBoard',
  async (payload: { createdAfter?: number; createdBefore?: number } | void, { dispatch, getState }) => {
    const state = getState() as any;
    const { session } = state.chat;
    const { selectedChainId } = state.tasks;
    if (!session.clientToken) return { chains: [], tasks: [], selectedChainId: '' };

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

    let tasks: any[] = [];
    if (targetChainId) {
      const tasksData = await daemonApi.listChainTasks({
        daemonUrl: session.daemonUrl,
        clientToken: session.clientToken,
        chainId: targetChainId,
      });
      tasks = (tasksData.tasks ?? []).map(normalizeTask);
    }

    return {
      chains,
      tasks,
      selectedChainId: targetChainId,
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

export const fetchTasksForChain = createAsyncThunk('tasks/fetchTasksForChain', async (chainId: string, { getState }) => {
  const { session } = (getState() as any).chat;
  if (!session.clientToken || !chainId) return { chainId, tasks: [] };

  const data = await daemonApi.listChainTasks({
    daemonUrl: session.daemonUrl,
    clientToken: session.clientToken,
    chainId,
  });

  return {
    chainId,
    tasks: (data.tasks ?? []).map(normalizeTask),
  };
});


export const fetchSelectedTaskLog = createAsyncThunk('tasks/fetchSelectedTaskLog', async (taskId: string | undefined, { getState }) => {
  const state = getState() as any;
  const { session } = state.chat;
  const selectedTaskId = taskId || state.tasks.selectedTaskId;
  if (!selectedTaskId || !session.clientToken) return { taskId: selectedTaskId, events: [] };
  const data = await daemonApi.fetchTaskLog({
    daemonUrl: session.daemonUrl,
    clientInstanceId: session.clientInstanceId,
    clientToken: session.clientToken,
    taskId: selectedTaskId,
  });
  return { taskId: selectedTaskId, events: (data.events ?? []).map(normalizeEvent) };
});

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
  const task = state.tasks.tasksById[payload.taskId || state.tasks.selectedTaskId];
  const response = await daemonApi.addTaskComment({ daemonUrl: session.daemonUrl, ...taskMutationAuth(session, payload.agentToken), taskId: task.taskId, chainId: task.chainId, body: payload.body });
  if (payload.resolveImmediately && response?.comment_id) {
    await daemonApi.resolveTaskComment({
      daemonUrl: session.daemonUrl,
      ...taskMutationAuth(session, payload.agentToken),
      taskId: task.taskId,
      chainId: task.chainId,
      commentId: response.comment_id,
    });
  }
  await (dispatch as any)(fetchSelectedTaskLog(task.taskId));
});

export const resolveCommentOnSelectedTask = createAsyncThunk('tasks/resolveCommentOnSelectedTask', async (payload: any, { dispatch, getState }) => {
  const state = getState() as any;
  const { session } = state.chat;
  const task = state.tasks.tasksById[payload.taskId || state.tasks.selectedTaskId];
  await daemonApi.resolveTaskComment({
    daemonUrl: session.daemonUrl,
    ...taskMutationAuth(session, payload.agentToken),
    taskId: task.taskId,
    chainId: task.chainId,
    commentId: payload.commentId,
  });
  await (dispatch as any)(fetchSelectedTaskLog(task.taskId));
});

export const updateSelectedTaskStatus = createAsyncThunk('tasks/updateSelectedTaskStatus', async (payload: any, { dispatch, getState }) => {
  const state = getState() as any;
  const { session } = state.chat;
  const task = state.tasks.tasksById[payload.taskId || state.tasks.selectedTaskId];
  await daemonApi.updateTaskStatus({ daemonUrl: session.daemonUrl, ...taskMutationAuth(session, payload.agentToken), taskId: task.taskId, chainId: task.chainId, status: payload.status, body: payload.body });
  await (dispatch as any)(fetchSelectedTaskLog(task.taskId));
});

export const assignSelectedTask = createAsyncThunk('tasks/assignSelectedTask', async (payload: any, { dispatch, getState }) => {
  const state = getState() as any;
  const { session } = state.chat;
  const task = state.tasks.tasksById[payload.taskId || state.tasks.selectedTaskId];
  await daemonApi.assignTask({ daemonUrl: session.daemonUrl, ...taskMutationAuth(session, payload.agentToken), taskId: task.taskId, chainId: task.chainId, agentInstanceId: payload.agentInstanceId });
});

export const addParticipantToSelectedTask = createAsyncThunk('tasks/addParticipantToSelectedTask', async (payload: any, { dispatch, getState }) => {
  const state = getState() as any;
  const { session } = state.chat;
  const task = state.tasks.tasksById[payload.taskId || state.tasks.selectedTaskId];
  await daemonApi.addTaskParticipant({ daemonUrl: session.daemonUrl, ...taskMutationAuth(session, payload.agentToken), taskId: task.taskId, chainId: task.chainId, agentInstanceId: payload.agentInstanceId, role: payload.role });
});

export const removeParticipantFromSelectedTask = createAsyncThunk('tasks/removeParticipantFromSelectedTask', async (payload: any, { dispatch, getState }) => {
  const state = getState() as any;
  const { session } = state.chat;
  const task = state.tasks.tasksById[payload.taskId || state.tasks.selectedTaskId];
  await daemonApi.removeTaskParticipant({ daemonUrl: session.daemonUrl, ...taskMutationAuth(session, payload.agentToken), taskId: task.taskId, chainId: task.chainId, agentInstanceId: payload.agentInstanceId, role: payload.role });
  await (dispatch as any)(fetchSelectedTaskLog(task.taskId));
});

export const voteOnSelectedTask = createAsyncThunk('tasks/voteOnSelectedTask', async (payload: any, { dispatch, getState }) => {
  const state = getState() as any;
  const { session } = state.chat;
  const task = state.tasks.tasksById[payload.taskId || state.tasks.selectedTaskId];
  await daemonApi.voteTask({ daemonUrl: session.daemonUrl, ...taskMutationAuth(session, payload.agentToken), taskId: task.taskId, chainId: task.chainId, approved: payload.approved, comment: payload.comment || 'Voted from UI.' });
  await (dispatch as any)(fetchSelectedTaskLog(task.taskId));
});

export const nudgeSelectedTask = createAsyncThunk('tasks/nudgeSelectedTask', async (payload: any, { dispatch, getState }) => {
  const state = getState() as any;
  const { session } = state.chat;
  const task = state.tasks.tasksById[payload.taskId || state.tasks.selectedTaskId];
  const result = await daemonApi.nudgeTask({ daemonUrl: session.daemonUrl, ...taskMutationAuth(session, payload.agentToken), taskId: task.taskId, chainId: task.chainId, body: payload.body });
  await (dispatch as any)(fetchSelectedTaskLog(task.taskId));
  return result;
});

export const updateSelectedChainMetadata = createAsyncThunk('tasks/updateSelectedChainMetadata', async (payload: any, { dispatch, getState }) => {
  const state = getState() as any;
  const { session } = state.chat;
  const chainId = payload.chainId || state.tasks.selectedChainId;
  await daemonApi.updateTaskChain({ daemonUrl: session.daemonUrl, ...taskMutationAuth(session, payload.agentToken), chainId, title: payload.title, description: payload.description, coordinatorAgentInstanceId: payload.coordinatorAgentInstanceId, defaultReviewerAgentInstanceId: payload.defaultReviewerAgentInstanceId, finalSummary: payload.finalSummary });
});

export const updateSelectedChainStatus = createAsyncThunk('tasks/updateSelectedChainStatus', async (payload: any, { dispatch, getState }) => {
  const state = getState() as any;
  const { session } = state.chat;
  const chainId = payload.chainId || state.tasks.selectedChainId;
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
  selectedChainId: '',
  selectedTaskId: '',
  expandedChainIds: {},
  taskLogsByTaskId: {},
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
    selectChain(state: any, action) {
      state.selectedChainId = action.payload || '';
    },
    selectTask(state: any, action) {
      const taskId = action.payload || '';
      state.selectedTaskId = taskId;
      const task = taskId ? state.tasksById[taskId] : null;
      if (task?.chainId) {
        state.selectedChainId = task.chainId;
        state.expandedChainIds[task.chainId] = true;
      }
    },
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
        if (targetChainId) {
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
        
        state.selectedChainId = targetChainId || action.payload.chains[0]?.chainId || '';
        if (state.selectedTaskId && !tasksById[state.selectedTaskId]) state.selectedTaskId = '';
      })
      .addCase(refreshTaskBoard.rejected, (state: any, action) => {
        state.loading = false;
        state.error = action.error.message || 'Failed to load tasks';
      })
      .addCase(fetchSelectedTaskLog.fulfilled, (state: any, action) => {
        if (action.payload.taskId) state.taskLogsByTaskId[action.payload.taskId] = action.payload.events;
      })
      .addCase(fetchSelectedTaskLog.rejected, (state: any, action) => {
        state.error = action.error.message || 'Failed to load task log';
      })
      .addCase(fetchTasksForChain.fulfilled, (state: any, action) => {
        const { chainId, tasks } = action.payload;
        if (!chainId) return;
        
        tasks.forEach((task: any) => {
          state.tasksById[task.taskId] = task;
        });
        
        state.chainTaskIds[chainId] = tasks.map((t: any) => t.taskId);
        state.chainTaskIds[chainId] = sortTaskIds(state.chainTaskIds[chainId], state.tasksById);
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

export const { selectChain, selectTask, toggleChainExpanded, taskEventReceived, updateTaskStateDirectly } = taskSlice.actions;
export default taskSlice.reducer;
