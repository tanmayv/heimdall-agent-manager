import { useCallback, useEffect, useRef, useState } from 'react';
import { apiAbsoluteUrl } from '../../api/apiBase';

const HEARTBEAT_INTERVAL_MS = 30000;
const INITIAL_RECONNECT_DELAY_MS = 1000;
const MAX_RECONNECT_DELAY_MS = 5000;
const MAX_RECONNECT_ATTEMPTS = 3;

type AgentStreamMsg =
  | { type: 'output'; data_b64: string }
  | { type: 'screen'; screen_b64?: string; data_b64?: string }
  | { type: 'ready'; agent_instance_id?: string; session_id?: string }
  | { type: 'status'; status: string }
  | { type: 'error'; message: string };

export type UseAgentStreamOptions = {
  agentInstanceId: string | null | undefined;
  enabled?: boolean;
  rows?: number;
  cols?: number;
  onConnect?: () => void;
  onReset?: () => void;
  onOutput?: (data: Uint8Array) => void;
  onStatus?: (status: string) => void;
  onError?: (message: string) => void;
  onClose?: () => void;
};

export interface UseAgentStreamResult {
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
async function agentStreamUrl(agentInstanceId: string): Promise<string> {
  const path = `/api/v1/agent-instances/${encodeURIComponent(agentInstanceId)}/stream`;
  if (hasElectronDeviceAuth()) {
    const base = await electronApiBaseUrl();
    return httpToWsUrl(base, path);
  }
  return httpUrlToWs(apiAbsoluteUrl(path));
}

export function useAgentStream({
  agentInstanceId,
  enabled = true,
  rows,
  cols,
  onConnect,
  onReset,
  onOutput,
  onStatus,
  onError,
  onClose,
}: UseAgentStreamOptions): UseAgentStreamResult {
  const [connected, setConnected] = useState(false);
  const socketRef = useRef<WebSocket | null>(null);
  const heartbeatRef = useRef<number | undefined>(undefined);
  const reconnectTimerRef = useRef<number | undefined>(undefined);
  const microNudgeTimerRef = useRef<number | undefined>(undefined);
  const reconnectAttemptsRef = useRef(0);
  const stoppedRef = useRef(false);
  const activeConnectIdRef = useRef(0);

  const rowsRef = useRef(rows);
  const colsRef = useRef(cols);
  const onConnectRef = useRef(onConnect);
  const onResetRef = useRef(onReset);
  const onOutputRef = useRef(onOutput);
  const onStatusRef = useRef(onStatus);
  const onErrorRef = useRef(onError);
  const onCloseRef = useRef(onClose);

  useEffect(() => { rowsRef.current = rows; }, [rows]);
  useEffect(() => { colsRef.current = cols; }, [cols]);
  useEffect(() => { onConnectRef.current = onConnect; }, [onConnect]);
  useEffect(() => { onResetRef.current = onReset; }, [onReset]);
  useEffect(() => { onOutputRef.current = onOutput; }, [onOutput]);
  useEffect(() => { onStatusRef.current = onStatus; }, [onStatus]);
  useEffect(() => { onErrorRef.current = onError; }, [onError]);
  useEffect(() => { onCloseRef.current = onClose; }, [onClose]);

  const clearHeartbeat = () => {
    if (heartbeatRef.current) window.clearInterval(heartbeatRef.current);
    heartbeatRef.current = undefined;
  };

  const clearReconnectTimer = () => {
    if (reconnectTimerRef.current) window.clearTimeout(reconnectTimerRef.current);
    reconnectTimerRef.current = undefined;
  };

  const clearMicroNudgeTimer = () => {
    if (microNudgeTimerRef.current) window.clearTimeout(microNudgeTimerRef.current);
    microNudgeTimerRef.current = undefined;
  };

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

  const closeSocket = () => {
    activeConnectIdRef.current += 1;
    clearHeartbeat();
    clearReconnectTimer();
    clearMicroNudgeTimer();
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

  const sendResize = useCallback((rows: number, cols: number) => {
    const s = socketRef.current;
    if (!s || s.readyState !== WebSocket.OPEN) return;
    s.send(JSON.stringify({ type: 'resize', rows, cols }));
  }, []);

  const connect = useCallback(() => {
    if (!agentInstanceId || !enabled || stoppedRef.current) return;
    closeSocket();

    const connectId = ++activeConnectIdRef.current;
    let socket: WebSocket;

    agentStreamUrl(agentInstanceId)
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

          // Purge stale terminal buffer on stream open / reconnect (REQ-STREAM-REDRAW-1)
          onConnectRef.current?.();
          onResetRef.current?.();

          // SIGWINCH micro-nudge for instant full-screen native repaint (REQ-STREAM-REDRAW-2)
          // Matches tools/pty_host/src/dclient.rs:392-414: resize to cols - 1 then restore after 25ms
          const targetRows = rowsRef.current ?? 24;
          const targetCols = colsRef.current ?? 80;
          if (targetCols > 1) {
            sendResize(targetRows, targetCols - 1);
            clearMicroNudgeTimer();
            microNudgeTimerRef.current = window.setTimeout(() => {
              if (activeConnectIdRef.current === connectId && socket.readyState === WebSocket.OPEN) {
                sendResize(targetRows, targetCols);
              }
            }, 25);
          }
        };

        socket.onmessage = (event) => {
          if (activeConnectIdRef.current !== connectId) return;
          let msg: AgentStreamMsg;
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
          clearMicroNudgeTimer();
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
            onErrorRef.current?.('Agent instance stream connection error');
          }
        };
      })
      .catch((err) => {
        if (activeConnectIdRef.current !== connectId) return;
        onErrorRef.current?.(String(err?.message || err || 'Failed to connect to agent instance stream'));
      });
  }, [agentInstanceId, enabled, sendResize]);

  useEffect(() => {
    stoppedRef.current = false;
    reconnectAttemptsRef.current = 0;
    if (enabled && agentInstanceId) {
      connect();
    } else {
      closeSocket();
    }

    return () => {
      stoppedRef.current = true;
      closeSocket();
    };
  }, [agentInstanceId, enabled, connect]);

  const sendInput = useCallback((data: string) => {
    const s = socketRef.current;
    if (!s || s.readyState !== WebSocket.OPEN) return;
    s.send(JSON.stringify({ type: 'input', data_b64: btoa(data) }));
  }, []);

  const reconnect = useCallback(() => {
    reconnectAttemptsRef.current = 0;
    connect();
  }, [connect]);

  return { connected, sendInput, sendResize, reconnect };
}
