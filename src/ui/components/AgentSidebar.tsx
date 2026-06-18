import AgentListItem from './AgentListItem';
import ConnectionBadge from './ConnectionBadge';

export default function AgentSidebar({ agents, selectedAgentId, session, onSelectAgent, onRefreshAgents, onOpenSettings }) {
  return (
    <aside className="flex h-full w-80 shrink-0 flex-col border-r border-slate-800 bg-slate-950/95 p-4">
      <div className="mb-4">
        <p className="text-xs font-semibold uppercase tracking-[0.3em] text-blue-300">Odin</p>
        <h1 className="mt-2 text-2xl font-bold text-white">Live Agents</h1>
        <p className="mt-1 text-sm text-slate-400">Connected daemon agents</p>
      </div>

      <ConnectionBadge session={session} />

      <div className="mt-5 flex items-center justify-between text-xs uppercase tracking-[0.2em] text-slate-500">
        <span>Agents</span>
        <div className="flex items-center gap-3">
          <button
            type="button"
            onClick={onOpenSettings}
            className="rounded-full border border-slate-800 px-3 py-1 text-[11px] font-semibold text-slate-200 transition-all duration-200 hover:border-blue-500/40 hover:bg-blue-500/10"
          >
            Settings
          </button>
          <button type="button" onClick={onRefreshAgents} className="text-blue-300 hover:text-blue-200">
            Refresh
          </button>
        </div>
      </div>

      <div className="mt-3 flex flex-1 flex-col gap-2 overflow-y-auto pr-1">
        {agents.length ? (
          agents.map((agent) => (
            <AgentListItem
              key={agent.id}
              agent={agent}
              selected={agent.id === selectedAgentId}
              onSelect={() => onSelectAgent(agent.id)}
            />
          ))
        ) : (
          <div className="rounded-2xl border border-dashed border-slate-800 p-4 text-sm text-slate-500">
            No connected agents reported by the daemon yet.
          </div>
        )}
      </div>
    </aside>
  );
}
