import { useCallback, useEffect, useRef, useState } from 'react';
import { useDispatch, useSelector } from 'react-redux';
import AgentSidebar from './AgentSidebar';
import ChatPane from './ChatPane';
import SettingsPage from './SettingsPage';
import TaskBoard from './TaskBoard';
import MemoryBoard from './MemoryBoard';
import MemoryAuditBoard from './MemoryAuditBoard';
import StartAgentPage from './StartAgentPage';
import ProjectsPage from './ProjectsPage';
import AgentsPage from './AgentsPage';
import {
  chatEventReceived,
  fetchSelectedChat,
  refreshAgents,
  registerSession,
  selectAgent,
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
} from '../store/chatSlice';
import { refreshTaskBoard, taskEventReceived, updateTaskStateDirectly, fetchUnreviewedChains } from '../store/taskSlice';
import { memoryEventReceived, refreshMemory, auditStartedReceived, auditEndedReceived } from '../store/memorySlice';
import { refreshProjects } from '../store/projectSlice';
import * as daemonApi from '../api/daemonApi';
import AuditSidebar from './AuditSidebar';

const EMPTY_ARRAY: any[] = [];

export default function App() {
  const renderStart = performance.now();
  useEffect(() => {
    const duration = performance.now() - renderStart;
    console.log(`[Render Timer] App took ${duration.toFixed(2)}ms`);
  });
  const dispatch = useDispatch<any>();
  const { agents, selectedAgentId, session } = useSelector((state: any) => state.chat);
  const { projectsById } = useSelector((state: any) => state.projects);
  const unreviewedChains = useSelector((state: any) => state.tasks.unreviewedChains || EMPTY_ARRAY);
  const selectedAgent = agents.find((agent) => agent.id === selectedAgentId) ?? null;
  const [view, setView] = useState<'chat' | 'settings' | 'tasks' | 'memory' | 'memoryAudit' | 'projects' | 'agents' | 'startAgent'>('chat');
  const [isAuditOpen, setIsAuditOpen] = useState(false);
  const selectedAgentRef = useRef(selectedAgentId);
  const sessionRef = useRef(session);

  useEffect(() => {
    sessionRef.current = session;
  }, [session]);

  useEffect(() => {
    selectedAgentRef.current = selectedAgentId;
  }, [selectedAgentId]);

  const connectSession = () => {
    dispatch(registerSession())
      .unwrap()
      .then(() => {
        dispatch(refreshAgents());
        dispatch(refreshTaskBoard());
        dispatch(refreshProjects());
      })
      .catch(() => undefined);
  };

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
          return;
        }
        if (payload?.type === 'task_event') {
          dispatch(taskEventReceived(payload));
          if (payload.task) {
            dispatch(updateTaskStateDirectly(payload.task));
          } else {
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
    window.addEventListener('focus', refreshSnapshot);
    document.addEventListener('visibilitychange', onVisibility);
    const interval = window.setInterval(refreshSnapshot, 45000);
    return () => {
      window.removeEventListener('focus', refreshSnapshot);
      document.removeEventListener('visibilitychange', onVisibility);
      window.clearInterval(interval);
    };
  }, [dispatch, session.connected]);

  const handleRefreshAgents = useCallback(() => {
    dispatch(refreshAgents());
  }, [dispatch]);

  const handleSelectAgent = useCallback((agentId: string) => {
    dispatch(selectAgent(agentId));
    setView('chat');
  }, [dispatch]);

  const handleStartAgent = useCallback((agent: any) => {
    dispatch(startAgentInstance(agent));
  }, [dispatch]);

  const handleStopAgent = useCallback((agentId: string) => {
    dispatch(stopAgentInstance(agentId));
  }, [dispatch]);

  const handleOpenChat = useCallback(() => {
    setView('chat');
  }, []);

  const handleOpenTasks = useCallback(() => {
    setView('tasks');
    dispatch(refreshTaskBoard());
  }, [dispatch]);

  const handleOpenMemory = useCallback(() => {
    setView('memory');
    dispatch(refreshMemory());
  }, [dispatch]);

  const handleOpenMemoryAudit = useCallback(() => {
    setView('memoryAudit');
    dispatch(refreshMemory());
  }, [dispatch]);

  const handleOpenProjects = useCallback(() => {
    setView('projects');
    dispatch(refreshProjects());
  }, [dispatch]);

  const handleOpenAgents = useCallback(() => {
    setView('agents');
  }, []);

  const handleOpenStartAgent = useCallback(() => {
    setView('startAgent');
  }, []);

  const handleOpenSettings = useCallback(() => {
    setView('settings');
  }, []);

  const handleToggleAudit = useCallback(() => {
    setIsAuditOpen((prev) => !prev);
  }, []);

  return (
    <div className="h-screen overflow-hidden bg-[var(--fd-canvas)] text-white">
      <div className="flex h-full">
        <AgentSidebar
          agents={agents}
          projectsById={projectsById}
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
          onToggleAudit={handleToggleAudit}
        />
        {view === 'chat' ? (
          <ChatPane agent={selectedAgent} session={session} />
        ) : view === 'tasks' ? (
          <TaskBoard session={session} />
        ) : view === 'memory' ? (
          <MemoryBoard session={session} agents={agents} />
        ) : view === 'memoryAudit' ? (
          <MemoryAuditBoard session={session} agents={agents} />
        ) : view === 'projects' ? (
          <ProjectsPage session={session} />
        ) : view === 'agents' ? (
          <AgentsPage session={session} onOpenStartAgent={handleOpenStartAgent} />
        ) : view === 'startAgent' ? (
          <StartAgentPage
            session={session}
            onBack={handleOpenChat}
            onStarted={() => {
              dispatch(refreshAgents());
              setView('chat');
            }}
          />
        ) : (
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
        <AuditSidebar open={isAuditOpen} onClose={() => setIsAuditOpen(false)} />
      </div>
    </div>
  );
}
