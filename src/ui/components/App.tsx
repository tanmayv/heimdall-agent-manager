import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { useDispatch, useSelector } from 'react-redux';
import { useUrlParams } from './useUrlParams';
import AgentSidebar from './AgentSidebar';
import ChatPane from './ChatPane';
import SettingsPage from './SettingsPage';
import TaskBoard from './TaskBoard';
import MemoryBoard from './MemoryBoard';
import MemoryAuditBoard from './MemoryAuditBoard';
import StartAgentPage from './StartAgentPage';
import ProjectsPage from './ProjectsPage';
import AgentsPage from './AgentsPage';
import OnboardingWizard from './OnboardingWizard';
import {
  chatEventReceived,
  fetchSelectedChat,
  refreshAgents,
  reorderAgentsFromUi,
  registerSession,
  fetchPreferences,
  selectAgent,
  setView as setChatView,
  updateSessionConfig,
  userWsConnected,
  userWsConnecting,
  userWsDisconnected,
  userWsError,
  agentLifecycleEventReceived,
  agentRuntimeEventReceived,
  testStartReceived,
  testDoneReceived,
  setTestRuns,
  appendMessage,
  startAgentInstance,
  stopAgentInstance,
  addDaemonProfile,
} from '../store/chatSlice';
import { refreshTaskBoard, taskEventReceived, updateTaskStateDirectly, updateChainStateDirectly, fetchUnreviewedChains } from '../store/taskSlice';
import { memoryEventReceived, refreshMemory, auditStartedReceived, auditEndedReceived } from '../store/memorySlice';
import { refreshProjects, reorderProjectsFromUi } from '../store/projectSlice';
import * as daemonApi from '../api/daemonApi';
import AuditSidebar from './AuditSidebar';

const EMPTY_ARRAY: any[] = [];

const STATUS_DOT: Record<string, string> = {
  connected: 'bg-emerald-400 shadow-emerald-400/40',
  starting: 'bg-sky-400 shadow-sky-400/40',
  startup_blocked: 'bg-amber-400 shadow-amber-400/40',
  startup_failed: 'bg-red-400 shadow-red-400/40',
  stopping: 'bg-amber-400 shadow-amber-400/40 animate-soft-pulse',
  offline: 'bg-[#555]/70',
};

const STATUS_LABEL: Record<string, string> = {
  connected: 'Live',
  starting: 'Starting',
  startup_blocked: 'Blocked',
  startup_failed: 'Failed',
  stopping: 'Stopping',
  offline: 'Known',
};

