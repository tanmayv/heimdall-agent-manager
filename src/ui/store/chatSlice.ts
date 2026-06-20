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
  return `heimdall-${suffix}`;
}

function createClientInstanceId() {
  const existing = getStoredValue('odin.clientInstanceId', '');
  if (existing) return existing;
  const clientInstanceId = newClientInstanceId();
  setStoredValue('odin.clientInstanceId', clientInstanceId);
  return clientInstanceId;
}

function loadKnownAgents(): any[] {
  try {
    return JSON.parse(window.localStorage.getItem('odin.knownAgents') || '[]');
  } catch {
    return [];
  }
}

function storeKnownAgents(agents: any[]) {
  try {
    window.localStorage.setItem('odin.knownAgents', JSON.stringify(agents));
  } catch {
    // Local known-agent records are a UI convenience when daemon persistence is unavailable.
  }
}

function safeStartupStatus(agent: any) {
  const status = agent.startup_status || agent.startupStatus || agent.lifecycle_state || agent.lifecycleState || '';
  if (status === 'startup_blocked' || status === 'startup_failed' || status === 'startup_unknown' || status === 'starting') return status;
  return '';
}

function mapAgent(agent: any) {
  const lastSeenUnixMs = Number(agent.last_seen_unix_ms ?? agent.lastSeenUnixMs ?? 0);
  const startupStatus = safeStartupStatus(agent);
  return {
    id: agent.agent_instance_id || agent.agentInstanceId || agent.id,
    label: agent.display_name || agent.displayName || agent.alias || agent.agent_instance_id || agent.id,
    status: startupStatus || (agent.connected ? 'connected' : 'offline'),
    startupStatus,
    startupReason: agent.safe_diagnostic || agent.safeDiagnostic || agent.startup_safe_diagnostic || agent.startupSafeDiagnostic || agent.reason || agent.startup_reason_code || agent.startupReasonCode || agent.reason_code || agent.reasonCode || '',
    startupSuggestedFix: agent.suggested_fix || agent.suggestedFix || '',
    runDir: agent.run_dir || agent.runDir || '',
    tmuxTarget: agent.tmux_pane || agent.tmuxPane || agent.tmux_target || agent.tmuxTarget || '',
    logPath: agent.log_path || agent.logPath || agent.wrapper_log || agent.wrapperLog || '',
    lastSeenUnixMs,
    lastSeen: lastSeenUnixMs ? new Date(lastSeenUnixMs).toLocaleString([], { month: 'short', day: 'numeric', hour: '2-digit', minute: '2-digit' }) : '—',
    conversationId: agent.conversation_id || agent.conversationId,
    unreadCount: agent.unreadCount || 0,
    projectId: agent.project_id || agent.projectId || '',
    templateId: agent.template_id || agent.templateId || '',
    providerProfile: agent.provider_profile || agent.providerProfile || agent.agent_class || '',
    roleHint: agent.role_hint || agent.roleHint || '',
    known: agent.known ?? true,
  };
}

function metadataOnlyAgent(agent: any) {
  return {
    ...agent,
    connected: false,
    status: 'offline',
    startup_status: '',
    startupStatus: '',
    lifecycle_state: '',
    lifecycleState: '',
  };
}

function mergeKnownAndLiveAgents(localKnownAgents: any[], daemonKnownAgents: any[], liveAgents: any[]) {
  const byId: any = {};
  for (const agent of localKnownAgents.map((item) => mapAgent(metadataOnlyAgent(item)))) {
    if (agent.id) byId[agent.id] = { ...agent, status: 'offline', startupStatus: '', known: true };
  }
  for (const daemonAgent of daemonKnownAgents.map(mapAgent)) {
    if (!daemonAgent.id) continue;
    byId[daemonAgent.id] = { ...(byId[daemonAgent.id] || {}), ...daemonAgent, status: daemonAgent.startupStatus || 'offline', known: true };
  }
  for (const live of liveAgents.map(mapAgent)) {
    if (!live.id) continue;
    const existing = byId[live.id] || {};
    const liveLabelLooksLikeId = !live.label || live.label === live.id;
    byId[live.id] = {
      ...existing,
      ...live,
      label: liveLabelLooksLikeId ? (existing.label || live.label) : live.label,
      projectId: live.projectId || existing.projectId || '',
      templateId: live.templateId || existing.templateId || '',
      providerProfile: live.providerProfile || existing.providerProfile || '',
      roleHint: live.roleHint || existing.roleHint || '',
      status: live.status,
      known: true,
    };
  }
  return Object.values(byId).sort((left: any, right: any) => {
    if (left.status !== right.status) return left.status === 'connected' ? -1 : right.status === 'connected' ? 1 : left.status.localeCompare(right.status);
    return (right.lastSeenUnixMs || 0) - (left.lastSeenUnixMs || 0);
  });
}

