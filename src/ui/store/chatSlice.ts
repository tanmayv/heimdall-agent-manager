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
  const execState = agent.exec_state || agent.execState || '';
  const execStateSinceUnixMs = Number(agent.exec_state_since_unix_ms ?? agent.execStateSinceUnixMs ?? 0);
  const blockedReason = agent.blocked_reason || agent.blockedReason || '';

  let status = 'offline';
  if (startupStatus) {
    status = startupStatus;
  } else if (agent.connected) {
    if (execState === 'running') {
      status = 'connected';
    } else if (execState === 'blocked') {
      status = 'startup_blocked';
    } else if (execState === 'idle') {
      status = 'idle';
    } else {
      status = 'connected'; // Fallback
    }
  }

  return {
    id: agent.agent_instance_id || agent.agentInstanceId || agent.id,
    label: agent.display_name || agent.displayName || agent.alias || agent.agent_instance_id || agent.id,
    status,
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
    projectName: agent.project_name || agent.projectName || '',
    templateId: agent.template_id || agent.templateId || '',
    providerProfile: agent.provider_profile || agent.providerProfile || agent.agent_class || '',
    roleHint: agent.role_hint || agent.roleHint || '',
    modelTier: agent.model_tier || agent.modelTier || 'normal',
    known: agent.known ?? true,
    execState,
    execStateSinceUnixMs,
    blockedReason,
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

// Merge persisted-and-live agent records from /agents with the UI's localStorage
// cache (so the sidebar isn't blank during a daemon round-trip). /agents already
// embeds live registry fields (connected, tmux_pane, startup_status, etc.) when
// a wrapper is up, so we no longer need a second /clients fetch.
function mergeKnownAndLiveAgents(localKnownAgents: any[], daemonAgents: any[], daemonReachable = false) {
  const byId: any = {};
  const daemonIds = new Set<string>();
  if (daemonReachable) {
    for (const a of daemonAgents) {
      const id = a.agent_instance_id || a.agentInstanceId || a.id;
      if (id) daemonIds.add(id);
    }
  }
  for (const agent of localKnownAgents.map((item) => mapAgent(metadataOnlyAgent(item)))) {
    if (!agent.id) continue;
    if (daemonReachable && !daemonIds.has(agent.id)) continue;
    byId[agent.id] = { ...agent, status: 'offline', startupStatus: '', known: true };
  }
  for (const daemonAgent of daemonAgents.map(mapAgent)) {
    if (!daemonAgent.id) continue;
    const existing = byId[daemonAgent.id] || {};
    const status = daemonAgent.status || daemonAgent.startupStatus || ((daemonAgent as any).connected ? 'connected' : 'offline');
    byId[daemonAgent.id] = { ...existing, ...daemonAgent, status, known: true };
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
  let daemonAgents: any[] = [];
  let daemonReachable = false;
  try {
    daemonAgents = await daemonApi.listKnownAgents({ daemonUrl });
    daemonReachable = true;
  } catch {
    daemonAgents = [];
  }
  const merged = mergeKnownAndLiveAgents(localKnown, daemonAgents, daemonReachable);
  storeKnownAgents(merged);
  return merged;
});

export const fetchSelectedChat = createAsyncThunk(
  'chat/fetchSelectedChat',
  async (payload: { agentId?: string; limit?: number; cursor?: number } | string | undefined, { getState }) => {
    const state = (getState() as any).chat;
    const { session, selectedAgentId } = state;
    
    let agentInstanceId = selectedAgentId;
    let limit = 50;
    let cursor = 0;
    
    if (typeof payload === 'string') {
      agentInstanceId = payload;
    } else if (payload && typeof payload === 'object') {
      agentInstanceId = payload.agentId || selectedAgentId;
      if (payload.limit !== undefined) limit = payload.limit;
      if (payload.cursor !== undefined) cursor = payload.cursor;
    }
    
    if (!agentInstanceId || !session.clientToken) return { agentId: agentInstanceId, messages: [], nextCursor: 0, isAppend: false, markedRead: false };
    
    const isOpenChat = agentInstanceId === selectedAgentId;
    if (isOpenChat && cursor === 0) { // Only mark as read on initial load
      await daemonApi.markChatRead({
        daemonUrl: session.daemonUrl,
        clientInstanceId: session.clientInstanceId,
        clientToken: session.clientToken,
        agentInstanceId,
      });
    }
    
    const data = await daemonApi.fetchChat({
      daemonUrl: session.daemonUrl,
      clientToken: session.clientToken,
      agentInstanceId,
      limit,
      cursor,
    });
    
    return { 
      agentId: agentInstanceId, 
      messages: (data.messages ?? []).map(mapMessage).reverse(), 
      nextCursor: data.next_cursor || 0, 
      isAppend: cursor > 0, 
      markedRead: isOpenChat && cursor === 0 
    };
  },
  {
    condition: (payload, { getState }) => {
      const state = (getState() as any).chat;
      const agentId = getAgentIdFromPayload(payload, state.selectedAgentId);
      if (!agentId) return false;
      if (state.fetchingChatsByAgentId?.[agentId]) {
        return false;
      }
      const isSelected = agentId === state.selectedAgentId;
      const isCached = Boolean(state.chats?.[agentId]);
      if (!isSelected && !isCached) {
        return false;
      }
    }
  }
);

export const sendMessageToSelectedAgent = createAsyncThunk(
  'chat/sendMessageToSelectedAgent',
  async (payload: { body: string; tempId: string }, { getState }) => {
    const { session, selectedAgentId } = (getState() as any).chat;
    const res = await daemonApi.sendToAgent({
      daemonUrl: session.daemonUrl,
      clientInstanceId: session.clientInstanceId,
      clientToken: session.clientToken,
      agentInstanceId: selectedAgentId,
      body: payload.body,
    });
    return { messageId: res.message_id };
  }
);

export const startAgentInstance = createAsyncThunk('chat/startAgentInstance', async (agent: any, { dispatch, getState }) => {
  const { session } = (getState() as any).chat;
  await daemonApi.startAgent({
    daemonUrl: session.daemonUrl,
    agentInstanceId: agent.id,
    provider: agent.providerProfile || agent.agent_class || '',
    templateId: agent.templateId,
    projectId: agent.projectId,
    modelTier: agent.modelTier,
  });
  dispatch(refreshAgents());
});

export const stopAgentInstance = createAsyncThunk('chat/stopAgentInstance', async (agentInstanceId: string, { dispatch, getState }) => {
  const { session } = (getState() as any).chat;
  await daemonApi.stopAgent({
    daemonUrl: session.daemonUrl,
    agentInstanceId,
  });
  dispatch(refreshAgents());
});

function getAgentIdFromPayload(payload: any, selectedAgentId: string): string {
  if (typeof payload === 'string') return payload;
  if (payload && typeof payload === 'object') return payload.agentId || selectedAgentId;
  return selectedAgentId;
}

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
  chatsCursor: {} as Record<string, number>,   // Track cursor per agent (identity)
  chatsHasMore: {} as Record<string, boolean>,  // Track if there are more messages per agent
  sending: false,
  testRuns: [] as any[],
  fetchingChatsByAgentId: {} as Record<string, boolean>,
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
    testStartReceived(state, action) {
      const run = action.payload;
      const idx = state.testRuns.findIndex((r: any) => r.testRunId === run.test_run_id);
      const mapped = {
        testRunId: run.test_run_id,
        provider: run.provider,
        tier: run.tier,
        resolvedModel: run.resolved_model,
        status: 'starting',
        startedUnixMs: run.started_unix_ms,
      };
      if (idx >= 0) state.testRuns[idx] = { ...state.testRuns[idx], ...mapped };
      else state.testRuns.unshift(mapped);
    },
    testDoneReceived(state, action) {
      const run = action.payload;
      const idx = state.testRuns.findIndex((r: any) => r.testRunId === run.test_run_id);
      const update = {
        testRunId: run.test_run_id,
        provider: run.provider,
        tier: run.tier,
        resolvedModel: run.resolved_model,
        status: run.status,
        reason: run.reason,
        elapsedMs: run.elapsed_ms,
        paneTail: run.pane_tail,
        completedUnixMs: run.completed_unix_ms,
      };
      if (idx >= 0) state.testRuns[idx] = { ...state.testRuns[idx], ...update };
      else state.testRuns.unshift(update);
    },
    setTestRuns(state, action) {
      state.testRuns = (action.payload ?? []).map((r: any) => ({
        testRunId: r.test_run_id,
        provider: r.provider,
        tier: r.tier,
        resolvedModel: r.resolved_model,
        status: r.status,
        reason: r.reason,
        elapsedMs: r.elapsed_ms,
        paneTail: r.pane_tail,
        startedUnixMs: r.started_unix_ms,
        completedUnixMs: r.completed_unix_ms,
      }));
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
          projectName: mapped.projectName || existing.projectName || '',
          templateId: mapped.templateId || existing.templateId || '',
          providerProfile: mapped.providerProfile || existing.providerProfile || '',
          roleHint: mapped.roleHint || existing.roleHint || '',
          modelTier: mapped.modelTier || existing.modelTier || 'normal',
          known: true,
        } as never;
      } else {
        state.agents.unshift({ ...mapped, known: true } as never);
      }
      storeKnownAgents(state.agents);
    },
    appendMessage(state, action) {
      const { agentId, message } = action.payload;
      if (!state.chats[agentId]) {
        state.chats[agentId] = [];
      }
      const mapped = mapMessage(message);

      // Resolve race condition: if this is a user message from us, check if there is an
      // optimistic temporary message already in the chat list matching the body.
      if (mapped.author === 'user') {
        const optimisticIndex = state.chats[agentId].findIndex(
          (m: any) => m.author === 'user' && m.body === mapped.body && (m.sending || String(m.id).startsWith('local_temp_'))
        );
        if (optimisticIndex >= 0) {
          // Upgrade the optimistic message in-place to the real database ID and clear sending state
          state.chats[agentId][optimisticIndex] = {
            ...state.chats[agentId][optimisticIndex],
            id: mapped.id,
            sending: false,
            timestamp: mapped.timestamp,
            deliveredUnixMs: mapped.deliveredUnixMs,
            deliveredAt: mapped.deliveredAt,
            readUnixMs: mapped.readUnixMs,
            readAt: mapped.readAt,
          } as any;
          return;
        }
      }

      if (!state.chats[agentId].some((m: any) => m.id === mapped.id)) {
        state.chats[agentId].push(mapped);
      }
    },
    agentRuntimeEventReceived(state, action) {
      const payload = action.payload || {};
      const agentId = payload.agent_instance_id;
      if (!agentId) return;
      const existingIndex = state.agents.findIndex((agent) => agent.id === agentId);
      if (existingIndex >= 0) {
        const existing: any = state.agents[existingIndex];
        const execState = payload.exec_state || '';
        
        let status = existing.status;
        if (existing.status !== 'offline' || payload.last_seen_unix_ms) {
          if (execState === 'running') {
            status = 'connected';
          } else if (execState === 'blocked') {
            status = 'startup_blocked';
          } else if (execState === 'idle') {
            status = 'idle';
          } else {
            status = 'connected';
          }
        }
        
        state.agents[existingIndex] = {
          ...existing,
          status,
          tmuxPane: payload.tmux_pane ?? existing.tmuxPane,
          pid: payload.pid ?? existing.pid,
          execState,
          execStateSinceUnixMs: payload.exec_state_since_unix_ms ?? existing.execStateSinceUnixMs,
          blockedReason: payload.blocked_reason ?? existing.blockedReason,
          runDir: payload.run_dir ?? existing.runDir,
          lastSeenUnixMs: payload.last_seen_unix_ms ?? existing.lastSeenUnixMs,
          lastSeen: payload.last_seen_unix_ms ? new Date(payload.last_seen_unix_ms).toLocaleString([], { month: 'short', day: 'numeric', hour: '2-digit', minute: '2-digit' }) : existing.lastSeen,
        } as never;
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
      .addCase(fetchSelectedChat.pending, (state: any, action) => {
        const agentId = getAgentIdFromPayload(action.meta.arg, state.selectedAgentId);
        if (agentId) {
          state.fetchingChatsByAgentId[agentId] = true;
        }
      })
      .addCase(fetchSelectedChat.fulfilled, (state: any, action) => {
        const agentId = getAgentIdFromPayload(action.meta.arg, state.selectedAgentId);
        if (agentId) {
          state.fetchingChatsByAgentId[agentId] = false;
        }
        const { agentId: payloadAgentId, messages, nextCursor, isAppend } = action.payload;
        if (payloadAgentId) {
          if (!state.chats[payloadAgentId]) {
            state.chats[payloadAgentId] = [];
          }
          if (isAppend) {
            // Prepend older paginated messages to the top
            state.chats[payloadAgentId] = [...messages, ...state.chats[payloadAgentId]];
          } else {
            // Initial load - replace
            state.chats[payloadAgentId] = messages;
          }
          state.chatsCursor[payloadAgentId] = nextCursor;
          state.chatsHasMore[payloadAgentId] = nextCursor > 0;

          if (action.payload.markedRead) {
            const agent = state.agents.find((item) => item.id === payloadAgentId);
            if (agent) agent.unreadCount = 0;
          }
        }
      })
      .addCase(fetchSelectedChat.rejected, (state: any, action) => {
        const agentId = getAgentIdFromPayload(action.meta.arg, state.selectedAgentId);
        if (agentId) {
          state.fetchingChatsByAgentId[agentId] = false;
        }
        state.session.error = action.error.message || 'Failed to fetch chat';
      })
      .addCase(sendMessageToSelectedAgent.pending, (state: any, action) => {
        state.sending = true;
        state.session.error = '';
        const { body, tempId } = action.meta.arg;
        const agentId = state.selectedAgentId;
        if (agentId && tempId) {
          if (!state.chats[agentId]) {
            state.chats[agentId] = [];
          }
          state.chats[agentId].push({
            id: tempId,
            author: 'user',
            body,
            timestamp: new Date().toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' }),
            sending: true,
            readUnixMs: 0,
            deliveredUnixMs: 0,
          });
        }
      })
      .addCase(sendMessageToSelectedAgent.fulfilled, (state: any, action) => {
        state.sending = false;
        const { tempId } = action.meta.arg;
        const agentId = state.selectedAgentId;
        const { messageId } = action.payload;
        if (agentId && tempId && state.chats[agentId]) {
          const msg = state.chats[agentId].find((m: any) => m.id === tempId);
          if (msg) {
            msg.id = messageId;
            msg.sending = false;
          }
        }
      })
      .addCase(sendMessageToSelectedAgent.rejected, (state: any, action) => {
        state.sending = false;
        const { tempId } = action.meta.arg;
        const agentId = state.selectedAgentId;
        if (agentId && tempId && state.chats[agentId]) {
          const msg = state.chats[agentId].find((m: any) => m.id === tempId);
          if (msg) {
            msg.sending = false;
            msg.error = true;
          }
        }
        state.session.error = action.error.message || 'Failed to send message';
      });
  },
});

export const { selectAgent, setDaemonUrl, updateSessionConfig, userWsConnecting, userWsConnected, userWsDisconnected, userWsError, chatEventReceived, upsertKnownAgent, agentLifecycleEventReceived, agentRuntimeEventReceived, testStartReceived, testDoneReceived, setTestRuns, appendMessage } = chatSlice.actions;
export default chatSlice.reducer;
