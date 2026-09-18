import { useCallback, useEffect, useLayoutEffect, useMemo, useRef, useState } from 'react';
import type { ReactNode, UIEvent } from 'react';
import Markdown from '../Markdown';
import ChatHoverCopyButton from '../ChatHoverCopyButton';
import type { ChatDeliveryStatus, ChatMessage, ChatTimestamp } from './types';

const EMPTY_TIMESTAMP: ChatTimestamp = { label: '', iso: '' };
const EMPTY_DELIVERY: ChatDeliveryStatus = { glyph: '', label: '', tone: '' };

// CHAT-SCROLL: per the user's request, always scroll the list to the bottom when a
// new INBOUND message arrives in the active conversation (not only when already
// near the bottom). Flip this to false to restore the standard "don't yank while
// reading history" near-bottom guard for inbound messages. The user's OWN send
// always scrolls to the bottom regardless of this flag.
const SCROLL_TO_BOTTOM_ON_INBOUND = true;

// Deep-link scroll-to-match tuning. HIGHLIGHT_MS is how long the matched message
// stays tinted; MAX_FOCUS_PAGE_LOADS caps how many "load older" pages we auto-fetch
// while hunting for a not-yet-loaded match, so a bad/old id can never loop forever.
const HIGHLIGHT_MS = 1500;
const MAX_FOCUS_PAGE_LOADS = 25;

// prefersReducedMotion reads the user's OS setting (mirrors AgentActivityBubbles):
// when true we skip smooth scrolling and the highlight fade so nothing animates.
function prefersReducedMotion(): boolean {
  return (
    typeof window !== 'undefined' &&
    typeof window.matchMedia === 'function' &&
    window.matchMedia('(prefers-reduced-motion: reduce)').matches
  );
}

