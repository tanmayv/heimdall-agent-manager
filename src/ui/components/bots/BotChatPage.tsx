import { Alert, Badge, Button, Spinner, Text } from '@ui';
import { useCallback, useEffect, useMemo, useRef, useState, type FormEvent } from 'react';
import { useDispatch } from 'react-redux';
import {
  botsApi, useGetBotQuery, useGetUnifiedBotMessagesQuery, useSendBotWebMessageMutation,
  type BotView, type UnifiedBotMessage,
} from '../../api/endpoints/bots';
import { useFetchExperimentsQuery } from '../../api/endpoints/settings';
import { apiErrorText, queryErrorStatus } from '../../api/cookieFetch';
import Markdown from '../Markdown';
import ChatMessageList from '../chat/ChatMessageList';
import {
  MessageComposerActions, MessageComposerInput, MessageComposerMorphShell, useComposerDockInset, useComposerExpanded,
} from '../chat/MessageComposer';
import type { StreamRevealOptions } from '../chat/streamReveal';
import type { ChatMessage } from '../chat/types';
import { useIsMobile } from '../shell/responsive';
import { BOTS_EXPERIMENT_KEY, resolveExperimentFlag } from '../settings/experimentFlags';
import { BOT_STATUS_DETAILS } from '../settings/botsView';
import {
  BOT_CHANNEL_LABELS, BOT_HISTORY_PAGE_SIZE, awaitingBotReply, botChatErrorText, botChatMessages, botChatMeta,
  botDeliveryStatus, botQueueNotice, botTimeline, checkBotComposerText, formatBotChatTimestamp,
  isBotComposerSend, mergeBotMessages, newIdempotencyKey, visiblePendingSends, type PendingBotSend,
} from './botChatModel';

/**
 * REQ-WEB-5: one conversation with the owner's bot across Telegram, WhatsApp and
 * the built-in web channel. Mounts nothing bot-related until the experiment and
 * the bot are known.
 *
 * Like the coordinator chat, the page owns the shell's top chrome row (AppShell
 * draws no spacer on /bot): the header IS that row. `headerLeading` reserves the
 * floating top-left cluster's width while the sidebar is collapsed.
 */
export default function BotChatPage({ headerLeading = null }: { headerLeading?: React.ReactNode } = {}) {
  const flags = useFetchExperimentsQuery();
  const flag = resolveExperimentFlag(flags.data?.flags, BOTS_EXPERIMENT_KEY);
  const enabled = flag === 'enabled';
  // Status changes (starting → ready) publish no event; poll like Settings › Bots.
  const query = useGetBotQuery(undefined, { skip: !enabled, pollingInterval: enabled ? 10000 : 0 });
  const bot = enabled ? query.currentData : undefined;
  const status = queryErrorStatus(query.error);
  const isMobile = useIsMobile();
  // The header is shown before the bot loads so the chrome row (and the
  // sidebar toggle above it) never collapses; the name fills in once known.
  const header = (
    <header data-debug-id="bot-chat-header"
      className={`window-drag flex ${isMobile ? 'h-14' : 'h-12'} min-w-0 shrink-0 items-center gap-2 px-3 sm:px-4`}>
      {headerLeading ? <div data-debug-id="bot-chat-header-leading" className="flex shrink-0 items-center">{headerLeading}</div> : null}
      <h1 data-debug-id="bot-chat-title" className={`min-w-0 truncate px-1.5 font-medium text-primary ${isMobile ? 'text-[15px]' : 'text-sm'}`}>{bot?.display_name ?? ''}</h1>
    </header>
  );
  let body: React.ReactNode;
  if (flag === 'loading' && !flags.isError) body = <Loading />;
  else if (!enabled) body = <div data-debug-id="bot-chat-disabled" className="m-4 min-w-0"><Alert tone="info">{botChatErrorText(403, '')}</Alert></div>;
  else if (bot) body = <BotChatView key={bot.bot_id} bot={bot} />;
  else if (query.isError) body = <div data-debug-id="bot-chat-load-error" className="m-4 min-w-0"><Alert tone="danger">{botChatErrorText(status, apiErrorText(query.error))}</Alert></div>;
  else body = <Loading />;
  return <div data-debug-id="bot-chat-page" className="flex h-full min-h-0 w-full min-w-0 flex-1 flex-col">{header}{body}</div>;
}

