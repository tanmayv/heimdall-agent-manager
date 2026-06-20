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
  };
}

export const refreshTaskBoard = createAsyncThunk('tasks/refreshTaskBoard', async (_, { getState }) => {
  const { session } = (getState() as any).chat;
  if (!session.clientToken) return { chains: [], tasks: [], participants: [] };
  const data = await daemonApi.listTasks({
    daemonUrl: session.daemonUrl,
    clientInstanceId: session.clientInstanceId,
    clientToken: session.clientToken,
  });
  return {
    chains: (data.chains ?? []).map(normalizeChain),
    tasks: (data.tasks ?? []).map(normalizeTask),
    participants: (data.participants ?? []).map(normalizeParticipant),
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
  await (dispatch as any)(refreshTaskBoard());
  return result;
});

export const createChainFromBoard = createAsyncThunk('tasks/createChainFromBoard', async (payload: any, { dispatch, getState }) => {
  const { session } = (getState() as any).chat;
  const result = await daemonApi.createTaskChain({ daemonUrl: session.daemonUrl, ...taskMutationAuth(session, payload.agentToken), ...payload });
  await (dispatch as any)(refreshTaskBoard());
  return result;
});

export const addCommentToSelectedTask = createAsyncThunk('tasks/addCommentToSelectedTask', async (payload: any, { dispatch, getState }) => {
  const state = getState() as any;
  const { session } = state.chat;
  const task = state.tasks.tasksById[payload.taskId || state.tasks.selectedTaskId];
  await daemonApi.addTaskComment({ daemonUrl: session.daemonUrl, ...taskMutationAuth(session, payload.agentToken), taskId: task.taskId, chainId: task.chainId, body: payload.body });
  await (dispatch as any)(refreshTaskBoard());
  await (dispatch as any)(fetchSelectedTaskLog(task.taskId));
});

export const updateSelectedTaskStatus = createAsyncThunk('tasks/updateSelectedTaskStatus', async (payload: any, { dispatch, getState }) => {
  const state = getState() as any;
  const { session } = state.chat;
  const task = state.tasks.tasksById[payload.taskId || state.tasks.selectedTaskId];
  await daemonApi.updateTaskStatus({ daemonUrl: session.daemonUrl, ...taskMutationAuth(session, payload.agentToken), taskId: task.taskId, chainId: task.chainId, status: payload.status, body: payload.body });
  await (dispatch as any)(refreshTaskBoard());
  await (dispatch as any)(fetchSelectedTaskLog(task.taskId));
});

export const assignSelectedTask = createAsyncThunk('tasks/assignSelectedTask', async (payload: any, { dispatch, getState }) => {
  const state = getState() as any;
  const { session } = state.chat;
  const task = state.tasks.tasksById[payload.taskId || state.tasks.selectedTaskId];
  await daemonApi.assignTask({ daemonUrl: session.daemonUrl, ...taskMutationAuth(session, payload.agentToken), taskId: task.taskId, chainId: task.chainId, agentInstanceId: payload.agentInstanceId });
  await (dispatch as any)(refreshTaskBoard());
});

export const addParticipantToSelectedTask = createAsyncThunk('tasks/addParticipantToSelectedTask', async (payload: any, { dispatch, getState }) => {
  const state = getState() as any;
  const { session } = state.chat;
  const task = state.tasks.tasksById[payload.taskId || state.tasks.selectedTaskId];
  await daemonApi.addTaskParticipant({ daemonUrl: session.daemonUrl, ...taskMutationAuth(session, payload.agentToken), taskId: task.taskId, chainId: task.chainId, agentInstanceId: payload.agentInstanceId, role: payload.role });
  await (dispatch as any)(refreshTaskBoard());
});

export const nudgeSelectedTask = createAsyncThunk('tasks/nudgeSelectedTask', async (payload: any, { dispatch, getState }) => {
  const state = getState() as any;
  const { session } = state.chat;
  const task = state.tasks.tasksById[payload.taskId || state.tasks.selectedTaskId];
  const result = await daemonApi.nudgeTask({ daemonUrl: session.daemonUrl, ...taskMutationAuth(session, payload.agentToken), taskId: task.taskId, chainId: task.chainId, body: payload.body });
  await (dispatch as any)(refreshTaskBoard());
  await (dispatch as any)(fetchSelectedTaskLog(task.taskId));
  return result;
});

export const updateSelectedChainMetadata = createAsyncThunk('tasks/updateSelectedChainMetadata', async (payload: any, { dispatch, getState }) => {
  const state = getState() as any;
  const { session } = state.chat;
  const chainId = payload.chainId || state.tasks.selectedChainId;
  await daemonApi.updateTaskChain({ daemonUrl: session.daemonUrl, ...taskMutationAuth(session, payload.agentToken), chainId, title: payload.title, description: payload.description, coordinatorAgentInstanceId: payload.coordinatorAgentInstanceId, defaultReviewerAgentInstanceId: payload.defaultReviewerAgentInstanceId, finalSummary: payload.finalSummary });
  await (dispatch as any)(refreshTaskBoard());
});

export const updateSelectedChainStatus = createAsyncThunk('tasks/updateSelectedChainStatus', async (payload: any, { dispatch, getState }) => {
  const state = getState() as any;
  const { session } = state.chat;
  const chainId = payload.chainId || state.tasks.selectedChainId;
  await daemonApi.updateTaskChainStatus({ daemonUrl: session.daemonUrl, ...taskMutationAuth(session, payload.agentToken), chainId, status: payload.status, finalSummary: payload.finalSummary });
  await (dispatch as any)(refreshTaskBoard());
});

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
        const tasksById: any = {};
        const chainTaskIds: any = {};
        const participantsByTaskId: any = {};

        action.payload.chains.forEach((chain: any) => {
          chainsById[chain.chainId] = chain;
          chainTaskIds[chain.chainId] = [];
        });
        action.payload.tasks.forEach((task: any) => {
          tasksById[task.taskId] = task;
          const chainId = task.chainId || 'standalone';
          if (!chainTaskIds[chainId]) chainTaskIds[chainId] = [];
          chainTaskIds[chainId].push(task.taskId);
        });
        Object.keys(chainTaskIds).forEach((chainId) => {
          chainTaskIds[chainId] = sortTaskIds(chainTaskIds[chainId], tasksById);
        });
        action.payload.participants.forEach((participant: any) => {
          if (!participant.taskId) return;
          if (!participantsByTaskId[participant.taskId]) participantsByTaskId[participant.taskId] = [];
          participantsByTaskId[participant.taskId].push(participant);
        });

        state.chainsById = chainsById;
        state.tasksById = tasksById;
        state.chainTaskIds = chainTaskIds;
        state.participantsByTaskId = participantsByTaskId;
        if (state.selectedTaskId && !tasksById[state.selectedTaskId]) state.selectedTaskId = '';
        if (state.selectedChainId && !chainsById[state.selectedChainId]) state.selectedChainId = '';
        if (!state.selectedChainId) state.selectedChainId = action.payload.chains[0]?.chainId || '';
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
      });
  },
});

export const { selectChain, selectTask, toggleChainExpanded, taskEventReceived } = taskSlice.actions;
export default taskSlice.reducer;
