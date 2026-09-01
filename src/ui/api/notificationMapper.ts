// Pure mapping layer for native browser notifications (v1).
//
// This module decides — with NO DOM/permission/side effects — whether a user
// WebSocket event should raise a native OS Notification while the Heimdall tab
// is OPEN but not focused, and what its content should be. Keeping this pure
// makes the curated notify-vs-skip policy unit-testable by feeding raw event
// payloads (see tests/ui_notification_mapper_test.ts).
//
// The side-effectful parts (permission state, visibility/focus gate, creating
// the Notification, click -> focus + route, Electron guard) live in the thin
// notificationService and are wired from the single handleUserWsEvent funnel.

export type NotificationCategory = 'chat' | 'attention';

export type NotificationPlan = {
  // Human-readable OS notification title/body.
  title: string;
  body: string;
  // Coalescing key: repeated events for the same conversation/chain replace
  // rather than stack (REQ-N6). The browser dedupes by (tag, origin).
  tag: string;
  // In-app hash route to navigate to on click (REQ-N4), e.g.
  // '/conversations/<conversationId>' or '/chains/<chainId>'.
  route: string;
  // Curated bucket, used by per-category settings + tests.
  category: NotificationCategory;
};

export type NotificationMapperCtx = {
  // The conversation currently visible/open in the UI. Even when unfocused we
  // still notify, but callers may choose to suppress for the visible thread;
  // v1 keeps it simple and always notifies when unfocused.
  visibleConversationId?: string;
};

function str(value: unknown): string {
  return value === undefined || value === null ? '' : String(value);
}

function truncate(text: string, max = 140): string {
  const trimmed = text.replace(/\s+/g, ' ').trim();
  if (trimmed.length <= max) return trimmed;
  return `${trimmed.slice(0, max - 1)}…`;
}

// The user WS chat_event carries a `direction`. Status-only receipts
// (read/delivered/delivery_failed) are never notifiable — they are not new
// content. Only a genuine inbound message directed at the user notifies.
const CHAT_STATUS_ONLY_DIRECTIONS = new Set(['read', 'delivered', 'delivery_failed']);

function planForChatEvent(payload: any, ctx: NotificationMapperCtx): NotificationPlan | null {
  const direction = str(payload?.direction);
  const message = payload?.message;

  // No inline message => this is an invalidation/receipt hint, not new content.
  if (!message) return null;
  // Explicit status-only receipts never notify (REQ-N2 exclusions).
  if (CHAT_STATUS_ONLY_DIRECTIONS.has(direction)) return null;

  // Only messages FROM an agent TO the user are user-actionable. Messages the
  // user themselves sent (user_to_agent) and agent<->agent chatter are skipped.
  const messageDirection = str(message?.direction || direction);
  if (messageDirection && messageDirection !== 'agent_to_user') return null;

  const body = str(message?.body).trim();
  if (!body) return null;

  const agentInstanceId = str(payload?.agent_instance_id || message?.agent_instance_id);
  const conversationId = str(payload?.conversation_id || payload?.conversationId || message?.conversation_id);
  const chainId = str(payload?.chain_id || message?.chain_id);

  // Distinguish a nudge/mention from a plain chat message using message_type or
  // metadata flags emitted by the hub; both still route to the conversation.
  const messageType = str(message?.message_type || message?.messageType);
  const metadata = (message?.metadata && typeof message.metadata === 'object') ? message.metadata : {};
  const isNudge = messageType === 'nudge' || Boolean(metadata?.nudge) || Boolean(metadata?.is_nudge);
  const isMention = messageType === 'mention' || Boolean(metadata?.mention);

  // Route: prefer the conversation deep-link (the shell resolves
  // /conversations/<conversationId>). Fall back to the agent instance id, which
  // the conversation route also accepts, then the chain view.
  const routeId = conversationId || agentInstanceId;
  const route = routeId ? `/conversations/${routeId}` : (chainId ? `/chains/${chainId}` : '/conversations');

  // Coalesce per conversation (or chain) so a burst collapses to one bubble.
  const tag = `heimdall:chat:${conversationId || agentInstanceId || chainId || 'unknown'}`;

  let title = 'New message';
  if (isNudge) title = 'Nudge';
  else if (isMention) title = 'You were mentioned';

  return {
    title,
    body: truncate(body),
    tag,
    route,
    category: 'chat',
  };
}

function planForChatApproval(payload: any): NotificationPlan | null {
  // A chat_approval event means an agent is blocking on the user for an answer
  // (approval / question / multi-question). This is a needs-attention event.
  const event = str(payload?.event);
  // Only the creation of a pending approval is actionable; dismissals/answers
  // (which also flow as chat_approval) must NOT notify.
  if (event && event !== 'chat_approval_created') return null;

  const approval = payload?.approval || payload;
  const chainId = str(approval?.chain_id || approval?.chainId || payload?.chain_id);
  const agentInstanceId = str(approval?.agent_instance_id || approval?.agentInstanceId);
  const conversationId = str(payload?.conversation_id || payload?.conversationId);
  const kind = str(approval?.kind);
  const promptBody = str(approval?.body || approval?.title || approval?.prompt).trim();

  const routeId = conversationId || agentInstanceId;
  const route = routeId ? `/conversations/${routeId}` : (chainId ? `/chains/${chainId}` : '/conversations');
  const tag = `heimdall:attention:approval:${chainId || agentInstanceId || conversationId || 'unknown'}`;

  const title = kind === 'multi_question' ? 'Agent needs answers' : 'Agent needs your input';
  const body = promptBody || 'An agent is waiting for your response.';

  return {
    title,
    body: truncate(body),
    tag,
    route,
    category: 'attention',
  };
}

function planForMergeDecision(payload: any): NotificationPlan | null {
  const chainId = str(payload?.chain_id || payload?.chainId);
  if (!chainId) return null;
  return {
    title: 'Merge decision pending',
    body: truncate(str(payload?.summary || payload?.preview?.summary) || 'A workspace merge is waiting for your decision.'),
    tag: `heimdall:attention:merge:${chainId}`,
    route: `/chains/${chainId}`,
    category: 'attention',
  };
}

// Curated + excluded policy lives here (REQ-N1/REQ-N2). Returns null for every
// event that must never raise an OS notification: status receipts, generic
// resource_changed invalidations, agent activity/lifecycle flips, memory
// invalidations, audit start/end, and task_event churn.
export function notificationForWsEvent(payload: any, ctx: NotificationMapperCtx = {}): NotificationPlan | null {
  const type = str(payload?.type);
  switch (type) {
    case 'chat_event':
      return planForChatEvent(payload, ctx);
    case 'chat_approval':
      return planForChatApproval(payload);
    case 'merge_decision_pending':
      return planForMergeDecision(payload);
    // Everything below is intentionally excluded from OS notifications.
    case 'task_event':
    case 'resource_changed':
    case 'agent_update':
    case 'agent_lifecycle_changed':
    case 'agent_runtime_changed':
    case 'memory_event':
    case 'audit_start':
    case 'audit_end':
    default:
      return null;
  }
}
