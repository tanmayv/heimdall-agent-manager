import TaskChainsPage from '../taskchain/TaskChainsPage';
import { useEffect, useMemo, useRef, useState } from 'react';
import { useDispatch } from 'react-redux';
import ConversationLaunchComposer from '../chat/ConversationLaunchComposer';
import ConversationsHomePage from '../chat/ConversationsHomePage';
import ConversationThreadPage from '../chat/ConversationThreadPage';
import CommandPalette from '../command-palette/CommandPalette';
import Icon, { type IconName } from '../Icon';
import { useViewport, MobileTabBar, MobileTopBar } from './responsive';
import { heimdallApi } from '../../api/heimdallApi';
import { useUserWebSocket } from '../../api/useUserWebSocket';
import { cookieJsonFetch, cookieMutation } from '../../api/cookieFetch';
import { useListAgentIdentitiesQuery } from '../../api/endpoints/agents';
import { useListSidebarConversationsQuery, useListSidebarProjectsQuery, type SidebarConversation, type SidebarProject } from '../../api/endpoints/sidebar';
import { useListBridgesQuery } from '../../api/endpoints/bridgeSupport';
import { buildRouteHash, getRoutePathname } from '../../utils/appLocation';
import { readLastSeenUserId, removeAppOwnedClientStorage, writeLastSeenUserId } from '../../utils/clientPersistence';
import BridgesPanel from '../settings/BridgesPanel';
import ProjectsPanel from '../settings/ProjectsPanel';
import { AgentsPanel, NewAgentPage } from '../agents/AgentsPanel';
import { AgentDetailPanel } from '../agents/AgentDetailPanel';
import { ProviderEditorPage, ProvidersPanel } from '../settings/ProvidersPanel';
import UserTokensPanel from '../settings/UserTokensPanel';
import MemoryPanel from '../settings/MemoryPanel';
import LibraryPage from '../LibraryPage';
import ArtifactViewer from '../ArtifactViewer';
import { clearUserClientState } from '../../store/chatSlice';
import { priorUserClientStateCleared } from '../../store/store';

type ShellRoute = {
  path: string;
  label: string;
  icon: IconName;
  description: string;
  group: 'primary' | 'secondary';
};

type AuthUser = {
  user_id?: string;
  name?: string;
  display_name?: string;
  email?: string;
};

type AuthStatus = 'checking' | 'authenticated' | 'unauthenticated' | 'forbidden' | 'error';

type AuthState = {
  status: AuthStatus;
  user: AuthUser | null;
  loginUrl: string;
  logoutUrl: string;
  error: string;
};


type ConversationSummary = {
  conversationId: string;
  agentId: string;
  agentInstanceId: string;
  agentName: string;
  projectId: string;
  title: string;
  unreadCount: number;
  updatedAt: string;
  lastMessageAt?: string;
  lastMessagePreview?: string;
  lastMessageDirection?: string;
  lastMessageUnixMs?: number;
  lastMessage?: any;
  participants?: any[];
  bridgeId?: string;
  runtimeStatus?: string;
};

type ProjectSummary = {
  projectId: string;
  name: string;
  isDefaultConversations?: boolean;
};

type SessionGroup = {
  conversation: ConversationSummary;
};

type AgentGroup = {
  agentId: string;
  agentName: string;
  unreadCount: number;
  sessions: SessionGroup[];
};

type ProjectGroup = {
  project: ProjectSummary;
  unreadCount: number;
  agents: AgentGroup[];
};

type BreadcrumbCrumb = { label: string; href?: string };

const DEFAULT_CONVERSATIONS_PROJECT: ProjectSummary = {
  projectId: 'default-conversations',
  name: 'Conversations',
  isDefaultConversations: true,
};
const NAV_ROUTES: ShellRoute[] = [
  { path: '/conversations', label: 'Conversations', icon: 'chat', description: 'Chat sessions grouped by project and agent', group: 'primary' },
  { path: '/chains', label: 'Task Chains', icon: 'tasks', description: 'Task-chain work and review', group: 'primary' },
  { path: '/agents', label: 'Agents', icon: 'grid', description: 'Agent identities and sessions', group: 'primary' },
  { path: '/library', label: 'Library', icon: 'device', description: 'Artifacts and files', group: 'primary' },
  { path: '/settings/bridges', label: 'Settings', icon: 'gear', description: 'Bridges, providers, user tokens, projects, and memory', group: 'secondary' },
];

function routeFromLocation(): string {
  const path = getRoutePathname();
  if (!path || path === '/' || path === '/index.html') return '/conversations';
  return path;
}

function isRouteActive(currentPath: string, itemPath: string): boolean {
  if (itemPath === '/conversations') return currentPath === '/conversations' || currentPath.startsWith('/conversations/');
  if (itemPath === '/settings/bridges') return currentPath.startsWith('/settings');
  return currentPath === itemPath || currentPath.startsWith(`${itemPath}/`);
}

function routeTitle(path: string): string {
  if (path === '/conversations/new') return 'New conversation';
  if (path.startsWith('/conversations/')) return 'Conversation';
  if (path === '/chains/new') return 'New task chain';
  if (path.startsWith('/chains/') && path.includes('/tasks/')) return 'Task detail';
  if (path.startsWith('/chains/')) return 'Task chain';
  if (path === '/agents/new') return 'New agent';
  if (path.startsWith('/agents/')) return 'Agent detail';
  if (path.startsWith('/library/artifacts/')) return 'Artifact viewer';
  if (path.startsWith('/library')) return 'Library';
  if (path.startsWith('/settings/bridges')) return 'Bridge settings';
  if (path.startsWith('/settings/user-tokens')) return 'User token settings';
  if (path.startsWith('/settings/projects')) return 'Project settings';
  if (path.startsWith('/settings/providers')) return 'Provider settings';
  if (path.startsWith('/settings/memory')) return 'Memory settings';
  if (path.startsWith('/settings')) return 'Settings';
  if (path.startsWith('/agents')) return 'Agents';
  if (path.startsWith('/chains')) return 'Task Chains';
  return 'Conversations';
}

function routeDescription(path: string): string {
  if (path === '/conversations/new') return 'Composer-first launch surface. Agent, project, Bridge, provider, and tier controls belong here in later UI tasks.';
  if (path.startsWith('/conversations/')) return 'Page-owned conversation area. The conversation inspector will be owned by this route, not by global shell chrome.';
  if (path.startsWith('/chains/')) return 'Creation-ordered task list and task-detail route outlet. No graph editor or global inspector is present.';
  if (path.startsWith('/agents/')) return 'Agent overview, sessions, Bridges, and memory tabs will attach to this route.';
  if (path.startsWith('/library/artifacts/')) return 'Fullscreen artifact viewer route owned by the Library surface.';
  if (path.startsWith('/library')) return 'Filterable artifact list/grid route.';
  if (path.startsWith('/settings')) return 'Settings surface for Bridges, Providers, User tokens, Projects, Memory, and Defaults.';
  return 'Chat-first home with the routed main region ready for conversation surfaces.';
}

const SETTINGS_NAV = [
  { path: '/settings/bridges', label: 'Bridges' },
  { path: '/settings/providers', label: 'Providers' },
  { path: '/settings/user-tokens', label: 'User tokens' },
  { path: '/settings/projects', label: 'Projects' },
  { path: '/settings/memory', label: 'Memory' },
  { path: '/settings/defaults', label: 'Defaults' },
];

function decodeSegment(value: string): string {
  try { return decodeURIComponent(value); } catch (_err) { return value; }
}

