import { useMemo, useState, memo, useCallback } from 'react';
import AgentListItem from './AgentListItem';
import ConnectionBadge from './ConnectionBadge';

function projectGroupKey(agent) {
  return agent.projectId || 'unassigned';
}

function projectGroupLabel(projectId, projectsById, agentsInGroup) {
  if (projectId === 'unassigned') return 'No project';
  const fromStore = projectsById?.[projectId]?.name;
  if (fromStore) return fromStore;
  for (const a of (agentsInGroup ?? [])) {
    if (a?.projectName) return a.projectName;
  }
  return projectId;
}

interface AgentSidebarProps {
  agents: any[];
  projectsById: Record<string, any>;
  selectedAgentId: string;
  session: any;
  activeView: string;
  onSelectAgent: (agentId: string) => void;
  onRefreshAgents: () => void;
  onStartAgent: (agent: any) => void;
  onStopAgent: (agentId: string) => void;
  onOpenChat: () => void;
  onOpenTasks: () => void;
  onOpenMemory: () => void;
  onOpenMemoryAudit: () => void;
  onOpenProjects: () => void;
  onOpenAgents: () => void;
  onOpenStartAgent: () => void;
  onOpenSettings: () => void;
  auditBadgeCount: number;
  onToggleAudit: () => void;
}

