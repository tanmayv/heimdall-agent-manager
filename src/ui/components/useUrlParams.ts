import { useState, useEffect, useCallback } from 'react';

export interface UrlParams {
  view: string;
  agentId: string;
  taskId: string;
  chainId: string;
  memoryId: string;
  projectId: string;
}

export function getUrlParams(): UrlParams {
  const params = new URLSearchParams(window.location.search);
  return {
    view: params.get('view') || 'chat',
    agentId: params.get('agentId') || '',
    taskId: params.get('taskId') || '',
    chainId: params.get('chainId') || '',
    memoryId: params.get('memoryId') || '',
    projectId: params.get('projectId') || '',
  };
}

const HEIMDALL_ROUTE_DEPTH_STATE_KEY = '__heimdallRouteDepth';

function routeDepth(): number {
  const raw = Number((window.history.state || {})[HEIMDALL_ROUTE_DEPTH_STATE_KEY] || 0);
  return Number.isFinite(raw) && raw > 0 ? raw : 0;
}

function ensureRouteState() {
  const state = window.history.state || {};
  if (Object.prototype.hasOwnProperty.call(state, HEIMDALL_ROUTE_DEPTH_STATE_KEY)) return;
  window.history.replaceState({ ...state, [HEIMDALL_ROUTE_DEPTH_STATE_KEY]: 0 }, '', `${window.location.pathname}${window.location.search}`);
}

export function canNavigateBackInApp(): boolean {
  ensureRouteState();
  return routeDepth() > 0;
}

export function updateUrlParams(updates: Partial<Record<keyof UrlParams, string | null>>) {
  ensureRouteState();
  const params = new URLSearchParams(window.location.search);
  Object.entries(updates).forEach(([key, val]) => {
    if (val === null || val === '') {
      params.delete(key);
    } else {
      params.set(key, val);
    }
  });
  const search = params.toString() ? `?${params.toString()}` : '';
  const url = `${window.location.pathname}${search}`;
  window.history.pushState({ ...(window.history.state || {}), [HEIMDALL_ROUTE_DEPTH_STATE_KEY]: routeDepth() + 1 }, '', url);
  window.dispatchEvent(new Event('popstate'));
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
    return () => window.removeEventListener('popstate', handlePopState);
  }, []);

  const setUrlParams = useCallback((updates: Partial<Record<keyof UrlParams, string | null>>) => {
    updateUrlParams(updates);
  }, []);

  return [params, setUrlParams] as const;
}
