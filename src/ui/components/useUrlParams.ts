import { useState, useEffect, useCallback } from 'react';
import { parseWorkspaceRoute, buildWorkspacePath, urlStateToWorkspaceRoute, workspaceRouteToUrlState } from './workspace/routes';
import { getRoutePathname, getRouteSearch, buildRouteHash } from '../utils/appLocation';

export interface UrlParams {
  view: string;
  agentId: string;
  taskId: string;
  chainId: string;
  memoryId: string;
  projectId: string;
}


const HEIMDALL_ROUTE_DEPTH_STATE_KEY = '__heimdallRouteDepth';

function readSearchParams() {
  const params = new URLSearchParams(getRouteSearch());
  return {
    view: params.get('view') || 'chat',
    agentId: params.get('agentId') || '',
    taskId: params.get('taskId') || '',
    chainId: params.get('chainId') || '',
    memoryId: params.get('memoryId') || '',
    projectId: params.get('projectId') || '',
  };
}

function urlParamsFromWorkspacePath(): UrlParams | null {
  const route = parseWorkspaceRoute(getRoutePathname());
  if (!route) return null;
  const query = readSearchParams();
  return {
    ...query,
    ...workspaceRouteToUrlState(route),
    memoryId: query.memoryId || '',
    projectId: query.projectId || (route.kind === 'project' ? route.projectId : ''),
  };
}

export function getUrlParams(): UrlParams {
  return urlParamsFromWorkspacePath() || readSearchParams();
}

function routeDepth(): number {
  const raw = Number((window.history.state || {})[HEIMDALL_ROUTE_DEPTH_STATE_KEY] || 0);
  return Number.isFinite(raw) && raw > 0 ? raw : 0;
}

function ensureRouteState() {
  const state = window.history.state || {};
  if (Object.prototype.hasOwnProperty.call(state, HEIMDALL_ROUTE_DEPTH_STATE_KEY)) return;
  window.history.replaceState({ ...state, [HEIMDALL_ROUTE_DEPTH_STATE_KEY]: 0 }, '', buildRouteHash(getRoutePathname(), getRouteSearch()));
}

function buildUrl(nextState: UrlParams): string {
  const workspaceRoute = urlStateToWorkspaceRoute(nextState);
  const pathname = workspaceRoute ? buildWorkspacePath(workspaceRoute) : '/';
  const params = new URLSearchParams();
  if (!workspaceRoute && nextState.view) params.set('view', nextState.view);
  if (!workspaceRoute && nextState.agentId) params.set('agentId', nextState.agentId);
  if (!workspaceRoute && nextState.chainId) params.set('chainId', nextState.chainId);
  if (!workspaceRoute && nextState.taskId) params.set('taskId', nextState.taskId);
  if (nextState.memoryId) params.set('memoryId', nextState.memoryId);
  if (nextState.projectId) params.set('projectId', nextState.projectId);
  const search = params.toString() ? `?${params.toString()}` : '';
  // Route lives in the URL hash so an Electron file:// refresh reloads index.html
  // and re-derives the route (see utils/appLocation.ts).
  return buildRouteHash(pathname, search);
}

export function canNavigateBackInApp(): boolean {
  ensureRouteState();
  return routeDepth() > 0;
}

export function updateUrlParams(updates: Partial<Record<keyof UrlParams, string | null>>) {
  ensureRouteState();
  const current = getUrlParams();
  const nextState: UrlParams = {
    view: current.view || 'chat',
    agentId: current.agentId || '',
    taskId: current.taskId || '',
    chainId: current.chainId || '',
    memoryId: current.memoryId || '',
    projectId: current.projectId || '',
  };
  Object.entries(updates).forEach(([key, val]) => {
    (nextState as any)[key] = val || '';
  });
  const url = buildUrl(nextState);
  window.history.pushState({ ...(window.history.state || {}), [HEIMDALL_ROUTE_DEPTH_STATE_KEY]: routeDepth() + 1 }, '', url);
  window.dispatchEvent(new Event('popstate'));
  // A hash change from pushState does not itself emit hashchange; the popstate
  // dispatch above drives our listener. Nothing else required here.
}

export function navigateBackOr(updates: Partial<Record<keyof UrlParams, string | null>>): boolean {
  if (canNavigateBackInApp()) {
    window.history.back();
    return true;
  }
  updateUrlParams(updates);
  return false;
}

export function useUrlParams() {
  const [params, setParams] = useState<UrlParams>(getUrlParams);

  useEffect(() => {
    const handlePopState = () => {
      setParams(getUrlParams());
    };
    window.addEventListener('popstate', handlePopState);
    // Hash-based routing: browser back/forward and manual hash edits emit
    // `hashchange` (not always `popstate`), so listen to both.
    window.addEventListener('hashchange', handlePopState);
    return () => {
      window.removeEventListener('popstate', handlePopState);
      window.removeEventListener('hashchange', handlePopState);
    };
  }, []);

  const setUrlParams = useCallback((updates: Partial<Record<keyof UrlParams, string | null>>) => {
    updateUrlParams(updates);
  }, []);

  return [params, setUrlParams] as const;
}
