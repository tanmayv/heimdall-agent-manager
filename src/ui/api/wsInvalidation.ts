import { heimdallApi } from './heimdallApi';
import { tasksApi } from './endpoints/tasks';
import { chatEndpoints } from './endpoints/chats';
import { chatApprovalEventReceived, mergeDecisionEventReceived } from '../store/attentionSlice';
import { GUIDE_AGENT_ID, agentLifecycleEventReceived, agentRuntimeEventReceived, appendMessage, chatEventReceived } from '../store/chatSlice';
import { appendCoordinatorChatMessage, wsChainViewRefreshRequested } from '../store/chainViewSlice';
import { wsRefreshRequested } from '../store/homeSlice';
import { applyMemoryEventRecord, auditEndedReceived, auditStartedReceived, memoryEventReceived } from '../store/memorySlice';
import { taskEventReceived, updateChainStateDirectly, updateTaskStateDirectly } from '../store/taskSlice';

type WsCtx = {
  selectedAgentId?: string;
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

function coordinatorChatArgs(chainId: string, coordinatorAgentInstanceId: string) {
  return { chainId, coordinatorAgentInstanceId, limit: 50 };
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
  } else {
    const tags: Array<{ type: 'Task' | 'ChainTasks'; id: string }> = [];
    if (taskId) tags.push({ type: 'Task', id: taskId });
    if (chainId) tags.push({ type: 'ChainTasks', id: chainId });
    if (tags.length) dispatch(heimdallApi.util.invalidateTags(tags));
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
  const selectedAgentId = String(ctx.selectedAgentId || '');
  const focusedChainId = String(ctx.focusedChainId || '');
  const focusedCoordinatorAgentInstanceId = String(ctx.focusedCoordinatorAgentInstanceId || '');
  const coordinatorChainId = eventChainId || (focusedCoordinatorAgentInstanceId && focusedCoordinatorAgentInstanceId === agentId ? focusedChainId : '');
  const hasInlineMessage = Boolean(payload.message);
  const message = hasInlineMessage ? normalizeChatMessage(payload.message) : null;

  dispatch(wsRefreshRequested(`chat_event:${coordinatorChainId || agentId || payload.message_id || 'unknown'}`));
  if (coordinatorChainId) {
    dispatch(wsChainViewRefreshRequested(`chat_event:${coordinatorChainId}:${payload.message_id || ''}`));
  }

  if (message && agentId && !coordinatorChainId) {
    if (agentId === GUIDE_AGENT_ID) {
      dispatch(chatEndpoints.util.updateQueryData('fetchGuideChat', guideChatArgs(), (draft: any) => {
        if (!draft) return;
        upsertChatMessage(draft.messages || (draft.messages = []), message);
        draft.nextCursor = Number(draft.nextCursor || 0);
        draft.hasMore = Boolean(draft.hasMore);
      }));
    } else {
      dispatch(chatEndpoints.util.updateQueryData('fetchDirectChat', directChatArgs(agentId), (draft: any) => {
        if (!draft) return;
        upsertChatMessage(draft.messages || (draft.messages = []), message);
        draft.nextCursor = Number(draft.nextCursor || 0);
        draft.hasMore = Boolean(draft.hasMore);
      }));
    }
    dispatch(chatEndpoints.util.updateQueryData('listConversationSummaries', undefined, (draft: any) => patchConversationSummary(draft, agentId, payload)));
  }

  if (message && coordinatorChainId && focusedCoordinatorAgentInstanceId) {
    dispatch(chatEndpoints.util.updateQueryData('fetchCoordinatorChat', coordinatorChatArgs(coordinatorChainId, focusedCoordinatorAgentInstanceId), (draft: any) => {
      if (!draft) return;
      upsertChatMessage(draft.messages || (draft.messages = []), message);
    }));
    dispatch(appendCoordinatorChatMessage({ chainId: coordinatorChainId, message: { ...payload.message, agent_instance_id: agentId } }));
  }

  if (selectedAgentId && selectedAgentId === agentId && message && !coordinatorChainId) {
    dispatch(appendMessage({ agentId, message: payload.message }));
  }

  if (agentId === GUIDE_AGENT_ID && ctx.guidePanelOpen && message && !coordinatorChainId) {
    dispatch(appendMessage({ agentId: GUIDE_AGENT_ID, message: payload.message }));
  }

  if (coordinatorChainId && !message) {
    dispatch(heimdallApi.util.invalidateTags([{ type: 'CoordinatorChat', id: coordinatorChainId }]));
  } else if (!coordinatorChainId && agentId === GUIDE_AGENT_ID && !message) {
    dispatch(heimdallApi.util.invalidateTags([{ type: 'GuideChat', id: GUIDE_AGENT_ID }]));
  } else if (!coordinatorChainId && agentId && !message) {
    dispatch(heimdallApi.util.invalidateTags([{ type: 'Chat', id: agentId }]));
  }

  if (!coordinatorChainId) {
    if (!message) {
      dispatch(heimdallApi.util.invalidateTags([{ type: 'ConversationSummaries', id: 'ALL' }]));
    }
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
  const agentId = String(payload.agent_instance_id || payload.agent?.agent_instance_id || payload.record?.agent_instance_id || '');
  dispatch(wsRefreshRequested(`${payload.type}:${agentId}`));
  if (ctx.focusedChainId) {
    dispatch(wsChainViewRefreshRequested(`${payload.type}:${agentId}`));
  }
  if (agentId) {
    dispatch(heimdallApi.util.invalidateTags([{ type: 'Agents', id: agentId }]));
  }
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
