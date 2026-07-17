import * as daemonApi from '../daemonApi';
import { heimdallApi, withSessionQuery } from '../heimdallApi';

const GUIDE_AGENT_ID = 'guide@heimdall';

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

function timeLabel(unixMs: number): string {
  return unixMs > 0 ? new Date(unixMs).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' }) : '';
}

function mapMessage(message: any): ChatMessage {
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

function normalizeChatPage(agentInstanceId: string, data: any, isAppend = false) {
  return {
    agentId: agentInstanceId,
    messages: (data?.messages || []).map(mapMessage).reverse(),
    nextCursor: Number(data?.next_cursor || data?.nextCursor || 0),
    hasMore: Number(data?.next_cursor || data?.nextCursor || 0) > 0,
    isAppend,
  };
}

function normalizeConversationSummaries(data: any) {
  const byId: Record<string, any> = {};
  for (const row of data?.chats || []) {
    const id = String(row.agent_instance_id || row.agentInstanceId || '');
    if (!id) continue;
    byId[id] = {
      agentInstanceId: id,
      agentId: String(row.agent_id || row.agentId || ''),
      projectId: String(row.project_id || row.projectId || ''),
      title: String(row.title || ''),
      lastMessageUnixMs: Number(row.last_message_unix_ms || row.lastMessageUnixMs || 0),
      unreadCount: Number(row.unread_count || row.unreadCount || 0),
    };
  }
  return byId;
}

function optimisticMessage(id: string, body: string): ChatMessage {
  const now = Date.now();
  return {
    id,
    author: 'user',
    body,
    timestamp: timeLabel(now),
    createdUnixMs: now,
    deliveredAt: '',
    deliveredUnixMs: 0,
    readAt: '',
    readUnixMs: 0,
    deliveryFailedAt: '',
    deliveryFailedUnixMs: 0,
    deliveryError: '',
    interrupt: false,
    sending: true,
    optimistic: true,
    error: false,
  };
}

function upsertMessage(messages: ChatMessage[], next: ChatMessage) {
  let index = messages.findIndex((message) => message.id === next.id);
  if (index < 0 && next.author === 'user') {
    index = messages.findIndex((message) => message.author === 'user' && message.body === next.body && (message.sending || message.optimistic || String(message.id || '').startsWith('local_')));
  }
  if (index >= 0) {
    const current = messages[index];
    messages[index] = {
      ...current,
      ...next,
      deliveredUnixMs: Math.max(Number(current.deliveredUnixMs || 0), Number(next.deliveredUnixMs || 0)),
      readUnixMs: Math.max(Number(current.readUnixMs || 0), Number(next.readUnixMs || 0)),
      deliveryFailedUnixMs: Math.max(Number(current.deliveryFailedUnixMs || 0), Number(next.deliveryFailedUnixMs || 0)),
      sending: false,
      optimistic: false,
    };
    return;
  }
  messages.push(next);
}

function mergeOlderMessages(existing: ChatMessage[], older: ChatMessage[]) {
  const byId = new Map<string, ChatMessage>();
  for (const message of [...older, ...existing]) {
    byId.set(message.id || `${message.createdUnixMs}-${message.body}`, message);
  }
  return Array.from(byId.values()).sort((left, right) => Number(left.createdUnixMs || 0) - Number(right.createdUnixMs || 0));
}

function patchConversationSummary(draft: Record<string, any> | undefined, agentInstanceId: string, body: string) {
  if (!draft) return;
  const now = Date.now();
  const existing = draft[agentInstanceId] || { agentInstanceId, agentId: '', projectId: '', title: '' };
  draft[agentInstanceId] = {
    ...existing,
    lastMessageUnixMs: now,
    unreadCount: 0,
  };
  if (!existing.title && body.trim()) {
    draft[agentInstanceId].title = body.trim().slice(0, 80);
  }
}

function hydrateChatPage(dispatch: any, payload: { agentId: string; messages: ChatMessage[]; nextCursor: number; isAppend: boolean; markedRead: boolean }) {
  dispatch({ type: 'chat/receiveChatPage', payload });
}

function appendChatMessage(dispatch: any, agentId: string, rawMessage: any) {
  if (!agentId || !rawMessage) return;
  dispatch({ type: 'chat/appendMessage', payload: { agentId, message: rawMessage } });
}

function guideChatArgs() {
  return { limit: 80 };
}

export const chatEndpoints = heimdallApi.injectEndpoints({
  endpoints: (build) => ({
    listConversationSummaries: build.query<Record<string, any>, void>({
      queryFn: withSessionQuery(async (_arg, { session }) => {
        if (!session?.clientToken) return {};
        const data = await daemonApi.listConversations({
          daemonUrl: session.daemonUrl,
          clientInstanceId: session.clientInstanceId,
          clientToken: session.clientToken,
        });
        return normalizeConversationSummaries(data);
      }),
      providesTags: [{ type: 'ConversationSummaries', id: 'ALL' }],
    }),
    fetchDirectChat: build.query<any, { agentInstanceId: string; limit?: number }>({
      queryFn: withSessionQuery(async ({ agentInstanceId, limit = 50 }, { session, state }) => {
        if (!session?.clientToken || !agentInstanceId) return normalizeChatPage(agentInstanceId, null, false);
        const selectedAgentId = state?.chat?.selectedAgentId || '';
        if (selectedAgentId === agentInstanceId) {
          await daemonApi.markChatRead({
            daemonUrl: session.daemonUrl,
            clientInstanceId: session.clientInstanceId,
            clientToken: session.clientToken,
            agentInstanceId,
          }).catch(() => undefined);
        }
        const data = await daemonApi.fetchChat({
          daemonUrl: session.daemonUrl,
          clientToken: session.clientToken,
          agentInstanceId,
          limit,
          cursor: 0,
        });
        return normalizeChatPage(agentInstanceId, data, false);
      }),
      providesTags: (_result, _error, { agentInstanceId }) => [{ type: 'Chat', id: agentInstanceId }],
      async onQueryStarted({ agentInstanceId }, { dispatch, queryFulfilled }) {
        try {
          const { data } = await queryFulfilled;
          hydrateChatPage(dispatch, {
            agentId: agentInstanceId,
            messages: data?.messages || [],
            nextCursor: Number(data?.nextCursor || 0),
            isAppend: false,
            markedRead: true,
          });
          dispatch(chatEndpoints.util.updateQueryData('listConversationSummaries', undefined, (draft: any) => {
            if (draft?.[agentInstanceId]) draft[agentInstanceId].unreadCount = 0;
          }));
        } catch (_error) {
          // noop
        }
      },
    }),
    fetchDirectChatPage: build.query<any, { agentInstanceId: string; cursor: number; limit?: number }>({
      queryFn: withSessionQuery(async ({ agentInstanceId, cursor, limit = 50 }, { session }) => {
        if (!session?.clientToken || !agentInstanceId) return normalizeChatPage(agentInstanceId, null, true);
        const data = await daemonApi.fetchChat({
          daemonUrl: session.daemonUrl,
          clientToken: session.clientToken,
          agentInstanceId,
          limit,
          cursor,
        });
        return normalizeChatPage(agentInstanceId, data, true);
      }),
      async onQueryStarted({ agentInstanceId, limit = 50 }, { dispatch, queryFulfilled }) {
        try {
          const { data } = await queryFulfilled;
          hydrateChatPage(dispatch, {
            agentId: agentInstanceId,
            messages: data?.messages || [],
            nextCursor: Number(data?.nextCursor || 0),
            isAppend: true,
            markedRead: false,
          });
          dispatch(chatEndpoints.util.updateQueryData('fetchDirectChat', { agentInstanceId, limit }, (draft: any) => {
            if (!draft) return;
            draft.messages = mergeOlderMessages(draft.messages || [], data?.messages || []);
            draft.nextCursor = Number(data?.nextCursor || 0);
            draft.hasMore = Boolean(data?.hasMore);
          }));
        } catch (_error) {
          // noop
        }
      },
    }),
    fetchGuideChat: build.query<any, { limit?: number } | void>({
      queryFn: withSessionQuery(async (arg, { session }) => {
        const limit = typeof arg === 'object' && arg?.limit !== undefined ? arg.limit : 80;
        if (!session?.clientToken) return normalizeChatPage(GUIDE_AGENT_ID, null, false);
        await daemonApi.markChatRead({
          daemonUrl: session.daemonUrl,
          clientInstanceId: session.clientInstanceId,
          clientToken: session.clientToken,
          agentInstanceId: GUIDE_AGENT_ID,
        }).catch(() => undefined);
        const data = await daemonApi.fetchChat({
          daemonUrl: session.daemonUrl,
          clientToken: session.clientToken,
          agentInstanceId: GUIDE_AGENT_ID,
          limit,
          cursor: 0,
        });
        return normalizeChatPage(GUIDE_AGENT_ID, data, false);
      }),
      providesTags: [{ type: 'GuideChat', id: GUIDE_AGENT_ID }],
      async onQueryStarted(_arg, { dispatch, queryFulfilled }) {
        try {
          const { data } = await queryFulfilled;
          hydrateChatPage(dispatch, {
            agentId: GUIDE_AGENT_ID,
            messages: data?.messages || [],
            nextCursor: Number(data?.nextCursor || 0),
            isAppend: false,
            markedRead: true,
          });
          dispatch(chatEndpoints.util.updateQueryData('listConversationSummaries', undefined, (draft: any) => {
            if (draft?.[GUIDE_AGENT_ID]) draft[GUIDE_AGENT_ID].unreadCount = 0;
          }));
        } catch (_error) {
          // noop
        }
      },
    }),
    fetchGuideChatPage: build.query<any, { cursor: number; limit?: number }>({
      queryFn: withSessionQuery(async ({ cursor, limit = 80 }, { session }) => {
        if (!session?.clientToken) return normalizeChatPage(GUIDE_AGENT_ID, null, true);
        const data = await daemonApi.fetchChat({
          daemonUrl: session.daemonUrl,
          clientToken: session.clientToken,
          agentInstanceId: GUIDE_AGENT_ID,
          limit,
          cursor,
        });
        return normalizeChatPage(GUIDE_AGENT_ID, data, true);
      }),
      async onQueryStarted({ limit = 80 }, { dispatch, queryFulfilled }) {
        try {
          const { data } = await queryFulfilled;
          hydrateChatPage(dispatch, {
            agentId: GUIDE_AGENT_ID,
            messages: data?.messages || [],
            nextCursor: Number(data?.nextCursor || 0),
            isAppend: true,
            markedRead: false,
          });
          dispatch(chatEndpoints.util.updateQueryData('fetchGuideChat', { limit }, (draft: any) => {
            if (!draft) return;
            draft.messages = mergeOlderMessages(draft.messages || [], data?.messages || []);
            draft.nextCursor = Number(data?.nextCursor || 0);
            draft.hasMore = Boolean(data?.hasMore);
          }));
        } catch (_error) {
          // noop
        }
      },
    }),
    fetchChatMessage: build.query<any, { messageId: string }>({
      queryFn: withSessionQuery(async ({ messageId }, { session }) => {
        if (!session?.clientToken || !messageId) return { message: null };
        const data = await daemonApi.fetchChatMessage({
          daemonUrl: session.daemonUrl,
          clientToken: session.clientToken,
          messageId,
        });
        const raw = data?.message || null;
        return {
          message: raw ? mapMessage(raw) : null,
          rawMessage: raw,
          agentInstanceId: String(raw?.agent_instance_id || raw?.agentInstanceId || ''),
          chainId: String(raw?.chain_id || raw?.chainId || ''),
        };
      }),
      async onQueryStarted(_arg, { dispatch, queryFulfilled }) {
        try {
          const { data } = await queryFulfilled;
          const agentInstanceId = String(data?.agentInstanceId || '');
          const message = data?.message;
          const rawMessage = data?.rawMessage;
          if (!agentInstanceId || !message || !rawMessage) return;
          if (agentInstanceId === GUIDE_AGENT_ID) {
            dispatch(chatEndpoints.util.updateQueryData('fetchGuideChat', guideChatArgs(), (draft: any) => {
              if (!draft) return;
              upsertMessage(draft.messages || (draft.messages = []), message);
            }));
          } else {
            dispatch(chatEndpoints.util.updateQueryData('fetchDirectChat', { agentInstanceId, limit: 50 }, (draft: any) => {
              if (!draft) return;
              upsertMessage(draft.messages || (draft.messages = []), message);
            }));
          }
          dispatch(chatEndpoints.util.updateQueryData('listConversationSummaries', undefined, (draft: any) => patchConversationSummary(draft, agentInstanceId, String(rawMessage.body || ''))));
          appendChatMessage(dispatch, agentInstanceId, rawMessage);
        } catch (_error) {
          // noop
        }
      },
    }),
    markChatRead: build.mutation<any, { agentInstanceId: string }>({
      queryFn: withSessionQuery(async ({ agentInstanceId }, { session }) => {
        if (!session?.clientToken || !agentInstanceId) return { ok: false, agentInstanceId };
        await daemonApi.markChatRead({
          daemonUrl: session.daemonUrl,
          clientInstanceId: session.clientInstanceId,
          clientToken: session.clientToken,
          agentInstanceId,
        });
        return { ok: true, agentInstanceId };
      }),
      async onQueryStarted({ agentInstanceId }, { dispatch, queryFulfilled }) {
        try {
          await queryFulfilled;
          dispatch(chatEndpoints.util.updateQueryData('listConversationSummaries', undefined, (draft: any) => {
            if (draft?.[agentInstanceId]) draft[agentInstanceId].unreadCount = 0;
          }));
        } catch (_error) {
          // noop
        }
      },
    }),
    sendAgentMessage: build.mutation<any, { agentInstanceId: string; body: string; tempId: string; interrupt?: boolean }>({
      queryFn: withSessionQuery(async ({ agentInstanceId, body, interrupt }, { session }) => {
        const res = await daemonApi.sendToAgent({
          daemonUrl: session.daemonUrl,
          clientInstanceId: session.clientInstanceId,
          clientToken: session.clientToken,
          agentInstanceId,
          body,
          interrupt,
        });
        return { messageId: String(res.message_id || ''), agentInstanceId };
      }),
      async onQueryStarted({ agentInstanceId, body, tempId }, { dispatch, queryFulfilled }) {
        const optimistic = optimisticMessage(tempId, body);
        const patch = dispatch(chatEndpoints.util.updateQueryData('fetchDirectChat', { agentInstanceId, limit: 50 }, (draft: any) => {
          if (!draft) return;
          upsertMessage(draft.messages || (draft.messages = []), optimistic);
        }));
        const summaryPatch = dispatch(chatEndpoints.util.updateQueryData('listConversationSummaries', undefined, (draft: any) => patchConversationSummary(draft, agentInstanceId, body)));
        try {
          const { data } = await queryFulfilled;
          dispatch(chatEndpoints.util.updateQueryData('fetchDirectChat', { agentInstanceId, limit: 50 }, (draft: any) => {
            const message = (draft?.messages || []).find((entry: any) => entry.id === tempId);
            if (!message) return;
            message.id = data?.messageId || message.id;
            message.sending = false;
            message.optimistic = true;
            message.deliveredUnixMs = Date.now();
            message.deliveryFailedUnixMs = 0;
            message.deliveryError = '';
          }));
        } catch (_error) {
          patch.undo();
          summaryPatch.undo();
        }
      },
    }),
    sendGuideMessage: build.mutation<any, { body: string; tempId: string; interrupt?: boolean }>({
      queryFn: withSessionQuery(async ({ body, interrupt }, { session }) => {
        const res = await daemonApi.sendToAgent({
          daemonUrl: session.daemonUrl,
          clientInstanceId: session.clientInstanceId,
          clientToken: session.clientToken,
          agentInstanceId: GUIDE_AGENT_ID,
          body,
          interrupt,
        });
        return { messageId: String(res.message_id || '') };
      }),
      async onQueryStarted({ body, tempId }, { dispatch, queryFulfilled }) {
        const optimistic = optimisticMessage(tempId, body);
        const patch = dispatch(chatEndpoints.util.updateQueryData('fetchGuideChat', { limit: 80 }, (draft: any) => {
          if (!draft) return;
          upsertMessage(draft.messages || (draft.messages = []), optimistic);
        }));
        const summaryPatch = dispatch(chatEndpoints.util.updateQueryData('listConversationSummaries', undefined, (draft: any) => patchConversationSummary(draft, GUIDE_AGENT_ID, body)));
        try {
          const { data } = await queryFulfilled;
          dispatch(chatEndpoints.util.updateQueryData('fetchGuideChat', { limit: 80 }, (draft: any) => {
            const message = (draft?.messages || []).find((entry: any) => entry.id === tempId);
            if (!message) return;
            message.id = data?.messageId || message.id;
            message.sending = false;
            message.optimistic = true;
            message.deliveredUnixMs = Date.now();
            message.deliveryFailedUnixMs = 0;
            message.deliveryError = '';
          }));
        } catch (_error) {
          patch.undo();
          summaryPatch.undo();
        }
      },
    }),
  }),
  overrideExisting: false,
});

export const {
  useListConversationSummariesQuery,
  useFetchDirectChatQuery,
  useLazyFetchDirectChatPageQuery,
  useFetchGuideChatQuery,
  useLazyFetchGuideChatPageQuery,
  useLazyFetchChatMessageQuery,
  useSendAgentMessageMutation,
  useSendGuideMessageMutation,
} = chatEndpoints;
