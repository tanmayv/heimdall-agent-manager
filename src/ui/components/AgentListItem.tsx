const statusStyles = {
  connected: 'bg-emerald-400 shadow-emerald-400/40',
  idle: 'bg-amber-300 shadow-amber-300/30',
  offline: 'bg-slate-500 shadow-slate-500/20',
};

export default function AgentListItem({ agent, selected, onSelect }) {
  return (
    <button
      type="button"
      onClick={onSelect}
      className={`animate-float-in group relative w-full overflow-hidden rounded-[1.5rem] border p-3 text-left transition-all duration-300 hover:-translate-y-0.5 hover:scale-[1.01] hover:border-blue-400/50 hover:bg-slate-800/80 hover:shadow-lg hover:shadow-blue-950/30 ${
        selected ? 'animate-halo-breathe border-blue-400/70 bg-blue-500/10 shadow-lg shadow-blue-500/10' : 'border-transparent bg-slate-900/60'
      }`}
    >
      <div className="pointer-events-none absolute inset-0 rounded-[1.5rem] bg-gradient-to-r from-blue-400/0 via-blue-300/5 to-emerald-300/0 opacity-0 transition-opacity duration-300 group-hover:opacity-100" />
      <div className="relative flex items-start justify-between gap-3">
        <div className="min-w-0">
          <div className="flex items-center gap-2">
            <span className={`h-2.5 w-2.5 rounded-full shadow ${agent.status === 'connected' ? 'animate-soft-pulse' : ''} ${statusStyles[agent.status] ?? statusStyles.offline}`} />
            <p className="truncate text-sm font-semibold text-slate-100 transition-transform duration-300 group-hover:translate-x-0.5">{agent.label}</p>
          </div>
          <p className="mt-1 truncate font-mono text-xs text-slate-400">{agent.id}</p>
          <p className="mt-2 text-xs text-slate-500">Last seen {agent.lastSeen}</p>
        </div>
        {agent.unreadCount > 0 ? (
          <span className="rounded-full bg-blue-500 px-2 py-0.5 text-xs font-bold text-white">{agent.unreadCount}</span>
        ) : null}
      </div>
    </button>
  );
}