function routeBreadcrumbs(path: string, conversations: ConversationSummary[] = []): BreadcrumbCrumb[] {
  if (path === '/conversations/new') return [{ label: 'Conversations', href: '/conversations' }, { label: 'New Conversation' }];
  if (path.startsWith('/conversations/')) {
    const id = decodeSegment(path.slice('/conversations/'.length));
    const convo = conversations.find((item) => item.conversationId === id || item.agentInstanceId === id);
    return [{ label: 'Conversations', href: '/conversations' }, { label: convo?.agentId || 'Conversation' }, { label: convo?.agentInstanceId || id }];
  }
  if (path === '/agents/new') return [{ label: 'Agents', href: '/agents' }, { label: 'New Agent' }];
  if (path.startsWith('/agents/')) return [{ label: 'Agents', href: '/agents' }, { label: decodeSegment(path.slice('/agents/'.length)) }];
  if (path === '/settings') return [{ label: 'Settings' }];
  if (path.startsWith('/settings/providers/')) {
    const rest = path.slice('/settings/providers/'.length);
    if (rest === 'new') return [{ label: 'Settings', href: '/settings/bridges' }, { label: 'Providers', href: '/settings/providers' }, { label: 'New Provider' }];
    if (rest.endsWith('/edit')) return [{ label: 'Settings', href: '/settings/bridges' }, { label: 'Providers', href: '/settings/providers' }, { label: decodeSegment(rest.slice(0, -'/edit'.length)) }, { label: 'Edit' }];
  }
  if (path.startsWith('/settings/')) {
    const key = path.slice('/settings/'.length).split('/')[0] || 'bridges';
    const match = SETTINGS_NAV.find((item) => item.path.endsWith(`/${key}`));
    return [{ label: 'Settings', href: '/settings/bridges' }, { label: match?.label || decodeSegment(key) }];
  }
  if (path.startsWith('/chains/')) return [{ label: 'Task Chains', href: '/chains' }, { label: decodeSegment(path.split('/')[2] || 'Chain') }];
  if (path.startsWith('/library')) return [{ label: 'Library' }];
  if (path.startsWith('/agents')) return [{ label: 'Agents' }];
  return [{ label: 'Conversations' }];
}

function Breadcrumbs({ crumbs }: { crumbs: BreadcrumbCrumb[] }) {
  return <nav data-debug-id="shell-breadcrumbs" aria-label="Breadcrumb" className="flex flex-wrap items-center gap-2 text-sm text-zinc-400">{crumbs.map((crumb, index) => <span key={`${crumb.label}-${index}`} data-debug-id={`shell-breadcrumb-crumb-${index}`} className="inline-flex items-center gap-2">{index > 0 ? <span className="text-zinc-700">/</span> : null}{crumb.href && index < crumbs.length - 1 ? <a data-debug-id={`shell-breadcrumb-link-${index}`} href={shellHash(crumb.href)} className="font-semibold text-zinc-300 hover:text-white">{crumb.label}</a> : <span className="font-semibold text-white">{crumb.label}</span>}</span>)}</nav>;
}

function SettingsSubNav({ path }: { path: string }) {
  return <nav data-debug-id="settings-sub-nav" className="mb-5 -mx-1 flex gap-2 overflow-x-auto rounded-2xl border border-white/10 bg-black/20 p-2 sm:mx-0 sm:flex-wrap">{SETTINGS_NAV.map((item) => {
    const active = path === item.path || path.startsWith(`${item.path}/`) || (path === '/settings' && item.path === '/settings/bridges');
    const debugKey = item.label.toLowerCase().replace(/\s+/g, '-');
    return <a key={item.path} data-debug-id={`settings-sub-nav-${debugKey}`} href={shellHash(item.path)} className={`inline-flex min-h-[44px] shrink-0 items-center rounded-xl px-4 py-2 text-sm font-semibold ${active ? 'bg-sky-400 text-black' : 'text-zinc-300 hover:bg-white/10 hover:text-white'}`}>{item.label}</a>;
  })}</nav>;
}

function shellHash(path: string): string {
  return buildRouteHash(path, '');
}

function apiUrl(path: string): string {
  return path.startsWith('/api/v1') ? path : `/api/v1${path.startsWith('/') ? path : `/${path}`}`;
}

function authRuntimeConfig(): Record<string, any> {
  if (typeof window === 'undefined') return {};
  return (window as any).__HEIMDALL_AUTH_CONFIG__ || (window as any).__HEIMDALL_UI_CONFIG__?.auth || {};
}

function metaContent(name: string): string {
  if (typeof document === 'undefined') return '';
  return document.querySelector<HTMLMetaElement>(`meta[name="${name}"]`)?.content || '';
}

function usableAuthUrl(value: string): string {
  const trimmed = String(value || '').trim();
  if (!trimmed || (trimmed.startsWith('%') && trimmed.endsWith('%'))) return '';
  return trimmed;
}

function configuredAuthUrl(kind: 'login' | 'logout'): string {
  const cfg = authRuntimeConfig();
  const snake = `${kind}_url`;
  const camel = `${kind}Url`;
  const fromConfig = usableAuthUrl(String(cfg?.[snake] || cfg?.[camel] || ''));
  if (fromConfig) return fromConfig;
  return usableAuthUrl(metaContent(`heimdall-${kind}-url`));
}

async function fetchPublicAuthConfig(): Promise<{ loginUrl: string; logoutUrl: string }> {
  let loginUrl = configuredAuthUrl('login');
  let logoutUrl = configuredAuthUrl('logout');
  try {
    const response = await fetch(apiUrl('/auth/config'), { credentials: 'include' });
    if (response.ok) {
      const body = await response.json();
      const data = body?.data || body || {};
      loginUrl = usableAuthUrl(data.login_url || data.loginUrl || loginUrl) || loginUrl;
      logoutUrl = usableAuthUrl(data.logout_url || data.logoutUrl || logoutUrl) || logoutUrl;
    }
  } catch (_err) {}
  return { loginUrl, logoutUrl };
}

function loginUrlWithReturn(loginUrl: string): string {
  if (!loginUrl || typeof window === 'undefined') return loginUrl;
  if (loginUrl.includes('{return_to}')) return loginUrl.replace('{return_to}', encodeURIComponent(window.location.href));
  if (loginUrl.includes('{returnTo}')) return loginUrl.replace('{returnTo}', encodeURIComponent(window.location.href));
  return loginUrl;
}

function isApiV1Url(input: RequestInfo | URL): boolean {
  const value = typeof input === 'string' ? input : input instanceof URL ? input.toString() : input.url;
  try {
    const url = new URL(value, window.location.href);
    return url.pathname.startsWith('/api/v1/');
  } catch (_err) {
    return String(value).startsWith('/api/v1/');
  }
}

function installApiAuthObserver() {
  if (typeof window === 'undefined' || !(window as any).fetch || (window as any).__heimdallApiAuthObserverInstalled) return;
  const originalFetch = window.fetch.bind(window);
  (window as any).__heimdallApiAuthObserverInstalled = true;
  window.fetch = async (input: RequestInfo | URL, init?: RequestInit) => {
    const response = await originalFetch(input, init);
    if (isApiV1Url(input)) {
      if (response.status === 401) window.dispatchEvent(new CustomEvent('heimdall:api-unauthenticated'));
      if (response.status === 403) window.dispatchEvent(new CustomEvent('heimdall:api-forbidden'));
    }
    return response;
  };
}

