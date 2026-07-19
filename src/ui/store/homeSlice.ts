import { createAsyncThunk, createSlice } from '@reduxjs/toolkit';
import * as daemonApi from '../api/daemonApi';
import { workspaceApi } from '../api/endpoints/workspace';
import { getRouteSearch } from '../utils/appLocation';

function initialUrlState() {
  try {
    const params = new URLSearchParams(getRouteSearch());
    const chainId = params.get('chainId') || '';
    const view = params.get('view') || '';
    if (view === 'memory') return { surface: 'memory', chainId };
    if (view === 'attention') return { surface: 'attention', chainId };
    if (view === 'settings') return { surface: 'settings', chainId };
    if (view === 'agents') return { surface: 'agents', chainId };
    if (view === 'task-chains') return { surface: 'task-chains', chainId };
    if (view === 'projects') return { surface: 'projects', chainId };
    if (view === 'chain' || chainId) return { surface: 'chain', chainId };
    return { surface: 'home', chainId: '' };
  } catch (_err) {
    return { surface: 'home', chainId: '' };
  }
}

const initialUrl = initialUrlState();

const initialState = {
  surface: initialUrl.surface,
  selectedProjectId: '',
  selectedChainId: initialUrl.chainId,
  newChainModalOpen: false,
  newChainCreating: false,
  newChainError: '',
  lastCreatedChainId: '',
  lastLocalAction: '',
  lastWsRefreshReason: '',
  lastHttpLoadUnixMs: 0,
  lastPeriodicRefreshUnixMs: 0,
};

// TODO(rtkq-migration owner=task-19f69e242e4): new-chain creation still performs a board refresh to surface the created chain in the home overview. Keep this quarantined to creation flow; do not expand it into task/chat recurring cache ownership.
export const submitNewChain = createAsyncThunk('home/submitNewChain', async (payload: any, { dispatch, getState }) => {
  const state = getState() as any;
  const { session } = state.chat;
  if (!session.clientToken) throw new Error('Not connected to daemon');
  const result = await daemonApi.createTaskChain({
    daemonUrl: session.daemonUrl,
    clientInstanceId: session.clientInstanceId,
    clientToken: session.clientToken,
    project_id: payload.projectId || '',
    title: payload.title || '',
    description: payload.goal || payload.description || '',
    wants_vcs: Boolean(payload.wantsVcs),
    coordinator_agent_instance_id: payload.coordinatorAgentInstanceId || '',
  });
  const chainId = result?.chain_id || result?.chainId || '';
  let activation: any = null;
  if (chainId) {
    activation = await daemonApi.updateTaskChainStatus({
      daemonUrl: session.daemonUrl,
      clientInstanceId: session.clientInstanceId,
      clientToken: session.clientToken,
      chainId,
      status: 'in_progress',
    });
  }
  await (dispatch as any)(workspaceApi.endpoints.listChains.initiate(undefined, { subscribe: false, forceRefetch: true })).catch(() => undefined);
  return { ...result, activation, chainId };
});

const homeSlice = createSlice({
  name: 'home',
  initialState,
  reducers: {
    selectSurface(state: any, action) {
      state.surface = action.payload || 'home';
      state.lastLocalAction = `selectSurface:${state.surface}`;
    },
    selectProject(state: any, action) {
      state.selectedProjectId = action.payload || '';
      state.lastLocalAction = `selectProject:${state.selectedProjectId}`;
    },
    selectChain(state: any, action) {
      state.selectedChainId = action.payload || '';
      state.surface = action.payload ? 'chain' : 'home';
      state.lastLocalAction = `selectChain:${state.selectedChainId}`;
    },
    openNewChainModal(state: any, action) {
      state.selectedProjectId = action.payload?.projectId || state.selectedProjectId || '';
      state.newChainModalOpen = true;
      state.newChainError = '';
      state.lastLocalAction = 'openNewChainModal';
    },
    closeNewChainModal(state: any) {
      state.newChainModalOpen = false;
      state.newChainError = '';
      state.lastLocalAction = 'closeNewChainModal';
    },
    httpLoadCompleted(state: any, action) {
      state.lastHttpLoadUnixMs = action.payload?.at || Date.now();
      if (action.payload?.periodic) state.lastPeriodicRefreshUnixMs = state.lastHttpLoadUnixMs;
    },
    wsRefreshRequested(state: any, action) {
      state.lastWsRefreshReason = action.payload || 'ws';
    },
  },
  extraReducers: (builder) => {
    builder
      .addCase(submitNewChain.pending, (state: any) => {
        state.newChainCreating = true;
        state.newChainError = '';
        state.lastLocalAction = 'submitNewChain';
      })
      .addCase(submitNewChain.fulfilled, (state: any, action) => {
        state.newChainCreating = false;
        state.newChainModalOpen = false;
        state.lastCreatedChainId = action.payload?.chainId || '';
        state.lastLocalAction = `createdChain:${state.lastCreatedChainId || 'unknown'}`;
      })
      .addCase(submitNewChain.rejected, (state: any, action) => {
        state.newChainCreating = false;
        state.newChainError = action.error.message || 'Failed to create chain';
      });
  },
});

export const {
  selectSurface,
  selectProject,
  selectChain,
  openNewChainModal,
  closeNewChainModal,
  httpLoadCompleted,
  wsRefreshRequested,
} = homeSlice.actions;

export default homeSlice.reducer;
