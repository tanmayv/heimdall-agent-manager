import { createAsyncThunk, createSlice } from '@reduxjs/toolkit';
import * as daemonApi from '../api/daemonApi';

const DEFAULT_DAEMON_URL = 'http://127.0.0.1:49322';
const DEFAULT_USER_ID = 'operator@local';
const DAEMON_PROFILES_KEY = 'odin.daemonProfiles';

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

function normalizeDaemonUrl(value: string): string {
  return (value || '').trim().replace(/\/$/, '');
}

function daemonLabelForUrl(url: string): string {
  try {
    const parsed = new URL(url);
    return parsed.host || url;
  } catch {
    return url;
  }
}

function normalizeDaemonProfiles(items: any[], activeUrl: string) {
  const byUrl: Record<string, any> = {};
  for (const item of items || []) {
    const url = normalizeDaemonUrl(item?.url || item?.daemonUrl || '');
    if (!url) continue;
    byUrl[url] = { label: String(item?.label || daemonLabelForUrl(url)), url };
  }
  if (activeUrl && !byUrl[activeUrl]) byUrl[activeUrl] = { label: daemonLabelForUrl(activeUrl), url: activeUrl };
  if (!byUrl[DEFAULT_DAEMON_URL]) byUrl[DEFAULT_DAEMON_URL] = { label: 'Local daemon', url: DEFAULT_DAEMON_URL };
  return Object.values(byUrl).sort((left: any, right: any) => (left.label || '').localeCompare(right.label || ''));
}

function loadDaemonProfiles(activeUrl: string) {
  try {
    return normalizeDaemonProfiles(JSON.parse(window.localStorage.getItem(DAEMON_PROFILES_KEY) || '[]'), activeUrl);
  } catch {
    return normalizeDaemonProfiles([], activeUrl);
  }
}

