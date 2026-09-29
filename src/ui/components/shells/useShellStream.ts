import { useCallback, useEffect, useRef, useState } from 'react';
import { apiAbsoluteUrl } from '../../api/apiBase';
import { shellResizeFrame } from './shellStreamFrames';

const HEARTBEAT_INTERVAL_MS = 30000;
const INITIAL_RECONNECT_DELAY_MS = 1000;
const MAX_RECONNECT_DELAY_MS = 5000;
const MAX_RECONNECT_ATTEMPTS = 3;

type ShellStreamMsg =
  | { type: 'output'; data_b64: string }
  | { type: 'screen'; screen_b64?: string; data_b64?: string }
  | { type: 'ready'; session_id?: string }
  | { type: 'status'; status: string }
  | { type: 'error'; message: string };

export type UseShellStreamOptions = {
  sessionId: string | null;
  enabled?: boolean;
  onOutput?: (data: Uint8Array) => void;
  onStatus?: (status: string) => void;
  onError?: (message: string) => void;
  onClose?: () => void;
  /**
   * REQ-SHELL-18 — the pane's CURRENT geometry, read at the moment the socket opens.
   *
   * `sendResize` below can only send on an OPEN socket; before that it drops the frame and
   * returns. The consumer computes its geometry when it mounts and fits, which is BEFORE the
   * socket is open (`connect()` awaits `shellStreamUrl()`, then constructs the WebSocket, then
   * waits for the handshake), so that first frame is exactly the one that gets dropped — and
   * nothing used to re-send it. The PTY then stayed at its 80x24 default for the whole session,
   * and only a later window resize, which happens to arrive on an open socket, corrected it.
   *
   * A pull, not a push: the geometry is read INSIDE `onopen`, so it cannot be stale, and it is
   * read again on every reconnect — after a backoff reconnect the new PTY needs telling too.
   */
  getGeometry?: () => { rows: number; cols: number } | null;
};

export interface UseShellStreamResult {
  connected: boolean;
  sendInput: (data: string) => void;
  sendResize: (rows: number, cols: number) => void;
  reconnect: () => void;
}

function hasElectronDeviceAuth(): boolean {
  return typeof window !== 'undefined' && Boolean((window as any).odinApi?.deviceAuth);
}

async function electronApiBaseUrl(): Promise<string> {
  try {
    const cfg = await (window as any).odinApi?.deviceAuth?.getConfig?.();
    return String(cfg?.apiBaseUrl || (window as any).odinApi?.hubApiBaseUrl || '').replace(/\/$/, '');
  } catch {
    return String((window as any).odinApi?.hubApiBaseUrl || '').replace(/\/$/, '');
  }
}

function httpToWsUrl(base: string, path: string): string {
  const origin = base || (typeof window !== 'undefined' ? window.location.origin : 'http://127.0.0.1:5173');
  const parsed = new URL(origin);
  parsed.protocol = parsed.protocol === 'https:' ? 'wss:' : 'ws:';
  parsed.pathname = path;
  parsed.search = '';
  parsed.hash = '';
  return parsed.toString();
}

function httpUrlToWs(httpUrl: string): string {
  const url = new URL(httpUrl);
  url.protocol = url.protocol === 'https:' ? 'wss:' : 'ws:';
  return url.toString();
}

/**
 * Resolves the WebSocket stream URL directly using browser cookie session authentication,
 * eliminating the mandatory HTTP pre-flight ticket request per user directive.
 * Outside Electron, resolves via apiAbsoluteUrl to preserve preview tunnel prefixes.
 */
async function shellStreamUrl(sessionId: string): Promise<string> {
  const path = `/api/v1/shells/${encodeURIComponent(sessionId)}/stream`;
  if (hasElectronDeviceAuth()) {
    const base = await electronApiBaseUrl();
    return httpToWsUrl(base, path);
  }
  return httpUrlToWs(apiAbsoluteUrl(path));
}

