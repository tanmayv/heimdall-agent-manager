const KNOWN_AGENTS_STORAGE_KEY = 'odin.knownAgents';

export function loadKnownAgents(): any[] {
  try {
    return JSON.parse(window.localStorage.getItem(KNOWN_AGENTS_STORAGE_KEY) || '[]');
  } catch {
    return [];
  }
}

export function storeKnownAgents(agents: any[]) {
  try {
    window.localStorage.setItem(KNOWN_AGENTS_STORAGE_KEY, JSON.stringify(agents || []));
  } catch {
    // Local known-agent records are a UI convenience when daemon persistence is unavailable.
  }
}

function safeStartupStatus(agent: any) {
  const status = agent.startup_status || agent.startupStatus || agent.lifecycle_state || agent.lifecycleState || '';
  if (status === 'startup_blocked' || status === 'startup_failed' || status === 'startup_unknown' || status === 'starting' || status === 'ready' || status === 'start_success' || status === 'stopping' || status === 'stopped') return status;
  return '';
}

export function mapAgent(agent: any) {
  const lastSeenUnixMs = Number(agent.last_seen_unix_ms ?? agent.lastSeenUnixMs ?? 0);
  const startupStatus = safeStartupStatus(agent);
  const execState = agent.exec_state || agent.execState || '';
  const execStateSinceUnixMs = Number(agent.exec_state_since_unix_ms ?? agent.execStateSinceUnixMs ?? 0);
  const blockedReason = agent.blocked_reason || agent.blockedReason || '';
  const activityStatus = agent.activity_status || agent.activityStatus || '';
  const activityCheckedUnixMs = Number(agent.activity_checked_unix_ms ?? agent.activityCheckedUnixMs ?? 0);
  const activitySource = agent.activity_source || agent.activitySource || '';

  let status = 'offline';
  if (startupStatus === 'stopped') {
    status = 'offline';
  } else if (startupStatus) {
    status = startupStatus;
  } else if (agent.connected) {
    if (activityStatus === 'active') {
      status = 'connected';
    } else if (activityStatus === 'idle') {
      status = 'idle';
    } else if (execState === 'running') {
      status = 'connected';
    } else if (execState === 'blocked') {
      status = 'startup_blocked';
    } else if (execState === 'idle') {
      status = 'idle';
    } else {
      status = 'connected';
    }
  }

  return {
    id: agent.agent_instance_id || agent.agentInstanceId || agent.id,
    agentId: agent.agent_id || agent.agentId || agent.agent_instance_id || agent.agentInstanceId || agent.id || '',
    agentRecordId: agent.agent_record_id || agent.agentRecordId || '',
    label: agent.display_name || agent.displayName || agent.alias || agent.agent_instance_id || agent.id,
    status,
    startupStatus,
    startupReason: agent.safe_diagnostic || agent.safeDiagnostic || agent.startup_safe_diagnostic || agent.startupSafeDiagnostic || agent.reason || agent.startup_reason_code || agent.startupReasonCode || agent.reason_code || agent.reasonCode || '',
    startupReasonCode: agent.startup_reason_code || agent.startupReasonCode || agent.reason_code || agent.reasonCode || '',
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
    agentKind: agent.agent_kind || agent.agentKind || 'local',
    remote: agent.remote ? {
      peerId: agent.remote.peer_id || agent.remote.peerId || '',
      originDaemonId: agent.remote.origin_daemon_id || agent.remote.originDaemonId || '',
      remoteAgentInstanceId: agent.remote.remote_agent_instance_id || agent.remote.remoteAgentInstanceId || '',
      status: agent.remote.status || '',
      connectionState: agent.remote.connection_state || agent.remote.connectionState || '',
      connected: agent.remote.connected === undefined ? undefined : Boolean(agent.remote.connected),
      currentTaskId: agent.remote.current_task_id || agent.remote.currentTaskId || '',
      providerProfile: agent.remote.provider_profile || agent.remote.providerProfile || '',
      modelTier: agent.remote.model_tier || agent.remote.modelTier || '',
      projectId: agent.remote.project_id || agent.remote.projectId || '',
      lastSeenUnixMs: Number(agent.remote.last_seen_unix_ms ?? agent.remote.lastSeenUnixMs ?? 0),
      peerReachable: (agent.remote.peer_reachable ?? agent.remote.peerReachable) === undefined ? undefined : Boolean(agent.remote.peer_reachable ?? agent.remote.peerReachable),
    } : ((agent.remote_peer_id || agent.remotePeerId || agent.remote_agent_instance_id || agent.remoteAgentInstanceId || agent.remote_origin_daemon_id || agent.remoteOriginDaemonId) ? {
      peerId: agent.remote_peer_id || agent.remotePeerId || '',
      originDaemonId: agent.remote_origin_daemon_id || agent.remoteOriginDaemonId || '',
      remoteAgentInstanceId: agent.remote_agent_instance_id || agent.remoteAgentInstanceId || '',
    } : null),
    providerProfile: agent.provider_profile || agent.providerProfile || agent.agent_class || '',
    connected: Boolean(agent.connected),
    connectionState: agent.connection_state || agent.connectionState || '',
    modelTier: (String(agent.agent_kind || agent.agentKind || '').toLowerCase() === 'remote_proxy') ? (agent.model_tier || agent.modelTier || '') : (agent.model_tier || agent.modelTier || 'normal'),
    known: agent.known ?? true,
    execState,
    execStateSinceUnixMs,
    blockedReason,
    activityStatus,
    activityCheckedUnixMs,
    activitySource,
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
    case 'ready': return 6;
    case 'connected': return 5;
    case 'idle': return 4;
    case 'startup_blocked': return 3;
    case 'starting': return 2;
    default: return 1;
  }
}

