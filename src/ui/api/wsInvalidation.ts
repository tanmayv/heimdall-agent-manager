import { heimdallApi, HEIMDALL_TAG_TYPES } from './heimdallApi';
import { tasksApi } from './endpoints/tasks';
import { normalizeChain, workspaceApi } from './endpoints/workspace';
import { chatEndpoints } from './endpoints/chats';
import { patchAgentCachesFromWs } from './endpoints/agents';
import { patchChatApprovalCachesFromWs, patchMergeDecisionCachesFromWs } from './endpoints/attention';
import { patchMemoryCachesFromWs } from './endpoints/memory';
import { upsertTaskInList, upsertTaskLogEvent } from './taskCache';
import { attentionEventReceived } from '../store/attentionSlice';
import { GUIDE_AGENT_ID, appendMessage, chatEventReceived, patchChatMessageStatus } from '../store/chatSlice';
import { wsChainViewRefreshRequested } from '../store/chainViewSlice';
import { wsRefreshRequested } from '../store/homeSlice';
import { auditEndedReceived, auditStartedReceived, memoryEventReceived } from '../store/memorySlice';
import { taskEventReceived } from '../store/taskSlice';
import { agentActionReceived } from '../store/agentActivitySlice';
import { fireNotificationForWsEvent } from '../services/notificationService';

// Focus context read at WS-event time (populated by the shell from the live
// route). Only focusedChainId is consumed — it lets a resource/chat/agent event
// for the chain the user is currently viewing trigger an extra chain-view
// refresh. Other former fields (selectedAgentId, visibleChatAgentId,
// focusedCoordinatorAgentInstanceId, guidePanelOpen) were never populated and had
// no live consumer, so they were removed; foreground notification suppression now
// derives the open conversation from the route hash inside notificationService.
type WsCtx = {
  focusedChainId?: string;
};

// TODO(FIX): Replace any with strict TypeScript interface matching Odin backend schema
function normalizeTask(task: any) {
  // TODO(FIX): Replace any with strict TypeScript interface matching Odin backend schema
  const result: any = {
    id: task.task_id,
    taskId: task.task_id,
    chainId: task.chain_id || '',
    title: task.title || '',
    priority: task.priority || 'normal',
    status: task.status || 'pending',
    assigneeAgentInstanceId: task.assignee_agent_instance_id || '',
    reviewerAgentInstanceId: task.reviewer_agent_instance_id || '',
    coordinatorAgentInstanceId: task.coordinator_agent_instance_id || '',
    dependsOn: task.depends_on || '',
    createdBy: task.created_by || '',
    createdAtUnixMs: Number(task.created_at_unix_ms || 0),
    updatedAtUnixMs: Number(task.updated_at_unix_ms || 0),
    notActionableReason: task.not_actionable_reason || '',
    // TODO(FIX): Replace any with strict TypeScript interface matching Odin backend schema
    votes: (task.votes || []).map((vote: any) => ({
      reviewerAgentInstanceId: vote.reviewer_agent_instance_id,
      approved: Boolean(vote.approved),
      comment: vote.comment || '',
    })),
    // TODO(FIX): Replace any with strict TypeScript interface matching Odin backend schema
    participants: (task.participants || []).map((participant: any) => ({
      agentInstanceId: participant.agent_instance_id,
      role: participant.role,
    })),
    unresolvedCommentCount: Number(task.unresolved_comment_count || 0),
    commentIds: task.comment_ids || [],
  };
  if (task.description !== undefined) {
    result.description = task.description;
  }
  if (task.acceptance_criteria !== undefined) {
    result.acceptanceCriteria = task.acceptance_criteria;
  }
  return result;
}

// TODO(FIX): Replace any with strict TypeScript interface matching Odin backend schema
function normalizeTaskLogEvent(event: any) {
  return {
    eventId: event.event_id || '',
    // TODO(FIX): Replace loose fallback chain with canonical typed schema property
    kind: event.kind || event.event || '',
    taskId: event.task_id || '',
    chainId: event.chain_id || '',
    status: event.status || '',
    body: event.body || '',
    // TODO(FIX): Replace loose fallback chain with canonical typed schema property
    authorAgentInstanceId: event.author_agent_instance_id || event.changed_by || '',
    createdUnixMs: Number(event.created_unix_ms || 0),
    commentId: event.comment_id || '',
  };
}