async function bootstrapAuth(): Promise<AuthState> {
  const authConfig = await fetchPublicAuthConfig();
  const loginUrl = authConfig.loginUrl;
  try {
    const me = await fetch(apiUrl('/me'), { credentials: 'include' });
    if (me.status === 401) return { status: 'unauthenticated', user: null, loginUrl, logoutUrl: authConfig.logoutUrl, error: '' };
    if (me.status === 403) return { status: 'forbidden', user: null, loginUrl, logoutUrl: authConfig.logoutUrl, error: 'Access denied' };
    if (!me.ok) return { status: 'error', user: null, loginUrl, logoutUrl: authConfig.logoutUrl, error: `Auth check failed (${me.status})` };
    const meBody = await me.json();
    return { status: 'authenticated', user: meBody?.data || {}, loginUrl, logoutUrl: authConfig.logoutUrl, error: '' };
  } catch (error: any) {
    return { status: 'error', user: null, loginUrl, logoutUrl: configuredAuthUrl('logout'), error: String(error?.message || error || 'Auth check failed') };
  }
}


function normalizeProject(raw: any): ProjectSummary {
  const name = String(raw?.name || raw?.title || 'Untitled project');
  const projectId = String(raw?.project_id || raw?.projectId || raw?.id || '');
  // UI-3 requires default-project semantics to survive rename. Do not infer the
  // protected default project from the display name; use only a durable backend
  // marker (or the synthetic fallback project id when no backend project exists).
  const hasDefaultMarker = raw?.is_default_conversations === true || raw?.isDefaultConversations === true;
  const isSyntheticFallback = projectId === DEFAULT_CONVERSATIONS_PROJECT.projectId;
  const isDefault = hasDefaultMarker || isSyntheticFallback;
  return { projectId: projectId || (isDefault ? DEFAULT_CONVERSATIONS_PROJECT.projectId : name), name, isDefaultConversations: isDefault };
}

// UI-14: adapt cookie-auth RTK Query sidebar data into the local tree types so
// server state lives in RTK Query (and is WS-invalidated) while the tree builder
// keeps its existing typed contract.
function sidebarConversationToSummary(c: SidebarConversation, agentNamesById: Map<string, string>): ConversationSummary {
  const agentId = c.agentId || 'unknown-agent';
  return {
    conversationId: c.conversationId,
    agentId,
    agentInstanceId: c.agentInstanceId,
    agentName: displayAgentName(agentId, c.agentName || agentNamesById.get(agentId)),
    projectId: c.projectId || DEFAULT_CONVERSATIONS_PROJECT.projectId,
    title: c.title,
    unreadCount: c.unreadCount,
    updatedAt: c.updatedAt,
    lastMessageAt: c.lastMessageAt,
    lastMessagePreview: c.lastMessagePreview,
    lastMessageDirection: c.lastMessageDirection,
    lastMessageUnixMs: c.lastMessageUnixMs,
    lastMessage: c.lastMessage,
    participants: c.participants,
    bridgeId: c.bridgeId,
    runtimeStatus: c.runtimeStatus,
  };
}

function sidebarProjectToSummary(p: SidebarProject): ProjectSummary {
  const projectId = p.projectId || (p.isDefaultConversations ? DEFAULT_CONVERSATIONS_PROJECT.projectId : p.name);
  return { projectId, name: p.name, isDefaultConversations: p.isDefaultConversations || projectId === DEFAULT_CONVERSATIONS_PROJECT.projectId };
}

function looksLikeInternalId(value: string): boolean {
  return /^(agt|inst|chat|conv|usr|brg|task|chain|proj|art)_[a-z0-9]/i.test(String(value || '').trim());
}

function displayAgentName(agentId: string, name?: string): string {
  const trimmed = String(name || '').trim();
  if (trimmed && trimmed !== agentId && !looksLikeInternalId(trimmed)) return trimmed;
  return 'Unnamed agent';
}

function displayConversationTitle(conversation: ConversationSummary): string {
  const title = String(conversation.title || '').trim();
  if (!title || title === conversation.agentId || title === conversation.agentInstanceId || title === conversation.conversationId || looksLikeInternalId(title)) {
    return conversation.agentName;
  }
  return title;
}

function displayConversationMeta(conversation: ConversationSummary): string {
  if (!conversation.updatedAt) return '';
  const date = new Date(conversation.updatedAt);
  if (Number.isNaN(date.getTime())) return '';
  return date.toLocaleDateString(undefined, { month: 'short', day: 'numeric' });
}

function routeMobileTitle(path: string, conversations: ConversationSummary[]): string {
  if (path.startsWith('/conversations/') && path !== '/conversations/new') {
    const id = decodeSegment(path.slice('/conversations/'.length));
    const conversation = conversations.find((item) => item.conversationId === id || item.agentInstanceId === id);
    if (conversation) return displayConversationTitle(conversation);
  }
  return routeTitle(path);
}


function buildProjectConversationTree(conversations: ConversationSummary[], projects: ProjectSummary[]): ProjectGroup[] {
  const projectsById = new Map<string, ProjectSummary>();
  const markedDefaultProject = projects.find((project) => project.isDefaultConversations);
  const defaultProject = markedDefaultProject || DEFAULT_CONVERSATIONS_PROJECT;
  const defaultProjectId = defaultProject.projectId || DEFAULT_CONVERSATIONS_PROJECT.projectId;
  projectsById.set(defaultProjectId, { ...defaultProject, projectId: defaultProjectId, isDefaultConversations: true });
  projects.forEach((project) => {
    if (project.projectId) projectsById.set(project.projectId, project.projectId === defaultProjectId ? { ...project, isDefaultConversations: true } : project);
  });

  const grouped = new Map<string, Map<string, ConversationSummary[]>>();
  conversations.forEach((conversation) => {
    const rawProjectId = conversation.projectId || DEFAULT_CONVERSATIONS_PROJECT.projectId;
    const projectId = rawProjectId === DEFAULT_CONVERSATIONS_PROJECT.projectId ? defaultProjectId : rawProjectId;
    if (!projectsById.has(projectId)) projectsById.set(projectId, { projectId, name: projectId });
    if (!grouped.has(projectId)) grouped.set(projectId, new Map());
    const byAgent = grouped.get(projectId)!;
    if (!byAgent.has(conversation.agentId)) byAgent.set(conversation.agentId, []);
    byAgent.get(conversation.agentId)!.push(conversation);
  });
  if (!grouped.has(defaultProjectId)) grouped.set(defaultProjectId, new Map());

  return Array.from(grouped.entries()).map(([projectId, agentMap]) => {
    const agents: AgentGroup[] = Array.from(agentMap.entries()).map(([agentId, sessions]) => {
      const sortedSessions = sessions.map((conversation) => ({ conversation }));
      const named = sortedSessions.find((session) => session.conversation.agentName && session.conversation.agentName !== 'Unnamed agent')?.conversation.agentName;
      return { agentId, agentName: named || 'Unnamed agent', sessions: sortedSessions, unreadCount: sortedSessions.reduce((sum, session) => sum + session.conversation.unreadCount, 0) };
    }).sort((a, b) => b.unreadCount - a.unreadCount || a.agentName.localeCompare(b.agentName));
    return { project: projectsById.get(projectId) || { projectId, name: projectId }, agents, unreadCount: agents.reduce((sum, agent) => sum + agent.unreadCount, 0) };
  }).sort((a, b) => {
    if (a.project.isDefaultConversations) return -1;
    if (b.project.isDefaultConversations) return 1;
    return b.unreadCount - a.unreadCount || a.project.name.localeCompare(b.project.name);
  });
}

function UnreadBadge({ count, debugId }: { count: number; debugId: string }) {
  if (count <= 0) return null;
  return <span data-debug-id={debugId} className="ml-auto inline-flex min-w-5 items-center justify-center rounded-full bg-sky-400 px-1.5 py-0.5 text-[10px] font-black text-black">{count > 99 ? '99+' : count}</span>;
}

const BRIDGE_PALETTE = ['emerald', 'sky', 'violet', 'amber', 'rose', 'teal', 'fuchsia', 'lime'] as const;

