import { useEffect, useRef } from 'react';
import { useDispatch, useSelector } from 'react-redux';
import { handleUserWsEvent, resyncAfterReconnect } from './wsInvalidation';
import {
  userWsConnecting,
  userWsConnected,
  userWsDisconnected,
  userWsError,
} from '../store/chatSlice';

// UI-14: the shell owns exactly ONE user WebSocket connection. It receives
// lightweight invalidation/summary events and routes them through the single
// `handleUserWsEvent` invalidation path (wsInvalidation.ts), which patches or
// invalidates the smallest relevant RTK Query cache entries. There is no second
// connection and no durable full-data stream.
//
// Auth model: browsers use the trusted-proxy/cookie-auth `/api/v1/user-ws`
// handshake. Electron cannot set Authorization on WebSocket handshakes, so it
// first mints a short-lived `/api/v1/me/ws-ticket` over bearer-authenticated
// fetch, then connects with `?ticket=...`. The long-lived `hut_...` token is
// never placed in the WebSocket URL.

const INITIAL_BACKOFF_MS = 1500;
const MAX_BACKOFF_MS = 30000;

function hasElectronDeviceAuth(): boolean {
  return typeof window !== 'undefined' && Boolean((window as any).odinApi?.deviceAuth);
}

async function electronApiBaseUrl(): Promise<string> {
  try {
    const cfg = await (window as any).odinApi?.deviceAuth?.getConfig?.();
    return String(cfg?.apiBaseUrl || (window as any).odinApi?.hubApiBaseUrl || '').replace(/\/$/, '');
  } catch (_err) {
    return String((window as any).odinApi?.hubApiBaseUrl || '').replace(/\/$/, '');
  }
}

function httpToWsUrl(base: string, path: string): string {
  const parsed = new URL(base || window.location.origin);
  parsed.protocol = parsed.protocol === 'https:' ? 'wss:' : 'ws:';
  parsed.pathname = path;
  parsed.search = '';
  parsed.hash = '';
  return parsed.toString();
}

async function electronUserWsUrl(): Promise<string> {
  const response = await fetch('/api/v1/me/ws-ticket', { method: 'POST', headers: { 'Content-Type': 'application/json' } });
  const text = await response.text();
  let body: any = {};
  if (text) {
    try { body = JSON.parse(text); } catch (_err) { body = {}; }
  }
  const data = body?.data !== undefined ? body.data : body;
  if (!response.ok) throw new Error(String(data?.error?.message || data?.message || `WebSocket ticket failed (${response.status})`));
  const ticket = String(data?.ticket || '');
  if (!ticket) throw new Error('WebSocket ticket response did not include a ticket');
  const base = await electronApiBaseUrl();
  const url = new URL(httpToWsUrl(base, '/api/v1/user-ws'));
  url.searchParams.set('ticket', ticket);
  return url.toString();
}

async function userWsUrl(): Promise<string> {
  if (typeof window === 'undefined') return '';
  if (hasElectronDeviceAuth()) return electronUserWsUrl();
  const scheme = window.location.protocol === 'https:' ? 'wss:' : 'ws:';
  return `${scheme}//${window.location.host}/api/v1/user-ws`;
}

export type UserWsContext = {
  selectedAgentId?: string;
  visibleChatAgentId?: string;
  focusedChainId?: string;
  focusedCoordinatorAgentInstanceId?: string;
  guidePanelOpen?: boolean;
};

// React hook form: pass a ref-like object whose `.current` is the live ctx.
export function useUserWebSocket(ctxRef?: { current: UserWsContext }): { status: string; connected: boolean } {
  const dispatch = useDispatch<any>();
  const connectedOnceRef = useRef(false);
  const stoppedRef = useRef(false);

  useEffect(() => {
    stoppedRef.current = false;
    let socket: WebSocket | null = null;
    let reconnectTimer: number | undefined;
    let backoff = INITIAL_BACKOFF_MS;

    const connect = async () => {
      if (stoppedRef.current) return;
      dispatch(userWsConnecting());
      try {
        const url = await userWsUrl();
        if (!url || stoppedRef.current) return;
        socket = new WebSocket(url);
      } catch (err: any) {
        dispatch(userWsError(String(err?.message || err || 'WebSocket construction failed')));
        reconnectTimer = window.setTimeout(() => { void connect(); }, backoff);
        backoff = Math.min(MAX_BACKOFF_MS, Math.round(backoff * 1.7));
        return;
      }

      socket.onopen = () => {
        backoff = INITIAL_BACKOFF_MS;
        dispatch(userWsConnected());
        if (connectedOnceRef.current) {
          // Reconnect: events emitted during the outage were lost (the user WS is
          // fire-and-forget fanout with no per-client replay), so invalidate the
          // RTK Query cache. Only currently-subscribed queries refetch.
          resyncAfterReconnect(dispatch);
          window.dispatchEvent(new CustomEvent('heimdall:user-ws-reconnected'));
        } else {
          connectedOnceRef.current = true;
        }
      };

      socket.onmessage = (event) => {
        let payload: any;
        try {
          payload = JSON.parse(event.data);
        } catch {
          return;
        }
        handleUserWsEvent(dispatch, payload, ctxRef?.current || {});
      };

      socket.onerror = () => {
        dispatch(userWsError('User WebSocket connection error'));
      };

      socket.onclose = () => {
        if (stoppedRef.current) return;
        dispatch(userWsDisconnected());
        reconnectTimer = window.setTimeout(() => { void connect(); }, backoff);
        backoff = Math.min(MAX_BACKOFF_MS, Math.round(backoff * 1.7));
      };
    };

    void connect();

    return () => {
      stoppedRef.current = true;
      if (reconnectTimer) window.clearTimeout(reconnectTimer);
      if (socket) {
        socket.onclose = null;
        socket.onerror = null;
        socket.onmessage = null;
        socket.onopen = null;
        try { socket.close(); } catch { /* ignore */ }
      }
    };
    // Connect once for the shell's lifetime. ctxRef is read at event time, so it
    // does not need to be a dependency.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [dispatch]);

  const status = useSelector((state: any) => state?.chat?.session?.wsStatus || 'idle');
  const connected = useSelector((state: any) => Boolean(state?.chat?.session?.wsConnected));
  return { status, connected };
}