type ChatMessage = {
  id: string;
  author: 'user' | 'agent';
  body: string;
  timestamp: string;
  createdUnixMs: number;
  deliveredAt: string;
  deliveredUnixMs: number;
  readAt: string;
  readUnixMs: number;
  deliveryFailedAt: string;
  deliveryFailedUnixMs: number;
  deliveryError: string;
  interrupt: boolean;
  sending?: boolean;
  optimistic?: boolean;
  error?: boolean;
};

function timeLabel(unixMs: number) {
  return unixMs > 0 ? new Date(unixMs).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' }) : '';
}

// TODO(FIX): Replace any with strict TypeScript interface matching Odin backend schema
function normalizeChatMessage(message: any): ChatMessage {
  // TODO(FIX): Replace loose fallback chain with canonical typed schema property
  const createdUnixMs = Number(message.created_unix_ms ?? message.createdUnixMs ?? 0);
  // TODO(FIX): Replace loose fallback chain with canonical typed schema property
  const deliveredUnixMs = Number(message.delivered_unix_ms ?? message.deliveredUnixMs ?? 0);
  // TODO(FIX): Replace loose fallback chain with canonical typed schema property
  const readUnixMs = Number(message.read_unix_ms ?? message.readUnixMs ?? 0);
  // TODO(FIX): Replace loose fallback chain with canonical typed schema property
  const deliveryFailedUnixMs = Number(message.delivery_failed_unix_ms ?? message.deliveryFailedUnixMs ?? 0);
  return {
    // TODO(FIX): Replace loose fallback chain with canonical typed schema property
    id: String(message.message_id ?? message.id ?? ''),
    author: message.direction === 'user_to_agent' || message.author === 'user' ? 'user' : 'agent',
    body: String(message.body || ''),
    timestamp: timeLabel(createdUnixMs) || String(message.timestamp || ''),
    createdUnixMs,
    deliveredAt: timeLabel(deliveredUnixMs) || String(message.deliveredAt || ''),
    deliveredUnixMs,
    readAt: timeLabel(readUnixMs) || String(message.readAt || ''),
    readUnixMs,
    deliveryFailedAt: timeLabel(deliveryFailedUnixMs) || String(message.deliveryFailedAt || ''),
    deliveryFailedUnixMs,
    // TODO(FIX): Replace loose fallback chain with canonical typed schema property
    deliveryError: String(message.delivery_error ?? message.deliveryError ?? ''),
    interrupt: Boolean(message.interrupt),
    sending: Boolean(message.sending),
    optimistic: Boolean(message.optimistic),
    error: Boolean(message.error),
  };
}

function upsertChatMessage(messages: ChatMessage[], next: ChatMessage) {
  const index = messages.findIndex((message) => message.id === next.id);
  if (index >= 0) {
    messages[index] = { ...messages[index], ...next };
    return;
  }
  messages.push(next);
  messages.sort((left, right) => Number(left.createdUnixMs || 0) - Number(right.createdUnixMs || 0));
}

// TODO(FIX): Replace any with strict TypeScript interface matching Odin backend schema
function patchConversationSummary(draft: any, agentInstanceId: string, payload: any) {
  if (!draft || !agentInstanceId) return;
  const summaries = draft.summaries || draft;
  const message = payload?.message || {};
  // TODO(FIX): Replace loose fallback chain with canonical typed schema property
  const createdUnixMs = Number(message.created_unix_ms ?? message.createdUnixMs ?? Date.now());
  const existing = summaries[agentInstanceId] || { agentInstanceId, agentId: '', projectId: '', title: '' };
  summaries[agentInstanceId] = {
    ...existing,
    lastMessageUnixMs: Math.max(Number(existing.lastMessageUnixMs || 0), createdUnixMs),
    // TODO(FIX): Replace loose fallback chain with canonical typed schema property
    unreadCount: Number(payload?.unread_count ?? existing.unreadCount ?? 0),
  };
  if (!existing.title && String(message.body || '').trim()) {
    summaries[agentInstanceId].title = String(message.body || '').trim().slice(0, 80);
  }
}

