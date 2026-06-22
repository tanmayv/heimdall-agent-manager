import { useLayoutEffect, useRef, useState } from 'react';
import { useDispatch, useSelector } from 'react-redux';
import { fetchSelectedChat } from '../store/chatSlice';
import Composer from './Composer';
import MessageBubble from './MessageBubble';

const NEW_MESSAGE_THRESHOLD = 48;

const EMPTY_ARRAY: any[] = [];

export default function ChatPane({ agent, session }: { agent: any; session: any }) {
  const dispatch = useDispatch<any>();
  const messages = useSelector((state: any) => agent ? state.chat.chats[agent.id] ?? EMPTY_ARRAY : EMPTY_ARRAY);
  const sending = useSelector((state: any) => state.chat.sending);
  const chatsCursor = useSelector((state: any) => state.chat.chatsCursor);
  const chatsHasMore = useSelector((state: any) => state.chat.chatsHasMore);
  const [fetchingMore, setFetchingMore] = useState(false);
  const messageListRef = useRef(null);
  const prevMessageCountRef = useRef(messages.length);
  const prevAgentIdRef = useRef(agent?.id ?? '');
  const wasNearBottomRef = useRef(true);
  const submitScrollPendingRef = useRef(false);
  const [showNewMessagesToast, setShowNewMessagesToast] = useState(false);

  function getIsNearBottom() {
    const container = messageListRef.current;
    if (!container) return true;
    const delta = container.scrollHeight - container.scrollTop - container.clientHeight;
    return delta <= NEW_MESSAGE_THRESHOLD;
  }

  function getIsScrollable() {
    const container = messageListRef.current;
    if (!container) return false;
    return container.scrollHeight > container.clientHeight;
  }

  function scrollToBottom(behavior: 'auto' | 'smooth' = 'auto') {
    const container = messageListRef.current;
    if (!container) return;
    container.scrollTo({ top: container.scrollHeight, behavior });
    wasNearBottomRef.current = true;
  }

  function scrollToBottomAfterLayout(behavior: 'auto' | 'smooth' = 'auto') {
    scrollToBottom(behavior);
    window.requestAnimationFrame(() => scrollToBottom(behavior));
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

  async function onMessagesScroll() {
    const nearBottom = getIsNearBottom();
    wasNearBottomRef.current = nearBottom;
    if (nearBottom) {
      setShowNewMessagesToast(false);
    }

    const container = messageListRef.current;
    if (container && container.scrollTop === 0 && agent?.id) {
      const hasMore = chatsHasMore[agent.id] ?? false;
      const cursor = chatsCursor[agent.id] ?? 0;

      if (hasMore && cursor > 0 && !fetchingMore) {
        setFetchingMore(true);
        const prevScrollHeight = container.scrollHeight;
        try {
          await dispatch(fetchSelectedChat({
            agentId: agent.id,
            cursor,
            limit: 50
          })).unwrap();

          window.requestAnimationFrame(() => {
            const newScrollHeight = container.scrollHeight;
            container.scrollTop = newScrollHeight - prevScrollHeight;
          });
        } catch (e) {
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
      setShowNewMessagesToast(false);
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
    <main className="framer-panel flex min-w-0 flex-1 flex-col bg-[var(--fd-canvas)]">
      <header className="animate-float-in border-b border-[var(--fd-hairline)] bg-[var(--fd-surface-2)] px-6 py-4 flex items-center justify-between">
        <div className="min-w-0">
          <p className="framer-topline">Selected agent</p>
          <h2 className="mt-1 truncate text-2xl framer-headline">{agent?.label ?? 'No agent selected'}</h2>
          <p className="framer-subtext mt-1 truncate">{agent ? `${agent.templateId || 'agent'} · ${agent.providerProfile || 'provider'}` : 'Choose an agent from the sidebar'}</p>
        </div>
        <div className="framer-chip animate-halo-breathe">User: <span className="text-white">{session.userId}</span></div>
      </header>

      <div className="relative flex-1 min-h-0">
        <section
          ref={messageListRef}
          onScroll={onMessagesScroll}
          className="h-full overflow-y-auto px-1 py-4 sm:px-2"
        >
          <div className="w-full flex flex-col gap-3">
            {messages.length ? (
              messages.map((message) => <MessageBubble key={message.id} message={message} />)
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
              className="framer-pill bg-white px-4 py-2 text-xs shadow-[0_14px_40px_rgba(0,0,0,0.35)] hover:translate-y-0 hover:scale-105"
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
