import TaskChainOverview from '../taskchain/TaskChainOverview';
import { type ClipboardEvent, type FormEvent, useEffect, useMemo, useRef, useState } from 'react';
import {
  useFetchConversationQuery,
  useFetchConversationMessagesQuery,
  useLazyFetchConversationMessagesQuery,
  useUpdateConversationTitleMutation,
  useRequestPaneCaptureMutation,
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
import { ArtifactAttachmentPreview } from '../ArtifactAttachmentPreview';
import {
  normalizeBridgeCapabilities,
  useListBridgesQuery,
  type BridgeCapability,
} from '../../api/endpoints/bridgeSupport';
import { MAX_UPLOAD_BYTES } from '../ArtifactUpload';
import Markdown from '../Markdown';
import ChatMessageList from './ChatMessageList';
import { useViewport } from '../shell/responsive';
import { artifactKindForFile, artifactLinkFromResponse, artifactMimeForFile, artifactUploadName, clipboardFilesFromEvent } from '../../utils/artifactUpload';
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
  artifact_ids?: string[];
  artifactIds?: string[];
  artifact_ids_json?: string;
  artifactIdsJson?: string;
  message_type?: string;
  messageType?: string;
  message_status?: string;
  messageStatus?: string;
  metadata?: any;
  metadata_json?: string;
  metadataJson?: string;
  sending?: boolean;
};

