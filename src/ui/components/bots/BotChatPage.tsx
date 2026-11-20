import { Alert, Badge, Button, Spinner, StatusPill, Text, Textarea } from '@ui';
import { useCallback, useEffect, useLayoutEffect, useMemo, useRef, useState } from 'react';
import { useDispatch } from 'react-redux';
import {
  botsApi, useGetBotQuery, useGetUnifiedBotMessagesQuery, useSendBotWebMessageMutation,
  type BotView, type UnifiedBotMessage,
} from '../../api/endpoints/bots';
import { useFetchExperimentsQuery } from '../../api/endpoints/settings';
import { apiErrorText, queryErrorStatus } from '../../api/cookieFetch';
import MarkdownBody from '../MarkdownBody';
import { BOTS_EXPERIMENT_KEY, resolveExperimentFlag } from '../settings/experimentFlags';
import { BOT_STATUS_DETAILS, resolveBotStatusLabel } from '../settings/botsView';
import {
  BOT_CHANNEL_LABELS, BOT_HISTORY_PAGE_SIZE, awaitingBotReply, botChatErrorText, botQueueNotice, botTimeline,
  checkBotComposerText, connectedBotChannels, formatBotMessageTime, isBotRunning, mergeBotMessages, newIdempotencyKey,
  visiblePendingSends, type PendingBotSend,
} from './botChatModel';

/** Distance from the top (px) that starts loading older history. */
const LOAD_OLDER_THRESHOLD = 64;
/** Distance from the bottom (px) within which new messages keep the view pinned. */
const STICK_THRESHOLD = 96;

/**
 * REQ-WEB-5: one conversation with the owner's bot across Telegram, WhatsApp and
 * the built-in web channel. Mounts nothing bot-related until the experiment and
 * the bot are known.
 */
export default function BotChatPage() {
  const flags = useFetchExperimentsQuery();
  const flag = resolveExperimentFlag(flags.data?.flags, BOTS_EXPERIMENT_KEY);
  const enabled = flag === 'enabled';
  // Status changes (starting → ready) publish no event; poll like Settings › Bots.
  const query = useGetBotQuery(undefined, { skip: !enabled, pollingInterval: enabled ? 10000 : 0 });
  const bot = enabled ? query.currentData : undefined;
  const status = queryErrorStatus(query.error);
  let body: React.ReactNode;
  if (flag === 'loading' && !flags.isError) body = <Loading />;
  else if (!enabled) body = <div data-debug-id="bot-chat-disabled" className="m-4 min-w-0"><Alert tone="info">{botChatErrorText(403, '')}</Alert></div>;
  else if (bot) body = <BotChatView key={bot.bot_id} bot={bot} />;
  else if (query.isError) body = <div data-debug-id="bot-chat-load-error" className="m-4 min-w-0"><Alert tone="danger">{botChatErrorText(status, apiErrorText(query.error))}</Alert></div>;
  else body = <Loading />;
  return <div data-debug-id="bot-chat-page" className="flex h-full min-h-0 w-full min-w-0 flex-1 flex-col">{body}</div>;
}

function Loading() {
  return <div className="flex items-center gap-2 px-4 py-6"><Spinner /><Text tone="muted">Loading…</Text></div>;
}

