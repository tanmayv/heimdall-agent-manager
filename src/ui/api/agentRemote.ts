// Shared remote-proxy helpers. Single source of truth for remote proxy
// detection, context labels, and real-liveness derived from the propagated
// origin status (see docs/plans/remote-proxy-stop-and-liveness.md, Part B).
//
// Prior to this module the same helpers were triplicated across App.tsx,
// chat/ChatWorkBanner.tsx, and AgentPicker.tsx with minor divergence. Keep one
// definition here and import it everywhere.

export interface AgentRemoteInfo {
  peerId: string;
  originDaemonId: string;
  remoteAgentInstanceId: string;
  // Real-liveness fields propagated from the origin daemon (Part B). Optional
  // because older/stale records may not carry them yet.
  status?: string;
  connectionState?: string;
  connected?: boolean;
  currentTaskId?: string;
  lastSeenUnixMs?: number;
  peerReachable?: boolean;
}

export type RemoteAgentStatus =
  | 'idle'
  | 'working'
  | 'starting'
  | 'stopping'
  | 'stopped'
  | 'offline'
  | 'blocked'
  | '';

const LIVE_REMOTE_STATUSES = new Set(['idle', 'working', 'starting']);

export function agentRemoteInfo(agent: any): AgentRemoteInfo | null {
  const remote = agent?.remote;
  if (remote) {
    const peerId = String(remote.peerId || remote.peer_id || '');
    const originDaemonId = String(remote.originDaemonId || remote.origin_daemon_id || '');
    const remoteAgentInstanceId = String(remote.remoteAgentInstanceId || remote.remote_agent_instance_id || '');
    const status = String(remote.status || '');
    const connectionState = String(remote.connectionState || remote.connection_state || '');
    const currentTaskId = String(remote.currentTaskId || remote.current_task_id || '');
    const lastSeenUnixMs = Number(remote.lastSeenUnixMs ?? remote.last_seen_unix_ms ?? 0);
    const connectedRaw = remote.connected;
    const peerReachableRaw = remote.peerReachable ?? remote.peer_reachable;
    if (peerId || originDaemonId || remoteAgentInstanceId) {
      return {
        peerId,
        originDaemonId,
        remoteAgentInstanceId,
        status,
        connectionState,
        connected: connectedRaw === undefined ? undefined : Boolean(connectedRaw),
        currentTaskId,
        lastSeenUnixMs,
        peerReachable: peerReachableRaw === undefined ? undefined : Boolean(peerReachableRaw),
      };
    }
  }
  const peerId = String(agent?.remotePeerId || agent?.remote_peer_id || '');
  const originDaemonId = String(agent?.remoteOriginDaemonId || agent?.remote_origin_daemon_id || agent?.originDaemonId || agent?.origin_daemon_id || '');
  const remoteAgentInstanceId = String(agent?.remoteAgentInstanceId || agent?.remote_agent_instance_id || '');
  if (peerId || originDaemonId || remoteAgentInstanceId) {
    return { peerId, originDaemonId, remoteAgentInstanceId };
  }
  return null;
}

export function isRemoteProxyAgent(agent: any): boolean {
  const kind = String(agent?.agentKind || agent?.agent_kind || '').toLowerCase();
  const remote = agentRemoteInfo(agent);
  return kind === 'remote_proxy' && Boolean(remote?.peerId) && Boolean(remote?.remoteAgentInstanceId);
}

// remoteAgentStatus normalizes the propagated origin status (Part B) for badge
// and label rendering. Returns '' when no status is known.
export function remoteAgentStatus(agent: any): RemoteAgentStatus {
  const remote = agentRemoteInfo(agent);
  if (!remote) return '';
  // Peer link unreachable overrides last-known status: report offline (B3).
  if (remote.peerReachable === false) return 'offline';
  const raw = String(remote.status || '').toLowerCase();
  switch (raw) {
    case 'idle':
    case 'working':
    case 'starting':
    case 'stopping':
    case 'stopped':
    case 'offline':
      return raw as RemoteAgentStatus;
    case 'startup_blocked':
    case 'startup_failed':
    case 'blocked':
      return 'blocked';
    default:
      break;
  }
  // Fall back to connection_state / connected when no explicit status.
  const connection = String(remote.connectionState || '').toLowerCase();
  if (connection === 'connected') return remote.currentTaskId ? 'working' : 'idle';
  if (connection === 'offline' || connection === 'disconnected') return 'offline';
  if (remote.connected === true) return remote.currentTaskId ? 'working' : 'idle';
  return '';
}

// remoteAgentIsLive returns true only when the peer link is reachable AND the
// origin's last-sent status is a live value (idle/working/starting). Falls back
// to false for stopped/offline/blocked/unknown or unreachable peers so a proxy
// to a stopped/unreachable agent reads as stopped, not falsely live.
export function remoteAgentIsLive(agent: any): boolean {
  const remote = agentRemoteInfo(agent);
  if (!remote) return false;
  if (remote.peerReachable === false) return false;
  const status = remoteAgentStatus(agent);
  return LIVE_REMOTE_STATUSES.has(status);
}

export function remoteProxyContext(agent: any): string {
  const remote = agentRemoteInfo(agent);
  if (!remote) return 'Remote agent proxy';
  const status = remoteAgentStatus(agent);
  const via = remote.originDaemonId || remote.peerId;
  const idPart = remote.remoteAgentInstanceId || 'agent';
  if (status) return `Remote · ${status} · ${idPart} via ${via}`;
  return `Remote · ${idPart} via ${via}`;
}
