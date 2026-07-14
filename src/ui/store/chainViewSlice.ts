import { createAsyncThunk, createSlice } from '@reduxjs/toolkit';
import * as daemonApi from '../api/daemonApi';

const OPTIMISTIC_MESSAGE_GRACE_MS = 30_000;

function auth(state: any) {
  const { session } = state.chat;
  return { daemonUrl: session.daemonUrl, clientInstanceId: session.clientInstanceId, clientToken: session.clientToken };
}

export const focusChainView = createAsyncThunk('chainView/focusChainView', async (chainId: string, { dispatch, getState }) => {
  const state = getState() as any;
  const session = auth(state);
  if (!chainId || !session.clientToken) return { chainId, focus: null, workspace: null, chat: null, team: null };
  dispatch(chainViewSlice.actions.chainFocusStarted(chainId));
  const chain = state.tasks.chainsById[chainId];
  const coordinator = chain?.coordinatorAgentInstanceId || '';
  const teamId = chain?.teamId || '';
  const [focus, workspace, chat, team] = await Promise.all([
    daemonApi.focusTaskChain({ ...session, chainId }).catch((err: any) => ({ ok: false, message: err?.message || 'focus failed' })),
    daemonApi.fetchWorkspace({ ...session, chainId }).catch(() => null),
    (coordinator ? daemonApi.fetchChat({ daemonUrl: session.daemonUrl, clientToken: session.clientToken, agentInstanceId: coordinator, chainId, limit: 50 }).catch(() => null) : Promise.resolve(null)),
    (teamId ? daemonApi.fetchTeam({ daemonUrl: session.daemonUrl, teamId }).catch(() => null) : Promise.resolve(null)),
  ]);
  return { chainId, focus, workspace, chat, team };
});

export const revalidateChainView = createAsyncThunk('chainView/revalidateChainView', async (chainId: string, { dispatch }) => {
  await (dispatch as any)(focusChainView(chainId));
  return { chainId, at: Date.now() };
});

export const sendCoordinatorMessage = createAsyncThunk('chainView/sendCoordinatorMessage', async (payload: { chainId: string; body: string; localId: string }, { getState }) => {
  const state = getState() as any;
  const session = auth(state);
  const result = await daemonApi.sendToCoordinator({ ...session, chainId: payload.chainId, body: payload.body });
  return { chainId: payload.chainId, localId: payload.localId, result };
});

export const fetchWorkspaceForChain = createAsyncThunk('chainView/fetchWorkspaceForChain', async (chainId: string, { getState }) => {
  const session = auth(getState() as any);
  if (!chainId || !session.clientToken) return { chainId, workspace: null };
  const workspace = await daemonApi.fetchWorkspace({ ...session, chainId }).catch(() => null);
  return { chainId, workspace };
});

export const previewWorkspaceMerge = createAsyncThunk('chainView/previewWorkspaceMerge', async (chainId: string, { getState }) => {
  const session = auth(getState() as any);
  const preview = await daemonApi.previewWorkspaceMerge({ ...session, chainId }).catch((err: any) => ({ ok: false, message: err?.message || 'preview failed' }));
  return { chainId, preview };
});

export const fetchWorkspaceDiff = createAsyncThunk('chainView/fetchWorkspaceDiff', async (payload: { chainId: string; file?: string }, { getState }) => {
  const session = auth(getState() as any);
  if (!payload.chainId || !session.clientToken) return { chainId: payload.chainId, file: payload.file || '', diff: null };
  const diff = await daemonApi.fetchWorkspaceDiff({ ...session, chainId: payload.chainId, file: payload.file }).catch(() => null);
  return { chainId: payload.chainId, file: payload.file || '', diff };
});

