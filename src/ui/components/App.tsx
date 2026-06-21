import { useEffect, useRef, useState } from 'react';
import { useDispatch, useSelector } from 'react-redux';
import AgentSidebar from './AgentSidebar';
import ChatPane from './ChatPane';
import SettingsPage from './SettingsPage';
import TaskBoard from './TaskBoard';
import MemoryBoard from './MemoryBoard';
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
  testStartReceived,
  testDoneReceived,
  setTestRuns,
} from '../store/chatSlice';
import { refreshTaskBoard, taskEventReceived } from '../store/taskSlice';
import { memoryEventReceived, refreshMemory } from '../store/memorySlice';
import { refreshProjects } from '../store/projectSlice';
import * as daemonApi from '../api/daemonApi';

export default function App() {
  const dispatch = useDispatch<any>();
  const { agents, selectedAgentId, chats, session, sending } = useSelector((state: any) => state.chat);
  const { projectsById } = useSelector((state: any) => state.projects);
  const selectedAgent = agents.find((agent) => agent.id === selectedAgentId) ?? null;
  const messages = selectedAgent ? chats[selectedAgent.id] ?? [] : [];
  const [view, setView] = useState<'chat' | 'settings' | 'tasks' | 'memory' | 'projects' | 'agents' | 'startAgent'>('chat');
  const selectedAgentRef = useRef(selectedAgentId);
  const cachedChatsRef = useRef(chats);
  const sessionRef = useRef(session);

  useEffect(() => {
    sessionRef.current = session;
  }, [session]);

  useEffect(() => {
    selectedAgentRef.current = selectedAgentId;
    cachedChatsRef.current = chats;
  }, [selectedAgentId, chats]);

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
          dispatch(refreshTaskBoard());
          return;
        }
        if (payload?.type === 'memory_event') {
          dispatch(memoryEventReceived(payload));
          dispatch(refreshMemory());
          return;
        }
        if (payload?.type === 'agent_lifecycle_changed') {
          dispatch(agentLifecycleEventReceived(payload));
          return;
        }
        if (payload?.type === 'test_start') {
          dispatch(testStartReceived(payload));
          return;
        }
        if (payload?.type === 'test_done') {
          dispatch(testDoneReceived(payload));
          // Belt-and-suspenders: refetch canonical history in case test_start
          // was missed (e.g. WS just reconnected) or the reducer needs a
          // field we didn't include in the event payload.
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
        const isSelected = agentId === selectedAgentRef.current;
        const isCached = Boolean(cachedChatsRef.current?.[agentId]);
        if (agentId && (isSelected || isCached)) {
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

  return (
    <div className="h-screen overflow-hidden bg-[var(--fd-canvas)] text-white">
      <div className="flex h-full">
        <AgentSidebar
          agents={agents}
          projectsById={projectsById}
          selectedAgentId={selectedAgentId}
          session={session}
          activeView={view}
          onRefreshAgents={() => dispatch(refreshAgents())}
          onSelectAgent={(agentId) => {
            dispatch(selectAgent(agentId));
            setView('chat');
          }}
          onOpenChat={() => setView('chat')}
          onOpenTasks={() => {
            setView('tasks');
            dispatch(refreshTaskBoard());
          }}
          onOpenMemory={() => {
            setView('memory');
            dispatch(refreshMemory());
          }}
          onOpenProjects={() => {
            setView('projects');
            dispatch(refreshProjects());
          }}
          onOpenAgents={() => setView('agents')}
          onOpenStartAgent={() => setView('startAgent')}
          onOpenSettings={() => setView('settings')}
        />
        {view === 'chat' ? (
          <ChatPane agent={selectedAgent} messages={messages} session={session} sending={sending} />
        ) : view === 'tasks' ? (
          <TaskBoard session={session} />
        ) : view === 'memory' ? (
          <MemoryBoard session={session} agents={agents} />
        ) : view === 'projects' ? (
          <ProjectsPage session={session} />
        ) : view === 'agents' ? (
          <AgentsPage session={session} onOpenStartAgent={() => setView('startAgent')} />
        ) : view === 'startAgent' ? (
          <StartAgentPage
            session={session}
            onBack={() => setView('chat')}
            onStarted={() => {
              dispatch(refreshAgents());
              setView('chat');
            }}
          />
        ) : (
          <SettingsPage
            session={session}
            onBack={() => setView('chat')}
            onReconnect={(config) => {
              dispatch(updateSessionConfig(config));
              setView('chat');
              window.setTimeout(connectSession, 0);
            }}
          />
        )}
      </div>
    </div>
  );
}
