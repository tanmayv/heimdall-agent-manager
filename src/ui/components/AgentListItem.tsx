import { useSelector } from 'react-redux';

const statusStyles = {
  connected: 'bg-emerald-400 shadow-emerald-400/40',
  starting: 'bg-sky-400 shadow-sky-400/40',
  startup_blocked: 'bg-amber-400 shadow-amber-400/40',
  startup_failed: 'bg-red-400 shadow-red-400/40',
  startup_unknown: 'bg-violet-400 shadow-violet-400/40',
  idle: 'bg-[var(--fd-hairline)] shadow-[var(--fd-hairline)]/30',
  offline: 'bg-[#999999]/70 shadow-[#999999]/20',
};

const statusLabels = {
  connected: 'Live connection',
  starting: 'Starting',
  startup_blocked: 'Startup blocked',
  startup_failed: 'Startup failed',
  startup_unknown: 'Startup unknown',
  offline: 'Known agent',
};

function defaultSuggestedFix(agent) {
  if (agent.startupSuggestedFix) return agent.startupSuggestedFix;
  if (agent.status === 'startup_blocked') return 'Open the agent terminal and approve any required provider prompt, such as Claude directory trust, then retry/restart.';
  if (agent.status === 'startup_failed') return 'Check the wrapper log or tmux target, fix the startup issue, then retry/restart.';
  if (agent.status === 'startup_unknown') return 'Refresh agent status or inspect the wrapper log if startup does not complete.';
  return '';
}

