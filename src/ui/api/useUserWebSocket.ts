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
// Auth model: `/api/v1/user-ws` is served behind the trusted-proxy auth that the
// rest of `/api/v1` uses. Browsers send cookies automatically on the WebSocket
// handshake, so this uses the SAME credential session as `fetch(..., {credentials:'include'})`
// — no client token in the URL (unlike the legacy token-bearing user-ws path).

const INITIAL_BACKOFF_MS = 1500;
const MAX_BACKOFF_MS = 30000;

function userWsUrl(): string {
  if (typeof window === 'undefined') return '';
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

    const connect = () => {
      if (stoppedRef.current) return;
      const url = userWsUrl();
      if (!url) return;
      dispatch(userWsConnecting());
      try {
        socket = new WebSocket(url);
      } catch (err: any) {
        dispatch(userWsError(String(err?.message || err || 'WebSocket construction failed')));
        reconnectTimer = window.setTimeout(connect, backoff);
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
        reconnectTimer = window.setTimeout(connect, backoff);
        backoff = Math.min(MAX_BACKOFF_MS, Math.round(backoff * 1.7));
      };
    };

    connect();

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
