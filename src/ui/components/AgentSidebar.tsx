import { useMemo, useState, memo, useCallback } from 'react';
import AgentListItem from './AgentListItem';
import { MessageSquare, ClipboardList, Brain, History, Folder, Bot, Settings, Activity, Pin, PinOff } from 'lucide-react';

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

const agentStatusColors: Record<string, string> = {
  connected: 'bg-emerald-400',
  starting: 'bg-sky-400',
  startup_blocked: 'bg-amber-400',
  startup_failed: 'bg-red-400',
  startup_unknown: 'bg-violet-400',
  idle: 'bg-gray-500',
  stopping: 'bg-amber-400 animate-pulse',
  offline: 'bg-gray-600',
};

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

  const [isPinned, setIsPinned] = useState(() => {
    return localStorage.getItem('sidebar_pinned') !== 'false';
  });
  const [isHovered, setIsHovered] = useState(false);

  const togglePin = useCallback(() => {
    setIsPinned((prev) => {
      const next = !prev;
      localStorage.setItem('sidebar_pinned', String(next));
      return next;
    });
  }, []);

  const handleMouseEnter = useCallback(() => {
    if (!isPinned) {
      setIsHovered(true);
    }
  }, [isPinned]);

  const handleMouseLeave = useCallback(() => {
    setIsHovered(false);
  }, []);

  const isExpanded = isPinned || isHovered;

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
    <aside
      onMouseEnter={handleMouseEnter}
      onMouseLeave={handleMouseLeave}
      className={`framer-panel flex h-full shrink-0 flex-col border-r border-[var(--fd-hairline)] p-4 transition-all duration-300 ease-in-out ${
        isExpanded ? 'w-72' : 'w-20'
      }`}
    >
      <div className="mb-4">
        <div className="flex items-center justify-between min-h-[20px]">
          {isExpanded ? (
            <p className="framer-topline tracking-[0.28em]">Heimdall</p>
          ) : (
            <p className="framer-topline tracking-[0.28em] text-center w-full">H</p>
          )}
        </div>
        <div className={`mt-3 flex items-center rounded-[var(--fd-radius-lg)] border border-[var(--fd-hairline)] bg-[var(--fd-surface-2)] transition-all ${isExpanded ? 'gap-3 p-3' : 'justify-center p-2'}`}>
          <div className="flex h-8 w-8 shrink-0 items-center justify-center rounded-full bg-[var(--fd-accent-blue)]/20 text-xs font-bold text-[var(--fd-accent-blue)]" title={session?.userDisplayName || 'Operator'}>
            {(session?.userDisplayName || session?.userId || 'OP')[0].toUpperCase()}
          </div>
          {isExpanded && (
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
          )}
        </div>
      </div>

      <nav className="mt-4 flex flex-col gap-1.5">
        <button
          type="button"
          data-debug-id="nav-chat"
          onClick={onOpenChat}
          className={`${activeView === 'chat' ? 'framer-pill bg-white text-black' : 'framer-pill-secondary'} w-full flex items-center ${isExpanded ? 'justify-between px-4 py-2.5' : 'justify-center p-2.5'} text-xs text-left`}
        >
          <div className="flex items-center gap-3">
            <MessageSquare className="h-4 w-4 shrink-0" />
            {isExpanded && <span>Chat</span>}
          </div>
        </button>
        <button
          type="button"
          data-debug-id="nav-tasks"
          onClick={onOpenTasks}
          className={`${activeView === 'tasks' ? 'framer-pill bg-white text-black' : 'framer-pill-secondary'} w-full flex items-center ${isExpanded ? 'justify-between px-4 py-2.5' : 'justify-center p-2.5 relative'} text-xs text-left`}
        >
          <div className="flex items-center gap-3">
            <ClipboardList className="h-4 w-4 shrink-0" />
            {isExpanded && <span>Tasks</span>}
          </div>
          {Boolean(tasksBadgeCount) && tasksBadgeCount > 0 && (
            isExpanded ? (
              <span className="bg-red-600 text-white rounded-full px-1.5 py-0.5 text-[9px] font-extrabold shadow-sm">
                {tasksBadgeCount}
              </span>
            ) : (
              <span className="absolute top-1.5 right-1.5 h-2 w-2 bg-red-600 rounded-full shadow-sm" />
            )
          )}
        </button>
        <button
          type="button"
          data-debug-id="nav-memory"
          onClick={onOpenMemory}
          className={`${activeView === 'memory' ? 'framer-pill bg-white text-black' : 'framer-pill-secondary'} w-full flex items-center ${isExpanded ? 'justify-between px-4 py-2.5' : 'justify-center p-2.5'} text-xs text-left`}
        >
          <div className="flex items-center gap-3">
            <Brain className="h-4 w-4 shrink-0" />
            {isExpanded && <span>Memory</span>}
          </div>
        </button>
        <button
          type="button"
          data-debug-id="nav-memory-audit"
          onClick={onOpenMemoryAudit}
          className={`${activeView === 'memoryAudit' ? 'framer-pill bg-white text-black' : 'framer-pill-secondary'} w-full flex items-center ${isExpanded ? 'justify-between px-4 py-2.5' : 'justify-center p-2.5'} text-xs text-left`}
        >
          <div className="flex items-center gap-3">
            <History className="h-4 w-4 shrink-0" />
            {isExpanded && <span>Memory Audit</span>}
          </div>
        </button>
        <button
          type="button"
          data-debug-id="nav-projects"
          onClick={onOpenProjects}
          className={`${activeView === 'projects' ? 'framer-pill bg-white text-black' : 'framer-pill-secondary'} w-full flex items-center ${isExpanded ? 'justify-between px-4 py-2.5' : 'justify-center p-2.5'} text-xs text-left`}
        >
          <div className="flex items-center gap-3">
            <Folder className="h-4 w-4 shrink-0" />
            {isExpanded && <span>Projects</span>}
          </div>
        </button>
        <button
          type="button"
          data-debug-id="nav-agents"
          onClick={onOpenAgents}
          className={`${activeView === 'agents' ? 'framer-pill bg-white text-black' : 'framer-pill-secondary'} w-full flex items-center ${isExpanded ? 'justify-between px-4 py-2.5' : 'justify-center p-2.5'} text-xs text-left`}
        >
          <div className="flex items-center gap-3">
            <Bot className="h-4 w-4 shrink-0" />
            {isExpanded && <span>Agents</span>}
          </div>
        </button>
        <button
          type="button"
          data-debug-id="nav-settings"
          onClick={onOpenSettings}
          className={`${activeView === 'settings' ? 'framer-pill bg-white text-black' : 'framer-pill-secondary'} w-full flex items-center ${isExpanded ? 'justify-between px-4 py-2.5' : 'justify-center p-2.5'} text-xs text-left`}
        >
          <div className="flex items-center gap-3">
            <Settings className="h-4 w-4 shrink-0" />
            {isExpanded && <span>Settings</span>}
          </div>
        </button>
        <button
          type="button"
          data-debug-id="nav-audit"
          onClick={onToggleAudit}
          className={`framer-pill-secondary w-full flex items-center ${isExpanded ? 'justify-between px-4 py-2.5' : 'justify-center p-2.5 relative'} text-xs text-left mt-1`}
        >
          <div className="flex items-center gap-3">
            <Activity className="h-4 w-4 shrink-0" />
            {isExpanded && <span>Task Chain Audit</span>}
          </div>
          {auditBadgeCount > 0 && (
            isExpanded ? (
              <span className="bg-red-500 text-white text-[9px] font-extrabold px-1.5 py-0.5 rounded-full animate-pulse shadow-sm">
                {auditBadgeCount}
              </span>
            ) : (
              <span className="absolute top-1.5 right-1.5 h-2 w-2 bg-red-500 rounded-full animate-pulse shadow-sm" />
            )
          )}
        </button>
      </nav>

      {isExpanded ? (
        <>
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
                  <section key={projectId} className="space-y-1.5">
                    <button
                      type="button"
                      data-debug-id={`project-group-toggle-${projectId}`}
                      draggable={projectId !== 'unassigned'}
                      onDragStart={(e) => handleDragStart(e, projectId)}
                      onDragOver={(e) => handleDragOverProject(e, projectId)}
                      onDragLeave={handleDragLeaveProject}
                      onDrop={(e) => handleDrop(e, projectId)}
                      onClick={() => toggleProjectGroup(projectId)}
                      className={`flex w-full items-center justify-between rounded-[var(--fd-radius-lg)] border px-3 py-1.5 text-left transition hover:border-[var(--fd-accent-blue)]/50 ${
                        dragOverProjectId === projectId
                          ? 'border-[var(--fd-accent-blue)] bg-[var(--fd-surface-3)]'
                          : 'border-[var(--fd-hairline)] bg-[var(--fd-surface-2)]'
                      } ${
                        projectId !== 'unassigned' ? 'cursor-grab active:cursor-grabbing' : ''
                      }`}
                    >
                      <div className="min-w-0 flex-1 flex items-center gap-2">
                        <span className="truncate text-[10px] font-semibold uppercase tracking-[0.15em] text-[#bbb]">{projectGroupLabel(projectId, projectsById, groupAgents)}</span>
                        <span className="text-[9px] font-medium text-[#777] shrink-0">({groupAgents.length}/{connectedCount})</span>
                      </div>
                      <span className="text-xs text-[#777] ml-2 shrink-0">{collapsed ? '▸' : '▾'}</span>
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
        </>
      ) : (
        <div className="mt-6 flex flex-1 flex-col items-center gap-4 overflow-y-auto">
          {agents
            .filter((agent) => agent.unreadCount > 0)
            .map((agent) => {
              const firstLetter = (agent.label || agent.id || 'A')[0].toUpperCase();
              const isSelected = agent.id === selectedAgentId;
              const statusColor = agentStatusColors[agent.status] || 'bg-gray-600';
              return (
                <button
                  key={agent.id}
                  type="button"
                  data-debug-id={`collapsed-agent-btn-${agent.id}`}
                  onClick={() => onSelectAgent(agent.id)}
                  className={`relative flex h-12 w-12 items-center justify-center rounded-full transition-all border shrink-0 ${
                    isSelected
                      ? 'border-[var(--fd-accent-blue)] bg-[var(--fd-accent-blue)]/10'
                      : 'border-[var(--fd-hairline)] bg-[var(--fd-surface-2)] hover:border-white/20'
                  }`}
                  title={`${agent.label || agent.id} (${agent.unreadCount} unread)`}
                >
                  <div className="flex h-9 w-9 items-center justify-center rounded-full bg-[var(--fd-accent-blue)]/20 text-xs font-bold text-[var(--fd-accent-blue)]">
                    {firstLetter}
                  </div>
                  <span className={`absolute bottom-0.5 right-0.5 h-3 w-3 rounded-full border-2 border-[var(--fd-surface-1)] ${statusColor}`} />
                  {agent.unreadCount > 0 && (
                    <span className="absolute -top-1 -right-1 flex h-5 min-w-[20px] items-center justify-center rounded-full bg-[var(--fd-accent-blue)] px-1.5 text-[9px] font-bold text-black shadow-sm">
                      {agent.unreadCount}
                    </span>
                  )}
                </button>
              );
            })}
        </div>
      )}
      <div className={`mt-auto pt-3 border-t border-[var(--fd-hairline)] flex items-center ${isExpanded ? 'justify-start' : 'justify-center'}`}>
        <button
          type="button"
          data-debug-id="toggle-pin-btn"
          onClick={togglePin}
          className={`flex items-center text-[#666] hover:text-white transition-colors ${isExpanded ? 'gap-2 text-xs' : ''}`}
          title={isPinned ? 'Unpin sidebar' : 'Pin sidebar'}
        >
          {isPinned ? <PinOff className="h-3.5 w-3.5" /> : <Pin className="h-3.5 w-3.5" />}
          {isExpanded && <span>{isPinned ? 'Collapse Sidebar' : 'Pin Sidebar'}</span>}
        </button>
      </div>
    </aside>
  );
});
export default AgentSidebar;