function directChatArgs(agentInstanceId: string) {
  return { agentInstanceId, limit: 50 };
}

function guideChatArgs() {
  return { limit: 80 };
}

// TODO(FIX): Replace any with strict TypeScript interface matching Odin backend schema
function applyChatMessageToCaches(dispatch: any, message: ChatMessage, rawMessage: any, agentId: string, _chainId: string, _ctx: WsCtx) {
  if (agentId === GUIDE_AGENT_ID) {
    // TODO(FIX): Replace any with strict TypeScript interface matching Odin backend schema
    dispatch(chatEndpoints.util.updateQueryData('fetchGuideChat', guideChatArgs(), (draft: any) => {
      if (!draft) return;
      upsertChatMessage(draft.messages || (draft.messages = []), message);
    }));
  } else if (agentId) {
    // TODO(FIX): Replace any with strict TypeScript interface matching Odin backend schema
    dispatch(chatEndpoints.util.updateQueryData('fetchDirectChat', directChatArgs(agentId), (draft: any) => {
      if (!draft) return;
      upsertChatMessage(draft.messages || (draft.messages = []), message);
    }));
  }
  if (agentId) {
    // TODO(FIX): Replace any with strict TypeScript interface matching Odin backend schema
    dispatch(chatEndpoints.util.updateQueryData('listConversationSummaries', undefined, (draft: any) => patchConversationSummary(draft, agentId, { message: rawMessage })));
    dispatch(appendMessage({ agentId, message: rawMessage }));
  }
}

// TODO(FIX): Replace any with strict TypeScript interface matching Odin backend schema
function handleTaskEvent(dispatch: any, payload: any) {
  dispatch(taskEventReceived(payload));
  if (payload.chain) {
    const chain = normalizeChain(payload.chain);
    if (chain.chainId) {
      dispatch(workspaceApi.util.upsertQueryData('fetchChain', { chainId: chain.chainId }, { chain }));
      // TODO(FIX): Replace any with strict TypeScript interface matching Odin backend schema
      dispatch(workspaceApi.util.updateQueryData('listChains', undefined, (draft: any) => {
        const rows = draft?.chains || (draft.chains = []);
        // TODO(FIX): Replace any with strict TypeScript interface matching Odin backend schema
        const index = rows.findIndex((item: any) => item.chainId === chain.chainId);
        if (index >= 0) rows[index] = { ...rows[index], ...chain };
        else rows.unshift(chain);
      }));
    }
  }

  // TODO(FIX): Replace loose fallback chain with canonical typed schema property
  const taskId = String(payload.task_id || payload.task?.task_id || '');
  // TODO(FIX): Replace loose fallback chain with canonical typed schema property
  const chainId = String(payload.chain_id || payload.chain?.chain_id || payload.task?.chain_id || '');
  dispatch(wsRefreshRequested(`task_event:${chainId || taskId || 'unknown'}`));

  // TODO(FIX): Replace any with strict TypeScript interface matching Odin backend schema
  const patchTaskCaches = (normalizedTask: any) => {
    if (!normalizedTask?.taskId) return;
    dispatch(tasksApi.util.upsertQueryData('fetchTask', { taskId: normalizedTask.taskId }, { task: normalizedTask }));
    if (chainId) {
      // TODO(FIX): Replace any with strict TypeScript interface matching Odin backend schema
      dispatch(tasksApi.util.updateQueryData('fetchChainTasks', { chainId }, (draft: any) => {
        if (!draft) return;
        upsertTaskInList(draft.tasks || (draft.tasks = []), normalizedTask);
      }));
    }
  };

  if (payload.task && taskId) {
    patchTaskCaches(normalizeTask(payload.task));
  } else if (payload.fetch_required && taskId) {
    // Oversized task/chain records arrive as a compact fetch_required event.
    // In practice this is the common case (full task+chain JSON exceeds the WS
    // inline limit for any real chain), so this path MUST fetch authoritative
    // state. forceRefetch is required: without it RTK Query dedupes against the
    // stale cache entry and the status/comments never change in the UI.
    // TODO(FIX): Replace any with strict TypeScript interface matching Odin backend schema
    dispatch(tasksApi.endpoints.fetchTask.initiate({ taskId }, { subscribe: false, forceRefetch: true })).unwrap().then((data: any) => {
      patchTaskCaches(data?.task);
    }).catch(() => undefined);
    // The compact fallback omits the chain payload and comment_id, so refetch the
    // authoritative task log (comments live here) for any open task-detail view.
    dispatch(heimdallApi.util.invalidateTags([{ type: 'TaskLog', id: taskId }]));
  }

  if (chainId) {
    dispatch(heimdallApi.util.invalidateTags([
      { type: 'Chain', id: chainId },
      { type: 'ChainList', id: 'ALL' },
      { type: 'ChainTasks', id: chainId },
    ]));
  }

  if (taskId) {
    const eventRecord = normalizeTaskLogEvent(payload);
    const patchLog = (args: { taskId: string; limit?: number }) => {
      // TODO(FIX): Replace any with strict TypeScript interface matching Odin backend schema
      dispatch(tasksApi.util.updateQueryData('fetchTaskLog', args, (draft: any) => {
        if (!draft) return;
        const events = draft.events || (draft.events = []);
        const inserted = upsertTaskLogEvent(events, eventRecord);
        if (inserted) draft.total = Number(draft.total || 0) + 1;
      }));
    };
    patchLog({ taskId });
    patchLog({ taskId, limit: 50 });
    dispatch(heimdallApi.util.invalidateTags([
      { type: 'Task', id: taskId },
      { type: 'TaskLog', id: taskId },
      { type: 'TaskComments', id: taskId },
    ]));
  }
}

