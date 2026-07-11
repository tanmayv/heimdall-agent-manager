import { useState, useEffect, useCallback } from 'react';

export interface UrlParams {
  view: string;
  agentId: string;
  taskId: string;
  chainId: string;
  memoryId: string;
}

export function getUrlParams(): UrlParams {
  const params = new URLSearchParams(window.location.search);
  return {
    view: params.get('view') || 'chat',
    agentId: params.get('agentId') || '',
    taskId: params.get('taskId') || '',
    chainId: params.get('chainId') || '',
    memoryId: params.get('memoryId') || '',
  };
}

export function updateUrlParams(updates: Partial<Record<keyof UrlParams, string | null>>) {
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
  window.history.pushState(null, '', url);
  window.dispatchEvent(new Event('popstate'));
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
