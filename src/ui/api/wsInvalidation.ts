import { heimdallApi } from './heimdallApi';
import { tasksApi } from './endpoints/tasks';
import { chatEndpoints } from './endpoints/chats';
import { chatApprovalEventReceived, mergeDecisionEventReceived } from '../store/attentionSlice';
import { GUIDE_AGENT_ID, agentLifecycleEventReceived, agentRuntimeEventReceived, appendMessage, chatEventReceived, patchChatMessageStatus } from '../store/chatSlice';
import { wsChainViewRefreshRequested } from '../store/chainViewSlice';
import { wsRefreshRequested } from '../store/homeSlice';
import { applyMemoryEventRecord, auditEndedReceived, auditStartedReceived, memoryEventReceived } from '../store/memorySlice';
import { taskEventReceived, updateChainStateDirectly, updateTaskStateDirectly } from '../store/taskSlice';

type WsCtx = {
  selectedAgentId?: string;
  visibleChatAgentId?: string;
  focusedChainId?: string;
  focusedCoordinatorAgentInstanceId?: string;
  guidePanelOpen?: boolean;
};

function normalizeTask(task: any) {
  return {
    id: task.task_id,
    taskId: task.task_id,
    chainId: task.chain_id || '',
    title: task.title || '',
    description: task.description || '',
    acceptanceCriteria: task.acceptance_criteria || '',
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
    votes: (task.votes || []).map((vote: any) => ({
      reviewerAgentInstanceId: vote.reviewer_agent_instance_id,
      approved: Boolean(vote.approved),
      comment: vote.comment || '',
    })),
    participants: (task.participants || []).map((participant: any) => ({
      agentInstanceId: participant.agent_instance_id,
      role: participant.role,
    })),
    unresolvedCommentCount: Number(task.unresolved_comment_count || 0),
    unresolvedComments: [],
  };
}