export const loadAgentSideSheet = createAsyncThunk('chainView/loadAgentSideSheet', async (agentId: string, { getState }) => {
  const state = getState() as any;
  const session = auth(state);
  const agent = (state.chat.agents || []).find((item: any) => item.id === agentId) || null;
  const focusedChainId = state.chainView.focusedChainId || '';
  const chainTaskIds = state.tasks.chainTaskIds?.[focusedChainId] || [];
  const assignedTask = chainTaskIds.map((taskId: string) => state.tasks.tasksById?.[taskId]).find((task: any) => task?.assigneeAgentInstanceId === agentId);
  const taskId = agent?.currentTaskId || assignedTask?.taskId || '';
  if (!taskId || !session.clientToken) return { agentId, taskId, task: null, comments: [] };
  const [task, comments] = await Promise.all([
    daemonApi.fetchTask({ daemonUrl: session.daemonUrl, clientToken: session.clientToken, taskId }).catch(() => null),
    daemonApi.fetchTaskComments({ daemonUrl: session.daemonUrl, clientToken: session.clientToken, taskId }).catch(() => null),
  ]);
  const allComments = comments?.comments || [];
  return { agentId, taskId, task: task?.task || null, comments: allComments.slice(-3) };
});

const initialState = {
  focusedChainId: '',
  focusByChainId: {} as Record<string, any>,
  workspaceByChainId: {} as Record<string, any>,
  teamByChainId: {} as Record<string, any>,
  chatByChainId: {} as Record<string, any[]>,
  optimisticMessagesByChainId: {} as Record<string, any[]>,
  mergePreviewByChainId: {} as Record<string, any>,
  workspaceDiffByChainId: {} as Record<string, Record<string, any>>,
  diffOpenByChainId: {} as Record<string, boolean>,
  sideSheetAgentId: '',
  sideSheetByAgentId: {} as Record<string, any>,
  lastFocusedAt: 0,
  lastHttpLoadByChainId: {} as Record<string, number>,
  lastPeriodicRefreshByChainId: {} as Record<string, number>,
  lastWsRefreshReason: '',
  lastLocalAction: '',
  loading: false,
  error: '',
};

