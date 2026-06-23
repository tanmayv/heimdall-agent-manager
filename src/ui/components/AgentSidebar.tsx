import { useMemo, useState, memo, useCallback } from 'react';
import AgentListItem from './AgentListItem';

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
  projectIds: string[];
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
  tasksBadgeCount?: number;
  onToggleAudit: () => void;
  onReorderProjects?: (projectIds: string[]) => void;
  onReorderAgents?: (agentIds: string[]) => void;
}

const AgentSidebar = memo(function AgentSidebar({
  agents,
  projectsById,
  projectIds,
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
  tasksBadgeCount = 0,
  onToggleAudit,
  onReorderProjects,
  onReorderAgents
}: AgentSidebarProps) {
  console.log('[Render] AgentSidebar');
  const [collapsedProjects, setCollapsedProjects] = useState({});
  const [dismissedWarnings, setDismissedWarnings] = useState<Set<string>>(new Set());
  const [dragOverProjectId, setDragOverProjectId] = useState<string | null>(null);
  const [dragOverAgentId, setDragOverAgentId] = useState<string | null>(null);

  const handleDragOverProject = useCallback((e: React.DragEvent, id: string) => {
    if (id === 'unassigned') return;
    e.preventDefault();
    setDragOverProjectId(id);
  }, []);

  const handleDragLeaveProject = useCallback(() => {
    setDragOverProjectId(null);
  }, []);

  const handleDragOverAgent = useCallback((e: React.DragEvent, id: string) => {
    e.preventDefault();
    setDragOverAgentId(id);
  }, []);

  const handleDragLeaveAgent = useCallback(() => {
    setDragOverAgentId(null);
  }, []);


  const handleDragStart = useCallback((e: React.DragEvent, id: string) => {
    if (id === 'unassigned') return;
    console.log('Drag start project:', id);
    e.dataTransfer.effectAllowed = 'move';
    e.dataTransfer.setData('text/plain', `project:${id}`);
  }, []);

  const handleDrop = useCallback((e: React.DragEvent, targetId: string) => {
    e.preventDefault();
    setDragOverProjectId(null);
    const rawData = e.dataTransfer.getData('text/plain');
    console.log('Drop project target:', targetId, 'rawData:', rawData, 'projectIds:', projectIds);
    if (!rawData.startsWith('project:')) return;
    const sourceId = rawData.substring('project:'.length);
    if (targetId === 'unassigned' || !sourceId || sourceId === targetId) return;

    const sourceIndex = projectIds.indexOf(sourceId);
    const targetIndex = projectIds.indexOf(targetId);
    console.log('Indices source:', sourceIndex, 'target:', targetIndex);
    if (sourceIndex < 0 || targetIndex < 0) return;

    const newProjectIds = [...projectIds];
    newProjectIds.splice(sourceIndex, 1);
    newProjectIds.splice(targetIndex, 0, sourceId);

    console.log('Calling onReorderProjects with:', newProjectIds);
    onReorderProjects?.(newProjectIds);
  }, [projectIds, onReorderProjects]);

  const handleDragStartAgent = useCallback((e: React.DragEvent, id: string, projectId: string) => {
    console.log('Drag start agent:', id, 'project:', projectId);
    e.dataTransfer.effectAllowed = 'move';
    e.dataTransfer.setData('text/plain', `agent:${JSON.stringify({ id, projectId })}`);
  }, []);

  const handleDropAgent = useCallback((e: React.DragEvent, targetId: string, targetProjectId: string, groupAgents: any[]) => {
    e.preventDefault();
    setDragOverAgentId(null);
    const rawData = e.dataTransfer.getData('text/plain');
    console.log('Drop agent target:', targetId, 'project:', targetProjectId, 'rawData:', rawData);
    if (!rawData.startsWith('agent:')) return;
    const dataStr = rawData.substring('agent:'.length);
    try {
      const dragged = JSON.parse(dataStr) as { id: string; projectId: string };
      if (!dragged || dragged.id === targetId) return;
      if (dragged.projectId !== targetProjectId) return;

      const agentIds = groupAgents.map((a) => a.id);
      const sourceIndex = agentIds.indexOf(dragged.id);
      const targetIndex = agentIds.indexOf(targetId);
      console.log('Agent indices source:', sourceIndex, 'target:', targetIndex);
      if (sourceIndex < 0 || targetIndex < 0) return;

      const newAgentIds = [...agentIds];
      newAgentIds.splice(sourceIndex, 1);
      newAgentIds.splice(targetIndex, 0, dragged.id);

      console.log('Calling onReorderAgents with:', newAgentIds);
      onReorderAgents?.(newAgentIds);
    } catch (err) {
      console.error('Failed to parse dragged agent data:', err);
    }
  }, [onReorderAgents]);

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
      const leftOrder = projectsById?.[left]?.order ?? 0;
      const rightOrder = projectsById?.[right]?.order ?? 0;
      const diff = leftOrder - rightOrder;
      if (diff !== 0) return diff;
      return left.localeCompare(right);
    });
  }, [agents, projectsById]);

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
            <div className="flex items-center gap-2">
              <span className="truncate text-sm font-semibold text-white">
                {session?.userDisplayName || 'Operator'}
              </span>
              <span
                className={`h-2 w-2 rounded-full shrink-0 ${
                  session?.status === 'connected'
                    ? (session?.wsStatus === 'connected' ? 'bg-emerald-400' : 'bg-amber-400')
                    : 'bg-rose-500'
                }`}
                title={
                  session?.status === 'connected'
                    ? (session?.wsStatus === 'connected' ? 'Daemon + WS Connected' : 'Daemon Connected (No WS)')
                    : 'Daemon Offline'
                }
              />
            </div>
            <span className="block truncate text-xs text-[#aaa]">
              {session?.userId || 'operator@local'}
            </span>
          </div>
        </div>
      </div>

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
          className={`${activeView === 'tasks' ? 'framer-pill bg-white' : 'framer-pill-secondary'} px-3 py-2 text-xs flex items-center justify-center gap-1.5`}
        >
          <span>Tasks</span>
          {Boolean(tasksBadgeCount) && tasksBadgeCount > 0 && (
            <span className="bg-red-600 text-white rounded-full px-1.5 py-0.2 text-[10px] font-bold">
              {tasksBadgeCount}
            </span>
          )}
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
            className="flex h-7 w-7 items-center justify-center rounded-full border border-[var(--fd-accent-blue)]/40 bg-[var(--fd-accent-blue)]/10 text-base leading-none text-[var(--fd-accent-blue)] transition  hover:bg-[var(--fd-accent-blue)] hover:text-black"
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
                  draggable={projectId !== 'unassigned'}
                  onDragStart={(e) => handleDragStart(e, projectId)}
                  onDragOver={(e) => handleDragOverProject(e, projectId)}
                  onDragLeave={handleDragLeaveProject}
                  onDrop={(e) => handleDrop(e, projectId)}
                  onClick={() => toggleProjectGroup(projectId)}
                  className={`flex w-full items-center justify-between rounded-[var(--fd-radius-lg)] border px-3 py-2 text-left transition hover:border-[var(--fd-accent-blue)]/50 ${
                    dragOverProjectId === projectId
                      ? 'border-[var(--fd-accent-blue)] bg-[var(--fd-surface-3)]'
                      : 'border-[var(--fd-hairline)] bg-[var(--fd-surface-2)]'
                  } ${
                    projectId !== 'unassigned' ? 'cursor-grab active:cursor-grabbing' : ''
                  }`}
                >
                  <span className="min-w-0">
                    <span className="block truncate text-xs font-semibold uppercase tracking-[0.18em] text-white">{projectGroupLabel(projectId, projectsById, groupAgents)}</span>
                    <span className="framer-subtext text-[11px]">{groupAgents.length} known · {connectedCount} live</span>
                  </span>
                  <span className="text-sm text-[#aaa]">{collapsed ? '▸' : '▾'}</span>
                </button>
                {!collapsed ? groupAgents.map((agent) => (
                  <div
                    key={agent.id}
                    draggable
                    onDragStart={(e) => handleDragStartAgent(e, agent.id, projectId)}
                    onDragOver={(e) => handleDragOverAgent(e, agent.id)}
                    onDragLeave={handleDragLeaveAgent}
                    onDrop={(e) => handleDropAgent(e, agent.id, projectId, groupAgents)}
                    className={`cursor-grab active:cursor-grabbing rounded-[var(--fd-radius-lg)] border transition-all duration-200 ${
                      dragOverAgentId === agent.id
                        ? 'border-[var(--fd-accent-blue)] bg-[var(--fd-accent-blue)]/5'
                        : 'border-transparent'
                    }`}
                  >
                    <AgentListItem
                      agent={agent}
                      selected={agent.id === selectedAgentId}
                      onSelect={onSelectAgent}
                      hideProject
                      warningDismissed={dismissedWarnings.has(agent.id)}
                      onDismissWarning={dismissWarning}
                      onStart={onStartAgent}
                      onStop={onStopAgent}
                    />
                  </div>
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
