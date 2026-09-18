import TaskChainOverview from '../taskchain/TaskChainOverview';
import ProjectFilesPanel from './ProjectFilesPanel';
import InstanceRunDirPanel from './InstanceRunDirPanel';
import ShellJobsPanel from './ShellJobsPanel';
import AtMentionPopup, { type MentionEntity } from './AtMentionPopup';
import AgentPaneComposerPanel from './AgentPaneComposerPanel';
import { type ClipboardEvent, type FormEvent, type UIEvent, useCallback, useEffect, useMemo, useRef, useState } from 'react';
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
  useFetchAgentIdentityQuery,
  useReconfigureAgentInstanceMutation,
  useRestartAgentInstanceMutation,
  useStopAgentInstanceMutation,
} from '../../api/endpoints/agents';
import { useCreateArtifactMutation } from '../../api/endpoints/artifacts';
import { useFetchProjectQuery } from '../../api/endpoints/projects';
import { useGetAgentsLiveQuery } from '../../api/endpoints/agentsLive';
import { ArtifactAttachmentPreview } from '../ArtifactAttachmentPreview';
import {
  normalizeBridgeCapabilities,
  useListBridgesQuery,
  type BridgeCapability,
} from '../../api/endpoints/bridgeSupport';
import { MAX_UPLOAD_BYTES } from '../ArtifactUpload';
import Markdown from '../Markdown';
import ChatMessageList from './ChatMessageList';
import { CommandPalette, Drawer, Icon as UiIcon, Menu, Popover, StatusDot, runtimeStateFromStatus, runtimeStateLabel, runtimeStatusToTone } from '@ui';
import { buildRouteHash, getRoutePathname, getRouteSearch } from '../../utils/appLocation';
import {
  CHAT_VIEW_MIN_WIDTH,
  RIGHT_SIDEBAR_DEFAULT_WIDTH,
  RIGHT_SIDEBAR_MIN_WIDTH,
  clampRightSidebarWidth,
  readRightSidebarOpen,
  readRightSidebarTab,
  readRightSidebarWidth,
  writeRightSidebarOpen,
  writeRightSidebarTab,
  writeRightSidebarWidth,
  type RightSidebarTab,
} from '../../utils/clientPersistence';
import Icon from '../Icon';
import { useFetchChainTasksQuery, useFetchTaskChainDetailQuery } from '../../api/endpoints/tasks';
import AgentActivityBubbles from './AgentActivityBubbles';
import { type TaskLike } from './chainTaskInference';
import { useIsMobile } from '../shell/responsive';
import { artifactKindForFile, artifactLinkFromResponse, artifactMimeForFile, artifactUploadName, clipboardFilesFromEvent } from '../../utils/artifactUpload';
import { describeCron, formatInTimeZone, timeZoneLabel } from '../actions/scheduleUtils';
import type { ChatDeliveryStatus, ChatMessage, ChatTimestamp } from './types';

// e2e conversation thread for /conversations/{agentInstanceId}. Cookie-auth,
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
  delivered_at?: string;
  deliveredAt?: string;
  delivered_unix_ms?: number | string;
  deliveredUnixMs?: number | string;
  read_at?: string;
  readAt?: string;
  read_unix_ms?: number | string;
  readUnixMs?: number | string;
  delivery_failed_at?: string;
  deliveryFailedAt?: string;
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

