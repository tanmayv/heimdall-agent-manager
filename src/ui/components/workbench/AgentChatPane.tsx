import { FloatingComposerDock, FloatingComposerForm, FloatingComposerCard } from '../chat/FloatingComposerDock';
import { PlainMessageBody } from '../chat/PlainMessageBody';
import { formatMessageTimestamp } from '../chat/formatMessageTimestamp';
import { ComposerAttachmentTray } from '../chat/ComposerAttachmentTray';
import { useComposerAttachments } from '../chat/useComposerAttachments';
import { VoiceRecorderPanel, useVoiceMessage } from '../chat/VoiceRecorderPanel';
import { hasLiveAgentOutput, selectAgentOutputTurns } from '../../store/agentOutputSlice';
import AgentOutputBlocks from '../chat/AgentOutputBlocks';
import React, {
  type FormEvent,
  useCallback,
  useEffect,
  useLayoutEffect,
  useMemo,
  useReducer,
  useRef,
  useState,
} from 'react';
import { lifecycleResult, useAgentLifecycle, type LifecycleResult } from '../../hooks/useAgentLifecycle';
import { useDispatch, useSelector, useStore } from 'react-redux';
import { desktopUpdateFrozen, desktopUpdatePreparation } from '../../utils/desktopUpdatePreparation';
import { writeClientStorageChecked, writeComposerDraftChecked } from '../../utils/clientPersistence';
import {
  CommandPalette,
  Icon as UiIcon,
  IconButton as UiIconButton,
  Menu,
  Modal,
  StatusDot,
  runtimeStateFromStatus,
  runtimeStateLabel,
  runtimeStatusToTone,
} from '@ui';
import {
  useFetchConversationQuery,
  useFetchConversationMessagesQuery,
  useLazyFetchConversationMessagesQuery,
  useUpdateConversationTitleMutation,
  useRequestPaneCaptureMutation,
  useSendConversationMessageMutation,
  useAnswerConversationQuestionsMutation,
  useMarkConversationReadMutation,
  useFetchSendNowStateQuery,
  useSendNowMutation,
} from '../../api/endpoints/chats';
import { QueuedMessages, UnreadSendNow } from '../chat/QueuedMessages';
import {
  acpDeliveryLabel,
  newSendNowRequestId,
  noticeSendNowPhase,
  orderTranscript,
  parseAcpDelivery,
  placementFor,
  sendNowErrorText,
  sendNowTooltip,
  trayView,
  unreadTrayState,
  unreadUserRows,
  type SendNowBatch,
} from '../chat/acpDelivery';
import {
  useFetchAgentInstanceQuery,
  useFetchAgentIdentityQuery,
  useListInstanceReconfigurationsQuery,
  useCancelInstanceConfigurationMutation,
  type InstanceReconfiguration,
  reconfigurationSettled,
  reconfigurationBlocksInput,
  isCancelledReconfiguration,
  agentErrorText,
} from '../../api/endpoints/agents';
import { useFetchProjectQuery } from '../../api/endpoints/projects';
import { useGetAgentsLiveQuery } from '../../api/endpoints/agentsLive';
import {
  normalizeBridgeCapabilities,
  useBridgeProviderStatus,
  useDiscoverBridgeProvidersMutation,
  useInstallAcpAdapterMutation,
  useListBridgeProvidersQuery,
  useListBridgesQuery,
  useRefreshBridgeModelsMutation,
  useUpdateBridgeMutation,
  type AcpAvailabilityFix,
  type BridgeCapability,
} from '../../api/endpoints/bridgeSupport';
import {
  useFetchChainTasksQuery,
  useFetchTaskChainConversationQuery,
  useLazyFetchTaskChainConversationQuery,
  useFetchTaskChainDetailQuery,
  useUpdateTaskChainMutation,
} from '../../api/endpoints/tasks';
import { chainTargetId } from '../../utils/paneTarget';
import { selectActiveVaultKey } from '../../store/vaultSlice';
import { getExpectedUserId } from '../../utils/expectedUser';
import { vaultSendBlock } from '../../utils/vaultSendGuard';
import type { AuxContent } from '../../store/auxTabId';
import { buildRouteHash } from '../../utils/appLocation';
import { buildConversationHash } from '../../utils/conversationUrl';
import { useRegisterActions } from '../../services/shortcuts/useRegisterActions';
import { readComposerDraft, writeComposerDraft } from '../../utils/clientPersistence';
import { conversationConfigurationIssues } from '../../utils/conversationConfigurationValidity';
import {
  isVaultArmored,
  containsVaultArmored,
  decryptVaultText,
  decryptEmbeddedVaultTokens,
  maskVaultArmored,
} from '../../utils/vaultContent';
import { ArtifactAttachmentPreview } from '../ArtifactAttachmentPreview';
import Icon from '../Icon';
import Markdown from '../Markdown';
import type { MarkdownTextSelection } from '../MarkdownBody';
import { PREVIOUS_CONTEXT_MESSAGE_TYPE, PreviousContextBlock } from '../chat/PreviousContextBlock';
import QuoteSelectionPopover from '../chat/QuoteSelectionPopover';
import ComposerContextChips from '../chat/ComposerContextChips';
import { addComposerQuote, removeComposerQuote, consumeComposerQuotes, selectComposerQuotes } from '../../store/composerContextSlice';
import { quoteLimitError, quotedMessageBody, type QuoteContext } from '../../utils/quoteContext';
import { VaultText, useDecryptedText } from '../vault/VaultText';
import { resolveRenameTarget } from './renameTarget';
import { decryptPaneCaptureBody } from '../../utils/vaultChats';
import { VAULT_LOCKED_MARKER } from '../../utils/vaultCrypto';
import { actionMessageContext } from '../actions/actionModel';
import { actionRunTime } from '../chat/actionRunTime';
import { useActionsAccess } from '../actions/useActionsAccess';
import { TaskChainSelectorModal } from '../chains/TaskChainSelectorModal';
import { useIsMobile } from '../shell/responsive';
import { chromeIconButtonSizeClass } from '../shell/shellChrome';
import { navigateTo, shellViewHref } from '../shells/shellModel';
import LiveToolActivity from '../extension/LiveToolActivity';
import AgentActivityBubbles from '../chat/AgentActivityBubbles';
import AtMentionPopup, { type MentionEntity } from '../chat/AtMentionPopup';
import ChatMessageList from '../chat/ChatMessageList';
import { useSettleWithoutReveal, type StreamRevealOptions } from '../chat/streamReveal';
import InstanceReconfigurationProgress from '../chat/InstanceReconfigurationProgress';
import { MessageComposerInput, MessageComposerActions, MessageComposerStatus, useComposerDockInset, useComposerExpanded } from '../chat/MessageComposer';
import RuntimeConfigurationOptions from '../chat/RuntimeConfigurationOptions';
import { AgentSettingsPanel } from '../agentSettings/AgentSettingsPanel';
import { RuntimeSection, providerDisplayName, runtimeSectionView } from '../agentSettings/RuntimeSection';
import { BridgeSection } from '../agentSettings/BridgeSection';
import { ModelSection } from '../agentSettings/ModelSection';
import { ConnectionSection } from '../agentSettings/ConnectionSection';
import { PermissionsSection } from '../agentSettings/PermissionsSection';
import { ApplyFooter } from '../agentSettings/ApplyFooter';
import { applyFooterView, useApplyAgentSettings } from '../agentSettings/useApplyAgentSettings';
import { acpAvailabilityCopy } from '../agentSettings/acpAvailabilityCopy';
import {
  applyBlockedReason,
  bridgeRowsView,
  draftDiff,
  lastCheckedAt,
  providerOptionsFromStatus,
  reconcileDraftProviders,
  reduceAgentDraft,
  type AgentConfig,
  type AgentDraftAction,
  type RuntimeTransport,
} from '../agentSettings/agentSettingsDraft';
import { projectEditHref } from '../projects/projectModel';
import { useAgentSettingsPanelState } from '../agentSettings/useAgentSettingsPanelState';
import { useFetchExperimentsQuery } from '../../api/endpoints/settings';
import { AGENT_SETTINGS_PANEL_EXPERIMENT_KEY, resolveExperimentFlag } from '../settings/experimentFlags';
import { usePaneDeferredRefresh, usePaneMarkRead, usePanePollPolicy, usePaneVisible, visiblePollInterval } from './paneVisibility';
import {
  CONVERSATION_MESSAGES_READ_EVENT,
  applyReadReceipt,
  reconcileOlderPages,
  type ConversationMessagesRead,
} from '../../api/conversationMessageEvents';
import { effectivePermissionMode, permissionToggleRequest, permissionToggleState } from './permissionToggleModel';
import { type TaskLike } from '../chat/chainTaskInference';
import { groupTranscriptMessages, isAgentStartMessage } from '../chat/transcriptGrouping';
import type { ChatDeliveryStatus, ChatMessage } from '../chat/types';
import type { SplitDirection } from '../../tiling/types';
import { replaceVaultTokens } from '../../utils/vaultCrypto.ts';
import { appendArtifactLinks } from '../../utils/artifactUpload';
import { ActionTray, NeedYouPill, useActionTrayItems, useSendTrayMode } from '../attention/ActionTray';
import {
  INITIAL_TRAY_STATE,
  TRAY_MODE_COPY,
  needYouPillVisible,
  trayReducer,
  trayVisible,
} from '../attention/actionTrayModel';

export const COMPOSER_DRAFT_KEY = 'heimdall:composer:draft';

/**
 * For user-initiated refreshes only; data freshness otherwise comes from tag
 * invalidation. RTK Query throws (error #38) when refetching a query that has not
 * started, e.g. one still skipped while its arguments load.
 */
// Fallback cadence for an unsettled reconfiguration this pane accepted (focused and on
// screen only). The hub announces every phase; this only bounds a missed frame.
export const RECONFIGURATION_ACTIVE_FALLBACK_MS = 15000;

export function refetchIfStarted(query: { isUninitialized: boolean; refetch: () => unknown }) {
  if (!query.isUninitialized) void query.refetch();
}

export interface AgentChatPaneProps {
  /** The agent instance shown (a chain pane passes its resolved coordinator). */
  agentInstanceId: string;
  /**
   * Set when this Main pane is addressed by chain (`chain:<id>`, REQ-TV2-7): the
   * chain context comes from the target instead of being inferred from the
   * conversation, and the chain selector swaps the pane's TARGET.
   */
  chainTarget?: { chainId: string; title?: string };
  paneId?: string;
  focusMessageId?: string;
  isActiveTab?: boolean;
  isMobile?: boolean;
  /** Main: true when this chat is the only Main pane. */
  isSinglePane?: boolean;
  projectVcsEnabled?: boolean;
  /**
   * 'main' (default): a Main workspace leaf with the full header
   * (`<Project> / <Task chain> / <agent>`, ⋮, [≡]).
   * 'auxSubagent': an aux sub-agent chat tab, transcript + composer ONLY.
   */
  variant?: 'main' | 'auxSubagent';
  /** Opens (or focuses) a tab in the current aux strip. */
  onOpenAuxTab?: (content: AuxContent, title?: string) => void;
  /**
   * Agent/chain switcher: swap this Main pane's TARGET (an agent instance id or
   * `chain:<id>`; deduped by the host).
   */
  onSwitchAgent?: (targetId: string, title?: string) => void;
  /** Opens a pane target (e.g. a selected chain's `chain:<id>`) in a new pane beside this one. */
  onOpenAgentInSplit?: (targetId: string, direction: 'right' | 'bottom') => void;
  /** Requests that this pane open its task-chain picker for a shortcut placement. */
  chainSelectorRequest?: {
    id: number;
    placement: 'replace' | 'right' | 'bottom';
  };
  onChainSelectorRequestHandled?: (requestId: number) => void;
  onSplitPane?: (direction: SplitDirection) => void;
  onReplaceWithNew?: () => void;
  onClosePane?: () => void;
  /** Main: this pane is the focused one (shows its close ✕ in split view). */
  isFocusedPane?: boolean;
  /** Inline before the breadcrumb (hidden-sidebar toggle + app name, top-left pane). */
  headerLeading?: React.ReactNode;
  /** Inline just before the ⋮ menu (update-available badge, top-right pane). */
  headerTrailing?: React.ReactNode;
  /** Inline at the far right (the side-panel toggle, top-right pane). */
  headerEnd?: React.ReactNode;
  /** The drawer reaches the window edge, but only some docked panes sit under the right chrome. */
  settingsPanelChrome?: { rightInset: number; overPane: boolean };
}

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

const modelOrder = ['cheap', 'normal', 'smart'];

function errMsg(err: any, fallback: string): string {
  if (!err) return fallback;
  if (typeof err === 'string') return err;
  return String(
    err.message || err.error || err.data?.error?.message || err.data?.message || fallback,
  );
}

const EMPTY_DELIVERY: ChatDeliveryStatus = { glyph: '', label: '', tone: '' };
/** Composer width below which the model pill shows only the provider icon. */
const COMPACT_MODEL_PILL_WIDTH = 300;

function bridgeId(bridge: any): string {
  return String(bridge?.bridge_id || bridge?.bridgeId || bridge?.id || '');
}
function msgId(m: Message, i: number): string {
  return String(m.message_id || m.messageId || m.id || `idx-${i}`);
}
function messageIdOf(m: Message): string {
  return String(m.message_id || m.messageId || m.id || '');
}
function msgDir(m: Message): string {
  return String(m.direction || '');
}