function normalizeTaskLogEvent(event: any) {
  return {
    eventId: event.event_id || '',
    kind: event.kind || event.event || '',
    taskId: event.task_id || '',
    chainId: event.chain_id || '',
    status: event.status || '',
    body: event.body || '',
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

function normalizeChatMessage(message: any): ChatMessage {
  const createdUnixMs = Number(message.created_unix_ms ?? message.createdUnixMs ?? 0);
  const deliveredUnixMs = Number(message.delivered_unix_ms ?? message.deliveredUnixMs ?? 0);
  const readUnixMs = Number(message.read_unix_ms ?? message.readUnixMs ?? 0);
  const deliveryFailedUnixMs = Number(message.delivery_failed_unix_ms ?? message.deliveryFailedUnixMs ?? 0);
  return {
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

function patchConversationSummary(draft: Record<string, any> | undefined, agentInstanceId: string, payload: any) {
  if (!draft || !agentInstanceId) return;
  const message = payload?.message || {};
  const createdUnixMs = Number(message.created_unix_ms ?? message.createdUnixMs ?? Date.now());
  const existing = draft[agentInstanceId] || { agentInstanceId, agentId: '', projectId: '', title: '' };
  draft[agentInstanceId] = {
    ...existing,
    lastMessageUnixMs: Math.max(Number(existing.lastMessageUnixMs || 0), createdUnixMs),
    unreadCount: Number(payload?.unread_count ?? existing.unreadCount ?? 0),
  };
  if (!existing.title && String(message.body || '').trim()) {
    draft[agentInstanceId].title = String(message.body || '').trim().slice(0, 80);
  }
}

function directChatArgs(agentInstanceId: string) {
  return { agentInstanceId, limit: 50 };
}

function guideChatArgs() {
  return { limit: 80 };
}

function applyChatMessageToCaches(dispatch: any, message: ChatMessage, rawMessage: any, agentId: string, _chainId: string, _ctx: WsCtx) {
  if (agentId === GUIDE_AGENT_ID) {
    dispatch(chatEndpoints.util.updateQueryData('fetchGuideChat', guideChatArgs(), (draft: any) => {
      if (!draft) return;
      upsertChatMessage(draft.messages || (draft.messages = []), message);
    }));
  } else if (agentId) {
    dispatch(chatEndpoints.util.updateQueryData('fetchDirectChat', directChatArgs(agentId), (draft: any) => {
      if (!draft) return;
      upsertChatMessage(draft.messages || (draft.messages = []), message);
    }));
  }
  if (agentId) {
    dispatch(chatEndpoints.util.updateQueryData('listConversationSummaries', undefined, (draft: any) => patchConversationSummary(draft, agentId, { message: rawMessage })));
    dispatch(appendMessage({ agentId, message: rawMessage }));
  }
}

function handleTaskEvent(dispatch: any, payload: any) {
  dispatch(taskEventReceived(payload));
  if (payload.task) dispatch(updateTaskStateDirectly(payload.task));
  if (payload.chain) dispatch(updateChainStateDirectly(payload.chain));

  const taskId = String(payload.task_id || payload.task?.task_id || '');
  const chainId = String(payload.chain_id || payload.chain?.chain_id || payload.task?.chain_id || '');
  dispatch(wsRefreshRequested(`task_event:${chainId || taskId || 'unknown'}`));

  if (payload.task && taskId) {
    const normalizedTask = normalizeTask(payload.task);
    dispatch(tasksApi.util.upsertQueryData('fetchTask', { taskId }, { task: normalizedTask }));
    if (chainId) {
      dispatch(tasksApi.util.updateQueryData('fetchChainTasks', { chainId }, (draft: any) => {
        if (!draft) return;
        const tasks = draft.tasks || (draft.tasks = []);
        const index = tasks.findIndex((task: any) => task.taskId === taskId);
        if (index >= 0) tasks[index] = { ...tasks[index], ...normalizedTask };
        else tasks.unshift(normalizedTask);
      }));
    }
  } else if (payload.fetch_required && taskId) {
    // Oversized task/chain records arrive as a compact fetch_required event.
    // In practice this is the common case (full task+chain JSON exceeds the WS
    // inline limit for any real chain), so this path MUST fetch authoritative
    // state. forceRefetch is required: without it RTK Query dedupes against the
    // stale cache entry and the status/comments never change in the UI.
    dispatch(tasksApi.endpoints.fetchTask.initiate({ taskId }, { subscribe: false, forceRefetch: true })).unwrap().then((data: any) => {
      const normalizedTask = data?.task;
      if (!normalizedTask) return;
      if (chainId) {
        dispatch(tasksApi.util.updateQueryData('fetchChainTasks', { chainId }, (draft: any) => {
          if (!draft) return;
          const tasks = draft.tasks || (draft.tasks = []);
          const index = tasks.findIndex((task: any) => task.taskId === taskId);
          if (index >= 0) tasks[index] = { ...tasks[index], ...normalizedTask };
          else tasks.unshift(normalizedTask);
        }));
      }
    }).catch(() => undefined);
    // The compact fallback omits the chain payload and comment_id, so refetch the
    // authoritative task log (comments live here) for any open task-detail view.
    dispatch(heimdallApi.util.invalidateTags([{ type: 'TaskLog', id: taskId }]));
  }

  if (payload.chain_fetch_required && chainId) {
    dispatch(heimdallApi.util.invalidateTags([
      { type: 'Chain', id: chainId },
      { type: 'ChainTasks', id: chainId },
    ]));
  }

  if (taskId) {
    const eventRecord = normalizeTaskLogEvent(payload);
    const patchLog = (args: { taskId: string; limit?: number }) => {
      dispatch(tasksApi.util.updateQueryData('fetchTaskLog', args, (draft: any) => {
        if (!draft) return;
        const events = draft.events || (draft.events = []);
        const index = events.findIndex((event: any) => event.eventId === eventRecord.eventId);
        if (index >= 0) events[index] = { ...events[index], ...eventRecord };
        else {
          events.push(eventRecord);
          events.sort((left: any, right: any) => Number(left.createdUnixMs || 0) - Number(right.createdUnixMs || 0));
          draft.total = Number(draft.total || 0) + 1;
        }
      }));
    };
    patchLog({ taskId });
    patchLog({ taskId, limit: 50 });
  }
}

function handleChatEvent(dispatch: any, payload: any, ctx: WsCtx) {
  dispatch(chatEventReceived(payload));
  const agentId = String(payload.agent_instance_id || '');
  const eventChainId = String(payload.chain_id || '');
  const focusedChainId = String(ctx.focusedChainId || '');
  const focusedCoordinatorAgentInstanceId = String(ctx.focusedCoordinatorAgentInstanceId || '');
  const focusedCoordinatorEvent = Boolean(focusedChainId && focusedCoordinatorAgentInstanceId && focusedCoordinatorAgentInstanceId === agentId);
  const hasInlineMessage = Boolean(payload.message);
  const message = hasInlineMessage ? normalizeChatMessage(payload.message) : null;
  const direction = String(payload.direction || '');
  const isStatusOnlyEvent = !message && (direction === 'read' || direction === 'delivered' || direction === 'delivery_failed');

  dispatch(wsRefreshRequested(`chat_event:${agentId || payload.message_id || 'unknown'}`));
  if (isStatusOnlyEvent) {
    if (agentId) {
      const statusPatch = {
        agentId,
        messageId: String(payload.message_id || ''),
        deliveredUnixMs: Number(payload.delivered_unix_ms || payload.deliveredUnixMs || 0),
        readUnixMs: Number(payload.read_unix_ms || payload.readUnixMs || 0),
        deliveryFailedUnixMs: Number(payload.delivery_failed_unix_ms || payload.deliveryFailedUnixMs || 0),
        deliveryError: String(payload.delivery_error || payload.deliveryError || ''),
      };
      dispatch(patchChatMessageStatus(statusPatch));
      const patchCache = (draft: any) => {
        if (!draft?.messages) return;
        const messageId = statusPatch.messageId;
        for (const message of draft.messages) {
          const matchesId = messageId && String(message.id || '') === messageId;
          const matchesReadWatermark = !messageId && statusPatch.readUnixMs > 0 && message.author === 'user' && Number(message.createdUnixMs || 0) <= statusPatch.readUnixMs;
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
      dispatch(chatEndpoints.util.updateQueryData('listConversationSummaries', undefined, (draft: any) => {
        if (draft?.[agentId] && payload.unread_count !== undefined) draft[agentId].unreadCount = Number(payload.unread_count || 0);
      }));
      if (statusPatch.messageId && !statusPatch.deliveredUnixMs && !statusPatch.readUnixMs && !statusPatch.deliveryFailedUnixMs) {
        dispatch(chatEndpoints.endpoints.fetchChatMessage.initiate({ messageId: statusPatch.messageId }, { subscribe: false, forceRefetch: true })).unwrap().catch(() => undefined);
      }
    }
    return;
  }
  if (!message && payload.fetch_required && String(payload.fetch_kind || '') === 'chat_message') {
    const messageId = String(payload.fetch_id || payload.message_id || '');
    if (messageId) {
      dispatch(chatEndpoints.endpoints.fetchChatMessage.initiate({ messageId }, { subscribe: false })).unwrap().catch(() => undefined);
    }
    return;
  }
  if (focusedCoordinatorEvent || eventChainId) {
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
    dispatch(heimdallApi.util.invalidateTags([{ type: 'ConversationSummaries', id: 'ALL' }]));
  }
}

function handleMemoryEvent(dispatch: any, payload: any) {
  dispatch(memoryEventReceived(payload));
  const memoryId = String(payload.memory_id || payload.record?.memory_id || payload.memory?.memory_id || '');
  if (memoryId) {
    dispatch(applyMemoryEventRecord(payload));
    dispatch(heimdallApi.util.invalidateTags([{ type: 'Memory', id: memoryId }, { type: 'MemoryHistory', id: memoryId }]));
  }
  const change = String(payload.change || payload.event || '').toLowerCase();
  if (change.includes('created') || change.includes('archived') || change.includes('deleted')) {
    dispatch(heimdallApi.util.invalidateTags([{ type: 'Memory', id: 'ALL' }]));
  }
}

function handleMergeDecisionPending(dispatch: any, payload: any, ctx: WsCtx) {
  const chainId = String(payload.chain_id || '');
  if (chainId && ctx.focusedChainId === chainId) {
    dispatch(wsChainViewRefreshRequested(`merge_decision_pending:${chainId}`));
  }
  if (chainId) {
    dispatch(heimdallApi.util.invalidateTags([{ type: 'Workspace', id: chainId }]));
  }
  dispatch(mergeDecisionEventReceived(payload));
  dispatch(heimdallApi.util.invalidateTags([{ type: 'MergeDecisions', id: 'ALL' }, { type: 'Attention', id: 'ALL' }]));
}

function handleAgentEvent(dispatch: any, payload: any, ctx: WsCtx) {
  if (payload?.type === 'agent_lifecycle_changed' || payload?.type === 'agent_update') {
    dispatch(agentLifecycleEventReceived(payload));
  }
  if (payload?.type === 'agent_runtime_changed') {
    dispatch(agentRuntimeEventReceived(payload));
  }
  const agentId = String(payload.target_agent_instance_id || payload.agent_instance_id || payload.agent?.agent_instance_id || payload.record?.agent_instance_id || '');
  dispatch(wsRefreshRequested(`${payload.type}:${agentId}`));
  if (ctx.focusedChainId) {
    dispatch(wsChainViewRefreshRequested(`${payload.type}:${agentId}`));
  }
  // Agent lifecycle/runtime/update events are targeted and contain enough fields
  // for chatSlice reducers to patch the single agent row. Do not invalidate an
  // Agents list tag here; that can turn frequent heartbeats/runtime events into
  // full agents-list refetches once the Agents domain moves to RTKQ.
}

export function handleUserWsEvent(dispatch: any, payload: any, ctx: WsCtx = {}) {
  switch (payload?.type) {
    case 'task_event':
      handleTaskEvent(dispatch, payload);
      return;
    case 'chat_event':
      handleChatEvent(dispatch, payload, ctx);
      return;
    case 'chat_approval':
      if (payload?.approval) dispatch(chatApprovalEventReceived(payload));
      dispatch(heimdallApi.util.invalidateTags([{ type: 'ChatApprovals', id: 'ALL' }, { type: 'Attention', id: 'ALL' }]));
      return;
    case 'memory_event':
      handleMemoryEvent(dispatch, payload);
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
    default:
      return;
  }
}