// TODO(FIX): Replace any with strict TypeScript interface matching Odin backend schema
function handleChatEvent(dispatch: any, payload: any, ctx: WsCtx) {
  dispatch(chatEventReceived(payload));
  const agentId = String(payload.agent_instance_id || '');
  // TODO(FIX): Replace loose fallback chain with canonical typed schema property
  const conversationId = String(payload.conversation_id || payload.conversationId || '');
  const eventChainId = String(payload.chain_id || '');
  const focusedChainId = String(ctx.focusedChainId || '');
  const hasInlineMessage = Boolean(payload.message);
  const message = hasInlineMessage ? normalizeChatMessage(payload.message) : null;
  const direction = String(payload.direction || '');
  const isStatusOnlyEvent = !message && (direction === 'read' || direction === 'delivered' || direction === 'delivery_failed' || payload.event === 'messages_read');

  dispatch(wsRefreshRequested(`chat_event:${agentId || payload.message_id || 'unknown'}`));
  if (isStatusOnlyEvent) {
    if (agentId) {
      // TODO(FIX): Replace loose fallback chain with canonical typed schema property
      const readUnixMs = Number(payload.read_unix_ms || payload.readUnixMs || 0) || (payload.read_at ? Date.parse(payload.read_at) : 0) || 0;
      // TODO(FIX): Replace loose fallback chain with canonical typed schema property
      const deliveredUnixMs = Number(payload.delivered_unix_ms || payload.deliveredUnixMs || 0) || (payload.delivered_at ? Date.parse(payload.delivered_at) : 0) || 0;
      const messageIds: string[] = Array.isArray(payload.message_ids) ? payload.message_ids.map(String) : (payload.message_id ? [String(payload.message_id)] : []);
      const statusPatch = {
        agentId,
        // TODO(FIX): Replace loose fallback chain with canonical typed schema property
        messageId: String(payload.message_id || (messageIds.length === 1 ? messageIds[0] : '')),
        deliveredUnixMs,
        readUnixMs,
        // TODO(FIX): Replace loose fallback chain with canonical typed schema property
        deliveryFailedUnixMs: Number(payload.delivery_failed_unix_ms || payload.deliveryFailedUnixMs || 0),
        // TODO(FIX): Replace loose fallback chain with canonical typed schema property
        deliveryError: String(payload.delivery_error || payload.deliveryError || ''),
      };
      dispatch(patchChatMessageStatus(statusPatch));
      // TODO(FIX): Replace any with strict TypeScript interface matching Odin backend schema
      const patchCache = (draft: any) => {
        if (!draft?.messages) return;
        const messageId = statusPatch.messageId;
        const idSet = new Set(messageIds);
        for (const message of draft.messages) {
          const mid = String(message.id || '');
          const matchesId = (messageId && mid === messageId) || (idSet.size > 0 && idSet.has(mid));
          const matchesReadWatermark = !messageId && idSet.size === 0 && statusPatch.readUnixMs > 0 && message.author === 'user' && Number(message.createdUnixMs || 0) <= statusPatch.readUnixMs;
          if (!matchesId && !matchesReadWatermark) continue;
          if (statusPatch.deliveredUnixMs > 0) message.deliveredUnixMs = Math.max(Number(message.deliveredUnixMs || 0), statusPatch.deliveredUnixMs);
          if (statusPatch.readUnixMs > 0) message.readUnixMs = Math.max(Number(message.readUnixMs || 0), statusPatch.readUnixMs);
          if (statusPatch.deliveryFailedUnixMs > 0) message.deliveryFailedUnixMs = Math.max(Number(message.deliveryFailedUnixMs || 0), statusPatch.deliveryFailedUnixMs);
          if (statusPatch.deliveryError) message.deliveryError = statusPatch.deliveryError;
          message.sending = false;
          message.optimistic = false;
        }
      };
      if (agentId === GUIDE_AGENT_ID) dispatch(chatEndpoints.util.updateQueryData('fetchGuideChat', guideChatArgs(), patchCache));
      else dispatch(chatEndpoints.util.updateQueryData('fetchDirectChat', directChatArgs(agentId), patchCache));
      // TODO(FIX): Replace any with strict TypeScript interface matching Odin backend schema
      dispatch(chatEndpoints.util.updateQueryData('listConversationSummaries', undefined, (draft: any) => {
        const summaries = draft?.summaries || draft;
        if (summaries?.[agentId] && payload.unread_count !== undefined) {
          summaries[agentId].unreadCount = Number(payload.unread_count || 0);
        }
      }));
      if (statusPatch.messageId && !statusPatch.deliveredUnixMs && !statusPatch.readUnixMs && !statusPatch.deliveryFailedUnixMs) {
        dispatch(chatEndpoints.endpoints.fetchChatMessage.initiate({ messageId: statusPatch.messageId }, { subscribe: false, forceRefetch: true })).unwrap().catch(() => undefined);
      }
    }
    return;
  }
  if (!message && payload.fetch_required && String(payload.fetch_kind || '') === 'chat_message') {
    // TODO(FIX): Replace loose fallback chain with canonical typed schema property
    const messageId = String(payload.fetch_id || payload.message_id || '');
    if (conversationId) dispatch(heimdallApi.util.invalidateTags([{ type: 'Chat', id: conversationId }, { type: 'ConversationSummaries', id: conversationId }]));
    if (messageId) {
      dispatch(chatEndpoints.endpoints.fetchChatMessage.initiate({ messageId }, { subscribe: false })).unwrap().catch(() => undefined);
    }
    return;
  }
  if (eventChainId) {
    dispatch(wsChainViewRefreshRequested(`chat_event:${focusedChainId || eventChainId}:${payload.message_id || ''}`));
  }

  if (message && agentId) {
    applyChatMessageToCaches(dispatch, message, payload.message, agentId, eventChainId, ctx);
  }

  if (!message) {
    if (agentId === GUIDE_AGENT_ID) {
      dispatch(heimdallApi.util.invalidateTags([{ type: 'GuideChat', id: GUIDE_AGENT_ID }]));
    } else if (agentId) {
      dispatch(heimdallApi.util.invalidateTags([{ type: 'Chat', id: agentId }]));
    }
    if (conversationId) dispatch(heimdallApi.util.invalidateTags([{ type: 'Chat', id: conversationId }, { type: 'ConversationSummaries', id: conversationId }]));
    dispatch(heimdallApi.util.invalidateTags([{ type: 'ConversationSummaries', id: 'ALL' }]));
  }
  // UI-14: any chat event (new message, read watermark, unread count) can change
  // the sidebar tree's unread badges. Invalidate the cookie-auth sidebar tag so the
  // live shell's project/agent/session rollups refresh through this single path.
  dispatch(heimdallApi.util.invalidateTags([{ type: 'SidebarConversations', id: 'ALL' }]));
}