function BotChatView({ bot }: { bot: BotView }) {
  const dispatch = useDispatch<any>();
  const head = useGetUnifiedBotMessagesQuery({ limit: BOT_HISTORY_PAGE_SIZE });
  const [send] = useSendBotWebMessageMutation();
  const [known, setKnown] = useState<ReadonlyMap<string, UnifiedBotMessage>>(() => new Map());
  const [pending, setPending] = useState<PendingBotSend[]>([]);
  const [text, setText] = useState('');
  const [composerError, setComposerError] = useState('');
  const [older, setOlder] = useState<{ loading: boolean; error: string; pagesLoaded: number; endReached: boolean }>(
    { loading: false, error: '', pagesLoaded: 0, endReached: false });
  const listRef = useRef<HTMLDivElement | null>(null);
  const stick = useRef(true);
  const prependFrom = useRef<number | null>(null);
  const loadingOlder = useRef(false);

  // Every head refresh (initial load, bot_changed invalidation, own send) is folded
  // into the accumulated history rather than replacing it.
  useEffect(() => { setKnown((current) => mergeBotMessages(current, head.currentData?.messages)); }, [head.currentData]);

  const timeline = useMemo(() => botTimeline(known), [known]);
  const shownPending = useMemo(() => visiblePendingSends(pending, known), [pending, known]);
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
      prependFrom.current = listRef.current ? listRef.current.scrollHeight - listRef.current.scrollTop : null;
      setKnown((current) => mergeBotMessages(current, page.messages));
      setOlder((o) => ({ loading: false, error: '', pagesLoaded: o.pagesLoaded + 1, endReached: !page.next_cursor }));
    } catch (error) {
      setOlder((o) => ({ ...o, loading: false, error: botChatErrorText(queryErrorStatus(error), apiErrorText(error, 'Could not load older messages.')) }));
    } finally {
      loadingOlder.current = false;
    }
  }, [dispatch, hasOlder, timeline]);

  // Keep the reader's place when older rows are prepended; otherwise follow the
  // bottom while the reader is already there (or has just sent).
  useLayoutEffect(() => {
    const node = listRef.current;
    if (!node) return;
    if (prependFrom.current !== null) {
      node.scrollTop = node.scrollHeight - prependFrom.current;
      prependFrom.current = null;
    } else if (stick.current) {
      node.scrollTop = node.scrollHeight;
    }
  }, [timeline, shownPending]);

  const onScroll = () => {
    const node = listRef.current;
    if (!node) return;
    stick.current = node.scrollHeight - node.scrollTop - node.clientHeight < STICK_THRESHOLD;
    if (node.scrollTop < LOAD_OLDER_THRESHOLD && !older.error) void loadOlder();
  };

  const deliver = async (item: PendingBotSend) => {
    stick.current = true;
    setPending((rows) => [...rows.filter((row) => row.key !== item.key), { ...item, state: 'sending', error: '' }]);
    try {
      const result = await send({ text: item.text, idempotency_key: item.key }).unwrap();
      setPending((rows) => rows.map((row) => row.key === item.key ? { ...row, state: 'sent', message_id: result.message_id } : row));
    } catch (error) {
      const message = botChatErrorText(queryErrorStatus(error), apiErrorText(error, 'Your message was not sent.'));
      setPending((rows) => rows.map((row) => row.key === item.key ? { ...row, state: 'failed', error: message } : row));
    }
  };

  const submit = () => {
    const check = checkBotComposerText(text);
    if (check === 'too_long') { setComposerError('This message is too long. Shorten it and send again.'); return; }
    if (check) return;
    setComposerError('');
    setText('');
    void deliver({ key: newIdempotencyKey(), text, state: 'sending', message_id: '', error: '' });
  };

  const notice = botQueueNotice(bot.status, awaitingBotReply(timeline, shownPending));
  const headStatus = queryErrorStatus(head.error);
  const running = isBotRunning(bot.status);
  const sendFailure = shownPending.find((row) => row.state === 'failed');

  return <>
    <header data-debug-id="bot-chat-header" className="flex min-w-0 shrink-0 flex-wrap items-center gap-x-3 gap-y-1 border-b border-subtle px-4 py-3">
      <h1 data-debug-id="bot-chat-title" className="min-w-0 truncate text-base font-semibold text-primary">{bot.display_name}</h1>
      <StatusPill data-debug-id="bot-chat-status" tone={bot.status === 'ready' ? 'success' : bot.status === 'working' || bot.status === 'starting' ? 'pending' : bot.status === 'waiting_for_machine' ? 'warning' : 'neutral'}
        className="max-w-full whitespace-normal leading-normal">{resolveBotStatusLabel(bot.status)}</StatusPill>
      <span data-debug-id="bot-chat-channels" className="min-w-0 truncate text-xs text-muted">{running ? 'Running' : 'Stopped'} · {connectedBotChannels(bot).join(' · ')}</span>
    </header>
    <div ref={listRef} onScroll={onScroll} data-debug-id="bot-chat-list" role="log" aria-label={`Messages with ${bot.display_name}`}
      aria-busy={head.isLoading || older.loading} className="min-h-0 min-w-0 flex-1 overflow-y-auto overflow-x-hidden px-3 py-3 sm:px-4">
      {hasOlder || older.loading || older.error ? (
        <div className="flex flex-col items-center gap-1 pb-3">
          {older.error ? <p role="alert" data-debug-id="bot-chat-older-error" className="text-xs text-muted">{older.error}</p> : null}
          <Button type="button" variant="ghost" size="sm" data-debug-id="bot-chat-load-older" loading={older.loading}
            onClick={() => { setOlder((o) => ({ ...o, error: '' })); void loadOlder(); }}>
            {older.error ? 'Retry' : 'Load older messages'}
          </Button>
        </div>
      ) : null}
      {head.isLoading ? <Loading /> : null}
      {head.isError && !timeline.length ? (
        <div data-debug-id="bot-chat-history-error" className="min-w-0"><Alert tone="danger">{botChatErrorText(headStatus, apiErrorText(head.error, 'Could not load messages.'))}</Alert></div>
      ) : null}
      {!head.isLoading && !head.isError && !timeline.length && !shownPending.length ? (
        <p data-debug-id="bot-chat-empty" className="py-10 text-center text-sm text-muted">No messages yet. Say hello to {bot.display_name}.</p>
      ) : null}
      <ol className="flex min-w-0 flex-col gap-3">
        {timeline.map((message) => <BotMessageRow key={message.message_id} message={message} />)}
        {shownPending.map((row) => <PendingRow key={row.key} row={row} onRetry={() => void deliver(row)} />)}
      </ol>
    </div>
    <div className="shrink-0 space-y-2 border-t border-subtle px-3 py-3 sm:px-4">
      {notice ? <div data-debug-id="bot-chat-queue-notice" className="min-w-0"><Alert tone={notice.tone}>{notice.text}</Alert></div> : null}
      {bot.status_detail && BOT_STATUS_DETAILS[bot.status_detail] ? <Text tone="muted" data-debug-id="bot-chat-status-detail">{BOT_STATUS_DETAILS[bot.status_detail]}</Text> : null}
      {sendFailure ? <div data-debug-id="bot-chat-send-error" className="min-w-0"><Alert tone="danger">{sendFailure.error}</Alert></div> : null}
      {composerError ? <div data-debug-id="bot-chat-composer-error" className="min-w-0"><Alert tone="danger">{composerError}</Alert></div> : null}
      <form className="flex min-w-0 items-end gap-2" onSubmit={(event) => { event.preventDefault(); submit(); }}>
        <Textarea data-debug-id="bot-chat-input" aria-label={`Message ${bot.display_name}`} placeholder={`Message ${bot.display_name}…`}
          rows={1} width="full" value={text} onChange={(value) => { setText(value); if (composerError) setComposerError(''); }}
          onKeyDown={(event) => {
            if (event.key === 'Enter' && !event.shiftKey && !event.nativeEvent.isComposing) { event.preventDefault(); submit(); }
          }}
          className="max-h-40 min-h-11 min-w-0 flex-1 resize-none text-base sm:text-sm" />
        <Button type="submit" variant="primary" data-debug-id="bot-chat-send" disabled={!text.trim()} className="min-h-11 shrink-0">Send</Button>
      </form>
    </div>
  </>;
}