function bridgeColorSlot(bridgeId?: string): string {
  if (!bridgeId) return 'zinc';
  let h = 0;
  for (let i = 0; i < bridgeId.length; i++) {
    h = (h * 31 + bridgeId.charCodeAt(i)) >>> 0;
  }
  return BRIDGE_PALETTE[h % BRIDGE_PALETTE.length];
}

function bridgeIsRevoked(bridge: any): boolean {
  const status = String(bridge?.status || bridge?.runtime_status || bridge?.runtimeStatus || bridge?.state || '').trim().toLowerCase();
  return status === 'revoked' || Boolean(bridge?.revoked_at || bridge?.revokedAt);
}

type LiveState = 'live' | 'starting' | 'stopping' | 'off' | 'stale' | 'error' | 'none';

function liveStateFromRuntime(runtimeStatus?: string): LiveState {
  switch (String(runtimeStatus || '').toLowerCase()) {
    case 'running': case 'idle': case 'busy': return 'live';
    case 'launching': case 'starting': return 'starting';
    case 'stopping': return 'stopping';
    case 'stopped': return 'off';
    case 'unreachable': return 'stale';
    case 'failed': return 'error';
    default: return 'none';
  }
}

const DOT_COLOR_CLASSES: Record<string, { solid: string; half: string }> = {
  emerald: { solid: 'bg-emerald-400', half: 'bg-emerald-400/60 border border-emerald-400' },
  sky: { solid: 'bg-sky-400', half: 'bg-sky-400/60 border border-sky-400' },
  violet: { solid: 'bg-violet-400', half: 'bg-violet-400/60 border border-violet-400' },
  amber: { solid: 'bg-amber-400', half: 'bg-amber-400/60 border border-amber-400' },
  rose: { solid: 'bg-rose-400', half: 'bg-rose-400/60 border border-rose-400' },
  teal: { solid: 'bg-teal-400', half: 'bg-teal-400/60 border border-teal-400' },
  fuchsia: { solid: 'bg-fuchsia-400', half: 'bg-fuchsia-400/60 border border-fuchsia-400' },
  lime: { solid: 'bg-lime-400', half: 'bg-lime-400/60 border border-lime-400' },
  zinc: { solid: 'bg-zinc-500', half: 'bg-zinc-500/60' },
};

function StatusDot({
  bridgeId,
  runtimeStatus,
  debugId,
  label,
}: {
  bridgeId?: string;
  runtimeStatus?: string;
  debugId?: string;
  label?: string;
}) {
  const state = liveStateFromRuntime(runtimeStatus);
  const isLive = state === 'live';
  const isStarting = state === 'starting' || state === 'stopping';
  const isRunning = isLive || isStarting;
  const colorKey = isRunning ? bridgeColorSlot(bridgeId) : 'zinc';
  const colorStyle = DOT_COLOR_CLASSES[colorKey] || DOT_COLOR_CLASSES.zinc;

  let tooltip = label ? `${label} · ` : '';
  tooltip += isRunning ? `running on ${bridgeId || 'unknown bridge'}` : 'not running';
  if (runtimeStatus) tooltip += ` (${runtimeStatus})`;

  let dot;
  if (isLive) {
    dot = <span className={`h-2 w-2 rounded-full ${colorStyle.solid} animate-pulse`} />;
  } else if (isStarting) {
    dot = <span className={`h-2 w-2 rounded-full ${colorStyle.half} animate-pulse`} />;
  } else {
    dot = <span className="h-2 w-2 rounded-full border border-zinc-500 bg-transparent" />;
  }

  return (
    <span
      data-debug-id={debugId}
      data-bridge-color={colorKey}
      data-live-state={state}
      title={tooltip}
      aria-label={tooltip}
      className="inline-flex items-center justify-center shrink-0"
    >
      {dot}
    </span>
  );
}

function ProjectGroupItem({ projectGroup }: { projectGroup: ProjectGroup }) {
  const projectId = projectGroup.project.projectId;
  const storageKey = `heimdall:project-collapsed:${projectId}`;
  const [collapsed, setCollapsed] = useState<boolean>(() => {
    try {
      return localStorage.getItem(storageKey) === 'true';
    } catch (_err) {
      return false;
    }
  });

  const toggleCollapsed = () => {
    setCollapsed((prev) => {
      const next = !prev;
      try {
        localStorage.setItem(storageKey, String(next));
      } catch (_err) {}
      return next;
    });
  };

  return (
    <div data-debug-id={`sidebar-project-group-${projectId}`} className="rounded-2xl border border-white/8 bg-black/15 p-2">
      <div className="flex items-center justify-between gap-2 px-1 py-1">
        <button
          type="button"
          data-debug-id={`sidebar-project-toggle-btn-${projectId}`}
          onClick={toggleCollapsed}
          aria-expanded={!collapsed}
          aria-controls={`sidebar-project-body-${projectId}`}
          className="flex min-w-0 flex-1 items-center gap-1.5 text-left text-sm font-semibold text-zinc-100 hover:text-white"
        >
          <span data-debug-id={`sidebar-project-chevron-${projectId}`} className="inline-flex w-4 items-center justify-center text-zinc-400">
            <Icon name={collapsed ? 'chevron-right' : 'chevron-down'} size={14} />
          </span>
          <span className="truncate">{projectGroup.project.name}</span>
        </button>
        <UnreadBadge count={projectGroup.unreadCount} debugId={`sidebar-project-unread-${projectId}`} />
      </div>
      {!collapsed && (
        <div id={`sidebar-project-body-${projectId}`} data-debug-id={`sidebar-project-body-${projectId}`}>
          {projectGroup.agents.length === 0 ? (
            <div data-debug-id={`sidebar-project-empty-${projectId}`} className="px-1 py-2 text-xs text-zinc-500">No sessions yet.</div>
          ) : (
            <div className="mt-1 space-y-1">
              {projectGroup.agents.map((agentGroup) => {
                const activeSession = agentGroup.sessions.find((s) => liveStateFromRuntime(s.conversation.runtimeStatus) === 'live')
                  || agentGroup.sessions.find((s) => liveStateFromRuntime(s.conversation.runtimeStatus) === 'starting')
                  || agentGroup.sessions[0];
                return (
                  <div key={agentGroup.agentId} data-debug-id={`sidebar-agent-group-${agentGroup.agentId}`} className="rounded-xl bg-white/[0.03] px-2 py-1.5">
                    <div className="flex items-center gap-2 text-xs font-semibold text-zinc-300">
                      <StatusDot
                        bridgeId={activeSession?.conversation.bridgeId}
                        runtimeStatus={activeSession?.conversation.runtimeStatus}
                        debugId={`sidebar-agent-status-dot-${agentGroup.agentId}`}
                        label={agentGroup.agentName}
                      />
                      <span className="min-w-0 flex-1 truncate">{agentGroup.agentName}</span>
                      <a
                        data-debug-id={`sidebar-agent-new-conversation-${agentGroup.agentId}`}
                        href={buildRouteHash('/conversations/new', `agent_id=${encodeURIComponent(agentGroup.agentId)}`)}
                        title={`Start a new conversation with ${agentGroup.agentName}`}
                        aria-label={`Start a new conversation with ${agentGroup.agentName}`}
                        className="grid h-6 w-6 shrink-0 place-items-center rounded-full border border-white/10 bg-white/5 text-zinc-300 hover:bg-sky-400 hover:text-black"
                      ><Icon name="plus" size={13} /></a>
                      <UnreadBadge count={agentGroup.unreadCount} debugId={`sidebar-agent-unread-${agentGroup.agentId}`} />
                    </div>
                    <div className="mt-1 space-y-1">
                      {agentGroup.sessions.map(({ conversation }) => (
                        <a
                          key={conversation.conversationId}
                          data-debug-id={`sidebar-session-row-${conversation.conversationId}`}
                          href={shellHash(`/conversations/${conversation.conversationId}`)}
                          className="flex items-center gap-2 rounded-lg px-2 py-1.5 text-[12px] text-zinc-400 hover:bg-white/8 hover:text-white"
                        >
                          <StatusDot
                            bridgeId={conversation.bridgeId}
                            runtimeStatus={conversation.runtimeStatus}
                            debugId={`sidebar-session-status-dot-${conversation.conversationId}`}
                            label={displayConversationTitle(conversation)}
                          />
                          <span className="min-w-0 flex-1 truncate">{displayConversationTitle(conversation)}</span>
                          {displayConversationMeta(conversation) ? <span className="shrink-0 text-[10px] text-zinc-600">{displayConversationMeta(conversation)}</span> : null}
                          <UnreadBadge count={conversation.unreadCount} debugId={`sidebar-session-unread-${conversation.conversationId}`} />
                        </a>
                      ))}
                    </div>
                  </div>
                );
              })}
            </div>
          )}
        </div>
      )}
    </div>
  );
}