// TODO(FIX): Replace any with strict TypeScript interface matching Odin backend schema
function handleMemoryEvent(dispatch: any, payload: any) {
  dispatch(memoryEventReceived(payload));
  patchMemoryCachesFromWs(dispatch, payload);
}

// Ephemeral agent-activity bubble event (P1 wire contract:
// { type:'agent_action', instance_id, action, summary, ts }). Routed ONLY to the
// transient agentActivity slice — it MUST NOT touch any RTK Query cache (no
// invalidateTags/updateQueryData) and never triggers a refetch. Fire-and-forget
// presence signal; buffered per-instance so it can replay when the user opens
// that conversation (see AgentActivityBubbles, P3).
// TODO(FIX): Replace any with strict TypeScript interface matching Odin backend schema
function handleAgentActionEvent(dispatch: any, payload: any) {
  const instanceId = String(payload?.instance_id || '');
  const summary = String(payload?.summary || '');
  if (!instanceId || !summary) return;
  dispatch(agentActionReceived({
    instanceId,
    action: String(payload?.action || ''),
    summary,
    ts: Number(payload?.ts) || Date.now(),
  }));
}

// TODO(FIX): Replace any with strict TypeScript interface matching Odin backend schema
function handleMergeDecisionPending(dispatch: any, payload: any, ctx: WsCtx) {
  const chainId = String(payload.chain_id || '');
  if (chainId && ctx.focusedChainId === chainId) {
    dispatch(wsChainViewRefreshRequested(`merge_decision_pending:${chainId}`));
  }
  if (chainId) {
    dispatch(heimdallApi.util.invalidateTags([
      { type: 'Workspace', id: chainId },
      { type: 'WorkspaceDiff', id: `${chainId}:` },
    ]));
  }
  dispatch(attentionEventReceived());
  patchMergeDecisionCachesFromWs(dispatch, payload);
}

