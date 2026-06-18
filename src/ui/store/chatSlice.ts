import { createAsyncThunk, createSlice } from '@reduxjs/toolkit';
import * as daemonApi from '../api/daemonApi';

const DEFAULT_DAEMON_URL = 'http://127.0.0.1:49322';
const DEFAULT_USER_ID = 'operator@local';

function getStoredValue(key: string, fallback: string): string {
  try {
    return window.localStorage.getItem(key) || fallback;
  } catch {
    return fallback;
  }
}

function setStoredValue(key: string, value: string): void {
  try {
    window.localStorage.setItem(key, value);
  } catch {
    // Local storage is only a convenience for this UI session.
  }
}

function newClientInstanceId(): string {
  const suffix = globalThis.crypto?.randomUUID?.() ?? `${Date.now()}-${Math.random().toString(16).slice(2)}`;
  return `odin-ui-${suffix}`;
}

function createClientInstanceId() {
  const existing = getStoredValue('odin.clientInstanceId', '');
  if (existing) return existing;
  const clientInstanceId = newClientInstanceId();
  setStoredValue('odin.clientInstanceId', clientInstanceId);
  return clientInstanceId;
}

function mapAgent(agent: any) {
  return {
    id: agent.agent_instance_id,
    label: agent.display_name || agent.agent_instance_id,
    status: agent.connected ? 'connected' : 'offline',
    lastSeenUnixMs: agent.last_seen_unix_ms ?? 0,
    conversationId: agent.conversation_id,
    unreadCount: 0,
  };
}

function mapMessage(message: any) {
  const createdTime = message.created_unix_ms ? new Date(message.created_unix_ms).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' }) : '';
  const readUnixMs = Number(message.read_unix_ms || 0);
  return {
    id: message.message_id,
    author: message.direction === 'user_to_agent' ? 'user' : 'agent',
    body: message.body,
    timestamp: createdTime,
    readAt: readUnixMs > 0 ? new Date(readUnixMs).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' }) : '',
    readUnixMs,
  };
}

export const registerSession = createAsyncThunk('chat/registerSession', async (_, { getState }) => {
  const { session } = (getState() as any).chat;
  return daemonApi.registerUserClient(session);
});

export const refreshAgents = createAsyncThunk('chat/refreshAgents', async (_, { getState }) => {
  const { daemonUrl } = (getState() as any).chat.session;
  const agents = await daemonApi.listConnectedAgents({ daemonUrl });
  return agents.map(mapAgent);
});

export const fetchSelectedChat = createAsyncThunk('chat/fetchSelectedChat', async (agentId: string | undefined, { getState }) => {
  const { session, selectedAgentId } = (getState() as any).chat;
  const agentInstanceId = agentId || selectedAgentId;
  if (!agentInstanceId || !session.clientToken) return { agentId: agentInstanceId, messages: [] };
  const data = await daemonApi.fetchChat({
    daemonUrl: session.daemonUrl,
    clientInstanceId: session.clientInstanceId,
    clientToken: session.clientToken,
    agentInstanceId,
  });
  return { agentId: agentInstanceId, messages: (data.messages ?? []).map(mapMessage) };
});

export const sendMessageToSelectedAgent = createAsyncThunk('chat/sendMessageToSelectedAgent', async (body: string, { dispatch, getState }) => {
  const { session, selectedAgentId } = (getState() as any).chat;
  await daemonApi.sendToAgent({
    daemonUrl: session.daemonUrl,
    clientInstanceId: session.clientInstanceId,
    clientToken: session.clientToken,
    agentInstanceId: selectedAgentId,
    body,
  });
  await (dispatch as any)(fetchSelectedChat(selectedAgentId));
});

const initialState = {
  session: {
    daemonUrl: getStoredValue('odin.daemonUrl', DEFAULT_DAEMON_URL),
    userId: getStoredValue('odin.userId', DEFAULT_USER_ID),
    clientInstanceId: createClientInstanceId(),
    clientToken: getStoredValue('odin.clientToken', ''),
    connected: false,
    status: 'idle',
    wsStatus: 'idle',
    wsConnected: false,
    lastChatEvent: null,
    error: '',
  },
  selectedAgentId: '',
  agents: [],
  chats: {},
  sending: false,
};