const AgentSidebar = memo(function AgentSidebar({
  agents,
  projectsById,
  selectedAgentId,
  session,
  activeView,
  onSelectAgent,
  onRefreshAgents,
  onStartAgent,
  onStopAgent,
  onOpenChat,
  onOpenTasks,
  onOpenMemory,
  onOpenMemoryAudit,
  onOpenProjects,
  onOpenAgents,
  onOpenStartAgent,
  onOpenSettings,
  auditBadgeCount,
  onToggleAudit
}: AgentSidebarProps) {
  console.log('[Render] AgentSidebar');
  const [collapsedProjects, setCollapsedProjects] = useState({});
  const [dismissedWarnings, setDismissedWarnings] = useState<Set<string>>(new Set());

  const dismissWarning = useCallback((agentId: string) => {
    setDismissedWarnings((prev) => new Set([...prev, agentId]));
  }, []);

  const handleRefresh = useCallback(() => {
    setDismissedWarnings(new Set());
    onRefreshAgents();
  }, [onRefreshAgents]);
  const projectGroups = useMemo(() => {
    const groups = new Map();
    for (const agent of agents) {
      const key = projectGroupKey(agent);
      if (!groups.has(key)) groups.set(key, []);
      groups.get(key).push(agent);
    }
    return Array.from(groups.entries()).sort(([left], [right]) => {
      if (left === 'unassigned') return 1;
      if (right === 'unassigned') return -1;
      return left.localeCompare(right);
    });
  }, [agents]);

  function toggleProjectGroup(projectId) {
    setCollapsedProjects((current) => ({ ...current, [projectId]: !current[projectId] }));
  }

  return (
    <aside className="framer-panel flex h-full w-80 shrink-0 flex-col border-r border-[var(--fd-hairline)] p-4">
      <div className="mb-4">
        <p className="framer-topline tracking-[0.28em]">Heimdall</p>
        <div className="mt-3 flex items-center gap-3 rounded-[var(--fd-radius-lg)] border border-[var(--fd-hairline)] bg-[var(--fd-surface-2)] p-3">
          <div className="flex h-8 w-8 shrink-0 items-center justify-center rounded-full bg-[var(--fd-accent-blue)]/20 text-xs font-bold text-[var(--fd-accent-blue)]">
            {(session?.userDisplayName || session?.userId || 'OP')[0].toUpperCase()}
          </div>
          <div className="min-w-0 flex-1">
            <span className="block truncate text-sm font-semibold text-white">
              {session?.userDisplayName || 'Operator'}
            </span>
            <span className="block truncate text-xs text-[#aaa]">
              {session?.userId || 'operator@local'}
            </span>
          </div>
        </div>
        <h1 className="mt-4 text-2xl font-bold text-white">Live Agents</h1>
        <p className="framer-subtext mt-1">Connected daemon agents</p>
      </div>

      <ConnectionBadge session={session} />

      <nav className="mt-4 grid grid-cols-2 gap-2">
        <button
          type="button"
          data-debug-id="nav-chat"
          onClick={onOpenChat}
          className={`${activeView === 'chat' ? 'framer-pill bg-white' : 'framer-pill-secondary'} px-3 py-2 text-xs`}
        >
          Chat
        </button>
        <button
          type="button"
          data-debug-id="nav-tasks"
          onClick={onOpenTasks}
          className={`${activeView === 'tasks' ? 'framer-pill bg-white' : 'framer-pill-secondary'} px-3 py-2 text-xs`}
        >
          Tasks
        </button>
        <button
          type="button"
          data-debug-id="nav-memory"
          onClick={onOpenMemory}
          className={`${activeView === 'memory' ? 'framer-pill bg-white' : 'framer-pill-secondary'} px-3 py-2 text-xs`}
        >
          Memory
        </button>
        <button
          type="button"
          data-debug-id="nav-memory-audit"
          onClick={onOpenMemoryAudit}
          className={`${activeView === 'memoryAudit' ? 'framer-pill bg-white' : 'framer-pill-secondary'} px-3 py-2 text-xs`}
        >
          Memory Audit
        </button>
        <button
          type="button"
          data-debug-id="nav-projects"
          onClick={onOpenProjects}
          className={`${activeView === 'projects' ? 'framer-pill bg-white' : 'framer-pill-secondary'} px-3 py-2 text-xs`}
        >
          Projects
        </button>
        <button
          type="button"
          data-debug-id="nav-agents"
          onClick={onOpenAgents}
          className={`${activeView === 'agents' ? 'framer-pill bg-white' : 'framer-pill-secondary'} px-3 py-2 text-xs`}
        >
          Agents
        </button>
        <button
          type="button"
          data-debug-id="nav-settings"
          onClick={onOpenSettings}
          className={`${activeView === 'settings' ? 'framer-pill bg-white' : 'framer-pill-secondary'} px-3 py-2 text-xs col-span-2`}
        >
          Settings
        </button>
        <button
          type="button"
          data-debug-id="nav-audit"
          onClick={onToggleAudit}
          className="framer-pill-secondary px-3 py-2 text-xs relative flex items-center justify-center gap-1.5 border border-[#333] hover:border-[#555] col-span-2 mt-1"
        >
          <span>Task Chain Audit</span>
          {auditBadgeCount > 0 && (
            <span className="bg-red-500 text-white text-[9px] font-extrabold px-1.5 py-0.5 rounded-full animate-pulse shadow-sm">
              {auditBadgeCount}
            </span>
          )}
        </button>
      </nav>

      <div className="framer-topline mt-5 flex items-center justify-between">
        <span>Agents</span>
        <div className="flex items-center gap-2">
          <button
            type="button"
            data-debug-id="new-agent-btn"
            onClick={onOpenStartAgent}
            className="flex h-7 w-7 items-center justify-center rounded-full border border-[var(--fd-accent-blue)]/40 bg-[var(--fd-accent-blue)]/10 text-base leading-none text-[var(--fd-accent-blue)] transition hover:scale-105 hover:bg-[var(--fd-accent-blue)] hover:text-black"
            aria-label="Start new agent"
            title="Start new agent"
          >
            <svg viewBox="0 0 16 16" aria-hidden="true" className="h-3.5 w-3.5" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round">
              <path d="M8 3.5v9M3.5 8h9" />
            </svg>
          </button>
          <button
            type="button"
            data-debug-id="refresh-agents-btn"
            onClick={handleRefresh}
            className="framer-topline text-[11px] text-[var(--fd-accent-blue)] transition-colors duration-200 hover:text-white"
          >
            Refresh
          </button>
        </div>
      </div>

      <div className="mt-3 flex flex-1 flex-col gap-3 overflow-y-auto pr-1">
        {agents.length ? (
          projectGroups.map(([projectId, groupAgents]) => {
            const collapsed = Boolean(collapsedProjects[projectId]);
            const connectedCount = groupAgents.filter((agent) => agent.status === 'connected').length;
            return (
              <section key={projectId} className="space-y-2">
                <button
                  type="button"
                  data-debug-id={`project-group-toggle-${projectId}`}
                  onClick={() => toggleProjectGroup(projectId)}
                  className="flex w-full items-center justify-between rounded-[var(--fd-radius-lg)] border border-[var(--fd-hairline)] bg-[var(--fd-surface-2)] px-3 py-2 text-left transition hover:border-[var(--fd-accent-blue)]/50"
                >
                  <span className="min-w-0">
                    <span className="block truncate text-xs font-semibold uppercase tracking-[0.18em] text-white">{projectGroupLabel(projectId, projectsById, groupAgents)}</span>
                    <span className="framer-subtext text-[11px]">{groupAgents.length} known · {connectedCount} live</span>
                  </span>
                  <span className="text-sm text-[#aaa]">{collapsed ? '▸' : '▾'}</span>
                </button>
                {!collapsed ? groupAgents.map((agent) => (
                  <AgentListItem
                    key={agent.id}
                    agent={agent}
                    selected={agent.id === selectedAgentId}
                    onSelect={onSelectAgent}
                    hideProject
                    warningDismissed={dismissedWarnings.has(agent.id)}
                    onDismissWarning={dismissWarning}
                    onStart={onStartAgent}
                    onStop={onStopAgent}
                  />
                )) : null}
              </section>
            );
          })
        ) : (
          <div className="framer-card border border-dashed border-[var(--fd-hairline)] p-4 text-sm text-[#999]">
            No connected or known agents reported by the daemon yet.
          </div>
        )}
      </div>
    </aside>
  );
});
export default AgentSidebar;