const chainViewSlice = createSlice({
  name: 'chainView',
  initialState,
  reducers: {
    chainFocusStarted(state: any, action) {
      state.focusedChainId = action.payload || '';
      state.lastFocusedAt = Date.now();
      state.lastLocalAction = `focus:${state.focusedChainId}`;
    },
    toggleWorkspaceDiff(state: any, action) {
      const chainId = action.payload || state.focusedChainId;
      state.diffOpenByChainId[chainId] = !state.diffOpenByChainId[chainId];
      state.lastLocalAction = `toggleDiff:${chainId}`;
    },
    openAgentSideSheet(state: any, action) {
      state.sideSheetAgentId = action.payload || '';
      state.lastLocalAction = `openAgent:${state.sideSheetAgentId}`;
    },
    closeAgentSideSheet(state: any) {
      state.sideSheetAgentId = '';
      state.lastLocalAction = 'closeAgent';
    },
    optimisticCoordinatorMessage(state: any, action) {
      const { chainId, body } = action.payload || {};
      if (!chainId || !body) return;
      if (!state.optimisticMessagesByChainId[chainId]) state.optimisticMessagesByChainId[chainId] = [];
      state.optimisticMessagesByChainId[chainId].push({ id: action.payload?.localId || `local_${Date.now()}`, localId: action.payload?.localId || '', body, author: 'user', sending: true, createdUnixMs: Date.now() });
      state.lastLocalAction = `sendCoordinator:${chainId}`;
    },
    wsChainViewRefreshRequested(state: any, action) {
      state.lastWsRefreshReason = action.payload || 'ws';
    },
  },
  extraReducers: (builder) => {
    builder
      .addCase(focusChainView.pending, (state: any) => { state.loading = true; state.error = ''; })
      .addCase(focusChainView.fulfilled, (state: any, action) => {
        const { chainId, focus, workspace, chat, team } = action.payload;
        state.loading = false;
        if (!chainId) return;
        state.focusByChainId[chainId] = focus;
        if (workspace?.workspace) state.workspaceByChainId[chainId] = workspace.workspace;
        if (team?.team) state.teamByChainId[chainId] = team;
        if (chat?.messages) {
          state.chatByChainId[chainId] = chat.messages;
          const serverIds = new Set(chat.messages.map((m: any) => m.message_id || m.id).filter(Boolean));
          const now = Date.now();
          state.optimisticMessagesByChainId[chainId] = (state.optimisticMessagesByChainId[chainId] || []).filter((m: any) => {
            if (m.messageId && serverIds.has(m.messageId)) return false;
            // Keep recently delivered optimistic messages briefly. A focus/revalidate
            // request can race ahead of chat persistence/read-your-write visibility;
            // dropping non-sending optimistic rows immediately makes the message
            // disappear until a later restart/refetch.
            const lastLocalAt = Number(m.deliveredUnixMs || m.createdUnixMs || 0);
            return Boolean(m.sending) || (lastLocalAt > 0 && now - lastLocalAt < OPTIMISTIC_MESSAGE_GRACE_MS);
          });
        }
        state.lastHttpLoadByChainId[chainId] = Date.now();
      })
      .addCase(focusChainView.rejected, (state: any, action) => { state.loading = false; state.error = action.error.message || 'Failed to load chain'; })
      .addCase(revalidateChainView.fulfilled, (state: any, action) => { if (action.payload.chainId) state.lastPeriodicRefreshByChainId[action.payload.chainId] = action.payload.at; })
      .addCase(sendCoordinatorMessage.pending, (state: any) => {
        state.error = '';
      })
      .addCase(sendCoordinatorMessage.fulfilled, (state: any, action) => {
        const { chainId, localId, result } = action.payload;
        const pending = state.optimisticMessagesByChainId[chainId] || [];
        const messageId = result?.message_id || '';
        state.optimisticMessagesByChainId[chainId] = pending.map((m: any) => {
          if (m.id !== localId && m.localId !== localId) return m;
          return {
            ...m,
            id: messageId || m.id,
            message_id: messageId || m.id,
            messageId: messageId || m.id,
            sending: false,
            deliveredUnixMs: Number(m.deliveredUnixMs || Date.now()),
            deliveryFailedUnixMs: 0,
            deliveryError: '',
          };
        });
        state.lastLocalAction = `sentCoordinator:${chainId}`;
      })
      .addCase(sendCoordinatorMessage.rejected, (state: any, action) => {
        const { chainId, localId } = action.meta.arg || {};
        const errorMessage = action.error.message || 'Failed to send coordinator message';
        const pending = state.optimisticMessagesByChainId[chainId] || [];
        state.optimisticMessagesByChainId[chainId] = pending.map((m: any) => {
          if (m.id !== localId && m.localId !== localId) return m;
          return {
            ...m,
            sending: false,
            deliveryFailedUnixMs: Date.now(),
            deliveryError: errorMessage,
          };
        });
        state.error = errorMessage;
        state.lastLocalAction = `sendCoordinatorFailed:${chainId}`;
      })
      .addCase(fetchWorkspaceForChain.fulfilled, (state: any, action) => { if (action.payload.chainId && action.payload.workspace?.workspace) state.workspaceByChainId[action.payload.chainId] = action.payload.workspace.workspace; })
      .addCase(previewWorkspaceMerge.fulfilled, (state: any, action) => { if (action.payload.chainId) state.mergePreviewByChainId[action.payload.chainId] = action.payload.preview; })
      .addCase(fetchWorkspaceDiff.fulfilled, (state: any, action) => {
        if (action.payload.chainId && action.payload.diff) {
          if (!state.workspaceDiffByChainId[action.payload.chainId]) {
            state.workspaceDiffByChainId[action.payload.chainId] = {};
          }
          state.workspaceDiffByChainId[action.payload.chainId][action.payload.file || ''] = action.payload.diff;
        }
      })
      .addCase(loadAgentSideSheet.pending, (state: any, action) => { state.sideSheetAgentId = action.meta.arg || ''; state.lastLocalAction = `openAgent:${state.sideSheetAgentId}`; })
      .addCase(loadAgentSideSheet.fulfilled, (state: any, action) => { if (action.payload.agentId) state.sideSheetByAgentId[action.payload.agentId] = action.payload; });
  },
});

export const {
  chainFocusStarted,
  toggleWorkspaceDiff,
  openAgentSideSheet,
  closeAgentSideSheet,
  optimisticCoordinatorMessage,
  wsChainViewRefreshRequested,
} = chainViewSlice.actions;

export default chainViewSlice.reducer;
