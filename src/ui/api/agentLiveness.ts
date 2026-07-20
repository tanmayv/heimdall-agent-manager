// Canonical agent liveness check. Previously forked between App.tsx and
// chat/ChatWorkBanner.tsx; unified here so the remote-proxy branch lives in one
// place (docs/plans/remote-proxy-stop-and-liveness.md, C2/C3).

import { isRemoteProxyAgent, remoteAgentIsLive } from './agentRemote';

export function agentHasLiveSession(agent: any): boolean {
  if (!agent) return false;
  const connection = String(agent.connectionState || agent.connection_state || '').toLowerCase();
  const startup = String(agent.startupStatus || agent.startup_status || '').toLowerCase();
  const status = String(agent.status || '').toLowerCase();
  const state = String(agent.state || '').toLowerCase();
  const execState = String(agent.execState || agent.exec_state || '').toLowerCase();
  const connected = Boolean(agent.connected) || connection === 'connected';
  // Remote proxies never register locally; their liveness reflects the real
  // remote instance's propagated status (Part B), not the local socket.
  if (isRemoteProxyAgent(agent)) return remoteAgentIsLive(agent);
  if (connected) return true;
  if (startup === 'stopped' || startup === 'stopping') return false;
  if (connection === 'offline' || connection === 'disconnected') return false;
  if (['offline', 'stopped', 'disconnected', 'archived', 'missing'].includes(status) || ['offline', 'stopped', 'disconnected', 'archived', 'missing'].includes(state)) return false;
  if (agent.currentTaskId || agent.current_task_id) return true;
  if (['ready', 'start_success', 'connected'].includes(startup)) return true;
  if (['ready', 'live', 'connected', 'idle', 'working', 'active'].includes(status) || ['ready', 'live', 'connected', 'idle', 'working'].includes(state)) return true;
  if (execState === 'running') return true;
  return false;
}