function mapMessage(message: any) {
  const createdTime = message.created_unix_ms ? new Date(message.created_unix_ms).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' }) : '';
  const deliveredUnixMs = Number(message.delivered_unix_ms || 0);
  const readUnixMs = Number(message.read_unix_ms || 0);
  return {
    id: message.message_id,
    author: message.direction === 'user_to_agent' ? 'user' : 'agent',
    body: message.body,
    timestamp: createdTime,
    deliveredAt: deliveredUnixMs > 0 ? new Date(deliveredUnixMs).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' }) : '',
    deliveredUnixMs,
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
  const localKnown = loadKnownAgents();
  let daemonKnown: any[] = [];
  try {
    daemonKnown = await daemonApi.listKnownAgents({ daemonUrl });
  } catch {
    daemonKnown = [];
  }
  const liveAgents = await daemonApi.listConnectedAgents({ daemonUrl });
  const merged = mergeKnownAndLiveAgents(localKnown, daemonKnown, liveAgents);
  storeKnownAgents(merged);
  return merged;
});

export const fetchSelectedChat = createAsyncThunk('chat/fetchSelectedChat', async (agentId: string | undefined, { getState }) => {
  const { session, selectedAgentId } = (getState() as any).chat;
  const agentInstanceId = agentId || selectedAgentId;
  if (!agentInstanceId || !session.clientToken) return { agentId: agentInstanceId, messages: [], markedRead: false };
  const isOpenChat = agentInstanceId === selectedAgentId;
  if (isOpenChat) {
    await daemonApi.markChatRead({
      daemonUrl: session.daemonUrl,
      clientInstanceId: session.clientInstanceId,
      clientToken: session.clientToken,
      agentInstanceId,
    });
  }
  const data = await daemonApi.fetchChat({
    daemonUrl: session.daemonUrl,
    clientInstanceId: session.clientInstanceId,
    clientToken: session.clientToken,
    agentInstanceId,
  });
  return { agentId: agentInstanceId, messages: (data.messages ?? []).map(mapMessage), markedRead: isOpenChat };
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
    upsertKnownAgent(state, action) {
      const mapped: any = mapAgent(action.payload);
      if (!mapped.id) return;
      const existingIndex = state.agents.findIndex((agent) => agent.id === mapped.id);
      if (existingIndex >= 0) state.agents[existingIndex] = { ...state.agents[existingIndex], ...mapped, known: true } as never;
      else state.agents.unshift(mapped as never);
      storeKnownAgents(state.agents);
    },
    agentLifecycleEventReceived(state, action) {
      const payload = action.payload || {};
      const agentPayload = payload.agent || payload.record || payload;
      const agentId = agentPayload.agent_instance_id || agentPayload.agentInstanceId || payload.agent_instance_id || payload.agentInstanceId;
      if (!agentId) return;
      const mapped: any = mapAgent({ ...agentPayload, agent_instance_id: agentId });
      const existingIndex = state.agents.findIndex((agent) => agent.id === agentId);
      if (existingIndex >= 0) {
        const existing: any = state.agents[existingIndex];
        const mappedLabelLooksLikeId = !mapped.label || mapped.label === mapped.id;
        state.agents[existingIndex] = {
          ...existing,
          ...mapped,
          label: mappedLabelLooksLikeId ? (existing.label || mapped.label) : mapped.label,
          projectId: mapped.projectId || existing.projectId || '',
          templateId: mapped.templateId || existing.templateId || '',
          providerProfile: mapped.providerProfile || existing.providerProfile || '',
          roleHint: mapped.roleHint || existing.roleHint || '',
          known: true,
        } as never;
      } else {
        state.agents.unshift({ ...mapped, known: true } as never);
      }
      storeKnownAgents(state.agents);
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
          if (action.payload.markedRead) {
            const agent = state.agents.find((item) => item.id === action.payload.agentId);
            if (agent) agent.unreadCount = 0;
          }
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

export const { selectAgent, setDaemonUrl, updateSessionConfig, userWsConnecting, userWsConnected, userWsDisconnected, userWsError, chatEventReceived, upsertKnownAgent, agentLifecycleEventReceived } = chatSlice.actions;
export default chatSlice.reducer;