// TODO(FIX): Replace any with strict TypeScript interface matching Odin backend schema
function handleAgentEvent(dispatch: any, payload: any, ctx: WsCtx) {
  // TODO(FIX): Replace loose fallback chain with canonical typed schema property
  const agentId = String(payload.target_agent_instance_id || payload.agent_instance_id || payload.agent?.agent_instance_id || payload.record?.agent_instance_id || '');
  patchAgentCachesFromWs(dispatch, payload);
  dispatch(wsRefreshRequested(`${payload.type}:${agentId}`));
  if (ctx.focusedChainId) {
    dispatch(wsChainViewRefreshRequested(`${payload.type}:${agentId}`));
  }
}

// UI-BE-7: the hub's event bus (src/hub/service/events/event_bus.odin) emits a
// single generic envelope `{ type: 'resource_changed', resource, resource_id,
// change, summary }` for every durable resource mutation, rather than the
// legacy per-domain `task_event`/`agent_update` types. This is the ONLY event
// shape the rewrite hub sends, so task/chain views only update live if we handle
// it here. We invalidate the smallest RTK Query tags for the changed resource;
// RTK Query refetches only entries with an active subscriber, so this scopes the
// refetch to whatever the UI is currently showing.
// TODO(FIX): Replace any with strict TypeScript interface matching Odin backend schema
function handleResourceChanged(dispatch: any, payload: any, ctx: WsCtx) {
  const resource = String(payload.resource || '');
  const resourceId = String(payload.resource_id || '');
  const summary = payload.summary || {};
  // TODO(FIX): Replace loose fallback chain with canonical typed schema property
  const chainId = String(summary.chain_id || (resource === 'task_chain' ? resourceId : '') || '');
  // TODO(FIX): Replace loose fallback chain with canonical typed schema property
  const taskId = String(summary.task_id || (resource === 'task' ? resourceId : '') || '');
  dispatch(wsRefreshRequested(`resource_changed:${resource}:${resourceId}`));

  switch (resource) {
    case 'task': {
      // TODO(FIX): Replace any with strict TypeScript interface matching Odin backend schema
      const tags: any[] = [{ type: 'ChainList', id: 'ALL' }];
      if (taskId) {
        tags.push({ type: 'Task', id: taskId });
        tags.push({ type: 'TaskLog', id: taskId });
        tags.push({ type: 'TaskComments', id: taskId });
      }
      if (chainId) {
        tags.push({ type: 'ChainTasks', id: chainId });
        tags.push({ type: 'Chain', id: chainId });
      }
      dispatch(heimdallApi.util.invalidateTags(tags));
      if (chainId && ctx.focusedChainId === chainId) {
        dispatch(wsChainViewRefreshRequested(`resource_changed:task:${taskId || resourceId}`));
      }
      return;
    }
    case 'task_chain': {
      // TODO(FIX): Replace any with strict TypeScript interface matching Odin backend schema
      const tags: any[] = [{ type: 'ChainList', id: 'ALL' }];
      if (chainId) {
        tags.push({ type: 'Chain', id: chainId });
        tags.push({ type: 'ChainTasks', id: chainId });
      }
      dispatch(heimdallApi.util.invalidateTags(tags));
      if (chainId && ctx.focusedChainId === chainId) {
        dispatch(wsChainViewRefreshRequested(`resource_changed:task_chain:${chainId}`));
      }
      return;
    }
    case 'agent_instance':
    case 'agent_id':
    case 'agent': {
      // Reuse the agent patch/refresh path; patchAgentCachesFromWs tolerates the
      // resource_changed shape (reads agent_instance_id/record fields defensively).
      // Forward the summary (runtime/startup/activity) so the caches can be patched
      // IN PLACE without refetching the whole /agents list on every status change.
      handleAgentEvent(dispatch, { ...payload, type: 'agent_update', agent_instance_id: resourceId, summary }, ctx);
      return;
    }
    default:
      return;
  }
}

