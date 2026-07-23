import { useEffect, useMemo, useState } from 'react';
import { buildRouteHash, getRoutePathname } from '../../utils/appLocation';

type ShellRoute = {
  path: string;
  label: string;
  icon: string;
  description: string;
  group: 'primary' | 'secondary';
};

const NAV_ROUTES: ShellRoute[] = [
  { path: '/conversations', label: 'Conversations', icon: '💬', description: 'Chat sessions grouped by project and agent', group: 'primary' },
  { path: '/chains', label: 'Task Chains', icon: '☑', description: 'Task-chain work and review', group: 'primary' },
  { path: '/agents', label: 'Agents', icon: '🤖', description: 'Agent identities and sessions', group: 'primary' },
  { path: '/library', label: 'Library', icon: '▣', description: 'Artifacts and files', group: 'primary' },
  { path: '/settings', label: 'Settings', icon: '⚙', description: 'Bridges, projects, providers, and memory', group: 'secondary' },
];

function routeFromLocation(): string {
  const path = getRoutePathname();
  if (!path || path === '/' || path === '/index.html') return '/conversations';
  return path;
}

function isRouteActive(currentPath: string, itemPath: string): boolean {
  if (itemPath === '/conversations') return currentPath === '/conversations' || currentPath.startsWith('/conversations/');
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
  if (path.startsWith('/settings')) return 'Settings surface for Bridges, Projects, Providers, Memory, and Defaults.';
  return 'Chat-first home with the routed main region ready for conversation surfaces.';
}

function shellHash(path: string): string {
  return buildRouteHash(path, '');
}

function NavItem({ item, active, collapsed }: { item: ShellRoute; active: boolean; collapsed: boolean }) {
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
      <span aria-hidden="true" className="grid h-6 w-6 shrink-0 place-items-center text-base">{item.icon}</span>
      {!collapsed && (
        <span className="min-w-0">
          <span className="block truncate font-semibold">{item.label}</span>
          <span className="block truncate text-[11px] text-zinc-500 group-hover:text-zinc-400">{item.description}</span>
        </span>
      )}
    </a>
  );
}

function RouteOutlet({ path }: { path: string }) {
  const title = routeTitle(path);
  const description = routeDescription(path);
  const isKnownRoute = useMemo(() => {
    return [
      '/conversations', '/conversations/new', '/chains', '/chains/new', '/agents', '/agents/new', '/library', '/settings',
    ].some((known) => path === known || path.startsWith(`${known}/`)) ||
      path.startsWith('/settings/bridges') ||
      path.startsWith('/settings/projects') ||
      path.startsWith('/settings/providers') ||
      path.startsWith('/settings/memory') ||
      path.startsWith('/settings/defaults');
  }, [path]);

  return (
    <main data-debug-id="shell-main-route-outlet" className="min-w-0 flex-1 overflow-auto bg-[#090909]">
      <section className="mx-auto flex min-h-full w-full max-w-6xl flex-col px-8 py-7">
        <div className="mb-5 flex items-center justify-between gap-4 border-b border-white/10 pb-5">
          <div>
            <p className="text-xs font-semibold uppercase tracking-[0.22em] text-sky-300/80">Routed main region</p>
            <h1 data-debug-id="shell-route-title" className="mt-2 text-3xl font-semibold tracking-tight text-white">{isKnownRoute ? title : 'Route not found'}</h1>
            <p data-debug-id="shell-route-path" className="mt-1 text-sm text-zinc-500">{path}</p>
          </div>
          <a
            data-debug-id="shell-new-conversation-link"
            href={shellHash('/conversations/new')}
            className="rounded-2xl bg-sky-400 px-4 py-2 text-sm font-bold text-black shadow-lg shadow-sky-400/20 hover:bg-sky-300"
          >
            New conversation
          </a>
        </div>
        <div className="grid flex-1 place-items-center rounded-[2rem] border border-dashed border-white/12 bg-white/[0.03] p-8 text-center">
          <div className="max-w-2xl">
            <div data-debug-id="shell-page-placeholder-icon" className="mx-auto mb-4 grid h-14 w-14 place-items-center rounded-3xl bg-white/10 text-2xl">⌁</div>
            <h2 className="text-xl font-semibold text-white">{isKnownRoute ? title : 'This route is not part of the v1 shell map'}</h2>
            <p className="mt-3 text-sm leading-6 text-zinc-400">{isKnownRoute ? description : 'Use the left sidebar to navigate to a v1 route. Legacy workspace, guide, attention-badge, and inspector routes are intentionally not mounted in this shell.'}</p>
          </div>
        </div>
      </section>
    </main>
  );
}

export default function AppShell() {
  const [collapsed, setCollapsed] = useState(false);
  const [path, setPath] = useState(routeFromLocation);

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

  return (
    <div data-debug-id="app-shell" className="flex h-screen min-h-[620px] bg-[#090909] text-zinc-100">
      <aside
        data-debug-id={collapsed ? 'shell-left-sidebar-collapsed' : 'shell-left-sidebar-expanded'}
        className={`flex shrink-0 flex-col border-r border-white/10 bg-[#101010] transition-[width] duration-200 ${collapsed ? 'w-16' : 'w-80'}`}
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
            {collapsed ? '›' : '‹'}
          </button>
        </div>

        <div className="flex-1 overflow-y-auto p-3">
          <a
            data-debug-id="shell-command-palette-button"
            href={shellHash('/conversations')}
            title="Command palette placeholder"
            className={`mb-3 flex min-h-11 items-center gap-3 rounded-2xl border border-white/10 bg-white/[0.04] px-3 py-2 text-sm text-zinc-300 hover:bg-white/8 ${collapsed ? 'justify-center' : ''}`}
          >
            <span aria-hidden="true" className="grid h-6 w-6 place-items-center">⌘</span>
            {!collapsed && <span className="font-semibold">Command palette</span>}
          </a>
          <nav data-debug-id="shell-primary-nav" className="space-y-2" aria-label="Primary destinations">
            {primary.map((item) => <NavItem key={item.path} item={item} active={isRouteActive(path, item.path)} collapsed={collapsed} />)}
          </nav>
        </div>

        <div className="border-t border-white/10 p-3">
          <nav data-debug-id="shell-secondary-nav" className="mb-3 space-y-2" aria-label="Settings destinations">
            {secondary.map((item) => <NavItem key={item.path} item={item} active={isRouteActive(path, item.path)} collapsed={collapsed} />)}
          </nav>
          <div data-debug-id="shell-global-ownership-points" className={`rounded-2xl border border-white/10 bg-black/20 p-3 ${collapsed ? 'px-2 text-center' : ''}`}>
            <div data-debug-id="shell-current-user-owner" title="Current user config is shell-owned" className="text-xs font-semibold text-zinc-300">{collapsed ? 'U' : 'Current user'}</div>
            {!collapsed && <div className="mt-1 text-[11px] text-zinc-500">/api/v1 current user + config owner</div>}
            <div data-debug-id="shell-user-ws-owner" title="The shell owns exactly one user WebSocket connection" className={`mt-2 inline-flex items-center gap-2 rounded-full bg-emerald-400/10 px-2 py-1 text-[11px] font-semibold text-emerald-200 ${collapsed ? 'justify-center' : ''}`}>
              <span className="h-1.5 w-1.5 rounded-full bg-emerald-300" />
              {!collapsed && <span>User WS owner</span>}
            </div>
          </div>
        </div>
      </aside>

      <RouteOutlet path={path} />
    </div>
  );
}
