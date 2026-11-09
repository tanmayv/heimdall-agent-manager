import { createSlice } from '@reduxjs/toolkit';
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
    if (view === 'library') return { surface: 'library', chainId };
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
  lastLocalAction: '',
  lastWsRefreshReason: '',
  lastHttpLoadUnixMs: 0,
  lastPeriodicRefreshUnixMs: 0,
};

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
      state.lastLocalAction = 'openNewChainModal';
    },
    closeNewChainModal(state: any) {
      state.newChainModalOpen = false;
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
