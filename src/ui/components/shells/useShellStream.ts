import { useCallback, useEffect, useRef, useState } from 'react';

const HEARTBEAT_INTERVAL_MS = 30000;

type ShellStreamMsg =
  | { type: 'output'; data_b64: string }
  | { type: 'status'; status: string }
  | { type: 'error'; message: string };

type UseShellStreamOptions = {
  sessionId: string | null;
  onOutput?: (data: Uint8Array) => void;
  onStatus?: (status: string) => void;
  onError?: (message: string) => void;
};

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
  const parsed = new URL(base || window.location.origin);
  parsed.protocol = parsed.protocol === 'https:' ? 'wss:' : 'ws:';
  parsed.pathname = path;
  parsed.search = '';
  parsed.hash = '';
  return parsed.toString();
}

async function shellStreamUrl(sessionId: string): Promise<string> {
  const path = `/api/v1/shells/${encodeURIComponent(sessionId)}/stream`;
  if (hasElectronDeviceAuth()) {
    const res = await fetch('/api/v1/me/ws-ticket', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
    });
    const text = await res.text();
    let body: any = {};
    try { body = JSON.parse(text); } catch { body = {}; }
    const data = body?.data !== undefined ? body.data : body;
    if (!res.ok) throw new Error(String(data?.error?.message || data?.message || `WS ticket failed (${res.status})`));
    const ticket = String(data?.ticket || '');
    if (!ticket) throw new Error('WS ticket missing ticket field');
    const base = await electronApiBaseUrl();
    const url = new URL(httpToWsUrl(base, path));
    url.searchParams.set('ticket', ticket);
    return url.toString();
  }
  const scheme = window.location.protocol === 'https:' ? 'wss:' : 'ws:';
  return `${scheme}//${window.location.host}${path}`;
}

export function useShellStream({ sessionId, onOutput, onStatus, onError }: UseShellStreamOptions) {
  const [connected, setConnected] = useState(false);
  const socketRef = useRef<WebSocket | null>(null);
  const heartbeatRef = useRef<number | undefined>(undefined);
  const stoppedRef = useRef(false);
  const onOutputRef = useRef(onOutput);
  const onStatusRef = useRef(onStatus);
  const onErrorRef = useRef(onError);

  useEffect(() => { onOutputRef.current = onOutput; }, [onOutput]);
  useEffect(() => { onStatusRef.current = onStatus; }, [onStatus]);
  useEffect(() => { onErrorRef.current = onError; }, [onError]);

  useEffect(() => {
    if (!sessionId) return;
    stoppedRef.current = false;

    const clearHeartbeat = () => {
      if (heartbeatRef.current) window.clearInterval(heartbeatRef.current);
      heartbeatRef.current = undefined;
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

    let socket: WebSocket;

    shellStreamUrl(sessionId)
      .then((url) => {
        if (stoppedRef.current) return;
        socket = new WebSocket(url);
        socketRef.current = socket;

        socket.onopen = () => {
          setConnected(true);
          startHeartbeat(socket);
        };

        socket.onmessage = (event) => {
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
          } else if (msg.type === 'status') {
            onStatusRef.current?.((msg as any).status);
          } else if (msg.type === 'error') {
            onErrorRef.current?.((msg as any).message);
          }
        };

        socket.onclose = () => {
          clearHeartbeat();
          setConnected(false);
        };

        socket.onerror = () => {
          onErrorRef.current?.('Shell stream connection error');
        };
      })
      .catch((err) => {
        onErrorRef.current?.(String(err?.message || err || 'Failed to connect to shell stream'));
      });

    return () => {
      stoppedRef.current = true;
      clearHeartbeat();
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
  }, [sessionId]);

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

  return { connected, sendInput, sendResize };
}
