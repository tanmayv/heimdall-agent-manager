import { memo, useState, useEffect } from 'react';
import { useSelector } from 'react-redux';
import { Play, Square } from 'lucide-react';

const statusStyles = {
  connected: 'bg-emerald-400 shadow-emerald-400/40',
  starting: 'bg-sky-400 shadow-sky-400/40',
  startup_blocked: 'bg-amber-400 shadow-amber-400/40',
  startup_failed: 'bg-red-400 shadow-red-400/40',
  startup_unknown: 'bg-violet-400 shadow-violet-400/40',
  idle: 'bg-[var(--fd-hairline)] shadow-[var(--fd-hairline)]/30',
  stopping: 'bg-amber-400 shadow-amber-400/40 animate-soft-pulse',
  offline: 'bg-[#999999]/70 shadow-[#999999]/20',
};

const statusLabels = {
  connected: 'Running',
  starting: 'Starting',
  startup_blocked: 'Blocked',
  startup_failed: 'Startup failed',
  startup_unknown: 'Startup unknown',
  idle: 'Connected (Idle)',
  stopping: 'Stopping',
  offline: 'Offline',
};

function defaultSuggestedFix(agent) {
  if (agent.startupSuggestedFix) return agent.startupSuggestedFix;
  if (agent.status === 'startup_blocked') return 'Open the agent terminal and approve any required provider prompt, such as Claude directory trust, then retry/restart.';
  if (agent.status === 'startup_failed') return 'Check the wrapper log or tmux target, fix the startup issue, then retry/restart.';
  if (agent.status === 'startup_unknown') return 'Refresh agent status or inspect the wrapper log if startup does not complete.';
  return '';
}

function StoppingLabel({ agent }: { agent: any }) {
  const [remaining, setRemaining] = useState<number | null>(null);

  useEffect(() => {
    if (!agent.stopRequestedUnixMs || !agent.stopTimeoutSeconds) {
      setRemaining(null);
      return;
    }

    const calculateRemaining = () => {
      const elapsedMs = Date.now() - agent.stopRequestedUnixMs;
      const elapsedSec = Math.floor(elapsedMs / 1000);
      const rem = Math.max(0, agent.stopTimeoutSeconds - elapsedSec);
      setRemaining(rem);
    };

    calculateRemaining();
    const interval = window.setInterval(calculateRemaining, 1000);
    return () => window.clearInterval(interval);
  }, [agent.stopRequestedUnixMs, agent.stopTimeoutSeconds]);

  if (remaining === null) return <span>Stopping...</span>;
  return <span>Stopping ({remaining}s remaining)</span>;
}