function ProjectConversationTree({ groups, loading = false, error = '' }: { groups: ProjectGroup[]; loading?: boolean; error?: string }) {
  const bridgesQuery = useListBridgesQuery(undefined, { pollingInterval: 120000 });
  const bridges = (bridgesQuery.data?.bridges || []).filter((bridge: any) => !bridgeIsRevoked(bridge));

  return (
    <section data-debug-id="sidebar-project-agent-session-tree" className="mt-4 border-t border-white/10 pt-4">
      <div className="mb-2 flex items-center justify-between px-1 text-[11px] font-bold uppercase tracking-[0.18em] text-zinc-500">
        <span>Projects</span>
        {loading ? <span data-debug-id="sidebar-project-agent-session-loading" className="normal-case tracking-normal text-zinc-600">Loading…</span> : null}
      </div>
      {error ? <div data-debug-id="sidebar-project-agent-session-error" className="mb-2 rounded-xl border border-red-400/20 bg-red-400/10 px-2 py-1.5 text-[11px] leading-4 text-red-100">{error}</div> : null}
      {bridges.length > 0 && (
        <div data-debug-id="sidebar-bridge-legend" className="mb-3 flex flex-wrap items-center gap-2 px-1 text-[11px] text-zinc-400">
          <span className="font-semibold text-zinc-500">Bridges:</span>
          {bridges.map((b: any) => {
            const bridgeId = String(b.bridge_id || b.bridgeId || b.id || '');
            const label = b.label || b.machine_hostname || bridgeId;
            const slot = bridgeColorSlot(bridgeId);
            const solid = DOT_COLOR_CLASSES[slot]?.solid || 'bg-zinc-500';
            return (
              <span key={bridgeId} data-debug-id={`sidebar-bridge-legend-item-${bridgeId}`} className="inline-flex items-center gap-1">
                <span className={`h-2 w-2 rounded-full ${solid}`} />
                <span>{label}</span>
              </span>
            );
          })}
        </div>
      )}
      <div className="space-y-3">
        {groups.map((projectGroup) => (
          <ProjectGroupItem key={projectGroup.project.projectId} projectGroup={projectGroup} />
        ))}
      </div>
    </section>
  );
}

function NavItem({ item, active, collapsed, badge = 0 }: { item: ShellRoute; active: boolean; collapsed: boolean; badge?: number }) {
  const activeClass = active
    ? 'border-white/20 bg-white/12 text-white shadow-[inset_3px_0_0_rgba(14,165,233,0.95)]'
    : 'border-transparent text-zinc-400 hover:border-white/10 hover:bg-white/8 hover:text-white';
  return (
    <a
      data-debug-id={`shell-nav-${item.label.toLowerCase().replace(/[^a-z0-9]+/g, '-')}`}
      href={shellHash(item.path)}
      aria-label={collapsed ? item.label : undefined}
      title={collapsed ? item.label : item.description}
      className={`group flex min-h-11 items-center gap-3 rounded-2xl border px-3 py-2 text-sm transition ${activeClass} ${collapsed ? 'justify-center' : ''}`}
    >
      <span aria-hidden="true" className="grid h-6 w-6 shrink-0 place-items-center"><Icon name={item.icon} size={18} /></span>
      {!collapsed && (
        <span className="min-w-0">
          <span className="block truncate font-semibold">{item.label}</span>
          <span className="block truncate text-[11px] text-zinc-500 group-hover:text-zinc-400">{item.description}</span>
        </span>
      )}
      <UnreadBadge count={badge} debugId={`shell-nav-unread-${item.label.toLowerCase().replace(/[^a-z0-9]+/g, '-')}`} />
    </a>
  );
}

function authUserId(user: AuthUser | null | undefined): string {
  return String(user?.user_id || '').trim();
}

function clearPriorUserClientState(dispatch: any, nextUserId: string) {
  dispatch(heimdallApi.util.resetApiState());
  removeAppOwnedClientStorage();
  dispatch(priorUserClientStateCleared());
  dispatch(clearUserClientState({ userId: nextUserId }));
}

function AuthGate() {
  const dispatch = useDispatch<any>();
  const [auth, setAuth] = useState<AuthState>({ status: 'checking', user: null, loginUrl: configuredAuthUrl('login'), logoutUrl: configuredAuthUrl('logout'), error: '' });
  const lastSeenUserRef = useRef(readLastSeenUserId());

  useEffect(() => {
    let cancelled = false;
    let refreshing = false;
    installApiAuthObserver();

    async function refreshIdentity(reason: string) {
      if (refreshing) return;
      refreshing = true;
      try {
        const next = await bootstrapAuth();
        if (cancelled) return;
        if (next.status === 'authenticated') {
          const nextUserId = authUserId(next.user);
          const previousUserId = lastSeenUserRef.current || readLastSeenUserId();
          if (nextUserId && previousUserId && previousUserId !== nextUserId) {
            clearPriorUserClientState(dispatch, nextUserId);
          }
          if (nextUserId) {
            writeLastSeenUserId(nextUserId);
            lastSeenUserRef.current = nextUserId;
          }
        }
        setAuth(next);
      } catch (err: any) {
        if (!cancelled) setAuth({ status: 'error', user: null, loginUrl: configuredAuthUrl('login'), logoutUrl: configuredAuthUrl('logout'), error: String(err?.message || err || 'The app could not reach /api/v1/me.') });
      } finally {
        refreshing = false;
        void reason;
      }
    }

    const onUnauthenticated = () => setAuth((prev) => ({ ...prev, status: 'unauthenticated', user: null, loginUrl: prev.loginUrl || configuredAuthUrl('login') }));
    const onForbidden = () => setAuth((prev) => ({ ...prev, status: 'forbidden', error: 'Access denied' }));
    const onFocus = () => { void refreshIdentity('focus'); };
    const onVisibility = () => { if (document.visibilityState === 'visible') void refreshIdentity('visibilitychange'); };
    const onUserWsReconnect = () => { void refreshIdentity('user-ws-reconnect'); };

    void refreshIdentity('initial');
    window.addEventListener('heimdall:api-unauthenticated', onUnauthenticated);
    window.addEventListener('heimdall:api-forbidden', onForbidden);
    window.addEventListener('focus', onFocus);
    document.addEventListener('visibilitychange', onVisibility);
    window.addEventListener('heimdall:user-ws-reconnected', onUserWsReconnect);
    return () => {
      cancelled = true;
      refreshing = false;
      window.removeEventListener('heimdall:api-unauthenticated', onUnauthenticated);
      window.removeEventListener('heimdall:api-forbidden', onForbidden);
      window.removeEventListener('focus', onFocus);
      document.removeEventListener('visibilitychange', onVisibility);
      window.removeEventListener('heimdall:user-ws-reconnected', onUserWsReconnect);
    };
  }, [dispatch]);

  if (auth.status === 'checking') return <AuthStatusScreen debugId="auth-checking" title="Checking session…" body="Verifying trusted-proxy identity with /api/v1/me." />;
  if (auth.status === 'unauthenticated') return <UnauthenticatedLanding loginUrl={auth.loginUrl} />;
  if (auth.status === 'forbidden') return <AccessDenied />;
  if (auth.status === 'error') return <AuthStatusScreen debugId="auth-error" title="Unable to verify session" body={auth.error || 'The app could not reach /api/v1/me.'} />;
  return <AuthenticatedShell key={authUserId(auth.user) || 'authenticated'} user={auth.user || {}} logoutUrl={auth.logoutUrl} />;
}