// The user WebSocket is fire-and-forget fanout with no per-client replay: any
// event emitted while we were disconnected is lost. After the socket re-opens we
// therefore invalidate every RTK Query tag so the cache re-fetches whatever the
// UI is currently showing. RTK Query only refetches entries that still have an
// active subscriber, so this is scoped to mounted queries (not a blanket reload)
// and dedupes concurrent invalidations. Call this ONLY on a genuine reconnect,
// not the first connect (initial mounts already fetch their data).
// TODO(FIX): Replace any with strict TypeScript interface matching Odin backend schema
export function resyncAfterReconnect(dispatch: any) {
  dispatch(heimdallApi.util.invalidateTags([...HEIMDALL_TAG_TYPES]));
}

// TODO(FIX): Replace any with strict TypeScript interface matching Odin backend schema
export function handleUserWsEvent(dispatch: any, payload: any, ctx: WsCtx = {}) {
  // Native (OS) notifications: fire from this single funnel for the curated
  // event set, gated to open-but-unfocused tabs. Implemented as a thunk so the
  // side-effectful service can read live settings via getState without a
  // circular store import. Never throws into the invalidation path.
  try {
    // TODO(FIX): Replace any with strict TypeScript interface matching Odin backend schema
    dispatch((_dispatch: any, getState: any) => {
      try {
        fireNotificationForWsEvent(getState, payload);
      } catch (_err) {
        /* notifications must never break cache invalidation */
      }
    });
  } catch (_err) {
    /* ignore */
  }

  switch (payload?.type) {
    case 'task_event':
      handleTaskEvent(dispatch, payload);
      return;
    case 'chat_event':
      handleChatEvent(dispatch, payload, ctx);
      return;
    case 'chat_approval':
      dispatch(attentionEventReceived());
      patchChatApprovalCachesFromWs(dispatch, payload);
      return;
    case 'memory_event':
      handleMemoryEvent(dispatch, payload);
      return;
    case 'agent_action':
      handleAgentActionEvent(dispatch, payload);
      return;
    case 'audit_start':
      dispatch(auditStartedReceived(payload));
      return;
    case 'audit_end':
      dispatch(auditEndedReceived(payload));
      return;
    case 'merge_decision_pending':
      handleMergeDecisionPending(dispatch, payload, ctx);
      return;
    case 'agent_update':
    case 'agent_lifecycle_changed':
    case 'agent_runtime_changed':
      handleAgentEvent(dispatch, payload, ctx);
      return;
    case 'resource_changed':
      handleResourceChanged(dispatch, payload, ctx);
      return;
    default:
      return;
  }
}