const AgentListItem = memo(function AgentListItem({ 
  agent, 
  selected, 
  onSelect, 
  onStart,
  onStop,
  hideProject = false, 
  warningDismissed = false, 
  onDismissWarning 
}: { 
  agent: any; 
  selected: boolean; 
  onSelect: (id: string) => void; 
  onStart: (agent: any) => void;
  onStop: (id: string) => void;
  hideProject?: boolean; 
  warningDismissed?: boolean; 
  onDismissWarning?: (id: string) => void 
}) {
  console.log('[Render] AgentListItem', agent.id);
  const startupIssue = !warningDismissed && (agent.status === 'startup_blocked' || agent.status === 'startup_failed' || agent.status === 'startup_unknown');
  const suggestedFix = defaultSuggestedFix(agent);
  
  const isRunning = agent.status === 'connected' || agent.status === 'starting' || agent.status === 'idle' || agent.status === 'startup_blocked';

  return (
    <div
      className={`group relative w-full overflow-hidden rounded-[var(--fd-radius-xl)] border transition-[transform,colors] duration-300 hover:border-[var(--fd-accent-blue)]/60 hover:bg-[var(--fd-surface-2)] ${
        selected
          ? 'animate-halo-breathe border-[var(--fd-accent-blue)]/70 bg-[var(--fd-surface-2)] shadow-lg shadow-[var(--fd-accent-blue)]/20'
          : 'border-[var(--fd-hairline)] bg-[var(--fd-surface-1)]'
      }`}
    >
      <div className="pointer-events-none absolute inset-0 rounded-[var(--fd-radius-xl)] bg-[linear-gradient(120deg,transparent,rgba(255,255,255,0.05),transparent)] opacity-0 transition-opacity duration-300 group-hover:opacity-100" />
      <div 
        onClick={() => onSelect(agent.id)}
        className="relative flex items-center justify-between gap-2.5 p-2.5 cursor-pointer"
      >
        <div className="min-w-0 flex-1 text-left">
          {/* Line 1: Status dot, label, and tier icon indicator */}
          <div className="flex items-center gap-2 min-w-0">
            <span
              className={`h-2 w-2 rounded-full shadow ${
                agent.status === 'connected' ? 'animate-soft-pulse' : ''
              } ${statusStyles[agent.status] ?? statusStyles.offline}`}
            />
            <p className="truncate text-xs font-semibold text-white">{agent.label}</p>
            <span className={`shrink-0 rounded-full px-1 py-0.5 text-[8px] font-semibold uppercase tracking-wider ${
              agent.modelTier === 'smart' ? 'bg-violet-500/20 text-violet-300' :
              agent.modelTier === 'cheap' ? 'bg-amber-500/15 text-amber-400' :
              'border border-[var(--fd-hairline)] text-[#666]'
            }`}>{agent.modelTier || 'normal'}</span>
          </div>

          {/* Line 2: inline template & status text */}
          <p className="framer-subtext mt-0.5 truncate text-[10px] text-[#aaa]">
            {agent.templateId || 'agent'}
            {agent.providerProfile && ` (${agent.providerProfile})`}
            {' · '}
            {agent.status === 'stopping' ? (
              <StoppingLabel agent={agent} />
            ) : (
              statusLabels[agent.status] || 'Known agent'
            )}
          </p>

          {/* Line 3: Last seen timestamp or compact inline warning */}
          {startupIssue ? (
            <div className="flex items-center justify-between gap-1 text-[10px] text-amber-400 font-medium mt-0.5 w-full min-w-0">
              <span className="truncate" title={suggestedFix}>⚠️ {agent.startupReason || 'Startup needs attention'}</span>
              {agent.status === 'startup_unknown' && onDismissWarning && (
                <button
                  type="button"
                  onClick={(e) => { e.stopPropagation(); onDismissWarning(agent.id); }}
                  className="text-[9px] text-amber-300 hover:text-white underline px-1 rounded shrink-0"
                >
                  Dismiss
                </button>
              )}
            </div>
          ) : agent.status === 'offline' ? null : (
            <p className="framer-subtext mt-0.5 text-[#777] text-[9px] truncate">
              Last seen {agent.lastSeen}
            </p>
          )}
        </div>
        
        {/* Actions Column */}
        <div className="flex flex-col items-end justify-center gap-1.5 shrink-0 self-center">
          {agent.unreadCount > 0 && (
            <span className="rounded-full bg-rose-500 px-1.5 py-0.5 text-[9px] font-extrabold text-white min-w-[16px] text-center shadow-sm">
              {agent.unreadCount}
            </span>
          )}
          
          {agent.status === 'stopping' ? (
            <div className="flex h-7 w-7 items-center justify-center rounded-md border border-amber-500/20 bg-amber-500/5 text-amber-400/40 cursor-not-allowed" title="Stopping...">
              <Square className="h-3 w-3 animate-pulse" />
            </div>
          ) : isRunning ? (
            <button
              type="button"
              data-debug-id={`agent-item-stop-btn-${agent.id}`}
              onClick={(e) => { e.stopPropagation(); onStop(agent.id); }}
              className="flex h-7 w-7 items-center justify-center rounded-md border border-red-500/30 bg-red-500/10 text-red-400 transition hover:bg-red-500 hover:text-white hover:border-red-500"
              title="Stop agent process"
            >
              <Square className="h-3 w-3 fill-current" />
            </button>
          ) : (
            <button
              type="button"
              data-debug-id={`agent-item-start-btn-${agent.id}`}
              onClick={(e) => { e.stopPropagation(); onStart(agent); }}
              className="flex h-7 w-7 items-center justify-center rounded-md border border-emerald-500/30 bg-emerald-500/10 text-emerald-400 transition hover:bg-emerald-500 hover:text-black hover:border-emerald-500"
              title="Start agent process"
            >
              <Play className="h-3 w-3 fill-current" />
            </button>
          )}
        </div>
      </div>
    </div>
  );
});

export default AgentListItem;