function AuthStatusScreen({ debugId, title, body }: { debugId: string; title: string; body: string }) {
  return (
    <main data-debug-id={debugId} className="grid min-h-screen place-items-center bg-[#090909] px-6 text-zinc-100">
      <section className="w-full max-w-md rounded-[2rem] border border-white/10 bg-white/[0.04] p-8 text-center shadow-2xl">
        <div className="mx-auto mb-4 grid h-12 w-12 place-items-center rounded-2xl bg-white/10 text-zinc-400"><Icon name="search" size={22} /></div>
        <h1 className="text-2xl font-semibold">{title}</h1>
        <p className="mt-3 text-sm leading-6 text-zinc-400">{body}</p>
      </section>
    </main>
  );
}

function UnauthenticatedLanding({ loginUrl }: { loginUrl: string }) {
  const target = loginUrlWithReturn(loginUrl);
  useEffect(() => {
    if (!target) return;
    const timer = window.setTimeout(() => window.location.assign(target), 350);
    return () => window.clearTimeout(timer);
  }, [target]);
  return (
    <main data-debug-id="unauthenticated-landing" className="grid min-h-screen place-items-center bg-[#090909] px-6 text-zinc-100">
      <section className="w-full max-w-lg rounded-[2rem] border border-white/10 bg-white/[0.04] p-8 text-center shadow-2xl">
        <p className="text-xs font-semibold uppercase tracking-[0.22em] text-sky-300/80">Trusted-proxy sign in</p>
        <h1 className="mt-3 text-3xl font-semibold tracking-tight">Redirecting to sign in…</h1>
        <p className="mt-3 text-sm leading-6 text-zinc-400">Your session is unauthenticated. Heimdall uses the configured external identity provider; no local credentials are collected.</p>
        {target ? (
          <a data-debug-id="auth-login-link" href={target} className="mt-6 inline-flex rounded-2xl bg-sky-400 px-5 py-3 text-sm font-bold text-black hover:bg-sky-300">Sign in</a>
        ) : (
          <div data-debug-id="auth-login-missing-config" className="mt-6 rounded-2xl border border-amber-400/30 bg-amber-400/10 px-4 py-3 text-sm text-amber-100">Login URL is missing from UI auth config.</div>
        )}
      </section>
    </main>
  );
}

function AccessDenied() {
  return (
    <main data-debug-id="access-denied" className="grid min-h-screen place-items-center bg-[#090909] px-6 text-zinc-100">
      <section className="w-full max-w-md rounded-[2rem] border border-red-400/20 bg-red-400/10 p-8 text-center shadow-2xl">
        <p className="text-xs font-semibold uppercase tracking-[0.22em] text-red-200">403 forbidden</p>
        <h1 className="mt-3 text-3xl font-semibold tracking-tight">Access denied</h1>
        <p className="mt-3 text-sm leading-6 text-red-100/80">You are authenticated, but this resource is not available to your account. Heimdall will not redirect to login for 403 responses.</p>
        <a data-debug-id="access-denied-home-link" href={shellHash('/conversations')} className="mt-6 inline-flex rounded-2xl bg-white/10 px-5 py-3 text-sm font-bold text-white hover:bg-white/15">Back to conversations</a>
      </section>
    </main>
  );
}



function MemorySettingsPanel() {
  return <MemoryPanel />;
}

function DefaultsSettingsPanel() {
  const agentsQuery = useListAgentIdentitiesQuery();
  const agents = agentsQuery.data?.agents || [];
  return <div data-debug-id="settings-defaults-panel" className="w-full max-w-4xl space-y-4 text-left"><h2 className="text-xl font-semibold text-white">Defaults</h2><p className="text-sm text-zinc-400">Default-agent choices are managed from available durable identities.</p>{agentsQuery.isLoading ? <div className="text-sm text-zinc-500">Loading agents…</div> : <div className="space-y-2">{agents.map((agent: any) => <div key={agent.agent_id || agent.agentId} data-debug-id={`settings-default-agent-row-${agent.agent_id || agent.agentId}`} className="rounded-xl border border-white/10 bg-black/20 p-3"><div className="break-words font-semibold text-zinc-100">{agent.name || agent.agent_id}</div><div className="mt-1 break-all text-xs text-zinc-500">{agent.agent_id || agent.agentId} · template {agent.template_id || '—'} · tier {agent.default_tier || 'Bridge default'}</div></div>)}</div>}</div>;
}