export default function ChatMessageList({
  conversationKey,
  messages,
  debugPrefix,
  focusMessageId,
  emptyText = 'No chat loaded.',
  emptyState,
  hasMore = false,
  loadingOlder = false,
  onLoadOlder,
  onScroll: onScrollProp,
  onReply,
  renderMessageTop,
  renderMessageBody,
  formatTimestamp = () => EMPTY_TIMESTAMP,
  getDeliveryStatus = () => EMPTY_DELIVERY,
  agentIsWorking = false,
  wrapperClassName = 'relative min-h-0 min-w-0 max-w-full flex-1 overflow-hidden overflow-x-hidden',
  scrollClassName = 'chat-scrollbar h-full min-h-0 max-w-full space-y-[22px] overflow-y-auto overflow-x-hidden rounded-none bg-[#090909] px-1 pt-16 pb-44 sm:space-y-4 sm:rounded-[18px] sm:p-5',
}: {
  conversationKey: string;
  messages: ChatMessage[];
  debugPrefix: string;
  // Deep-link focus target (from `/conversations/:id?msg=:mid`): once messages have
  // loaded, scroll this message into view and briefly highlight it, exactly once per
  // id. Best-effort: if the message isn't on a loaded page yet we simply stay put.
  focusMessageId?: string;
  emptyText?: string;
  emptyState?: ReactNode;
  hasMore?: boolean;
  loadingOlder?: boolean;
  onLoadOlder?: () => void;
  onScroll?: (event: UIEvent<HTMLDivElement>) => void;
  onReply?: (reply: string) => void;
  renderMessageTop?: (args: { message: ChatMessage; index: number; messages: ChatMessage[] }) => React.ReactNode;
  renderMessageBody?: (args: { message: ChatMessage; onReply: (reply: string) => void }) => React.ReactNode;
  formatTimestamp?: (unixMs: number) => ChatTimestamp;
  getDeliveryStatus?: (message: ChatMessage) => ChatDeliveryStatus;
  agentIsWorking?: boolean;
  wrapperClassName?: string;
  scrollClassName?: string;
}) {
  const scrollRef = useRef<HTMLDivElement | null>(null);
  const stickyRef = useRef(true);
  const lastCountRef = useRef(0);
  const lastConversationRef = useRef(conversationKey);
  const didInitialScrollRef = useRef(false);
  const [showJump, setShowJump] = useState(false);
  const [highlightId, setHighlightId] = useState<string | null>(null);
  const focusedRef = useRef<string | null>(null);
  // Scroll-to-match bookkeeping: how many "load older" pages we've auto-fetched for
  // the current focus id, the id we've already given up on (so we announce "not
  // found" once), and a polite aria-live message for screen readers.
  const focusPageLoadsRef = useRef(0);
  const gaveUpRef = useRef<string | null>(null);
  const [focusAnnouncement, setFocusAnnouncement] = useState('');
  const reduceMotion = prefersReducedMotion();
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
      if (grew) {
        // Always scroll on the user's OWN send (even if scrolled up); for inbound
        // messages scroll per SCROLL_TO_BOTTOM_ON_INBOUND, else only when the user
        // is already near the bottom (stickyRef).
        const ownSend = messages[count - 1]?.isUser === true;
        if (ownSend || SCROLL_TO_BOTTOM_ON_INBOUND || stickyRef.current) {
          requestAnimationFrame(() => scrollToBottom('smooth'));
        }
      }
    }
  }, [conversationKey, messages.length, scrollToBottom]);

  // Reset the scroll-to-match bookkeeping whenever the target id changes, so a new
  // search result re-runs the hunt (and re-announces) rather than being suppressed by
  // the once-per-id guards below.
  useEffect(() => {
    focusPageLoadsRef.current = 0;
    gaveUpRef.current = null;
    setFocusAnnouncement('');
  }, [focusMessageId]);

  // Deep-link scroll-to-match: bring the target message into view + briefly highlight
  // it, and move focus/announce for a11y. Runs after the initial bottom-scroll layout
  // effect so it wins, and succeeds at most once per focusMessageId (a background
  // poll/new message must not yank the reader back). If the message is NOT on a loaded
  // page yet, auto-fetch older pages (capped) until it appears; if it never does, give
  // up gracefully with a non-blocking announcement (no error, reader stays put).
  useEffect(() => {
    if (!focusMessageId) return;
    if (focusedRef.current === focusMessageId) return;
    if (gaveUpRef.current === focusMessageId) return;
    if (messages.length === 0) return;
    const node = scrollRef.current;
    if (!node) return;

    const el = node.querySelector<HTMLElement>(`[data-debug-id="${debugPrefix}-message-${focusMessageId}"]`);
    if (el) {
      focusedRef.current = focusMessageId;
      requestAnimationFrame(() => {
        el.scrollIntoView({ block: 'center', behavior: reduceMotion ? 'auto' : 'smooth' });
        // Move keyboard/AT focus to the matched message (non-tab-stop) so keyboard and
        // screen-reader users land on it; preventScroll keeps scrollIntoView in charge.
        el.tabIndex = -1;
        el.focus({ preventScroll: true });
        stickyRef.current = false; // we intentionally moved off the bottom
        setShowJump(true);
      });
      setHighlightId(focusMessageId);
      setFocusAnnouncement('Jumped to the matching message.');
      const timer = window.setTimeout(() => setHighlightId((cur) => (cur === focusMessageId ? null : cur)), HIGHLIGHT_MS);
      return () => window.clearTimeout(timer);
    }

    // Not loaded yet: walk older pages until the row appears or we exhaust/limit.
    if (hasMore && onLoadOlder && !loadingOlder && focusPageLoadsRef.current < MAX_FOCUS_PAGE_LOADS) {
      focusPageLoadsRef.current += 1;
      setFocusAnnouncement('Loading earlier messages to reach the matching message…');
      onLoadOlder(); // messages grows → this effect re-runs and re-checks
      return;
    }

    // No more pages (or hit the cap) and still not found: stop, announce once.
    if (!loadingOlder) {
      gaveUpRef.current = focusMessageId;
      setFocusAnnouncement('Could not find the matching message in this conversation.');
    }
  }, [focusMessageId, messages, debugPrefix, hasMore, loadingOlder, onLoadOlder, reduceMotion]);

  const onScroll = useCallback((event: UIEvent<HTMLDivElement>) => {
    onScrollProp?.(event);
    const node = scrollRef.current;
    if (!node) return;
    const distance = node.scrollHeight - node.scrollTop - node.clientHeight;
    const nearBottom = distance < 64;
    stickyRef.current = nearBottom;
    setShowJump(!nearBottom && messages.length > 0);
  }, [messages.length, onScrollProp]);

  return (
    <div className={wrapperClassName}>
      {/* Polite live region for scroll-to-match: announces the jump / paging / not-found
          to screen readers without stealing focus or blocking. */}
      <div data-debug-id={`${debugPrefix}-focus-status`} role="status" aria-live="polite" className="sr-only">{focusAnnouncement}</div>
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
            <div key={message.key} data-debug-id={`${debugPrefix}-message-${message.messageId}`} className={`msg group flex min-w-0 max-w-full rounded-xl outline-none focus-visible:shadow-focus ${reduceMotion ? '' : 'transition-colors duration-500'} ${message.messageId === highlightId ? 'bg-warning-soft ring-1 ring-warning' : ''} ${message.isUser ? 'justify-end' : 'justify-start'}`}>
              <div className={`flex min-w-0 max-w-full ${message.isUser ? 'max-w-[86%] items-end sm:max-w-[78%]' : 'w-full items-start'} flex-col text-sm`}>
                {renderMessageTop ? renderMessageTop({ message, index, messages }) : null}
                <div className={`min-w-0 max-w-full overflow-hidden break-words [overflow-wrap:anywhere] ${message.isUser ? 'rounded-[15px] border border-[#262626] bg-[#1c1c1c] px-[14px] py-[10px] text-zinc-100' : 'text-zinc-200'}`}>
                  {renderMessageBody ? renderMessageBody({ message, onReply: reply }) : <Markdown source={message.body} compact copyAll={false} />}
                </div>
                <div data-debug-id={`${debugPrefix}-message-actions-${message.messageId}`} className={`pointer-events-none h-0 overflow-visible text-[12px] text-zinc-500 ${message.isUser ? 'self-end' : 'self-start'}`}>
                  <ChatHoverCopyButton debugId={`${debugPrefix}-message-copy-btn-${message.messageId}`} text={message.body} className="pointer-events-auto rounded-full border border-white/10 bg-black/50 px-1.5 py-0.5 shadow-lg" />
                </div>
                <div className="mt-1 flex w-full items-center justify-end gap-1.5 text-[10px] text-zinc-500">
                  {timestamp.label ? <time data-debug-id={`${debugPrefix}-message-${message.messageId}-time`} dateTime={timestamp.iso} title={timestamp.iso}>{timestamp.label}</time> : null}
                  {message.isUser && delivery.glyph ? (
                    <span data-debug-id={`${debugPrefix}-message-${message.messageId}-status`} title={delivery.label} className={delivery.tone}>{delivery.glyph} {delivery.label}</span>
                  ) : null}
                </div>
              </div>
            </div>
          );
        })}
        {agentIsWorking && (
          <div data-debug-id={`${debugPrefix}-working-indicator`} className="msg flex min-w-0 max-w-full justify-start">
            <div className="flex w-full flex-col items-start text-sm text-zinc-400">
              <div className="flex items-center gap-1.5 rounded-full border border-[#262626] bg-[#111111] px-3 py-2 shadow-sm">
                <span className="h-1.5 w-1.5 animate-bounce rounded-full bg-zinc-500" style={{ animationDelay: '0ms' }} />
                <span className="h-1.5 w-1.5 animate-bounce rounded-full bg-zinc-500" style={{ animationDelay: '150ms' }} />
                <span className="h-1.5 w-1.5 animate-bounce rounded-full bg-zinc-500" style={{ animationDelay: '300ms' }} />
              </div>
            </div>
          </div>
        )}
      </div>
      {showJump ? (
        <button data-debug-id={`${debugPrefix}-jump-latest-btn`} onClick={() => scrollToBottom('smooth')} className="absolute bottom-3 right-3 rounded-full border border-white/10 bg-black/70 px-3 py-1 text-caption text-zinc-100 shadow-lg hover:bg-black">Jump to latest ↓</button>
      ) : null}
    </div>
  );
}
