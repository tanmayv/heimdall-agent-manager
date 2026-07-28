import { heimdallApi } from '../heimdallApi';
import { cookieJsonFetch } from '../cookieFetch';

// UI-14: cookie-authenticated sidebar data for the live shell. The shell serves
// the rewrite behind the trusted proxy, so these use `credentials: 'include'`
// (same auth session as `/api/v1/me`) — not the legacy per-client token session.
// Server state lives in RTK Query; WS events invalidate the tags below so the
// sidebar's unread badges refresh through the single user-WS invalidation path.

export type SidebarConversation = {
  conversationId: string;
  agentId: string;
  agentInstanceId: string;
  agentName?: string;
  projectId: string;
  title: string;
  unreadCount: number;
  updatedAt: string;
};

export type SidebarProject = {
  projectId: string;
  name: string;
  isDefaultConversations?: boolean;
};

function asNumber(value: any): number {
  const parsed = Number(value ?? 0);
  return Number.isFinite(parsed) ? parsed : 0;
}

function normalizeSidebarConversation(raw: any): SidebarConversation {
  const conversationId = String(raw?.conversation_id || raw?.conversationId || raw?.id || '');
  const agentInstanceId = String(raw?.agent_instance_id || raw?.agentInstanceId || raw?.instance_id || '');
  const agentId = String(raw?.agent_id || raw?.agentId || raw?.agent || 'unknown-agent');
  const projectId = String(raw?.project_id || raw?.projectId || 'default-conversations');
  return {
    conversationId,
    agentId: agentId || 'unknown-agent',
    agentInstanceId,
    agentName: String(raw?.agent_name || raw?.agentName || raw?.agent_display_name || raw?.agentDisplayName || '').trim() || undefined,
    projectId: projectId || 'default-conversations',
    title: String(raw?.title || raw?.last_message_preview || raw?.lastMessagePreview || agentInstanceId || conversationId || 'Untitled session'),
    unreadCount: asNumber(raw?.unread_count ?? raw?.unreadCount),
    updatedAt: String(raw?.updated_at || raw?.updatedAt || raw?.last_message_at || raw?.lastMessageAt || ''),
  };
}

function normalizeSidebarProject(raw: any): SidebarProject {
  const name = String(raw?.name || raw?.title || 'Untitled project');
  const projectId = String(raw?.project_id || raw?.projectId || raw?.id || '');
  const isDefaultConversations = raw?.is_default_conversations === true || raw?.isDefaultConversations === true || projectId === 'default-conversations';
  return { projectId: projectId || (isDefaultConversations ? 'default-conversations' : name), name, isDefaultConversations };
}

async function fetchCookieJson(path: string): Promise<any> {
  const rows = await cookieJsonFetch(path);
  return Array.isArray(rows) ? rows : [];
}

export const sidebarApi = heimdallApi.injectEndpoints({
  endpoints: (build) => ({
    // Conversations list for the sidebar tree. Tagged so the user-WS chat-event
    // path can invalidate it and refresh unread badges.
    listSidebarConversations: build.query<SidebarConversation[], { limit?: number } | void>({
      queryFn: async (arg) => {
        try {
          const limit = (arg && typeof arg === 'object' && arg.limit) || 100;
          const rows = await fetchCookieJson(`/chats?limit=${limit}`);
          const conversations = rows.map(normalizeSidebarConversation).filter((c) => c.conversationId);
          return { data: conversations };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error || 'Request failed') } as any };
        }
      },
      providesTags: (result) => [
        { type: 'SidebarConversations' as const, id: 'ALL' },
        ...(result || []).map((c) => ({ type: 'SidebarConversations' as const, id: c.conversationId })),
      ],
    }),
    listSidebarProjects: build.query<SidebarProject[], { limit?: number } | void>({
      queryFn: async (arg) => {
        try {
          const limit = (arg && typeof arg === 'object' && arg.limit) || 100;
          const rows = await fetchCookieJson(`/projects?limit=${limit}`);
          return { data: rows.map(normalizeSidebarProject) };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error || 'Request failed') } as any };
        }
      },
      providesTags: [{ type: 'SidebarProjects' as const, id: 'ALL' }],
    }),
  }),
});

export const { useListSidebarConversationsQuery, useListSidebarProjectsQuery } = sidebarApi;
