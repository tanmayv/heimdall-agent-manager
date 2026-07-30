import { isRemoteProxyAgent } from '../../api/agentRemote';
import { agentHasLiveSession } from '../../api/agentLiveness';

const PI_ACTIVITY_STALE_MS = 20_000;

type BannerMode = 'working' | 'idle' | 'stopped' | '';

function hasCurrentTask(agent: any): boolean {
  return Boolean(agent?.currentTaskId || agent?.current_task_id);
}

function activitySummary(agent: any): string {
  return String(agent?.activitySummary || agent?.activity_summary || '').trim();
}

function freshActivity(agent: any): string {
  const activity = String(agent?.activityStatus || agent?.activity_status || '').toLowerCase();
  const source = String(agent?.activitySource || agent?.activity_source || '').toLowerCase();
  const checked = Number(agent?.activityCheckedUnixMs ?? agent?.activity_checked_unix_ms ?? 0);
  if (activity === 'active' && source.startsWith('pi_extension') && checked > 0 && Date.now() - checked > PI_ACTIVITY_STALE_MS) return 'unknown';
  return activity;
}

function agentWorkingBannerState(agent: any): BannerMode {
  if (!agent?.id && !agent?.agent_instance_id && !agent?.agentInstanceId) return '';
  const live = agentHasLiveSession(agent);
  const activity = freshActivity(agent);
  const status = String(agent.status || '').toLowerCase();
  const state = String(agent.state || '').toLowerCase();
  const startup = String(agent.startupStatus || agent.startup_status || '').toLowerCase();
  if (isRemoteProxyAgent(agent)) return '';
  if (!live || startup === 'stopped' || status === 'offline' || status === 'stopped' || state === 'stopped') return 'stopped';
  if (activity === 'active' || status === 'active' || status === 'working' || state === 'working') return 'working';
  if (activity === 'idle' || status === 'idle' || state === 'idle') return (hasCurrentTask(agent) || activitySummary(agent)) ? 'idle' : '';
  if (hasCurrentTask(agent) || activitySummary(agent)) return 'idle';
  return '';
}

function agentCurrentTaskLabel(agent: any, tasksById: Record<string, any> = {}): string {
  const taskId = String(agent?.currentTaskId || agent?.current_task_id || '');
  if (!taskId) return '';
  const task = tasksById?.[taskId];
  return task?.title ? `Current task: ${task.title}` : `Current task: ${taskId}`;
}

export default function ChatWorkBanner({ agent, tasksById = {}, debugPrefix, onStart, startDisabled = false }: { agent: any; tasksById?: Record<string, any>; debugPrefix: string; onStart?: () => void; startDisabled?: boolean }) {
  const mode = agentWorkingBannerState(agent);
  if (!mode) return null;
  const label = agent?.label || agent?.displayName || agent?.id || 'Agent';
  const taskLabel = agentCurrentTaskLabel(agent, tasksById);
  const summary = activitySummary(agent);
  const dotClass = mode === 'working' ? 'animate-pulse bg-emerald-300' : mode === 'idle' ? 'bg-zinc-500' : 'bg-zinc-600';
  return (
    <div data-debug-id={`${debugPrefix}-status-banner`} className="mb-2 flex items-center gap-2 rounded-[14px] border border-white/10 bg-[#101010] px-3 py-2 text-[12px] text-zinc-300 shadow-[inset_0_1px_0_rgba(255,255,255,0.035)]">
      <span className={`h-2 w-2 shrink-0 rounded-full ${dotClass}`} />
      <div className="min-w-0 flex-1">
        <div className="truncate font-medium text-zinc-200">{label} is {mode}</div>
        {summary && mode === 'working' ? <div className="mt-0.5 truncate text-[11px] text-emerald-200/70">{summary}</div> : null}
        {taskLabel ? <div className="mt-0.5 truncate text-[11px] text-zinc-500">{taskLabel}</div> : null}
      </div>
      {mode === 'stopped' && onStart ? (
        <button data-debug-id={`${debugPrefix}-status-start-btn`} type="button" onClick={onStart} disabled={startDisabled} className="rounded-full border border-white/15 bg-zinc-200 px-2.5 py-1 text-[11px] font-semibold text-zinc-950 hover:bg-white disabled:cursor-not-allowed disabled:opacity-50">Start</button>
      ) : null}
    </div>
  );
}