export default function App() {
  const renderStart = performance.now();
  useEffect(() => {
    const duration = performance.now() - renderStart;
    console.log(`[Render Timer] App took ${duration.toFixed(2)}ms`);
  });
  const dispatch = useDispatch<any>();
  const [urlParams, setUrlParams] = useUrlParams();
  const view = urlParams.view;
  const selectedAgentId = urlParams.agentId;
  const setView = useCallback((val: any) => setUrlParams({ view: val }), [setUrlParams]);

  const { agents, session, userPreferences, daemonProfiles } = useSelector((state: any) => state.chat);
  const { projectsById, projectIds } = useSelector((state: any) => state.projects);
  const unreviewedChains = useSelector((state: any) => state.tasks.unreviewedChains || EMPTY_ARRAY);
  const tasksById = useSelector((state: any) => state.tasks.tasksById);
  const tasksBadgeCount = useMemo(() => {
    const userId = session.userId || 'operator@local';
    return Object.values(tasksById).filter((task: any) => {
      if (task.status !== 'review_ready') return false;
      const isPart = (task.participants ?? []).some((p: any) => p.agentInstanceId === userId && (p.role === 'lgtm_required' || p.role === 'lgtm_optional'));
      if (!isPart) return false;
      const hasVoted = (task.votes ?? []).some((v: any) => v.reviewerAgentInstanceId === userId);
      return !hasVoted;
    }).length;
  }, [tasksById, session.userId]);
  const selectedAgent = agents.find((agent) => agent.id === selectedAgentId) ?? null;
  const [newDaemonUrl, setNewDaemonUrl] = useState('');
  const [newDaemonLabel, setNewDaemonLabel] = useState('');
  const [showDaemonAdd, setShowDaemonAdd] = useState(false);
  
  const [showOnboarding, setShowOnboarding] = useState<boolean>(false);

  useEffect(() => {
    if (session.connected) {
      const completed = userPreferences['setup_completed'] === 'true';
      setShowOnboarding(!completed);
    } else {
      const hasToken = Boolean(window.localStorage.getItem('odin.clientToken'));
      if (!hasToken) {
        setShowOnboarding(true);
      }
    }
  }, [session.connected, userPreferences]);

  // Sync urlParams.agentId changes to Redux selectAgent state for backend thunk integrations
  useEffect(() => {
    dispatch(selectAgent(selectedAgentId));
  }, [dispatch, selectedAgentId]);
  const [isAuditOpen, setIsAuditOpen] = useState(false);
  const [isAgentSwitcherOpen, setIsAgentSwitcherOpen] = useState(false);
  const [agentSearchQuery, setAgentSearchQuery] = useState('');
  const [switcherSelectedIndex, setSwitcherSelectedIndex] = useState(0);
  const selectedAgentRef = useRef(selectedAgentId);
  const sessionRef = useRef(session);

  useEffect(() => {
    sessionRef.current = session;
  }, [session]);

  useEffect(() => {
    selectedAgentRef.current = selectedAgentId;
  }, [selectedAgentId]);

  // --- Agent Switcher (Ctrl+K) Logic ---
  const filteredSwitcherAgents = useMemo(() => {
    return (agents ?? []).filter((agent: any) =>
      (agent.label || '').toLowerCase().includes(agentSearchQuery.toLowerCase())
    );
  }, [agents, agentSearchQuery]);

  const handleSelectAgentFromSwitcher = useCallback((agent: any) => {
    setIsAgentSwitcherOpen(false);
    setUrlParams({ agentId: agent.id, view: 'chat' });
  }, [setUrlParams]);

  // Global Ctrl+K hotkey listener
  useEffect(() => {
    const handleGlobalKeyDown = (e: KeyboardEvent) => {
      if (e.key === 'k' && (e.ctrlKey || e.metaKey)) {
        e.preventDefault();
        setIsAgentSwitcherOpen((prev) => !prev);
        setAgentSearchQuery('');
        setSwitcherSelectedIndex(0);
      }
    };
    window.addEventListener('keydown', handleGlobalKeyDown);
    return () => window.removeEventListener('keydown', handleGlobalKeyDown);
  }, []);

  // Keyboard navigation when switcher is open
  useEffect(() => {
    if (!isAgentSwitcherOpen) return undefined;
    const handleSwitcherKeyDown = (e: KeyboardEvent) => {
      if (e.key === 'Escape') {
        e.preventDefault();
        setIsAgentSwitcherOpen(false);
      } else if (e.key === 'ArrowDown') {
        e.preventDefault();
        setSwitcherSelectedIndex((prev) => (filteredSwitcherAgents.length ? (prev + 1) % filteredSwitcherAgents.length : 0));
      } else if (e.key === 'ArrowUp') {
        e.preventDefault();
        setSwitcherSelectedIndex((prev) => (filteredSwitcherAgents.length ? (prev - 1 + filteredSwitcherAgents.length) % filteredSwitcherAgents.length : 0));
      } else if (e.key === 'Enter') {
        e.preventDefault();
        const selected = filteredSwitcherAgents[switcherSelectedIndex];
        if (selected) {
          handleSelectAgentFromSwitcher(selected);
        }
      }
    };
    window.addEventListener('keydown', handleSwitcherKeyDown);
    return () => window.removeEventListener('keydown', handleSwitcherKeyDown);
  }, [isAgentSwitcherOpen, filteredSwitcherAgents, switcherSelectedIndex, handleSelectAgentFromSwitcher]);

  const connectSession = () => {
    dispatch(registerSession())
      .unwrap()
      .then(() => {
        dispatch(fetchPreferences()); // Fetch preferences immediately on startup!
        dispatch(refreshAgents());
        dispatch(refreshTaskBoard());
        dispatch(refreshProjects());
      })
      .catch(() => undefined);
  };

  const switchDaemon = useCallback((daemonUrl: string) => {
    if (!daemonUrl || daemonUrl === session.daemonUrl) return;
    setUrlParams({ agentId: '', taskId: '', chainId: '' });
    dispatch(updateSessionConfig({ daemonUrl, userId: session.userId }));
    window.setTimeout(connectSession, 0);
  }, [dispatch, session.daemonUrl, session.userId, setUrlParams]);

  const addDaemon = useCallback(() => {
    const daemonUrl = newDaemonUrl.trim();
    if (!daemonUrl) return;
    dispatch(addDaemonProfile({ daemonUrl, label: newDaemonLabel.trim() }));
    setShowDaemonAdd(false);
    setNewDaemonUrl('');
    setNewDaemonLabel('');
    switchDaemon(daemonUrl.replace(/\/$/, ''));
  }, [dispatch, newDaemonLabel, newDaemonUrl, switchDaemon]);

  useEffect(() => {
    connectSession();
  }, [dispatch]);

  useEffect(() => {
    if (selectedAgentId && session.clientToken) {
      dispatch(fetchSelectedChat(selectedAgentId));
    }
  }, [dispatch, selectedAgentId, session.clientToken]);

  useEffect(() => {
    if (!session.connected || !session.clientToken || !session.clientInstanceId) return undefined;

    let socket: WebSocket | null = null;
    let reconnectTimer: number | undefined;
    let stopped = false;

    const connect = () => {
      if (stopped) return;

      const current = sessionRef.current;
      if (!current.clientToken || !current.clientInstanceId) {
        dispatch(registerSession())
          .unwrap()
          .then(() => {
            if (!stopped) {
              reconnectTimer = window.setTimeout(connect, 0);
            }
          })
          .catch(() => {
            dispatch(userWsError('Failed to re-register user client'));
            if (!stopped) {
              reconnectTimer = window.setTimeout(connect, 1500);
            }
          });
        return;
      }

      dispatch(userWsConnecting());
      const wsBaseUrl = current.daemonUrl.replace(/^http/i, 'ws').replace(/\/$/, '');
      const wsUrl = `${wsBaseUrl}/user-ws/${encodeURIComponent(current.clientInstanceId)}?client_token=${encodeURIComponent(current.clientToken)}`;
      socket = new WebSocket(wsUrl);

      socket.onopen = () => {
        dispatch(userWsConnected());
        dispatch(refreshAgents());
      };

      socket.onmessage = (event) => {
        let payload: any = null;
        try {
          payload = JSON.parse(event.data);
        } catch {
          console.warn("[WS USER CLIENT] failed to parse WS text message:", event.data);
          return;
        }
        console.log("[WS USER CLIENT] message received:", payload);
        if (payload?.type === 'task_event') {
          dispatch(taskEventReceived(payload));
          if (payload.task) {
            dispatch(updateTaskStateDirectly(payload.task));
          }
          if (payload.chain) {
            dispatch(updateChainStateDirectly(payload.chain));
          }
          if (!payload.task && !payload.chain) {
            dispatch(refreshTaskBoard());
          }
          return;
        }
        if (payload?.type === 'memory_event') {
          dispatch(memoryEventReceived(payload));
          dispatch(refreshMemory());
          return;
        }
        if (payload?.type === 'audit_start') {
          dispatch(auditStartedReceived(payload));
          return;
        }
        if (payload?.type === 'audit_end') {
          dispatch(auditEndedReceived(payload));
          dispatch(refreshMemory());
          return;
        }
        if (payload?.type === 'agent_lifecycle_changed') {
          dispatch(agentLifecycleEventReceived(payload));
          return;
        }
        if (payload?.type === 'agent_runtime_changed') {
          dispatch(agentRuntimeEventReceived(payload));
          return;
        }
        if (payload?.type === 'test_start') {
          dispatch(testStartReceived(payload));
          return;
        }
        if (payload?.type === 'test_done') {
          dispatch(testDoneReceived(payload));
          const url = sessionRef.current?.daemonUrl;
          if (url) {
            daemonApi.getTestHistory({ daemonUrl: url })
              .then((data: any) => dispatch(setTestRuns(data?.runs ?? [])))
              .catch(() => {});
          }
          return;
        }
        if (payload?.type !== 'chat_event') return;
        dispatch(chatEventReceived(payload));
        const agentId = payload.agent_instance_id;
        if (agentId && payload.message) {
          dispatch(appendMessage({ agentId, message: payload.message }));
        } else if (agentId) {
          dispatch(fetchSelectedChat(agentId));
        }
      };

      socket.onerror = () => {
        dispatch(userWsError('User WebSocket connection error'));
      };

      socket.onclose = () => {
        if (stopped) return;
        dispatch(userWsDisconnected());
        dispatch(registerSession())
          .unwrap()
          .catch(() => dispatch(userWsError('Failed to re-register user client')))
          .finally(() => {
            if (!stopped) {
              reconnectTimer = window.setTimeout(connect, 1500);
            }
          });
      };
    };

    connect();

    return () => {
      stopped = true;
      if (reconnectTimer) window.clearTimeout(reconnectTimer);
      socket?.close();
    };
  }, [dispatch, session.connected, session.daemonUrl]);

  useEffect(() => {
    if (!session.connected) return undefined;
    dispatch(fetchUnreviewedChains());
    const refreshSnapshot = () => dispatch(refreshAgents());
    const onVisibility = () => {
      if (document.visibilityState === 'visible') refreshSnapshot();
    };
    document.addEventListener('visibilitychange', onVisibility);
    const interval = window.setInterval(refreshSnapshot, 45000);
    return () => {
      document.removeEventListener('visibilitychange', onVisibility);
      window.clearInterval(interval);
    };
  }, [dispatch, session.connected]);

  const handleRefreshAgents = useCallback(() => {
    dispatch(refreshAgents());
  }, [dispatch]);

  const handleSelectAgent = useCallback((agentId: string) => {
    setUrlParams({ agentId, view: 'chat' });
  }, [setUrlParams]);

  const handleStartAgent = useCallback((agent: any) => {
    dispatch(startAgentInstance(agent));
  }, [dispatch]);

  const handleStopAgent = useCallback((agentId: string) => {
    dispatch(stopAgentInstance(agentId));
  }, [dispatch]);

  const handleOpenChat = useCallback(() => {
    setUrlParams({ view: 'chat' });
  }, [setUrlParams]);

  const handleOpenTasks = useCallback(() => {
    setUrlParams({ view: 'tasks', taskId: '', chainId: '' });
    dispatch(refreshTaskBoard());
  }, [setUrlParams, dispatch]);

  const handleOpenMemory = useCallback(() => {
    setUrlParams({ view: 'memory', memoryId: '' });
    dispatch(refreshMemory());
  }, [setUrlParams, dispatch]);

  const handleOpenMemoryAudit = useCallback(() => {
    setUrlParams({ view: 'memoryAudit' });
    dispatch(refreshMemory());
  }, [setUrlParams, dispatch]);

  const handleOpenProjects = useCallback(() => {
    setUrlParams({ view: 'projects' });
    dispatch(refreshProjects());
  }, [setUrlParams, dispatch]);

  const handleReorderProjects = useCallback((newProjectIds: string[]) => {
    dispatch(reorderProjectsFromUi(newProjectIds));
  }, [dispatch]);

  const handleReorderAgents = useCallback((agentIds: string[]) => {
    dispatch(reorderAgentsFromUi(agentIds));
  }, [dispatch]);

  const handleOpenAgents = useCallback(() => {
    setUrlParams({ view: 'agents' });
  }, [setUrlParams]);

  const handleOpenStartAgent = useCallback(() => {
    setUrlParams({ view: 'startAgent' });
  }, [setUrlParams]);

  const handleOpenSettings = useCallback(() => {
    setUrlParams({ view: 'settings' });
  }, [setUrlParams]);

  const handleToggleAudit = useCallback(() => {
    setIsAuditOpen((prev) => !prev);
  }, []);

  if (showOnboarding) {
    return <OnboardingWizard onComplete={() => setShowOnboarding(false)} />;
  }

  return (
    <div className="h-screen overflow-hidden bg-[var(--fd-canvas)] text-white">
      <div className="fixed right-4 top-3 z-50 flex max-w-[min(720px,calc(100vw-2rem))] flex-wrap items-center justify-end gap-2 rounded-full border border-[var(--fd-hairline)] bg-[var(--fd-surface-2)]/95 px-3 py-2 shadow-lg backdrop-blur">
        <span className="framer-topline text-[10px]">Daemon</span>
        <select
          data-debug-id="daemon-profile-select"
          value={session.daemonUrl}
          onChange={(event) => switchDaemon(event.target.value)}
          className="framer-input max-w-[260px] px-2 py-1 text-xs"
          title={session.daemonUrl}
        >
          {(daemonProfiles || []).map((profile: any) => (
            <option key={profile.url} value={profile.url}>{profile.label || profile.url}</option>
          ))}
        </select>
        <span className={`h-2 w-2 rounded-full ${session.connected ? 'bg-emerald-400' : session.status === 'error' || session.wsStatus === 'error' ? 'bg-red-400' : 'bg-amber-400'}`} title={session.error || session.status} />
        <button type="button" data-debug-id="daemon-profile-add-toggle" onClick={() => setShowDaemonAdd((prev) => !prev)} className="framer-pill-secondary px-2 py-1 text-xs">+ Daemon</button>
        {showDaemonAdd && (
          <div className="flex flex-wrap items-center gap-2">
            <input value={newDaemonLabel} onChange={(event) => setNewDaemonLabel(event.target.value)} placeholder="Label" className="framer-input w-24 px-2 py-1 text-xs" />
            <input value={newDaemonUrl} onChange={(event) => setNewDaemonUrl(event.target.value)} placeholder="http://127.0.0.1:49322" className="framer-input w-52 px-2 py-1 text-xs" />
            <button type="button" data-debug-id="daemon-profile-add-btn" onClick={addDaemon} className="framer-pill bg-white px-2 py-1 text-xs">Add</button>
          </div>
        )}
      </div>
      <div className="flex h-full">
        <AgentSidebar
          agents={agents}
          projectsById={projectsById}
          projectIds={projectIds}
          onReorderProjects={handleReorderProjects}
          onReorderAgents={handleReorderAgents}
          selectedAgentId={selectedAgentId}
          session={session}
          activeView={view}
          onRefreshAgents={handleRefreshAgents}
          onSelectAgent={handleSelectAgent}
          onStartAgent={handleStartAgent}
          onStopAgent={handleStopAgent}
          onOpenChat={handleOpenChat}
          onOpenTasks={handleOpenTasks}
          onOpenMemory={handleOpenMemory}
          onOpenMemoryAudit={handleOpenMemoryAudit}
          onOpenProjects={handleOpenProjects}
          onOpenAgents={handleOpenAgents}
          onOpenStartAgent={handleOpenStartAgent}
          onOpenSettings={handleOpenSettings}
          auditBadgeCount={unreviewedChains.length}
          tasksBadgeCount={tasksBadgeCount}
          onToggleAudit={handleToggleAudit}
        />
        {/* Persistent Dashboard Pages (Preserves DOM, State, and Scroll positions) */}
        <div className={`flex-1 min-w-0 min-h-0 h-full ${view === 'chat' ? 'flex flex-col' : 'hidden'}`}>
          <ChatPane agent={selectedAgent} session={session} />
        </div>
        <div className={`flex-1 min-w-0 min-h-0 h-full ${view === 'tasks' ? 'flex flex-col' : 'hidden'}`}>
          <TaskBoard session={session} />
        </div>
        <div className={`flex-1 min-w-0 min-h-0 h-full ${view === 'memory' ? 'flex flex-col' : 'hidden'}`}>
          <MemoryBoard session={session} agents={agents} />
        </div>
        <div className={`flex-1 min-w-0 min-h-0 h-full ${view === 'memoryAudit' ? 'flex flex-col' : 'hidden'}`}>
          <MemoryAuditBoard session={session} agents={agents} />
        </div>
        <div className={`flex-1 min-w-0 min-h-0 h-full ${view === 'projects' ? 'flex flex-col' : 'hidden'}`}>
          <ProjectsPage session={session} />
        </div>
        <div className={`flex-1 min-w-0 min-h-0 h-full ${view === 'agents' ? 'flex flex-col' : 'hidden'}`}>
          <AgentsPage session={session} onOpenStartAgent={handleOpenStartAgent} />
        </div>

        {/* Conditional Form Pages (Resets state on mount/unmount) */}
        <div className={`flex-1 min-w-0 min-h-0 h-full ${view === 'startAgent' ? 'flex flex-col' : 'hidden'}`}>
          {view === 'startAgent' && (
            <StartAgentPage
              session={session}
              onBack={handleOpenChat}
              onStarted={() => {
                dispatch(refreshAgents());
                setView('chat');
              }}
            />
          )}
        </div>
        <div className={`flex-1 min-w-0 min-h-0 h-full ${view === 'settings' ? 'flex flex-col' : 'hidden'}`}>
          {view === 'settings' && (
            <SettingsPage
              session={session}
              onBack={handleOpenChat}
              onReconnect={(config) => {
                dispatch(updateSessionConfig(config));
                setView('chat');
                window.setTimeout(connectSession, 0);
              }}
            />
          )}
        </div>
        <AuditSidebar open={isAuditOpen} onClose={() => setIsAuditOpen(false)} />

        {/* Agent Switcher (Ctrl+K) Modal */}
        {isAgentSwitcherOpen && (
          <div className="fixed inset-0 bg-black/60 backdrop-blur-sm z-[999] flex items-start justify-center pt-24" onClick={() => setIsAgentSwitcherOpen(false)}>
            <div 
              className="bg-[var(--fd-surface-1)] border border-[var(--fd-hairline)] rounded-2xl w-full max-w-lg shadow-2xl flex flex-col max-h-[400px] overflow-hidden"
              onClick={(e) => e.stopPropagation()}
            >
              {/* Search input */}
              <input
                autoFocus
                type="text"
                value={agentSearchQuery}
                onChange={(e) => {
                  setAgentSearchQuery(e.target.value);
                  setSwitcherSelectedIndex(0);
                }}
                placeholder="Search agent instance by name..."
                className="framer-input w-full border-0 border-b border-[var(--fd-hairline)] rounded-t-2xl px-4 py-3 bg-[#111] text-white text-sm placeholder-[#666] outline-none focus:ring-0"
              />
              
              {/* Agent list */}
              <div className="overflow-y-auto p-2 space-y-1 flex-1 min-h-0">
                {filteredSwitcherAgents.length === 0 ? (
                  <p className="text-center text-xs text-[#555] py-4">No matching agents found.</p>
                ) : (
                  filteredSwitcherAgents.map((agent: any, index: number) => {
                    const isSelected = index === switcherSelectedIndex;
                    const statusDotColor = STATUS_DOT[agent.status] ?? STATUS_DOT.offline;
                    return (
                      <button
                        key={agent.id}
                        type="button"
                        onClick={() => handleSelectAgentFromSwitcher(agent)}
                        className={`w-full flex items-center justify-between px-3 py-2.5 rounded-xl text-left text-sm transition-colors border ${
                          isSelected 
                            ? 'bg-[var(--fd-accent-blue)]/15 border-[var(--fd-accent-blue)]/30 text-white' 
                            : 'bg-transparent border-transparent text-[#aaa] hover:bg-[var(--fd-surface-2)] hover:text-white'
                        }`}
                      >
                        <div className="flex items-center gap-2 min-w-0">
                          <span className={`h-2 w-2 shrink-0 rounded-full ${statusDotColor} ${agent.status === 'connected' ? 'animate-soft-pulse' : ''}`} />
                          <span className="truncate font-medium">{agent.label}</span>
                          <span className="text-[10px] text-[#555] truncate">({agent.id})</span>
                        </div>
                        <span className="text-[10px] text-[#666] uppercase tracking-wider font-semibold">{STATUS_LABEL[agent.status] ?? 'Offline'}</span>
                      </button>
                    );
                  })
                )}
              </div>
              
              {/* Keyboard shortcuts footer */}
              <div className="bg-[#111]/60 px-4 py-2 border-t border-[var(--fd-hairline)] flex justify-between items-center text-[10px] text-[#555]">
                <span>Use ↑↓ arrows to navigate, Enter to select</span>
                <span>ESC to close</span>
              </div>
            </div>
          </div>
        )}
      </div>
    </div>
  );
}