function defaultRuntimeBaseId(agent: any): string {
  const id = String(agent?.id || agent?.agent_instance_id || agent?.agentInstanceId || '');
  const durableId = String(agent?.agentId || agent?.agent_id || '');
  if (!id || !durableId) return '';
  if (id === durableId) return durableId;
  if (id === `${durableId}@default`) return durableId;
  return '';
}

function shouldPreferAgentRecord(candidate: any, existing: any): boolean {
  if (!existing) return true;
  const candidateLive = Boolean(candidate.connected) || String(candidate.connectionState || candidate.connection_state || '').toLowerCase() === 'connected';
  const existingLive = Boolean(existing.connected) || String(existing.connectionState || existing.connection_state || '').toLowerCase() === 'connected';
  if (candidateLive !== existingLive) return candidateLive;
  const candidatePriority = getStatusPriority(candidate.status || candidate.startupStatus || '');
  const existingPriority = getStatusPriority(existing.status || existing.startupStatus || '');
  if (candidatePriority !== existingPriority) return candidatePriority > existingPriority;
  return Number(candidate.lastSeenUnixMs || 0) >= Number(existing.lastSeenUnixMs || 0);
}

function sortAgentsInPlace(agents: any[]) {
  agents.sort((left: any, right: any) => {
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

export function mergeKnownAndLiveAgents(localKnownAgents: any[], daemonAgents: any[], daemonReachable = false) {
  const byId: Record<string, any> = {};
  const defaultRuntimeAliases: Record<string, string> = {};
  const putAgent = (agent: any) => {
    if (!agent?.id) return;
    const baseId = defaultRuntimeBaseId(agent);
    if (baseId) {
      const previousId = defaultRuntimeAliases[baseId];
      const previous = previousId ? byId[previousId] : null;
      if (!previous || shouldPreferAgentRecord(agent, previous)) {
        if (previousId && previousId !== agent.id) delete byId[previousId];
        defaultRuntimeAliases[baseId] = agent.id;
        byId[agent.id] = previous ? { ...previous, ...agent } : agent;
      }
      return;
    }
    byId[agent.id] = agent;
  };
  const daemonIds = new Set<string>();
  if (daemonReachable) {
    for (const agent of daemonAgents) {
      const id = agent.agent_instance_id || agent.agentInstanceId || agent.id;
      if (id) daemonIds.add(id);
    }
  }
  for (const agent of localKnownAgents.map((item) => mapAgent(metadataOnlyAgent(item)))) {
    if (!agent.id) continue;
    if (daemonReachable && !daemonIds.has(agent.id)) continue;
    putAgent({ ...agent, status: 'offline', startupStatus: '', known: true });
  }
  for (const rawDaemonAgent of daemonAgents) {
    const daemonAgent = mapAgent(rawDaemonAgent);
    if (!daemonAgent.id) continue;
    const existing = byId[daemonAgent.id] || {};
    const status = daemonAgent.status || daemonAgent.startupStatus || (daemonAgent.connected ? 'connected' : 'offline');
    const hasDaemonUnread = rawDaemonAgent.unread_count !== undefined || rawDaemonAgent.unreadCount !== undefined;
    const unreadCount = hasDaemonUnread ? daemonAgent.unreadCount : (existing.unreadCount || 0);
    putAgent({ ...existing, ...daemonAgent, status, unreadCount, known: true });
  }
  const merged = Object.values(byId);
  sortAgentsInPlace(merged);
  return merged;
}

export function upsertKnownAgentRecord(agents: any[], rawAgent: any) {
  const mapped: any = mapAgent(rawAgent);
  if (!mapped.id) return null;
  const existingIndex = agents.findIndex((agent: any) => agent.id === mapped.id);
  if (existingIndex >= 0) {
    const existing: any = agents[existingIndex];
    const unreadCount = existing.unreadCount || mapped.unreadCount || 0;
    agents[existingIndex] = { ...existing, ...mapped, unreadCount, known: true };
  } else {
    agents.unshift({ ...mapped, known: true });
    sortAgentsInPlace(agents);
  }
  return mapped;
}

export function applyAgentLifecycleEvent(agents: any[], payload: any) {
  const normalizedPayload = payload || {};
  const agentPayload = normalizedPayload.agent || normalizedPayload.record || normalizedPayload;
  const agentId = agentPayload.agent_instance_id || agentPayload.agentInstanceId || normalizedPayload.agent_instance_id || normalizedPayload.agentInstanceId;
  if (!agentId) return '';
  const mapped: any = mapAgent({ ...agentPayload, agent_instance_id: agentId });
  const existingIndex = agents.findIndex((agent: any) => agent.id === agentId);
  if (existingIndex >= 0) {
    const existing: any = agents[existingIndex];
    const mappedLabelLooksLikeId = !mapped.label || mapped.label === mapped.id;
    agents[existingIndex] = {
      ...existing,
      ...mapped,
      label: mappedLabelLooksLikeId ? (existing.label || mapped.label) : mapped.label,
      projectId: mapped.projectId || existing.projectId || '',
      projectName: mapped.projectName || existing.projectName || '',
      templateId: mapped.templateId || existing.templateId || '',
      providerProfile: mapped.providerProfile || existing.providerProfile || '',
      modelTier: mapped.modelTier || existing.modelTier || 'normal',
      known: true,
    };
  } else {
    agents.unshift({ ...mapped, known: true });
    sortAgentsInPlace(agents);
  }
  return agentId;
}

export function applyAgentRuntimeEvent(agents: any[], payload: any) {
  const normalizedPayload = payload || {};
  const agentId = normalizedPayload.agent_instance_id || normalizedPayload.agentInstanceId || '';
  if (!agentId) return '';
  const existingIndex = agents.findIndex((agent: any) => agent.id === agentId);
  if (existingIndex < 0) return agentId;
  const existing: any = agents[existingIndex];
  const execState = normalizedPayload.exec_state || '';
  const activityStatus = normalizedPayload.activity_status ?? existing.activityStatus ?? '';

  let status = existing.status;
  if (existing.startupStatus === 'stopped' || existing.startupStatus === 'stopping') {
    status = existing.startupStatus;
  } else if (existing.startupStatus && existing.startupStatus !== 'ready' && existing.startupStatus !== 'start_success') {
    status = existing.startupStatus;
  } else if (activityStatus === 'active') {
    status = 'connected';
  } else if (activityStatus === 'idle') {
    status = 'idle';
  } else if (execState === 'running') {
    status = 'connected';
  } else if (execState === 'blocked') {
    status = 'startup_blocked';
  } else if (execState === 'idle') {
    status = 'idle';
  } else {
    status = 'connected';
  }

  const stopping = existing.startupStatus === 'stopped' || existing.startupStatus === 'stopping';
  const connected = stopping ? Boolean(existing.connected) : true;
  agents[existingIndex] = {
    ...existing,
    status,
    connected,
    connectionState: connected ? 'connected' : (existing.connectionState || existing.connection_state || ''),
    tmuxPane: normalizedPayload.tmux_pane ?? existing.tmuxPane,
    pid: normalizedPayload.pid ?? existing.pid,
    execState,
    execStateSinceUnixMs: normalizedPayload.exec_state_since_unix_ms ?? existing.execStateSinceUnixMs,
    blockedReason: normalizedPayload.blocked_reason ?? existing.blockedReason,
    activityStatus,
    activityCheckedUnixMs: normalizedPayload.activity_checked_unix_ms ?? existing.activityCheckedUnixMs,
    activitySource: normalizedPayload.activity_source ?? existing.activitySource,
    runDir: normalizedPayload.run_dir ?? existing.runDir,
    lastSeenUnixMs: normalizedPayload.last_seen_unix_ms ?? existing.lastSeenUnixMs,
    lastSeen: normalizedPayload.last_seen_unix_ms ? new Date(normalizedPayload.last_seen_unix_ms).toLocaleString([], { month: 'short', day: 'numeric', hour: '2-digit', minute: '2-digit' }) : existing.lastSeen,
  };
  return agentId;
}