function RouteOutlet({ path, mobileBottomPadded = false, conversations = [] }: { path: string; mobileBottomPadded?: boolean; conversations?: ConversationSummary[] }) {
  const viewport = useViewport();
  const isMobile = viewport === 'mobile';
  const description = routeDescription(path);
  const crumbs = routeBreadcrumbs(path, conversations);
  const isConversationThreadRoute = path.startsWith('/conversations/') && path !== '/conversations/new';
  const isKnownRoute = useMemo(() => {
    return [
      '/conversations', '/conversations/new', '/chains', '/chains/new', '/agents', '/agents/new', '/library', '/settings',
    ].some((known) => path === known || path.startsWith(`${known}/`)) ||
      path.startsWith('/settings/bridges') ||
      path.startsWith('/settings/user-tokens') ||
      path.startsWith('/settings/projects') ||
      path.startsWith('/settings/providers') ||
      path.startsWith('/settings/memory') ||
      path.startsWith('/settings/defaults') ||
      path === '/agents/new';
  }, [path]);

  if (isConversationThreadRoute) {
    return (
      <main data-debug-id="shell-main-route-outlet" className={`min-w-0 flex-1 overflow-hidden bg-[#090909] ${mobileBottomPadded ? 'pb-16 md:pb-0' : ''}`}>
        <ConversationThreadPage conversationId={decodeSegment(path.slice('/conversations/'.length))} />
      </main>
    );
  }

  return (
    <main data-debug-id="shell-main-route-outlet" className={`min-w-0 flex-1 overflow-auto bg-[#090909] ${mobileBottomPadded ? 'pb-20 md:pb-0' : ''}`}>
      <section className="mx-auto flex min-h-full w-full max-w-6xl flex-col items-start px-3 py-3 text-left sm:px-4 sm:py-4 lg:px-5 lg:py-5">
        {path.startsWith('/settings') ? <SettingsSubNav path={path} /> : null}
        {path === '/conversations' ? (
          <ConversationsHomePage />
        ) : path === '/conversations/new' ? (
          <ConversationLaunchComposer />
        ) : path === '/settings' || path === '/settings/bridges' ? (
          <BridgesPanel />
        ) : path === '/settings/providers' ? (
          <ProvidersPanel />
        ) : path === '/settings/user-tokens' ? (
          <UserTokensPanel />
        ) : path === '/settings/providers/new' ? (
          <ProviderEditorPage />
        ) : path.startsWith('/settings/providers/') && path.endsWith('/edit') ? (
          <ProviderEditorPage providerName={decodeSegment(path.slice('/settings/providers/'.length, -'/edit'.length))} />
        ) : path === '/settings/projects' ? (
          <ProjectsPanel />
        ) : path === '/settings/memory' ? (
          <MemorySettingsPanel />
        ) : path === '/settings/defaults' ? (
          <DefaultsSettingsPanel />
        ) : path === '/chains' ? (
          <TaskChainsPage isMobile={isMobile} />
        ) : path.startsWith('/chains/') ? (
          <TaskChainsPage chainId={decodeURIComponent(path.slice('/chains/'.length))} isMobile={isMobile} />
        ) : path === '/agents' ? (
          <AgentsPanel />
        ) : path === '/agents/new' ? (
          <NewAgentPage />
        ) : path.startsWith('/agents/') ? (
          <AgentDetailPanel agentId={decodeURIComponent(path.slice('/agents/'.length))} />
        ) : path === '/library' ? (
          <LibraryPage session={{ clientToken: 'v1', daemonUrl: '' }} />
        ) : path.startsWith('/library/artifacts/') ? (
          <ArtifactViewer artifactId={decodeURIComponent(path.slice('/library/artifacts/'.length))} daemonUrl="" clientToken="v1" onClose={() => window.history.back()} />
        ) : (
          <div className="w-full max-w-2xl rounded-2xl border border-white/10 bg-white/[0.03] p-5 text-left">
            <div data-debug-id="shell-page-placeholder-icon" className="mb-4 grid h-12 w-12 place-items-center rounded-2xl bg-white/10 text-zinc-400"><Icon name="search" size={22} /></div>
            {isKnownRoute ? <Breadcrumbs crumbs={crumbs} /> : <h1 data-debug-id="shell-route-title" className="text-2xl font-semibold tracking-tight text-white">Route not found</h1>}
            <p data-debug-id="shell-route-path" className="mt-1 text-xs text-zinc-600">{path}</p>
            <h2 className="mt-4 text-xl font-semibold text-white">{isKnownRoute ? (crumbs[crumbs.length - 1]?.label || 'Route') : 'This route is not part of the v1 shell map'}</h2>
            <p className="mt-3 text-sm leading-6 text-zinc-400">{isKnownRoute ? description : 'Use the left sidebar to navigate to a v1 route. Legacy workspace, guide, attention-badge, and inspector routes are intentionally not mounted in this shell.'}</p>
          </div>
        )}
      </section>
    </main>
  );
}