function Loading() {
  return <div className="flex items-center gap-2 px-4 py-6"><Spinner /><Text tone="muted">Loading…</Text></div>;
}

function BotChatView({ bot }: { bot: BotView }) {
  const dispatch = useDispatch<any>();
  const isMobile = useIsMobile();
  const head = useGetUnifiedBotMessagesQuery({ limit: BOT_HISTORY_PAGE_SIZE });
  const [send] = useSendBotWebMessageMutation();
  const [known, setKnown] = useState<ReadonlyMap<string, UnifiedBotMessage>>(() => new Map());
  const [pending, setPending] = useState<PendingBotSend[]>([]);
  // message_id → idempotency key of the composer send that stored it (stable row keys).
  const [sentKeys, setSentKeys] = useState<ReadonlyMap<string, string>>(() => new Map());
  const [text, setText] = useState('');
  const [composerError, setComposerError] = useState('');
  const [older, setOlder] = useState<{ loading: boolean; error: string; pagesLoaded: number; endReached: boolean }>(
    { loading: false, error: '', pagesLoaded: 0, endReached: false });
  const loadingOlder = useRef(false);
  const textareaRef = useRef<HTMLTextAreaElement | null>(null);
  const composerDockRef = useRef<HTMLDivElement | null>(null);
  // The same dock/transcript synchronisation as the coordinator chat (REQ-FROST-1).
  const composerDockHeight = useComposerDockInset(composerDockRef, {
    insetDebugId: 'bot-chat-bottom-inset',
    jumpDebugId: 'bot-chat-jump-latest-btn',
    resetKey: `${isMobile}:${bot.bot_id}`,
  });
  const expansion = useComposerExpanded({ draft: text });

  // Every head refresh (initial load, bot_changed invalidation, own send) is folded
  // into the accumulated history rather than replacing it.
  useEffect(() => { setKnown((current) => mergeBotMessages(current, head.currentData?.messages)); }, [head.currentData]);

  const timeline = useMemo(() => botTimeline(known), [known]);
  const shownPending = useMemo(() => visiblePendingSends(pending, known), [pending, known]);
  const messages = useMemo(() => botChatMessages(timeline, shownPending, sentKeys), [timeline, shownPending, sentKeys]);
  const headNext = head.currentData?.next_cursor ?? '';
  const hasOlder = !older.endReached && (headNext !== '' || older.pagesLoaded > 0) && timeline.length > 0;

  const loadOlder = useCallback(async () => {
    const cursor = timeline[0]?.message_id;
    if (loadingOlder.current || !hasOlder || !cursor) return;
    loadingOlder.current = true;
    setOlder((o) => ({ ...o, loading: true, error: '' }));
    try {
      const page = await dispatch(botsApi.endpoints.getUnifiedBotMessages.initiate(
        { limit: BOT_HISTORY_PAGE_SIZE, cursor }, { subscribe: false, forceRefetch: true })).unwrap();
      setKnown((current) => mergeBotMessages(current, page.messages));
      setOlder((o) => ({ loading: false, error: '', pagesLoaded: o.pagesLoaded + 1, endReached: !page.next_cursor }));
    } catch (error) {
      setOlder((o) => ({ ...o, loading: false, error: botChatErrorText(queryErrorStatus(error), apiErrorText(error, 'Could not load older messages.')) }));
    } finally {
      loadingOlder.current = false;
    }
  }, [dispatch, hasOlder, timeline]);

  const deliver = useCallback(async (item: PendingBotSend) => {
    setPending((rows) => [...rows.filter((row) => row.key !== item.key), { ...item, state: 'sending', error: '' }]);
    try {
      const result = await send({ text: item.text, idempotency_key: item.key }).unwrap();
      setSentKeys((keys) => new Map(keys).set(result.message_id, item.key));
      setPending((rows) => rows.map((row) => row.key === item.key ? { ...row, state: 'sent', message_id: result.message_id } : row));
    } catch (error) {
      const message = botChatErrorText(queryErrorStatus(error), apiErrorText(error, 'Your message was not sent.'));
      setPending((rows) => rows.map((row) => row.key === item.key ? { ...row, state: 'failed', error: message } : row));
    }
  }, [send]);

  const submit = (event?: FormEvent) => {
    event?.preventDefault();
    const check = checkBotComposerText(text);
    if (check === 'too_long') { setComposerError('This message is too long. Shorten it and send again.'); return; }
    if (check) return;
    setComposerError('');
    setText('');
    void deliver({ key: newIdempotencyKey(), text, state: 'sending', message_id: '', error: '' });
    textareaRef.current?.focus({ preventScroll: true });
  };

  const waiting = awaitingBotReply(timeline, shownPending);
  const notice = botQueueNotice(bot.status, waiting);
  const headStatus = queryErrorStatus(head.error);
  const sendFailure = shownPending.find((row) => row.state === 'failed');
  const statusDetail = bot.status_detail ? BOT_STATUS_DETAILS[bot.status_detail] : '';

  const renderMeta = useCallback((message: ChatMessage) => {
    const meta = botChatMeta(message);
    if (!meta) return null;
    const failedSend = meta.pending === 'failed' ? shownPending.find((row) => row.key === message.key) : undefined;
    const outbound = !message.isUser && meta.sendState && meta.sendState !== 'sent'
      ? (meta.sendState === 'failed' || meta.sendState === 'held' ? 'Not delivered' : 'Sending…') : '';
    return <>
      <ChannelBadge provider={meta.provider} />
      {outbound ? <span data-debug-id="bot-chat-message-state" className={outbound === 'Not delivered' ? 'text-danger' : undefined}>{outbound}</span> : null}
      {failedSend ? <button type="button" data-debug-id="bot-chat-retry" onClick={() => void deliver(failedSend)}
        className="min-h-11 rounded-lg px-2 text-xs text-accent hover:bg-neutral-soft sm:min-h-8">Retry</button> : null}
    </>;
  }, [deliver, shownPending]);

  const renderBody = useCallback(({ message, reveal }: { message: ChatMessage; reveal?: StreamRevealOptions }) =>
    botChatMeta(message)?.purged
      ? <span className="italic text-muted">This message was removed by retention.</span>
      : <Markdown source={message.body} compact copyAll={false} reveal={reveal} />, []);

  const emptyState = head.isLoading ? <Loading />
    : head.isError ? <div data-debug-id="bot-chat-history-error" className="min-w-0 p-4"><Alert tone="danger">{botChatErrorText(headStatus, apiErrorText(head.error, 'Could not load messages.'))}</Alert></div>
    : <p data-debug-id="bot-chat-empty" className="py-10 text-center text-sm text-muted">No messages yet. Say hello to {bot.display_name}.</p>;

  return <>
    {older.error ? (
      <div data-debug-id="bot-chat-older-error-row" className="flex min-w-0 shrink-0 items-center justify-center gap-2 px-4 py-2">
        <p role="alert" data-debug-id="bot-chat-older-error" className="min-w-0 text-xs text-muted">{older.error}</p>
        <Button type="button" variant="ghost" size="sm" data-debug-id="bot-chat-older-retry"
          onClick={() => { setOlder((o) => ({ ...o, error: '' })); void loadOlder(); }}>Retry</Button>
      </div>
    ) : null}
    <div data-debug-id="bot-chat-transcript" role="log" aria-label={`Messages with ${bot.display_name}`} aria-busy={head.isLoading || older.loading}
      className="relative flex w-full min-h-0 min-w-0 max-w-full flex-1 flex-col overflow-x-hidden p-0 sm:px-4 sm:py-3">
      <ChatMessageList
        conversationKey={`bot:${bot.bot_id}`}
        messages={messages}
        debugPrefix="bot-chat"
        hasMore={hasOlder && !older.error}
        paginationCursor={timeline[0]?.message_id}
        loadingOlder={older.loading}
        onLoadOlder={() => void loadOlder()}
        formatTimestamp={formatBotChatTimestamp}
        getDeliveryStatus={botDeliveryStatus}
        renderMessageMeta={renderMeta}
        renderMessageBody={renderBody}
        agentIsWorking={waiting && bot.status === 'working'}
        bottomInset={composerDockHeight}
        pinOnSend={isBotComposerSend}
        pinOriginRef={textareaRef}
        emptyState={emptyState}
        wrapperClassName="relative min-h-0 min-w-0 max-w-full flex-1 overflow-hidden overflow-x-hidden"
        scrollClassName="chat-scrollbar h-full min-h-0 max-w-full space-y-3 overflow-y-auto overflow-x-hidden rounded-none bg-canvas px-1 py-3 sm:space-y-4 sm:rounded-[18px] sm:px-4 sm:py-4"
      />
      {/* The coordinator chat's floating composer dock (AgentChatPane, REQ-FROST-1/2). */}
      <div ref={composerDockRef} data-debug-id="bot-chat-composer-dock" data-floating="true"
        className="ui-float-dock absolute inset-x-0 bottom-0 z-20 mx-auto w-full max-w-[calc(56rem+1.5rem)]">
        <div aria-hidden="true" className="ui-frost-tail" />
        <form onSubmit={submit} data-debug-id="bot-chat-composer-shell"
          className={`mx-auto w-full max-w-[calc(56rem+1.5rem)] px-3 pt-2 ${isMobile ? 'ui-float-dock-pad' : 'pb-4'}`}>
          <div className="mx-auto w-full max-w-4xl space-y-2">
            {notice ? <div className="pointer-events-none flex justify-center">
              <div role="status" data-debug-id="bot-chat-queue-notice" data-tone={notice.tone}
                className={`ui-liquid-glass max-w-full rounded-full px-4 py-1.5 text-center text-[13px] ${notice.tone === 'warning' ? 'text-warning' : 'text-primary'}`}>{notice.text}</div>
            </div> : null}
            {statusDetail ? <Text tone="muted" data-debug-id="bot-chat-status-detail" className="block text-center">{statusDetail}</Text> : null}
            {sendFailure ? <div data-debug-id="bot-chat-send-error" className="min-w-0"><Alert tone="danger">{sendFailure.error}</Alert></div> : null}
            {composerError ? <div data-debug-id="bot-chat-composer-error" className="min-w-0"><Alert tone="danger">{composerError}</Alert></div> : null}
            <MessageComposerMorphShell expansion={expansion} debugPrefix="bot-chat" debugId="bot-chat-composer-card"
              className="ui-frost-card isolate rounded-[28px] border px-5"
              leading={<div data-debug-id="bot-chat-composer-frost" aria-hidden="true" className="ui-frost-gradient -z-10"><span /><span /><span /></div>}
              actions={<MessageComposerActions debugPrefix="bot-chat" mobile={isMobile} provider="" model=""
                sendDisabled={!text.trim()} morph={expansion} />}>
              <MessageComposerInput mobile={isMobile} morph debugId="bot-chat-input" ref={textareaRef}
                aria-label={`Message ${bot.display_name}`} value={text}
                onChange={(event) => { setText(event.target.value); if (composerError) setComposerError(''); }}
                onKeyDown={(event) => {
                  if (event.key === 'Enter' && (event.metaKey || event.ctrlKey) && !event.nativeEvent.isComposing) { event.preventDefault(); submit(); }
                }}
                placeholder={isMobile ? `Message ${bot.display_name}…` : `Message ${bot.display_name}… (Cmd/Ctrl+Enter to send)`} />
            </MessageComposerMorphShell>
          </div>
        </form>
      </div>
    </div>
  </>;
}

function ChannelBadge({ provider }: { provider: UnifiedBotMessage['provider'] }) {
  return <Badge data-debug-id="bot-chat-channel" tone={provider === 'web' ? 'neutral' : 'info'}>{BOT_CHANNEL_LABELS[provider] ?? provider}</Badge>;
}
