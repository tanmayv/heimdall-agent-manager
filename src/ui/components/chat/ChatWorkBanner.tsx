function agentRemoteInfo(agent: any): { peerId: string; remoteAgentInstanceId: string } | null {
  const remote = agent?.remote;
  if (remote) {
    const peerId = String(remote.peerId || remote.peer_id || '');
    const remoteAgentInstanceId = String(remote.remoteAgentInstanceId || remote.remote_agent_instance_id || '');
    if (peerId || remoteAgentInstanceId) return { peerId, remoteAgentInstanceId };
  }
  const peerId = String(agent?.remotePeerId || agent?.remote_peer_id || '');
  const remoteAgentInstanceId = String(agent?.remoteAgentInstanceId || agent?.remote_agent_instance_id || '');
  if (peerId || remoteAgentInstanceId) return { peerId, remoteAgentInstanceId };
  return null;
}

function isRemoteProxyAgent(agent: any): boolean {
  const kind = String(agent?.agentKind || agent?.agent_kind || '').toLowerCase();
  const remote = agentRemoteInfo(agent);
  return kind === 'remote_proxy' && Boolean(remote?.peerId) && Boolean(remote?.remoteAgentInstanceId);
}

function agentHasLiveSession(agent: any): boolean {
  if (!agent) return false;
  const status = String(agent.status || '').toLowerCase();
  const state = String(agent.state || '').toLowerCase();
  const startup = String(agent.startupStatus || agent.startup_status || '').toLowerCase();
  const execState = String(agent.execState || agent.exec_state || '').toLowerCase();
  if (isRemoteProxyAgent(agent)) return !['archived', 'missing', 'deleted'].includes(status) && !['archived', 'missing', 'deleted'].includes(state);
  if (['offline', 'stopped', 'disconnected', 'archived', 'missing'].includes(status) || ['offline', 'stopped', 'disconnected', 'archived', 'missing'].includes(state)) return false;
  if (agent.currentTaskId || agent.current_task_id) return true;
  if (['ready', 'start_success', 'connected'].includes(startup)) return true;
  if (['ready', 'live', 'connected', 'idle', 'working', 'active'].includes(status) || ['ready', 'live', 'connected', 'idle', 'working'].includes(state)) return true;
  if (execState === 'running') return true;
  return false;
}

function agentWorkingBannerState(agent: any): 'working' | 'stopped' | '' {
  if (!agent?.id && !agent?.agent_instance_id && !agent?.agentInstanceId) return '';
  const live = agentHasLiveSession(agent);
  const activity = String(agent.activityStatus || agent.activity_status || '').toLowerCase();
  const status = String(agent.status || '').toLowerCase();
  const state = String(agent.state || '').toLowerCase();
  const startup = String(agent.startupStatus || agent.startup_status || '').toLowerCase();
  if (isRemoteProxyAgent(agent)) return '';
  if (!live || startup === 'stopped' || status === 'offline' || status === 'stopped' || state === 'stopped') return 'stopped';
  if (activity === 'idle' || status === 'idle' || state === 'idle') return '';
  if (activity === 'active' || agent.currentTaskId || agent.current_task_id || status === 'active' || status === 'working' || state === 'working') return 'working';
  return '';
}

function agentCurrentTaskLabel(agent: any, tasksById: Record<string, any> = {}): string {
  const taskId = String(agent?.currentTaskId || agent?.current_task_id || '');
  if (!taskId) return '';
  const task = tasksById?.[taskId];
  return task?.title ? `Task: ${task.title}` : `Task: ${taskId}`;
}

export default function ChatWorkBanner({ agent, tasksById = {}, debugPrefix, onStart, startDisabled = false }: { agent: any; tasksById?: Record<string, any>; debugPrefix: string; onStart?: () => void; startDisabled?: boolean }) {
  const mode = agentWorkingBannerState(agent);
  if (!mode) return null;
  const label = agent?.label || agent?.displayName || agent?.id || 'Agent';
  const taskLabel = mode === 'working' ? agentCurrentTaskLabel(agent, tasksById) : '';
  return (
    <div data-debug-id={`${debugPrefix}-status-banner`} className="mb-2 flex items-center gap-2 rounded-[14px] border border-white/10 bg-[#101010] px-3 py-2 text-[12px] text-zinc-300 shadow-[inset_0_1px_0_rgba(255,255,255,0.035)]">
      <span className={`h-2 w-2 shrink-0 rounded-full ${mode === 'working' ? 'animate-pulse bg-zinc-300' : 'bg-zinc-600'}`} />
      <div className="min-w-0 flex-1">
        <div className="truncate font-medium text-zinc-200">{label} is {mode}</div>
        {taskLabel ? <div className="mt-0.5 truncate text-[11px] text-zinc-500">{taskLabel}</div> : null}
      </div>
      {mode === 'stopped' && onStart ? (
        <button data-debug-id={`${debugPrefix}-status-start-btn`} type="button" onClick={onStart} disabled={startDisabled} className="rounded-full border border-white/15 bg-zinc-200 px-2.5 py-1 text-[11px] font-semibold text-zinc-950 hover:bg-white disabled:cursor-not-allowed disabled:opacity-50">Start</button>
      ) : null}
    </div>
  );
}
