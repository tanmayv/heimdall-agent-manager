import type { LauncherIntent } from '../../store/workspaceLayoutSlice';

export function launcherIntentFromSearch(search: string): LauncherIntent | undefined {
  const intent = new URLSearchParams(search.startsWith('?') ? search.slice(1) : search).get('intent');
  return intent === 'agent' || intent === 'shell' ? intent : undefined;
}

/** Keep launch bookmarks working while the plain home route becomes the dashboard. */
export function resolveShellRoute(pathname: string, search: string): string {
  const path = pathname.length > 1 && pathname.endsWith('/') ? pathname.slice(0, -1) : pathname;
  const home = !path || path === '/' || path === '/index.html' || path === '/home' || path === '/cards'
    || path.includes('/preview/') || path.includes('/proxy/');
  if (home) return launcherIntentFromSearch(search) ? '/new' : '/home';
  if (path.startsWith('/c/')) return '/conversations/' + path.slice('/c/'.length);
  return path;
}