function AuthenticatedShell({ user, logoutUrl }: { user: AuthUser; logoutUrl: string }) {
  const [collapsed, setCollapsed] = useState(false);
  const [path, setPath] = useState(routeFromLocation);
  const [paletteOpen, setPaletteOpen] = useState(false);
  const [drawerOpen, setDrawerOpen] = useState(false);
  const [mobileChromeSuppressed, setMobileChromeSuppressed] = useState(false);
  const displayName = user.display_name || user.name || user.user_id || 'Current user';

  // UI-14: server state for the sidebar lives in RTK Query (cookie-auth), not
  // component-local state. The single user-WS connection invalidates the
  // SidebarConversations tag on chat/unread events so badges refresh live.
  const conversationsQuery = useListSidebarConversationsQuery({ limit: 100 });
  const projectsQuery = useListSidebarProjectsQuery({ limit: 100 });
  const agentIdentitiesQuery = useListAgentIdentitiesQuery();
  const agentNamesById = useMemo(() => {
    const map = new Map<string, string>();
    for (const agent of (agentIdentitiesQuery.data?.agents || [])) {
      const id = String(agent?.agent_id || agent?.agentId || agent?.id || '').trim();
      const name = String(agent?.name || agent?.display_name || agent?.displayName || '').trim();
      if (id && name) map.set(id, name);
    }
    return map;
  }, [agentIdentitiesQuery.data]);
  const conversations = useMemo(
    () => (conversationsQuery.data || []).map((conversation) => sidebarConversationToSummary(conversation, agentNamesById)),
    [agentNamesById, conversationsQuery.data],
  );
  const projects = useMemo(
    () => (projectsQuery.data || []).map(sidebarProjectToSummary),
    [projectsQuery.data],
  );

  // UI-14: the shell owns exactly one user WebSocket connection (cookie-auth
  // `/api/v1/user-ws`). Its events flow through the single `handleUserWsEvent`
  // invalidation path. ctxRef supplies focus state read at event time.
  const wsCtxRef = useRef({});
  const { status: wsStatus, connected: wsConnected } = useUserWebSocket(wsCtxRef);

  // UI-13: viewport-aware shell. On mobile the sidebar is an off-canvas drawer
  // (toggled), main is full-width, and a bottom tab bar replaces sidebar chrome.
  const viewport = useViewport();
  const isMobile = viewport === 'mobile';
  // Close the mobile drawer whenever the route changes.
  useEffect(() => { setDrawerOpen(false); }, [path]);

  // Mobile keyboards consume most of the viewport. While focus is inside an
  // opted-in chat composer/input, hide the mobile top bar and bottom tab bar;
  // restore them as soon as focus leaves the composer. Desktop is unaffected.
  useEffect(() => {
    if (!isMobile) { setMobileChromeSuppressed(false); return; }
    const focusSuppressesChrome = (target: EventTarget | null) => {
      const node = target as Element | null;
      return Boolean(node?.closest?.('[data-mobile-shell-chrome="hide-on-focus"]'));
    };
    const updateFromActiveElement = () => setMobileChromeSuppressed(focusSuppressesChrome(document.activeElement));
    const onFocusIn = (event: FocusEvent) => setMobileChromeSuppressed(focusSuppressesChrome(event.target));
    const onFocusOut = () => window.setTimeout(updateFromActiveElement, 0);
    document.addEventListener('focusin', onFocusIn);
    document.addEventListener('focusout', onFocusOut);
    updateFromActiveElement();
    return () => {
      document.removeEventListener('focusin', onFocusIn);
      document.removeEventListener('focusout', onFocusOut);
    };
  }, [isMobile, path]);

  // UI-12: Cmd/Ctrl-K opens the command palette (desktop). Also the sidebar
  // Search button and the mobile bottom-tab center button open the same surface.
  useEffect(() => {
    function handler(event: KeyboardEvent) {
      if ((event.metaKey || event.ctrlKey) && (event.key === 'k' || event.key === 'K')) {
        event.preventDefault();
        setPaletteOpen((open) => !open);
      }
    }
    window.addEventListener('keydown', handler);
    return () => window.removeEventListener('keydown', handler);
  }, []);

  // Palette navigation: convert a logical route into a hash location.
  const handlePaletteNavigate = (route: string) => {
    window.location.hash = buildRouteHash(route, '');
  };

  useEffect(() => {
    const update = () => setPath(routeFromLocation());
    window.addEventListener('hashchange', update);
    window.addEventListener('popstate', update);
    update();
    return () => {
      window.removeEventListener('hashchange', update);
      window.removeEventListener('popstate', update);
    };
  }, []);

  const primary = NAV_ROUTES.filter((item) => item.group === 'primary');
  const secondary = NAV_ROUTES.filter((item) => item.group === 'secondary');
  const conversationTree = useMemo(() => buildProjectConversationTree(conversations, projects), [conversations, projects]);
  const totalUnread = conversationTree.reduce((sum, project) => sum + project.unreadCount, 0);
  const mobileRouteTitle = useMemo(() => routeMobileTitle(path, conversations), [path, conversations]);
  const hideMobileShellChrome = isMobile && mobileChromeSuppressed;
  const sidebarError = String((conversationsQuery.error as any)?.error || (projectsQuery.error as any)?.error || '');
  const sidebarLoading = conversationsQuery.isLoading || projectsQuery.isLoading;

  return (
    <div data-debug-id="app-shell" className="flex h-screen bg-[#090909] text-zinc-100">
      {/* UI-13: mobile drawer scrim. Closes the off-canvas sidebar on tap. */}
      {isMobile && drawerOpen ? (
        <div
          data-debug-id="shell-mobile-drawer-scrim"
          onClick={() => setDrawerOpen(false)}
          className="fixed inset-0 z-40 bg-black/60 backdrop-blur-sm md:hidden"
          aria-hidden="true"
        />
      ) : null}
      <aside
        data-debug-id={collapsed ? 'shell-left-sidebar-collapsed' : 'shell-left-sidebar-expanded'}
        className={`flex shrink-0 flex-col border-r border-white/10 bg-[#101010] transition-[width,transform] duration-200 ${collapsed ? 'w-16' : 'w-80'} ${isMobile ? 'fixed inset-y-0 left-0 z-50 w-80 transition-transform md:static md:z-auto' : 'md:static'} ${isMobile && !drawerOpen ? '-translate-x-full md:translate-x-0' : 'translate-x-0'}`}
        aria-label="Primary navigation"
      >
        <div className={`flex items-center gap-3 border-b border-white/10 p-3 ${collapsed ? 'justify-center' : 'justify-between'}`}>
          {!collapsed && (
            <a href={shellHash('/conversations')} data-debug-id="shell-brand" className="min-w-0 rounded-xl px-2 py-1 hover:bg-white/5">
              <span className="block truncate text-sm font-black tracking-tight text-white">Heimdall</span>
              <span className="block truncate text-[11px] font-medium text-zinc-500">Hub UI v1</span>
            </a>
          )}
          <button
            data-debug-id="shell-sidebar-collapse-toggle"
            type="button"
            onClick={() => setCollapsed((value) => !value)}
            aria-label={collapsed ? 'Expand sidebar' : 'Collapse sidebar'}
            title={collapsed ? 'Expand sidebar' : 'Collapse sidebar'}
            className="grid h-10 w-10 shrink-0 place-items-center rounded-2xl border border-white/10 bg-white/5 text-sm text-zinc-300 hover:bg-white/10 hover:text-white"
          >
            <Icon name={collapsed ? 'chevron-right' : 'chevron-left'} size={16} />
          </button>
        </div>

        <div className="flex-1 overflow-y-auto p-3">
          {/* Primary action: start a new conversation. Prominent, always first. */}
          <a
            data-debug-id="shell-new-chat-button"
            href={shellHash('/conversations/new')}
            title="New chat"
            className={`mb-2 flex min-h-11 items-center gap-2 rounded-2xl bg-sky-400 px-3 py-2 text-sm font-black text-black shadow-lg shadow-sky-950/30 hover:bg-sky-300 ${collapsed ? 'justify-center' : ''}`}
          >
            <Icon name="plus" size={18} />
            {!collapsed && <span>New chat</span>}
          </a>
          <button
            type="button"
            data-debug-id="shell-command-palette-button"
            onClick={() => setPaletteOpen(true)}
            title="Command palette (Cmd/Ctrl-K)"
            className={`mb-3 flex min-h-11 items-center gap-3 rounded-2xl border border-white/10 bg-white/[0.04] px-3 py-2 text-sm text-zinc-300 hover:bg-white/[0.08] ${collapsed ? 'justify-center' : ''}`}
          >
            <span aria-hidden="true" className="grid h-6 w-6 place-items-center">⌘</span>
            {!collapsed && <span className="font-semibold">Command palette</span>}
          </button>
          <nav data-debug-id="shell-primary-nav" className="space-y-2" aria-label="Primary destinations">
            {primary.map((item) => <NavItem key={item.path} item={item} active={isRouteActive(path, item.path)} collapsed={collapsed} badge={item.path === '/conversations' ? totalUnread : 0} />)}
          </nav>
          {!collapsed && <ProjectConversationTree groups={conversationTree} loading={sidebarLoading} error={sidebarError} />}
        </div>

        <div className="border-t border-white/10 p-3">
          <nav data-debug-id="shell-secondary-nav" className="mb-3 space-y-2" aria-label="Settings destinations">
            {secondary.map((item) => <NavItem key={item.path} item={item} active={isRouteActive(path, item.path)} collapsed={collapsed} />)}
          </nav>
          <div data-debug-id="shell-global-ownership-points" className={`rounded-2xl border border-white/10 bg-black/20 p-3 ${collapsed ? 'px-2 text-center' : ''}`}>
            <div data-debug-id="shell-current-user-owner" title="Current user config is shell-owned" className="text-xs font-semibold text-zinc-300">{collapsed ? 'U' : displayName}</div>
            {!collapsed && <div className="mt-1 truncate text-[11px] text-zinc-500">{user.email || user.user_id || '/api/v1 current user'}</div>}
            <div data-debug-id="shell-user-ws-owner" data-ws-status={wsStatus} title="The shell owns exactly one user WebSocket connection (/api/v1/user-ws)" className={`mt-2 inline-flex items-center gap-2 rounded-full px-2 py-1 text-[11px] font-semibold ${wsConnected ? 'bg-emerald-400/10 text-emerald-200' : wsStatus === 'error' ? 'bg-red-400/10 text-red-200' : 'bg-amber-400/10 text-amber-200'} ${collapsed ? 'justify-center' : ''}`}>
              <span className={`h-1.5 w-1.5 rounded-full ${wsConnected ? 'bg-emerald-300' : wsStatus === 'error' ? 'bg-red-300' : 'bg-amber-300 animate-pulse'}`} />
              {!collapsed && <span>{wsConnected ? 'User WS · live' : wsStatus === 'error' ? 'User WS · error' : 'User WS · connecting'}</span>}
            </div>
            {logoutUrl && !collapsed && <a data-debug-id="auth-logout-link" href={logoutUrl} className="mt-3 block text-[11px] font-semibold text-zinc-400 underline-offset-4 hover:text-white hover:underline">Sign out</a>}
          </div>
        </div>
      </aside>

      {/* UI-13: on mobile, the sidebar is an off-canvas drawer (hidden by default);
          a mobile top bar carries the drawer toggle + title, and the route outlet
          gets bottom padding so content clears the bottom tab bar. On >= md the
          sidebar is a normal static column. */}
      <div className="flex min-w-0 flex-1 flex-col">
        {isMobile && !hideMobileShellChrome ? (
          <MobileTopBar title={mobileRouteTitle} onOpenDrawer={() => setDrawerOpen(true)} />
        ) : null}
        <RouteOutlet path={path} mobileBottomPadded={isMobile && !hideMobileShellChrome} conversations={conversations} />
      </div>

      {/* UI-12/UI-13: mobile bottom tab bar with a command-palette center button.
          The center button owns the canonical `shell-mobile-palette-button` debug-id
          so the palette entry point has one stable, layout-independent id. */}
      {!hideMobileShellChrome ? (
        <MobileTabBar
          activePath={path}
          onNavigate={(route) => { window.location.hash = buildRouteHash(route, ''); }}
          onOpenPalette={() => setPaletteOpen(true)}
          chatBadge={totalUnread}
        />
      ) : null}

      <CommandPalette open={paletteOpen} onClose={() => setPaletteOpen(false)} onNavigate={handlePaletteNavigate} />
    </div>
  );
}

export default function AppShell() {
  return <AuthGate />;
}