function extractMessageArtifactIds(message: Message): string[] | undefined {
  const seen = new Set<string>();
  const out: string[] = [];
  const push = (value: any) => {
    const raw =
      typeof value === 'object' && value !== null
        ? String(value.artifact_id || value.artifactId || value.id || '')
        : String(value || '');
    const id = raw.replace(/^artifact:\/\//i, '').trim();
    if (!id || seen.has(id)) return;
    seen.add(id);
    out.push(id);
  };

  const direct = (message as any).artifact_ids ?? (message as any).artifactIds;
  if (Array.isArray(direct)) direct.forEach(push);

  const artifactIdsJson =
    (message as any).artifact_ids_json ?? (message as any).artifactIdsJson;
  if (typeof artifactIdsJson === 'string' && artifactIdsJson.trim()) {
    try {
      const parsed = JSON.parse(artifactIdsJson);
      if (Array.isArray(parsed)) parsed.forEach(push);
    } catch {
      // ignore invalid json
    }
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

// REQ-PIN-1: only a row this pane just appended optimistically pins to the top; a poll
// that delivers the server copy of a message must not replay the send animation.
function isOptimisticSend(message: { messageId: string }): boolean {
  return message.messageId.startsWith('local_');
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

function optimisticPaneCaptureMessage(
  conversationId: string,
  requestId: string,
  agentInstanceId: string,
): Message {
  return {
    message_id: `local_${requestId}`,
    conversation_id: conversationId,
    direction: 'agent_to_user',
    body: 'Requesting pane capture...',
    message_type: 'pane_capture',
    message_status: 'pending',
    metadata: {
      pane_capture_request_id: requestId,
      agent_instance_id: agentInstanceId,
      width: 80,
      line_limit: 120,
    },
    created_unix_ms: Date.now(),
    sending: true,
  };
}

function sentMessageFromResult(result: any): Message | null {
  const candidate =
    result?.message || result?.chat_message || result?.chatMessage || result;
  if (!candidate || typeof candidate !== 'object') return null;
  const id = String(candidate.message_id || candidate.messageId || candidate.id || '');
  const body = String(candidate.body || '');
  if (!id && !body) return null;
  return { ...candidate, sending: false } as Message;
}

// REQ-ENC-1: the send ack echoes the stored row, whose body is vault ciphertext while the
// vault is unlocked. The user's own bubble keeps the text they typed instead, so it never
// shows `vault:v2:` until the decrypted refetch lands.
function ownSentBody(ackBody: unknown, sendBody: string): string {
  const body = typeof ackBody === 'string' ? ackBody : '';
  if (!body || isVaultArmored(body) || containsVaultArmored(body)) return sendBody;
  return body;
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

function PaneCaptureOutput({ body: rawBody, messageId }: { body: string; messageId: string }) {
  const preRef = useRef<HTMLPreElement | null>(null);
  const activeKey = useSelector(selectActiveVaultKey);
  const armored = isVaultArmored(rawBody);
  // A sealed capture shows the locked marker until it decrypts; never the ciphertext.
  const [body, setBody] = useState<string>(armored ? VAULT_LOCKED_MARKER : rawBody);

  useEffect(() => {
    let mounted = true;
    if (!armored) {
      setBody(rawBody);
      return;
    }
    setBody(VAULT_LOCKED_MARKER);
    void decryptPaneCaptureBody(rawBody, activeKey).then((text) => {
      if (mounted) setBody(text);
    });
    return () => {
      mounted = false;
    };
  }, [rawBody, armored, activeKey]);

  useEffect(() => {
    const node = preRef.current;
    if (!node) return;
    const scrollToBottom = () => {
      node.scrollTop = node.scrollHeight;
    };
    scrollToBottom();
    const frame =
      typeof window !== 'undefined' ? window.requestAnimationFrame(scrollToBottom) : 0;
    return () => {
      if (frame && typeof window !== 'undefined') window.cancelAnimationFrame(frame);
    };
  }, [body, messageId]);

  return (
    <pre
      ref={preRef}
      data-debug-id={`conversation-pane-capture-pre-${messageId}`}
      className="chat-scrollbar max-h-[420px] max-w-full overflow-auto whitespace-pre-wrap rounded-xl border border-subtle bg-surface p-3 font-mono text-xs leading-5 text-primary"
    >
      {body}
    </pre>
  );
}

export function ThreadMessageBody({ body, onQuote, quoteDisabledReason = '', reveal }: {
  body: string; onQuote?: (selectedText: string) => Promise<void>; quoteDisabledReason?: string;
  /** Live-reply reveal from ChatMessageList (chat/streamReveal.ts). */
  reveal?: StreamRevealOptions;
}) {
  const [selection, setSelection] = useState<MarkdownTextSelection | null>(null);
  const dismiss = useCallback(() => setSelection(null), []);
  const [decryptedFor, setDecryptedFor] = useState('');
  // The body whose decrypt failed while unlocked. It renders as-is, without the reveal's
  // hold, so a failure never leaves the body hidden.
  const [failedFor, setFailedFor] = useState('');

  const isArmored = isVaultArmored(body);
  const containsArmored = containsVaultArmored(body);
  const hasVault = isArmored || containsArmored;
  const activeKey = useSelector(selectActiveVaultKey);
  const vaultUnlocked = useSelector((state: any) => Boolean(state.vault?.isUnlocked));
  const [decrypted, setDecrypted] = useState<string | null>(null);

  useEffect(() => {
    let mounted = true;
    if (!hasVault) {
      setDecrypted(body);
      setDecryptedFor(body);
      return;
    }
    if (!activeKey || !vaultUnlocked) {
      setDecrypted(null);
      setDecryptedFor('');
      return;
    }
    const decryptPromise = isArmored
      ? decryptVaultText(body, activeKey)
      : decryptEmbeddedVaultTokens(body, activeKey);
    decryptPromise
      .then((res) => {
        if (mounted) { setDecrypted(res); setDecryptedFor(body); }
      })
      .catch(() => {
        if (mounted) { setDecrypted(null); setDecryptedFor(''); setFailedFor(body); }
      });
    return () => {
      mounted = false;
    };
  }, [body, hasVault, isArmored, activeKey, vaultUnlocked]);

  useEffect(() => { setSelection(null); }, [body, activeKey, vaultUnlocked]);
  const quoteReady = Boolean(onQuote && vaultUnlocked && activeKey && (!hasVault || (decryptedFor === body && decrypted !== null && !containsVaultArmored(decrypted))));
  const locked = hasVault && (!activeKey || !vaultUnlocked);
  const decryptFailed = hasVault && !locked && failedFor === body;
  // A locked or undecryptable body drops the reveal, so settle the live reply right away.
  useSettleWithoutReveal(locked || decryptFailed ? reveal : undefined);
  if (isArmored && locked) {
    return <VaultText value={body} as="div" />;
  }
  if (containsArmored && locked) {
    const sanitized = replaceVaultTokens(body, '[🔒 Encrypted]');
    return <Markdown source={sanitized} variant="conversation" compact copyAll={false} />;
  }
  // REQ-ENC-2: never paint `vault:v2:`. While a vault body decrypts, keep this row's
  // previous plaintext (e.g. the optimistic send's text) or show the mask; a failed open
  // shows the mask.
  const ready = decrypted !== null && decryptedFor === body;
  const plain = (text: string | null) => text !== null && !isVaultArmored(text) && !containsVaultArmored(text);
  const source = !hasVault ? body
    : plain(decrypted) && (ready || !decryptFailed) ? decrypted! : maskVaultArmored(body);
  return <>
    <Markdown source={source} variant="conversation" compact copyAll={false}
      onTextSelectionChange={quoteReady ? setSelection : undefined}
      // Hold the reveal until a vault body has decrypted, so ciphertext never shows.
      reveal={reveal && !decryptFailed ? { ...reveal, hold: reveal.hold || (hasVault && !ready) } : undefined} />
    {quoteReady && selection ? <QuoteSelectionPopover selection={selection} onDismiss={dismiss}
      disabledReason={quoteDisabledReason} onQuote={() => onQuote!(selection.selectedText)} /> : null}
  </>;
}

function parseMessageMetadata(message: Message): any {
  const raw =
    (message as any).metadata ??
    (message as any).metadata_json ??
    (message as any).metadataJson;
  if (!raw) return {};
  if (typeof raw === 'object') return raw;
  try {
    return JSON.parse(String(raw));
  } catch {
    return {};
  }
}

function capModels(cap: BridgeCapability | undefined): string[] {
  if (!cap) return [];
  return Array.isArray(cap.models) ? cap.models.filter(Boolean) : [];
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
  return (
    coerceUnixMs(message.created_unix_ms ?? message.createdUnixMs) ||
    dateStringToUnixMs(message.created_at || message.createdAt)
  );
}


function looksLikeInternalId(value: string): boolean {
  return /^(agt|inst|chat|conv|usr|brg|task|chain|proj|art)_[a-z0-9]/i.test(
    String(value || '').trim(),
  );
}

function conversationAgentLabel(conversation: any): string {
  const candidates = [
    conversation?.agent_name,
    conversation?.agentName,
    conversation?.agent_display_name,
    conversation?.agentDisplayName,
    conversation?.agent_slug,
    conversation?.agentSlug,
  ];
  for (const value of candidates) {
    const trimmed = String(value || '').trim();
    if (trimmed && !looksLikeInternalId(trimmed)) return trimmed;
  }
  return '';
}

function conversationDisplayTitle(
  conversation: any,
  agentId: string,
  agentInstanceId: string,
  conversationId: string,
): string {
  const rawTitle = String(conversation?.title || '').trim();
  const agentLabel = conversationAgentLabel(conversation);
  if (
    !rawTitle ||
    rawTitle === agentId ||
    rawTitle === agentInstanceId ||
    rawTitle === conversationId ||
    looksLikeInternalId(rawTitle)
  ) {
    return agentLabel || agentId || conversationId;
  }
  return rawTitle;
}

function runtimeNeedsStart(status: string): boolean {
  const normalized = String(status || '').toLowerCase();
  return (
    !normalized ||
    normalized === 'stopped' ||
    normalized === 'failed' ||
    normalized === 'unreachable'
  );
}

function runtimeIsStopping(status: string): boolean {
  return String(status || '').toLowerCase() === 'stopping';
}

function deliveryStatusFor(message: ChatMessage): ChatDeliveryStatus {
  if (!message.isUser) return EMPTY_DELIVERY;
  if (message.sending) return { glyph: '…', label: 'Sending', tone: 'text-muted' };
  if (message.deliveryFailedUnixMs > 0)
    return {
      glyph: '!',
      label: message.deliveryError || 'Delivery failed',
      tone: 'text-danger',
    };
  // ACP rows: the Hub's delivery status. Their legacy read_at is bridge admission, not Read.
  if (message.acpDelivery) return acpDeliveryLabel(message.acpDelivery);
  if (message.readUnixMs > 0) return { glyph: '✓✓', label: 'Read', tone: 'text-success' };
  if (message.deliveredUnixMs > 0)
    return { glyph: '✓', label: 'Delivered', tone: 'text-muted' };
  return { glyph: '✓', label: 'Sent', tone: 'text-faint' };
}

// `keyFor` maps a server id to the React key of the optimistic row it replaced
// (REQ-PIN-2), so the sent bubble keeps one key across the send ack.
function normalizeConversationMessages(rows: Message[], agentLabel: string, keyFor: (id: string) => string | undefined = () => undefined): ChatMessage[] {
  const seen = new Set<string>();
  // Newest-page data supersedes carried older rows with the same durable ID,
  // including answered state and freshness. Display sorting happens afterwards.
  const canonicalRows = new Map(rows.map((row, index) => [msgId(row, index), row]));
  return [...canonicalRows.values()]
    .map((message, index) => {
      const id = msgId(message, index);
      const direction = msgDir(message);
      const createdUnixMs = messageCreatedUnixMs(message);
      const sender = String(
        message.sender_agent_instance_id || message.senderAgentInstanceId || '',
      );
      const messageType = String(
        (message as any).message_type || (message as any).messageType || 'text',
      );
      // previous_context is stored inbound (user_to_agent) so the restarted
      // agent reads it, but the agent wrote it: never show it as a user bubble.
      const isUser = direction === 'user_to_agent' && messageType !== PREVIOUS_CONTEXT_MESSAGE_TYPE;
      const authorLabel = isUser
        ? 'you'
        : messageType === 'system'
        ? ''
        : sender || agentLabel || 'agent';
      const artifactIds = extractMessageArtifactIds(message);
      return {
        order: index,
        chatMessage: {
          key: keyFor(id) ?? (id || `${direction}-${createdUnixMs}-${index}`),
          messageId: id,
          body: String(message.body || ''),
          isUser,
          createdUnixMs,
          deliveredUnixMs:
            coerceUnixMs(message.delivered_unix_ms ?? message.deliveredUnixMs) ||
            dateStringToUnixMs(message.delivered_at ?? message.deliveredAt),
          readUnixMs:
            coerceUnixMs(message.read_unix_ms ?? message.readUnixMs) ||
            dateStringToUnixMs(message.read_at ?? message.readAt),
          deliveryFailedUnixMs:
            coerceUnixMs(
              message.delivery_failed_unix_ms ?? message.deliveryFailedUnixMs,
            ) ||
            dateStringToUnixMs(message.delivery_failed_at ?? message.deliveryFailedAt),
          deliveryError: String(message.delivery_error || message.deliveryError || ''),
          sending: Boolean(message.sending),
          authorLabel,
          artifactIds,
          messageType,
          messageStatus: String(
            (message as any).message_status || (message as any).messageStatus || 'complete',
          ),
          metadata: parseMessageMetadata(message),
          isLatestMessage: (message as any).is_latest_message === true,
          optionsRevision: (message as any).optionsRevision,
          questionAnswer: (message as any).question_answer,
          acpDelivery: isUser ? parseAcpDelivery((message as any).acp_delivery) : null,
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

export function AgentChatPane({
  agentInstanceId: routeInstanceId,
  chainTarget,
  paneId,
  focusMessageId,
  isActiveTab = true,
  isMobile: explicitIsMobile,
  isSinglePane = true,
  variant = 'main',
  projectVcsEnabled = false,
  onOpenAuxTab,
  onSwitchAgent,
  onOpenAgentInSplit,
  chainSelectorRequest,
  onChainSelectorRequestHandled,
  onSplitPane,
  onReplaceWithNew,
  onClosePane,
  isFocusedPane = false,
  headerLeading,
  headerTrailing,
  headerEnd,
  settingsPanelChrome,
}: AgentChatPaneProps) {
  const dispatch = useDispatch<any>();
  const reduxStore = useStore<any>();
  const [resolveQuoteCoordinator] = useLazyFetchTaskChainConversationQuery();
  const [normalSendBusy, setNormalSendBusy] = useState(false);
  const sendingRef = useRef(false);
  const mountedRef = useRef(true);
  useEffect(() => { mountedRef.current = true; return () => { mountedRef.current = false; }; }, []);
  const renderTarget = chainTarget?.chainId ? chainTargetId(chainTarget.chainId) : routeInstanceId;
  const currentTargetRef = useRef(renderTarget);
  const routeGeneration = useRef(0);
  if (currentTargetRef.current !== renderTarget) routeGeneration.current++;
  currentTargetRef.current = renderTarget;
  const isMobileHook = useIsMobile();
  const isMobile = explicitIsMobile ?? isMobileHook;
  const isAuxSubagent = variant === 'auxSubagent';
  // On screen (not behind a maximised pane, an off-screen mobile page or a hidden
  // tab). Hidden panes keep their caches but do not poll or mark read.
  const paneVisible = usePaneVisible();
  // Steady polls are retired: conversation, messages, instance, live tree, bridges and
  // chain detail all refresh from owner-scoped user-WS events (wsInvalidation.ts), and
  // initial/reconnect/gap recovery refetches mounted queries. The policy still tracks
  // 401/403/404/410 so the active-operation fallback below stops on a gone instance.
  const pollPolicy = usePanePollPolicy(paneVisible);

  const convQuery = useFetchConversationQuery(
    { conversationId: '', agentInstanceId: routeInstanceId },
    { skip: !routeInstanceId },
  );
  const conversation = convQuery.data?.conversation || null;
  const conversationId = String(
    conversation?.conversation_id || conversation?.conversationId || '',
  );
  const messagesQuery = useFetchConversationMessagesQuery(
    { conversationId },
    { skip: !conversationId },
  );
  // Message events that reach only hidden panes are deferred (paneDeferral.ts); the
  // newest page refetches once when this pane is shown again (after any older request
  // still in flight settles).
  usePaneDeferredRefresh(conversationId, paneVisible, messagesQuery.refetch, messagesQuery);
  const [fetchOlderMessages, olderMessagesState] = useLazyFetchConversationMessagesQuery();
  const [updateConversationTitle, updateTitleState] = useUpdateConversationTitleMutation();
  const [updateTaskChain, updateChainState] = useUpdateTaskChainMutation();
  const [requestPaneCapture, requestPaneCaptureState] = useRequestPaneCaptureMutation();
  const [sendMessage] = useSendConversationMessageMutation();
  const [answerQuestions] = useAnswerConversationQuestionsMutation();
  const [markRead] = useMarkConversationReadMutation();
  const configurationIntent = useRef<{ signature: string; key: string } | null>(null);
  function configurationIntentKey(request: object) {
    const signature = JSON.stringify(request);
    if (configurationIntent.current?.signature !== signature) {
      configurationIntent.current = {
        signature,
        key: globalThis.crypto?.randomUUID?.() || `apply-${Date.now()}-${Math.random().toString(36).slice(2)}`,
      };
    }
    return configurationIntent.current.key;
  }
  function finishConfigurationIntent(result: LifecycleResult) {
    // Only ambiguous delivery may replay this intent. Acceptance identifies the
    // operation; applying again after it fails is a new attempt, even if the
    // destination never committed and the configuration revision is unchanged.
    if (result.status !== 'failed' || (result.httpStatus !== undefined && result.httpStatus < 500)) {
      configurationIntent.current = null;
    }
  }
  const lifecycle = useAgentLifecycle({ inline: result => { if (result) setReconfigStatus(result.message); } });

  const agentId = String(conversation?.agent_id || conversation?.agentId || '');
  const agentInstanceId = String(
    conversation?.agent_instance_id || conversation?.agentInstanceId || routeInstanceId,
  );
  // A chain-addressed pane knows its chain from the target; an agent pane infers
  // it from its conversation.
  const chainId = String(
    chainTarget?.chainId || conversation?.chain_id || conversation?.chainId || '',
  );
  const ownTargetId = chainTarget?.chainId ? chainTargetId(chainTarget.chainId) : agentInstanceId;
  const quoteTargetId = chainTargetId(chainId);
  const quotes = useSelector((state: any) => selectComposerQuotes(state, ownTargetId));
  const quoteEpoch = useSelector((state: any) => state.composerContext?.epoch ?? 0);
  const quoteFocusRevision = useSelector((state: any) => state.composerContext?.focusTarget === ownTargetId ? state.composerContext.focusRevision : 0);
  const quoteVaultKey = useSelector(selectActiveVaultKey);
  const quoteVaultUnlocked = useSelector((state: any) => Boolean(state.vault?.isUnlocked));
  // REQ-SWFIX-SEND-1: blocked (draft kept) while this account's vault is not ready or a
  // previous account's key is still installed.
  const deviceVaultState = useSelector((state: any) => state.deviceVault);
  const vaultSendBlocked = vaultSendBlock({ activeKey: quoteVaultKey, isUnlocked: quoteVaultUnlocked, currentUserId: getExpectedUserId(), deviceVault: deviceVaultState });
  const isMultiPane = !isSinglePane;
  const title = conversationDisplayTitle(
    conversation,
    agentId,
    agentInstanceId,
    conversationId,
  );

  const configurationInputBlockedRef = useRef(false);

  const chainTasksQuery = useFetchChainTasksQuery({ chainId }, { skip: !chainId });
  const chainDetailQuery = useFetchTaskChainDetailQuery(
    { chainId },
    { skip: !chainId },
  );
  const chainProgress = useMemo(() => {
    const allTasks: TaskLike[] = (chainDetailQuery.data?.chain?.tasks ||
      chainTasksQuery.data?.tasks ||
      []) as TaskLike[];
    const tasks = allTasks.filter((t: TaskLike) => t.status !== 'cancelled');
    const total = tasks.length;
    const done = tasks.filter(
      (t: TaskLike) => t.status === 'validated_good' || t.status === 'completed',
    ).length;
    return { total, done };
  }, [chainDetailQuery.data, chainTasksQuery.data]);
  const rawTitle = String(conversation?.title || '').trim();
  const editableTitle = rawTitle && !looksLikeInternalId(rawTitle) ? rawTitle : title;
  const chainTitle = String(
    chainDetailQuery.data?.chain?.title || chainTarget?.title || '',
  ).trim();
  // REQ-CR-1: Rename targets the chain title (decrypted, as VaultText shows it) when
  // this conversation belongs to a chain, else the conversation title.
  const decryptedChainTitle = useDecryptedText(chainTitle);
  const renameTarget = resolveRenameTarget({
    chainId,
    decryptedChainTitle: decryptedChainTitle.text,
    chainTitleUnreadable: decryptedChainTitle.isLocked || decryptedChainTitle.isDecrypting,
    conversationTitle: editableTitle,
  });
  const renameSeed = renameTarget.seed;
  // Legacy instance link (REQ-TV2-7): when this instance was its chain's
  // coordinator and has since been replaced, offer the chain-addressed URL.
  const chainConversationQuery = useFetchTaskChainConversationQuery(
    { chainId },
    { skip: !chainId },
  );
  const replacedCoordinator = Boolean(
    !chainTarget &&
      chainId &&
      agentInstanceId &&
      chainConversationQuery.data?.coordinatorAgentInstanceId &&
      chainConversationQuery.data.coordinatorAgentInstanceId !== agentInstanceId &&
      chainConversationQuery.data.replacedCoordinatorInstanceIds.includes(agentInstanceId),
  );
  const openCurrentChainCoordinator = () => {
    const target = chainTargetId(chainId);
    if (!target) return;
    if (onSwitchAgent) onSwitchAgent(target);
    else if (typeof window !== 'undefined') {
      window.location.hash = buildConversationHash([target]);
    }
  };

  // agent_instance/* events carry the complete instance summary (status, config,
  // current task, run_count/started_at for restarts) and are patched into this entry.
  const instanceQuery = useFetchAgentInstanceQuery(
    { instanceId: agentInstanceId },
    { skip: !agentInstanceId },
  );
  const instance = instanceQuery.data?.instance || null;
  const { data: liveProjects } = useGetAgentsLiveQuery(undefined);
  const agentIdentityQuery = useFetchAgentIdentityQuery({ agentId }, { skip: !agentId });
  const agentIdentity = agentIdentityQuery.data?.agent || null;
  const agentDisplayName = String(
    agentIdentity?.name || conversationAgentLabel(conversation) || agentId || '',
  ).trim();
  const agentPersona = String(
    agentIdentity?.instructions ||
      agentIdentity?.persona ||
      agentIdentity?.template_persona ||
      '',
  ).trim();
  const instanceProvider = String(instance?.provider || '');
  const instanceModel = String(instance?.model || '');
  const instanceBridgeId = String(instance?.bridge_id || instance?.bridgeId || '');
  const projectId = String(
    instance
      ? instance.project_id ?? instance.projectId ?? ''
      : conversation?.project_id || conversation?.projectId || '',
  );
  const projectQuery = useFetchProjectQuery({ projectId }, { skip: !projectId });
  const projectName = String(
    projectQuery.data?.project?.name ||
      projectQuery.data?.project?.display_name ||
      projectId ||
      '',
  ).trim();
  const conversationRuntimeStatus = String(
    conversation?.runtime_status || conversation?.runtimeStatus || '',
  );
  const runtimeStatus = String(
    instance?.runtime_status || instance?.runtimeStatus || conversationRuntimeStatus || '',
  );
  const startupStatus = String(
    instance?.startup_status ||
      instance?.startupStatus ||
      conversation?.startup_status ||
      conversation?.startupStatus ||
      '',
  ).toLowerCase();
  const isStarting =
    startupStatus === 'starting' || runtimeStateFromStatus(runtimeStatus) === 'starting';
  const activityStatus = String(
    instance?.activity_status || instance?.activityStatus || '',
  ).toLowerCase();
  const isWorking =
    runtimeStateFromStatus(runtimeStatus) === 'live' &&
    (activityStatus === 'active' ||
      activityStatus === 'busy' ||
      activityStatus === 'working');

  const [stagedBridgeId, setStagedBridgeId] = useState<string | null>(null);
  const [provider, setProvider] = useState('');
  const [providerProfile, setProviderProfile] = useState('');
  const [model, setModel] = useState('');
  // Agent settings panel draft (T6): transport and bypass staged like bridge/provider/
  // model above; null follows the running instance.
  const [stagedTransport, setStagedTransport] = useState<RuntimeTransport | null>(null);
  const [stagedBypass, setStagedBypass] = useState<boolean | null>(null);
  // A bridge picked in the panel whose provider status has not answered yet: once it
  // does, the draft falls back to an installed provider (reconcileDraftProviders).
  const [draftBridgeCheck, setDraftBridgeCheck] = useState<string | null>(null);
  const [runtimeMenuOpen, setRuntimeMenuOpen] = useState(false);
  // Agent settings: the docked panel (agent_settings_panel experiment, default on) or,
  // with the experiment off or not loaded yet, the previous modal.
  const experimentsQuery = useFetchExperimentsQuery();
  const settingsPanelEnabled =
    !isAuxSubagent &&
    resolveExperimentFlag(experimentsQuery.data?.flags, AGENT_SETTINGS_PANEL_EXPERIMENT_KEY) === 'enabled';
  const settingsPanel = useAgentSettingsPanelState({ enabled: settingsPanelEnabled });
  const openAgentSettings = () => {
    if (settingsPanelEnabled) settingsPanel.setOpen(true);
    else setRuntimeMenuOpen(true);
  };
  // The Runtime card's uptime ticks while the panel is open.
  const [panelNow, setPanelNow] = useState(() => Date.now());
  useEffect(() => {
    if (!settingsPanel.open) return;
    setPanelNow(Date.now());
    const timer = setInterval(() => setPanelNow(Date.now()), 30_000);
    return () => clearInterval(timer);
  }, [settingsPanel.open]);
  // Either settings surface is open: provider status is fetched live only then.
  const settingsOpen = runtimeMenuOpen || settingsPanel.open;
  const editingRuntime =
    settingsOpen ||
    stagedBridgeId !== null ||
    Boolean(provider && provider !== instanceProvider) ||
    Boolean(providerProfile && providerProfile !== (instance?.provider_profile || instanceProvider)) ||
    Boolean(model && model !== instanceModel);
  // Bridge status/update/revoke events patch or invalidate this list; opening the
  // runtime picker fetches only the selected bridge's provider status.
  const bridgesQuery = useListBridgesQuery(undefined);
  const bridges = bridgesQuery.data?.bridges || [];
  const instanceBridgeRow = useMemo(
    () => bridges.find((b: any) => bridgeId(b) === instanceBridgeId),
    [bridges, instanceBridgeId],
  );
  // Provider status for this pane's bridge only (it gates sending); polled only while
  // the runtime is being edited.
  const instanceProviders = useBridgeProviderStatus(instanceBridgeRow, { live: editingRuntime });
  const instanceBridge = instanceProviders.bridge;

  const baseMessages: Message[] = messagesQuery.data?.messages || [];
  const [olderMessages, setOlderMessages] = useState<Message[]>([]);
  const [olderCursor, setOlderCursor] = useState('');
  const [olderHasMore, setOlderHasMore] = useState(false);

  // Per-agent composer draft state isolated by routeInstanceId, with fallback to COMPOSER_DRAFT_KEY
  const loadedDraftAgentIdRef = useRef<string>(routeInstanceId);
  const [draft, setDraft] = useState<string>(() => readComposerDraft(routeInstanceId));
  const updateDraftRef = useRef(draft);
  updateDraftRef.current = draft;

  useEffect(() => {
    if (desktopUpdateFrozen()) return;
    if (loadedDraftAgentIdRef.current !== routeInstanceId) {
      const nextDraft = readComposerDraft(routeInstanceId);
      loadedDraftAgentIdRef.current = routeInstanceId;
      setDraft(nextDraft);
      return;
    }
    writeComposerDraft(routeInstanceId, draft);
  }, [routeInstanceId, draft]);

  const updateDraft = useCallback(
    (value: string) => {
      if (desktopUpdateFrozen()) return;
      updateDraftRef.current = value;
      setDraft(value);
      if (loadedDraftAgentIdRef.current === routeInstanceId) {
        writeComposerDraft(routeInstanceId, value);
      }
      if (typeof window !== 'undefined') {
        try {
          if (value) {
            window.localStorage.setItem(COMPOSER_DRAFT_KEY, value);
          } else {
            window.localStorage.removeItem(COMPOSER_DRAFT_KEY);
          }
        } catch {
          // ignore storage errors
        }
      }
    },
    [routeInstanceId],
  );

  // REQ-AT-1: task items waiting on the user in this conversation (its chain, or
  // the agent instance without one) replace the composer with the action tray.
  // Answer / Request changes borrow the composer with their own draft
  // (`trayDraft`), so the persisted chat draft is never touched.
  const trayItemList = useActionTrayItems(
    { chainId, agentInstanceId },
    { skip: isAuxSubagent || !agentInstanceId },
  );
  const [trayState, dispatchTray] = useReducer(trayReducer, INITIAL_TRAY_STATE);
  const [trayDraft, setTrayDraft] = useState('');
  const quotedTrayDrafts = useRef(new Map<string, string>());
  useEffect(() => { quotedTrayDrafts.current.clear(); }, [quoteEpoch, quoteVaultKey]);
  const [trayNotice, setTrayNotice] = useState('');
  const sendTrayMode = useSendTrayMode();
  const trayItemIds = useMemo(() => trayItemList.map((item) => item.card_id), [trayItemList]);
  const trayItemIdsKey = trayItemIds.join('\n');
  const draftEmpty = !draft.trim() && quotes.length === 0;
  useEffect(() => {
    dispatchTray({ type: 'items', ids: trayItemIds, draftEmpty });
  }, [trayItemIdsKey]); // eslint-disable-line react-hooks/exhaustive-deps
  const trayMode = trayState.mode;
  // Only task items borrow the composer (agent blockers act in place).
  const trayModeFound = trayMode
    ? trayItemList.find((item) => item.card_id === trayMode.cardId)
    : undefined;
  const trayModeItem = trayModeFound?.kind === 'task' ? trayModeFound : undefined;
  const showTray = trayVisible(trayState, trayItemList.length);
  useEffect(() => {
    if (!trayNotice) return;
    const id = setTimeout(() => setTrayNotice(''), 3500);
    return () => clearTimeout(id);
  }, [trayNotice]);
  // Leaving a mode clears its draft.
  useEffect(() => {
    if (!trayMode) setTrayDraft('');
  }, [trayMode]);

  // Context surfaces (files, terminal, ...) open as tabs in the aux dock.
  const openAux = useCallback(
    (content: AuxContent, auxTitle?: string) => {
      onOpenAuxTab?.(content, auxTitle);
    },
    [onOpenAuxTab],
  );

  const handleOpenPtyTab = useCallback(() => {
    const label = agentDisplayName || editableTitle || agentInstanceId;
    openAux({ type: 'agentPty', agentInstanceId }, `${label} terminal`);
  }, [agentDisplayName, editableTitle, agentInstanceId, openAux]);

  const [mentionQuery, setMentionQuery] = useState<string | null>(null);
  const [mentionIndex, setMentionIndex] = useState(0);
  const textareaRef = useRef<HTMLTextAreaElement>(null);
  useEffect(() => {
    if (!quoteFocusRevision) return;
    // Quote explicitly opens normal chat; preserve a borrowed task answer for re-entry.
    if (trayMode) quotedTrayDrafts.current.set(trayMode.kind + ':' + trayMode.cardId, trayDraft);
    dispatchTray({ type: 'show_composer' });
    const frame = requestAnimationFrame(() => textareaRef.current?.focus({ preventScroll: true }));
    return () => cancelAnimationFrame(frame);
  }, [quoteFocusRevision]);

  const composerContainerRef = useRef<HTMLFormElement | HTMLDivElement | null>(null);
  // REQ-FROST-1: the composer dock floats over the transcript; its measured height becomes
  // the transcript's bottom inset so the last message stays reachable. The morphing card
  // animates that height, so the inset is synced in the same frame (useComposerDockInset).
  const composerDockRef = useRef<HTMLDivElement | null>(null);
  const composerDockHeight = useComposerDockInset(composerDockRef, {
    insetDebugId: 'conversation-thread-bottom-inset',
    jumpDebugId: 'conversation-thread-jump-latest-btn',
    resetKey: `${isMobile}:${conversation?.conversation_id || conversation?.conversationId || ''}:${agentInstanceId}`,
  });
  const [error, setError] = useState('');
  const { attachments, setAttachments, uploadAttachment, handlePaste: handleComposerPaste } = useComposerAttachments({
    metadata: { originKind: 'conversation_chat', originRef: conversationId, projectId, agentId, agentInstanceId, chainId },
    namePrefix: 'conversation-attachment',
    canUpload: () => !desktopUpdateFrozen() && !configurationInputBlocked && !sendingRef.current,
    onUploadStart: () => setError(''),
    errorText: err => errMsg(err, 'Upload failed'),
  });
  // REQ-VOICE-4: Send on a recording uploads it as an audio artifact, then submits the message.
  const voice = useVoiceMessage({
    attachments,
    uploadAttachment,
    onReadyToSend: () => { void submit({ preventDefault() {} } as FormEvent); },
  });
  const updateFilePickerPending = useRef(false);
  // Mirrors updateFilePickerPending as render state: the native file chooser holds the
  // morphing composer open until it reports a choice or a cancel.
  const [filePickerOpen, setFilePickerOpen] = useState(false);
  const updateBlockers = useRef({ attachments, trayDraft, quotes, trayModeItem, voiceActive: voice.active });
  updateBlockers.current = { attachments, trayDraft, quotes, trayModeItem, voiceActive: voice.active };
  useEffect(() => desktopUpdatePreparation.register({
    blocked: () => sendingRef.current || updateFilePickerPending.current || updateBlockers.current.attachments.length > 0
      || updateBlockers.current.voiceActive || updateBlockers.current.quotes.length > 0 || Boolean(updateBlockers.current.trayModeItem) || Boolean(updateBlockers.current.trayDraft.trim())
      || [...quotedTrayDrafts.current.values()].some(value => Boolean(value.trim())),
    flush: () => {
      const latest = textareaRef.current?.value ?? updateDraftRef.current;
      writeComposerDraftChecked(routeInstanceId, latest);
      writeClientStorageChecked(COMPOSER_DRAFT_KEY, latest || null);
    },
  }), [routeInstanceId]);
  const [localMessages, setLocalMessages] = useState<Message[]>([]);
  useEffect(() => { setLocalMessages(current => current.filter(item => !(item as any).hasQuoteContext)); }, [quoteEpoch, quoteVaultKey]);

  const settingsEditedRef = useRef(false);
  const [acceptedOperation, setAcceptedOperation] =
    useState<InstanceReconfiguration | null>(null);
  const [reconfigStatus, setReconfigStatus] = useState('');
  const [isSmallComposer, setIsSmallComposer] = useState(false);

  const mentionEntities = useMemo<MentionEntity[]>(() => {
    const items: MentionEntity[] = [];
    for (const proj of liveProjects ?? []) {
      const pName = String(proj.name || proj.projectId || '');
      items.push({
        type: 'project',
        id: String(proj.projectId || ''),
        label: pName,
        sublabel: 'project',
      });
      for (const chain of proj.chains ?? []) {
        items.push({
          type: 'chain',
          id: String(chain.chainId || ''),
          label: String(chain.title || chain.chainId || ''),
          sublabel: pName,
        });
        for (const agent of chain.liveAgents ?? []) {
          items.push({
            type: 'agent',
            id: String(agent.agentInstanceId || ''),
            label: String(agent.displayName || agent.agentInstanceId || ''),
            sublabel: String(chain.title || ''),
          });
        }
      }
    }
    return items;
  }, [liveProjects]);

  const filteredMentions = useMemo(() => {
    if (mentionQuery === null) return [] as MentionEntity[];
    const q = mentionQuery.toLowerCase();
    return mentionEntities
      .filter(
        (e) => !q || e.label.toLowerCase().includes(q) || e.id.toLowerCase().includes(q),
      )
      .slice(0, 8);
  }, [mentionEntities, mentionQuery]);

  function handleMentionSelect(entity: MentionEntity) {
    const ta = textareaRef.current;
    const pos = ta?.selectionStart ?? draft.length;
    const before = draft.slice(0, pos);
    const after = draft.slice(pos);
    const newBefore = before.replace(/@([^\s@]*)$/, `@${entity.id}`);
    updateDraft(newBefore + after);
    setMentionQuery(null);
    setMentionIndex(0);
    setTimeout(() => {
      ta?.focus();
      const np = newBefore.length;
      ta?.setSelectionRange(np, np);
    }, 0);
  }

  useEffect(() => {
    setLocalMessages([]);
    setOlderMessages([]);
    setOlderCursor('');
    setOlderHasMore(false);
    setError('');
  }, [routeInstanceId]);

  // The model pill keeps its label down to phone widths (it truncates); only a composer
  // narrower than a small phone collapses it to the provider icon.
  useEffect(() => {
    const el = composerContainerRef.current;
    if (!el || typeof ResizeObserver === 'undefined') return;
    const checkWidth = () => {
      if (typeof el.getBoundingClientRect === 'function') {
        const rect = el.getBoundingClientRect();
        setIsSmallComposer(rect.width > 0 && rect.width < COMPACT_MODEL_PILL_WIDTH);
      }
    };
    checkWidth();
    const observer = new ResizeObserver((entries) => {
      for (const entry of entries) {
        const width = entry.contentRect.width;
        setIsSmallComposer(width > 0 && width < COMPACT_MODEL_PILL_WIDTH);
      }
    });
    observer.observe(el);
    return () => observer.disconnect();
    // showTray: the composer form unmounts while the action tray has the dock.
  }, [conversation?.conversation_id, conversation?.conversationId, agentInstanceId, showTray]);

  const [statusMenuOpen, setStatusMenuOpen] = useState(false);
  const [headerActionsOpen, setHeaderActionsOpen] = useState(false);
  const actionsAccess = useActionsAccess();
  const [paletteOpen, setPaletteOpen] = useState(false);
  const [chainSelectorOpen, setChainSelectorOpen] = useState(false);
  const [chainSelectorPlacement, setChainSelectorPlacement] = useState<'replace' | 'right' | 'bottom'>('replace');
  const [chainAgentSwitcherOpen, setChainAgentSwitcherOpen] = useState(false);

  useEffect(() => {
    if (!chainSelectorRequest) return;
    setChainSelectorPlacement(chainSelectorRequest.placement);
    setChainSelectorOpen(true);
    onChainSelectorRequestHandled?.(chainSelectorRequest.id);
  }, [chainSelectorRequest, onChainSelectorRequestHandled]);

  const chainAgentGroups = useMemo(() => {
    const chain = chainDetailQuery.data?.chain;
    const members = (chain?.members || []) as any[];
    if (!chainId || members.length === 0) return [];
    const coordinator = String(chain?.coordinatorAgentInstanceId || '');
    return [
      {
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
      },
    ];
  }, [chainDetailQuery.data, chainId]);

  const chainAgentOptions = chainAgentGroups[0]?.conversations || [];
  const chainMemberTitle =
    chainAgentGroups[0]?.conversations.find((member) => member.agentInstanceId === agentInstanceId)?.title || '';
  const agentBreadcrumbLabel = chainMemberTitle || agentDisplayName || agentId;
  // Agent settings subtitle: "<agent> #<n>" (the instance's numbered display name).
  const agentInstanceLabel =
    chainMemberTitle || String(instance?.display_name || '').trim() || agentDisplayName || agentId;
  const canOpenChainAgentSwitcher = (
    variant === 'main'
    && isFocusedPane
    && Boolean(paneId)
    && Boolean(chainId)
    && chainAgentOptions.length > 0
  );
  useRegisterActions([{
    id: `workspace.open-chain-agents.${variant}.${paneId || routeInstanceId}`,
    title: 'Agents in this task chain',
    category: 'Workspace',
    sequence: ['s', 'o', 'a'],
    isEnabled: () => canOpenChainAgentSwitcher,
    run: () => {
      if (!canOpenChainAgentSwitcher) return;
      setChainAgentSwitcherOpen(true);
      refetchIfStarted(chainDetailQuery);
    },
  }]);

  const fileInputRef = useRef<HTMLInputElement | null>(null);
  useEffect(() => {
    const input = fileInputRef.current;
    const cancelled = () => { updateFilePickerPending.current = false; setFilePickerOpen(false); };
    // Engines without the input `cancel` event: the window regains focus when the chooser
    // closes; a chosen file's `change` (and its attachment) arrives before this fallback.
    let fallback: ReturnType<typeof setTimeout> | undefined;
    const refocused = () => { clearTimeout(fallback); fallback = setTimeout(() => setFilePickerOpen(false), 1000); };
    input?.addEventListener('cancel', cancelled);
    window.addEventListener('focus', refocused);
    return () => { input?.removeEventListener('cancel', cancelled); window.removeEventListener('focus', refocused); clearTimeout(fallback); };
  });

  const [renaming, setRenaming] = useState(false);
  const [titleDraft, setTitleDraft] = useState('');
  const [titleError, setTitleError] = useState('');

  const destinationBridgeId = stagedBridgeId ?? instanceBridgeId;
  const destinationProjectId = projectId;
  const destinationBridgeRow = useMemo(
    () => bridges.find((item: any) => bridgeId(item) === destinationBridgeId),
    [bridges, destinationBridgeId],
  );
  const stagingOtherBridge = destinationBridgeId !== instanceBridgeId;
  const destinationProviders = useBridgeProviderStatus(destinationBridgeRow, {
    skip: !stagingOtherBridge,
    live: editingRuntime,
  });
  const destination = stagingOtherBridge ? destinationProviders : instanceProviders;
  const destinationBridge = destination.bridge;
  const destinationProjectQuery = projectQuery;
  const operationQuery = useListInstanceReconfigurationsQuery(
    { instanceId: agentInstanceId },
    {
      // A deleted instance (404) has no reconfigurations to poll either.
      skip: !agentInstanceId,
      // Event-driven: every phase advance publishes agent_instance_reconfiguration and
      // the hub reaper progresses operations without client reads. While an operation
      // this pane accepted is unsettled, a slow focused fallback covers a missed frame
      // between resyncs; idle panes never poll.
      pollingInterval:
        pollPolicy.isTerminal('instance') || pollPolicy.isTerminal('reconfigurations')
          ? 0
          : acceptedOperation &&
              !['ready', 'failed', 'recovery_required'].includes(acceptedOperation.phase)
            ? visiblePollInterval(paneVisible, RECONFIGURATION_ACTIVE_FALLBACK_MS)
            : 0,
      skipPollingIfUnfocused: true,
    },
  );
  pollPolicy.useReportErrors({
    conversation: convQuery.error,
    messages: messagesQuery.error,
    instance: instanceQuery.error,
    reconfigurations: operationQuery.error,
  });
  const serverOperation = operationQuery.data?.operations?.[0];
  const operation =
    acceptedOperation &&
    (!serverOperation ||
      (serverOperation.operation_id === acceptedOperation.operation_id &&
        serverOperation.revision < acceptedOperation.revision))
      ? acceptedOperation
      : serverOperation;
  const operationInFlight = Boolean(
    operation &&
      ['prepared', 'stopping', 'source_stopped', 'launching'].includes(operation.phase),
  );
  // A change queued after the current turn (waiting_for_idle) keeps the
  // conversation and runtime actions usable, exactly like the Hub.
  const operationBlocksInput = reconfigurationBlocksInput(operation);
  const bridgeLabel = String(
    instanceBridge?.label || instanceBridge?.machine_hostname || instanceBridgeId || '',
  );
  const currentCaps = useMemo(
    () => normalizeBridgeCapabilities(instanceBridge),
    [instanceBridge],
  );
  const caps = useMemo(
    () => normalizeBridgeCapabilities(destinationBridge),
    [destinationBridge],
  );

  const providerOptions = useMemo(() => {
    const list = caps.map((c) => c.provider).filter(Boolean);
    if (instanceProvider && !list.includes(instanceProvider)) list.push(instanceProvider);
    return Array.from(new Set(list)).sort();
  }, [caps, instanceProvider]);
  const modelOptions = useMemo(() => {
    const selectedProvider = provider || instanceProvider || providerOptions[0] || '';
    const cap = caps.find((c) => c.provider === selectedProvider && (c.profile_id || c.provider) === (providerProfile || instance?.provider_profile || selectedProvider));
    const t = capModels(cap);
    const ordered = modelOrder
      .filter((x) => t.includes(x))
      .concat(t.filter((x) => !modelOrder.includes(x)));
    if (instanceModel && !ordered.includes(instanceModel)) ordered.unshift(instanceModel);
    return ordered;
  }, [caps, provider, providerProfile, providerOptions, instanceProvider, instanceModel, instance?.provider_profile]);

  // REQ-PIN-3: rows that slide out of a refetched newest page are carried here, during
  // render, so the list never sees a temporarily shrunken array (an effect would commit
  // one frame without them, which unpinned a send in a conversation of 30+ messages). A
  // refetch that no longer joins the older pages re-anchors (effect below).
  const olderCarryRef = useRef({ conversationId, base: [] as Message[], slid: [] as Message[], dropped: null as Message[] | null });
  const carry = olderCarryRef.current;
  if (carry.conversationId !== conversationId) Object.assign(carry, { conversationId, base: [], slid: [], dropped: null });
  if (carry.base !== baseMessages) {
    const carried = [...carry.slid, ...olderMessages];
    const { older, reanchor } = reconcileOlderPages(carry.base, baseMessages, carried, messageIdOf);
    carry.base = baseMessages;
    if (reanchor) Object.assign(carry, { slid: [], dropped: olderMessages });
    else if (older !== carried) carry.slid = [...older.slice(0, older.length - carried.length), ...carry.slid];
  }
  const effectiveOlder = carry.dropped === olderMessages ? carry.slid : carry.slid.length ? [...carry.slid, ...olderMessages] : olderMessages;
  const carriedCount = carry.slid.length;
  const olderReanchored = carry.dropped !== null && carry.dropped === olderMessages && olderMessages.length > 0;

  // REQ-PIN-2: server id -> key of the optimistic row it replaced, and for each pending
  // send the ids already in the transcript when it was sent.
  const sentKeysRef = useRef(new Map<string, string>());
  const pendingSendsRef = useRef(new Map<string, Set<string>>());
  const chatMessages = useMemo(() => {
    const keys = sentKeysRef.current;
    // REQ-PIN-3: the WS echo of a send can land before its POST resolves. Its server row
    // takes over the pending row's key and the pending row is hidden, so the list never
    // holds both (no second bubble, no double pin, no scroll-back).
    const hidden = new Set<string>();
    for (const local of localMessages) {
      const localId = msgId(local, 0);
      const before = pendingSendsRef.current.get(localId);
      if (!before) continue;
      const echo = baseMessages.find((row) => {
        const id = messageIdOf(row);
        return id && msgDir(row) === 'user_to_agent' && !before.has(id) && (keys.get(id) ?? localId) === localId
          && String(row.body || '') === String(local.body || '');
      });
      if (!echo) continue;
      keys.set(messageIdOf(echo), localId);
      hidden.add(localId);
    }
    return normalizeConversationMessages(
      [...effectiveOlder, ...baseMessages, ...(hidden.size ? localMessages.filter((message) => !hidden.has(msgId(message, 0))) : localMessages)],
      agentId || agentInstanceId,
      (id) => keys.get(id),
    );
  }, [effectiveOlder, baseMessages, localMessages, agentId, agentInstanceId]);

  // G12: streamed output for this conversation, UI memory only.
  const agentOutputTurns = useSelector((state: any) => selectAgentOutputTurns(state, conversationId));
  const activeVaultKey = useSelector(selectActiveVaultKey);
  const hasLockedVaultMessages = useMemo(
    () =>
      !activeVaultKey &&
      chatMessages.some(
        (m) => isVaultArmored(m.body) || containsVaultArmored(m.body),
      ),
    [activeVaultKey, chatMessages],
  );

  // ACP delivery (docs/acp-send-now.md). User messages the agent has not received yet
  // wait above the composer (QueuedMessages); only delivered/read rows (and failures)
  // are in the transcript, placed causally. PTY/non-ACP conversations keep their transcript.
  // Whether and how Send now works is the runtime's declared capability (send-now
  // `send_now`): `members` is the tray above; `notice` (PTY) asks the agent to read its
  // unread messages now.
  const acpConversation = instance?.runtime_transport === 'acp';
  const hasAcpDelivery = useMemo(() => chatMessages.some((m) => m.acpDelivery), [chatMessages]);
  const sendNowQuery = useFetchSendNowStateQuery({ conversationId }, { skip: !conversationId });
  const sendNowKind = sendNowQuery.data?.sendNow ?? '';
  const notifiedThrough = sendNowQuery.data?.notifiedThrough;
  const agentRunning = runtimeStateFromStatus(runtimeStatus) === 'live';
  // Unread rows, and whether the bridge's typed unread notice covered all of them.
  const { agentUnreadCount, agentUnreadState } = useMemo(() => {
    if (sendNowKind !== 'notice') return { agentUnreadCount: 0, agentUnreadState: 'pending' as const };
    const unread = unreadUserRows(chatMessages);
    return { agentUnreadCount: unread.length, agentUnreadState: unreadTrayState(unread, notifiedThrough, agentRunning) };
  }, [agentRunning, chatMessages, notifiedThrough, sendNowKind]);
  const [sendNowRequest] = useSendNowMutation();
  const aboveComposerMessages = useMemo(
    () => (acpConversation || hasAcpDelivery ? chatMessages.filter((m) => placementFor(m, acpConversation) !== 'transcript') : []),
    [acpConversation, chatMessages, hasAcpDelivery],
  );
  const transcriptSource = useMemo(
    () => (acpConversation || hasAcpDelivery
      ? orderTranscript(chatMessages.filter((m) => placementFor(m, acpConversation) === 'transcript'))
      : chatMessages),
    [acpConversation, chatMessages, hasAcpDelivery],
  );
  const transcriptMessages = useMemo(
    () => groupTranscriptMessages(transcriptSource),
    [transcriptSource],
  );

  // Send now: one batch for the turn-held snapshot. Between the click and the Send now
  // state refetch that follows it, the clicked snapshot (then the POST's own batch) is
  // shown, so the button never flashes back to Send now. Retry reuses the request_id.
  const [sendNowLocal, setSendNowLocal] = useState<{
    conversationId: string; batch: SendNowBatch; settledAt: number;
  } | null>(null);
  const [sendNowError, setSendNowError] = useState<{ conversationId: string; text: string } | null>(null);
  const serverBatch = sendNowQuery.data?.batch ?? null;
  const localBatch = sendNowLocal && sendNowLocal.conversationId === conversationId
    && (!sendNowLocal.settledAt || (sendNowQuery.fulfilledTimeStamp ?? 0) < sendNowLocal.settledAt)
    ? sendNowLocal.batch : null;
  useEffect(() => {
    if (sendNowLocal && sendNowLocal.settledAt && !localBatch) setSendNowLocal(null);
  }, [localBatch, sendNowLocal]);
  const queuedView = useMemo(
    () => trayView(aboveComposerMessages, acpConversation, localBatch ?? serverBatch),
    [aboveComposerMessages, acpConversation, localBatch, serverBatch],
  );
  const sendNowLocalError = sendNowError && sendNowError.conversationId === conversationId ? sendNowError.text : '';
  useEffect(() => {
    if (sendNowLocalError && queuedView.waiting.length === 0 && queuedView.batch.length === 0 && agentUnreadCount === 0) setSendNowError(null);
  }, [agentUnreadCount, queuedView.batch.length, queuedView.waiting.length, sendNowLocalError]);
  const postSendNow = useCallback(async (batch: SendNowBatch) => {
    if (!conversationId) return;
    const target = conversationId;
    setSendNowError(null);
    setSendNowLocal({ conversationId: target, batch: { ...batch, state: 'pending', error: '' }, settledAt: 0 });
    try {
      const result = await sendNowRequest({
        conversationId: target, requestId: batch.requestId, launchEpoch: batch.launchEpoch, messageIds: batch.messageIds,
      }).unwrap();
      setSendNowLocal((current) => (current?.batch.requestId === batch.requestId
        ? { ...current, batch: result.batch ?? { ...batch, state: result.outcome || 'empty' }, settledAt: Date.now() }
        : current));
    } catch (err: any) {
      setSendNowLocal((current) => (current?.batch.requestId === batch.requestId ? null : current));
      const stale = Number(err?.originalStatus ?? err?.status) === 409 || /stale launch epoch/i.test(String(err?.error || ''));
      setSendNowError({ conversationId: target, text: stale ? sendNowErrorText('stale_epoch') : sendNowErrorText('') });
      void sendNowQuery.refetch?.();
    }
  }, [conversationId, sendNowQuery, sendNowRequest]);
  const handleSendNow = useCallback((messageIds: string[]) => {
    if (!messageIds.length) return;
    void postSendNow({
      batchId: '', requestId: newSendNowRequestId(), attempt: 0, state: 'pending', error: '', messageIds,
      launchEpoch: sendNowQuery.data?.launchEpoch || String((instance as any)?.launch_epoch || ''),
    });
  }, [instance, postSendNow, sendNowQuery.data?.launchEpoch]);
  const handleSendNowRetry = useCallback(() => {
    const batch = localBatch ?? serverBatch;
    if (batch && batch.state === 'failed') void postSendNow(batch);
  }, [localBatch, postSendNow, serverBatch]);
  // A runtime without members (PTY): one action over the unread rows, no snapshot.
  const noticePhase = noticeSendNowPhase(localBatch ?? serverBatch);
  const handleNoticeSendNow = useCallback(() => {
    void postSendNow({
      batchId: '', requestId: newSendNowRequestId(), attempt: 0, state: 'pending', error: '', messageIds: [],
      launchEpoch: sendNowQuery.data?.launchEpoch || String((instance as any)?.launch_epoch || ''),
    });
  }, [instance, postSendNow, sendNowQuery.data?.launchEpoch]);

  // REQ-PIN-1 for delivery: a message this mount showed above the composer plays the
  // send animation once, from its own bubble, when it enters the transcript. Keys are
  // recorded after commit and dropped once the row is in the transcript (ChatMessageList's
  // layout effect, a child, runs first), so a refetch, remount or reload never replays it.
  const queuedBubbleEls = useRef(new Map<string, HTMLElement>());
  const queuedBubbleRef = useCallback((key: string, el: HTMLElement | null) => {
    if (el) queuedBubbleEls.current.set(key, el);
    else if (queuedBubbleEls.current.get(key)?.isConnected === false) queuedBubbleEls.current.delete(key);
  }, []);
  const seenAboveRef = useRef(new Set<string>());
  useLayoutEffect(() => {
    for (const m of aboveComposerMessages) seenAboveRef.current.add(m.key);
  }, [aboveComposerMessages]);
  useLayoutEffect(() => {
    const seen = seenAboveRef.current;
    if (!seen.size) return;
    for (const m of transcriptSource) {
      if (!seen.has(m.key)) continue;
      seen.delete(m.key);
      queuedBubbleEls.current.delete(m.key);
    }
  }, [transcriptSource]);
  const pinOnSend = useCallback(
    (message: ChatMessage) => isOptimisticSend(message) || seenAboveRef.current.has(message.key),
    [],
  );
  const lastTranscriptKey = transcriptMessages[transcriptMessages.length - 1]?.key ?? '';
  const pinOriginRef = useMemo<React.RefObject<HTMLElement | null>>(() => ({
    get current() {
      const bubble = queuedBubbleEls.current.get(lastTranscriptKey);
      return bubble && bubble.isConnected ? bubble : textareaRef.current;
    },
  }), [lastTranscriptKey]);
  const liveChain = chainDetailQuery.data?.chain;
  const isChainCoordinator = Boolean(chainId) && (
    String(liveChain?.coordinatorAgentInstanceId || liveChain?.coordinator_agent_instance_id || '') === agentInstanceId ||
    (liveChain?.members || []).some((member: any) =>
      String(member.agentInstanceId || member.agent_instance_id || '') === agentInstanceId &&
      (member.role === 'coordinator' || member.isCoordinator === true))
  );

  const needsStart = runtimeNeedsStart(runtimeStatus);
  const runtimeStopping = runtimeIsStopping(runtimeStatus);
  const runtimeActionBusy =
    operationInFlight ||
    lifecycle.isPending('retry') ||
    lifecycle.isPending('reconfigure') ||
    lifecycle.isPending();
  // Composer "Bypass permissions" toggle: the catalog descriptor for the
  // instance's provider comes from the bridge provider-status (only fetched
  // while the settings panel is open).
  const instanceProvidersQuery = useListBridgeProvidersQuery(
    { bridgeId: instanceBridgeId },
    { skip: !instanceBridgeId || !settingsOpen },
  );
  const instanceCatalogExtension = useMemo(
    () =>
      (instanceProvidersQuery.data?.providers || []).find(
        (entry: any) => entry?.provider === instanceProvider && (entry?.profile_id || entry?.provider) === (instance?.provider_profile || instanceProvider),
      )?.extension ?? null,
    [instanceProvidersQuery.data, instanceProvider, instance?.provider_profile],
  );
  const hasUploadingAttachments = attachments.some((item) => item.status === 'uploading');
  const hasFailedAttachments = attachments.some((item) => item.status === 'error');
  const uploadedAttachments = attachments.filter(
    (item) => item.status === 'uploaded' && item.id,
  );

  const pendingPaneCapture = chatMessages.some(
    (message) =>
      message.messageType === 'pane_capture' && message.messageStatus === 'pending',
  );
  const paneCaptureDisabled =
    !agentInstanceId ||
    needsStart ||
    runtimeStopping ||
    pendingPaneCapture ||
    requestPaneCaptureState.isLoading;

  useEffect(() => {
    if (!renaming) setTitleDraft(renameSeed);
  }, [renameSeed, renaming]);
  const unreadCount = Number(conversation?.unread_count || conversation?.unreadCount || 0);
  usePaneMarkRead({
    isActiveTab,
    paneVisible,
    conversationId,
    agentInstanceId,
    unreadCount,
    markRead: (id) => void markRead({ conversationId: id }),
  });
  // No catch-up refetch on show: nothing polls, and events/resyncs reach a hidden
  // pane's subscriptions the same as a visible one's.
  useEffect(() => {
    if (settingsEditedRef.current) return;
    setProvider(instanceProvider);
    setProviderProfile(String(instance?.provider_profile || instanceProvider));
    setModel(instanceModel);
  }, [instanceProvider, instanceModel, instance?.provider_profile]);
  const observedOperationRef = useRef<InstanceReconfiguration | undefined>(undefined);
  useEffect(() => {
    observedOperationRef.current = undefined;
    settingsEditedRef.current = false;
    setStagedBridgeId(null);
    setStagedTransport(null);
    setStagedBypass(null);
    setDraftBridgeCheck(null);
    setAcceptedOperation(null);
    setProvider(instanceProvider);
    setProviderProfile(String(instance?.provider_profile || instanceProvider));
    setModel(instanceModel);
    setReconfigStatus('');
  }, [agentInstanceId]);
  useEffect(() => {
    if (
      !operation ||
      !operationBlocksInput ||
      operation.failure_code === 'force_stopping'
    )
      return;
    settingsEditedRef.current = true;
    setStagedBridgeId(operation.destination.bridge_id);
    setProvider(operation.destination.provider);
    setProviderProfile(operation.destination.provider_profile || operation.destination.provider);
    setModel(operation.destination.model);
  }, [operation?.operation_id, operation?.phase]);
  // React to an operation settling WHILE this pane watches it, never to a settled
  // operation it merely loads (an instance reconfigured long ago reports `ready` on
  // every open). Refreshing the instance, conversation and messages is the API
  // layer's job (listInstanceReconfigurations invalidates their tags).
  useEffect(() => {
    const previous = observedOperationRef.current;
    observedOperationRef.current = operation;
    if (!operation || !reconfigurationSettled(previous, operation)) return;
    setAcceptedOperation(null);
    setReconfigStatus('');
    if (operation.phase !== 'ready') return;
    settingsEditedRef.current = false;
    setStagedBridgeId(null);
    setStagedTransport(null);
    setStagedBypass(null);
    setDraftBridgeCheck(null);
    setProvider(operation.destination.provider);
    setProviderProfile(operation.destination.provider_profile || operation.destination.provider);
    setModel(operation.destination.model);
  }, [operation?.operation_id, operation?.phase, operation?.failure_code]);
  useEffect(() => {
    setOlderMessages([]);
    setOlderCursor('');
    setOlderHasMore(false);
    setLocalMessages([]);
    setAttachments([]);
    sentKeysRef.current.clear();
    pendingSendsRef.current.clear();
  }, [conversationId]);
  useEffect(() => {
    if (baseMessages.length === 0 || localMessages.length === 0) return;
    const serverIds = new Set(baseMessages.map((message, index) => msgId(message, index)));
    setLocalMessages((current) =>
      current.filter((message, index) => {
        const id = msgId(message, index);
        return !id || id.startsWith('local_') || !serverIds.has(id);
      }),
    );
  }, [baseMessages, localMessages.length]);
  // With carried rows the cursor stays where the older end was (the page they slid from).
  useEffect(() => {
    if (olderMessages.length > 0 || carriedCount > 0) return;
    setOlderCursor(String(messagesQuery.data?.nextCursor || ''));
    setOlderHasMore(Boolean(messagesQuery.data?.hasMore));
  }, [messagesQuery.data?.nextCursor, messagesQuery.data?.hasMore, olderMessages.length, carriedCount]);
  // The render-time carry above found that the older pages no longer join: drop them and
  // page back from the new newest page.
  useEffect(() => {
    if (!olderReanchored) return;
    setOlderMessages([]);
    setOlderCursor(String(messagesQuery.data?.nextCursor || ''));
    setOlderHasMore(Boolean(messagesQuery.data?.hasMore));
  }, [olderReanchored]);
  // Read receipts for older pages held in state (RTK pages are patched in wsInvalidation).
  useEffect(() => {
    if (!conversationId) return undefined;
    const onRead = (event: Event) => {
      const receipt = (event as CustomEvent<ConversationMessagesRead>).detail;
      if (!receipt || receipt.conversationId !== conversationId) return;
      setOlderMessages((current) => applyReadReceipt(current, receipt));
    };
    window.addEventListener(CONVERSATION_MESSAGES_READ_EVENT, onRead);
    return () => window.removeEventListener(CONVERSATION_MESSAGES_READ_EVENT, onRead);
  }, [conversationId]);

  const instanceProfile = String(instance?.provider_profile || instanceProvider);
  const effectiveProfile = providerProfile || instanceProfile;
  const effectiveProvider = provider || instanceProvider;
  const effectiveModel = model || instanceModel;
  const selectionChangesConfig =
    Boolean(agentInstanceId) &&
    (destinationBridgeId !== instanceBridgeId ||
      (effectiveProvider && effectiveProvider !== instanceProvider) ||
      effectiveProfile !== instanceProfile ||
      (effectiveModel && effectiveModel !== instanceModel));
  // ---- Agent settings panel draft (T6; rules in agentSettings/agentSettingsDraft.ts).
  const instanceTransport: RuntimeTransport = instance?.runtime_transport === 'acp' ? 'acp' : 'pty';
  const instanceBypass = effectivePermissionMode(instance) === 'yolo';
  const currentConfig: AgentConfig = {
    bridgeId: instanceBridgeId, provider: instanceProvider, providerProfile: instanceProfile,
    model: instanceModel, transport: instanceTransport, bypass: instanceBypass,
  };
  const draftConfig: AgentConfig = {
    bridgeId: destinationBridgeId, provider: effectiveProvider, providerProfile: effectiveProfile,
    model: effectiveModel, transport: stagedTransport ?? instanceTransport, bypass: stagedBypass ?? instanceBypass,
  };
  // Provider rows (installed or not, versions, models, acp_availability) for the DRAFT
  // bridge. provider_status_changed on the user WebSocket refetches it (live installs).
  const draftProvidersQuery = useListBridgeProvidersQuery(
    { bridgeId: destinationBridgeId },
    { skip: !destinationBridgeId || !settingsPanel.open },
  );
  const draftProviderOptions = useMemo(
    () => providerOptionsFromStatus(draftProvidersQuery.currentData),
    [draftProvidersQuery.currentData],
  );
  const draftProvidersLoaded = Boolean(draftProvidersQuery.currentData) || draftProvidersQuery.isError;
  const bridgeLabelOf = (id: string) => {
    const row = bridges.find((b: any) => bridgeId(b) === id);
    return String(row?.label || row?.machine_hostname || id || '');
  };
  const providerLabelOf = (config: AgentConfig) =>
    draftProviderOptions.find((p) => p.id === (config.providerProfile || config.provider))?.label
      || providerDisplayName(config.provider);
  const draftChanges = agentInstanceId
    ? draftDiff(currentConfig, draftConfig, { bridgeLabel: bridgeLabelOf, providerLabel: providerLabelOf })
    : [];
  // Model refresh and the ACP fixes act on the DRAFT bridge through the existing paths.
  const [refreshBridgeModels, refreshModelsState] = useRefreshBridgeModelsMutation();
  const [updateBridgeRequest, updateBridgeState] = useUpdateBridgeMutation();
  const [installAcpAdapter, installAcpState] = useInstallAcpAdapterMutation();
  const [discoverBridgeProviders, discoverProvidersState] = useDiscoverBridgeProvidersMutation();
  const [draftRefreshError, setDraftRefreshError] = useState('');
  const [draftFixError, setDraftFixError] = useState('');
  useEffect(() => { setDraftRefreshError(''); setDraftFixError(''); }, [destinationBridgeId]);
  async function refreshDraftModels() {
    if (!destinationBridgeId) return;
    setDraftRefreshError('');
    try { await refreshBridgeModels({ bridgeId: destinationBridgeId }).unwrap(); }
    catch (err) { setDraftRefreshError(agentErrorText(err, 'Could not check models.')); }
  }
  async function fixDraftConnection(fix: AcpAvailabilityFix) {
    if (!destinationBridgeId) return;
    setDraftFixError('');
    try {
      if (fix === 'update_bridge') await updateBridgeRequest({ bridgeId: destinationBridgeId }).unwrap();
      else if (fix === 'install_adapter') await installAcpAdapter({ bridgeId: destinationBridgeId, provider: draftConfig.provider }).unwrap();
      // check_now: provider discovery is the stage that records the ACP adapter state.
      else await discoverBridgeProviders({ bridgeId: destinationBridgeId }).unwrap();
    } catch (err) {
      setDraftFixError(agentErrorText(err, 'The request failed.'));
    }
  }
  // The panel's gate. The old modal (panel closed, flag off) keeps its own rules: the
  // draft bridge's provider status is not even fetched there.
  const draftApplyBlocked = settingsPanel.open
    ? applyBlockedReason(draftConfig, draftProvidersLoaded ? draftProviderOptions : null)
    : null;
  // Staged-changes footer (T7): the panel's Apply flow (useApplyAgentSettings.ts).
  const [cancelInstanceConfiguration] = useCancelInstanceConfigurationMutation();
  const applyFlow = useApplyAgentSettings({
    instanceId: agentInstanceId,
    projectId: destinationProjectId,
    current: currentConfig,
    draft: draftConfig,
    revision: Number(instance?.configuration_revision || 0),
    launchEpoch: String((instance as any)?.launch_epoch || ''),
    running: runtimeStateFromStatus(runtimeStatus) === 'live',
    midTurn: isWorking,
    operation,
    labels: { bridgeLabel: bridgeLabelOf, providerLabel: providerLabelOf },
    // The footer shows the outcome; the Runtime card's inline message would repeat it.
    reconfigure: async (args) => { const result = await lifecycle.reconfigure(args); setReconfigStatus(''); return result; },
    retry: async (args) => { const result = await lifecycle.retry(args); setReconfigStatus(''); return result; },
    cancel: (args) => lifecycleResult('reconfigure', () => cancelInstanceConfiguration(args).unwrap()),
    refetchInstance: () => refetchIfStarted(instanceQuery),
    onAccepted: (accepted) => setAcceptedOperation(accepted),
  });
  function commitDraft(next: AgentConfig) {
    settingsEditedRef.current = true;
    setStagedBridgeId(next.bridgeId === instanceBridgeId ? null : next.bridgeId);
    setProvider(next.provider);
    setProviderProfile(next.providerProfile || next.provider);
    setModel(next.model);
    setStagedTransport(next.transport === instanceTransport ? null : next.transport);
    setStagedBypass(next.bypass === instanceBypass ? null : next.bypass);
  }
  function dispatchDraft(action: AgentDraftAction) {
    const next = reduceAgentDraft(draftConfig, action);
    if (action.type === 'bridge' && next.bridgeId !== draftConfig.bridgeId) setDraftBridgeCheck(next.bridgeId);
    if (next !== draftConfig) commitDraft(next);
  }
  // A picked bridge's provider status arrived: keep the provider if it is installed
  // there, else switch to the first installed one and its first model.
  useEffect(() => {
    if (!draftBridgeCheck || draftBridgeCheck !== destinationBridgeId || !draftProvidersQuery.currentData) return;
    setDraftBridgeCheck(null);
    const next = reconcileDraftProviders(draftConfig, draftProviderOptions);
    if (next !== draftConfig) commitDraft(next);
  }, [draftBridgeCheck, destinationBridgeId, draftProvidersQuery.currentData]);
  const validityInput = {
    instanceLoaded: Boolean(instance),
    instanceError: instanceQuery.isError,
    bridgeId: instanceBridgeId,
    bridge: instanceBridge,
    bridgesLoaded: Boolean(bridgesQuery.data),
    bridgesError: bridgesQuery.isError,
    projectId,
    project: projectQuery.data?.project,
    projectLoaded: Boolean(projectQuery.data),
    projectError: projectQuery.isError,
    provider: instanceProvider,
    providerProfile: instanceProfile,
    model: instanceModel,
    capabilities: currentCaps,
    capabilitiesLoaded: !instanceBridge || instanceProviders.loaded,
  };
  const configurationIssues = conversationConfigurationIssues(validityInput);
  const stagedConfigurationIssues = conversationConfigurationIssues({
    ...validityInput,
    bridgeId: destinationBridgeId,
    bridge: destinationBridge,
    projectId: destinationProjectId,
    project: destinationProjectQuery.data?.project,
    projectLoaded: Boolean(destinationProjectQuery.data),
    projectError: destinationProjectQuery.isError,
    provider: effectiveProvider,
    providerProfile: effectiveProfile,
    model: effectiveModel,
    capabilities: caps,
    capabilitiesLoaded: !destinationBridge || destination.loaded,
  });
  if (
    destinationBridge &&
    destinationBridge.runtime_connected !== true &&
    !stagedConfigurationIssues.some((issue) =>
      issue.includes('connection is disconnected'),
    )
  ) {
    stagedConfigurationIssues.push(
      'Destination bridge is not connected. Reconnect it or choose a connected bridge before Apply.',
    );
  }
  if (destinationBridge && !destinationBridge.reconfiguration_supported) {
    stagedConfigurationIssues.push(
      'Update the destination bridge before applying configuration changes.',
    );
  }
  if (instanceBridge && !instanceBridge.reconfiguration_supported) {
    stagedConfigurationIssues.push(
      'Update the source bridge before applying configuration changes.',
    );
  }
  if (operation?.failure_code === 'force_stopping') {
    stagedConfigurationIssues.push(
      'Waiting for Force stop confirmation before allowing Apply.',
    );
  }
  if (operationBlocksInput) {
    configurationIssues.push(
      operation?.failure_message ||
        'Configuration change is in progress. Messages are disabled until the destination is ready.',
    );
  }
  if (operationQuery.isLoading) {
    configurationIssues.push(
      'Checking for an in-progress configuration change before allowing messages.',
    );
  }
  if (operationQuery.isError) {
    configurationIssues.push(
      'Configuration operation state could not be verified. Refresh before sending.',
    );
  }
  const conversationReadOnly = configurationIssues.length > 0;
  const configurationInputBlocked =
    conversationReadOnly ||
    selectionChangesConfig ||
    runtimeActionBusy ||
    runtimeStopping ||
    isStarting;
  configurationInputBlockedRef.current = Boolean(configurationInputBlocked);
  // A borrowed composer (Answer / Request changes) talks to the hub, not the
  // agent runtime, so runtime state does not block it.
  const sendDisabled = normalSendBusy || Boolean(vaultSendBlocked) || (trayModeItem
    ? hasUploadingAttachments || hasFailedAttachments || !trayDraft.trim()
    : configurationInputBlocked ||
      hasUploadingAttachments ||
      hasFailedAttachments ||
      (quotes.length > 0 && !quoteVaultUnlocked) ||
      (!draft.trim() && uploadedAttachments.length === 0 && quotes.length === 0));

  async function saveRenameTitle() {
    const next = titleDraft.trim();
    if (!next) {
      setTitleError('Title is required.');
      return;
    }
    setTitleError('');
    try {
      if (renameTarget.kind === 'chain') {
        // Vault-aware: encrypts the title when the vault is unlocked, and invalidates
        // the chain detail and chain list tags so the header and sidebar refresh.
        await updateTaskChain({ chainId, title: next }).unwrap();
      } else {
        await updateConversationTitle({ conversationId, title: next }).unwrap();
      }
      setRenaming(false);
    } catch (err: any) {
      setTitleError(errMsg(err, 'Rename failed'));
    }
  }

  async function loadOlderMessages() {
    if (!olderCursor || olderMessagesState.isFetching) return;
    setError('');
    try {
      const data = await fetchOlderMessages({
        conversationId,
        limit: 30,
        cursor: olderCursor,
      }).unwrap();
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

  function handleAttachmentInput(event: any) {
    updateFilePickerPending.current = false;
    setFilePickerOpen(false);
    if (desktopUpdateFrozen()) return;
    if (configurationInputBlocked || sendingRef.current) return;
    const files = Array.from(event.target.files || []) as File[];
    event.target.value = '';
    files.forEach((file) => void uploadAttachment(file));
  }

  function openAttachmentPicker() {
    if (desktopUpdateFrozen()) return;
    if (!configurationInputBlocked && !sendingRef.current && fileInputRef.current) {
      updateFilePickerPending.current = true;
      setFilePickerOpen(true);
      fileInputRef.current.click();
    }
  }


  async function submitTrayMode() {
    if (desktopUpdateFrozen()) return;
    if (!trayMode || !trayModeItem) return;
    const text = appendArtifactLinks(
      trayDraft.trim(),
      uploadedAttachments.map((a) => `artifact://${a.id}`),
    ).trim();
    const item = trayModeItem;
    const { kind } = trayMode;
    const typed = trayDraft;
    setError('');
    dispatchTray({ type: 'mode_sent' });
    setAttachments([]);
    try {
      setTrayNotice(await sendTrayMode(item, kind, text));
    } catch (err: any) {
      // The card is back (unsettled): reopen the mode with what was typed.
      dispatchTray({ type: 'start_mode', kind, cardId: item.card_id });
      setTrayDraft(typed);
      setError(errMsg(err, kind === 'answer' ? 'Answer failed' : 'Request changes failed'));
    }
  }

  // REQ-PIN-2/3: remember what the transcript held at send time (to spot the WS echo),
  // and on the ack map the server id to the optimistic row's key.
  function trackPendingSend(localId: string) {
    pendingSendsRef.current.set(localId, new Set([...effectiveOlder, ...baseMessages].map(messageIdOf).filter(Boolean)));
  }
  function settlePendingSend(localId: string, sent: Message | null) {
    pendingSendsRef.current.delete(localId);
    const id = sent ? messageIdOf(sent) : '';
    if (id) sentKeysRef.current.set(id, localId);
  }

  async function submit(event: FormEvent) {
    event.preventDefault();
    if (desktopUpdateFrozen()) return;
    if (sendDisabled || sendingRef.current) return;
    if (trayModeItem) {
      await submitTrayMode();
      return;
    }
    const body = draft.trim();
    const attachmentIds = uploadedAttachments.map((a) => a.id);
    const sendBody = quotedMessageBody(body || (attachmentIds.length ? 'Uploaded file' : ''), quotes);
    const submittedQuotes = quotes;
    const submittedEpoch = quoteEpoch;
    const submittedRoute = routeInstanceId;
    const submittedDraft = draft;
    const submittedTarget = ownTargetId;
    const submittedKey = quoteVaultKey;
    const submittedGeneration = routeGeneration.current;
    if (!sendBody && attachmentIds.length === 0) return;
    sendingRef.current = true;
    setNormalSendBusy(true);
    const local = optimisticUserMessage(conversationId, sendBody);
    const localId = msgId(local, 0);
    (local as any).artifact_ids_json = JSON.stringify(attachmentIds);
    setError('');
    if (submittedQuotes.length) (local as any).hasQuoteContext = true;
    trackPendingSend(localId);
    setLocalMessages((current) => [...current, local]);
    // REQ-PIN-1: release the message at t=0. The input clears now (a failed send puts
    // the draft back) and, on phones, blurring dismisses the keyboard; the composer then
    // collapses with its morph while the bubble travels.
    updateDraft('');
    if (isMobile) textareaRef.current?.blur();
    try {
      const result = await sendMessage({
        conversationId,
        body: sendBody,
        artifactIds: attachmentIds,
        ...(submittedQuotes.length ? { quoteTarget: { chainId, coordinatorAgentInstanceId: agentInstanceId, epoch: submittedEpoch } } : {}),
      }).unwrap();
      if (submittedQuotes.length && ((reduxStore.getState() as any).composerContext?.epoch !== submittedEpoch || selectActiveVaultKey() !== submittedKey)) return;
      dispatch(consumeComposerQuotes({ target: ownTargetId, ids: submittedQuotes.map(q => q.id), epoch: submittedEpoch }));
      if (!mountedRef.current || routeGeneration.current !== submittedGeneration || currentTargetRef.current !== submittedTarget) {
        if (readComposerDraft(submittedRoute) === submittedDraft) writeComposerDraft(submittedRoute, '');
        return;
      }
      // The input was cleared at send; adopt a newer draft another pane stored meanwhile.
      const latestDraft = readComposerDraft(submittedRoute);
      if (latestDraft !== submittedDraft && latestDraft !== updateDraftRef.current) updateDraft(latestDraft);
      setAttachments([]);
      const sent = sentMessageFromResult(result);
      settlePendingSend(localId, sent);
      setLocalMessages((current) =>
        current.map((message) => {
          if (msgId(message, 0) !== localId) return message;
          return sent
            ? {
                ...sent,
                body: ownSentBody(sent.body, sendBody),
                direction: sent.direction || 'user_to_agent',
                artifact_ids_json:
                  (sent as any).artifact_ids_json || JSON.stringify(attachmentIds),
              }
            : { ...message, sending: false };
        }),
      );
    } catch (err: any) {
      settlePendingSend(localId, null);
      // The input was cleared at send, so every failure path puts the draft back.
      if (!mountedRef.current || routeGeneration.current !== submittedGeneration || currentTargetRef.current !== submittedTarget) {
        // The pane moved on: restore the draft to storage for the submitted route
        // unless a newer one was typed there meanwhile.
        if (!readComposerDraft(submittedRoute)) writeComposerDraft(submittedRoute, submittedDraft);
        return;
      }
      if (submittedQuotes.length && ((reduxStore.getState() as any).composerContext?.epoch !== submittedEpoch || selectActiveVaultKey() !== submittedKey)) {
        if (!updateDraftRef.current) updateDraft(submittedDraft);
        return;
      }
      setError(errMsg(err, 'Send failed. Your draft is retained.'));
      if (!updateDraftRef.current) updateDraft(submittedDraft);
      setLocalMessages(current => current.filter(item => msgId(item, 0) !== localId));
    } finally {
      sendingRef.current = false;
      if (mountedRef.current) setNormalSendBusy(false);
    }
  }

  async function handleSendReply(text: string) {
    if (configurationInputBlocked) return;
    const sendBody = text.trim();
    if (!sendBody || !conversationId) return;
    const local = optimisticUserMessage(conversationId, sendBody);
    const localId = msgId(local, 0);
    setError('');
    trackPendingSend(localId);
    setLocalMessages((current) => [...current, local]);
    try {
      const result = await sendMessage({
        conversationId,
        body: sendBody,
        artifactIds: [],
      }).unwrap();
      const sent = sentMessageFromResult(result);
      settlePendingSend(localId, sent);
      setLocalMessages((current) =>
        current.map((message) => {
          if (msgId(message, 0) !== localId) return message;
          return sent
            ? {
                ...sent,
                body: ownSentBody(sent.body, sendBody),
                direction: sent.direction || 'user_to_agent',
                artifact_ids_json: '[]',
              }
            : { ...message, sending: false };
        }),
      );
    } catch (err: any) {
      settlePendingSend(localId, null);
      const message = errMsg(err, 'Send failed');
      setLocalMessages((current) =>
        current.map((item) =>
          msgId(item, 0) === localId ? failedLocalMessage(item, message) : item,
        ),
      );
    }
  }

  async function requestPane() {
    if (paneCaptureDisabled) return;
    const requestId = `cap_local_${Date.now()}_${Math.random().toString(36).slice(2, 8)}`;
    const local = optimisticPaneCaptureMessage(
      conversationId,
      requestId,
      agentInstanceId,
    );
    const localId = msgId(local, 0);
    setError('');
    setLocalMessages((current) => [...current, local]);
    try {
      const result = await requestPaneCapture({
        conversationId,
        width: 80,
        settleMs: 3000,
        lineLimit: 120,
      }).unwrap();
      const serverMessage = result?.message || null;
      setLocalMessages((current) =>
        current.map((message) =>
          msgId(message, 0) === localId && serverMessage
            ? { ...serverMessage, sending: false }
            : message,
        ),
      );
    } catch (err: any) {
      const message = errMsg(err, 'Pane capture request failed');
      setLocalMessages((current) =>
        current.map((item) =>
          msgId(item, 0) === localId ? failedPaneCaptureMessage(item, message) : item,
        ),
      );
    }
  }

  function beginRenameFromHeader() {
    setHeaderActionsOpen(false);
    setTitleDraft(renameSeed);
    setRenaming(true);
    setTitleError('');
  }

  function refreshFromHeader() {
    setHeaderActionsOpen(false);
    refetchIfStarted(messagesQuery);
  }

  function renderConversationMessageBody(message: ChatMessage, reveal?: StreamRevealOptions) {
    if (message.messageType === 'pane_capture') {
      const metadata = message.metadata || {};
      const status = message.messageStatus || 'complete';
      const lineCount = Number(metadata.line_count || metadata.lineCount || 0);
      return (
        <div
          data-debug-id={
            status === 'pending'
              ? `conversation-pane-capture-loading-${message.messageId}`
              : status === 'failed'
              ? `conversation-pane-capture-error-${message.messageId}`
              : `conversation-pane-capture-output-${message.messageId}`
          }
          className={`rounded-2xl border p-3 ${
            status === 'failed'
              ? 'border-danger/30 bg-danger-soft text-danger'
              : 'border-info/30 bg-info-soft text-info'
          }`}
        >
          <div className="mb-2 flex flex-wrap items-center gap-2 text-caption uppercase tracking-wide text-info">
            <span>
              {status === 'pending'
                ? 'Requesting terminal pane…'
                : status === 'failed'
                ? 'Pane capture failed'
                : 'Terminal pane capture'}
            </span>
            <span>{Number(metadata.width || 80)} cols</span>
            {lineCount ? <span>{lineCount} lines</span> : null}
            {metadata.truncated ? <span>truncated</span> : null}
          </div>
          {status === 'pending' ? (
            <div className="text-sm text-info">
              Waiting for the wrapper to resize and capture the pane…
            </div>
          ) : (
            <PaneCaptureOutput body={message.body} messageId={message.messageId} />
          )}
          {status === 'failed' ? (
            <button
              type="button"
              data-debug-id={`conversation-pane-capture-retry-${message.messageId}`}
              onClick={() => void requestPane()}
              disabled={paneCaptureDisabled}
              className="mt-2 rounded-full border border-subtle bg-surface px-3 py-1 text-xs text-primary hover:bg-surface-raised disabled:opacity-50"
            >
              Retry
            </button>
          ) : null}
        </div>
      );
    }
    if (message.messageType === 'configuration_change') {
      const metadata = message.metadata || {};
      const source = metadata.source || {};
      const destination = metadata.destination || {};
      const fields = [
        { name: 'Bridge', key: 'bridge_id', label: 'bridge_label' },
        { name: 'Project', key: 'project_id', label: 'project_label' },
        { name: 'Provider', key: 'provider', label: 'provider' },
        { name: 'Model', key: 'model', label: 'model' },
      ].filter((field) => source[field.key] !== destination[field.key]);
      return (
        <div
          data-debug-id={`conversation-configuration-event-${message.messageId}`}
          className="py-2 text-xs text-muted"
        >
          <span className="font-medium">{message.body}</span>
          {fields.map((field) => (
            <span key={field.key}>
              {' '}
              · {field.name}:{' '}
              <VaultText
                value={source[field.label] || source[field.key] || 'None'}
                fallback={source[field.key] || 'None'}
              />{' '}
              →{' '}
              <VaultText
                value={destination[field.label] || destination[field.key] || 'None'}
                fallback={destination[field.key] || 'None'}
              />
            </span>
          ))}
          {metadata.failure_message ? (
            <div className="mt-1 text-danger">{metadata.failure_message}</div>
          ) : null}
        </div>
      );
    }
    if (message.messageType === 'agent_start_clubbed') {
      const count = message.metadata?.count || 2;
      const startMs = message.metadata?.startUnixMs || message.createdUnixMs;
      const endMs = message.metadata?.endUnixMs || message.createdUnixMs;
      const startTime = formatMessageTimestamp(startMs).label;
      const endTime = formatMessageTimestamp(endMs).label;
      const timeStr =
        startTime && endTime ? `${startTime} – ${endTime}` : startTime || endTime || '';
      return (
        <div
          data-debug-id={`conversation-agent-start-clubbed-${message.messageId}`}
          className="my-2 truncate text-sm font-normal text-muted"
        >
          agent started {count} times ({timeStr})
        </div>
      );
    }
    if (isAgentStartMessage(message)) {
      const time = formatMessageTimestamp(message.createdUnixMs).label;
      return (
        <div
          data-debug-id={`conversation-agent-start-${message.messageId}`}
          className="my-2 truncate text-sm font-normal text-muted"
        >
          agent started ({time})
        </div>
      );
    }
    if (message.messageType === PREVIOUS_CONTEXT_MESSAGE_TYPE) {
      return (
        <PreviousContextBlock messageId={message.messageId} metadata={message.metadata}>
          <ThreadMessageBody body={message.body} />
        </PreviousContextBlock>
      );
    }
    if (message.messageType === 'system') {
      return (
        <div
          data-debug-id={`conversation-system-message-${message.messageId}`}
          className="rounded-xl border border-subtle bg-surface px-3 py-2 text-muted"
        >
          <div className="mb-1 flex items-center gap-1.5 text-[10px] font-semibold uppercase tracking-wider text-faint">
            <Icon name="info" size={12} title="System message" />
            System
          </div>
          <div className="text-sm text-primary">
            <ThreadMessageBody body={message.body} />
          </div>
        </div>
      );
    }
    if (message.messageType === 'action') {
      const fireTime = actionRunTime(message.metadata);
      const context = actionMessageContext(message.metadata);
      const eventRun = context.eventType && context.eventType !== 'schedule.fired';
      return (
        <div
          data-debug-id={`conversation-action-message-${message.messageId}`}
          className="rounded-xl border border-subtle bg-surface px-3 py-2 text-sm text-primary"
        >
          <div className="mb-2 flex flex-wrap items-center gap-x-2 gap-y-1 text-caption text-muted">
            <span className="inline-flex items-center gap-1.5">
              <Icon name="clock" size={13} title={eventRun ? "Event action" : "Scheduled action"} />
              {context.actionName ? <VaultText value={context.actionName} as="span" /> : (eventRun ? context.eventType : "Scheduled action")}
            </span>
            {fireTime.label ? <time dateTime={fireTime.timestamp} title={fireTime.timestamp}>· {fireTime.label}</time> : null}
            {context.joinedCount > 0 ? <span>+{context.joinedCount} merged</span> : null}
            {context.movedTo ? <a className="underline underline-offset-2 hover:text-primary" data-debug-id={`conversation-action-moved-${message.messageId}`} href={buildConversationHash([context.movedTo])}>Moved to another machine</a> : null}
          </div>
          <ThreadMessageBody body={message.body} />
          {message.artifactIds && message.artifactIds.length > 0 && (
            <div className="mt-2 flex max-w-full flex-wrap gap-2">
              {message.artifactIds.map((id) => (
                <ArtifactAttachmentPreview
                  key={id}
                  artifactId={id}
                  session={{ daemonUrl: '', clientToken: '' }}
                  debugId={`conversation-thread-artifact-${message.messageId}-${id}`}
                />
              ))}
            </div>
          )}
        </div>
      );
    }
    return (
      <PlainMessageBody body={message.body} artifactIds={message.artifactIds} messageId={message.messageId}
        debugPrefix="conversation-thread" textContent={<ThreadMessageBody body={message.body} reveal={reveal}
          onQuote={!message.isUser && (!message.messageType || message.messageType === 'text') ? async selectedText => {
            const epoch = (reduxStore.getState() as any).composerContext?.epoch;
            const generation = routeGeneration.current;
            const capturedKey = selectActiveVaultKey();
            if (!quoteVaultUnlocked || !quoteTargetId) throw new Error('A chain coordinator and unlocked Vault are required.');
            const coordinator = await resolveQuoteCoordinator({ chainId }, false).unwrap();
            if (!coordinator.coordinatorAgentInstanceId || !coordinator.conversationId) throw new Error('The chain coordinator is unavailable.');
            if (!mountedRef.current || generation !== routeGeneration.current || (reduxStore.getState() as any).composerContext?.epoch !== epoch || currentTargetRef.current !== ownTargetId || selectActiveVaultKey() !== capturedKey) throw new Error('The selection changed. Select the text again.');
            const quote: QuoteContext = { version: 1, id: crypto.randomUUID(), selectedText, capturedAt: Date.now(), source: {
              kind: 'agent_message', messageId: message.messageId, conversationId, agentInstanceId, chainId,
              author: message.authorLabel, createdUnixMs: message.createdUnixMs,
              href: buildConversationHash([routeInstanceId], { extraSearch: { msg: message.messageId } }),
            } };
            const error = quoteLimitError(selectComposerQuotes(reduxStore.getState(), quoteTargetId), quote);
            if (error) throw new Error(error);
            dispatch(addComposerQuote({ target: quoteTargetId, quote }));
            if (ownTargetId !== quoteTargetId) openCurrentChainCoordinator();
          } : undefined}
          quoteDisabledReason={!chainId ? 'This message has no chain coordinator.' : !chainConversationQuery.data?.coordinatorAgentInstanceId ? 'The chain coordinator is unavailable.' : ''} />}>
        {message.metadata?.acp && message.messageStatus === 'failed' && (
          <div role="status" data-debug-id={`conversation-assistant-failed-${message.messageId}`} className="mb-1 text-xs text-muted">Response interrupted.</div>
        )}
      </PlainMessageBody>
    );
  }

  async function toggleRuntime() {
    if (!agentId || !agentInstanceId || runtimeActionBusy) return;
    setStatusMenuOpen(false);
    setReconfigStatus(needsStart ? 'Starting…' : 'Stopping…');
    await (needsStart
      ? lifecycle.start({ agentId, instanceId: agentInstanceId })
      : lifecycle.stop({ agentId, instanceId: agentInstanceId }));
  }

  async function applyReconfigure() {
    if (!agentInstanceId || runtimeActionBusy || stagedConfigurationIssues.length > 0)
      return;
    if (operation?.phase === 'recovery_required') {
      setReconfigStatus('Retrying configuration change…');
      const result = await lifecycle.retry({
        instanceId: agentInstanceId,
        idempotency_key: operation.idempotency_key,
        expected_operation_revision: operation.revision,
      });
      if (result.status === 'accepted') {
        setAcceptedOperation(result.data);
        setReconfigStatus('');
      }
      return;
    }
    const nextProvider = provider || providerOptions[0] || '';
    const nextModel = model || modelOptions[0] || '';
    if (!nextProvider || !nextModel) {
      setReconfigStatus('Choose a provider and model first.');
      return;
    }
    if (draftApplyBlocked) {
      setReconfigStatus(draftApplyBlocked.message);
      return;
    }
    // The panel's draft also stages the connection and bypass; send them only when
    // they change, so the old modal's requests stay exactly as before.
    const draftExtras = {
      ...(draftConfig.transport !== instanceTransport ? { runtime_transport: draftConfig.transport } : {}),
      ...(draftConfig.bypass !== instanceBypass ? { permission_mode: draftConfig.bypass ? 'yolo' as const : 'ask' as const } : {}),
    };
    setRuntimeMenuOpen(false);
    setReconfigStatus(
      `Applying configuration on ${bridgeLabel || instanceBridgeId || 'this bridge'}…`,
    );
    const result = await lifecycle.reconfigure({
      instanceId: agentInstanceId,
      bridge_id: destinationBridgeId,
      project_id: destinationProjectId,
      provider: nextProvider,
      provider_profile: effectiveProfile,
      model: nextModel,
      ...draftExtras,
      expected_revision: Number(instance?.configuration_revision || 0),
      idempotency_key: configurationIntentKey({
        instanceId: agentInstanceId, bridge_id: destinationBridgeId, project_id: destinationProjectId,
        provider: nextProvider, provider_profile: effectiveProfile, model: nextModel, ...draftExtras,
        expected_revision: Number(instance?.configuration_revision || 0),
      }),
    });
    finishConfigurationIntent(result);
    if (result.status === 'accepted') {
      setAcceptedOperation(result.data);
      setReconfigStatus('');
    }
  }

  async function togglePermissionBypass(bypass: boolean) {
    if (!agentInstanceId || !instance || runtimeActionBusy) return;
    setRuntimeMenuOpen(false);
    setReconfigStatus(bypass ? 'Requesting permission bypass…' : 'Requesting permission approvals…');
    const request = permissionToggleRequest(
      { ...instance, agent_instance_id: agentInstanceId }, bypass, '',
    );
    const result = await lifecycle.reconfigure({
      ...request, idempotency_key: configurationIntentKey(request),
    });
    finishConfigurationIntent(result);
    if (result.status === 'accepted') {
      setAcceptedOperation(result.data);
      setReconfigStatus('');
    }
  }

  async function forceStopRuntime() {
    if (
      !agentId ||
      !agentInstanceId ||
      (needsStart && !operationBlocksInput) ||
      lifecycle.isPending('stop') ||
      lifecycle.isPending('reconfigure') ||
      lifecycle.isPending('retry')
    )
      return;
    setReconfigStatus('Force stopping…');
    const result = await lifecycle.stop({
      agentId, instanceId: agentInstanceId, force: true,
    });
    if (result.status === 'accepted') setReconfigStatus('Force stop requested. Waiting for confirmed termination…');
  }

  async function restartRuntime() {
    if (!agentId || !agentInstanceId || runtimeActionBusy || needsStart) return;
    setReconfigStatus('Restarting…');
    const result = await lifecycle.restart({ agentId, instanceId: agentInstanceId });
    if (result.status === 'accepted') setReconfigStatus('');
  }

  function resetRuntimeConfiguration() {
    settingsEditedRef.current = false;
    setStagedBridgeId(null);
    setStagedTransport(null);
    setStagedBypass(null);
    setDraftBridgeCheck(null);
    setProvider(instanceProvider);
    setProviderProfile(String(instance?.provider_profile || instanceProvider));
    setModel(instanceModel);
    setReconfigStatus('');
  }

  const pendingReconfig =
    selectionChangesConfig || draftChanges.length > 0 || operation?.phase === 'recovery_required';
  // Morphing composer: a 56px pill that grows into the full card while focused or while
  // anything below holds it open (MessageComposer.tsx useComposerExpanded).
  const composerExpansion = useComposerExpanded({
    // Raw value: whitespace-only and restored drafts keep it open.
    draft: trayModeItem ? trayDraft : draft,
    hasAttachments: attachments.length > 0,
    hasQuotes: !trayModeItem && quotes.length > 0,
    borrowed: Boolean(trayModeItem),
    menuOpen: statusMenuOpen || runtimeMenuOpen || mentionQuery !== null,
    uploadActive: filePickerOpen || hasUploadingAttachments || voice.active,
    // The open settings panel owns Apply (one primary action per decision).
    // With the panel enabled its footer owns Apply (one primary action per decision).
    pendingActions: pendingReconfig && !settingsPanelEnabled,
    readOnly: conversationReadOnly,
  });
  const permissionToggle = permissionToggleState({
    catalogExtension: instanceCatalogExtension,
    instance,
    busy:
      runtimeActionBusy || operationBlocksInput || isStarting || runtimeStopping || !agentInstanceId,
    pendingChanges: pendingReconfig,
  });
  const runtimeStatusCard = (
    <div className="mb-4 flex flex-wrap items-center justify-between gap-3 rounded-xl border border-subtle p-3">
      <span className="inline-flex items-center gap-2 text-sm text-primary">
        <StatusDot
          size="sm"
          tone={runtimeStatusToTone(runtimeStatus)}
          label={needsStart ? 'Stopped' : 'Running'}
        />
        {needsStart
          ? 'Stopped'
          : runtimeStopping
          ? 'Stopping…'
          : isStarting
          ? 'Starting…'
          : 'Running'}
      </span>
      <div className="flex gap-2">
        <button
          type="button"
          data-debug-id="conversation-runtime-modal-toggle-btn"
          disabled={
            !agentInstanceId ||
            runtimeActionBusy ||
            runtimeStopping ||
            operationBlocksInput ||
            (needsStart && conversationReadOnly)
          }
          onClick={() => void toggleRuntime()}
          className="min-h-11 rounded-xl border border-subtle px-3 text-sm text-primary disabled:opacity-40"
        >
          {needsStart ? 'Start agent' : 'Stop agent'}
        </button>
        <button
          type="button"
          data-debug-id="conversation-runtime-force-stop-btn"
          disabled={
            !agentInstanceId ||
            (needsStart && !operationBlocksInput) ||
            lifecycle.isPending('stop') ||
            lifecycle.isPending('reconfigure') ||
            lifecycle.isPending('retry') ||
            instanceBridge?.runtime_connected !== true
          }
          onClick={() => void forceStopRuntime()}
          className="min-h-11 rounded-xl border border-danger/30 px-3 text-sm text-danger disabled:opacity-40"
        >
          Force stop
        </button>
      </div>
    </div>
  );
  // Bypass, project and bridge/provider/model pickers: the old modal's body, also the
  // panel's interim configuration slot until T6 lands sections 2-5.
  const runtimeConfigControls = (
    <>
      {permissionToggle.visible ? (
        <div
          data-debug-id="conversation-permission-toggle"
          className="mb-4 rounded-xl border border-subtle p-3"
        >
          <label className="flex min-h-11 items-center justify-between gap-3 text-sm text-primary">
            <span>
              <span className="block font-medium">Bypass permissions</span>
              <span className="block text-xs text-muted">
                {permissionToggle.bypass
                  ? 'The agent runs tools without asking.'
                  : 'The agent asks before running tools; approve them here.'}{' '}
                Applies to this running agent and restarts it. The agent&apos;s
                default is set in its settings.
              </span>
            </span>
            <input
              type="checkbox"
              role="switch"
              data-debug-id="conversation-permission-toggle-input"
              aria-checked={permissionToggle.bypass}
              checked={permissionToggle.bypass}
              disabled={permissionToggle.disabled}
              onChange={(e) => void togglePermissionBypass(e.target.checked)}
              className="h-5 w-5 shrink-0 accent-accent disabled:opacity-40"
            />
          </label>
          {permissionToggle.hint ? (
            <p
              data-debug-id="conversation-permission-toggle-hint"
              className="mt-1 text-xs text-muted"
            >
              {permissionToggle.hint}
            </p>
          ) : null}
        </div>
      ) : null}
      <div className="mb-4 rounded-xl bg-neutral-soft px-3 py-2 text-xs text-muted">
        Project:{' '}
        {projectId ? (
          <VaultText value={projectName} fallback="Project" />
        ) : (
          'No project'
        )}
      </div>
      <RuntimeConfigurationOptions
        debugPrefix="conversation"
        bridges={bridges}
        selection={{ bridgeId: destinationBridgeId, provider, providerProfile: effectiveProfile, model }}
        requireReconfiguration
        disabled={runtimeActionBusy || operationBlocksInput || isStarting}
        onChange={(next) => {
          settingsEditedRef.current = true;
          setStagedBridgeId(next.bridgeId);
          setProvider(next.provider);
          setProviderProfile(next.providerProfile || next.provider);
          setModel(next.model);
        }}
      />
      <div className="mt-1.5 flex items-center gap-2 border-t border-subtle px-2 pt-2 text-[12px] text-muted">
        <Icon
          name="alert"
          size={14}
          className={pendingReconfig ? 'text-warning' : 'text-faint'}
        />
        <span>
          <span
            className={`font-semibold ${
              pendingReconfig ? 'text-warning' : 'text-muted'
            }`}
          >
            Restarts the agent
          </span>{' '}
          — choose Apply to confirm.
        </span>
      </div>
      {pendingReconfig && stagedConfigurationIssues.length ? (
        <ul
          data-debug-id="conversation-destination-validation"
          className="mt-2 list-disc space-y-1 pl-5 text-xs text-danger"
        >
          {stagedConfigurationIssues.map((issue) => (
            <li key={issue}>{issue}</li>
          ))}
        </ul>
      ) : null}
      {/* In the panel the Runtime card shows this message. */}
      {reconfigStatus && !settingsPanel.open ? (
        <div
          data-debug-id="conversation-reconfigure-status"
          className="px-2 pt-1 text-caption text-muted"
        >
          {reconfigStatus}
        </div>
      ) : null}
    </>
  );
  const runtimeSection = settingsPanel.open ? (
    <RuntimeSection
      view={runtimeSectionView({
        runtimeStatus,
        startupStatus,
        activityStatus,
        startedAt: String(instance?.started_at || instance?.startedAt || ''),
        stopReason: String(instance?.stop_reason || ''),
        operations: operationQuery.data?.operations,
        operationInFlight,
        restartPending: lifecycle.isPending('restart') || applyFlow.state.phase === 'restarting',
        now: panelNow,
      })}
      bridgeLabel={bridgeLabel}
      provider={instanceProvider}
      model={instanceModel}
      transport={instance?.runtime_transport === 'acp' ? 'acp' : 'pty'}
      folder={String(instance?.project_path || '')}
      agentLabel={agentInstanceLabel}
      touch={settingsPanel.mode === 'page'}
      actionsDisabled={
        !agentInstanceId ||
        runtimeActionBusy ||
        runtimeStopping ||
        operationBlocksInput ||
        (needsStart && conversationReadOnly)
      }
      forceStopDisabled={
        !agentInstanceId ||
        (needsStart && !operationBlocksInput) ||
        lifecycle.isPending('stop') ||
        lifecycle.isPending('reconfigure') ||
        lifecycle.isPending('retry') ||
        instanceBridge?.runtime_connected !== true
      }
      pendingAction={
        lifecycle.isPending('restart') ? 'restart'
          : lifecycle.isPending('start') ? 'start'
            : lifecycle.isPending('stop') ? 'stop'
              : null
      }
      statusMessage={reconfigStatus}
      onStart={() => void toggleRuntime()}
      onStop={() => void toggleRuntime()}
      onRestart={() => void restartRuntime()}
      onForceStop={() => void forceStopRuntime()}
    />
  ) : null;
  // Sections 2-5 (T6): every control edits the draft above; nothing applies on click.
  const draftBridgeLabel = bridgeLabelOf(destinationBridgeId);
  const draftProviderOption = draftProviderOptions.find((p) => p.id === (draftConfig.providerProfile || draftConfig.provider));
  // A change queued after this turn locks the draft: the footer shows and Restart now
  // sends exactly what is queued; Cancel it to edit again.
  const draftControlsDisabled = !agentInstanceId || runtimeActionBusy || operationBlocksInput || isStarting
    || operation?.phase === 'waiting_for_idle';
  const panelTouch = settingsPanel.mode === 'page';
  const settingsSections = settingsPanel.open ? (
    <>
      <BridgeSection
        view={bridgeRowsView({
          bridges,
          currentBridgeId: instanceBridgeId,
          projectId,
          bridgePaths: projectQuery.data?.bridge_paths || [],
          defaultPath: String(projectQuery.data?.project?.default_path || ''),
          currentFolder: String(instance?.project_path || ''),
        })}
        selected={destinationBridgeId}
        onSelect={(id) => dispatchDraft({ type: 'bridge', bridgeId: id, providers: null })}
        manageFoldersHref={projectId ? projectEditHref(projectId) : undefined}
        disabled={draftControlsDisabled}
        loading={!bridgesQuery.data}
        touch={panelTouch}
      />
      <ModelSection
        providers={draftProviderOptions}
        loaded={draftProvidersLoaded}
        selectedProvider={draftConfig.providerProfile || draftConfig.provider}
        selectedModel={draftConfig.model}
        bridgeLabel={draftBridgeLabel}
        onSelectProvider={(id) => dispatchDraft({ type: 'provider', id, providers: draftProviderOptions })}
        onSelectModel={(next) => dispatchDraft({ type: 'model', model: next })}
        onRefresh={() => void refreshDraftModels()}
        refreshing={refreshModelsState.isLoading}
        checkedAt={lastCheckedAt(draftProviderOptions)}
        refreshError={draftRefreshError}
        disabled={draftControlsDisabled}
        touch={panelTouch}
      />
      <ConnectionSection
        selected={draftConfig.transport}
        onSelect={(transport) => dispatchDraft({ type: 'transport', transport })}
        acp={acpAvailabilityCopy(draftProviderOption?.acp, {
          provider: providerLabelOf(draftConfig),
          bridge: draftBridgeLabel,
        })}
        onFix={(fix) => void fixDraftConnection(fix)}
        fixPending={discoverProvidersState.isLoading || updateBridgeState.isLoading || installAcpState.isLoading}
        fixError={draftFixError}
        disabled={draftControlsDisabled}
        touch={panelTouch}
      />
      <PermissionsSection
        bypass={draftConfig.bypass}
        transport={draftConfig.transport}
        providerLabel={providerLabelOf(draftConfig)}
        onChange={(bypass) => dispatchDraft({ type: 'bypass', bypass })}
        disabled={draftControlsDisabled}
        touch={panelTouch}
      />
    </>
  ) : null;
  const destinationFolder = bridgeRowsView({
    bridges,
    currentBridgeId: instanceBridgeId,
    projectId,
    bridgePaths: projectQuery.data?.bridge_paths || [],
    defaultPath: String(projectQuery.data?.project?.default_path || ''),
    currentFolder: String(instance?.project_path || ''),
  }).rows.find((row) => row.bridgeId === destinationBridgeId)?.folder || '';
  const applyFooter = settingsPanel.open ? (
    <ApplyFooter
      view={applyFooterView({
        changes: applyFlow.changes,
        flow: applyFlow.state,
        midTurn: isWorking,
        stopped: needsStart,
        destinationBridge: draftBridgeLabel,
        destinationFolder,
        blockedMessage: draftApplyBlocked?.message || '',
        issues: applyFlow.changes.length ? stagedConfigurationIssues : [],
        busy:
          !agentInstanceId ||
          runtimeActionBusy ||
          (operation?.phase !== 'recovery_required' && (operationBlocksInput || isStarting || runtimeStopping)),
        now: panelNow,
      })}
      touch={panelTouch}
      onApply={() => void (operation?.phase === 'recovery_required' ? applyFlow.retry() : applyFlow.apply())}
      onRestartNow={() => void applyFlow.restartNow()}
      onCancel={() => void applyFlow.cancelWaiting()}
      onDiscard={() => { applyFlow.clear(); resetRuntimeConfiguration(); }}
    />
  ) : null;
  const runtimeControls = (
    <div data-debug-id="conversation-runtime-controls" className="text-left">
      {runtimeStatusCard}
      {runtimeConfigControls}
    </div>
  );

  function renderComposer() {
    const activeProvider = instanceProvider || provider;
    const showNeedYouPill = needYouPillVisible(trayState, trayItemList.length);
    const composerInput = (
      <MessageComposerInput
        mobile={isMobile}
        morph
        debugId="conversation-composer-input"
        ref={textareaRef}
        value={trayModeItem ? trayDraft : draft}
        disabled={normalSendBusy || (trayModeItem ? false : configurationInputBlocked)}
        onChange={(e) => {
          if (desktopUpdateFrozen()) return;
          if (trayModeItem) {
            setTrayDraft(e.target.value);
            return;
          }
          updateDraft(e.target.value);
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
          if (mentionQuery !== null && filteredMentions.length > 0) {
            if (e.key === 'ArrowDown') {
              e.preventDefault();
              setMentionIndex((i) => (i + 1) % filteredMentions.length);
              return;
            }
            if (e.key === 'ArrowUp') {
              e.preventDefault();
              setMentionIndex(
                (i) => (i - 1 + filteredMentions.length) % filteredMentions.length,
              );
              return;
            }
            if (e.key === 'Enter') {
              e.preventDefault();
              handleMentionSelect(filteredMentions[mentionIndex]);
              return;
            }
            if (e.key === 'Escape') {
              e.preventDefault();
              setMentionQuery(null);
              return;
            }
          }
          if (e.key === 'Enter' && (e.metaKey || e.ctrlKey)) {
            e.preventDefault();
            void submit(e as any);
          }
          if (e.key === 'Escape' && trayModeItem) {
            e.preventDefault();
            dispatchTray({ type: 'cancel_mode' });
          }
        }}
        onPaste={handleComposerPaste}
        placeholder={
          trayMode && trayModeItem
            ? TRAY_MODE_COPY[trayMode.kind].placeholder
            : isMobile
            ? 'Message the agent…'
            : 'Message the agent… (Cmd/Ctrl+Enter to send)'
        }
      />
    );
    const composerActions = {
      debugPrefix: 'conversation',
      mobile: isMobile,
      compactModel: isSmallComposer,
      provider: activeProvider,
      model: instanceModel,
      onSettings: openAgentSettings,
      onUpload: openAttachmentPicker,
      uploadDisabled: normalSendBusy || (trayModeItem ? false : configurationInputBlocked),
      onRecord: () => { if (!desktopUpdateFrozen()) void voice.recorder.start(); },
      // Tray-mode replies need typed text (artifacts ride along as links), so a voice note
      // alone could not be sent there: the mic is off while a tray item is borrowed.
      recordDisabled: voice.recorder.phase !== 'idle' || normalSendBusy || Boolean(trayModeItem) || configurationInputBlocked,
      recordActive: voice.recorder.phase !== 'idle',
      sendDisabled,
      paneExpanded: false,
      onPaneToggle: handleOpenPtyTab,
      onOpenTasks: chainId ? () => openAux({ type: 'tasks' }) : undefined,
    };
    const runtimeLabel = needsStart
      ? 'Stopped'
      : runtimeStopping
      ? 'Stopping…'
      : isStarting
      ? 'Starting…'
      : isWorking
      ? 'Working…'
      : 'Running';
    const runtimeStatusMenu = (
      <Menu
        side="top"
        align="end"
        label="Runtime status"
        open={statusMenuOpen}
        onOpenChange={setStatusMenuOpen}
        trigger={
          <button
            type="button"
            data-debug-id="conversation-runtime-status-chip"
            data-status={runtimeStateFromStatus(runtimeStatus)}
            aria-label={`Agent ${runtimeLabel.replace('…', '').toLowerCase()}. Start or stop the agent`}
            title={`${runtimeLabel} — start/stop the agent`}
            // Sits on the morph context row's 20px line: the negative margins keep the row
            // height while the button keeps a larger hit area; the hover disc is inner.
            className={`group grid shrink-0 place-items-center rounded-full ${isMobile ? '-my-2.5 -mr-2.5 h-10 w-10' : '-my-2 -mr-2 h-9 w-9'}`}
          >
            <span className="grid h-6 w-6 place-items-center rounded-full group-hover:bg-neutral-soft">
              <MessageComposerStatus
                debugPrefix="conversation"
                tone={runtimeStatusToTone(runtimeStatus)}
                label={runtimeLabel}
              />
            </span>
          </button>
        }
      >
        <Menu.Label>Runtime: {runtimeLabel}</Menu.Label>
        <Menu.Item
          data-debug-id="conversation-runtime-status-toggle-btn"
          disabled={!agentInstanceId || runtimeActionBusy || runtimeStopping}
          onClick={() => void toggleRuntime()}
          className={needsStart ? 'text-success' : 'text-danger'}
        >
          <Icon name={needsStart ? 'play' : 'stop'} size={15} />
          <span>{needsStart ? 'Start agent' : 'Stop agent'}</span>
        </Menu.Item>
        {reconfigStatus ? <Menu.Label>{reconfigStatus}</Menu.Label> : null}
      </Menu>
    );
    return (
      <FloatingComposerForm mobile={isMobile} raised={showNeedYouPill}
        ref={composerContainerRef as any}
        onSubmit={submit}
        data-debug-id="conversation-composer-shell"
>
        <div className="mx-auto w-full max-w-4xl">
          {vaultSendBlocked ? (
            <div
              data-debug-id="conversation-composer-vault-blocked"
              role="status"
              className="mb-2 rounded-xl border border-subtle bg-surface-raised px-3 py-2 text-xs text-secondary"
            >
              {vaultSendBlocked.message}
            </div>
          ) : null}
          {error ? (
            <div
              data-debug-id="conversation-composer-send-error"
              className="mb-2 rounded-xl border border-danger/30 bg-danger-soft px-3 py-2 text-xs text-danger"
            >
              {error}
            </div>
          ) : null}
          {!trayModeItem ? <ComposerContextChips quotes={quotes} disabled={normalSendBusy}
            onRemove={id => dispatch(removeComposerQuote({ target: ownTargetId, id }))} /> : null}
          <ComposerAttachmentTray attachments={attachments} isMobile={isMobile} disabled={normalSendBusy}
            onRetry={a => void uploadAttachment(a.file, a.localId)}
            onRemove={localId => setAttachments(prev => prev.filter(item => item.localId !== localId))} />
          <VoiceRecorderPanel recorder={voice.recorder} isMobile={isMobile} debugPrefix="conversation"
            sendDisabled={normalSendBusy} onSend={voice.send} />
          <input
            ref={fileInputRef}
            data-debug-id="conversation-attach-input"
            type="file"
            multiple
            className="hidden"
            onChange={handleAttachmentInput}
          />
          <FloatingComposerCard
            expansion={composerExpansion}
            debugPrefix="conversation"
            debugId="conversation-composer-card"
            // REQ-FROST-1/2: the frost rim and stacked backdrop layers stay; the shell owns
            // geometry, borders while open, and motion.
            leading={<>
              {showNeedYouPill ? (
                <div className="absolute -top-4 right-4 z-10">
                  <NeedYouPill
                    count={trayItemList.length}
                    onClick={() => dispatchTray({ type: 'show_items' })}
                  />
                </div>
              ) : null}
              {trayMode && trayModeItem ? (
                <div
                  data-debug-id="conversation-composer-tray-mode"
                  className="mt-4 flex min-w-0 items-center gap-2 rounded-xl bg-warning-soft py-1 pl-2.5 pr-1 text-[13px] text-warning"
                >
                  <Icon name={trayMode.kind === 'answer' ? 'chat' : 'pencil'} size={14} className="shrink-0" />
                  <span className="min-w-0 flex-1 truncate">
                    {TRAY_MODE_COPY[trayMode.kind].banner}{' '}
                    <strong className="font-semibold">
                      <VaultText value={trayModeItem.title} fallback="this task" />
                    </strong>
                  </span>
                  <button
                    type="button"
                    aria-label="Cancel"
                    data-debug-id="conversation-composer-tray-mode-cancel"
                    onClick={() => dispatchTray({ type: 'cancel_mode' })}
                    className="grid h-8 w-8 shrink-0 place-items-center rounded-full hover:bg-surface-raised"
                  >
                    <Icon name="close" size={14} />
                  </button>
                </div>
              ) : null}
              {replacedCoordinator ? (
                <div
                  data-debug-id="conversation-replaced-coordinator"
                  role="status"
                  className="mt-4 flex flex-wrap items-center justify-between gap-2 rounded-xl border border-subtle bg-neutral-soft px-3 py-2 text-xs text-muted"
                >
                  <span className="min-w-0 flex-1">
                    This agent no longer coordinates{' '}
                    <VaultText value={chainTitle} fallback="this task chain" as="span" />.
                  </span>
                  <button
                    type="button"
                    data-debug-id="conversation-open-chain-coordinator-btn"
                    onClick={openCurrentChainCoordinator}
                    className="min-h-9 rounded-lg border border-subtle px-3 text-xs font-medium text-primary hover:bg-surface-raised"
                  >
                    Open current coordinator
                  </button>
                </div>
              ) : null}
              {pendingReconfig && !settingsPanelEnabled && stagedConfigurationIssues.length > 0 ? (
                <div
                  data-debug-id="conversation-apply-blocked-reasons"
                  role="status"
                  className="mt-4 rounded-xl border border-subtle px-3 py-2 text-xs text-muted"
                >
                  <div className="font-medium text-primary">
                    Changes cannot be applied yet
                  </div>
                  <ul className="mt-1 list-disc pl-4">
                    {stagedConfigurationIssues.map((issue) => (
                      <li key={issue}>{issue}</li>
                    ))}
                  </ul>
                </div>
              ) : null}
              {operation && !isCancelledReconfiguration(operation) ? (
                <InstanceReconfigurationProgress operation={operation} />
              ) : null}
              {operationBlocksInput ? (
                <div className="mt-4 flex flex-wrap items-center justify-between gap-3 rounded-xl border border-subtle px-3 py-2">
                  <p className="min-w-0 flex-1 text-xs text-muted">
                    {operation?.failure_code === 'force_stopping'
                      ? 'Waiting for confirmed termination. Settings will unlock once the agent is stopped.'
                      : 'To change the model or bridge, force stop this run first. Settings unlock after the bridge confirms termination.'}
                  </p>
                  <button
                    type="button"
                    data-debug-id="conversation-recovery-force-stop-btn"
                    disabled={
                      lifecycle.isPending('stop') ||
                      lifecycle.isPending('reconfigure') ||
                      lifecycle.isPending('retry') ||
                      instanceBridge?.runtime_connected !== true
                    }
                    onClick={() => void forceStopRuntime()}
                    className="min-h-10 rounded-xl border border-danger/30 px-3 text-sm text-danger disabled:opacity-40"
                  >
                    Force stop
                  </button>
                </div>
              ) : null}
              {!operationInFlight &&
              (runtimeStopping || isStarting || reconfigStatus) ? (
                <div
                  data-debug-id="conversation-runtime-transition"
                  role="status"
                  aria-live="polite"
                  className="mt-4 rounded-xl border border-subtle bg-neutral-soft px-3 py-2 text-sm"
                >
                  <div className="font-medium text-primary">
                    {runtimeStopping
                      ? 'Stopping agent'
                      : isStarting
                      ? 'Starting agent'
                      : 'Runtime configuration'}
                  </div>
                  <div className="mt-0.5 truncate text-xs text-muted">
                    {bridgeLabel || instanceBridgeId || 'Current bridge'}
                    {projectId ? (
                      <>
                        {' '}
                        · <VaultText value={projectName} fallback="Project" />
                      </>
                    ) : null}
                  </div>
                  {reconfigStatus ? (
                    <div className="mt-1 text-xs text-muted">{reconfigStatus}</div>
                  ) : null}
                </div>
              ) : null}
            </>}
            // Reference context row: bridge · project, runtime status (start/stop menu) at the end.
            context={
              <div
                data-debug-id="conversation-composer-context"
                className="flex min-w-0 items-center gap-x-2 text-[13px] font-semibold leading-5 text-muted"
              >
                <div className="flex min-w-0 flex-1 items-center gap-2 overflow-hidden">
                  <button
                    type="button"
                    onClick={openAgentSettings}
                    aria-haspopup="dialog"
                    aria-label="Change bridge, provider or model"
                    data-debug-id="conversation-composer-bridge-chip"
                    className="inline-flex min-w-0 max-w-[50%] shrink items-center gap-1.5 rounded-md hover:text-primary"
                    title={`Bridge: ${bridgeLabel || '—'} (current location)`}
                  >
                    <Icon name="device" size={16} className="shrink-0" />
                    <span className="min-w-0 truncate">
                      {bridgeLabel || 'no bridge'}
                    </span>
                  </button>
                  {projectId && !isAuxSubagent ? (
                    <>
                      <span aria-hidden="true" className="shrink-0 text-faint">·</span>
                      {/* The chip opens Project Explorer files only while it is enabled
                          (REQ-EXP-GATE-2); otherwise it just names the project. */}
                      <button
                        type="button"
                        data-debug-id="conversation-composer-project-chip"
                        disabled={!projectVcsEnabled}
                        onClick={projectVcsEnabled ? () => openAux({ type: 'files' }) : undefined}
                        title={projectVcsEnabled ? `Open project files — ${projectName}` : `Project — ${projectName}`}
                        className="inline-flex min-w-0 max-w-[50%] shrink items-center gap-1.5 rounded-md enabled:hover:text-primary disabled:cursor-default"
                      >
                        <Icon name="folder" size={16} className="shrink-0" />
                        <span className="min-w-0 truncate">
                          <VaultText value={projectName} fallback="Project" />
                        </span>
                      </button>
                    </>
                  ) : null}
                </div>
                {!conversationReadOnly ? <div className="ml-auto flex shrink-0">{runtimeStatusMenu}</div> : null}
              </div>
            }
            actions={
              <MessageComposerActions
                {...composerActions}
                readOnly={conversationReadOnly}
                pendingActions={
                  // With the settings panel enabled its staged-changes footer owns
                  // Discard/Apply for the draft, so the composer shows none.
                  pendingReconfig && !settingsPanelEnabled ? (
                    <div className="flex items-center gap-2">
                      <button
                        type="button"
                        data-debug-id="conversation-reconfigure-reset-btn"
                        disabled={runtimeActionBusy || operationBlocksInput}
                        onClick={resetRuntimeConfiguration}
                        className="rounded-xl border border-subtle px-4 py-2 text-sm text-primary disabled:opacity-40"
                      >
                        Reset
                      </button>
                      <button
                        type="button"
                        data-debug-id="conversation-reconfigure-apply-btn"
                        disabled={
                          runtimeActionBusy ||
                          (operation?.phase !== 'recovery_required' &&
                            (isStarting || runtimeStopping)) ||
                          stagedConfigurationIssues.length > 0 ||
                          Boolean(draftApplyBlocked)
                        }
                        onClick={() => void applyReconfigure()}
                        className="rounded-xl bg-accent px-4 py-2 text-sm font-semibold text-accent-fg disabled:opacity-40"
                      >
                        Apply
                      </button>
                    </div>
                  ) : undefined
                }
                morph={composerExpansion}
              />
            }
          >
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
              {conversationReadOnly ? (
                <div
                  data-debug-id="conversation-configuration-read-only"
                  role="status"
                  aria-live="polite"
                  className="mt-4 rounded-xl border border-subtle bg-neutral-soft px-4 py-3 text-sm"
                >
                  <div className="font-semibold text-primary">
                    This conversation is read-only
                  </div>
                  <p className="mt-1 text-xs text-muted">
                    Messages are disabled until the following configuration issues are
                    resolved.
                  </p>
                  <ul className="mt-2 list-disc space-y-1 pl-4 text-xs text-muted">
                    {configurationIssues.map((issue) => (
                      <li key={issue}>{issue}</li>
                    ))}
                  </ul>
                </div>
              ) : (
                composerInput
              )}
            </div>
          </FloatingComposerCard>
        </div>
      </FloatingComposerForm>
    );
  }

  if (!conversation && convQuery.isFetching) {
    return (
      <div
        data-debug-id={`workbench-agent-chat-pane-${agentInstanceId}`}
        className="flex h-full min-h-0 w-full flex-col overflow-hidden bg-canvas p-6 text-left"
      >
        <div
          data-debug-id="conversation-thread-resolving"
          className="grid min-h-[220px] place-items-center text-sm text-muted"
        >
          Loading conversation…
        </div>
      </div>
    );
  }

  if (!conversation && !convQuery.isFetching) {
    return (
      <div
        data-debug-id={`workbench-agent-chat-pane-${agentInstanceId}`}
        className="flex h-full min-h-0 w-full flex-col overflow-hidden bg-canvas text-left"
      >
        {!isAuxSubagent && (onReplaceWithNew || (isMultiPane && onClosePane) || headerLeading || headerEnd) ? (
          // Minimal header so a pane whose conversation is missing can still be
          // replaced or closed.
          <header
            data-debug-id="conversation-thread-header-minimal"
            className={`window-drag flex ${isMobile ? 'min-h-14' : 'min-h-12'} shrink-0 items-center justify-end gap-1 px-3 py-2`}
          >
            {headerLeading ? <div className="mr-auto flex items-center gap-1">{headerLeading}</div> : null}
            {onReplaceWithNew ? (
              <button
                type="button"
                data-debug-id="conversation-replace-with-new-action"
                onClick={onReplaceWithNew}
                className="inline-flex h-8 items-center gap-1.5 rounded-lg px-2 text-xs text-muted hover:bg-neutral-soft hover:text-primary"
              >
                <Icon name="plus" size={14} />
                <span>Replace with New</span>
              </button>
            ) : null}
            {isMultiPane && onClosePane ? (
              <button
                type="button"
                data-debug-id="conversation-remove-from-split-action"
                aria-label="Close pane"
                title="Close pane"
                onClick={onClosePane}
                className={`grid ${chromeIconButtonSizeClass(isMobile)} place-items-center text-muted hover:bg-neutral-soft hover:text-primary`}
              >
                <Icon name="close" size={16} />
              </button>
            ) : null}
            {headerTrailing}
            {headerEnd}
          </header>
        ) : null}
        <div className="mx-auto mt-6 w-full max-w-4xl rounded-[2rem] border border-subtle bg-surface p-6">
          <h2 className="text-xl font-semibold text-primary">Conversation not found</h2>
          <p className="mt-2 text-sm text-muted">
            No conversation for instance{' '}
            <span className="font-mono">{routeInstanceId}</span> for this user.
          </p>
          <a
            data-debug-id="conversation-thread-back-btn"
            href="#/conversations/new"
            className="mt-4 inline-flex rounded-2xl bg-accent px-4 py-2 text-sm font-bold text-accent-fg hover:opacity-90"
          >
            Start a new conversation
          </a>
        </div>
      </div>
    );
  }

  return (
    <div
      data-debug-id={`workbench-agent-chat-pane-${agentInstanceId}`}
      className="relative flex h-full w-full min-h-0 min-w-0 flex-1 flex-row overflow-hidden bg-canvas text-left"
    >
      {/* Conversation column; the Agent settings panel is its flex sibling. */}
      <div
        data-debug-id="conversation-thread-column"
        className="relative flex h-full min-h-0 min-w-0 flex-1 flex-col overflow-hidden"
      >
      {/* Scoped top bar in Chat Pane (absent in an aux sub-agent tab: transcript + composer only) */}
      {!isAuxSubagent ? (
      <header
        data-debug-id="conversation-thread-header"
        data-pane-active={isFocusedPane ? 'true' : 'false'}
        className={`window-drag sticky top-0 z-20 flex ${isMobile ? 'min-h-14' : 'min-h-12'} shrink-0 items-center gap-2 px-3 py-2 sm:gap-3 sm:px-4 bg-canvas/90 backdrop-blur-md overflow-visible`}
      >
        <div
          data-debug-id="conversation-topbar-blur-fade"
          className="pointer-events-none absolute left-0 right-0 -bottom-6 h-6 bg-gradient-to-b from-canvas/90 via-canvas/50 to-transparent backdrop-blur-sm z-10"
          aria-hidden="true"
        />

        <div className="flex min-w-0 flex-1 items-center justify-start gap-1.5">
          {headerLeading ? (
            <div data-debug-id="conversation-header-leading" className="flex shrink-0 items-center gap-1">
              {headerLeading}
            </div>
          ) : null}
          {renaming ? (
            <div className="flex min-w-0 flex-1 items-center gap-2">
              <input
                data-debug-id="conversation-thread-title-input"
                value={titleDraft}
                onChange={(event) => {
                  setTitleDraft(event.target.value);
                  setTitleError('');
                }}
                onKeyDown={(event) => {
                  if (event.key === 'Enter') {
                    event.preventDefault();
                    void saveRenameTitle();
                  }
                  if (event.key === 'Escape') {
                    setRenaming(false);
                    setTitleError('');
                    setTitleDraft(renameSeed);
                  }
                }}
                aria-label={renameTarget.inputLabel}
                className={`${isMobile ? 'min-h-11' : 'min-h-9'} min-w-0 flex-1 rounded-xl border border-subtle bg-surface px-3 py-1.5 text-base font-semibold text-primary outline-none focus:border-accent sm:text-sm`}
                autoFocus
              />
              <button
                type="button"
                data-debug-id="conversation-thread-title-save-btn"
                aria-label={renameTarget.saveLabel}
                title="Save"
                onClick={() => void saveRenameTitle()}
                disabled={updateTitleState.isLoading || updateChainState.isLoading || !titleDraft.trim()}
                className={`grid ${isMobile ? 'h-11 w-11 rounded-full' : 'h-9 w-9 rounded-xl'} shrink-0 place-items-center bg-accent text-accent-fg hover:opacity-90 disabled:opacity-50`}
              >
                <Icon name="check" size={16} />
              </button>
              <button
                type="button"
                data-debug-id="conversation-thread-title-cancel-btn"
                aria-label={renameTarget.cancelLabel}
                title="Cancel"
                onClick={() => {
                  setRenaming(false);
                  setTitleError('');
                  setTitleDraft(renameSeed);
                }}
                className={`grid ${isMobile ? 'h-11 w-11 rounded-full' : 'h-9 w-9 rounded-xl'} shrink-0 place-items-center border border-subtle bg-surface-raised text-muted hover:bg-neutral-soft hover:text-primary`}
              >
                <Icon name="close" size={16} />
              </button>
            </div>
          ) : (
            <div
              data-debug-id="conversation-thread-breadcrumb"
              className="flex min-w-0 items-center gap-1.5 text-sm font-medium"
            >
              {!isMobile ? (
                <>
                  <span
                    data-debug-id="conversation-breadcrumb-project"
                    data-pane-crumb
                    className="truncate text-muted"
                  >
                    <VaultText value={projectName} fallback="Project" />
                  </span>
                  <span className="shrink-0 text-faint">/</span>
                </>
              ) : null}
              <button
                type="button"
                data-debug-id="conversation-thread-title"
                data-pane-crumb
                aria-label="Select task chain"
                title="Click to search and select task chains"
                onClick={() => {
                  setChainSelectorPlacement('replace');
                  setChainSelectorOpen(true);
                }}
                className={`group flex min-w-0 items-center gap-1.5 rounded-md px-1.5 py-0.5 text-left ${isMobile ? 'min-h-11 text-[15px]' : 'text-sm'} font-medium text-primary hover:bg-neutral-soft hover:text-accent transition-colors cursor-pointer`}
              >
                <span className="truncate">
                  <VaultText value={chainTitle || title} as="span" />
                </span>
                <Icon
                  name="chevron-down"
                  size={13}
                  className="shrink-0 text-muted group-hover:text-accent"
                />
              </button>
              <span className="shrink-0 text-faint">/</span>
              <button
                type="button"
                data-debug-id="conversation-chain-agent-switcher-btn"
                data-pane-crumb
                aria-label="Switch agent in this task chain"
                aria-haspopup="dialog"
                aria-expanded={chainAgentSwitcherOpen}
                onClick={() => {
                  setChainAgentSwitcherOpen(true);
                  refetchIfStarted(chainDetailQuery);
                }}
                className={`flex min-w-0 items-center gap-1.5 rounded-md px-1.5 py-0.5 text-primary hover:bg-neutral-soft ${isMobile ? 'min-h-11 text-[15px]' : ''}`}
              >
                {/* REQ-PORT-5: on mobile the runtime dot lives in the composer card instead. */}
                {!isMobile ? (
                  <StatusDot
                    size="sm"
                    tone={runtimeStatusToTone(runtimeStatus)}
                    label={
                      needsStart
                        ? 'Stopped'
                        : runtimeStopping
                        ? 'Stopping'
                        : isStarting
                        ? 'Starting'
                        : 'Running'
                    }
                  />
                ) : null}
                <span className="truncate">
                  <VaultText value={agentBreadcrumbLabel} fallback="Agent" />
                </span>
                <Icon name="chevron-down" size={13} className="shrink-0 text-muted" />
              </button>
            </div>
          )}
          {titleError ? (
            <div
              data-debug-id="conversation-thread-title-error"
              className="mt-1 text-caption text-danger"
            >
              {titleError}
            </div>
          ) : null}
        </div>

        {/* Right Cluster: Vault pill + Vertical 3-dots menu (⋮). The ONE side-panel toggle lives in the workspace top bar. */}
        <div className="flex shrink-0 items-center gap-1">
          {hasLockedVaultMessages ? (
            <span
              data-debug-id="conversation-thread-vault-pill"
              title="Vault is locked — unlock Vault to decrypt armored messages"
              className="inline-flex items-center gap-1 rounded-full border border-warning/30 bg-warning-soft px-2 py-0.5 text-[11px] font-medium text-warning"
            >
              <Icon name="lock" size={12} />
              <span className="hidden sm:inline">Vault locked</span>
            </span>
          ) : null}

          {headerTrailing}
          {settingsPanelEnabled ? (
            <UiIconButton
              ref={settingsPanel.gearRef}
              icon="gear"
              label="Agent settings"
              variant={settingsPanel.open ? 'solid' : 'ghost'}
              size={isMobile ? 'md' : 'sm'}
              aria-expanded={settingsPanel.open}
              data-debug-id="conversation-agent-settings-btn"
              onClick={settingsPanel.toggle}
            />
          ) : null}
          <Menu
            align="end"
            label="Conversation options"
            open={headerActionsOpen}
            onOpenChange={setHeaderActionsOpen}
            className="w-64 max-w-[calc(100vw-2rem)] z-30"
            trigger={
              <button
                type="button"
                data-debug-id="conversation-thread-overflow-menu-btn"
                aria-label="Conversation options"
                title="More options"
                className={`grid ${chromeIconButtonSizeClass(isMobile)} shrink-0 place-items-center text-muted hover:bg-neutral-soft hover:text-primary`}
              >
                <Icon name="more-vertical" size={isMobile ? 22 : 18} />
              </button>
            }
          >
            <Menu.Item
              data-debug-id="conversation-thread-rename-action"
              onClick={beginRenameFromHeader}
            >
              <Icon name="pencil" size={15} />
              <span>{renameTarget.kind === 'chain' ? 'Rename chain' : 'Rename'}</span>
            </Menu.Item>
            <Menu.Item
              data-debug-id="conversation-thread-refresh-btn"
              onClick={refreshFromHeader}
            >
              <Icon name="refresh" size={15} />
              <span>Refresh messages</span>
            </Menu.Item>
            <Menu.Item
              data-debug-id="conversation-thread-settings-action"
              onClick={() => {
                setHeaderActionsOpen(false);
                openAgentSettings();
              }}
            >
              <Icon name="gear" size={15} />
              <span>Agent settings</span>
            </Menu.Item>
            <Menu.Separator />
            {onSplitPane || onReplaceWithNew || (isMultiPane && onClosePane) ? (
              <>
                <Menu.Label>{isMobile ? 'Panes' : 'Split'}</Menu.Label>
                {onSplitPane ? (
                  isMobile ? (
                    <Menu.Item
                      data-debug-id="conversation-new-pane-action"
                      onClick={() => {
                        setHeaderActionsOpen(false);
                        onSplitPane('right');
                      }}
                    >
                      <Icon name="plus" size={15} />
                      <span>New Pane</span>
                    </Menu.Item>
                  ) : (
                    <>
                      {(
                        [
                          ['right', 'Split Right', 'panel-right'],
                          ['bottom', 'Split Down', 'chevron-down'],
                          ['left', 'Split Left', 'panel-left'],
                          ['top', 'Split Up', 'chevron-up'],
                        ] as const
                      ).map(([direction, label, icon]) => (
                        <Menu.Item
                          key={direction}
                          data-debug-id={`conversation-split-${direction === 'bottom' ? 'down' : direction === 'top' ? 'up' : direction}-action`}
                          onClick={() => {
                            setHeaderActionsOpen(false);
                            onSplitPane(direction);
                          }}
                        >
                          <Icon name={icon} size={15} />
                          <span>{label}</span>
                        </Menu.Item>
                      ))}
                    </>
                  )
                ) : null}
                {onReplaceWithNew ? (
                  <Menu.Item
                    data-debug-id="conversation-replace-with-new-action"
                    onClick={() => {
                      setHeaderActionsOpen(false);
                      onReplaceWithNew();
                    }}
                  >
                    <Icon name="plus" size={15} />
                    <span>Replace with New</span>
                  </Menu.Item>
                ) : null}
                {isMultiPane && onClosePane ? (
                  <Menu.Item
                    data-debug-id="conversation-remove-from-split-action"
                    onClick={() => {
                      setHeaderActionsOpen(false);
                      onClosePane();
                    }}
                  >
                    <Icon name="close" size={15} />
                    <span>{isMobile ? 'Close Pane' : 'Remove from Split'}</span>
                  </Menu.Item>
                ) : null}
              </>
            ) : null}
            <Menu.Separator />
            <div
              data-debug-id="conversation-thread-overflow-details"
              role="presentation"
              className="px-3 py-1.5 text-caption leading-5 text-faint overflow-hidden"
            >
              <div data-debug-id="conversation-thread-agent" className="truncate">
                Agent: {agentDisplayName || agentId || '—'}
              </div>
              <div data-debug-id="conversation-thread-instance" className="truncate">
                Instance: {agentInstanceId || '—'}
              </div>
              <div data-debug-id="conversation-thread-bridge" className="truncate">
                Bridge: {bridgeLabel || '—'}
              </div>
              <div className="flex gap-2">
                <span data-debug-id="conversation-thread-provider">
                  Provider: {instanceProvider || '—'}
                </span>
                <span data-debug-id="conversation-thread-model">
                  Model: {instanceModel || '—'}
                </span>
              </div>
              <div data-debug-id="conversation-thread-status">
                Status: {runtimeStatus || '—'}
              </div>
              {chainId ? (
                <div data-debug-id="conversation-thread-chain" className="truncate">
                  Chain: <VaultText value={chainTitle || chainId} as="span" />
                </div>
              ) : null}
            </div>
          </Menu>
          {/* Jetski: in split view the focused pane shows a close ✕. */}
          {isMultiPane && isFocusedPane && onClosePane ? (
            <button
              type="button"
              data-debug-id="conversation-close-pane-btn"
              aria-label="Close pane"
              title="Close pane"
              onClick={onClosePane}
              className={`grid ${chromeIconButtonSizeClass(isMobile)} shrink-0 place-items-center text-muted hover:bg-neutral-soft hover:text-primary`}
            >
              <Icon name="close" size={16} />
            </button>
          ) : null}
          {headerEnd}
        </div>
      </header>
      ) : null}

      {/* Transcript + Composer Dock */}
      <div
        data-debug-id="conversation-thread-transcript"
        className={`relative flex w-full min-h-0 min-w-0 max-w-full flex-1 flex-col overflow-x-hidden p-0 sm:px-4 sm:py-3`}
      >
        <ChatMessageList
          conversationKey={conversationId}
          messages={transcriptMessages}
          debugPrefix="conversation-thread"
          focusMessageId={focusMessageId}
          hasMore={olderHasMore && Boolean(olderCursor)}
          paginationCursor={olderCursor}
          loadingOlder={olderMessagesState.isFetching}
          onLoadOlder={loadOlderMessages}
          onReply={handleSendReply}
          onAnswerQuestions={(sourceMessageId, submission) => answerQuestions({ conversationId, sourceMessageId, submission }).unwrap()}
          formatTimestamp={formatMessageTimestamp}
          getDeliveryStatus={deliveryStatusFor}
          agentActivity={<>
            <AgentOutputBlocks conversationId={conversationId} />
            <AgentActivityBubbles key={agentInstanceId} instanceId={agentInstanceId} isWorking={isWorking} isResponding={hasLiveAgentOutput(agentOutputTurns)} />
          </>}
          bottomInset={composerDockHeight}
          pinOnSend={pinOnSend}
          pinOriginRef={pinOriginRef}
          renderMessageBody={({ message, reveal }) => renderConversationMessageBody(message, reveal)}
          wrapperClassName="relative min-h-0 min-w-0 max-w-full flex-1 overflow-hidden overflow-x-hidden"
          scrollClassName="chat-scrollbar h-full min-h-0 max-w-full space-y-3 overflow-y-auto overflow-x-hidden rounded-none bg-canvas px-1 py-3 sm:space-y-4 sm:rounded-[18px] sm:px-4 sm:py-4"
          emptyState={
            messagesQuery.isFetching ? (
              <div
                data-debug-id="conversation-thread-empty-state"
                className="grid h-full min-h-[220px] place-items-center p-6 text-sm text-muted"
              >
                Loading messages…
              </div>
            ) : (
              <div
                data-debug-id="conversation-thread-empty-state"
                className="flex h-full min-h-[220px] flex-col items-center justify-center gap-4 p-6 text-center"
              >
                <div
                  data-debug-id="conversation-thread-empty-avatar"
                  className="grid h-16 w-16 place-items-center rounded-full bg-neutral-soft text-2xl font-semibold text-primary"
                >
                  {(agentDisplayName || 'A').trim().charAt(0).toUpperCase()}
                </div>
                <h3
                  data-debug-id="conversation-thread-empty-title"
                  className="text-2xl font-semibold text-primary"
                >
                  {agentDisplayName || 'New conversation'}
                </h3>
                {agentPersona ? (
                  <p
                    data-debug-id="conversation-thread-empty-persona"
                    className="max-w-xl whitespace-pre-line text-[15px] leading-relaxed text-muted"
                  >
                    {agentPersona}
                  </p>
                ) : (
                  <p
                    data-debug-id="conversation-thread-empty-persona"
                    className="max-w-md text-[15px] text-muted"
                  >
                    Say something below to get started.
                  </p>
                )}
              </div>
            )
          }
        >
          <LiveToolActivity
            conversationId={conversationId}
            enabled={isActiveTab && paneVisible}
            instanceId={agentInstanceId}
            members={isChainCoordinator ? [
              { instanceId: agentInstanceId, displayName: agentDisplayName },
              ...(liveChain?.members || []).map((member: any) => ({
                instanceId: String(member.agentInstanceId || member.agent_instance_id || ''),
                displayName: String(member.displayName || member.display_name || ''),
              })),
            ] : [{ instanceId: agentInstanceId, displayName: agentDisplayName }]}
            onOpenShell={(sessionId) => navigateTo(shellViewHref(sessionId))}
          />
        </ChatMessageList>
        <FloatingComposerDock ref={composerDockRef} data-debug-id="conversation-thread-composer-dock">
          {aboveComposerMessages.length ? (
            // Same gutter and width as the composer form, so the bubble text lines up
            // with the composer text (the send animation's origin).
            <div className="mx-auto w-full max-w-[calc(56rem+1.5rem)] px-3 pt-2">
              <div className="mx-auto w-full max-w-4xl">
                <QueuedMessages
                  view={queuedView}
                  tooltip={sendNowTooltip(sendNowQuery.data?.steeringSupported ?? null)}
                  localError={sendNowLocalError}
                  onSendNow={handleSendNow}
                  onRetry={handleSendNowRetry}
                  renderBody={(message) => renderConversationMessageBody(message)}
                  bubbleRef={queuedBubbleRef}
                />
              </div>
            </div>
          ) : agentUnreadCount ? (
            <div className="mx-auto w-full max-w-[calc(56rem+1.5rem)] px-3 pt-2">
              <div className="mx-auto w-full max-w-4xl">
                <UnreadSendNow
                  unread={agentUnreadCount}
                  state={agentUnreadState}
                  phase={noticePhase}
                  error={(localBatch ?? serverBatch)?.error ?? ''}
                  tooltip={sendNowTooltip(null, 'notice')}
                  localError={sendNowLocalError}
                  onSendNow={handleNoticeSendNow}
                  onRetry={handleSendNowRetry}
                />
              </div>
            </div>
          ) : null}
          {trayNotice ? (
            <div className="pointer-events-none mb-2 flex justify-center px-3">
              <div
                role="status"
                data-debug-id="conversation-tray-notice"
                className="ui-liquid-glass max-w-full truncate rounded-full px-4 py-1.5 text-[13px] text-primary"
              >
                {trayNotice}
              </div>
            </div>
          ) : null}
          {showTray ? (
            <div
              data-debug-id="conversation-action-tray"
              className={isMobile ? 'w-full px-3 pt-2 ui-float-dock-pad' : 'mx-auto w-full max-w-[calc(56rem+1.5rem)] px-3 pt-2 pb-4'}
            >
              <ActionTray
                items={trayItemList}
                mobile={isMobile}
                onShowComposer={() => {
                  dispatchTray({ type: 'show_composer' });
                  requestAnimationFrame(() => textareaRef.current?.focus());
                }}
                onStartMode={(kind, item) => {
                  setError('');
                  const key = kind + ':' + item.card_id;
                  setTrayDraft(quotedTrayDrafts.current.get(key) || '');
                  quotedTrayDrafts.current.delete(key);
                  dispatchTray({ type: 'start_mode', kind, cardId: item.card_id });
                  requestAnimationFrame(() => textareaRef.current?.focus());
                }}
              />
            </div>
          ) : (
            renderComposer()
          )}
        </FloatingComposerDock>
      </div>
      </div>

      <AgentSettingsPanel
        state={settingsPanel}
        closeRightInset={
          settingsPanel.mode === 'drawer' || settingsPanelChrome?.overPane
            ? settingsPanelChrome?.rightInset
            : undefined
        }
        agentLabel={<VaultText value={agentInstanceLabel} fallback="Agent" />}
        projectLabel={projectId ? <VaultText value={projectName} fallback="Project" /> : undefined}
        runtime={runtimeSection}
        footer={applyFooter}
      >
        {settingsSections}
      </AgentSettingsPanel>

      <Modal
        open={runtimeMenuOpen}
        onOpenChange={setRuntimeMenuOpen}
        title="Agent settings"
        size="lg"
        data-debug-id="conversation-runtime-modal"
      >
        <Modal.Body>{runtimeControls}</Modal.Body>
        <Modal.Footer>
          <button
            type="button"
            data-debug-id="conversation-runtime-modal-reset-btn"
            disabled={!pendingReconfig || runtimeActionBusy || operationBlocksInput}
            onClick={resetRuntimeConfiguration}
            className="min-h-11 rounded-xl border border-subtle px-4 py-2 text-sm text-primary disabled:opacity-40"
          >
            Reset
          </button>
          <button
            type="button"
            data-debug-id="conversation-runtime-modal-apply-btn"
            disabled={
              !pendingReconfig ||
              runtimeActionBusy ||
              (operation?.phase !== 'recovery_required' &&
                (isStarting || runtimeStopping)) ||
              stagedConfigurationIssues.length > 0
            }
            onClick={() => void applyReconfigure()}
            className="min-h-11 rounded-xl bg-accent px-4 py-2 text-sm font-semibold text-accent-fg disabled:opacity-40"
          >
            Apply
          </button>
        </Modal.Footer>
      </Modal>

      <Modal
        open={chainAgentSwitcherOpen}
        onOpenChange={setChainAgentSwitcherOpen}
        title="Agents in this task chain"
        size="md"
        data-debug-id="conversation-chain-agent-modal"
      >
        <Modal.Body>
          <div className="space-y-2">
            {(chainAgentGroups[0]?.conversations || []).map((member) => (
              <button
                key={member.agentInstanceId}
                type="button"
                data-debug-id={`conversation-chain-agent-option-${member.agentInstanceId}`}
                aria-pressed={member.agentInstanceId === agentInstanceId}
                onClick={() => {
                  setChainAgentSwitcherOpen(false);
                  if (member.agentInstanceId === agentInstanceId) return;
                  // The coordinator is addressed by chain so the pane follows a
                  // coordinator replacement (REQ-TV2-7).
                  const memberTarget =
                    member.isCoordinator && chainId ? chainTargetId(chainId) : member.agentInstanceId;
                  if (onSwitchAgent) {
                    // The workspace swaps the target in THIS pane (deduped: a target
                    // already open elsewhere is focused instead) and syncs the URL.
                    onSwitchAgent(memberTarget, member.title);
                  } else if (typeof window !== 'undefined') {
                    window.location.hash = buildConversationHash([memberTarget]);
                  }
                }}
                className={`flex min-h-14 w-full items-center gap-3 rounded-xl border px-3 py-3 text-left ${
                  member.agentInstanceId === agentInstanceId
                    ? 'border-accent bg-accent/10'
                    : 'border-subtle hover:bg-neutral-soft'
                }`}
              >
                <StatusDot
                  size="sm"
                  tone={runtimeStatusToTone(member.runtimeStatus)}
                  label={runtimeStateLabel(runtimeStateFromStatus(member.runtimeStatus))}
                />
                <span className="min-w-0 flex-1">
                  <span className="block truncate text-sm font-medium text-primary">
                    <VaultText value={member.title} fallback="Agent" />
                  </span>
                  {member.isCoordinator ? (
                    <span className="text-xs text-muted">Coordinator</span>
                  ) : null}
                </span>
                {member.agentInstanceId === agentInstanceId ? (
                  <Icon name="check" size={18} className="text-accent" />
                ) : null}
              </button>
            ))}
            {!chainAgentGroups[0]?.conversations.length ? (
              <p className="text-sm text-muted">
                No agents are available in this task chain.
              </p>
            ) : null}
          </div>
        </Modal.Body>
      </Modal>

      <TaskChainSelectorModal
        open={chainSelectorOpen}
        onClose={() => setChainSelectorOpen(false)}
        currentChainId={chainId}
        // Per-pane (REQ-TV2-7): picking a chain swaps THIS pane's target to
        // `chain:<id>` in place (deduped by the workspace); other panes never
        // change. A chain without a coordinator keeps the default navigation to
        // /chains/<id>.
        onSelectChain={
          onSwitchAgent || onOpenAgentInSplit
            ? (chain) => {
                if (chain.coordinatorAgentInstanceId) {
                  const target = chainTargetId(chain.chainId);
                  if (chainSelectorPlacement === 'replace') {
                    if (target !== ownTargetId) onSwitchAgent?.(target);
                  } else {
                    onOpenAgentInSplit?.(target, chainSelectorPlacement);
                  }
                } else if (typeof window !== 'undefined') {
                  window.location.hash = buildRouteHash(
                    `/chains/${encodeURIComponent(chain.chainId)}`,
                    '',
                  );
                }
              }
            : undefined
        }
      />

      <CommandPalette
        open={paletteOpen}
        onClose={() => setPaletteOpen(false)}
        onNavigate={(route) => {
          window.location.hash = buildRouteHash(route, '');
          setPaletteOpen(false);
        }}
        actions={[]}
        actionsEnabled={actionsAccess === 'enabled'}
        conversationGroups={chainAgentGroups}
      />
    </div>
  );
}

export default AgentChatPane;
