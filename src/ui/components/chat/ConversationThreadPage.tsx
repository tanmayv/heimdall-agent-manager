import { type FormEvent, useEffect, useMemo, useState } from 'react';
import {
  useFetchConversationQuery,
  useFetchConversationMessagesQuery,
  useLazyFetchConversationMessagesQuery,
  useUpdateConversationTitleMutation,
  useSendConversationMessageMutation,
  useMarkConversationReadMutation,
} from '../../api/endpoints/chats';
import {
  useFetchAgentInstanceQuery,
  useReconfigureAgentInstanceMutation,
  useRestartAgentInstanceMutation,
  useStopAgentInstanceMutation,
} from '../../api/endpoints/agents';
import { useCreateArtifactMutation } from '../../api/endpoints/artifacts';
import {
  normalizeBridgeCapabilities,
  useListBridgesQuery,
  type BridgeCapability,
} from '../../api/endpoints/bridgeSupport';
import Markdown from '../Markdown';
import ChatMessageList from './ChatMessageList';
import type { ChatDeliveryStatus, ChatMessage, ChatTimestamp } from './types';

// e2e conversation thread for /conversations/{conversationId}. Cookie-auth,
// hub-native. Fetches messages via /api/v1/chats/{id}/messages, sends via POST,
// marks read, and (per the launch composer) exposes provider/tier selection for
// the bound instance — plus a Bridge indicator — so a live conversation can be
// reconfigured/restarted without leaving the page.

type Message = {
  message_id?: string;
  messageId?: string;
  id?: string;
  conversation_id?: string;
  conversationId?: string;
  direction?: string;
  body?: string;
  created_at?: string;
  createdAt?: string;
  created_unix_ms?: number | string;
  createdUnixMs?: number | string;
  delivered_unix_ms?: number | string;
  deliveredUnixMs?: number | string;
  read_unix_ms?: number | string;
  readUnixMs?: number | string;
  delivery_failed_unix_ms?: number | string;
  deliveryFailedUnixMs?: number | string;
  delivery_error?: string;
  deliveryError?: string;
  sender_agent_instance_id?: string;
  senderAgentInstanceId?: string;
  sending?: boolean;
};

const tierOrder = ['cheap', 'normal', 'smart'];

// RTK Query queryFn errors reject with `{ status: 'CUSTOM_ERROR', error: '...' }`
// (not an Error), so `err.message` is undefined and String(err) => "[object
// Object]". Extract the real message from every shape we produce.
function errMsg(err: any, fallback: string): string {
  if (!err) return fallback;
  if (typeof err === 'string') return err;
  return String(err.message || err.error || err.data?.error?.message || err.data?.message || fallback);
}

const EMPTY_TIMESTAMP: ChatTimestamp = { label: '', iso: '' };
const EMPTY_DELIVERY: ChatDeliveryStatus = { glyph: '', label: '', tone: '' };

function bridgeId(bridge: any): string { return String(bridge?.bridge_id || bridge?.bridgeId || bridge?.id || ''); }
function msgId(m: Message, i: number): string { return String(m.message_id || m.messageId || m.id || `idx-${i}`); }
function msgDir(m: Message): string { return String(m.direction || ''); }

function localMessageId(): string {
  return `local_${Date.now()}_${Math.random().toString(36).slice(2, 8)}`;
}

function optimisticUserMessage(conversationId: string, body: string): Message {
  return {
    message_id: localMessageId(),
    conversation_id: conversationId,
    direction: 'user_to_agent',
    body,
    created_unix_ms: Date.now(),
    sending: true,
  };
}

function sentMessageFromResult(result: any): Message | null {
  const candidate = result?.message || result?.chat_message || result?.chatMessage || result;
  if (!candidate || typeof candidate !== 'object') return null;
  const id = String(candidate.message_id || candidate.messageId || candidate.id || '');
  const body = String(candidate.body || '');
  if (!id && !body) return null;
  return { ...candidate, sending: false } as Message;
}

function failedLocalMessage(message: Message, error: string): Message {
  return {
    ...message,
    sending: false,
    delivery_failed_unix_ms: Date.now(),
    delivery_error: error,
  };
}