type PendingAttachment = {
  localId: string;
  id: string;
  name: string;
  file: File;
  status: 'uploading' | 'uploaded' | 'error';
  error: string;
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

function extractMessageArtifactIds(message: Message): string[] | undefined {
  const seen = new Set<string>();
  const out: string[] = [];
  const push = (value: any) => {
    const raw = typeof value === 'object' && value !== null
      ? String(value.artifact_id || value.artifactId || value.id || '')
      : String(value || '');
    const id = raw.replace(/^artifact:\/\//i, '').trim();
    if (!id || seen.has(id)) return;
    seen.add(id);
    out.push(id);
  };

  const direct = (message as any).artifact_ids ?? (message as any).artifactIds;
  if (Array.isArray(direct)) direct.forEach(push);

  const artifactIdsJson = (message as any).artifact_ids_json ?? (message as any).artifactIdsJson;
  if (typeof artifactIdsJson === 'string' && artifactIdsJson.trim()) {
    try {
      const parsed = JSON.parse(artifactIdsJson);
      if (Array.isArray(parsed)) parsed.forEach(push);
    } catch (e) {}
  } else if (Array.isArray(artifactIdsJson)) {
    artifactIdsJson.forEach(push);
  }

  const body = String(message.body || '');
  const artifactLinkPattern = /artifact:\/\/([A-Za-z0-9._:-]+)/g;
  let match: RegExpExecArray | null;
  while ((match = artifactLinkPattern.exec(body)) !== null) push(match[1]);

  return out.length ? out : undefined;
}

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

function optimisticPaneCaptureMessage(conversationId: string, requestId: string, agentInstanceId: string): Message {
  return {
    message_id: `local_${requestId}`,
    conversation_id: conversationId,
    direction: 'agent_to_user',
    body: 'Requesting pane capture...',
    message_type: 'pane_capture',
    message_status: 'pending',
    metadata: { pane_capture_request_id: requestId, agent_instance_id: agentInstanceId, width: 80, line_limit: 120 },
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

function failedPaneCaptureMessage(message: Message, error: string): Message {
  return {
    ...message,
    sending: false,
    body: error,
    message_status: 'failed',
    messageStatus: 'failed',
    metadata: { ...((message as any).metadata || {}), error_code: 'request_failed' },
  };
}

function PaneCaptureOutput({ body, messageId }: { body: string; messageId: string }) {
  const preRef = useRef<HTMLPreElement | null>(null);

  useEffect(() => {
    const node = preRef.current;
    if (!node) return;
    const scrollToBottom = () => {
      node.scrollTop = node.scrollHeight;
    };
    scrollToBottom();
    const frame = typeof window !== 'undefined' ? window.requestAnimationFrame(scrollToBottom) : 0;
    return () => {
      if (frame && typeof window !== 'undefined') window.cancelAnimationFrame(frame);
    };
  }, [body, messageId]);

  return <pre ref={preRef} data-debug-id={`conversation-pane-capture-pre-${messageId}`} className="chat-scrollbar max-h-[420px] max-w-full overflow-auto whitespace-pre-wrap rounded-xl bg-black/30 p-3 font-mono text-xs leading-5 text-zinc-100">{body}</pre>;
}

function parseMessageMetadata(message: Message): any {
  const raw = (message as any).metadata ?? (message as any).metadata_json ?? (message as any).metadataJson;
  if (!raw) return {};
  if (typeof raw === 'object') return raw;
  try { return JSON.parse(String(raw)); } catch (_err) { return {}; }
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

function looksLikeInternalId(value: string): boolean {
  return /^(agt|inst|chat|conv|usr|brg|task|chain|proj|art)_[a-z0-9]/i.test(String(value || '').trim());
}

function conversationAgentLabel(conversation: any): string {
  const candidates = [conversation?.agent_name, conversation?.agentName, conversation?.agent_display_name, conversation?.agentDisplayName, conversation?.agent_slug, conversation?.agentSlug];
  for (const value of candidates) {
    const trimmed = String(value || '').trim();
    if (trimmed && !looksLikeInternalId(trimmed)) return trimmed;
  }
  return '';
}

function conversationDisplayTitle(conversation: any, agentId: string, agentInstanceId: string, conversationId: string): string {
  const rawTitle = String(conversation?.title || '').trim();
  const agentLabel = conversationAgentLabel(conversation);
  if (!rawTitle || rawTitle === agentId || rawTitle === agentInstanceId || rawTitle === conversationId || looksLikeInternalId(rawTitle)) {
    return agentLabel || agentId || conversationId;
  }
  return rawTitle;
}

function runtimeNeedsStart(status: string): boolean {
  const normalized = String(status || '').toLowerCase();
  // `idle` is a live Bridge runtime state: the wrapper is connected and ready,
  // just not currently busy. Show Stop for idle/running/busy instances so users
  // can stop the real process instead of accidentally relaunching it.
  return !normalized || normalized === 'stopped' || normalized === 'failed' || normalized === 'unreachable';
}

function runtimeIsStopping(status: string): boolean {
  return String(status || '').toLowerCase() === 'stopping';
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
      const artifactIds = extractMessageArtifactIds(message);
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
          messageType: String((message as any).message_type || (message as any).messageType || 'text'),
          messageStatus: String((message as any).message_status || (message as any).messageStatus || 'complete'),
          metadata: parseMessageMetadata(message),
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
  const messagesQuery = useFetchConversationMessagesQuery({ conversationId }, { skip: !conversationId, pollingInterval: 120000, refetchOnMountOrArgChange: true });
  const [fetchOlderMessages, olderMessagesState] = useLazyFetchConversationMessagesQuery();
  const [updateConversationTitle, updateTitleState] = useUpdateConversationTitleMutation();
  const [requestPaneCapture, requestPaneCaptureState] = useRequestPaneCaptureMutation();
  const [sendMessage] = useSendConversationMessageMutation();
  const [markRead] = useMarkConversationReadMutation();
  const [reconfigureInstance, reconfigureState] = useReconfigureAgentInstanceMutation();
  const [restartInstance, restartState] = useRestartAgentInstanceMutation();
  const [stopInstance, stopState] = useStopAgentInstanceMutation();
  const [createArtifact] = useCreateArtifactMutation();

  const conversation = convQuery.data?.conversation || null;
  const agentId = String(conversation?.agent_id || conversation?.agentId || '');
  const agentInstanceId = String(conversation?.agent_instance_id || conversation?.agentInstanceId || '');
  const chainId = String(conversation?.chain_id || conversation?.chainId || '');
  const title = conversationDisplayTitle(conversation, agentId, agentInstanceId, conversationId);
  const rawTitle = String(conversation?.title || '').trim();
  const editableTitle = rawTitle && !looksLikeInternalId(rawTitle) ? rawTitle : title;

  // The instance record is the source of truth for the CONCRETE provider / tier /
  // bridge this conversation runs on (never "default"/"Auto").
  const instanceQuery = useFetchAgentInstanceQuery({ instanceId: agentInstanceId }, { skip: !agentInstanceId, pollingInterval: 120000, refetchOnMountOrArgChange: true });
  const instance = instanceQuery.data?.instance || null;
  const instanceProvider = String(instance?.provider || '');
  const instanceTier = String(instance?.tier || '');
  const instanceBridgeId = String(instance?.bridge_id || instance?.bridgeId || '');
  const conversationRuntimeStatus = String(conversation?.runtime_status || conversation?.runtimeStatus || '');
  const runtimeStatus = String(instance?.runtime_status || instance?.runtimeStatus || conversationRuntimeStatus || '');

  const bridgesQuery = useListBridgesQuery(undefined, { pollingInterval: 120000, refetchOnMountOrArgChange: true });
  const bridges = bridgesQuery.data?.bridges || [];
  const instanceBridge = useMemo(() => bridges.find((b: any) => bridgeId(b) === instanceBridgeId), [bridges, instanceBridgeId]);

  const baseMessages: Message[] = messagesQuery.data?.messages || [];
  const [olderMessages, setOlderMessages] = useState<Message[]>([]);
  const [olderCursor, setOlderCursor] = useState('');
  const [olderHasMore, setOlderHasMore] = useState(false);
  const [draft, setDraft] = useState('');
  const [error, setError] = useState('');
  const [attachments, setAttachments] = useState<PendingAttachment[]>([]);
  const [localMessages, setLocalMessages] = useState<Message[]>([]);
  const [provider, setProvider] = useState('');
  const [tier, setTier] = useState('');
  const [reconfigStatus, setReconfigStatus] = useState('');
  const [taskChainOpen, setTaskChainOpen] = useState(false);
  const [runtimeMenuOpen, setRuntimeMenuOpen] = useState(false);
  const [headerActionsOpen, setHeaderActionsOpen] = useState(false);
  const [composerActionsOpen, setComposerActionsOpen] = useState(false);
  const runtimeMenuRef = useRef<HTMLDivElement | null>(null);
  const runtimeMenuButtonRef = useRef<HTMLButtonElement | null>(null);
  const headerActionsRef = useRef<HTMLDivElement | null>(null);
  const headerActionsButtonRef = useRef<HTMLButtonElement | null>(null);
  const composerActionsRef = useRef<HTMLDivElement | null>(null);
  const composerActionsButtonRef = useRef<HTMLButtonElement | null>(null);
  const fileInputRef = useRef<HTMLInputElement | null>(null);
  const viewport = useViewport();
  const isMobile = viewport === 'mobile';
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
  const runtimeStopping = runtimeIsStopping(runtimeStatus);
  const runtimeActionBusy = reconfigureState.isLoading || restartState.isLoading || stopState.isLoading;
  const runtimeButtonLabel = runtimeActionBusy ? (stopState.isLoading ? 'Stopping…' : (needsStart ? 'Starting…' : 'Restarting…')) : (runtimeStopping ? 'Stopping…' : needsStart ? 'Start' : 'Stop');
  const runtimeButtonIcon = runtimeActionBusy || runtimeStopping ? '…' : needsStart ? '▶' : '■';
  const bridgeLabel = String(instanceBridge?.label || instanceBridge?.machine_hostname || instanceBridgeId || '');
  const runtimeConfigLabel = [instanceProvider, instanceTier].filter(Boolean).join(' / ');
  const hasUploadingAttachments = attachments.some((item) => item.status === 'uploading');
  const hasFailedAttachments = attachments.some((item) => item.status === 'error');
  const uploadedAttachments = attachments.filter((item) => item.status === 'uploaded' && item.id);
  const sendDisabled = hasUploadingAttachments || hasFailedAttachments || (!draft.trim() && uploadedAttachments.length === 0);
  const pendingPaneCapture = chatMessages.some((message) => message.messageType === 'pane_capture' && message.messageStatus === 'pending');
  const paneCaptureDisabled = !agentInstanceId || needsStart || runtimeStopping || pendingPaneCapture || requestPaneCaptureState.isLoading;

  useEffect(() => { if (!renaming) setTitleDraft(editableTitle); }, [editableTitle, renaming]);
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
  useEffect(() => {
    if (!runtimeMenuOpen) return;
    const isInsideRuntimeMenu = (target: EventTarget | null) => {
      const node = target as Node | null;
      return Boolean(node && (runtimeMenuRef.current?.contains(node) || runtimeMenuButtonRef.current?.contains(node)));
    };
    const onPointerDown = (event: MouseEvent | TouchEvent) => {
      if (!isInsideRuntimeMenu(event.target)) setRuntimeMenuOpen(false);
    };
    const onFocusIn = (event: FocusEvent) => {
      if (!isInsideRuntimeMenu(event.target)) setRuntimeMenuOpen(false);
    };
    const onKeyDown = (event: KeyboardEvent) => {
      if (event.key === 'Escape') setRuntimeMenuOpen(false);
    };
    document.addEventListener('mousedown', onPointerDown);
    document.addEventListener('touchstart', onPointerDown, { passive: true });
    document.addEventListener('focusin', onFocusIn);
    document.addEventListener('keydown', onKeyDown);
    return () => {
      document.removeEventListener('mousedown', onPointerDown);
      document.removeEventListener('touchstart', onPointerDown);
      document.removeEventListener('focusin', onFocusIn);
      document.removeEventListener('keydown', onKeyDown);
    };
  }, [runtimeMenuOpen]);

  useEffect(() => {
    if (!headerActionsOpen) return;
    const isInsideHeaderActions = (target: EventTarget | null) => {
      const node = target as Node | null;
      return Boolean(node && (headerActionsRef.current?.contains(node) || headerActionsButtonRef.current?.contains(node)));
    };
    const onPointerDown = (event: MouseEvent | TouchEvent) => {
      if (!isInsideHeaderActions(event.target)) setHeaderActionsOpen(false);
    };
    const onFocusIn = (event: FocusEvent) => {
      if (!isInsideHeaderActions(event.target)) setHeaderActionsOpen(false);
    };
    const onKeyDown = (event: KeyboardEvent) => {
      if (event.key === 'Escape') setHeaderActionsOpen(false);
    };
    document.addEventListener('mousedown', onPointerDown);
    document.addEventListener('touchstart', onPointerDown, { passive: true });
    document.addEventListener('focusin', onFocusIn);
    document.addEventListener('keydown', onKeyDown);
    return () => {
      document.removeEventListener('mousedown', onPointerDown);
      document.removeEventListener('touchstart', onPointerDown);
      document.removeEventListener('focusin', onFocusIn);
      document.removeEventListener('keydown', onKeyDown);
    };
  }, [headerActionsOpen]);

  useEffect(() => {
    if (!composerActionsOpen) return;
    const isInsideComposerActions = (target: EventTarget | null) => {
      const node = target as Node | null;
      return Boolean(node && (composerActionsRef.current?.contains(node) || composerActionsButtonRef.current?.contains(node)));
    };
    const onPointerDown = (event: MouseEvent | TouchEvent) => {
      if (!isInsideComposerActions(event.target)) setComposerActionsOpen(false);
    };
    const onFocusIn = (event: FocusEvent) => {
      if (!isInsideComposerActions(event.target)) setComposerActionsOpen(false);
    };
    const onKeyDown = (event: KeyboardEvent) => {
      if (event.key === 'Escape') setComposerActionsOpen(false);
    };
    document.addEventListener('mousedown', onPointerDown);
    document.addEventListener('touchstart', onPointerDown, { passive: true });
    document.addEventListener('focusin', onFocusIn);
    document.addEventListener('keydown', onKeyDown);
    return () => {
      document.removeEventListener('mousedown', onPointerDown);
      document.removeEventListener('touchstart', onPointerDown);
      document.removeEventListener('focusin', onFocusIn);
      document.removeEventListener('keydown', onKeyDown);
    };
  }, [composerActionsOpen]);

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

  async function uploadAttachment(file: File, existingLocalId = '') {
    const localId = existingLocalId || `att_${Date.now()}_${Math.random().toString(36).slice(2, 8)}`;
    const name = artifactUploadName(file, 'conversation-attachment');
    const tooLarge = file.size > MAX_UPLOAD_BYTES;
    setError('');
    setAttachments((current) => {
      const without = current.filter((item) => item.localId !== localId);
      return [...without, { localId, id: '', name, file, status: tooLarge ? 'error' : 'uploading', error: tooLarge ? `File is too large. Maximum upload size is ${Math.round(MAX_UPLOAD_BYTES / (1024 * 1024))} MB.` : '' }];
    });
    if (tooLarge) return;
    try {
      const res = await createArtifact({
        file,
        name,
        mime: artifactMimeForFile(file),
        kind: artifactKindForFile(file),
        originKind: 'conversation_chat',
        originRef: conversationId,
      }).unwrap();
      const link = artifactLinkFromResponse(res);
      const id = link.replace(/^artifact:\/\//i, '');
      if (!id) throw new Error('Upload failed: Hub did not return an artifact id.');
      setAttachments((current) => current.map((item) => item.localId === localId ? { ...item, id, status: 'uploaded', error: '' } : item));
    } catch (err: any) {
      setAttachments((current) => current.map((item) => item.localId === localId ? { ...item, status: 'error', error: errMsg(err, 'Upload failed') } : item));
    }
  }

  function handleAttachmentInput(event: any) {
    const files = Array.from(event.target.files || []) as File[];
    event.target.value = '';
    files.forEach((file) => void uploadAttachment(file));
  }

  function openAttachmentPicker() {
    setComposerActionsOpen(false);
    fileInputRef.current?.click();
  }

  function handleComposerPaste(event: ClipboardEvent<HTMLTextAreaElement>) {
    const files = clipboardFilesFromEvent(event);
    if (files.length === 0) return;
    event.preventDefault();
    files.forEach((file) => void uploadAttachment(file));
  }

  async function submit(event: FormEvent) {
    event.preventDefault();
    if (sendDisabled) return;
    const body = draft.trim();
    const attachmentIds = uploadedAttachments.map(a => a.id);
    const sendBody = body || (attachmentIds.length ? 'Uploaded file' : '');
    if (!sendBody && attachmentIds.length === 0) return;
    const local = optimisticUserMessage(conversationId, sendBody);
    const localId = msgId(local, 0);
    (local as any).artifact_ids_json = JSON.stringify(attachmentIds);
    setError('');
    setDraft('');
    setAttachments([]);
    setLocalMessages((current) => [...current, local]);
    try {
      const result = await sendMessage({ conversationId, body: sendBody, artifactIds: attachmentIds }).unwrap();
      const sent = sentMessageFromResult(result);
      setLocalMessages((current) => current.map((message) => {
        if (msgId(message, 0) !== localId) return message;
        return sent ? { ...sent, body: String(sent.body || sendBody), direction: sent.direction || 'user_to_agent', artifact_ids_json: (sent as any).artifact_ids_json || JSON.stringify(attachmentIds) } : { ...message, sending: false };
      }));
      void messagesQuery.refetch();
    } catch (err: any) {
      const message = errMsg(err, 'Send failed');
      setLocalMessages((current) => current.map((item) => (msgId(item, 0) === localId ? failedLocalMessage(item, message) : item)));
    }
  }

  async function requestPane() {
    if (paneCaptureDisabled) return;
    const requestId = `cap_local_${Date.now()}_${Math.random().toString(36).slice(2, 8)}`;
    const local = optimisticPaneCaptureMessage(conversationId, requestId, agentInstanceId);
    const localId = msgId(local, 0);
    setError('');
    setLocalMessages((current) => [...current, local]);
    try {
      const result = await requestPaneCapture({ conversationId, width: 80, settleMs: 3000, lineLimit: 120 }).unwrap();
      const serverMessage = result?.message || null;
      setLocalMessages((current) => current.map((message) => (msgId(message, 0) === localId && serverMessage ? { ...serverMessage, sending: false } : message)));
      void messagesQuery.refetch();
    } catch (err: any) {
      const message = errMsg(err, 'Pane capture request failed');
      setLocalMessages((current) => current.map((item) => (msgId(item, 0) === localId ? failedPaneCaptureMessage(item, message) : item)));
    }
  }

  function requestPaneFromComposer() {
    setComposerActionsOpen(false);
    if (!paneCaptureDisabled) void requestPane();
  }

  function beginRenameFromHeader() {
    setHeaderActionsOpen(false);
    setTitleDraft(editableTitle);
    setRenaming(true);
    setTitleError('');
  }

  function refreshFromHeader() {
    setHeaderActionsOpen(false);
    void messagesQuery.refetch();
  }

  function toggleTaskChainFromHeader() {
    setHeaderActionsOpen(false);
    setTaskChainOpen((open) => !open);
  }

  function renderConversationMessageBody(message: ChatMessage) {
    if (message.messageType === 'pane_capture') {
      const metadata = message.metadata || {};
      const status = message.messageStatus || 'complete';
      const lineCount = Number(metadata.line_count || metadata.lineCount || 0);
      return (
        <div data-debug-id={status === 'pending' ? `conversation-pane-capture-loading-${message.messageId}` : status === 'failed' ? `conversation-pane-capture-error-${message.messageId}` : `conversation-pane-capture-output-${message.messageId}`} className={`rounded-2xl border p-3 ${status === 'failed' ? 'border-red-400/30 bg-red-500/10 text-red-100' : 'border-sky-400/20 bg-sky-400/10 text-sky-50'}`}>
          <div className="mb-2 flex flex-wrap items-center gap-2 text-[11px] uppercase tracking-wide text-sky-100/70">
            <span>{status === 'pending' ? 'Requesting terminal pane…' : status === 'failed' ? 'Pane capture failed' : 'Terminal pane capture'}</span>
            <span>{Number(metadata.width || 80)} cols</span>
            {lineCount ? <span>{lineCount} lines</span> : null}
            {metadata.truncated ? <span>truncated</span> : null}
          </div>
          {status === 'pending' ? <div className="text-sm text-sky-100/80">Waiting for the wrapper to resize and capture the pane…</div> : <PaneCaptureOutput body={message.body} messageId={message.messageId} />}
          {status === 'failed' ? <button type="button" data-debug-id={`conversation-pane-capture-retry-${message.messageId}`} onClick={() => void requestPane()} disabled={paneCaptureDisabled} className="mt-2 rounded-full border border-white/10 px-3 py-1 text-xs text-zinc-100 hover:bg-white/10 disabled:opacity-50">Retry</button> : null}
        </div>
      );
    }
    return (
      <div className="flex flex-col gap-1">
        <Markdown source={message.body} compact copyAll={false} />
        {message.artifactIds && message.artifactIds.length > 0 && (
          <div className="mt-2 flex max-w-full flex-wrap gap-2">
            {message.artifactIds.map((id) => (
              <ArtifactAttachmentPreview key={id} artifactId={id} session={{ daemonUrl: '', clientToken: '' }} debugId={`conversation-thread-artifact-${message.messageId}-${id}`} />
            ))}
          </div>
        )}
      </div>
    );
  }

  async function applyReconfigure() {
    if (!agentInstanceId) return;
    const nextProvider = provider || providerOptions[0] || '';
    const nextTier = tier || tierOptions[0] || '';
    if (!nextProvider || !nextTier) { setReconfigStatus('Choose a provider and tier first.'); return; }
    setReconfigStatus('Applying selected runtime config…');
    try {
      await reconfigureInstance({ agentId, instanceId: agentInstanceId, provider: nextProvider, tier: nextTier }).unwrap();
      setReconfigStatus(`Applied ${nextProvider}/${nextTier} — restarting…`);
      await restartInstance({ agentId, instanceId: agentInstanceId }).unwrap();
      setReconfigStatus(`Restart requested with ${nextProvider}/${nextTier}.`);
      void instanceQuery.refetch();
      void messagesQuery.refetch();
    } catch (err: any) {
      setReconfigStatus(errMsg(err, 'Reconfigure/restart failed'));
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

  const runtimeControls = (
    <div data-debug-id="conversation-runtime-controls" className="space-y-3">
      <div className="grid gap-2 sm:grid-cols-2">
        <label className="text-[11px] text-zinc-500">Provider
          <select data-debug-id="conversation-provider-select" value={provider} onChange={(e) => setProvider(e.target.value)} disabled={runtimeActionBusy} className="mt-1 w-full rounded-lg border border-white/10 bg-black/30 px-2 py-2 text-xs text-white disabled:cursor-not-allowed disabled:opacity-50">
            {providerOptions.map((p) => <option key={p} value={p}>{p}</option>)}
          </select>
        </label>
        <label className="text-[11px] text-zinc-500">Tier
          <select data-debug-id="conversation-tier-select" value={tier} onChange={(e) => setTier(e.target.value)} disabled={runtimeActionBusy} className="mt-1 w-full rounded-lg border border-white/10 bg-black/30 px-2 py-2 text-xs text-white disabled:cursor-not-allowed disabled:opacity-50">
            {tierOptions.map((t) => <option key={t} value={t}>{t}</option>)}
          </select>
        </label>
      </div>
      <div className="flex flex-wrap gap-2">
        <button type="button" data-debug-id="conversation-reconfigure-btn" onClick={() => { setRuntimeMenuOpen(false); void applyReconfigure(); }} disabled={!selectionChangesConfig || runtimeActionBusy} title={selectionChangesConfig ? 'Save the selected provider/tier and relaunch' : 'Selection matches the current config'} className="min-h-10 rounded-lg border border-sky-400/30 bg-sky-400/10 px-3 py-1.5 text-xs text-sky-100 hover:bg-sky-400/20 disabled:cursor-not-allowed disabled:opacity-40">Apply &amp; relaunch</button>
        <button type="button" data-debug-id="conversation-restart-btn" onClick={() => { setRuntimeMenuOpen(false); void doRestart(); }} disabled={runtimeActionBusy} title="Relaunch the process with its current provider/tier" className="min-h-10 rounded-lg border border-white/10 bg-white/5 px-3 py-1.5 text-xs text-zinc-200 hover:bg-white/10 disabled:cursor-not-allowed disabled:opacity-40">Restart current config</button>
      </div>
      {reconfigStatus ? <div data-debug-id="conversation-reconfigure-status" className="text-[11px] text-zinc-400">{reconfigStatus}</div> : null}
      <p data-debug-id="conversation-runtime-hint" className="text-[10px] leading-4 text-zinc-600"><span className="text-zinc-400">Apply &amp; relaunch</span> saves the selected provider/tier then restarts this exact instance. <span className="text-zinc-400">Restart current config</span> relaunches as-is.</p>
    </div>
  );

  if (!conversation && !convQuery.isFetching) {
    return (
      <section data-debug-id="conversation-thread-page" className="w-full max-w-4xl rounded-[2rem] border border-white/10 bg-white/[0.04] p-6 text-left">
        <h2 className="text-xl font-semibold text-white">Conversation not found</h2>
        <p className="mt-2 text-sm text-zinc-400">No conversation with id <span className="font-mono">{conversationId}</span> for this user.</p>
        <a data-debug-id="conversation-thread-back-btn" href="#/conversations/new" className="mt-4 inline-flex rounded-2xl bg-sky-400 px-4 py-2 text-sm font-bold text-black hover:bg-sky-300">Start a new conversation</a>
      </section>
    );
  }


  function renderComposer() {
    return (
      <form onSubmit={submit} data-debug-id="conversation-composer-shell" data-mobile-shell-chrome="hide-on-focus" className="w-full max-w-full shrink-0 overflow-x-hidden border-t border-white/10 px-2 py-2 sm:px-4 sm:py-3">
        {error ? <div data-debug-id="conversation-composer-send-error" className="mb-2 rounded-xl border border-red-400/20 bg-red-400/10 px-3 py-2 text-xs text-red-100">{error}</div> : null}
        {attachments.length > 0 && (
          <div data-debug-id="conversation-attachment-tray" className="mb-2 space-y-2 rounded-2xl border border-white/10 bg-white/[0.03] p-2 text-xs text-zinc-200">
            {attachments.map((a) => (
              <div key={a.localId} data-debug-id={`conversation-attachment-${a.localId}`} className="rounded-xl border border-white/10 bg-black/20 px-2.5 py-2">
                <div className="flex min-w-0 items-center gap-2">
                  <span className={a.status === 'uploaded' ? 'text-emerald-300' : a.status === 'error' ? 'text-red-300' : 'text-sky-300'}>{a.status === 'uploading' ? '⇧' : a.status === 'uploaded' ? '✓' : '!'}</span>
                  <span className="min-w-0 flex-1 truncate" title={a.name}>{a.name}</span>
                  <span className={a.status === 'uploaded' ? 'text-emerald-300' : a.status === 'error' ? 'text-red-300' : 'text-sky-300'}>{a.status === 'uploading' ? 'Uploading…' : a.status === 'uploaded' ? 'Uploaded' : 'Failed'}</span>
                  {a.status === 'error' ? <button type="button" data-debug-id={`conversation-attachment-retry-${a.localId}`} onClick={() => void uploadAttachment(a.file, a.localId)} className="rounded-full border border-white/10 px-2 py-0.5 text-zinc-200 hover:bg-white/10">Retry</button> : null}
                  <button type="button" data-debug-id={`conversation-attachment-remove-${a.localId}`} onClick={() => setAttachments(prev => prev.filter((item) => item.localId !== a.localId))} className="rounded-full border border-white/10 px-2 py-0.5 text-zinc-400 hover:bg-white/10">Remove</button>
                </div>
                {a.status === 'uploading' ? <div data-debug-id={`conversation-attachment-progress-${a.localId}`} className="mt-2 h-1.5 overflow-hidden rounded-full bg-white/10"><div className="h-full w-1/2 animate-pulse rounded-full bg-sky-300" /></div> : null}
                {a.error ? <div data-debug-id={`conversation-attachment-error-${a.localId}`} className="mt-1 text-red-300">{a.error}</div> : null}
              </div>
            ))}
            {hasUploadingAttachments ? <div data-debug-id="conversation-attachment-uploading-hint" className="text-[11px] text-zinc-500">You can keep typing. Send unlocks when uploads finish.</div> : null}
            {hasFailedAttachments ? <div data-debug-id="conversation-attachment-failed-hint" className="text-[11px] text-red-300">Retry or remove failed uploads before sending.</div> : null}
          </div>
        )}
        <div className="flex items-end gap-1.5 sm:gap-2">
          <input ref={fileInputRef} data-debug-id="conversation-attach-input" type="file" multiple className="hidden" onChange={handleAttachmentInput} />
          <div ref={composerActionsRef} className="relative shrink-0 sm:hidden">
            <button ref={composerActionsButtonRef} data-debug-id="conversation-composer-actions-menu-btn" type="button" aria-label="More composer actions" aria-haspopup="menu" aria-expanded={composerActionsOpen ? 'true' : 'false'} onClick={() => setComposerActionsOpen((open) => !open)} className="grid h-[44px] w-[44px] place-items-center rounded-2xl border border-white/10 bg-black/30 text-2xl leading-none text-zinc-300 hover:bg-white/5 hover:text-white">⋯</button>
            {composerActionsOpen ? (
              <div data-debug-id="conversation-composer-actions-menu" role="menu" className="absolute bottom-full left-0 z-40 mb-2 w-56 overflow-hidden rounded-2xl border border-white/10 bg-[#101010] p-1.5 shadow-2xl shadow-black/50">
                <button data-debug-id="conversation-composer-actions-upload" type="button" role="menuitem" onClick={openAttachmentPicker} className="flex w-full items-center gap-2 rounded-xl px-3 py-2.5 text-left text-sm text-zinc-100 hover:bg-white/10"><span className="text-lg">＋</span><span>Upload</span></button>
                <button data-debug-id="conversation-composer-actions-pane" type="button" role="menuitem" disabled={paneCaptureDisabled} onClick={requestPaneFromComposer} className="flex w-full items-center gap-2 rounded-xl px-3 py-2.5 text-left text-sm text-zinc-100 hover:bg-white/10 disabled:cursor-not-allowed disabled:opacity-45"><span className="text-lg">▣</span><span>Pane capture</span></button>
              </div>
            ) : null}
          </div>
          <button data-debug-id="conversation-attach-btn" type="button" onClick={openAttachmentPicker} aria-label="Upload attachment" title="Upload attachment" className="hidden h-[44px] w-[44px] shrink-0 place-items-center rounded-2xl border border-white/10 bg-black/30 text-xl text-zinc-400 hover:bg-white/5 hover:text-white sm:grid">＋</button>
          <textarea
            data-debug-id="conversation-composer-input"
            value={draft}
            onChange={(e) => setDraft(e.target.value)}
            onKeyDown={(e) => { if (e.key === 'Enter' && (e.metaKey || e.ctrlKey)) { e.preventDefault(); void submit(e as any); } }}
            onPaste={handleComposerPaste}
            rows={2}
            placeholder="Message the agent… (Cmd/Ctrl+Enter to send)"
            className="min-h-[44px] min-w-0 flex-1 resize-none rounded-2xl border border-white/10 bg-black/30 px-3 py-2 text-base text-white outline-none placeholder:text-zinc-600 focus:border-sky-400/60 sm:px-4 sm:text-sm"
          />
          <button data-debug-id="conversation-request-pane-btn" type="button" disabled={paneCaptureDisabled} title={pendingPaneCapture ? 'A pane capture is already pending' : needsStart ? 'Start the agent before requesting a pane capture' : 'Request terminal pane capture'} aria-label="Request terminal pane capture" onClick={requestPaneFromComposer} className="hidden h-[44px] w-[44px] shrink-0 place-items-center rounded-2xl border border-sky-400/30 bg-sky-400/10 text-lg font-bold text-sky-100 hover:bg-sky-400/20 disabled:cursor-not-allowed disabled:opacity-40 sm:grid">▣</button>
          <button data-debug-id="conversation-composer-send-btn" type="submit" disabled={sendDisabled} aria-label="Send message" title={hasUploadingAttachments ? 'Wait for uploads to finish before sending' : hasFailedAttachments ? 'Retry or remove failed uploads before sending' : 'Send'} className="grid h-[44px] w-[44px] shrink-0 place-items-center rounded-2xl bg-sky-400 text-lg font-black text-black hover:bg-sky-300 disabled:cursor-not-allowed disabled:bg-zinc-700 disabled:text-zinc-400">{hasUploadingAttachments ? '⇧' : '↑'}</button>
        </div>
      </form>
    );
  }

  return (
    <section data-debug-id="conversation-thread-page" className="flex h-full min-h-0 w-full max-w-full flex-col overflow-x-hidden bg-[#090909] p-0 text-left">
      <header data-debug-id="conversation-thread-header" className="flex shrink-0 items-center gap-2 border-b border-white/10 px-3 py-2 sm:gap-3 sm:px-4">
        <div className="min-w-0 flex-1 self-stretch sm:self-auto">
          {renaming ? (
            <div className="flex min-w-0 items-center gap-2">
              <input
                data-debug-id="conversation-thread-title-input"
                value={titleDraft}
                onChange={(event) => { setTitleDraft(event.target.value); setTitleError(''); }}
                onKeyDown={(event) => {
                  if (event.key === 'Enter') { event.preventDefault(); void saveConversationTitle(); }
                  if (event.key === 'Escape') { setRenaming(false); setTitleError(''); setTitleDraft(editableTitle); }
                }}
                className="min-h-9 min-w-0 flex-1 rounded-xl border border-white/10 bg-black/30 px-3 py-1.5 text-base font-semibold text-white outline-none focus:border-sky-400/60 sm:text-sm"
                autoFocus
              />
              <button type="button" data-debug-id="conversation-thread-title-save-btn" aria-label="Save conversation title" title="Save" onClick={() => void saveConversationTitle()} disabled={updateTitleState.isLoading || !titleDraft.trim()} className="grid h-10 w-10 shrink-0 place-items-center rounded-xl bg-sky-400 text-sm font-bold text-black hover:bg-sky-300 disabled:opacity-50">✓</button>
              <button type="button" data-debug-id="conversation-thread-title-cancel-btn" aria-label="Cancel title edit" title="Cancel" onClick={() => { setRenaming(false); setTitleError(''); setTitleDraft(editableTitle); }} className="grid h-10 w-10 shrink-0 place-items-center rounded-xl border border-white/10 bg-white/5 text-sm text-zinc-300 hover:bg-white/10">×</button>
            </div>
          ) : (
            <div className="flex min-w-0 items-center gap-2">
              <h2 data-debug-id="conversation-thread-title" className="truncate text-base font-semibold text-white sm:text-lg">{title}</h2>
              <span data-debug-id="conversation-thread-status-chip" title={`Runtime status: ${runtimeStatus || 'unknown'}`} className={`max-w-[96px] shrink-0 truncate rounded-full border px-2 py-0.5 text-[10.5px] font-semibold uppercase tracking-wide ${needsStart ? 'border-zinc-600 bg-zinc-800/70 text-zinc-300' : runtimeStopping ? 'border-amber-400/30 bg-amber-400/10 text-amber-200' : 'border-emerald-400/30 bg-emerald-400/10 text-emerald-200'}`}>{runtimeStatus || '—'}</span>
            </div>
          )}
          {titleError ? <div data-debug-id="conversation-thread-title-error" className="mt-1 text-[11px] text-red-300">{titleError}</div> : null}
          <div data-debug-id="conversation-thread-compact-summary" className="mt-0.5 flex min-w-0 items-center gap-1.5 text-[11px] text-zinc-500">
            {bridgeLabel ? <span data-debug-id="conversation-thread-bridge-summary" className="min-w-0 truncate">{bridgeLabel}</span> : null}
            {bridgeLabel && runtimeConfigLabel ? <span className="shrink-0 text-zinc-700">•</span> : null}
            {runtimeConfigLabel ? <span data-debug-id="conversation-thread-runtime-summary" className="shrink-0">{runtimeConfigLabel}</span> : null}
            {chainId ? <span data-debug-id="conversation-thread-chain-summary" className="hidden shrink-0 text-sky-300/70 sm:inline">• task chain linked</span> : null}
          </div>
        </div>
        <div data-debug-id="conversation-thread-mobile-actions" className="flex shrink-0 items-center gap-1.5 sm:gap-2">
          <button type="button" data-debug-id={needsStart ? 'conversation-thread-start-btn' : 'conversation-thread-stop-btn'} aria-label={`${runtimeButtonLabel} runtime`} title={`${runtimeButtonLabel} runtime`} onClick={() => void toggleRuntime()} disabled={!agentInstanceId || runtimeActionBusy || runtimeStopping} className={needsStart ? 'grid h-10 w-10 shrink-0 place-items-center rounded-xl bg-emerald-400 text-sm font-bold text-black hover:bg-emerald-300 disabled:cursor-not-allowed disabled:opacity-50' : 'grid h-10 w-10 shrink-0 place-items-center rounded-xl border border-red-400/30 bg-red-400/10 text-sm font-bold text-red-100 hover:bg-red-400/20 disabled:cursor-not-allowed disabled:opacity-50'}>{runtimeButtonIcon}</button>
          <div className="relative" ref={runtimeMenuRef}>
            <button ref={runtimeMenuButtonRef} type="button" data-debug-id="conversation-runtime-menu-btn" aria-label="Runtime controls" title="Runtime controls" aria-haspopup={isMobile ? 'dialog' : 'menu'} aria-expanded={runtimeMenuOpen ? 'true' : 'false'} onClick={() => setRuntimeMenuOpen((open) => !open)} className="grid h-10 w-10 shrink-0 place-items-center rounded-xl border border-white/10 bg-white/5 text-base text-zinc-200 hover:bg-white/10">⚙</button>
            {runtimeMenuOpen && !isMobile ? (
              <div data-debug-id="conversation-runtime-menu" role="menu" className="absolute right-0 top-full z-40 mt-2 w-[min(92vw,430px)] rounded-2xl border border-white/10 bg-[#101010] p-3 text-left shadow-2xl shadow-black/60">
                {runtimeControls}
              </div>
            ) : null}
            {runtimeMenuOpen && isMobile ? (
              <div data-debug-id="conversation-runtime-mobile-sheet" className="fixed inset-0 z-50 flex items-end bg-black/60 p-2 backdrop-blur-sm sm:hidden" role="dialog" aria-modal="true" aria-labelledby="conversation-runtime-sheet-title" onPointerDown={(event) => { if (event.target === event.currentTarget) setRuntimeMenuOpen(false); }}>
                <div data-debug-id="conversation-runtime-mobile-sheet-panel" className="max-h-[86vh] w-full overflow-y-auto rounded-t-[1.75rem] border border-white/10 bg-[#101010] p-4 pb-[calc(env(safe-area-inset-bottom)+1rem)] shadow-2xl shadow-black/70">
                  <div className="mb-3 flex items-center justify-between gap-3">
                    <h2 id="conversation-runtime-sheet-title" data-debug-id="conversation-runtime-mobile-sheet-title" className="text-sm font-semibold text-white">Runtime controls</h2>
                    <button type="button" data-debug-id="conversation-runtime-mobile-sheet-close" onClick={() => setRuntimeMenuOpen(false)} aria-label="Close runtime controls" className="grid h-10 w-10 place-items-center rounded-xl border border-white/10 bg-white/5 text-zinc-300 hover:bg-white/10">×</button>
                  </div>
                  {runtimeControls}
                </div>
              </div>
            ) : null}
          </div>
          {chainId ? (
            <button type="button" data-debug-id="taskchain-overview-toggle-btn" aria-label={taskChainOpen ? 'Hide task chain' : 'Show task chain'} title={taskChainOpen ? 'Hide task chain' : 'Show task chain'} onClick={toggleTaskChainFromHeader} className="grid h-10 w-10 shrink-0 place-items-center rounded-xl border border-sky-400/30 bg-sky-400/10 text-base font-semibold text-sky-200 hover:bg-sky-400/20">▤</button>
          ) : null}
          <div className="relative" ref={headerActionsRef}>
            <button ref={headerActionsButtonRef} type="button" data-debug-id="conversation-thread-overflow-menu-btn" aria-label="More conversation actions" title="More conversation actions" aria-haspopup="menu" aria-expanded={headerActionsOpen ? 'true' : 'false'} onClick={() => setHeaderActionsOpen((open) => !open)} className="grid h-10 w-10 shrink-0 place-items-center rounded-xl border border-white/10 bg-white/5 text-xl leading-none text-zinc-200 hover:bg-white/10">⋯</button>
            {headerActionsOpen ? (
              <div data-debug-id="conversation-thread-overflow-menu" role="menu" className="absolute right-0 top-full z-40 mt-2 w-[min(88vw,300px)] overflow-hidden rounded-2xl border border-white/10 bg-[#101010] p-1.5 text-left shadow-2xl shadow-black/60">
                <button type="button" role="menuitem" data-debug-id="conversation-thread-title-edit-btn" onClick={beginRenameFromHeader} className="flex w-full items-center gap-2 rounded-xl px-3 py-2.5 text-sm text-zinc-100 hover:bg-white/10"><span className="w-5 text-center">✎</span><span>Rename</span></button>
                <button type="button" role="menuitem" data-debug-id="conversation-thread-refresh-btn" onClick={refreshFromHeader} className="flex w-full items-center gap-2 rounded-xl px-3 py-2.5 text-sm text-zinc-100 hover:bg-white/10"><span className="w-5 text-center">↻</span><span>Refresh messages</span></button>
                <div data-debug-id="conversation-thread-overflow-details" className="mt-1 border-t border-white/10 px-3 py-2 text-[11px] leading-5 text-zinc-500">
                  <div data-debug-id="conversation-thread-agent" className="truncate">Agent: {agentId || '—'}</div>
                  <div data-debug-id="conversation-thread-instance" className="truncate">Instance: {agentInstanceId || '—'}</div>
                  <div data-debug-id="conversation-thread-bridge" className="truncate">Bridge: {bridgeLabel || '—'}</div>
                  <div className="flex gap-2"><span data-debug-id="conversation-thread-provider">Provider: {instanceProvider || '—'}</span><span data-debug-id="conversation-thread-tier">Tier: {instanceTier || '—'}</span></div>
                  <div data-debug-id="conversation-thread-status">Status: {runtimeStatus || '—'}</div>
                  {chainId ? <div data-debug-id="conversation-thread-chain" className="truncate">Chain: {chainId}</div> : null}
                </div>
              </div>
            ) : null}
          </div>
        </div>
      </header>

      {taskChainOpen && chainId ? (
        <div className="flex h-full min-h-0 w-full max-w-full flex-col overflow-x-hidden sm:flex-row">
          {/* Mobile view (< 768px): TaskChain 100% width (Requirement 10) */}
          <div className="flex h-full w-full min-h-0 max-w-full flex-col overflow-x-hidden sm:hidden">
            <TaskChainOverview
              chainId={chainId}
              onClose={() => setTaskChainOpen(false)}
              isMobile={true}
            />
          </div>
          {/* Desktop view (>= 768px): 50/50 split panel */}
          <div className="hidden h-full min-h-0 w-full max-w-full flex-row overflow-x-hidden sm:flex">
            <div className="flex h-full min-h-0 min-w-0 w-1/2 flex-col overflow-x-hidden border-r border-white/10">
              <div data-debug-id="conversation-thread-transcript" className="min-h-0 min-w-0 max-w-full flex-1 overflow-x-hidden px-2 py-2 sm:px-4 sm:py-3">
        <ChatMessageList
          conversationKey={conversationId}
          messages={chatMessages}
          debugPrefix="conversation-thread"
          hasMore={olderHasMore && Boolean(olderCursor)}
          loadingOlder={olderMessagesState.isFetching}
          onLoadOlder={loadOlderMessages}
          formatTimestamp={formatMessageTimestamp}
          getDeliveryStatus={deliveryStatusFor}
          renderMessageBody={({ message }) => renderConversationMessageBody(message)}
          wrapperClassName="relative h-full min-h-0 min-w-0 max-w-full overflow-hidden overflow-x-hidden"
          scrollClassName="chat-scrollbar h-full min-h-0 max-w-full space-y-3 overflow-y-auto overflow-x-hidden rounded-none bg-[#090909] px-1 py-2 sm:space-y-4 sm:rounded-[18px] sm:px-4 sm:py-4"
          emptyState={messagesQuery.isFetching ? (
            <div data-debug-id="conversation-thread-empty-state" className="grid h-full min-h-[220px] place-items-center rounded-2xl border border-dashed border-white/10 p-6 text-sm text-zinc-500">Loading messages…</div>
          ) : (
            <div data-debug-id="conversation-thread-empty-state" className="grid h-full min-h-[220px] place-items-center rounded-2xl border border-dashed border-white/10 p-6 text-sm text-zinc-500">No messages yet. Say something below.</div>
          )}
        />
      </div>

      {renderComposer()}
            </div>
            <div className="flex h-full min-h-0 min-w-0 w-1/2 flex-col overflow-x-hidden">
              <TaskChainOverview
                chainId={chainId}
                onClose={() => setTaskChainOpen(false)}
                isMobile={false}
              />
            </div>
          </div>
        </div>
      ) : (
        <>
          <div data-debug-id="conversation-thread-transcript" className="min-h-0 min-w-0 max-w-full flex-1 overflow-x-hidden px-2 py-2 sm:px-4 sm:py-3">
        <ChatMessageList
          conversationKey={conversationId}
          messages={chatMessages}
          debugPrefix="conversation-thread"
          hasMore={olderHasMore && Boolean(olderCursor)}
          loadingOlder={olderMessagesState.isFetching}
          onLoadOlder={loadOlderMessages}
          formatTimestamp={formatMessageTimestamp}
          getDeliveryStatus={deliveryStatusFor}
          renderMessageBody={({ message }) => renderConversationMessageBody(message)}
          wrapperClassName="relative h-full min-h-0 min-w-0 max-w-full overflow-hidden overflow-x-hidden"
          scrollClassName="chat-scrollbar h-full min-h-0 max-w-full space-y-3 overflow-y-auto overflow-x-hidden rounded-none bg-[#090909] px-1 py-2 sm:space-y-4 sm:rounded-[18px] sm:px-4 sm:py-4"
          emptyState={messagesQuery.isFetching ? (
            <div data-debug-id="conversation-thread-empty-state" className="grid h-full min-h-[220px] place-items-center rounded-2xl border border-dashed border-white/10 p-6 text-sm text-zinc-500">Loading messages…</div>
          ) : (
            <div data-debug-id="conversation-thread-empty-state" className="grid h-full min-h-[220px] place-items-center rounded-2xl border border-dashed border-white/10 p-6 text-sm text-zinc-500">No messages yet. Say something below.</div>
          )}
        />
      </div>

      {renderComposer()}
        </>
      )}
    </section>
  );
}
