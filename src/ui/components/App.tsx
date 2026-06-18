import { useEffect, useRef, useState } from 'react';
import { useDispatch, useSelector } from 'react-redux';
import AgentSidebar from './AgentSidebar';
import ChatPane from './ChatPane';
import SettingsPage from './SettingsPage';
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
} from '../store/chatSlice';

export default function App() {
  const dispatch = useDispatch<any>();
  const { agents, selectedAgentId, chats, session, sending } = useSelector((state: any) => state.chat);
  const selectedAgent = agents.find((agent) => agent.id === selectedAgentId) ?? null;
  const messages = selectedAgent ? chats[selectedAgent.id] ?? [] : [];
  const [view, setView] = useState<'chat' | 'settings'>('chat');
  const selectedAgentRef = useRef(selectedAgentId);
  const cachedChatsRef = useRef(chats);

  useEffect(() => {
    selectedAgentRef.current = selectedAgentId;
    cachedChatsRef.current = chats;
  }, [selectedAgentId, chats]);

  const connectSession = () => {
    dispatch(registerSession())
      .unwrap()
      .then(() => dispatch(refreshAgents()))
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
      dispatch(userWsConnecting());
      const wsBaseUrl = session.daemonUrl.replace(/^http/i, 'ws').replace(/\/$/, '');
      const wsUrl = `${wsBaseUrl}/user-ws/${encodeURIComponent(session.clientInstanceId)}?client_token=${encodeURIComponent(session.clientToken)}`;
      socket = new WebSocket(wsUrl);

      socket.onopen = () => {
        dispatch(userWsConnected());
      };

      socket.onmessage = (event) => {
        let payload: any = null;
        try {
          payload = JSON.parse(event.data);
        } catch {
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
        reconnectTimer = window.setTimeout(connect, 1500);
      };
    };

    connect();

    return () => {
      stopped = true;
      if (reconnectTimer) window.clearTimeout(reconnectTimer);
      socket?.close();
    };
  }, [dispatch, session.connected, session.clientInstanceId, session.clientToken, session.daemonUrl]);

  return (
    <div className="h-screen overflow-hidden bg-slate-950 text-slate-100">
      <div className="flex h-full">
        <AgentSidebar
          agents={agents}
          selectedAgentId={selectedAgentId}
          session={session}
          onRefreshAgents={() => dispatch(refreshAgents())}
          onSelectAgent={(agentId) => dispatch(selectAgent(agentId))}
          onOpenSettings={() => setView('settings')}
        />
        {view === 'chat' ? (
          <ChatPane agent={selectedAgent} messages={messages} session={session} sending={sending} />
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
