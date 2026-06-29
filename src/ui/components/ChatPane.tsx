import { useEffect, useLayoutEffect, useRef, useState } from 'react';
import { useDispatch, useSelector } from 'react-redux';
import { fetchSelectedChat, refreshAgents, startAgentInstance, stopAgentInstance } from '../store/chatSlice';
import { refreshTaskBoard } from '../store/taskSlice';
import { updateUrlParams } from './useUrlParams';
import Composer from './Composer';
import MessageBubble from './MessageBubble';
import * as daemonApi from '../api/daemonApi';

const NEW_MESSAGE_THRESHOLD = 48;

const EMPTY_ARRAY: any[] = [];

export default function ChatPane({ agent, session }: { agent: any; session: any }) {
  const renderStart = performance.now();
  useEffect(() => {
    const duration = performance.now() - renderStart;
    console.log(`[Render Timer] ChatPane took ${duration.toFixed(2)}ms`);
  });
  const dispatch = useDispatch<any>();
  const messages = useSelector((state: any) => agent ? state.chat.chats[agent.id] ?? EMPTY_ARRAY : EMPTY_ARRAY);
  const sending = useSelector((state: any) => state.chat.sending);
  const chatsCursor = useSelector((state: any) => state.chat.chatsCursor);
  const chatsHasMore = useSelector((state: any) => state.chat.chatsHasMore);
  const [fetchingMore, setFetchingMore] = useState(false);
  const [agentAction, setAgentAction] = useState<'start' | 'stop' | 'force-stop' | 'active-task' | ''>('');
  const [agentActionMessage, setAgentActionMessage] = useState('');
  const messageListRef = useRef(null);
  const prevMessageCountRef = useRef(messages.length);
  const prevAgentIdRef = useRef(agent?.id ?? '');
  const wasNearBottomRef = useRef(true);
  const submitScrollPendingRef = useRef(false);
  const prevScrollHeightRef = useRef(0);
  const initialBottomScrollPendingRef = useRef(!!agent?.id);
  const initialBottomScrollCompleteRef = useRef(false);
  const userScrollIntentRef = useRef(false);
  const userScrolledAfterInitialRef = useRef(false);
  const programmaticScrollRef = useRef(false);
  const prependScrollRestoreRef = useRef<number | null>(null);
  const [showNewMessagesToast, setShowNewMessagesToast] = useState(false);

  function getIsNearBottom() {
    const container = messageListRef.current;
    if (!container) return true;
    const height = prevScrollHeightRef.current || container.scrollHeight;
    const delta = height - container.scrollTop - container.clientHeight;
    return delta <= NEW_MESSAGE_THRESHOLD;
  }

  function getIsScrollable() {
    const container = messageListRef.current;
    if (!container) return false;
    return container.scrollHeight > container.clientHeight;
  }

  function markProgrammaticScroll() {
    programmaticScrollRef.current = true;
    window.requestAnimationFrame(() => {
      window.requestAnimationFrame(() => {
        programmaticScrollRef.current = false;
      });
    });
  }

  function scrollToBottom(behavior: 'auto' | 'smooth' = 'auto') {
    const container = messageListRef.current;
    if (!container) return;
    markProgrammaticScroll();
    container.scrollTo({ top: container.scrollHeight, behavior });
    wasNearBottomRef.current = true;
  }

  function scrollToBottomAfterLayout(behavior: 'auto' | 'smooth' = 'auto', onComplete?: () => void) {
    scrollToBottom(behavior);
    window.requestAnimationFrame(() => {
      scrollToBottom(behavior);
      window.requestAnimationFrame(() => {
        scrollToBottom(behavior);
        onComplete?.();
      });
    });
  }

  function markUserScrollIntent() {
    if (initialBottomScrollCompleteRef.current && !programmaticScrollRef.current) {
      userScrollIntentRef.current = true;
    }
  }

  function onComposerSubmit() {
    // The sent message appears after the async send/fetch completes; remember the
    // user's intent so the next message-list update scrolls even if the new row
    // makes the post-render position no longer count as near-bottom.
    submitScrollPendingRef.current = true;
    if (getIsScrollable()) {
      scrollToBottom('smooth');
    }
    setShowNewMessagesToast(false);
  }

  function onScrollToBottomClick() {
    scrollToBottom('smooth');
    setShowNewMessagesToast(false);
  }

  const agentStatus = agent?.status || '';
  const agentIsRunning = ['connected', 'idle', 'running', 'startup_blocked'].includes(agentStatus);
  const agentIsStarting = agentStatus === 'starting';
  const agentIsStopping = agentStatus === 'stopping';
  const canStartAgent = !!agent?.id && !agentIsRunning && !agentIsStarting && !agentIsStopping;
  const canStopAgent = !!agent?.id && (agentIsRunning || agentIsStarting || agentIsStopping);

  async function runAgentAction(action: 'start' | 'stop' | 'force-stop') {
    if (!agent?.id || agentAction) return;
    setAgentAction(action);
    setAgentActionMessage('');
    try {
      if (action === 'start') {
        await dispatch(startAgentInstance(agent)).unwrap();
        setAgentActionMessage('Start requested.');
      } else if (action === 'stop') {
        await dispatch(stopAgentInstance(agent.id)).unwrap();
        setAgentActionMessage('Stop requested.');
      } else {
        await daemonApi.stopAgent({ daemonUrl: session.daemonUrl, agentInstanceId: agent.id, timeInSec: 1 });
        dispatch(refreshAgents());
        setAgentActionMessage('Force stop requested.');
      }
    } catch (err: any) {
      setAgentActionMessage(err?.message || `Failed to ${action.replace('-', ' ')} agent.`);
    } finally {
      setAgentAction('');
    }
  }

  function normalizeTask(task: any) {
    return {
      taskId: task.task_id || task.taskId || '',
      chainId: task.chain_id || task.chainId || '',
      title: task.title || '',
      status: task.status || '',
      assigneeAgentInstanceId: task.assignee_agent_instance_id || task.assigneeAgentInstanceId || '',
      updatedAtUnixMs: Number(task.updated_at_unix_ms || task.updatedAtUnixMs || 0),
    };
  }

  async function viewActiveTask() {
    if (!agent?.id || agentAction) return;
    setAgentAction('active-task');
    setAgentActionMessage('');
    try {
      const data = await daemonApi.listTasks({
        daemonUrl: session.daemonUrl,
        clientToken: session.clientToken,
        limit: 500,
      });
      const activeTasks = (data.tasks || [])
        .map(normalizeTask)
        .filter((task: any) => task.assigneeAgentInstanceId === agent.id && task.status === 'in_progress')
        .sort((left: any, right: any) => right.updatedAtUnixMs - left.updatedAtUnixMs);
      const activeTask = activeTasks[0];
      if (!activeTask) {
        setAgentActionMessage('No active in-progress task for this agent.');
        return;
      }
      updateUrlParams({ view: 'tasks', chainId: activeTask.chainId, taskId: activeTask.taskId });
      dispatch(refreshTaskBoard({}));
    } catch (err: any) {
      setAgentActionMessage(err?.message || 'Failed to find active task.');
    } finally {
      setAgentAction('');
    }
  }

  async function onMessagesScroll() {
    const nearBottom = getIsNearBottom();
    wasNearBottomRef.current = nearBottom;
    if (nearBottom) {
      setShowNewMessagesToast(false);
    }

    if (userScrollIntentRef.current && !programmaticScrollRef.current) {
      userScrolledAfterInitialRef.current = true;
      userScrollIntentRef.current = false;
    }

    const container = messageListRef.current;
    if (
      container &&
      container.scrollTop === 0 &&
      agent?.id &&
      initialBottomScrollCompleteRef.current &&
      userScrolledAfterInitialRef.current
    ) {
      const hasMore = chatsHasMore[agent.id] ?? false;
      const cursor = chatsCursor[agent.id] ?? 0;

      if (hasMore && cursor > 0 && !fetchingMore) {
        setFetchingMore(true);
        const prevScrollHeight = container.scrollHeight;
        prependScrollRestoreRef.current = prevScrollHeight;
        try {
          await dispatch(fetchSelectedChat({
            agentId: agent.id,
            cursor,
            limit: 50
          })).unwrap();

          window.requestAnimationFrame(() => {
            const newScrollHeight = container.scrollHeight;
            markProgrammaticScroll();
            container.scrollTop = newScrollHeight - prevScrollHeight;
            prependScrollRestoreRef.current = null;
          });
        } catch (e) {
          prependScrollRestoreRef.current = null;
          console.error('Failed to fetch older messages:', e);
        } finally {
          setFetchingMore(false);
        }
      }
    }
  }

  useLayoutEffect(() => {
    const previousAgentId = prevAgentIdRef.current;
    const currentAgentId = agent?.id ?? '';
    const previousCount = prevMessageCountRef.current;
    const agentChanged = currentAgentId !== previousAgentId;
    const messageAdded = messages.length > previousCount;

    if (agentChanged) {
      initialBottomScrollPendingRef.current = !!currentAgentId;
      initialBottomScrollCompleteRef.current = false;
      userScrollIntentRef.current = false;
      userScrolledAfterInitialRef.current = false;
      setShowNewMessagesToast(false);
    }

    if (prependScrollRestoreRef.current !== null) {
      setShowNewMessagesToast(false);
    } else if (initialBottomScrollPendingRef.current && currentAgentId && messages.length > 0) {
      setShowNewMessagesToast(false);
      scrollToBottomAfterLayout('auto', () => {
        initialBottomScrollPendingRef.current = false;
        initialBottomScrollCompleteRef.current = true;
      });
    } else if (agentChanged && currentAgentId && messages.length === 0) {
      scrollToBottomAfterLayout('auto');
    } else if (messageAdded) {
      if (submitScrollPendingRef.current || wasNearBottomRef.current) {
        scrollToBottom(submitScrollPendingRef.current ? 'smooth' : 'auto');
        setShowNewMessagesToast(false);
      } else {
        setShowNewMessagesToast(true);
      }
    } else if (getIsNearBottom()) {
      wasNearBottomRef.current = true;
      setShowNewMessagesToast(false);
    }

    submitScrollPendingRef.current = false;
    prevMessageCountRef.current = messages.length;
    prevAgentIdRef.current = currentAgentId;
    
    const container = messageListRef.current;
    if (container) {
      prevScrollHeightRef.current = container.scrollHeight;
    }
  }, [agent?.id, messages]);

  const lastMessage = messages.length > 0 ? messages[messages.length - 1] : null;
  let smartReplies: string[] | null = null;
  if (lastMessage && lastMessage.author !== 'user' && lastMessage.body) {
    try {
      const parsed = JSON.parse(lastMessage.body);
      if (parsed && parsed.type === 'smart_answer' && Array.isArray(parsed.suggested_replies)) {
        smartReplies = parsed.suggested_replies;
      }
    } catch (e) {
      // Ignore
    }
  }

  return (
    <main className="framer-panel flex min-w-0 min-h-0 flex-1 flex-col bg-[var(--fd-canvas)]">
      <header className="border-b border-[var(--fd-hairline)] bg-[var(--fd-surface-2)] px-6 py-4 flex items-center justify-between">
        <div className="min-w-0">
          <p className="framer-topline">Selected agent</p>
          <h2 className="mt-1 truncate text-2xl framer-headline">{agent?.label ?? 'No agent selected'}</h2>
          <p className="framer-subtext mt-1 truncate">{agent ? `${agent.templateId || 'agent'} · ${agent.providerProfile || 'provider'} · ${agentStatus || 'unknown'}` : 'Choose an agent from the sidebar'}</p>
          {agentActionMessage && <p className="mt-2 text-xs text-[#bdbdbd]">{agentActionMessage}</p>}
        </div>
        <div className="flex shrink-0 flex-wrap items-center justify-end gap-2">
          <button
            type="button"
            data-debug-id="chat-agent-start-btn"
            onClick={() => runAgentAction('start')}
            disabled={!canStartAgent || !!agentAction}
            className="framer-pill bg-white px-3 py-2 text-xs disabled:opacity-40"
          >
            {agentAction === 'start' ? 'Starting…' : 'Start'}
          </button>
          <button
            type="button"
            data-debug-id="chat-agent-stop-btn"
            onClick={() => runAgentAction('stop')}
            disabled={!canStopAgent || !!agentAction}
            className="framer-pill-secondary px-3 py-2 text-xs disabled:opacity-40"
          >
            {agentAction === 'stop' ? 'Stopping…' : 'Stop'}
          </button>
          <button
            type="button"
            data-debug-id="chat-agent-force-stop-btn"
            onClick={() => runAgentAction('force-stop')}
            disabled={!canStopAgent || !!agentAction}
            className="framer-pill-secondary px-3 py-2 text-xs text-red-100 disabled:opacity-40"
            title="Send a stop request with a 1 second timeout."
          >
            {agentAction === 'force-stop' ? 'Forcing…' : 'Force Stop'}
          </button>
          <button
            type="button"
            data-debug-id="chat-agent-active-task-btn"
            onClick={viewActiveTask}
            disabled={!agent?.id || !session.clientToken || !!agentAction}
            className="framer-pill-secondary px-3 py-2 text-xs disabled:opacity-40"
          >
            {agentAction === 'active-task' ? 'Finding…' : 'View Active Task'}
          </button>
          <div className="framer-chip animate-halo-breathe">User: <span className="text-white">{session.userId}</span></div>
        </div>
      </header>

      <div className="relative flex-1 min-h-0 flex flex-col">
        <section
          ref={messageListRef}
          onScroll={onMessagesScroll}
          onWheel={markUserScrollIntent}
          onTouchMove={markUserScrollIntent}
          onPointerDown={markUserScrollIntent}
          onKeyDown={markUserScrollIntent}
          className="flex-1 min-h-0 overflow-y-auto px-1 py-4 sm:px-2"
        >
          <div className="w-full flex flex-col gap-3">
            {messages.length ? (
              messages.map((message) => <MessageBubble key={message.id} message={message} session={session} />)
            ) : (
              <div className="framer-card framer-subtext text-center p-8 text-[#999]">
                {agent ? 'No chat messages for this agent yet.' : 'Select a connected agent to view chat history.'}
              </div>
            )}
          </div>
        </section>

        {showNewMessagesToast && (
          <div className="absolute bottom-6 left-1/2 z-10 -translate-x-1/2">
            <button
              onClick={onScrollToBottomClick}
              type="button"
              data-debug-id="chat-scroll-to-bottom-btn"
              className="framer-pill bg-white px-4 py-2 text-xs shadow-[0_14px_40px_rgba(0,0,0,0.35)] hover:translate-y-0 "
            >
              New Messages
            </button>
          </div>
        )}
      </div>

      <Composer
        selectedAgent={agent}
        disabled={!session.connected || sending}
        onSubmit={onComposerSubmit}
        smartReplies={smartReplies}
      />
    </main>
  );
}
