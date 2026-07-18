import { createAsyncThunk, createSlice } from '@reduxjs/toolkit';
import * as daemonApi from '../api/daemonApi';
import { selectCachedChainById } from '../api/chainViewCache';
import { fetchSelectedChat, appendMessage } from './chatSlice';

function auth(state: any) {
  const { session } = state.chat;
  return { daemonUrl: session.daemonUrl, clientInstanceId: session.clientInstanceId, clientToken: session.clientToken };
}

export const fetchChainCoordinatorChatPage = createAsyncThunk('chainView/fetchChainCoordinatorChatPage', async (payload: { chainId: string; cursor?: number; limit?: number }, { dispatch, getState }) => {
  const state = getState() as any;
  const session = auth(state);
  const chainId = payload.chainId || '';
  const chain = selectCachedChainById(state, chainId);
  const coordinator = chain?.coordinatorAgentInstanceId || chain?.coordinator_agent_instance_id || '';
  if (!chainId || !coordinator || !session.clientToken) return { chainId, messages: [], nextCursor: 0, isAppend: false };
  const cursor = Number(payload.cursor || 0);
  return await (dispatch as any)(fetchSelectedChat({ agentId: coordinator, cursor, limit: payload.limit || 50 })).unwrap();
});

export const sendCoordinatorMessage = createAsyncThunk('chainView/sendCoordinatorMessage', async (payload: { chainId: string; body: string; localId: string }, { dispatch, getState }) => {
  const state = getState() as any;
  const session = auth(state);
  const chain = selectCachedChainById(state, payload.chainId);
  const coordinatorAgentInstanceId = chain?.coordinatorAgentInstanceId || chain?.coordinator_agent_instance_id || '';
  if (coordinatorAgentInstanceId) {
    dispatch(appendMessage({
      agentId: coordinatorAgentInstanceId,
      message: {
        id: payload.localId,
        author: 'user',
        body: payload.body,
        createdUnixMs: Date.now(),
        deliveredUnixMs: 0,
        readUnixMs: 0,
        sending: true,
        optimistic: true,
      },
    }));
  }
  const result = await daemonApi.sendToCoordinator({
    daemonUrl: session.daemonUrl,
    clientInstanceId: session.clientInstanceId,
    clientToken: session.clientToken,
    chainId: payload.chainId,
    body: payload.body,
  });
  if (coordinatorAgentInstanceId && result?.message_id) {
    dispatch(appendMessage({
      agentId: coordinatorAgentInstanceId,
      message: {
        id: result.message_id,
        author: 'user',
        body: payload.body,
        createdUnixMs: Date.now(),
        deliveredUnixMs: Number(result.delivered_unix_ms || 0),
        readUnixMs: 0,
      },
    }));
  }
  return { chainId: payload.chainId, localId: payload.localId, result: { message_id: result?.message_id || '' }, coordinatorAgentInstanceId };
});

const initialState = {
  focusedChainId: '',
  diffOpenByChainId: {} as Record<string, boolean>,
  sideSheetAgentId: '',
  lastFocusedAt: 0,
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
    wsChainViewRefreshRequested(state: any, action) {
      state.lastWsRefreshReason = action.payload || 'ws';
    },
  },
  extraReducers: (builder) => {
    builder
      .addCase(fetchChainCoordinatorChatPage.rejected, (state: any, action) => {
        state.error = action.error.message || 'Failed to load coordinator chat page';
      })
      .addCase(sendCoordinatorMessage.pending, (state: any) => {
        state.error = '';
      })
      .addCase(sendCoordinatorMessage.fulfilled, (state: any, action) => {
        const { chainId } = action.payload;
        state.lastLocalAction = `sentCoordinator:${chainId}`;
      })
      .addCase(sendCoordinatorMessage.rejected, (state: any, action) => {
        const { chainId } = action.meta.arg || {};
        const errorMessage = action.error.message || 'Failed to send coordinator message';
        state.error = errorMessage;
        state.lastLocalAction = `sendCoordinatorFailed:${chainId}`;
      });
  },
});

export const {
  chainFocusStarted,
  toggleWorkspaceDiff,
  openAgentSideSheet,
  closeAgentSideSheet,
  wsChainViewRefreshRequested,
} = chainViewSlice.actions;

export default chainViewSlice.reducer;
