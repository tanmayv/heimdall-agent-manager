// Shared agent identity normalization helpers.
//
// Single source of truth for reading ids/labels/liveness off the many agent
// record shapes that flow through the UI (mapped agents, raw daemon records,
// durable identities, remote proxies). Used by AgentPickerV2 and any other
// surface that needs to render/select agents without re-deriving field access.

import { agentRemoteInfo, isRemoteProxyAgent, remoteAgentIsLive } from './agentRemote';

export type AgentEntityType = 'agent_id' | 'agent_instance_id';

export interface RemoteRef {
  daemonId: string;
  peerId: string;
}

export interface AgentSelection {
  type: AgentEntityType;
  id: string;              // always a LOCAL id (agent_id or local agent_instance_id)
  label?: string;
  live?: boolean;
  remote?: RemoteRef;      // display hint only; the id still addresses the local proxy
}

export function agentInstanceId(agent: any): string {
  return String(agent?.id || agent?.agentInstanceId || agent?.agent_instance_id || '');
}

export function durableAgentId(agent: any): string {
  const durable = String(agent?.agentId || agent?.agent_id || '');
  if (durable) return durable;
  const id = agentInstanceId(agent);
  const at = id.indexOf('@');
  return at >= 0 ? id.slice(0, at) : id;
}

export function agentLabel(agent: any): string {
  return String(
    agent?.label || agent?.displayName || agent?.display_name || agentInstanceId(agent) || durableAgentId(agent) || 'Agent',
  );
}

export function agentTemplate(agent: any): string {
  return String(agent?.templateId || agent?.template_id || durableAgentId(agent));
}

export function agentProvider(agent: any): string {
  return String(agent?.providerProfile || agent?.provider_profile || '');
}

export function agentTier(agent: any): string {
  return String(agent?.modelTier || agent?.model_tier || 'normal') || 'normal';
}

export function agentProject(agent: any): string {
  return String(agent?.projectId || agent?.project_id || '');
}

function connectionState(agent: any): string {
  return String(agent?.connectionState || agent?.connection_state || '').toLowerCase();
}

// isAgentLive mirrors the liveness rules used across the app: a stopped /
// stopping / blocked instance is not live even if its durable state lingers;
// remote proxies defer to the propagated origin liveness.
export function isAgentLive(agent: any): boolean {
  if (isRemoteProxyAgent(agent)) return remoteAgentIsLive(agent);
  const startup = String(agent?.startupStatus || agent?.startup_status || '').toLowerCase();
  const state = String(agent?.state || agent?.status || '').toLowerCase();
  if (startup === 'stopped' || startup === 'stopping' || startup === 'startup_blocked' || startup === 'blocked') return false;
  if (agent?.connected || connectionState(agent) === 'connected') return true;
  return ['connected', 'ready', 'active', 'working', 'running', 'idle'].includes(state) && state !== 'offline';
}

// remoteRef returns the { daemonId, peerId } display hint for a remote proxy
// agent, or null for a purely local agent.
export function remoteRef(agent: any): RemoteRef | null {
  if (!isRemoteProxyAgent(agent)) {
    // durable identities may carry a lightweight remote hint
    const daemonId = String(agent?.remoteDaemonId || agent?.remote_daemon_id || '');
    const peerId = String(agent?.remotePeerId || agent?.remote_peer_id || '');
    if (daemonId || peerId) return { daemonId, peerId };
    return null;
  }
  const info = agentRemoteInfo(agent);
  if (!info) return null;
  return { daemonId: info.originDaemonId || info.peerId, peerId: info.peerId };
}

export function isUserProxy(agent: any): boolean {
  return agentInstanceId(agent) === 'user_proxy' || durableAgentId(agent) === 'user_proxy';
}

export function selectionKey(sel: { type: AgentEntityType; id: string }): string {
  return `${sel.type}:${sel.id}`;
}

// normalizeDefaultSelection accepts either AgentSelection[] or a bare string[]
// of ids (assumed agent_instance_id unless a type is supplied) and returns a
// keyed set plus the normalized selections.
export function normalizeDefaultSelection(
  input: AgentSelection[] | string[] | undefined,
  fallbackType: AgentEntityType,
): AgentSelection[] {
  if (!input || input.length === 0) return [];
  const out: AgentSelection[] = [];
  for (const item of input) {
    if (typeof item === 'string') {
      const id = item.trim();
      if (id) out.push({ type: fallbackType, id });
    } else if (item && typeof item.id === 'string' && item.id.trim()) {
      out.push({ type: item.type || fallbackType, id: item.id.trim(), label: item.label, live: item.live, remote: item.remote });
    }
  }
  return out;
}
