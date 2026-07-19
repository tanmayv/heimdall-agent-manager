import { useCallback, useLayoutEffect, useMemo, useRef, useState } from 'react';
import type { ReactNode } from 'react';
import Markdown from '../Markdown';
import ChatHoverCopyButton from '../ChatHoverCopyButton';
import type { ChatDeliveryStatus, ChatMessage, ChatTimestamp } from './types';

const EMPTY_TIMESTAMP: ChatTimestamp = { label: '', iso: '' };
const EMPTY_DELIVERY: ChatDeliveryStatus = { glyph: '', label: '', tone: '' };

export default function ChatMessageList({
  conversationKey,
  messages,
  debugPrefix,
  emptyText = 'No chat loaded.',
  emptyState,
  hasMore = false,
  loadingOlder = false,
  onLoadOlder,
  onReply,
  renderMessageTop,
  renderMessageBody,
  formatTimestamp = () => EMPTY_TIMESTAMP,
  getDeliveryStatus = () => EMPTY_DELIVERY,
  wrapperClassName = 'relative min-h-0 flex-1 overflow-hidden',
  scrollClassName = 'chat-scrollbar h-full min-h-0 space-y-[22px] overflow-y-auto rounded-[18px] bg-[#090909] p-5',
}: {
  conversationKey: string;
  messages: ChatMessage[];
  debugPrefix: string;
  emptyText?: string;
  emptyState?: ReactNode;
  hasMore?: boolean;
  loadingOlder?: boolean;
  onLoadOlder?: () => void;
  onReply?: (reply: string) => void;
  renderMessageTop?: (args: { message: ChatMessage; index: number; messages: ChatMessage[] }) => React.ReactNode;
  renderMessageBody?: (args: { message: ChatMessage; onReply: (reply: string) => void }) => React.ReactNode;
  formatTimestamp?: (unixMs: number) => ChatTimestamp;
  getDeliveryStatus?: (message: ChatMessage) => ChatDeliveryStatus;
  wrapperClassName?: string;
  scrollClassName?: string;
}) {
  const scrollRef = useRef<HTMLDivElement | null>(null);
  const stickyRef = useRef(true);
  const lastCountRef = useRef(0);
  const lastConversationRef = useRef(conversationKey);
  const didInitialScrollRef = useRef(false);
  const [showJump, setShowJump] = useState(false);
  const reply = useMemo(() => onReply || (() => undefined), [onReply]);

  const scrollToBottom = useCallback((behavior: ScrollBehavior = 'auto') => {
    const node = scrollRef.current;
    if (!node) return;
    node.scrollTo({ top: node.scrollHeight, behavior });
    stickyRef.current = true;
    setShowJump(false);
  }, []);

  useLayoutEffect(() => {
    if (lastConversationRef.current !== conversationKey) {
      lastConversationRef.current = conversationKey;
      lastCountRef.current = 0;
      stickyRef.current = true;
      didInitialScrollRef.current = false;
      setShowJump(false);
    }

    const count = messages.length;
    if (count === 0) {
      lastCountRef.current = 0;
      return;
    }

    if (!didInitialScrollRef.current) {
      didInitialScrollRef.current = true;
      lastCountRef.current = count;
      scrollToBottom('auto');
      return;
    }

    if (count !== lastCountRef.current) {
      const grew = count > lastCountRef.current;
      lastCountRef.current = count;
      if (grew && stickyRef.current) requestAnimationFrame(() => scrollToBottom('smooth'));
    }
  }, [conversationKey, messages.length, scrollToBottom]);

  const onScroll = useCallback(() => {
    const node = scrollRef.current;
    if (!node) return;
    const distance = node.scrollHeight - node.scrollTop - node.clientHeight;
    const nearBottom = distance < 48;
    stickyRef.current = nearBottom;
    setShowJump(!nearBottom && messages.length > 0);
  }, [messages.length]);

  return (
    <div className={wrapperClassName}>
      <div ref={scrollRef} data-debug-id={`${debugPrefix}-scroll`} onScroll={onScroll} className={scrollClassName}>
        {hasMore ? (
          <div className="flex justify-center">
            <button data-debug-id={`${debugPrefix}-load-older-messages-btn`} type="button" onClick={onLoadOlder} disabled={loadingOlder || !onLoadOlder} className="rounded-full border border-white/10 bg-[#141414] px-3 py-1.5 text-xs text-zinc-400 hover:text-zinc-100 disabled:cursor-not-allowed disabled:opacity-50">
              {loadingOlder ? 'Loading older messages…' : 'Load older messages'}
            </button>
          </div>
        ) : null}
        {messages.length === 0 ? (
          emptyState || <div className="rounded-2xl border border-dashed border-white/10 p-6 text-sm text-zinc-500">{emptyText}</div>
        ) : messages.map((message, index) => {
          const timestamp = formatTimestamp(message.createdUnixMs);
          const delivery = getDeliveryStatus(message);
          return (
            <div key={message.key} data-debug-id={`${debugPrefix}-message-${message.messageId}`} className={`msg group flex ${message.isUser ? 'justify-end' : 'justify-start'}`}>
              <div className={`flex ${message.isUser ? 'max-w-[74%] items-end' : 'w-full items-start'} flex-col text-sm`}>
                <div className="mb-1 flex max-w-full items-center gap-2 text-[10px] uppercase tracking-wider text-zinc-600">
                  <span className="truncate">{message.authorLabel}</span>
                  {timestamp.label ? <time data-debug-id={`${debugPrefix}-message-${message.messageId}-time`} dateTime={timestamp.iso} title={timestamp.iso} className="shrink-0">{timestamp.label}</time> : null}
                </div>
                {renderMessageTop ? renderMessageTop({ message, index, messages }) : null}
                <div className={`${message.isUser ? 'rounded-[15px] border border-[#262626] bg-[#1c1c1c] px-[14px] py-[10px] text-zinc-100' : 'max-w-full text-zinc-200'}`}>
                  {renderMessageBody ? renderMessageBody({ message, onReply: reply }) : <Markdown source={message.body} compact copyAll={false} />}
                </div>
                <div data-debug-id={`${debugPrefix}-message-actions-${message.messageId}`} className={`mt-1 flex items-center gap-[10px] text-[13px] text-zinc-500 ${message.isUser ? 'self-end' : 'self-start'}`}>
                  <ChatHoverCopyButton debugId={`${debugPrefix}-message-copy-btn-${message.messageId}`} text={message.body} />
                </div>
                {message.isUser && delivery.glyph ? (
                  <div data-debug-id={`${debugPrefix}-message-${message.messageId}-status`} title={delivery.label} className={`mt-1 text-right text-[10px] ${delivery.tone}`}>{delivery.glyph} {delivery.label}</div>
                ) : null}
              </div>
            </div>
          );
        })}
      </div>
      {showJump ? (
        <button data-debug-id={`${debugPrefix}-jump-latest-btn`} onClick={() => scrollToBottom('smooth')} className="absolute bottom-3 right-3 rounded-full border border-white/10 bg-black/70 px-3 py-1 text-[11px] text-zinc-100 shadow-lg hover:bg-black">Jump to latest ↓</button>
      ) : null}
    </div>
  );
}