function ChannelBadge({ provider }: { provider: UnifiedBotMessage['provider'] }) {
  return <Badge data-debug-id="bot-chat-channel" tone={provider === 'web' ? 'neutral' : 'info'}>{BOT_CHANNEL_LABELS[provider] ?? provider}</Badge>;
}

function outboundStateText(state: string): string {
  if (!state || state === 'sent') return '';
  if (state === 'failed' || state === 'held') return 'Not delivered';
  return 'Sending…';
}

function BotMessageRow({ message }: { message: UnifiedBotMessage }) {
  const mine = message.direction === 'inbound';
  const state = mine ? (message.read_at ? '' : 'Queued') : outboundStateText(message.send_state);
  return (
    <li data-debug-id={`bot-chat-message-${message.message_id}`} data-direction={mine ? 'user' : 'bot'}
      className={`flex min-w-0 flex-col gap-1 ${mine ? 'items-end' : 'items-start'}`}>
      <div data-chat-body className={`min-w-0 max-w-[85%] break-words rounded-2xl px-3 py-2 text-sm sm:max-w-[75%] ${mine ? 'bg-accent-soft text-primary' : 'border border-subtle bg-surface text-primary'}`}>
        {message.body_purged ? <span className="italic text-muted">This message was removed by retention.</span>
          : mine ? <span className="whitespace-pre-wrap">{message.body}</span>
          : <MarkdownBody source={message.body} compact copyAll={false} />}
      </div>
      <div className="flex min-w-0 items-center gap-1.5 px-1 text-xs text-muted">
        <ChannelBadge provider={message.provider} />
        <time dateTime={message.created_at}>{formatBotMessageTime(message.created_at)}</time>
        {state ? <span data-debug-id="bot-chat-message-state">· {state}</span> : null}
      </div>
    </li>
  );
}

function PendingRow({ row, onRetry }: { row: PendingBotSend; onRetry: () => void }) {
  return (
    <li data-debug-id={`bot-chat-pending-${row.key}`} data-direction="user" data-state={row.state} className="flex min-w-0 flex-col items-end gap-1">
      <div data-chat-body className={`min-w-0 max-w-[85%] whitespace-pre-wrap break-words rounded-2xl bg-accent-soft px-3 py-2 text-sm text-primary sm:max-w-[75%] ${row.state === 'failed' ? 'opacity-70' : ''}`}>{row.text}</div>
      <div className="flex min-w-0 items-center gap-1.5 px-1 text-xs text-muted">
        <ChannelBadge provider="web" />
        {row.state === 'failed' ? <>
          <span className="text-danger">Not sent</span>
          <button type="button" data-debug-id="bot-chat-retry" onClick={onRetry} className="min-h-11 rounded-lg px-2 text-accent hover:bg-neutral-soft">Retry</button>
        </> : <span data-debug-id="bot-chat-message-state">{row.state === 'sending' ? 'Sending…' : 'Queued'}</span>}
      </div>
    </li>
  );
}