export default function AgentListItem({ 
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
  onSelect: () => void; 
  onStart: () => void;
  onStop: () => void;
  hideProject?: boolean; 
  warningDismissed?: boolean; 
  onDismissWarning?: () => void 
}) {
  const startupIssue = !warningDismissed && (agent.status === 'startup_blocked' || agent.status === 'startup_failed' || agent.status === 'startup_unknown');
  const suggestedFix = defaultSuggestedFix(agent);
  const projectsById = useSelector((state: any) => state.projects?.projectsById ?? {});
  const projectLabel = agent.projectId ? (projectsById[agent.projectId]?.name || agent.projectName || agent.projectId) : '';
  const isRunning = agent.status === 'connected' || agent.status === 'starting';

  return (
    <div
      className={`animate-float-in group relative w-full overflow-hidden rounded-[var(--fd-radius-xl)] border transition-all duration-300 hover:-translate-y-0.5 hover:scale-[1.01] hover:border-[var(--fd-accent-blue)]/60 hover:bg-[var(--fd-surface-2)] ${
        selected
          ? 'animate-halo-breathe border-[var(--fd-accent-blue)]/70 bg-[var(--fd-surface-2)] shadow-lg shadow-[var(--fd-accent-blue)]/20'
          : 'border-[var(--fd-hairline)] bg-[var(--fd-surface-1)]'
      }`}
    >
      <div className="pointer-events-none absolute inset-0 rounded-[var(--fd-radius-xl)] bg-[linear-gradient(120deg,transparent,rgba(255,255,255,0.05),transparent)] opacity-0 transition-opacity duration-300 group-hover:opacity-100" />
      <div 
        onClick={onSelect}
        className="relative flex items-start justify-between gap-3 p-3 cursor-pointer"
      >
        <div className="min-w-0 flex-1 text-left">
          <div className="flex items-center gap-2">
            <span
              className={`h-2.5 w-2.5 rounded-full shadow ${
                agent.status === 'connected' ? 'animate-soft-pulse' : ''
              } ${statusStyles[agent.status] ?? statusStyles.offline}`}
            />
            <p className="truncate text-sm font-semibold text-white transition-transform duration-300 group-hover:translate-x-0.5">{agent.label}</p>
            <span className={`shrink-0 rounded-full px-1.5 py-0.5 text-[9px] font-semibold uppercase tracking-wider ${
              agent.modelTier === 'smart' ? 'bg-violet-500/20 text-violet-300' :
              agent.modelTier === 'cheap' ? 'bg-amber-500/15 text-amber-400' :
              'border border-[var(--fd-hairline)] text-[#666]'
            }`}>{agent.modelTier || 'normal'}</span>
          </div>
          <p className="framer-subtext mt-1 truncate">{agent.templateId || 'agent'} · {agent.providerProfile || 'provider'}</p>
          <p className="framer-subtext mt-2 text-[#999]">{statusLabels[agent.status] || 'Known agent'} · Last seen {agent.lastSeen}</p>
          {startupIssue ? (
            <div className="mt-2 rounded-xl border border-amber-400/25 bg-amber-400/10 p-2 text-left text-[11px] leading-4 text-amber-100">
              <div className="flex items-start justify-between gap-2">
                <p className="font-semibold">{agent.startupReason || 'Startup needs attention.'}</p>
                {agent.status === 'startup_unknown' && onDismissWarning ? (
                  <button
                    type="button"
                    data-debug-id={`agent-item-dismiss-warning-${agent.id}`}
                    onClick={(e) => { e.stopPropagation(); onDismissWarning(); }}
                    className="shrink-0 rounded px-1.5 py-0.5 text-[10px] font-semibold text-amber-300 transition hover:bg-amber-400/20 hover:text-amber-100"
                  >
                    Dismiss
                  </button>
                ) : null}
              </div>
              {suggestedFix ? <p className="mt-1 text-amber-100/80">Fix: {suggestedFix}</p> : null}
              {(agent.runDir || agent.tmuxTarget || agent.logPath) ? (
                <p className="mt-1 break-all text-amber-100/70">
                  {agent.runDir ? `Run dir: ${agent.runDir}` : ''}
                  {agent.tmuxTarget ? `${agent.runDir ? ' · ' : ''}Tmux: ${agent.tmuxTarget}` : ''}
                  {agent.logPath ? `${agent.runDir || agent.tmuxTarget ? ' · ' : ''}Log: ${agent.logPath}` : ''}
                </p>
              ) : null}
            </div>
          ) : null}
          {((!hideProject && agent.projectId) || agent.templateId || agent.providerProfile || agent.roleHint) ? (
            <p className="mt-2 line-clamp-2 text-left text-[11px] leading-4 text-[#aaa]">
              {!hideProject && agent.projectId ? `Project ${projectLabel}` : ''}
              {agent.templateId ? `${!hideProject && agent.projectId ? ' · ' : ''}Template ${agent.templateId}` : ''}
              {agent.providerProfile ? `${(!hideProject && agent.projectId) || agent.templateId ? ' · ' : ''}Provider ${agent.providerProfile}` : ''}
              {agent.roleHint ? `${(!hideProject && agent.projectId) || agent.templateId || agent.providerProfile ? ' · ' : ''}Role ${agent.roleHint}` : ''}
            </p>
          ) : null}
        </div>
        
        {/* Actions Column */}
        <div className="flex flex-col items-end gap-2 shrink-0">
          {agent.unreadCount > 0 ? (
            <span className="rounded-full bg-[var(--fd-accent-blue)] px-2 py-0.5 text-[11px] font-bold text-black">
              {agent.unreadCount}
            </span>
          ) : null}
          
          {isRunning ? (
            <button
              type="button"
              data-debug-id={`agent-item-stop-btn-${agent.id}`}
              onClick={(e) => { e.stopPropagation(); onStop(); }}
              className="rounded-md border border-red-500/30 bg-red-500/10 px-2.5 py-1 text-[10px] font-bold uppercase tracking-wider text-red-400 transition hover:bg-red-500 hover:text-white hover:border-red-500"
              title="Stop agent daemon wrapper process"
            >
              Stop
            </button>
          ) : (
            <button
              type="button"
              data-debug-id={`agent-item-start-btn-${agent.id}`}
              onClick={(e) => { e.stopPropagation(); onStart(); }}
              className="rounded-md border border-emerald-500/30 bg-emerald-500/10 px-2.5 py-1 text-[10px] font-bold uppercase tracking-wider text-emerald-400 transition hover:bg-emerald-505 hover:bg-emerald-500 hover:text-black hover:border-emerald-500"
              title="Start agent daemon wrapper process"
            >
              Start
            </button>
          )}
        </div>
      </div>
    </div>
  );
}
