// Canonical agent runtime status helpers. Previously these lived only in
// src/ui/components/App.tsx (legacy chrome). They are relocated here so live
// components and tests import them from a stable, dead-code-free location.
// Behavior is unchanged from the original App.tsx implementations.

function agentRuntimeDotTone(status: string): string {
  if (status === 'connected') return 'bg-emerald-400 shadow-emerald-400/40 animate-soft-pulse';
  if (status === 'idle' || status === 'ready') return 'bg-emerald-300 shadow-emerald-300/30';
  if (status === 'starting') return 'bg-sky-400 shadow-sky-400/40 animate-soft-pulse';
  if (status === 'startup_blocked' || status === 'stopping') return 'bg-amber-400 shadow-amber-400/40 animate-soft-pulse';
  if (status === 'startup_failed') return 'bg-red-400 shadow-red-400/40';
  if (status === 'startup_unknown') return 'bg-violet-400 shadow-violet-400/40';
  return 'bg-zinc-500/70 shadow-zinc-500/20';
}

export function agentRuntimeDot(agent: any): { color: string; label: string } {
  if (!agent) return { color: 'bg-zinc-500', label: 'unknown' };
  const startup = String(agent.startupStatus || '').toLowerCase();
  const state = String(agent.state || agent.status || '').toLowerCase();
  const activity = String(agent.activityStatus || agent.activity_status || '').toLowerCase();
  const blocked = agent.blockedReason || state === 'blocked' || startup === 'startup_blocked' || startup === 'blocked';
  const live = Boolean(agent.connected || startup === 'ready' || state === 'ready' || state === 'live' || state === 'connected' || state === 'idle');
  if (blocked) return { color: 'bg-red-400', label: 'blocked' };
  if (startup === 'startup_failed' || startup === 'startup_unknown') return { color: startup === 'startup_failed' ? 'bg-red-400' : 'bg-violet-400', label: startup.replace('startup_', '') };
  if (state === 'missing' || state === 'archived') return { color: 'bg-zinc-500', label: state };
  if (state === 'disconnected' || state === 'offline' || state === 'stopped') return { color: 'bg-zinc-500', label: state };
  if (startup === 'starting' || state === 'starting' || state === 'warming' || state === 'restarting') return { color: 'bg-amber-400 animate-pulse', label: startup || state || 'starting' };
  if (live && activity === 'active') return { color: 'bg-emerald-400', label: 'working' };
  if (live && activity === 'idle') return { color: 'bg-amber-300', label: 'idle' };
  if (live && agent.currentTaskId) return { color: 'bg-teal-400', label: 'working' };
  if (live) return { color: 'bg-emerald-400', label: state || 'connected' };
  return { color: 'bg-zinc-500', label: state || startup || 'unknown' };
}

export function isAgentRunning(agent: any): boolean {
  if (!agent) return false;
  const startup = String(agent.startupStatus || '').toLowerCase();
  const state = String(agent.state || agent.status || '').toLowerCase();
  const mappedStatus = String(agent.status || '').toLowerCase();
  if (agent.blockedReason || state === 'blocked' || startup === 'blocked' || startup === 'startup_blocked') return false;
  // An explicitly stopped/stopping instance is not running even if its durable
  // `state` field is still `idle`. The mapped status is `offline` for stopped
  // agents (see chatSlice), so a disconnected offline instance must not be
  // treated as live — otherwise the conversation thread hides its Start/resume
  // affordance after a stop.
  if (startup === 'stopped' || startup === 'stopping') return false;
  if (mappedStatus === 'offline' && !agent.connected) return false;
  if (agent.currentTaskId || agent.connected) return true;
  return ['ready', 'live', 'connected', 'working', 'active'].includes(state) || ['ready', 'connected'].includes(startup);
}

// Keep the tone helper exported for potential reuse; it is intentionally not
// used by the two functions' public contract but mirrors the original module.
export { agentRuntimeDotTone };