function capTiers(cap: BridgeCapability | undefined): string[] {
  if (!cap) return [];
  const t = Array.isArray(cap.tiers) ? cap.tiers.filter(Boolean) : [];
  return t.length ? t : (cap.defaultTier ? [cap.defaultTier] : []);
}

function coerceUnixMs(value: any): number {
  const parsed = Number(value ?? 0);
  if (!Number.isFinite(parsed) || parsed <= 0) return 0;
  return parsed < 1_000_000_000_000 ? parsed * 1000 : parsed;
}

function dateStringToUnixMs(value: any): number {
  const raw = String(value || '').trim();
  if (!raw) return 0;
  const parsed = Date.parse(raw);
  return Number.isFinite(parsed) ? parsed : 0;
}

function messageCreatedUnixMs(message: Message): number {
  return coerceUnixMs(message.created_unix_ms ?? message.createdUnixMs) || dateStringToUnixMs(message.created_at || message.createdAt);
}

function formatMessageTimestamp(unixMs: number): ChatTimestamp {
  if (!unixMs) return EMPTY_TIMESTAMP;
  const date = new Date(unixMs);
  if (Number.isNaN(date.getTime())) return EMPTY_TIMESTAMP;
  return { label: date.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' }), iso: date.toISOString() };
}

function runtimeNeedsStart(status: string): boolean {
  const normalized = String(status || '').toLowerCase();
  return !normalized || normalized === 'stopped' || normalized === 'failed' || normalized === 'unreachable' || normalized === 'idle';
}

function deliveryStatusFor(message: ChatMessage): ChatDeliveryStatus {
  if (!message.isUser) return EMPTY_DELIVERY;
  if (message.sending) return { glyph: '…', label: 'Sending', tone: 'text-zinc-500' };
  if (message.deliveryFailedUnixMs > 0) return { glyph: '!', label: message.deliveryError || 'Delivery failed', tone: 'text-red-300' };
  if (message.readUnixMs > 0) return { glyph: '✓✓', label: 'Read', tone: 'text-emerald-400' };
  if (message.deliveredUnixMs > 0) return { glyph: '✓', label: 'Delivered', tone: 'text-zinc-500' };
  return { glyph: '✓', label: 'Sent', tone: 'text-zinc-600' };
}

function normalizeConversationMessages(rows: Message[], agentLabel: string): ChatMessage[] {
  const seen = new Set<string>();
  return rows
    .map((message, index) => {
      const id = msgId(message, index);
      const direction = msgDir(message);
      const isUser = direction === 'user_to_agent';
      const createdUnixMs = messageCreatedUnixMs(message);
      const sender = String(message.sender_agent_instance_id || message.senderAgentInstanceId || '');
      const authorLabel = isUser ? 'you' : direction === 'system' ? 'system' : (sender || agentLabel || 'agent');
      let artifactIds: string[] | undefined = undefined;
      const artifactIdsJson = (message as any).artifact_ids_json;
      if (artifactIdsJson && typeof artifactIdsJson === 'string') {
        try {
          const parsed = JSON.parse(artifactIdsJson);
          if (Array.isArray(parsed)) artifactIds = parsed;
        } catch (e) {}
      }
      return {
        order: index,
        chatMessage: {
          key: id || `${direction}-${createdUnixMs}-${index}`,
          messageId: id,
          body: String(message.body || ''),
          isUser,
          createdUnixMs,
          deliveredUnixMs: coerceUnixMs(message.delivered_unix_ms ?? message.deliveredUnixMs),
          readUnixMs: coerceUnixMs(message.read_unix_ms ?? message.readUnixMs),
          deliveryFailedUnixMs: coerceUnixMs(message.delivery_failed_unix_ms ?? message.deliveryFailedUnixMs),
          deliveryError: String(message.delivery_error || message.deliveryError || ''),
          sending: Boolean(message.sending),
          authorLabel,
          artifactIds,
        } satisfies ChatMessage,
      };
    })
    .filter(({ chatMessage }) => {
      const key = chatMessage.messageId || chatMessage.key;
      if (seen.has(key)) return false;
      seen.add(key);
      return true;
    })
    .sort((left, right) => {
      const lt = left.chatMessage.createdUnixMs;
      const rt = right.chatMessage.createdUnixMs;
      if (lt && rt && lt !== rt) return lt - rt;
      return left.order - right.order;
    })
    .map(({ chatMessage }) => chatMessage);
}

export default function ConversationThreadPage({ conversationId }: { conversationId: string }) {
  const convQuery = useFetchConversationQuery({ conversationId }, { skip: !conversationId });
  const messagesQuery = useFetchConversationMessagesQuery({ conversationId }, { skip: !conversationId, pollingInterval: 4000, refetchOnMountOrArgChange: true });
  const [fetchOlderMessages, olderMessagesState] = useLazyFetchConversationMessagesQuery();
  const [updateConversationTitle, updateTitleState] = useUpdateConversationTitleMutation();
  const [sendMessage] = useSendConversationMessageMutation();
  const [markRead] = useMarkConversationReadMutation();
  const [reconfigureInstance] = useReconfigureAgentInstanceMutation();
  const [restartInstance, restartState] = useRestartAgentInstanceMutation();
  const [stopInstance, stopState] = useStopAgentInstanceMutation();
  const [createArtifact] = useCreateArtifactMutation();

  const conversation = convQuery.data?.conversation || null;
  const agentId = String(conversation?.agent_id || conversation?.agentId || '');
  const agentInstanceId = String(conversation?.agent_instance_id || conversation?.agentInstanceId || '');
  const chainId = String(conversation?.chain_id || conversation?.chainId || '');
  const title = String(conversation?.title || '').trim() || agentId || conversationId;
  const rawTitle = String(conversation?.title || '').trim();

  // The instance record is the source of truth for the CONCRETE provider / tier /
  // bridge this conversation runs on (never "default"/"Auto").
  const instanceQuery = useFetchAgentInstanceQuery({ instanceId: agentInstanceId }, { skip: !agentInstanceId, pollingInterval: 5000, refetchOnMountOrArgChange: true });
  const instance = instanceQuery.data?.instance || null;
  const instanceProvider = String(instance?.provider || '');
  const instanceTier = String(instance?.tier || '');
  const instanceBridgeId = String(instance?.bridge_id || instance?.bridgeId || '');
  const runtimeStatus = String(instance?.runtime_status || instance?.runtimeStatus || '');

  const bridgesQuery = useListBridgesQuery(undefined, { pollingInterval: 5000, refetchOnMountOrArgChange: true });
  const bridges = bridgesQuery.data?.bridges || [];
  const instanceBridge = useMemo(() => bridges.find((b: any) => bridgeId(b) === instanceBridgeId), [bridges, instanceBridgeId]);

  const baseMessages: Message[] = messagesQuery.data?.messages || [];
  const [olderMessages, setOlderMessages] = useState<Message[]>([]);
  const [olderCursor, setOlderCursor] = useState('');
  const [olderHasMore, setOlderHasMore] = useState(false);
  const [draft, setDraft] = useState('');
  const [error, setError] = useState('');
  const [attachments, setAttachments] = useState<{id: string, name: string}[]>([]);
  const [localMessages, setLocalMessages] = useState<Message[]>([]);
  const [provider, setProvider] = useState('');
  const [tier, setTier] = useState('');
  const [reconfigStatus, setReconfigStatus] = useState('');
  const [renaming, setRenaming] = useState(false);
  const [titleDraft, setTitleDraft] = useState('');
  const [titleError, setTitleError] = useState('');

  // Provider/tier selectable range is the instance Bridge's real capability
  // matrix; agent bridge-support provider/tier values are preferred defaults,
  // not allowlists.
  const caps = useMemo(() => normalizeBridgeCapabilities(instanceBridge), [instanceBridge]);

  const providerOptions = useMemo(() => {
    const list = caps.map((c) => c.provider).filter(Boolean);
    // Always include the instance's current provider so it is selectable/visible.
    if (instanceProvider && !list.includes(instanceProvider)) list.push(instanceProvider);
    return Array.from(new Set(list)).sort();
  }, [caps, instanceProvider]);
  const tierOptions = useMemo(() => {
    const selectedProvider = provider || instanceProvider || providerOptions[0] || '';
    const cap = caps.find((c) => c.provider === selectedProvider);
    const t = capTiers(cap);
    const ordered = tierOrder.filter((x) => t.includes(x)).concat(t.filter((x) => !tierOrder.includes(x)));
    if (instanceTier && !ordered.includes(instanceTier)) ordered.unshift(instanceTier);
    return ordered;
  }, [caps, provider, providerOptions, instanceProvider, instanceTier]);

  const chatMessages = useMemo(
    () => normalizeConversationMessages([...olderMessages, ...baseMessages, ...localMessages], agentId || agentInstanceId),
    [olderMessages, baseMessages, localMessages, agentId, agentInstanceId],
  );
  const needsStart = runtimeNeedsStart(runtimeStatus);
  const runtimeActionBusy = restartState.isLoading || stopState.isLoading;
  const runtimeButtonLabel = runtimeActionBusy ? (stopState.isLoading ? 'Stopping…' : (needsStart ? 'Starting…' : 'Restarting…')) : (needsStart ? 'Start' : 'Stop');

  useEffect(() => { if (!renaming) setTitleDraft(rawTitle || title); }, [rawTitle, title, renaming]);
  useEffect(() => { if (agentInstanceId && (conversation?.unread_count || conversation?.unreadCount)) void markRead({ conversationId }); }, [conversationId, agentInstanceId]);
  // Seed the selects from the instance's ACTUAL provider/tier (no empty/"default").
  useEffect(() => { if (instanceProvider) setProvider(instanceProvider); }, [instanceProvider]);
  useEffect(() => { if (instanceTier) setTier(instanceTier); }, [instanceTier]);
  useEffect(() => { setProvider((p) => (p && providerOptions.includes(p) ? p : (instanceProvider || providerOptions[0] || p))); }, [providerOptions.join('|')]);
  useEffect(() => { setTier((t) => (t && tierOptions.includes(t) ? t : (instanceTier || tierOptions[0] || t))); }, [tierOptions.join('|')]);
  useEffect(() => {
    setOlderMessages([]);
    setOlderCursor('');
    setOlderHasMore(false);
    setLocalMessages([]);
    setAttachments([]);
  }, [conversationId]);
  useEffect(() => {
    if (baseMessages.length === 0 || localMessages.length === 0) return;
    const serverIds = new Set(baseMessages.map((message, index) => msgId(message, index)));
    setLocalMessages((current) => current.filter((message, index) => {
      const id = msgId(message, index);
      return !id || id.startsWith('local_') || !serverIds.has(id);
    }));
  }, [baseMessages, localMessages.length]);
  useEffect(() => {
    if (olderMessages.length > 0) return;
    setOlderCursor(String(messagesQuery.data?.nextCursor || ''));
    setOlderHasMore(Boolean(messagesQuery.data?.hasMore));
  }, [messagesQuery.data?.nextCursor, messagesQuery.data?.hasMore, olderMessages.length]);

  // Apply & relaunch only matters when the selection differs from what the
  // instance currently runs; otherwise it's a no-op (use Restart instead).
  const effectiveProvider = provider || instanceProvider;
  const effectiveTier = tier || instanceTier;
  const selectionChangesConfig = Boolean(agentInstanceId) && ((effectiveProvider && effectiveProvider !== instanceProvider) || (effectiveTier && effectiveTier !== instanceTier));

  async function saveConversationTitle() {
    const next = titleDraft.trim();
    if (!next) { setTitleError('Title is required.'); return; }
    setTitleError('');
    try {
      await updateConversationTitle({ conversationId, title: next }).unwrap();
      setRenaming(false);
      void convQuery.refetch();
    } catch (err: any) {
      setTitleError(errMsg(err, 'Rename failed'));
    }
  }

  async function toggleRuntime() {
    if (!agentId || !agentInstanceId || runtimeActionBusy) return;
    setReconfigStatus(needsStart ? 'Starting…' : 'Stopping…');
    try {
      if (needsStart) await restartInstance({ agentId, instanceId: agentInstanceId }).unwrap();
      else await stopInstance({ agentId, instanceId: agentInstanceId }).unwrap();
      setReconfigStatus(needsStart ? 'Start requested.' : 'Stop requested.');
      void instanceQuery.refetch();
    } catch (err: any) {
      setReconfigStatus(errMsg(err, needsStart ? 'Start failed' : 'Stop failed'));
    }
  }

  async function loadOlderMessages() {
    if (!olderCursor || olderMessagesState.isFetching) return;
    setError('');
    try {
      const data = await fetchOlderMessages({ conversationId, limit: 100, cursor: olderCursor }).unwrap();
      const rows: Message[] = data?.messages || [];
      setOlderMessages((current) => {
        const seen = new Set(current.map((message, index) => msgId(message, index)));
        const next = [...current];
        rows.forEach((message, index) => {
          const id = msgId(message, current.length + index);
          if (seen.has(id)) return;
          seen.add(id);
          next.push(message);
        });
        return next;
      });
      setOlderCursor(String(data?.nextCursor || ''));
      setOlderHasMore(Boolean(data?.hasMore));
    } catch (err: any) {
      setError(errMsg(err, 'Could not load older messages'));
    }
  }

  async function submit(event: FormEvent) {
    event.preventDefault();
    const body = draft.trim();
    if (!body && attachments.length === 0) return;
    const local = optimisticUserMessage(conversationId, body || 'Uploaded file');
    const localId = msgId(local, 0);
    const attachmentIds = attachments.map(a => a.id);
    (local as any).artifact_ids_json = JSON.stringify(attachmentIds);
    setError('');
    setDraft('');
    setAttachments([]);
    setLocalMessages((current) => [...current, local]);
    try {
      const result = await sendMessage({ conversationId, body, artifactIds: attachmentIds }).unwrap();
      const sent = sentMessageFromResult(result);
      setLocalMessages((current) => current.map((message) => {
        if (msgId(message, 0) !== localId) return message;
        return sent ? { ...sent, body: String(sent.body || body), direction: sent.direction || 'user_to_agent', artifact_ids_json: (sent as any).artifact_ids_json || JSON.stringify(attachmentIds) } : { ...message, sending: false };
      }));
      void messagesQuery.refetch();
    } catch (err: any) {
      const message = errMsg(err, 'Send failed');
      setLocalMessages((current) => current.map((item) => (msgId(item, 0) === localId ? failedLocalMessage(item, message) : item)));
    }
  }

  async function applyReconfigure() {
    if (!agentInstanceId) return;
    const nextProvider = provider || providerOptions[0] || '';
    const nextTier = tier || tierOptions[0] || '';
    if (!nextProvider || !nextTier) { setReconfigStatus('Choose a provider and tier first.'); return; }
    setReconfigStatus('Reconfiguring…');
    try {
      await reconfigureInstance({ agentId, instanceId: agentInstanceId, provider: nextProvider, tier: nextTier }).unwrap();
      setReconfigStatus(`Applied ${nextProvider}/${nextTier} — relaunching…`);
      void instanceQuery.refetch();
      void messagesQuery.refetch();
    } catch (err: any) {
      setReconfigStatus(errMsg(err, 'Reconfigure failed'));
    }
  }

  async function doRestart() {
    if (!agentInstanceId) return;
    setReconfigStatus('Restarting…');
    try {
      await restartInstance({ agentId, instanceId: agentInstanceId }).unwrap();
      setReconfigStatus('Restart requested.');
      void messagesQuery.refetch();
    } catch (err: any) {
      setReconfigStatus(errMsg(err, 'Restart failed'));
    }
  }

  if (!conversation && !convQuery.isFetching) {
    return (
      <section data-debug-id="conversation-thread-page" className="w-full max-w-4xl rounded-[2rem] border border-white/10 bg-white/[0.04] p-6 text-left">
        <h2 className="text-xl font-semibold text-white">Conversation not found</h2>
        <p className="mt-2 text-sm text-zinc-400">No conversation with id <span className="font-mono">{conversationId}</span> for this user.</p>
        <a data-debug-id="conversation-thread-back-btn" href="#/conversations/new" className="mt-4 inline-flex rounded-2xl bg-sky-400 px-4 py-2 text-sm font-bold text-black hover:bg-sky-300">Start a new conversation</a>
      </section>
    );
  }

  return (
    <section data-debug-id="conversation-thread-page" className="flex h-full min-h-0 w-full flex-col bg-[#090909] p-0 text-left">
      <header data-debug-id="conversation-thread-header" className="flex shrink-0 items-center justify-between gap-2 border-b border-white/10 px-3 py-2 sm:px-4">
        <div className="min-w-0 flex-1">
          {renaming ? (
            <div className="flex min-w-0 items-center gap-2">
              <input
                data-debug-id="conversation-thread-title-input"
                value={titleDraft}
                onChange={(event) => { setTitleDraft(event.target.value); setTitleError(''); }}
                onKeyDown={(event) => {
                  if (event.key === 'Enter') { event.preventDefault(); void saveConversationTitle(); }
                  if (event.key === 'Escape') { setRenaming(false); setTitleError(''); setTitleDraft(rawTitle || title); }
                }}
                className="min-h-9 min-w-0 flex-1 rounded-xl border border-white/10 bg-black/30 px-3 py-1.5 text-sm font-semibold text-white outline-none focus:border-sky-400/60"
                autoFocus
              />
              <button type="button" data-debug-id="conversation-thread-title-save-btn" onClick={() => void saveConversationTitle()} disabled={updateTitleState.isLoading || !titleDraft.trim()} className="rounded-xl bg-sky-400 px-3 py-1.5 text-xs font-bold text-black hover:bg-sky-300 disabled:opacity-50">Save</button>
              <button type="button" data-debug-id="conversation-thread-title-cancel-btn" onClick={() => { setRenaming(false); setTitleError(''); setTitleDraft(rawTitle || title); }} className="rounded-xl border border-white/10 bg-white/5 px-2.5 py-1.5 text-xs text-zinc-300 hover:bg-white/10">Cancel</button>
            </div>
          ) : (
            <div className="flex min-w-0 items-center gap-2">
              <h2 data-debug-id="conversation-thread-title" className="truncate text-base font-semibold text-white sm:text-lg">{title}</h2>
              <button type="button" data-debug-id="conversation-thread-title-edit-btn" onClick={() => { setTitleDraft(rawTitle || title); setRenaming(true); setTitleError(''); }} className="rounded-lg border border-white/10 bg-white/5 px-2 py-1 text-[11px] text-zinc-300 hover:bg-white/10">Rename</button>
            </div>
          )}
          {titleError ? <div data-debug-id="conversation-thread-title-error" className="mt-1 text-[11px] text-red-300">{titleError}</div> : null}
          <div className="mt-0.5 hidden flex-wrap gap-2 text-[11px] text-zinc-500 sm:flex">
            <span data-debug-id="conversation-thread-agent">agent: {agentId || '—'}</span>
            <span data-debug-id="conversation-thread-instance">instance: {agentInstanceId || '—'}</span>
            <span data-debug-id="conversation-thread-bridge">bridge: {instanceBridge?.label || instanceBridge?.machine_hostname || instanceBridgeId || '—'}</span>
            <span data-debug-id="conversation-thread-provider">provider: {instanceProvider || '—'}</span>
            <span data-debug-id="conversation-thread-tier">tier: {instanceTier || '—'}</span>
            <span data-debug-id="conversation-thread-status">{runtimeStatus || '—'}</span>
            {chainId ? <span>chain: {chainId}</span> : null}
          </div>
        </div>
        <div className="flex shrink-0 items-center gap-2">
          <button type="button" data-debug-id={needsStart ? 'conversation-thread-start-btn' : 'conversation-thread-stop-btn'} onClick={() => void toggleRuntime()} disabled={!agentInstanceId || runtimeActionBusy} className={needsStart ? 'rounded-xl bg-emerald-400 px-3 py-1.5 text-xs font-bold text-black hover:bg-emerald-300 disabled:cursor-not-allowed disabled:opacity-50' : 'rounded-xl border border-red-400/30 bg-red-400/10 px-3 py-1.5 text-xs font-bold text-red-100 hover:bg-red-400/20 disabled:cursor-not-allowed disabled:opacity-50'}>{runtimeButtonLabel}</button>
          <button type="button" data-debug-id="conversation-thread-refresh-btn" onClick={() => void messagesQuery.refetch()} className="rounded-xl border border-white/10 bg-white/5 px-3 py-1.5 text-xs text-zinc-200 hover:bg-white/10">Refresh</button>
        </div>
      </header>

      <div data-debug-id="conversation-thread-transcript" className="min-h-0 flex-1 px-2 py-2 sm:px-4 sm:py-3">
        <ChatMessageList
          conversationKey={conversationId}
          messages={chatMessages}
          debugPrefix="conversation-thread"
          hasMore={olderHasMore && Boolean(olderCursor)}
          loadingOlder={olderMessagesState.isFetching}
          onLoadOlder={loadOlderMessages}
          formatTimestamp={formatMessageTimestamp}
          getDeliveryStatus={deliveryStatusFor}
          renderMessageBody={({ message }) => (
            <div className="flex flex-col gap-1">
              <Markdown source={message.body} compact copyAll={false} />
              {message.artifactIds && message.artifactIds.length > 0 && (
                <div className="mt-1 flex flex-wrap gap-2">
                  {message.artifactIds.map(id => (
                    <a key={id} href={`#/library/artifacts/${encodeURIComponent(id)}`} className="flex items-center gap-1 rounded bg-sky-400/10 px-2 py-1 text-[11px] text-sky-300 hover:bg-sky-400/20">
                      <span className="opacity-70">▣</span> {id}
                    </a>
                  ))}
                </div>
              )}
            </div>
          )}
          wrapperClassName="relative h-full min-h-0 overflow-hidden"
          scrollClassName="chat-scrollbar h-full min-h-0 space-y-3 overflow-y-auto rounded-none bg-[#090909] px-1 py-2 sm:space-y-4 sm:rounded-[18px] sm:px-4 sm:py-4"
          emptyState={messagesQuery.isFetching ? (
            <div data-debug-id="conversation-thread-empty-state" className="grid h-full min-h-[220px] place-items-center rounded-2xl border border-dashed border-white/10 p-6 text-sm text-zinc-500">Loading messages…</div>
          ) : (
            <div data-debug-id="conversation-thread-empty-state" className="grid h-full min-h-[220px] place-items-center rounded-2xl border border-dashed border-white/10 p-6 text-sm text-zinc-500">No messages yet. Say something below.</div>
          )}
        />
      </div>

      <fieldset data-debug-id="conversation-thread-runtime-controls" className="hidden shrink-0 border-t border-white/10 px-3 py-1.5 sm:block sm:px-4 sm:py-2">
        <div className="flex flex-wrap items-end gap-2">
          <label className="text-[11px] text-zinc-500">Provider
            <select data-debug-id="conversation-provider-select" value={provider} onChange={(e) => setProvider(e.target.value)} className="ml-2 rounded-lg border border-white/10 bg-black/30 px-2 py-1 text-xs text-white">
              {providerOptions.map((p) => <option key={p} value={p}>{p}</option>)}
            </select>
          </label>
          <label className="text-[11px] text-zinc-500">Tier
            <select data-debug-id="conversation-tier-select" value={tier} onChange={(e) => setTier(e.target.value)} className="ml-2 rounded-lg border border-white/10 bg-black/30 px-2 py-1 text-xs text-white">
              {tierOptions.map((t) => <option key={t} value={t}>{t}</option>)}
            </select>
          </label>
          <button type="button" data-debug-id="conversation-reconfigure-btn" onClick={() => void applyReconfigure()} disabled={!selectionChangesConfig} title={selectionChangesConfig ? 'Save the selected provider/tier and relaunch' : 'Selection matches the current config'} className="rounded-lg border border-sky-400/30 bg-sky-400/10 px-3 py-1 text-xs text-sky-100 hover:bg-sky-400/20 disabled:cursor-not-allowed disabled:opacity-40">Apply &amp; relaunch</button>
          <button type="button" data-debug-id="conversation-restart-btn" onClick={() => void doRestart()} title="Relaunch the process with its current provider/tier (does not use the dropdowns)" className="rounded-lg border border-white/10 bg-white/5 px-3 py-1 text-xs text-zinc-200 hover:bg-white/10">Restart (current config)</button>
          {reconfigStatus ? <span data-debug-id="conversation-reconfigure-status" className="text-[11px] text-zinc-400">{reconfigStatus}</span> : null}
        </div>
        <p data-debug-id="conversation-runtime-hint" className="mt-1 hidden text-[10px] text-zinc-600 md:block">The provider/tier dropdowns only take effect on <span className="text-zinc-400">Apply &amp; relaunch</span>. <span className="text-zinc-400">Restart (current config)</span> relaunches as-is — use it to recover an idle/unreachable instance without changing settings.</p>
      </fieldset>

      <form onSubmit={submit} data-debug-id="conversation-composer-shell" className="shrink-0 border-t border-white/10 px-2 py-2 sm:px-4 sm:py-3">
        {error ? <div data-debug-id="conversation-composer-send-error" className="mb-2 rounded-xl border border-red-400/20 bg-red-400/10 px-3 py-2 text-xs text-red-100">{error}</div> : null}
        {attachments.length > 0 && (
          <div className="mb-2 flex flex-wrap gap-2">
            {attachments.map((a, i) => (
              <div key={i} className="flex items-center gap-1 rounded-lg bg-sky-400/10 px-2 py-1 text-xs text-sky-300" title={a.name}>
                <span className="max-w-[150px] truncate">{a.name}</span>
                <button type="button" onClick={() => setAttachments(prev => prev.filter((_, idx) => idx !== i))} className="hover:text-sky-100">×</button>
              </div>
            ))}
          </div>
        )}
        <div className="flex items-end gap-2">
          <label data-debug-id="conversation-attach-btn" className="grid h-[44px] w-[44px] shrink-0 cursor-pointer place-items-center rounded-2xl border border-white/10 bg-black/30 text-xl text-zinc-400 hover:bg-white/5 hover:text-white" title="Upload Attachment">
            <input data-debug-id="conversation-attach-input" type="file" className="hidden" onChange={async (e) => {
              const file = e.target.files?.[0];
              if (!file) return;
              try {
                const res = await createArtifact({
                  file,
                  name: file.name,
                  mime: file.type || 'application/octet-stream',
                  kind: (file.type || '').startsWith('image/') ? 'image' : 'text',
                  originKind: 'conversation_chat',
                  originRef: conversationId,
                }).unwrap();
                const artifact = res?.artifact || res;
                const id = artifact?.artifact_id || artifact?.artifactId || artifact?.id;
                if (id) {
                  setAttachments(prev => [...prev, { id, name: file.name }]);
                } else {
                  setError('Upload failed: Hub did not return an artifact id.');
                }
              } catch (err: any) {
                setError(errMsg(err, 'Failed to upload attachment'));
              } finally {
                e.target.value = '';
              }
            }} />
            ＋
          </label>
          <textarea
            data-debug-id="conversation-composer-input"
            value={draft}
            onChange={(e) => setDraft(e.target.value)}
            onKeyDown={(e) => { if (e.key === 'Enter' && (e.metaKey || e.ctrlKey)) { e.preventDefault(); void submit(e as any); } }}
            rows={2}
            placeholder="Message the agent… (Cmd/Ctrl+Enter to send)"
            className="min-h-[44px] flex-1 resize-none rounded-2xl border border-white/10 bg-black/30 px-3 py-2 text-sm text-white outline-none placeholder:text-zinc-600 focus:border-sky-400/60 sm:px-4"
          />
          <button data-debug-id="conversation-composer-send-btn" type="submit" disabled={!draft.trim() && attachments.length === 0} className="rounded-2xl bg-sky-400 px-4 py-2.5 text-sm font-black text-black hover:bg-sky-300 disabled:cursor-not-allowed disabled:bg-zinc-700 disabled:text-zinc-400">Send</button>
        </div>
      </form>
    </section>
  );
}