// MSG-3: derive a human-readable schedule context line for a scheduled-action
// message from its metadata. The hub bridge_execute path may attach action
// context (cron_expr, timezone, target_run_at, action_id) to the action
// message's metadata_json; this reads it defensively so the card degrades
// gracefully to just the header when no metadata is present.
//   HOOK: once the hub emits these fields, the schedule summary + trigger time
//   appear automatically — no further UI change required.
function scheduleContextFromMetadata(metadata: any): { summary: string; triggeredAt: string } {
  const meta = metadata && typeof metadata === 'object' ? metadata : {};
  const cronExpr = String(meta.cron_expr ?? meta.cronExpr ?? meta.cron ?? '').trim();
  const timezone = String(meta.timezone ?? meta.time_zone ?? meta.tz ?? '').trim();

  let summary = '';
  if (cronExpr) {
    const described = describeCron(cronExpr);
    summary = timezone ? `${described} (${timezone})` : described;
  }

  let triggeredAt = '';
  const rawTrigger = String(meta.target_run_at ?? meta.targetRunAt ?? meta.triggered_at ?? meta.triggeredAt ?? '').trim();
  if (rawTrigger) {
    const date = new Date(rawTrigger);
    if (!Number.isNaN(date.getTime())) {
      triggeredAt = `${formatInTimeZone(date, timezone)} (${timeZoneLabel(date, timezone)})`;
    }
  }

  return { summary, triggeredAt };
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
      const messageType = String((message as any).message_type || (message as any).messageType || 'text');
      // SYS-2: the system message card is self-labeled ('System'), so suppress
      // the redundant generic author label above it. System notices arrive as
      // message_type='system' (direction is 'agent_to_user'), so key on the type,
      // not direction. ChatMessageList renders the label span unconditionally
      // with the timestamp beside it, so an empty label degrades cleanly
      // (timestamp still shows) without layout changes.
      const authorLabel = isUser ? 'you' : messageType === 'system' ? '' : (sender || agentLabel || 'agent');
      const artifactIds = extractMessageArtifactIds(message);
      return {
        order: index,
        chatMessage: {
          key: id || `${direction}-${createdUnixMs}-${index}`,
          messageId: id,
          body: String(message.body || ''),
          isUser,
          createdUnixMs,
          deliveredUnixMs: coerceUnixMs(message.delivered_unix_ms ?? message.deliveredUnixMs) || dateStringToUnixMs(message.delivered_at ?? message.deliveredAt),
          readUnixMs: coerceUnixMs(message.read_unix_ms ?? message.readUnixMs) || dateStringToUnixMs(message.read_at ?? message.readAt),
          deliveryFailedUnixMs: coerceUnixMs(message.delivery_failed_unix_ms ?? message.deliveryFailedUnixMs) || dateStringToUnixMs(message.delivery_failed_at ?? message.deliveryFailedAt),
          deliveryError: String(message.delivery_error || message.deliveryError || ''),
          sending: Boolean(message.sending),
          authorLabel,
          artifactIds,
          messageType,
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

export default function ConversationThreadPage({ agentInstanceId: routeInstanceId, focusMessageId }: { agentInstanceId: string; focusMessageId?: string }) {
  // The route is instance-id-only (#/conversations/{agentInstanceId}); an instance
  // maps 1:1 to a conversation, which we resolve via the O(1) by-instance endpoint.
  // New messages, read receipts and delivery status arrive live over the user WS
  // (`chat_event` -> wsInvalidation patches the `Chat`/`ConversationSummaries`
  // caches and invalidates the `Chat` tag for this conversation). Polling is only
  // a slow fallback for missed events, so we poll at 10s and pause when the tab is
  // unfocused so we don't hammer the hub in the background. (skipPollingIfUnfocused.)
  // No refetchOnMountOrArgChange: serve cached conversation instantly on switch
  // (keepUnusedDataFor keeps it warm); WS chat_event invalidation + the 10s poll
  // keep it fresh. This avoids a full /chats/by-instance fetch on every switch.
  const convQuery = useFetchConversationQuery({ conversationId: '', agentInstanceId: routeInstanceId }, { skip: !routeInstanceId, pollingInterval: 10000, skipPollingIfUnfocused: true });
  const conversation = convQuery.data?.conversation || null;
  // Message fetch/send/markRead stay keyed by conversation_id (server contract);
  // only the URL is instance-id. Resolve it from the fetched conversation.
  const conversationId = String(conversation?.conversation_id || conversation?.conversationId || '');
  // Do NOT force a refetch on every conversation switch: with keepUnusedDataFor
  // (30s) a recently-viewed thread renders instantly from cache, and the user WS
  // `chat_event` already invalidates this conversation's `Chat` tag when anything
  // changes. refetchOnMountOrArgChange:true made every switch blank the transcript
  // behind a "Loading messages…" gate while it re-hit the hub — the perceived hang.
  const messagesQuery = useFetchConversationMessagesQuery({ conversationId }, { skip: !conversationId, pollingInterval: 10000, skipPollingIfUnfocused: true });
  const [fetchOlderMessages, olderMessagesState] = useLazyFetchConversationMessagesQuery();
  const [updateConversationTitle, updateTitleState] = useUpdateConversationTitleMutation();
  const [requestPaneCapture, requestPaneCaptureState] = useRequestPaneCaptureMutation();
  const [sendMessage] = useSendConversationMessageMutation();
  const [markRead] = useMarkConversationReadMutation();
  const [reconfigureInstance, reconfigureState] = useReconfigureAgentInstanceMutation();
  const [restartInstance, restartState] = useRestartAgentInstanceMutation();
  const [stopInstance, stopState] = useStopAgentInstanceMutation();
  const [createArtifact] = useCreateArtifactMutation();

  const agentId = String(conversation?.agent_id || conversation?.agentId || '');
  const agentInstanceId = String(conversation?.agent_instance_id || conversation?.agentInstanceId || routeInstanceId);
  const conversationRuntimeStatusForPoll = String(conversation?.runtime_status || conversation?.runtimeStatus || '');
  const chainId = String(conversation?.chain_id || conversation?.chainId || '');
  const title = conversationDisplayTitle(conversation, agentId, agentInstanceId, conversationId);

  // Publish the Files panel's collected line comments as a single chat message to
  // this conversation's agent. Returns true on success so the panel clears its
  // in-memory store.
  const publishFileComments = useCallback(
    async (markdown: string): Promise<boolean> => {
      if (!conversationId || !markdown.trim()) return false;
      try {
        const res: any = await sendMessage({ conversationId, body: markdown }).unwrap();
        return !(res?.error);
      } catch {
        return false;
      }
    },
    [conversationId, sendMessage],
  );

  // Lightweight chain-task progress for the header "Task chain N/M" button, so
  // the coordinator's chain is one glance + one click away. Only fetched when the
  // conversation is linked to a chain.
  const chainTasksQuery = useFetchChainTasksQuery({ chainId }, { skip: !chainId });
  // Cookie-auth chain detail (works in the live shell, unlike the client-token
  // fetchChainTasks). Used to resolve the agent's current task for the working
  // indicator; polled modestly so the task title stays fresh.
  // Tasks change infrequently and task/chain mutations invalidate the Chain tag
  // over WS, so poll slowly (2 min) as a fallback rather than every 10s.
  const chainDetailQuery = useFetchTaskChainDetailQuery({ chainId }, { skip: !chainId, pollingInterval: 120000 });
  const chainProgress = useMemo(() => {
    // Prefer the cookie-auth chain detail (works in the live shell); fall back to
    // the legacy client-token fetchChainTasks. Without this the live shell always
    // read 0/0 because fetchChainTasks needs a client token the shell doesn't have.
    const tasks: TaskLike[] = (chainDetailQuery.data?.chain?.tasks || chainTasksQuery.data?.tasks || []) as TaskLike[];
    const total = tasks.length;
    const done = tasks.filter((t: TaskLike) => t.status === 'validated_good' || t.status === 'completed').length;
    return { total, done };
  }, [chainDetailQuery.data, chainTasksQuery.data]);
  const rawTitle = String(conversation?.title || '').trim();
  const editableTitle = rawTitle && !looksLikeInternalId(rawTitle) ? rawTitle : title;

  // The instance record is the source of truth for the CONCRETE provider / tier /
  // bridge this conversation runs on (never "default"/"Auto").
  // Adaptive polling: while the runtime is transitional (starting) poll fast so
  // the status chip settles quickly; once stable, poll moderately. The interval is
  // derived from the last-seen status tracked in a ref (updated after each read),
  // seeded from the conversation summary before the instance loads.
  const lastInstanceStatusRef = useRef('');
  const pollHint = lastInstanceStatusRef.current || conversationRuntimeStatusForPoll;
  const instancePollInterval = runtimeStateFromStatus(pollHint) === 'starting' ? 2500 : 8000;
  // No refetchOnMountOrArgChange: serve the cached instance runtime instantly on
  // switch. WS resource_changed(agent_instance) patches runtime/activity live,
  // reconfigure invalidates AgentInstances, and the poll below is the backstop.
  const instanceQuery = useFetchAgentInstanceQuery({ instanceId: agentInstanceId }, { skip: !agentInstanceId, pollingInterval: instancePollInterval, skipPollingIfUnfocused: true });
  const instance = instanceQuery.data?.instance || null;
  // Currently running agents across all projects/chains, for the composer's
  // agent-switcher picker (grouped by project → chain like the sidebar). Polled
  // slowly (the picker is a convenience, not a live surface).
  const { data: liveProjects } = useGetAgentsLiveQuery(undefined, { pollingInterval: 30000, skipPollingIfUnfocused: true });
  // Agent identity (name + persona/instructions) — used for the empty-state
  // welcome so a fresh conversation shows who you're talking to.
  const agentIdentityQuery = useFetchAgentIdentityQuery({ agentId }, { skip: !agentId });
  const agentIdentity = agentIdentityQuery.data?.agent || null;
  const agentDisplayName = String(agentIdentity?.name || conversationAgentLabel(conversation) || agentId || '').trim();
  const agentPersona = String(agentIdentity?.instructions || agentIdentity?.persona || agentIdentity?.template_persona || '').trim();
  useEffect(() => {
    const s = String(instance?.runtime_status || instance?.runtimeStatus || '');
    if (s) lastInstanceStatusRef.current = s;
  }, [instance?.runtime_status, instance?.runtimeStatus]);
  const instanceProvider = String(instance?.provider || '');
  const instanceTier = String(instance?.tier || '');
  const instanceBridgeId = String(instance?.bridge_id || instance?.bridgeId || '');
  // Project the conversation/instance is scoped to — powers the Files (project
  // directory browser) tab. Prefer the live instance, fall back to conversation.
  const projectId = String(instance?.project_id || instance?.projectId || conversation?.project_id || conversation?.projectId || '');
  // Project display name for the composer chip (falls back to the id).
  const projectQuery = useFetchProjectQuery({ projectId }, { skip: !projectId });
  const projectName = String(projectQuery.data?.project?.name || projectQuery.data?.project?.display_name || projectId || '').trim();
  const conversationRuntimeStatus = String(conversation?.runtime_status || conversation?.runtimeStatus || '');
  const runtimeStatus = String(instance?.runtime_status || instance?.runtimeStatus || conversationRuntimeStatus || '');
  const activityStatus = String(instance?.activity_status || instance?.activityStatus || '').toLowerCase();
  const isWorking = runtimeStateFromStatus(runtimeStatus) === 'live' && (activityStatus === 'active' || activityStatus === 'busy' || activityStatus === 'working');


  // Bridges are near-static (label + provider/tier caps); no refetch on every
  // conversation switch. The Bridges LIST tag invalidates on bridge mutations,
  // and the slow poll is a backstop.
  const bridgesQuery = useListBridgesQuery(undefined, { pollingInterval: 120000 });
  const bridges = bridgesQuery.data?.bridges || [];
  const instanceBridge = useMemo(() => bridges.find((b: any) => bridgeId(b) === instanceBridgeId), [bridges, instanceBridgeId]);

  const baseMessages: Message[] = messagesQuery.data?.messages || [];
  const [olderMessages, setOlderMessages] = useState<Message[]>([]);
  const [olderCursor, setOlderCursor] = useState('');
  const [olderHasMore, setOlderHasMore] = useState(false);
  const [draft, setDraft] = useState('');
  const [isPaneExpanded, setIsPaneExpanded] = useState<boolean>(false);
  // @-mention popup state: mentionQuery is the fragment typed after '@' (null when
  // the popup is closed); mentionIndex is the highlighted row for arrow-key nav.
  const [mentionQuery, setMentionQuery] = useState<string | null>(null);
  const [mentionIndex, setMentionIndex] = useState(0);
  const textareaRef = useRef<HTMLTextAreaElement>(null);
  const [error, setError] = useState('');
  const [attachments, setAttachments] = useState<PendingAttachment[]>([]);
  const [localMessages, setLocalMessages] = useState<Message[]>([]);
  const [provider, setProvider] = useState('');
  const [tier, setTier] = useState('');
  const [reconfigStatus, setReconfigStatus] = useState('');
  // Flatten the live projects->chains->agents tree into a single @-mention list
  // (agents, projects, and task chains). liveProjects is LiveProject[] with the
  // camelCase shape from api/endpoints/agentsLive.ts.
  const mentionEntities = useMemo<MentionEntity[]>(() => {
    const items: MentionEntity[] = [];
    for (const proj of (liveProjects ?? [])) {
      const projectName = String(proj.name || proj.projectId || '');
      items.push({ type: 'project', id: String(proj.projectId || ''), label: projectName, sublabel: 'project' });
      for (const chain of (proj.chains ?? [])) {
        items.push({ type: 'chain', id: String(chain.chainId || ''), label: String(chain.title || chain.chainId || ''), sublabel: projectName });
        for (const agent of (chain.liveAgents ?? [])) {
          items.push({ type: 'agent', id: String(agent.agentInstanceId || ''), label: String(agent.displayName || agent.agentInstanceId || ''), sublabel: String(chain.title || '') });
        }
      }
    }
    return items;
  }, [liveProjects]);
  // Client-side fuzzy filter (label or id contains the query, case-insensitive),
  // capped at 8 items. Empty query shows the first 8 entities.
  const filteredMentions = useMemo(() => {
    if (mentionQuery === null) return [] as MentionEntity[];
    const q = mentionQuery.toLowerCase();
    return mentionEntities
      .filter((e) => !q || e.label.toLowerCase().includes(q) || e.id.toLowerCase().includes(q))
      .slice(0, 8);
  }, [mentionEntities, mentionQuery]);
  // Replace the '@fragment' immediately before the caret with '@<id>' and restore
  // focus/caret after React re-renders the textarea value.
  function handleMentionSelect(entity: MentionEntity) {
    const ta = textareaRef.current;
    const pos = ta?.selectionStart ?? draft.length;
    const before = draft.slice(0, pos);
    const after = draft.slice(pos);
    const newBefore = before.replace(/@([^\s@]*)$/, `@${entity.id}`);
    setDraft(newBefore + after);
    setMentionQuery(null);
    setMentionIndex(0);
    setTimeout(() => { ta?.focus(); const np = newBefore.length; ta?.setSelectionRange(np, np); }, 0);
  }
  const isMobile = useIsMobile();
  // Unified right-sidebar state. The top-right toggle opens/closes the panel; the
  // panel itself has Tasks / Files / RunDir tabs. 'closed' hides it entirely.
  // Initialized from ?panel= / ?sidebar= query param, falling back to UI storage.
  const [rightPanel, setRightPanel] = useState<'closed' | 'tasks' | 'files' | 'rundir' | 'jobs'>(() => {
    const search = getRouteSearch();
    const params = new URLSearchParams(search.replace(/^\?/, ''));
    const param = params.get('panel') || params.get('sidebar');
    if (param) {
      const norm = param.trim().toLowerCase();
      if (norm === 'tasks') return 'tasks';
      if (norm === 'files') return 'files';
      if (norm === 'rundir') return 'rundir';
      if (norm === 'jobs') return 'jobs';
      if (norm === 'closed' || norm === 'false' || norm === '0') return 'closed';
      if (norm === 'open' || norm === 'true' || norm === '1') {
        return readRightSidebarTab() || 'tasks';
      }
    }
    const open = !isMobile && readRightSidebarOpen();
    if (open) {
      return readRightSidebarTab() || 'tasks';
    }
    return 'closed';
  });

  const [sidebarWidth, setSidebarWidth] = useState<number>(() => readRightSidebarWidth());
  const [isDragging, setIsDragging] = useState(false);
  const containerRef = useRef<HTMLDivElement>(null);

  // Sync state if hash/search changes while mounted (e.g. browser back/forward or internal navigation)
  useEffect(() => {
    const handleLocationChange = () => {
      const search = getRouteSearch();
      const params = new URLSearchParams(search.replace(/^\?/, ''));
      const param = params.get('panel') || params.get('sidebar');
      if (param) {
        const norm = param.trim().toLowerCase();
        if (norm === 'tasks') {
          setRightPanel('tasks');
          writeRightSidebarOpen(true);
          writeRightSidebarTab('tasks');
        } else if (norm === 'files') {
          setRightPanel('files');
          writeRightSidebarOpen(true);
          writeRightSidebarTab('files');
        } else if (norm === 'rundir') {
          setRightPanel('rundir');
          writeRightSidebarOpen(true);
          writeRightSidebarTab('rundir');
        } else if (norm === 'jobs') {
          setRightPanel('jobs');
          writeRightSidebarOpen(true);
          writeRightSidebarTab('jobs');
        } else if (norm === 'closed' || norm === 'false' || norm === '0') {
          setRightPanel('closed');
          writeRightSidebarOpen(false);
        }
      } else {
        setRightPanel('closed');
        writeRightSidebarOpen(false);
      }
    };
    window.addEventListener('hashchange', handleLocationChange);
    window.addEventListener('popstate', handleLocationChange);
    return () => {
      window.removeEventListener('hashchange', handleLocationChange);
      window.removeEventListener('popstate', handleLocationChange);
    };
  }, []);

  // Guardrail: adjust sidebar width on window resize so chat view never violates CHAT_VIEW_MIN_WIDTH
  useEffect(() => {
    const handleWindowResize = () => {
      if (!containerRef.current) return;
      const containerWidth = containerRef.current.getBoundingClientRect().width;
      const maxAllowedWidth = Math.max(RIGHT_SIDEBAR_MIN_WIDTH, containerWidth - CHAT_VIEW_MIN_WIDTH);
      setSidebarWidth((prev) => {
        if (prev > maxAllowedWidth) {
          return maxAllowedWidth;
        }
        return prev;
      });
    };
    window.addEventListener('resize', handleWindowResize);
    return () => window.removeEventListener('resize', handleWindowResize);
  }, []);
  const [runtimeMenuOpen, setRuntimeMenuOpen] = useState(false);
  const [agentPickerOpen, setAgentPickerOpen] = useState(false);
  const [statusMenuOpen, setStatusMenuOpen] = useState(false);
  const [headerActionsOpen, setHeaderActionsOpen] = useState(false);
  const [searchOpen, setSearchOpen] = useState(false);

  // The chain's agents, shaped as a single palette conversation group so the
  // scoped search modal (opened from the header) lists them even before typing.
  // Sourced from the chain detail we already fetch — no extra request.
  const chainAgentGroups = useMemo(() => {
    const chain = chainDetailQuery.data?.chain;
    const members = (chain?.members || []) as any[];
    if (!chainId || members.length === 0) return [];
    const coordinator = String(chain?.coordinatorAgentInstanceId || '');
    return [{
      projectId: chainId,
      projectName: 'Agents in this chain',
      conversations: members
        .filter((m) => m?.agentInstanceId)
        .map((m) => ({
          conversationId: String(m.agentInstanceId),
          agentInstanceId: String(m.agentInstanceId),
          title: String(m.displayName || m.agentInstanceId),
          agentName: m.displayName ? String(m.displayName) : undefined,
          isCoordinator: String(m.agentInstanceId) === coordinator,
          runtimeStatus: m.runtimeStatus || undefined,
          activityStatus: m.activityStatus || undefined,
          unreadCount: 0,
        })),
    }];
  }, [chainDetailQuery.data, chainId]);

  // status / runtime / header-actions overlays are @ui Menu / Popover / Drawer —
  // they own their own outside-click / Esc / focus handling (no bespoke refs).
  const fileInputRef = useRef<HTMLInputElement | null>(null);


  // Mobile scroll hide/reveal chrome tracking
  const [chromeVisible, setChromeVisible] = useState(true);
  const lastScrollTopRef = useRef(0);

  const restoreChrome = useCallback(() => {
    setChromeVisible(true);
  }, []);

  const handleTranscriptScroll = useCallback(
    (event: UIEvent<HTMLDivElement>) => {
      if (!isMobile) return;

      const TOP_MARGIN = 60;
      const BOTTOM_MARGIN = 100;
      const target = event.currentTarget;
      const currentTop = target.scrollTop;
      const distanceToBottom = target.scrollHeight - currentTop - target.clientHeight;
      const isAtTop = currentTop <= TOP_MARGIN;
      const isAtBottom = distanceToBottom <= BOTTOM_MARGIN;

      if (isAtTop || isAtBottom) {
        restoreChrome();
        lastScrollTopRef.current = currentTop;
        return;
      }

      const delta = currentTop - lastScrollTopRef.current;
      if (Math.abs(delta) > 8) {
        setChromeVisible(false);
        lastScrollTopRef.current = currentTop;
      }
    },
    [isMobile, restoreChrome],
  );

  useEffect(() => {
    if (!isMobile) {
      restoreChrome();
    }
  }, [isMobile, restoreChrome]);

  useEffect(() => {
    if (typeof window !== 'undefined' && isMobile) {
      window.dispatchEvent(new CustomEvent('heimdall:mobile-chrome', { detail: { visible: chromeVisible } }));
    }
  }, [chromeVisible, isMobile]);

  useEffect(() => {
    return () => {
      if (typeof window !== 'undefined') {
        window.dispatchEvent(new CustomEvent('heimdall:mobile-chrome', { detail: { visible: true } }));
      }
    };
  }, []);
  const [renaming, setRenaming] = useState(false);
  const [titleDraft, setTitleDraft] = useState('');
  const [titleError, setTitleError] = useState('');

  // Bridge (device) is fixed per-instance. Provider/tier options follow
  // the instance bridge's capability matrix.
  const bridgeLabel = String(instanceBridge?.label || instanceBridge?.machine_hostname || instanceBridgeId || '');
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
    // System notices (e.g. "Agent has started and is ready.") are runtime chrome,
    // not conversation content — hide them from the transcript entirely.
    () => normalizeConversationMessages([...olderMessages, ...baseMessages, ...localMessages], agentId || agentInstanceId)
      .filter((message) => message.messageType !== 'system'),
    [olderMessages, baseMessages, localMessages, agentId, agentInstanceId],
  );
  const needsStart = runtimeNeedsStart(runtimeStatus);
  const runtimeStopping = runtimeIsStopping(runtimeStatus);
  const runtimeActionBusy = reconfigureState.isLoading || restartState.isLoading || stopState.isLoading;
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
    restoreChrome();
    lastScrollTopRef.current = 0;
  }, [conversationId, restoreChrome]);
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
  // (status / runtime / header-actions outside-click + Esc handling now lives in
  // the @ui Menu / Popover / Drawer primitives.)

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

  async function loadOlderMessages() {
    if (!olderCursor || olderMessagesState.isFetching) return;
    setError('');
    try {
      const data = await fetchOlderMessages({ conversationId, limit: 30, cursor: olderCursor }).unwrap();
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
    // A staged provider/tier change from the model switcher applies on the next
    // send: reconfigure + relaunch this instance before delivering the message.
    if (selectionChangesConfig && !runtimeActionBusy) {
      try { await applyReconfigure(); } catch (_err) { /* status surfaced via reconfigStatus */ }
    }
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

  // Default the panel's active tab based on what this conversation has: prefer
  // Tasks when linked to a chain, else Files when it has a project.
  function defaultPanelTab(): 'tasks' | 'files' | 'rundir' | 'jobs' {
    if (chainId) return 'tasks';
    if (projectId) return 'files';
    if (agentInstanceId) return 'rundir';
    return 'tasks';
  }

  // Sync ?panel=<tab> to route hash search on panel open/tab switch, or clean it up on close
  function syncUrlPanel(tab: 'tasks' | 'files' | 'rundir' | 'jobs' | null) {
    if (typeof window === 'undefined') return;
    try {
      const search = getRouteSearch();
      const params = new URLSearchParams(search.replace(/^\?/, ''));
      if (tab) {
        params.set('panel', tab);
        params.delete('sidebar');
      } else {
        params.delete('panel');
        params.delete('sidebar');
      }
      const nextSearch = params.toString();
      const nextHash = buildRouteHash(getRoutePathname(), nextSearch);
      if (window.location.hash !== nextHash) {
        window.history.replaceState(window.history.state || {}, '', nextHash);
      }
    } catch {
      // Best-effort URL query parameter synchronization
    }
  }

  // Top-right toggle: open to the default tab, or close if already open.
  function toggleRightPanel() {
    setHeaderActionsOpen(false);
    setRightPanel((cur) => {
      if (cur === 'closed') {
        const targetTab = readRightSidebarTab() || defaultPanelTab();
        writeRightSidebarOpen(true);
        writeRightSidebarTab(targetTab);
        syncUrlPanel(targetTab);
        return targetTab;
      } else {
        writeRightSidebarOpen(false);
        syncUrlPanel(null);
        return 'closed';
      }
    });
  }

  // Open the panel focused on a specific tab (e.g. the composer project chip
  // opens Files; a current-task link opens Tasks).
  function openRightPanel(tab: 'tasks' | 'files' | 'rundir' | 'jobs') {
    setHeaderActionsOpen(false);
    writeRightSidebarOpen(true);
    writeRightSidebarTab(tab);
    syncUrlPanel(tab);
    setRightPanel(tab);
  }

  function closeRightPanel() {
    writeRightSidebarOpen(false);
    syncUrlPanel(null);
    setRightPanel('closed');
  }

  useEffect(() => {
    const handleCloseSidebar = () => {
      setRightPanel('closed');
      writeRightSidebarOpen(false);
      syncUrlPanel(null);
    };
    window.addEventListener('heimdall:close-sidebar', handleCloseSidebar);
    return () => {
      window.removeEventListener('heimdall:close-sidebar', handleCloseSidebar);
    };
  }, []);

  function selectRightPanelTab(tab: 'tasks' | 'files' | 'rundir' | 'jobs') {
    writeRightSidebarOpen(true);
    writeRightSidebarTab(tab);
    syncUrlPanel(tab);
    setRightPanel(tab);
  }

  const handleResizerPointerDown = (e: React.PointerEvent) => {
    e.preventDefault();
    setIsDragging(true);

    const startX = e.clientX;
    const startWidth = sidebarWidth;
    const container = containerRef.current;
    const containerWidth = container ? container.getBoundingClientRect().width : window.innerWidth;
    const maxAllowedWidth = Math.max(RIGHT_SIDEBAR_MIN_WIDTH, containerWidth - CHAT_VIEW_MIN_WIDTH);

    let latestWidth = startWidth;

    const handlePointerMove = (moveEvent: PointerEvent) => {
      moveEvent.preventDefault();
      const deltaX = startX - moveEvent.clientX;
      const rawWidth = startWidth + deltaX;
      const clampedWidth = clampRightSidebarWidth(rawWidth, maxAllowedWidth);
      latestWidth = clampedWidth;
      setSidebarWidth(clampedWidth);
    };

    const handlePointerUp = (upEvent: PointerEvent) => {
      upEvent.preventDefault();
      setIsDragging(false);
      writeRightSidebarWidth(latestWidth);
      window.removeEventListener('pointermove', handlePointerMove);
      window.removeEventListener('pointerup', handlePointerUp);
      window.removeEventListener('pointercancel', handlePointerUp);
    };

    window.addEventListener('pointermove', handlePointerMove);
    window.addEventListener('pointerup', handlePointerUp);
    window.addEventListener('pointercancel', handlePointerUp);
  };

  const handleResizerDoubleClick = () => {
    setSidebarWidth(RIGHT_SIDEBAR_DEFAULT_WIDTH);
    writeRightSidebarWidth(RIGHT_SIDEBAR_DEFAULT_WIDTH);
  };

  const handleResizerKeyDown = (event: React.KeyboardEvent) => {
    const step = event.shiftKey ? 40 : 10;
    const containerWidth = containerRef.current?.getBoundingClientRect().width || window.innerWidth;
    const maxAllowedWidth = Math.max(RIGHT_SIDEBAR_MIN_WIDTH, containerWidth - CHAT_VIEW_MIN_WIDTH);

    if (event.key === 'ArrowLeft') {
      event.preventDefault();
      setSidebarWidth((prev) => {
        const next = clampRightSidebarWidth(prev + step, maxAllowedWidth);
        writeRightSidebarWidth(next);
        return next;
      });
    } else if (event.key === 'ArrowRight') {
      event.preventDefault();
      setSidebarWidth((prev) => {
        const next = clampRightSidebarWidth(prev - step, maxAllowedWidth);
        writeRightSidebarWidth(next);
        return next;
      });
    } else if (event.key === 'Home') {
      event.preventDefault();
      setSidebarWidth(RIGHT_SIDEBAR_MIN_WIDTH);
      writeRightSidebarWidth(RIGHT_SIDEBAR_MIN_WIDTH);
    } else if (event.key === 'End') {
      event.preventDefault();
      setSidebarWidth(maxAllowedWidth);
      writeRightSidebarWidth(maxAllowedWidth);
    } else if (event.key === 'Enter') {
      event.preventDefault();
      handleResizerDoubleClick();
    }
  };

  function renderConversationMessageBody(message: ChatMessage) {
    if (message.messageType === 'pane_capture') {
      const metadata = message.metadata || {};
      const status = message.messageStatus || 'complete';
      const lineCount = Number(metadata.line_count || metadata.lineCount || 0);
      return (
        <div data-debug-id={status === 'pending' ? `conversation-pane-capture-loading-${message.messageId}` : status === 'failed' ? `conversation-pane-capture-error-${message.messageId}` : `conversation-pane-capture-output-${message.messageId}`} className={`rounded-2xl border p-3 ${status === 'failed' ? 'border-red-400/30 bg-red-500/10 text-red-100' : 'border-sky-400/20 bg-sky-400/10 text-sky-50'}`}>
          <div className="mb-2 flex flex-wrap items-center gap-2 text-caption uppercase tracking-wide text-sky-100/70">
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
    // SYS-1: system notices (message_type='system', e.g. 'Agent has started and
    // is ready.') get a deliberately LOW-KEY, muted treatment — a small info
    // Icon + uppercase 'System' label + Markdown body — so they read as
    // ambient status, clearly distinct from user bubbles and the amber action
    // card without dominating the thread.
    if (message.messageType === 'system') {
      return (
        <div data-debug-id={`conversation-system-message-${message.messageId}`} className="rounded-xl border border-white/10 bg-white/[0.03] px-3 py-2 text-zinc-400">
          <div className="mb-1 flex items-center gap-1.5 text-[10px] font-semibold uppercase tracking-wider text-zinc-500">
            <Icon name="info" size={12} title="System message" />
            System
          </div>
          <div className="text-sm text-zinc-300">
            <Markdown source={message.body} compact copyAll={false} />
          </div>
        </div>
      );
    }
    // MSG-1/MSG-2: scheduled actions arrive as message_type='action'. Give them a
    // distinct card (left accent rail + border + header with an Icon badge, no
    // emoji) so they are recognizable at a glance versus normal chat, while
    // keeping the Markdown body + artifact previews intact.
    if (message.messageType === 'action') {
      const { summary, triggeredAt } = scheduleContextFromMetadata(message.metadata);
      return (
        <div data-debug-id={`conversation-action-message-${message.messageId}`} className="rounded-2xl border border-amber-400/25 border-l-2 border-l-amber-400/70 bg-amber-400/[0.06] p-3">
          <div className="mb-2 flex flex-wrap items-center gap-x-2 gap-y-1 text-caption uppercase tracking-wide text-amber-100/80">
            <span className="inline-flex items-center gap-1.5 font-semibold text-amber-200">
              <Icon name="clock" size={13} title="Scheduled action" />
              Scheduled action
            </span>
            {summary ? <span className="normal-case tracking-normal text-amber-100/60">{summary}</span> : null}
          </div>
          {triggeredAt ? (
            <div className="mb-2 text-caption text-amber-100/50">Ran on schedule: {triggeredAt}</div>
          ) : null}
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

  // Start/stop the agent from the runtime status popup.
  async function toggleRuntime() {
    if (!agentId || !agentInstanceId || runtimeActionBusy) return;
    setStatusMenuOpen(false);
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

  const tierMeta: Record<string, { icon: 'rocket' | 'spark' | 'zap'; blurb: string }> = {
    cheap: { icon: 'rocket', blurb: 'Fast, lower cost' },
    normal: { icon: 'rocket', blurb: 'Balanced' },
    smart: { icon: 'zap', blurb: 'Best reasoning' },
  };
  const pendingReconfig = selectionChangesConfig;
  const runtimeControls = (
    <div data-debug-id="conversation-runtime-controls" className="text-left">
      <input data-debug-id="conversation-provider-select" type="hidden" value={provider} readOnly />
      <input data-debug-id="conversation-tier-select" type="hidden" value={tier} readOnly />
      <div className="px-2 pb-1 pt-1 text-caption font-semibold uppercase tracking-wider text-zinc-500">Provider</div>
      {providerOptions.map((p) => {
        const selected = (provider || instanceProvider) === p;
        const current = instanceProvider === p;
        return (
          <button key={p} type="button" data-debug-id={`conversation-provider-option-${p}`} onClick={() => setProvider(p)} className="flex w-full items-center gap-3 rounded-xl px-2 py-2 text-left hover:bg-white/[0.06]">
            <span className="grid h-9 w-9 shrink-0 place-items-center rounded-lg bg-white/5 text-zinc-300"><Icon name="spark" size={16} /></span>
            <span className="min-w-0 flex-1">
              <span className="block truncate text-sm font-semibold text-white">{p}</span>
              <span className="block truncate text-xs text-zinc-500">{current ? 'current' : 'Provider'}</span>
            </span>
            {selected ? <Icon name="check" size={18} className="text-sky-400" /> : null}
          </button>
        );
      })}
      <div className="my-1.5 border-t border-white/10" />
      <div className="px-2 pb-1 pt-1 text-caption font-semibold uppercase tracking-wider text-zinc-500">Tier</div>
      {tierOptions.map((t) => {
        const selected = (tier || instanceTier) === t;
        const current = instanceTier === t;
        const meta = tierMeta[t] || { icon: 'rocket' as const, blurb: 'Model tier' };
        return (
          <button key={t} type="button" data-debug-id={`conversation-tier-option-${t}`} onClick={() => setTier(t)} className="flex w-full items-center gap-3 rounded-xl px-2 py-2 text-left hover:bg-white/[0.06]">
            <span className="grid h-9 w-9 shrink-0 place-items-center rounded-lg bg-white/5 text-zinc-300"><Icon name={meta.icon} size={16} /></span>
            <span className="min-w-0 flex-1">
              <span className="block truncate text-sm font-semibold text-white">{t}</span>
              <span className="block truncate text-xs text-zinc-500">{meta.blurb}{current ? ' — current' : ''}</span>
            </span>
            {selected ? <Icon name="check" size={18} className="text-sky-400" /> : null}
          </button>
        );
      })}
      <div className="mt-1.5 flex items-center gap-2 border-t border-white/10 px-2 pt-2 text-[12px] text-zinc-500">
        <Icon name="alert" size={14} className={pendingReconfig ? 'text-amber-400' : 'text-zinc-600'} />
        <span><span className={`font-semibold ${pendingReconfig ? 'text-amber-300' : 'text-zinc-400'}`}>Restarts the agent</span> — applies on next send.</span>
      </div>
      {reconfigStatus ? <div data-debug-id="conversation-reconfigure-status" className="px-2 pt-1 text-caption text-zinc-400">{reconfigStatus}</div> : null}
    </div>
  );

  // While the instance-id route is being resolved to its conversation (the
  // by-instance fetch), show a resolving state rather than the not-found card.
  if (!conversation && convQuery.isFetching) {
    return (
      <section data-debug-id="conversation-thread-page" className="w-full max-w-4xl rounded-[2rem] border border-white/10 bg-white/[0.04] p-6 text-left">
        <div data-debug-id="conversation-thread-resolving" className="grid min-h-[220px] place-items-center text-sm text-zinc-500">Loading conversation…</div>
      </section>
    );
  }

  if (!conversation && !convQuery.isFetching) {
    return (
      <section data-debug-id="conversation-thread-page" className="w-full max-w-4xl rounded-[2rem] border border-white/10 bg-white/[0.04] p-6 text-left">
        <h2 className="text-xl font-semibold text-white">Conversation not found</h2>
        <p className="mt-2 text-sm text-zinc-400">No conversation for instance <span className="font-mono">{routeInstanceId}</span> for this user.</p>
        <a data-debug-id="conversation-thread-back-btn" href="#/conversations/new" className="mt-4 inline-flex rounded-2xl bg-sky-400 px-4 py-2 text-sm font-bold text-black hover:bg-sky-300">Start a new conversation</a>
      </section>
    );
  }


  // The right sidebar: a Tasks / Files tabbed panel. Tabs only appear when the
  // conversation actually has that context (a chain for Tasks, a project for
  // Files). `isMobile` renders it as a full-width overlay with its own header.
  function renderRightPanel(isMobilePanel: boolean) {
    const hasTasks = Boolean(chainId);
    const hasFiles = Boolean(projectId);
    const hasRunDir = Boolean(agentInstanceId);
    const hasJobs = Boolean(agentInstanceId);
    // The two file-explorer tabs are labeled with a folder icon + the resource
    // name (project name for Files, instance display name for Run dir) and
    // truncate when long. Tasks keeps its fixed label.
    const instanceDisplayName = String(instance?.display_name || (instance as any)?.displayName || title || agentId || agentInstanceId || 'instance').trim();
    const filesLabel = projectName || 'Files';
    const active: 'tasks' | 'files' | 'rundir' | 'jobs' =
      rightPanel === 'files' && hasFiles ? 'files'
      : rightPanel === 'rundir' && hasRunDir ? 'rundir'
      : rightPanel === 'jobs' && hasJobs ? 'jobs'
      : rightPanel === 'tasks' && (hasTasks || convQuery.isLoading) ? 'tasks'
      : hasTasks ? 'tasks'
      : hasFiles ? 'files'
      : 'rundir';
    const tabBase = 'flex h-9 min-w-0 flex-1 items-center justify-center gap-1.5 rounded-lg px-1.5 text-xs font-semibold';
    return (
      <div data-debug-id="conversation-right-panel" className="flex h-full min-h-0 min-w-0 max-w-full flex-col overflow-x-hidden bg-[#0c0c0c]">
        <div data-debug-id="conversation-right-panel-tabs" className="flex shrink-0 items-center gap-1 border-b border-white/10 px-2 py-2">
          {hasTasks ? (
            <button type="button" data-debug-id="conversation-right-panel-tab-tasks" onClick={() => selectRightPanelTab('tasks')} aria-pressed={active === 'tasks' ? 'true' : 'false'} className={`${tabBase} ${active === 'tasks' ? 'bg-sky-400/20 text-sky-100' : 'text-zinc-400 hover:bg-white/5'}`}>
              <Icon name="tasks" size={15} />
              <span>Tasks</span>
              {chainProgress.total > 0 ? <span className="rounded-full bg-black/30 px-1.5 py-0.5 text-[10px] font-bold text-sky-100">{chainProgress.done}/{chainProgress.total}</span> : null}
            </button>
          ) : null}
          {hasFiles ? (
            <button type="button" title={filesLabel} data-debug-id="conversation-right-panel-tab-files" onClick={() => selectRightPanelTab('files')} aria-pressed={active === 'files' ? 'true' : 'false'} className={`${tabBase} ${active === 'files' ? 'bg-sky-400/20 text-sky-100' : 'text-zinc-400 hover:bg-white/5'}`}>
              <Icon name="folder" size={15} className="shrink-0" />
              <span className="truncate">{filesLabel}</span>
            </button>
          ) : null}
          {hasRunDir ? (
            <button type="button" title={`Run dir — ${instanceDisplayName}`} data-debug-id="conversation-right-panel-tab-rundir" onClick={() => selectRightPanelTab('rundir')} aria-pressed={active === 'rundir' ? 'true' : 'false'} className={`${tabBase} ${active === 'rundir' ? 'bg-sky-400/20 text-sky-100' : 'text-zinc-400 hover:bg-white/5'}`}>
              <Icon name="folder" size={15} className="shrink-0" />
              <span className="truncate">{instanceDisplayName}</span>
            </button>
          ) : null}
          {hasJobs ? (
            <button type="button" title="Background jobs" data-debug-id="conversation-right-panel-tab-jobs" onClick={() => selectRightPanelTab('jobs')} aria-pressed={active === 'jobs' ? 'true' : 'false'} className={`${tabBase} ${active === 'jobs' ? 'bg-sky-400/20 text-sky-100' : 'text-zinc-400 hover:bg-white/5'}`}>
              <Icon name="terminal" size={15} className="shrink-0" />
              <span className="truncate">Jobs</span>
            </button>
          ) : null}
        </div>
        <div className="min-h-0 flex-1 overflow-hidden">
          {active === 'files' && hasFiles ? (
            <ProjectFilesPanel
              projectId={projectId}
              bridgeId={instanceBridgeId}
              projectName={projectName}
              conversationKey={conversationId}
              onPublishComments={publishFileComments}
              onClose={closeRightPanel}
              isMobile={isMobilePanel}
            />
          ) : active === 'rundir' && hasRunDir ? (
            <InstanceRunDirPanel
              agentInstanceId={agentInstanceId}
              rootLabel={instanceDisplayName}
              conversationKey={conversationId}
              onPublishComments={publishFileComments}
              onClose={closeRightPanel}
              isMobile={isMobilePanel}
            />
          ) : active === 'jobs' && hasJobs ? (
            <ShellJobsPanel
              agentInstanceId={agentInstanceId}
              rootLabel={instanceDisplayName}
              onClose={closeRightPanel}
              isMobile={isMobilePanel}
            />
          ) : active === 'tasks' ? (
            chainId ? (
              <TaskChainOverview
                chainId={chainId}
                onClose={closeRightPanel}
                isMobile={isMobilePanel}
              />
            ) : (
              <div className="grid h-full place-items-center text-sm text-zinc-500">Loading tasks…</div>
            )
          ) : null}
        </div>
      </div>
    );
  }

  function renderComposer() {
    // Group running agents by project → chain, mirroring the sidebar: project
    // header labels, a subtle divider before every chain group except the first,
    // and amber-300 coordinators. The current agent keeps sky-400 + check and
    // always wins over the coordinator color.
    const pickerProjects = (liveProjects ?? []).filter((p) =>
      p.chains.some((c) => c.liveAgents.length > 0)
    );
    let pickerChainsRendered = 0;
    const agentPickerList = (
      <div className="max-h-64 overflow-y-auto py-1">
        {pickerProjects.length === 0 ? (
          <p className="px-3 py-2 text-xs text-zinc-500">No running agents</p>
        ) : (
          pickerProjects.map((project) => (
            <div key={project.projectId}>
              <div className="px-3 pt-2 pb-0.5 text-[11px] font-semibold uppercase tracking-wide text-zinc-500">
                {project.name || project.projectId}
              </div>
              {project.chains
                .filter((chain) => chain.liveAgents.length > 0)
                .map((chain) => {
                  const showDivider = pickerChainsRendered > 0;
                  pickerChainsRendered += 1;
                  return (
                    <div key={chain.chainId}>
                      {showDivider && <div className="mx-3 my-1 border-t border-white/5" />}
                      {chain.liveAgents.map((agent) => {
                        const isCurrent = agent.agentInstanceId === agentInstanceId;
                        const textClass = isCurrent
                          ? 'text-sky-400'
                          : agent.isCoordinator
                          ? 'text-amber-300'
                          : 'text-zinc-200';
                        return (
                          <button
                            key={agent.agentInstanceId}
                            type="button"
                            data-debug-id={`conversation-agent-picker-item-${agent.agentInstanceId}`}
                            className={`flex w-full items-center gap-2 rounded-lg px-3 py-2 text-left text-[13px] hover:bg-white/10 ${textClass}`}
                            onClick={() => {
                              setAgentPickerOpen(false);
                              window.location.hash = buildRouteHash('/conversations/' + encodeURIComponent(agent.agentInstanceId), '');
                            }}
                          >
                            <span className="min-w-0 truncate">{agent.displayName || agent.agentInstanceId}</span>
                            {isCurrent && <Icon name="check" size={14} className="ml-auto shrink-0 text-sky-400" />}
                          </button>
                        );
                      })}
                    </div>
                  );
                })}
            </div>
          ))
        )}
      </div>
    );
    const agentPickerTrigger = (
      <button
        type="button"
        data-debug-id="conversation-agent-picker-btn"
        aria-label="Current agent — click to switch"
        title={agentDisplayName || agentInstanceId || 'Agent'}
        aria-haspopup={isMobile ? 'dialog' : undefined}
        aria-expanded={isMobile ? (agentPickerOpen ? 'true' : 'false') : undefined}
        onClick={isMobile ? () => setAgentPickerOpen((open) => !open) : undefined}
        className="inline-flex h-9 items-center gap-1.5 rounded-xl px-2.5 text-[13px] text-zinc-300 hover:bg-white/10 hover:text-white"
      >
        <span className="max-w-[140px] truncate font-medium">{agentDisplayName || agentInstanceId || 'Agent'}</span>
        <Icon name="chevron-down" size={13} />
      </button>
    );
    return (
      <form
        onSubmit={submit}
        data-debug-id="conversation-composer-shell"
        data-mobile-shell-chrome="hide-on-focus"
        className={`w-full max-w-full shrink-0 transition-all duration-300 ease-in-out ${
          isMobile
            ? `fixed bottom-14 inset-x-0 z-20 px-3 pb-2 pt-0 ${
                !chromeVisible
                  ? 'translate-y-full opacity-0 pointer-events-none'
                  : 'translate-y-0 opacity-100 pointer-events-auto'
              }`
            : 'max-h-[800px] px-3 pb-4 pt-2 sm:px-6 sm:pb-6 sm:pt-3 translate-y-0 opacity-100 pointer-events-auto'
        }`}
      >
        {/* Push-only ephemeral ham-ctl activity bubbles for THIS instance, just
            above the composer (co-located with the working indicator). */}
        <AgentActivityBubbles instanceId={agentInstanceId} onOpenJobs={() => openRightPanel('jobs')} />
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
            {hasUploadingAttachments ? <div data-debug-id="conversation-attachment-uploading-hint" className="text-caption text-zinc-500">You can keep typing. Send unlocks when uploads finish.</div> : null}
            {hasFailedAttachments ? <div data-debug-id="conversation-attachment-failed-hint" className="text-caption text-red-300">Retry or remove failed uploads before sending.</div> : null}
          </div>
        )}
        <input ref={fileInputRef} data-debug-id="conversation-attach-input" type="file" multiple className="hidden" onChange={handleAttachmentInput} />
        {/* Composer card: immutable context row (bridge · project + status) on top,
            input in the middle, action toolbar (attach/terminal · model switcher ·
            send) on the bottom. */}
        <div data-debug-id="conversation-composer-card" className="rounded-[22px] border border-white/10 bg-[#161618] px-3 py-2.5 focus-within:border-sky-400/50 sm:px-4 sm:py-3">
          <div data-debug-id="conversation-composer-context" className="mb-2 flex flex-wrap items-center gap-x-2 gap-y-1 text-[12px] text-zinc-500">
            <span data-debug-id="conversation-composer-bridge-chip" className="inline-flex min-w-0 max-w-[45%] items-center gap-1.5" title={`Bridge: ${bridgeLabel || '—'} (fixed for this conversation)`}>
              <Icon name="lock" size={12} /><span className="min-w-0 truncate font-semibold text-zinc-400">{bridgeLabel || 'no bridge'}</span>
            </span>
            {projectId ? (
              <>
                <span className="opacity-40">·</span>
                <button type="button" data-debug-id="conversation-composer-project-chip" onClick={() => openRightPanel('files')} title={`Open project files — ${projectName}`} className="inline-flex min-w-0 max-w-[45%] items-center gap-1.5 rounded-md px-1 py-0.5 hover:bg-white/5 hover:text-zinc-300">
                  <Icon name="folder" size={13} /><span className="min-w-0 truncate font-semibold text-zinc-400">{projectName}</span>
                </button>
              </>
            ) : null}
            <div className="ml-auto shrink-0">
              <Menu
                side="top"
                align="end"
                label="Runtime status"
                open={statusMenuOpen}
                onOpenChange={setStatusMenuOpen}
                trigger={
                  <button type="button" data-debug-id="conversation-runtime-status-chip" title="Runtime status — start/stop the agent" className="inline-flex items-center gap-1.5 rounded-full border border-white/10 bg-white/5 px-2.5 py-1 text-caption text-zinc-300 hover:bg-white/10">
                    <StatusDot size="sm" tone={runtimeStatusToTone(runtimeStatus)} label={needsStart ? 'Stopped' : runtimeStopping ? 'Stopping' : runtimeStateLabel(runtimeStateFromStatus(runtimeStatus))} />
                    {needsStart ? 'Stopped' : (runtimeStopping ? 'Stopping…' : (runtimeStateFromStatus(runtimeStatus) === 'starting' ? 'Starting…' : 'Running'))}
                  </button>
                }
              >
                <Menu.Label>Runtime: {needsStart ? 'Stopped' : (runtimeStopping ? 'Stopping…' : (runtimeStateFromStatus(runtimeStatus) === 'starting' ? 'Starting…' : 'Running'))}</Menu.Label>
                <Menu.Item data-debug-id="conversation-runtime-status-toggle-btn" disabled={!agentInstanceId || runtimeActionBusy || runtimeStopping} onClick={() => void toggleRuntime()} className={needsStart ? 'text-success' : 'text-danger'}>
                  <Icon name={needsStart ? 'play' : 'stop'} size={15} />
                  <span>{needsStart ? 'Start agent' : 'Stop agent'}</span>
                </Menu.Item>
                {reconfigStatus ? <Menu.Label>{reconfigStatus}</Menu.Label> : null}
              </Menu>
            </div>
          </div>

          {/* Terminal pane panel above composer textarea when isPaneExpanded is true */}
          <AgentPaneComposerPanel
            agentInstanceId={agentInstanceId}
            isExpanded={isPaneExpanded}
            onClose={() => setIsPaneExpanded(false)}
            onToggleExpand={() => setIsPaneExpanded((prev) => !prev)}
            isActiveTab={true}
            runtimeStatus={runtimeStatus}
            className="mb-2.5"
          />

          <div className="relative">
            {mentionQuery !== null && (
              <AtMentionPopup
                query={mentionQuery}
                entities={filteredMentions}
                activeIndex={mentionIndex}
                onSelect={handleMentionSelect}
                onClose={() => setMentionQuery(null)}
              />
            )}
            <textarea
              ref={textareaRef}
              data-debug-id="conversation-composer-input"
              value={draft}
              onFocus={() => {
                restoreChrome();
              }}
              onChange={(e) => {
                restoreChrome();
                setDraft(e.target.value);
                const val = e.target.value;
                const pos = e.target.selectionStart ?? val.length;
                const before = val.slice(0, pos);
                const match = before.match(/@([^\s@]*)$/);
                if (match) {
                  setMentionQuery(match[1]);
                  setMentionIndex(0);
                } else {
                  setMentionQuery(null);
                }
              }}
              onKeyDown={(e) => {
                restoreChrome();
                if (mentionQuery !== null && filteredMentions.length > 0) {
                  if (e.key === 'ArrowDown') { e.preventDefault(); setMentionIndex((i) => (i + 1) % filteredMentions.length); return; }
                  if (e.key === 'ArrowUp') { e.preventDefault(); setMentionIndex((i) => (i - 1 + filteredMentions.length) % filteredMentions.length); return; }
                  if (e.key === 'Enter') { e.preventDefault(); handleMentionSelect(filteredMentions[mentionIndex]); return; }
                  if (e.key === 'Escape') { e.preventDefault(); setMentionQuery(null); return; }
                }
                if (e.key === 'Enter' && (e.metaKey || e.ctrlKey)) { e.preventDefault(); void submit(e as any); }
              }}
              onPaste={handleComposerPaste}
              rows={2}
              placeholder="Message the agent… (Cmd/Ctrl+Enter to send)"
              className="min-h-[44px] w-full resize-none bg-transparent px-1 py-1 text-base text-white outline-none placeholder:text-zinc-600 sm:text-sm"
            />
          </div>

          <div className="mt-1 flex items-center gap-1.5">
            <button data-debug-id="conversation-attach-btn" type="button" onClick={openAttachmentPicker} aria-label="Upload attachment" title="Upload attachment" className="grid h-9 w-9 shrink-0 place-items-center rounded-xl text-zinc-400 hover:bg-white/10 hover:text-white"><Icon name="plus" size={19} /></button>
            <button
              data-debug-id="conversation-request-pane-btn"
              type="button"
              aria-pressed={isPaneExpanded}
              title="Toggle terminal pane panel"
              aria-label="Toggle terminal pane panel"
              onClick={() => setIsPaneExpanded((prev) => !prev)}
              className={`grid h-9 w-9 shrink-0 place-items-center rounded-xl transition-colors ${
                isPaneExpanded
                  ? 'bg-sky-400/20 text-sky-300 border border-sky-400/40 hover:bg-sky-400/30'
                  : 'text-zinc-400 hover:bg-white/10 hover:text-white'
              }`}
            >
              <Icon name="terminal" size={18} />
            </button>

            <div className="flex-1" />

            {/* Agent chip: shows the current agent's display name, centered
                between the pane-capture controls and the model switcher. Clicking
                it opens a picker of all running agents to switch conversations.
                Desktop uses a Popover; mobile uses a bottom Drawer (matching the
                runtime menu pattern below). */}
            {!isMobile ? (
              <Popover
                side="top"
                align="start"
                label="Switch agent"
                open={agentPickerOpen}
                onOpenChange={setAgentPickerOpen}
                className="w-[min(92vw,320px)]"
                trigger={agentPickerTrigger}
              >
                {agentPickerList}
              </Popover>
            ) : (
              <>
                {agentPickerTrigger}
                <Drawer side="bottom" title="Switch agent" open={agentPickerOpen} onOpenChange={setAgentPickerOpen} data-debug-id="conversation-agent-picker-mobile-sheet">
                  <Drawer.Body>{agentPickerList}</Drawer.Body>
                </Drawer>
              </>
            )}

            <div className="flex-1" />

            {/* Model switcher: shows current provider · tier; opens the runtime
                menu to change them (which restarts the agent). */}
            {!isMobile ? (
              <Popover
                side="top"
                align="end"
                label="Runtime controls"
                open={runtimeMenuOpen}
                onOpenChange={setRuntimeMenuOpen}
                className="w-[min(92vw,430px)]"
                trigger={
                  <button type="button" data-debug-id="conversation-runtime-menu-btn" aria-label="Change provider and tier" title="Change provider / tier — restarts the agent" className="inline-flex h-9 items-center gap-1.5 rounded-xl border border-white/10 bg-white/5 px-2.5 text-[13px] text-zinc-100 hover:bg-white/10">
                    <span className="font-semibold">{instanceProvider || 'model'}</span>
                    <span className="hidden text-zinc-400 sm:inline">· {instanceTier || '—'}</span>
                    <Icon name="chevron-down" size={14} />
                  </button>
                }
              >
                {runtimeControls}
              </Popover>
            ) : (
              <>
                <button type="button" data-debug-id="conversation-runtime-menu-btn" aria-label="Change provider and tier" title="Change provider / tier — restarts the agent" aria-haspopup="dialog" aria-expanded={runtimeMenuOpen ? 'true' : 'false'} onClick={() => setRuntimeMenuOpen((open) => !open)} className="inline-flex h-9 items-center gap-1.5 rounded-xl border border-white/10 bg-white/5 px-2.5 text-[13px] text-zinc-100 hover:bg-white/10">
                  <span className="font-semibold">{instanceProvider || 'model'}</span>
                  <span className="hidden text-zinc-400 sm:inline">· {instanceTier || '—'}</span>
                  <Icon name="chevron-down" size={14} />
                </button>
                <Drawer side="bottom" title="Runtime controls" open={runtimeMenuOpen} onOpenChange={setRuntimeMenuOpen} data-debug-id="conversation-runtime-mobile-sheet">
                  <Drawer.Body>{runtimeControls}</Drawer.Body>
                </Drawer>
              </>
            )}

            <button data-debug-id="conversation-composer-send-btn" type="submit" disabled={sendDisabled} aria-label="Send message" title={hasUploadingAttachments ? 'Wait for uploads to finish before sending' : hasFailedAttachments ? 'Retry or remove failed uploads before sending' : 'Send'} className="grid h-9 w-9 shrink-0 place-items-center rounded-xl bg-sky-400 text-black hover:bg-sky-300 disabled:cursor-not-allowed disabled:bg-zinc-700 disabled:text-zinc-400"><Icon name="arrow-up" size={18} /></button>
          </div>
        </div>
      </form>
    );
  }

  return (
    <section data-debug-id="conversation-thread-page" className="flex h-full min-h-0 w-full max-w-full flex-col overflow-visible bg-[#090909] p-0 text-left">
      {/* Minimal top bar: centered title with inline rename + info popover ·
          right-sidebar toggle (right). The left nav sidebar has its own toggle.
          Runtime/model controls + immutable bridge/project context live in the
          composer. */}
      <header
        data-debug-id="conversation-thread-header"
        className={`flex shrink-0 items-center gap-2 px-3 sm:gap-3 sm:px-4 transition-all duration-300 ease-in-out ${
          isMobile
            ? `fixed top-0 inset-x-0 z-20 h-14 border-b border-white/10 bg-[#0c0c0c]/90 backdrop-blur-md ${
                !chromeVisible
                  ? '-translate-y-full opacity-0 pointer-events-none'
                  : 'translate-y-0 opacity-100 pointer-events-auto'
              }`
            : 'max-h-16 py-2 border-b border-white/10 translate-y-0 opacity-100 pointer-events-auto'
        }`}
      >
        <div className="hidden h-9 w-9 shrink-0 sm:block" aria-hidden="true" />

        <div className="flex min-w-0 flex-1 items-center justify-start gap-1.5 sm:justify-center">
          {renaming ? (
            <div className="flex min-w-0 flex-1 items-center gap-2">
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
              <button type="button" data-debug-id="conversation-thread-title-save-btn" aria-label="Save conversation title" title="Save" onClick={() => void saveConversationTitle()} disabled={updateTitleState.isLoading || !titleDraft.trim()} className="grid h-9 w-9 shrink-0 place-items-center rounded-xl bg-sky-400 text-black hover:bg-sky-300 disabled:opacity-50"><Icon name="check" size={16} /></button>
              <button type="button" data-debug-id="conversation-thread-title-cancel-btn" aria-label="Cancel title edit" title="Cancel" onClick={() => { setRenaming(false); setTitleError(''); setTitleDraft(editableTitle); }} className="grid h-9 w-9 shrink-0 place-items-center rounded-xl border border-white/10 bg-white/5 text-zinc-300 hover:bg-white/10"><Icon name="close" size={16} /></button>
            </div>
          ) : (
            <>
              <h2 data-debug-id="conversation-thread-title" className="truncate text-base font-semibold text-white sm:text-lg">{title}</h2>
              <button type="button" data-debug-id="conversation-thread-title-edit-btn" aria-label="Rename conversation" title="Rename" onClick={beginRenameFromHeader} className="grid h-7 w-7 shrink-0 place-items-center rounded-lg text-zinc-500 hover:bg-white/10 hover:text-zinc-200"><Icon name="pencil" size={14} /></button>
            </>
          )}
          {titleError ? <div data-debug-id="conversation-thread-title-error" className="mt-1 text-caption text-red-300">{titleError}</div> : null}
        </div>

        <button
          type="button"
          data-debug-id="conversation-search-btn"
          aria-label="Search this conversation and its task chain"
          title="Search this conversation & chain"
          onClick={() => setSearchOpen(true)}
          className="grid h-9 w-9 shrink-0 place-items-center rounded-xl text-zinc-400 hover:bg-white/10 hover:text-zinc-200"
        >
          <UiIcon name="search" size={16} />
        </button>

        <div className="shrink-0">
          <Menu
            align="end"
            label="Conversation details"
            open={headerActionsOpen}
            onOpenChange={setHeaderActionsOpen}
            trigger={
              <button type="button" data-debug-id="conversation-thread-overflow-menu-btn" aria-label="Conversation details" title="Details" className="grid h-9 w-9 shrink-0 place-items-center rounded-xl text-zinc-400 hover:bg-white/10 hover:text-zinc-200"><Icon name="info" size={16} /></button>
            }
          >
            <Menu.Item data-debug-id="conversation-thread-refresh-btn" onClick={refreshFromHeader}><Icon name="refresh" size={15} /><span>Refresh messages</span></Menu.Item>
            <Menu.Separator />
            <div data-debug-id="conversation-thread-overflow-details" role="presentation" className="px-3 py-1 text-caption leading-5 text-zinc-500">
              <div data-debug-id="conversation-thread-agent" className="truncate">Agent: {agentId || '—'}</div>
              <div data-debug-id="conversation-thread-instance" className="truncate">Instance: {agentInstanceId || '—'}</div>
              <div data-debug-id="conversation-thread-bridge" className="truncate">Bridge: {bridgeLabel || '—'}</div>
              <div className="flex gap-2"><span data-debug-id="conversation-thread-provider">Provider: {instanceProvider || '—'}</span><span data-debug-id="conversation-thread-tier">Tier: {instanceTier || '—'}</span></div>
              <div data-debug-id="conversation-thread-status">Status: {runtimeStatus || '—'}</div>
              {chainId ? <div data-debug-id="conversation-thread-chain" className="truncate">Chain: {chainId}</div> : null}
            </div>
          </Menu>
        </div>

        {(chainId || projectId || agentInstanceId) ? (
          <button type="button" data-debug-id="conversation-right-panel-toggle-btn" aria-label={rightPanel !== 'closed' ? 'Close side panel' : 'Open side panel'} title={rightPanel !== 'closed' ? 'Close panel' : 'Open panel'} aria-pressed={rightPanel !== 'closed' ? 'true' : 'false'} onClick={toggleRightPanel} className={`relative grid h-9 w-9 shrink-0 place-items-center rounded-xl ${rightPanel !== 'closed' ? 'text-sky-300' : 'text-zinc-400 hover:bg-white/10 hover:text-zinc-200'}`}>
            <Icon name="panel-right" size={18} />
            {rightPanel === 'closed' && chainId && chainProgress.total > 0 ? <span data-debug-id="conversation-right-panel-toggle-progress" className="absolute -right-1 -top-1 rounded-full bg-sky-400 px-1 text-[9px] font-bold leading-4 text-black">{chainProgress.done}/{chainProgress.total}</span> : null}
          </button>
        ) : null}
      </header>

      {/* Subtle Top-Right Floating Toggle Button */}
      {isMobile && !chromeVisible && rightPanel === 'closed' && Boolean(chainId || projectId || agentInstanceId) ? (
        <button
          type="button"
          data-debug-id="conversation-floating-panel-toggle-btn"
          aria-label="Open side panel"
          title="Open panel"
          onClick={toggleRightPanel}
          className="fixed top-2.5 right-2.5 z-30 bg-black/50 backdrop-blur border border-white/10 text-zinc-400 hover:text-white rounded-xl h-9 w-9 grid place-items-center transition-opacity duration-200"
        >
          <Icon name="panel-right" size={18} />
          {chainId && chainProgress.total > 0 ? (
            <span
              data-debug-id="conversation-floating-panel-toggle-progress"
              className="absolute -right-1 -top-1 rounded-full bg-sky-400 px-1 text-[9px] font-bold leading-4 text-black"
            >
              {chainProgress.done}/{chainProgress.total}
            </span>
          ) : null}
        </button>
      ) : null}

      {/* Subtle Bottom Floating Pills */}
      {isMobile && !chromeVisible ? (
        <div className="fixed bottom-9 inset-x-0 flex justify-center items-center gap-2 z-30 pointer-events-none">
          <button
            type="button"
            data-debug-id="conversation-floating-agent-pill"
            aria-label="Switch agent"
            title={agentDisplayName || agentInstanceId || 'Agent'}
            onClick={() => setAgentPickerOpen(true)}
            className="pointer-events-auto bg-[#161618]/90 backdrop-blur-md border border-white/10 px-3 py-1.5 rounded-full text-xs font-medium text-zinc-300 shadow-lg flex items-center gap-1.5 hover:bg-white/10 hover:text-white transition-all duration-200"
          >
            <span className="max-w-[160px] truncate">{agentDisplayName || agentInstanceId || 'Agent'}</span>
            <Icon name="chevron-down" size={13} />
          </button>
          <button
            type="button"
            data-debug-id="conversation-floating-reply-pill"
            aria-label="Reply"
            title="Reply"
            onClick={() => {
              restoreChrome();
            }}
            className="pointer-events-auto bg-[#161618]/90 backdrop-blur-md border border-white/10 px-3 py-1.5 rounded-full text-xs font-medium text-zinc-300 shadow-lg flex items-center gap-1.5 hover:bg-white/10 hover:text-white transition-all duration-200"
          >
            Reply
          </button>
        </div>
      ) : null}

      <CommandPalette
        open={searchOpen}
        onClose={() => setSearchOpen(false)}
        onNavigate={(route) => { window.location.hash = buildRouteHash(route, ''); setSearchOpen(false); }}
        actions={[]}
        conversationGroups={chainAgentGroups}
        scope={{ chainId, conversationId, label: chainDetailQuery.data?.chain?.title || title }}
      />

      {(() => {
        const transcript = (
          <div data-debug-id="conversation-thread-transcript" className="h-full w-full min-h-0 min-w-0 max-w-full flex-1 overflow-x-hidden p-0 sm:px-4 sm:py-3">
            <ChatMessageList
              conversationKey={conversationId}
              messages={chatMessages}
              debugPrefix="conversation-thread"
              focusMessageId={focusMessageId}
              hasMore={olderHasMore && Boolean(olderCursor)}
              loadingOlder={olderMessagesState.isFetching}
              onLoadOlder={loadOlderMessages}
              onScroll={handleTranscriptScroll}
              formatTimestamp={formatMessageTimestamp}
              getDeliveryStatus={deliveryStatusFor}
              agentIsWorking={isWorking}
              renderMessageBody={({ message }) => renderConversationMessageBody(message)}
              wrapperClassName="relative h-full min-h-0 min-w-0 max-w-full overflow-hidden overflow-x-hidden"
              scrollClassName="chat-scrollbar h-full min-h-0 max-w-full space-y-3 overflow-y-auto overflow-x-hidden rounded-none bg-[#090909] px-1 pt-16 pb-4 sm:space-y-4 sm:rounded-[18px] sm:px-4 sm:py-4"
              emptyState={messagesQuery.isFetching ? (
                <div data-debug-id="conversation-thread-empty-state" className="grid h-full min-h-[220px] place-items-center p-6 text-sm text-zinc-500">Loading messages…</div>
              ) : (
                <div data-debug-id="conversation-thread-empty-state" className="flex h-full min-h-[220px] flex-col items-center justify-center gap-4 p-6 text-center">
                  <div data-debug-id="conversation-thread-empty-avatar" className="grid h-16 w-16 place-items-center rounded-full bg-white/[0.06] text-2xl font-semibold text-zinc-300">
                    {(agentDisplayName || 'A').trim().charAt(0).toUpperCase()}
                  </div>
                  <h3 data-debug-id="conversation-thread-empty-title" className="text-2xl font-semibold text-white">{agentDisplayName || 'New conversation'}</h3>
                  {agentPersona ? (
                    <p data-debug-id="conversation-thread-empty-persona" className="max-w-xl whitespace-pre-line text-[15px] leading-relaxed text-zinc-400">{agentPersona}</p>
                  ) : (
                    <p data-debug-id="conversation-thread-empty-persona" className="max-w-md text-[15px] text-zinc-500">Say something below to get started.</p>
                  )}
                </div>
              )}
            />
          </div>
        );

        const panelOpen = rightPanel !== 'closed' && Boolean(chainId || projectId || agentInstanceId);

        return (
          <div ref={containerRef} className="relative flex h-full min-h-0 w-full max-w-full flex-col overflow-x-hidden sm:flex-row">
            {/* Mobile (< 768px): the panel is a full-width overlay; the chat is hidden behind it when panel is open. */}
            {panelOpen ? (
              <div className="absolute inset-0 z-30 flex h-full w-full min-h-0 max-w-full flex-col overflow-x-hidden bg-[#0c0c0c] sm:hidden">
                {renderRightPanel(true)}
              </div>
            ) : null}

            {/* Chat pane on the left: expands to full width when sidebar is closed or on mobile */}
            <div
              className="flex h-full w-full min-h-0 min-w-0 flex-1 flex-col sm:min-w-[380px]"
            >
              {transcript}
              {renderComposer()}
            </div>

            {/* Desktop (>= 768px) vertical resizer divider between chat view and right sidebar */}
            {panelOpen ? (
              <div
                role="separator"
                aria-orientation="vertical"
                aria-label="Resize right sidebar"
                aria-valuenow={sidebarWidth}
                aria-valuemin={RIGHT_SIDEBAR_MIN_WIDTH}
                tabIndex={0}
                data-debug-id="conversation-right-panel-resizer"
                onPointerDown={handleResizerPointerDown}
                onDoubleClick={handleResizerDoubleClick}
                onKeyDown={handleResizerKeyDown}
                className={`hidden sm:flex group relative w-1.5 cursor-col-resize shrink-0 select-none items-center justify-center border-l border-white/10 hover:border-sky-400/50 hover:bg-sky-400/10 active:bg-sky-400/20 z-10 ${isDragging ? 'bg-sky-400/20 border-sky-400' : ''}`}
              >
                <div className={`h-8 w-0.5 rounded-full ${isDragging ? 'bg-sky-400' : 'bg-white/20 group-hover:bg-sky-300'}`} />
              </div>
            ) : null}

            {/* Desktop (>= 768px) right sidebar with smooth 200ms open/close transition & overflow clipping */}
            <div
              data-debug-id="conversation-right-panel-resizable-container"
              style={{ width: panelOpen ? `${sidebarWidth}px` : '0px' }}
              className={`hidden sm:flex overflow-hidden shrink-0 flex-col ${isDragging ? 'transition-none' : 'transition-[width] duration-200 ease-in-out'}`}
            >
              <div
                style={{ width: `${sidebarWidth}px` }}
                className="h-full flex flex-col min-w-[360px]"
              >
                {renderRightPanel(false)}
              </div>
            </div>
          </div>
        );
      })()}
    </section>
  );
}