export function useShellStream({
  sessionId,
  enabled = true,
  onOutput,
  onStatus,
  onError,
  onClose,
  getGeometry,
}: UseShellStreamOptions): UseShellStreamResult {
  const [connected, setConnected] = useState(false);
  const socketRef = useRef<WebSocket | null>(null);
  const heartbeatRef = useRef<number | undefined>(undefined);
  const reconnectTimerRef = useRef<number | undefined>(undefined);
  const reconnectAttemptsRef = useRef(0);
  const stoppedRef = useRef(false);
  const activeConnectIdRef = useRef(0);

  const onOutputRef = useRef(onOutput);
  const onStatusRef = useRef(onStatus);
  const onErrorRef = useRef(onError);
  const onCloseRef = useRef(onClose);
  const getGeometryRef = useRef(getGeometry);

  useEffect(() => { onOutputRef.current = onOutput; }, [onOutput]);
  useEffect(() => { onStatusRef.current = onStatus; }, [onStatus]);
  useEffect(() => { onErrorRef.current = onError; }, [onError]);
  useEffect(() => { onCloseRef.current = onClose; }, [onClose]);
  useEffect(() => { getGeometryRef.current = getGeometry; }, [getGeometry]);

  const clearHeartbeat = () => {
    if (heartbeatRef.current) window.clearInterval(heartbeatRef.current);
    heartbeatRef.current = undefined;
  };

  const clearReconnectTimer = () => {
    if (reconnectTimerRef.current) window.clearTimeout(reconnectTimerRef.current);
    reconnectTimerRef.current = undefined;
  };

  // REQ-SHELL-6 §6 — JUSTIFIED EXCEPTION 1 of 2 to the no-polling rule, and the one
  // that requirement explicitly told us to check for rather than pattern-match on
  // `setInterval`. This is a WEBSOCKET KEEPALIVE, not a poller: it sends a heartbeat
  // frame on an ALREADY-OPEN socket and closes it if the send fails. It fetches
  // nothing, invalidates no cache tag, and produces no UI update — deleting it would
  // not remove a poll, it would let idle sockets be reaped by the first intermediary
  // with a read timeout. KEEP.
  const startHeartbeat = (socket: WebSocket) => {
    clearHeartbeat();
    heartbeatRef.current = window.setInterval(() => {
      if (socket.readyState === WebSocket.OPEN) {
        try {
          socket.send(JSON.stringify({ type: 'heartbeat' }));
        } catch {
          try { socket.close(); } catch { /* ignore */ }
        }
      }
    }, HEARTBEAT_INTERVAL_MS);
  };

  /**
   * REQ-SHELL-18 — tell the PTY its size the instant the socket is usable.
   *
   * Sent directly on `socket`, not through `sendResize`, and from inside `onopen` rather than
   * from an effect reacting to `connected`: `socketRef.current` and the `connected` state are
   * both a React round-trip behind this moment, and a backoff reconnect can leave `connected`
   * true throughout, so an effect keyed on it would not fire at all for the reconnect case.
   */
  const sendGeometry = (socket: WebSocket) => {
    const frame = shellResizeFrame(getGeometryRef.current?.());
    if (!frame) return;
    if (socket.readyState !== WebSocket.OPEN) return;
    try {
      socket.send(frame);
    } catch { /* a socket that fails here will surface through onclose */ }
  };

  const closeSocket = () => {
    activeConnectIdRef.current += 1;
    clearHeartbeat();
    clearReconnectTimer();
    if (socketRef.current) {
      socketRef.current.onclose = null;
      socketRef.current.onerror = null;
      socketRef.current.onmessage = null;
      socketRef.current.onopen = null;
      try { socketRef.current.close(); } catch { /* ignore */ }
      socketRef.current = null;
    }
    setConnected(false);
  };

  const connect = useCallback(() => {
    if (!sessionId || !enabled || stoppedRef.current) return;
    closeSocket();

    const connectId = ++activeConnectIdRef.current;
    let socket: WebSocket;

    shellStreamUrl(sessionId)
      .then((url) => {
        if (activeConnectIdRef.current !== connectId || stoppedRef.current || !enabled) return;
        socket = new WebSocket(url);
        socketRef.current = socket;

        socket.onopen = () => {
          if (activeConnectIdRef.current !== connectId) {
            try { socket.close(); } catch { /* ignore */ }
            return;
          }
          reconnectAttemptsRef.current = 0;
          setConnected(true);
          startHeartbeat(socket);
          sendGeometry(socket);
        };

        socket.onmessage = (event) => {
          if (activeConnectIdRef.current !== connectId) return;
          let msg: ShellStreamMsg;
          try {
            msg = JSON.parse(event.data);
          } catch {
            return;
          }

          if (msg.type === 'output' && msg.data_b64) {
            try {
              const raw = atob(msg.data_b64);
              const bytes = new Uint8Array(raw.length);
              for (let i = 0; i < raw.length; i++) bytes[i] = raw.charCodeAt(i);
              onOutputRef.current?.(bytes);
            } catch { /* ignore decode errors */ }
          } else if (msg.type === 'screen') {
            const b64 = msg.screen_b64 || msg.data_b64;
            if (b64) {
              try {
                const raw = atob(b64);
                const bytes = new Uint8Array(raw.length);
                for (let i = 0; i < raw.length; i++) bytes[i] = raw.charCodeAt(i);
                onOutputRef.current?.(bytes);
              } catch { /* ignore decode errors */ }
            }
          } else if (msg.type === 'status') {
            onStatusRef.current?.(msg.status);
          } else if (msg.type === 'error') {
            onErrorRef.current?.(msg.message);
          }
        };

        socket.onclose = () => {
          if (activeConnectIdRef.current !== connectId) return;
          clearHeartbeat();
          setConnected(false);

          // Auto-reconnect with exponential backoff if not explicitly stopped
          if (!stoppedRef.current && enabled && reconnectAttemptsRef.current < MAX_RECONNECT_ATTEMPTS) {
            const delay = Math.min(
              INITIAL_RECONNECT_DELAY_MS * Math.pow(2, reconnectAttemptsRef.current),
              MAX_RECONNECT_DELAY_MS
            );
            reconnectAttemptsRef.current += 1;
            reconnectTimerRef.current = window.setTimeout(() => {
              if (!stoppedRef.current && enabled) {
                connect();
              }
            }, delay);
          } else {
            onCloseRef.current?.();
          }
        };

        socket.onerror = () => {
          if (activeConnectIdRef.current !== connectId) return;
          if (reconnectAttemptsRef.current >= MAX_RECONNECT_ATTEMPTS) {
            onErrorRef.current?.('Shell stream connection error');
          }
        };
      })
      .catch((err) => {
        if (activeConnectIdRef.current !== connectId) return;
        onErrorRef.current?.(String(err?.message || err || 'Failed to connect to shell stream'));
      });
  }, [sessionId, enabled]);

  useEffect(() => {
    stoppedRef.current = false;
    reconnectAttemptsRef.current = 0;
    if (enabled && sessionId) {
      connect();
    } else {
      closeSocket();
    }

    return () => {
      stoppedRef.current = true;
      closeSocket();
    };
  }, [sessionId, enabled, connect]);

  const sendInput = useCallback((data: string) => {
    const s = socketRef.current;
    if (!s || s.readyState !== WebSocket.OPEN) return;
    s.send(JSON.stringify({ type: 'input', data_b64: btoa(data) }));
  }, []);

  const sendResize = useCallback((rows: number, cols: number) => {
    const s = socketRef.current;
    if (!s || s.readyState !== WebSocket.OPEN) return;
    s.send(JSON.stringify({ type: 'resize', rows, cols }));
  }, []);

  const reconnect = useCallback(() => {
    reconnectAttemptsRef.current = 0;
    connect();
  }, [connect]);

  return { connected, sendInput, sendResize, reconnect };
}