const chatSlice = createSlice({
  name: 'chat',
  initialState,
  reducers: {
    selectAgent(state, action) {
      state.selectedAgentId = action.payload;
    },
    setDaemonUrl(state, action) {
      state.session.daemonUrl = action.payload;
      setStoredValue('odin.daemonUrl', action.payload);
    },
    updateSessionConfig(state, action) {
      const daemonUrl = action.payload.daemonUrl?.trim() || DEFAULT_DAEMON_URL;
      const userId = action.payload.userId?.trim() || DEFAULT_USER_ID;
      const userChanged = userId !== state.session.userId;
      state.session.daemonUrl = daemonUrl;
      state.session.userId = userId;
      state.session.connected = false;
      state.session.status = 'idle';
      state.session.wsConnected = false;
      state.session.wsStatus = 'idle';
      state.session.error = '';
      if (userChanged) {
        state.session.clientInstanceId = newClientInstanceId();
        state.session.clientToken = '';
        setStoredValue('odin.clientInstanceId', state.session.clientInstanceId);
        setStoredValue('odin.clientToken', '');
      }
      setStoredValue('odin.daemonUrl', daemonUrl);
      setStoredValue('odin.userId', userId);
    },
    userWsConnecting(state) {
      state.session.wsStatus = 'connecting';
      state.session.wsConnected = false;
      if (state.session.error === 'User WebSocket connection error' || state.session.error === 'User WebSocket disconnected') {
        state.session.error = '';
      }
    },
    userWsConnected(state) {
      state.session.wsStatus = 'connected';
      state.session.wsConnected = true;
      if (state.session.error === 'User WebSocket connection error' || state.session.error === 'User WebSocket disconnected') {
        state.session.error = '';
      }
    },
    userWsDisconnected(state) {
      state.session.wsStatus = 'reconnecting';
      state.session.wsConnected = false;
    },
    userWsError(state, action) {
      state.session.wsStatus = 'error';
      state.session.wsConnected = false;
      state.session.error = action.payload || 'User WebSocket disconnected';
    },
    chatEventReceived(state, action) {
      state.session.lastChatEvent = action.payload;
      const agentId = action.payload?.agent_instance_id;
      if (agentId) {
        const agent = state.agents.find((item) => item.id === agentId);
        if (agent) agent.unreadCount = action.payload.unread_count ?? agent.unreadCount;
      }
    },
  },
  extraReducers: (builder) => {
    builder
      .addCase(registerSession.pending, (state) => {
        state.session.status = 'connecting';
        state.session.error = '';
      })
      .addCase(registerSession.fulfilled, (state, action) => {
        state.session.status = 'connected';
        state.session.connected = true;
        state.session.wsStatus = 'idle';
        state.session.userId = action.payload.user_id;
        state.session.clientInstanceId = action.payload.client_instance_id;
        state.session.clientToken = action.payload.client_token;
        setStoredValue('odin.userId', action.payload.user_id);
        setStoredValue('odin.clientInstanceId', action.payload.client_instance_id);
        setStoredValue('odin.clientToken', action.payload.client_token);
      })
      .addCase(registerSession.rejected, (state, action) => {
        state.session.status = 'error';
        state.session.connected = false;
        state.session.wsStatus = 'error';
        state.session.error = action.error.message || 'Failed to register user client';
      })
      .addCase(refreshAgents.fulfilled, (state, action) => {
        state.agents = action.payload;
        if (!state.selectedAgentId || !state.agents.some((agent) => agent.id === state.selectedAgentId)) {
          state.selectedAgentId = state.agents[0]?.id ?? '';
        }
      })
      .addCase(refreshAgents.rejected, (state, action) => {
        state.session.error = action.error.message || 'Failed to load agents';
      })
      .addCase(fetchSelectedChat.fulfilled, (state, action) => {
        if (action.payload.agentId) {
          state.chats[action.payload.agentId] = action.payload.messages;
        }
      })
      .addCase(fetchSelectedChat.rejected, (state, action) => {
        state.session.error = action.error.message || 'Failed to fetch chat';
      })
      .addCase(sendMessageToSelectedAgent.pending, (state) => {
        state.sending = true;
        state.session.error = '';
      })
      .addCase(sendMessageToSelectedAgent.fulfilled, (state) => {
        state.sending = false;
      })
      .addCase(sendMessageToSelectedAgent.rejected, (state, action) => {
        state.sending = false;
        state.session.error = action.error.message || 'Failed to send message';
      });
  },
});

export const { selectAgent, setDaemonUrl, updateSessionConfig, userWsConnecting, userWsConnected, userWsDisconnected, userWsError, chatEventReceived } = chatSlice.actions;
export default chatSlice.reducer;
