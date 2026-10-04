import { useCallback, useEffect, useRef, useState } from 'react';
import { useSelector } from 'react-redux';
import { apiAbsoluteUrl } from '../../api/apiBase';
import { decryptShellStreamPayload, encryptShellStreamPayload } from '../shells/useShellStream';
import { VAULT_ARMOR_PREFIX, bytesToBase64, getActiveVaultKey } from '../../utils/vaultContent';
import { readSessionVaultKey } from '../../store/vaultSlice';

const HEARTBEAT_INTERVAL_MS = 30000;
const INITIAL_RECONNECT_DELAY_MS = 1000;
const MAX_RECONNECT_DELAY_MS = 5000;
const MAX_RECONNECT_ATTEMPTS = 3;

function toBase64(str: string): string {
  try {
    return btoa(str);
  } catch {
    return bytesToBase64(new TextEncoder().encode(str));
  }
}

type AgentStreamMsg =
  | { type: 'output'; data_b64?: string; enc_b64?: string }
  | { type: 'screen'; screen_b64?: string; data_b64?: string; enc_b64?: string }
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
  rawVaultKeyHex?: string | null;
  isVaultUnlocked?: boolean;
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
  rawVaultKeyHex: propRawVaultKeyHex,
  isVaultUnlocked: propIsVaultUnlocked,
}: UseAgentStreamOptions): UseAgentStreamResult {
  const [connected, setConnected] = useState(false);
  const socketRef = useRef<WebSocket | null>(null);
  const heartbeatRef = useRef<number | undefined>(undefined);
  const reconnectTimerRef = useRef<number | undefined>(undefined);
  const microNudgeTimerRef = useRef<number | undefined>(undefined);
  const reconnectAttemptsRef = useRef(0);
  const stoppedRef = useRef(false);
  const activeConnectIdRef = useRef(0);

  // Vault state subscription
  let reduxUnlocked = false;
  let reduxKeyHex: string | null = null;
  try {
    reduxUnlocked = useSelector((state: any) => Boolean(state?.vault?.isUnlocked || state?.vault?.unlocked));
    reduxKeyHex = useSelector((state: any) => state?.vault?.rawVaultKeyHex ?? null);
  } catch {
    // Non-fatal when rendered outside Redux Provider (e.g. standalone test)
  }

  const sessionKey = readSessionVaultKey();
  const activeKey = getActiveVaultKey();
  const isVaultUnlocked = propIsVaultUnlocked !== undefined
    ? propIsVaultUnlocked
    : (reduxUnlocked || Boolean(reduxKeyHex) || Boolean(sessionKey) || Boolean(activeKey));
  const rawVaultKeyHex = propRawVaultKeyHex !== undefined
    ? propRawVaultKeyHex
    : (reduxKeyHex || sessionKey);

  const isVaultUnlockedRef = useRef(isVaultUnlocked);
  isVaultUnlockedRef.current = isVaultUnlocked;
  const rawVaultKeyHexRef = useRef(rawVaultKeyHex);
  rawVaultKeyHexRef.current = rawVaultKeyHex;
  const outputQueueRef = useRef<Promise<void>>(Promise.resolve());
  const inputQueueRef = useRef<Promise<void>>(Promise.resolve());

  useEffect(() => {
    isVaultUnlockedRef.current = isVaultUnlocked;
  }, [isVaultUnlocked]);

  useEffect(() => {
    rawVaultKeyHexRef.current = rawVaultKeyHex;
  }, [rawVaultKeyHex]);

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
            // REQ-SHELL-29: announce the REAL geometry FIRST, before the nudge.
            // The hub captures the late-join screen snapshot from the FIRST resize frame
            // it sees (agent_instance_handlers.odin), and the nudge below deliberately
            // sends a wrong width. Without this line that wrong width is what the capture
            // wraps at, so a full-width line breaks one column early and every line after
            // it shifts — and a shell sitting at a prompt never repaints to correct it.
            // The shells hook already announces honest geometry on open
            // (useShellStream.ts:202); this makes the agent pane consistent with it.
            // ORDER IS LOAD-BEARING: keep this call above the cols - 1 nudge.
            sendResize(targetRows, targetCols);
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

          if (msg.type === 'output') {
            const rawPayload = msg.data_b64 || msg.enc_b64;
            const isArmored = typeof rawPayload === 'string' && rawPayload.startsWith(VAULT_ARMOR_PREFIX);
            const enc_b64 = isArmored ? rawPayload : msg.enc_b64;
            const data_b64 = !isArmored ? msg.data_b64 : undefined;

            // If unarmored plaintext base64 arrives, decode immediately via atob() with zero delay.
            if (!isArmored && data_b64) {
              try {
                const raw = atob(data_b64);
                const bytes = new Uint8Array(raw.length);
                for (let i = 0; i < raw.length; i++) bytes[i] = raw.charCodeAt(i);
                onOutputRef.current?.(bytes);
              } catch { /* ignore decode errors */ }
              return;
            }

            if (enc_b64) {
              outputQueueRef.current = outputQueueRef.current.then(async () => {
                if (activeConnectIdRef.current !== connectId) return;
                const activeVaultKey = getActiveVaultKey();
                const isUnlocked = isVaultUnlockedRef.current || Boolean(readSessionVaultKey()) || Boolean(activeVaultKey);
                const keyToUse = activeVaultKey || rawVaultKeyHexRef.current || readSessionVaultKey();
                if (isUnlocked && keyToUse) {
                  try {
                    const bytes = await decryptShellStreamPayload(enc_b64, keyToUse);
                    onOutputRef.current?.(bytes);
                  } catch { /* ignore decryption errors */ }
                }
              }).catch(() => { /* ignore queue errors */ });
            }
          } else if (msg.type === 'screen') {
            const rawPayload = msg.data_b64 || msg.screen_b64 || msg.enc_b64;
            const isArmored = typeof rawPayload === 'string' && rawPayload.startsWith(VAULT_ARMOR_PREFIX);
            const enc_b64 = isArmored ? rawPayload : msg.enc_b64;
            const b64 = !isArmored ? (msg.screen_b64 || msg.data_b64) : undefined;

            // If unarmored plaintext base64 arrives, decode immediately via atob() with zero delay.
            if (!isArmored && b64) {
              try {
                const raw = atob(b64);
                const bytes = new Uint8Array(raw.length);
                for (let i = 0; i < raw.length; i++) bytes[i] = raw.charCodeAt(i);
                onOutputRef.current?.(bytes);
              } catch { /* ignore decode errors */ }
              return;
            }

            if (enc_b64) {
              outputQueueRef.current = outputQueueRef.current.then(async () => {
                if (activeConnectIdRef.current !== connectId) return;
                const activeVaultKey = getActiveVaultKey();
                const isUnlocked = isVaultUnlockedRef.current || Boolean(readSessionVaultKey()) || Boolean(activeVaultKey);
                const keyToUse = activeVaultKey || rawVaultKeyHexRef.current || readSessionVaultKey();
                if (isUnlocked && keyToUse) {
                  try {
                    const bytes = await decryptShellStreamPayload(enc_b64, keyToUse);
                    onOutputRef.current?.(bytes);
                  } catch { /* ignore decryption errors */ }
                }
              }).catch(() => { /* ignore queue errors */ });
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

    const activeVaultKey = getActiveVaultKey();
    const isUnlocked = isVaultUnlockedRef.current || Boolean(readSessionVaultKey()) || Boolean(activeVaultKey);
    const keyToUse = activeVaultKey || rawVaultKeyHexRef.current || readSessionVaultKey();

    if (isUnlocked && keyToUse) {
      inputQueueRef.current = inputQueueRef.current.then(async () => {
        if (s.readyState !== WebSocket.OPEN) return;
        try {
          const enc_b64 = await encryptShellStreamPayload(data, keyToUse);
          if (s.readyState === WebSocket.OPEN) {
            s.send(JSON.stringify({ type: 'input', enc_b64, data_b64: `${VAULT_ARMOR_PREFIX}${enc_b64}` }));
          }
        } catch {
          if (s.readyState === WebSocket.OPEN) {
            s.send(JSON.stringify({ type: 'input', data_b64: toBase64(data) }));
          }
        }
      }).catch(() => { /* ignore queue error */ });
    } else {
      s.send(JSON.stringify({ type: 'input', data_b64: toBase64(data) }));
    }
  }, []);

  const reconnect = useCallback(() => {
    reconnectAttemptsRef.current = 0;
    connect();
  }, [connect]);

  return { connected, sendInput, sendResize, reconnect };
}