function storeDaemonProfiles(profiles: any[]) {
  try {
    window.localStorage.setItem(DAEMON_PROFILES_KEY, JSON.stringify(profiles));
  } catch {
    // Local daemon profiles are a UI convenience.
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
    agentRecordId: agent.agent_record_id || agent.agentRecordId || '',
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
    unreadCount: Number(agent.unread_count ?? agent.unreadCount ?? 0),
    order: agent.order ?? 0,
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
    currentTaskId: agent.current_task_id || agent.currentTaskId || '',
    currentTaskSince: Number(agent.current_task_since ?? agent.currentTaskSince ?? 0),
    state: agent.state || '',
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

function getStatusPriority(status: string): number {
  switch (status) {
    case 'connected': return 5;
    case 'idle': return 4;
    case 'startup_blocked': return 3;
    case 'starting': return 2;
    default: return 1;
  }
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
  for (const rawDaemonAgent of daemonAgents) {
    const daemonAgent = mapAgent(rawDaemonAgent);
    if (!daemonAgent.id) continue;
    const existing = byId[daemonAgent.id] || {};
    const status = daemonAgent.status || daemonAgent.startupStatus || ((daemonAgent as any).connected ? 'connected' : 'offline');
    const hasDaemonUnread = rawDaemonAgent.unread_count !== undefined || rawDaemonAgent.unreadCount !== undefined;
    const unreadCount = hasDaemonUnread ? daemonAgent.unreadCount : (existing.unreadCount || 0);
    byId[daemonAgent.id] = { ...existing, ...daemonAgent, status, unreadCount, known: true };
  }
  return Object.values(byId).sort((left: any, right: any) => {
    const diff = (left.order ?? 0) - (right.order ?? 0);
    if (diff !== 0) return diff;
    const leftPriority = getStatusPriority(left.status);
    const rightPriority = getStatusPriority(right.status);
    if (leftPriority !== rightPriority) {
      return rightPriority - leftPriority;
    }
    return (left.label || '').localeCompare(right.label || '');
  });
}

function mapMessage(message: any) {
  const createdTime = message.created_unix_ms ? new Date(message.created_unix_ms).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' }) : '';
  const deliveredUnixMs = Number(message.delivered_unix_ms ?? message.deliveredUnixMs ?? 0);
  const readUnixMs = Number(message.read_unix_ms ?? message.readUnixMs ?? 0);
  const deliveryFailedUnixMs = Number(message.delivery_failed_unix_ms ?? message.deliveryFailedUnixMs ?? 0);
  return {
    id: message.message_id ?? message.id,
    author: message.direction === 'user_to_agent' || message.author === 'user' ? 'user' : 'agent',
    body: message.body,
    timestamp: createdTime || message.timestamp || '',
    deliveredAt: deliveredUnixMs > 0 ? new Date(deliveredUnixMs).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' }) : (message.deliveredAt || ''),
    deliveredUnixMs,
    readAt: readUnixMs > 0 ? new Date(readUnixMs).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' }) : (message.readAt || ''),
    readUnixMs,
    deliveryFailedAt: deliveryFailedUnixMs > 0 ? new Date(deliveryFailedUnixMs).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' }) : (message.deliveryFailedAt || ''),
    deliveryFailedUnixMs,
    deliveryError: message.delivery_error ?? message.deliveryError ?? '',
    interrupt: !!message.interrupt,
  };
}

function mergeMessage(existing: any, incoming: any) {
  const merged = { ...existing, ...incoming };
  return {
    ...merged,
    body: incoming.body ?? existing.body,
    timestamp: incoming.timestamp || existing.timestamp,
    sending: false,
    error: incoming.deliveryFailedUnixMs > 0 ? false : (existing.error && !incoming.id ? existing.error : false),
  };
}

function mergeMessages(existingMessages: any[], incomingMessages: any[]) {
  const result = [...existingMessages];
  for (const incoming of incomingMessages) {
    const byId = result.findIndex((m: any) => m.id === incoming.id);
    if (byId >= 0) {
      result[byId] = mergeMessage(result[byId], incoming);
      continue;
    }
    const optimisticIndex = incoming.author === 'user'
      ? result.findIndex((m: any) => m.author === 'user' && m.body === incoming.body && (m.sending || String(m.id).startsWith('local_temp_')))
      : -1;
    if (optimisticIndex >= 0) {
      result[optimisticIndex] = mergeMessage(result[optimisticIndex], incoming);
    } else {
      result.push(incoming);
    }
  }
  return result;
}

export const registerSession = createAsyncThunk('chat/registerSession', async (_, { getState }) => {
  const { session } = (getState() as any).chat;
  return daemonApi.registerUserClient(session);
});

export const fetchPreferences = createAsyncThunk('chat/fetchPreferences', async (_, { getState }) => {
  const { session } = (getState() as any).chat;
  const data = await daemonApi.fetchPreferences({
    daemonUrl: session.daemonUrl,
    clientToken: session.clientToken,
  });
  return data?.preferences ?? [];
});

export const saveUserPreference = createAsyncThunk(
  'chat/saveUserPreference',
  async (payload: { key: string; value: string; interrupt?: boolean }, { getState }) => {
    const { session } = (getState() as any).chat;
    const res = await daemonApi.savePreference({
      daemonUrl: session.daemonUrl,
      clientToken: session.clientToken,
      key: payload.key,
      value: payload.value,
      interrupt: payload.interrupt ?? false,
    });
    return res.preference;
  }
);


export const refreshSettingsCatalog = createAsyncThunk('chat/refreshSettingsCatalog', async (_, { getState }) => {
  const state = getState() as any;
  const { daemonUrl } = state.chat.session;
  const [templates, providers] = await Promise.all([
    daemonApi.listAgentTemplates({ daemonUrl }).catch(() => []),
    daemonApi.listAgentProviders({ daemonUrl }).catch(() => []),
  ]);
  return { templates, providers };
});

export const refreshAgents = createAsyncThunk('chat/refreshAgents', async (_, { getState }) => {
  const state = getState() as any;
  const { daemonUrl } = state.chat.session;
  
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
  async (payload: { body: string; tempId: string; interrupt?: boolean }, { getState }) => {
    const { session, selectedAgentId } = (getState() as any).chat;
    const res = await daemonApi.sendToAgent({
      daemonUrl: session.daemonUrl,
      clientInstanceId: session.clientInstanceId,
      clientToken: session.clientToken,
      agentInstanceId: selectedAgentId,
      body: payload.body,
      interrupt: payload.interrupt,
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

export const reorderAgentsFromUi = createAsyncThunk(
  'chat/reorderAgentsFromUi',
  async (agentIds: string[], { dispatch, getState }) => {
    dispatch(chatSlice.actions.reorderAgentsLocally(agentIds));
    const state = getState() as any;
    const { session } = state.chat;
    try {
      const result = await daemonApi.reorderAgents({
        daemonUrl: session.daemonUrl,
        clientInstanceId: session.clientInstanceId,
        clientToken: session.clientToken,
        agentIds,
      });
      await (dispatch as any)(refreshAgents());
      return result;
    } catch (err) {
      await (dispatch as any)(refreshAgents());
      throw err;
    }
  }
);


function getAgentIdFromPayload(payload: any, selectedAgentId: string): string {
  if (typeof payload === 'string') return payload;
  if (payload && typeof payload === 'object') return payload.agentId || selectedAgentId;
  return selectedAgentId;
}

const initialDaemonUrl = normalizeDaemonUrl((window as any).odinApi?.daemonUrl || getStoredValue('odin.daemonUrl', DEFAULT_DAEMON_URL)) || DEFAULT_DAEMON_URL;

const initialState = {
  daemonProfiles: loadDaemonProfiles(initialDaemonUrl),
  session: {
    daemonUrl: initialDaemonUrl,
    userId: getStoredValue('odin.userId', DEFAULT_USER_ID),
    userDisplayName: getStoredValue('odin.userDisplayName', ''),
    clientInstanceId: createClientInstanceId(),
    clientToken: getStoredValue('odin.clientToken', ''),
    connected: false,
    status: 'idle',
    wsStatus: 'idle',
    wsConnected: false,
    lastChatEvent: null,
    error: '',
  },
  preferences: [] as any[],
  userPreferences: {} as Record<string, string>,
  settingsTemplates: [] as any[],
  settingsProviders: [] as any[],
  selectedAgentId: '',
  agents: [],
  chats: {},
  chatsCursor: {} as Record<string, number>,   // Track cursor per agent (identity)
  chatsHasMore: {} as Record<string, boolean>,  // Track if there are more messages per agent
  sending: false,
  testRuns: [] as any[],
  fetchingChatsByAgentId: {} as Record<string, boolean>,
  activeView: 'chat' as 'chat' | 'settings' | 'tasks' | 'memory' | 'memoryAudit' | 'projects' | 'agents' | 'startAgent',
};


const chatSlice = createSlice({
  name: 'chat',
  initialState,
  reducers: {
    selectAgent(state, action) {
      state.selectedAgentId = action.payload;
    },
    setView(state, action) {
      state.activeView = action.payload || 'chat';
    },
    markAgentReadLocally(state, action) {
      const agentInstanceId = String(action.payload || '');
      if (!agentInstanceId) return;
      const agent = state.agents.find((item: any) => item.id === agentInstanceId);
      if (agent) {
        agent.unreadCount = 0;
        storeKnownAgents(state.agents);
      }
    },
    reorderAgentsLocally(state, action) {
      const agentIds = action.payload;
      const agentsById = new Map<string, any>();
      for (const agent of state.agents) {
        agentsById.set(agent.id, agent);
      }
      agentIds.forEach((id: string, index: number) => {
        const agent = agentsById.get(id);
        if (agent) {
          agent.order = index;
        }
      });
      state.agents.sort((left: any, right: any) => {
        const diff = (left.order ?? 0) - (right.order ?? 0);
        if (diff !== 0) return diff;
        const leftPriority = getStatusPriority(left.status);
        const rightPriority = getStatusPriority(right.status);
        if (leftPriority !== rightPriority) {
          return rightPriority - leftPriority;
        }
        return (left.label || '').localeCompare(right.label || '');
      });
      storeKnownAgents(state.agents);
    },

    setDaemonUrl(state, action) {
      const daemonUrl = normalizeDaemonUrl(action.payload) || DEFAULT_DAEMON_URL;
      state.session.daemonUrl = daemonUrl;
      setStoredValue('odin.daemonUrl', daemonUrl);
    },
    addDaemonProfile(state, action) {
      const daemonUrl = normalizeDaemonUrl(action.payload?.daemonUrl || action.payload?.url || '');
      if (!daemonUrl) return;
      const profile = { label: String(action.payload?.label || daemonLabelForUrl(daemonUrl)), url: daemonUrl };
      state.daemonProfiles = normalizeDaemonProfiles([...state.daemonProfiles, profile], daemonUrl);
      storeDaemonProfiles(state.daemonProfiles);
    },
    renameDaemonProfile(state, action) {
      const daemonUrl = normalizeDaemonUrl(action.payload?.daemonUrl || action.payload?.url || '');
      const label = String(action.payload?.label || '').trim();
      if (!daemonUrl || !label) return;
      state.daemonProfiles = state.daemonProfiles.map((profile: any) => (
        normalizeDaemonUrl(profile?.url || '') === daemonUrl ? { ...profile, label } : profile
      ));
      state.daemonProfiles = normalizeDaemonProfiles(state.daemonProfiles, state.session.daemonUrl);
      storeDaemonProfiles(state.daemonProfiles);
    },
    removeDaemonProfile(state, action) {
      const daemonUrl = normalizeDaemonUrl(action.payload?.daemonUrl || action.payload?.url || action.payload || '');
      if (!daemonUrl) return;
      if (daemonUrl === state.session.daemonUrl) return; // never delete the active profile
      state.daemonProfiles = state.daemonProfiles.filter((profile: any) => normalizeDaemonUrl(profile?.url || '') !== daemonUrl);
      state.daemonProfiles = normalizeDaemonProfiles(state.daemonProfiles, state.session.daemonUrl);
      storeDaemonProfiles(state.daemonProfiles);
    },
    updateSessionConfig(state, action) {
      const daemonUrl = normalizeDaemonUrl(action.payload.daemonUrl) || DEFAULT_DAEMON_URL;
      const userId = action.payload.userId?.trim() || DEFAULT_USER_ID;
      const daemonChanged = daemonUrl !== state.session.daemonUrl;
      const userChanged = userId !== state.session.userId;
      state.session.daemonUrl = daemonUrl;
      state.session.userId = userId;
      state.session.connected = false;
      state.session.status = 'idle';
      state.session.wsConnected = false;
      state.session.wsStatus = 'idle';
      state.session.error = '';
      if (daemonChanged || userChanged) {
        state.session.clientInstanceId = newClientInstanceId();
        state.session.clientToken = '';
        state.session.lastChatEvent = null;
        state.agents = [];
        state.chats = {};
        state.chatsCursor = {};
        state.chatsHasMore = {};
        state.fetchingChatsByAgentId = {};
        state.selectedAgentId = '';
        state.testRuns = [];
        setStoredValue('odin.clientInstanceId', state.session.clientInstanceId);
        setStoredValue('odin.clientToken', '');
        storeKnownAgents([]);
      }
      state.daemonProfiles = normalizeDaemonProfiles(state.daemonProfiles, daemonUrl);
      storeDaemonProfiles(state.daemonProfiles);
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
        if (agent) {
          agent.unreadCount = action.payload.unread_count ?? agent.unreadCount;
          storeKnownAgents(state.agents);
        }
      }
    },
     upsertKnownAgent(state, action) {
      const mapped: any = mapAgent(action.payload);
      if (!mapped.id) return;
      const existingIndex = state.agents.findIndex((agent) => agent.id === mapped.id);
      if (existingIndex >= 0) {
        const existing: any = state.agents[existingIndex];
        const unreadCount = existing.unreadCount || mapped.unreadCount || 0;
        state.agents[existingIndex] = { ...existing, ...mapped, unreadCount, known: true } as never;
      } else {
        state.agents.unshift(mapped as never);
      }
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
      state.chats[agentId] = mergeMessages(state.chats[agentId], [mapMessage(message)]);
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
      .addCase(fetchPreferences.fulfilled, (state, action) => {
        state.preferences = action.payload;
        const cache: Record<string, string> = {};
        for (const p of action.payload) {
          cache[p.key] = p.value;
        }
        state.userPreferences = cache;
        if (cache['user_display_name']) {
          state.session.userDisplayName = cache['user_display_name'];
          setStoredValue('odin.userDisplayName', cache['user_display_name']);
        }
      })
      .addCase(saveUserPreference.fulfilled, (state, action) => {
        const pref = action.payload;
        const idx = state.preferences.findIndex((p) => p.key === pref.key);
        if (idx >= 0) {
          state.preferences[idx] = pref;
        } else {
          state.preferences.push(pref);
        }
        state.userPreferences[pref.key] = pref.value;
        if (pref.key === 'user_display_name') {
          state.session.userDisplayName = pref.value;
          setStoredValue('odin.userDisplayName', pref.value);
        }
      })
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
      .addCase(refreshSettingsCatalog.fulfilled, (state: any, action) => {
        state.settingsTemplates = action.payload.templates || [];
        state.settingsProviders = action.payload.providers || [];
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
            // Prepend older paginated messages to the top, but merge duplicates/status updates.
            state.chats[payloadAgentId] = mergeMessages(messages, state.chats[payloadAgentId]);
          } else {
            // Initial load - daemon truth plus any still-unmatched optimistic sends.
            const optimistic = state.chats[payloadAgentId].filter((m: any) => m.sending || String(m.id).startsWith('local_temp_'));
            const unmatchedOptimistic = optimistic.filter((local: any) => !messages.some((server: any) => server.id === local.id || (server.author === local.author && server.body === local.body)));
            state.chats[payloadAgentId] = [...messages, ...unmatchedOptimistic];
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

export const { selectAgent, setView, setDaemonUrl, addDaemonProfile, renameDaemonProfile, removeDaemonProfile, updateSessionConfig, userWsConnecting, userWsConnected, userWsDisconnected, userWsError, chatEventReceived, upsertKnownAgent, agentLifecycleEventReceived, agentRuntimeEventReceived, testStartReceived, testDoneReceived, setTestRuns, appendMessage, reorderAgentsLocally, markAgentReadLocally } = chatSlice.actions;

export const markCoordinatorRead = createAsyncThunk('chat/markCoordinatorRead', async (agentInstanceId: string, { dispatch, getState }) => {
  const state = getState() as any;
  const { session } = state.chat;
  if (!agentInstanceId || !session.clientToken || !session.clientInstanceId) return { agentInstanceId, ok: false };
  dispatch(markAgentReadLocally(agentInstanceId));
  try {
    await daemonApi.markChatRead({
      daemonUrl: session.daemonUrl,
      clientInstanceId: session.clientInstanceId,
      clientToken: session.clientToken,
      agentInstanceId,
    });
    return { agentInstanceId, ok: true };
  } catch (_err) {
    return { agentInstanceId, ok: false };
  }
});
export default chatSlice.reducer;

