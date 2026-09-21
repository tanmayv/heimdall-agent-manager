import { useCallback, useEffect, useRef, useState } from 'react';
import { useLazyGetShellPaneQuery } from '../api/endpoints/shells';

export interface UseShellPaneSubscriptionOptions {
  sessionId?: string | null;
  isExpanded?: boolean;
  isActiveTab?: boolean;
  status?: string;
  width?: number;
  lineLimit?: number;
}

export interface UseShellPaneSubscriptionResult {
  output: string;
  hash: string;
  isLoading: boolean;
  isFetching: boolean;
  lastUpdatedAt: number | null;
  polling: boolean;
  refetch: () => void;
}

/** Statuses after which a shell session can never produce new output again. */
export const SHELL_TERMINAL_STATUSES = ['exited', 'killed', 'failed'];

export function isShellTerminalStatus(status?: string): boolean {
  return Boolean(status && SHELL_TERMINAL_STATUSES.includes(status));
}

/**
 * Computes the polling interval for a shell session's pane feed. Mirrors
 * computeAgentPanePollingInterval, with runtime_status replaced by the shell session
 * status vocabulary:
 * - sessionId: null/empty pauses polling (0)
 * - status: a terminal status (exited/killed/failed) pauses polling (0)
 * - isActiveTab: false pauses polling (0)
 * - isDocumentHidden: true pauses polling (0)
 * - isExpanded: true => 500 ms (continuous feed), false => 300000 ms (5m)
 */
export function computeShellPanePollingInterval(options: {
  sessionId?: string | null;
  isExpanded?: boolean;
  isActiveTab?: boolean;
  status?: string;
  isDocumentHidden?: boolean;
}): number {
  const {
    sessionId,
    isExpanded = true,
    isActiveTab = true,
    status,
    isDocumentHidden = false,
  } = options;

  if (!sessionId || isShellTerminalStatus(status) || !isActiveTab || isDocumentHidden) {
    return 0;
  }

  return isExpanded ? 500 : 300000;
}

/**
 * Subscribes to a shell session's terminal pane feed by polled capture with hash
 * diffing — the same model the agent pane uses (useAgentPaneSubscription), deliberately
 * NOT a PTY output stream: no Attach, no per-instance Output flood on the bridge's
 * single-threaded event loop.
 *
 * - 500ms feed while the pane is open, 300s when collapsed
 * - 0 (paused) when the tab is inactive, the document is hidden, or the session has
 *   reached a terminal status
 * - Tracks the last seen hash and sends it as since_hash; an unchanged reply carries no
 *   output and leaves the retained buffer untouched
 * - Cleans up timers and aborts in-flight queries on unmount
 */
export function useShellPaneSubscription({
  sessionId,
  isExpanded = true,
  isActiveTab = true,
  status,
  width = 80,
  lineLimit = 120,
}: UseShellPaneSubscriptionOptions): UseShellPaneSubscriptionResult {
  const [output, setOutput] = useState<string>('');
  const [hash, setHash] = useState<string>('');
  const [lastUpdatedAt, setLastUpdatedAt] = useState<number | null>(null);

  const lastSeenHashRef = useRef<string>('');
  const activeRequestRef = useRef<{ abort?: () => void } | null>(null);
  const prevSessionIdRef = useRef<string | null | undefined>(sessionId);
  const prevExpandedRef = useRef<boolean>(isExpanded);
  const wasActiveRef = useRef<boolean>(false);

  const [trigger, result] = useLazyGetShellPaneQuery();

  const [isDocumentHidden, setIsDocumentHidden] = useState<boolean>(() => {
    if (typeof document !== 'undefined') {
      return document.hidden;
    }
    return false;
  });

  useEffect(() => {
    if (typeof document === 'undefined') return;
    const handleVisibilityChange = () => {
      setIsDocumentHidden(document.hidden);
    };
    document.addEventListener('visibilitychange', handleVisibilityChange);
    return () => {
      document.removeEventListener('visibilitychange', handleVisibilityChange);
    };
  }, []);

  const interval = computeShellPanePollingInterval({
    sessionId,
    isExpanded,
    isActiveTab,
    status,
    isDocumentHidden,
  });

  // Reset state when the session changes.
  useEffect(() => {
    if (prevSessionIdRef.current !== sessionId) {
      prevSessionIdRef.current = sessionId;
      lastSeenHashRef.current = '';
      wasActiveRef.current = false;
      setOutput('');
      setHash('');
      setLastUpdatedAt(null);
    }
  }, [sessionId]);

  const doFetch = useCallback(
    async (customSinceHash?: string) => {
      if (!sessionId || isShellTerminalStatus(status)) {
        return;
      }

      const sinceHashToSend = customSinceHash !== undefined ? customSinceHash : lastSeenHashRef.current;

      try {
        const request = trigger({
          sessionId,
          sinceHash: sinceHashToSend,
          width,
          lineLimit,
        });
        activeRequestRef.current = request;

        const res = await request.unwrap();
        if (res) {
          if (res.hash) {
            lastSeenHashRef.current = res.hash;
            setHash(res.hash);
          }
          // Retain the previous screen when the bridge short-circuits on since_hash.
          if (!res.unchanged && res.output !== undefined) {
            setOutput(res.output);
          }
          setLastUpdatedAt(Date.now());
        }
      } catch (err: any) {
        if (err?.name === 'AbortError') {
          return;
        }
        // Polling errors do not overwrite the cached screen.
      } finally {
        activeRequestRef.current = null;
      }
    },
    [sessionId, status, width, lineLimit, trigger]
  );

  const doFetchRef = useRef(doFetch);
  useEffect(() => {
    doFetchRef.current = doFetch;
  });

  // Immediate fetch when becoming active, so the prompt appears without typing.
  useEffect(() => {
    const isActive = Boolean(
      sessionId && !isShellTerminalStatus(status) && isActiveTab && !isDocumentHidden
    );

    if (isActive && !wasActiveRef.current) {
      doFetchRef.current();
    }
    wasActiveRef.current = isActive;
  }, [sessionId, status, isActiveTab, isDocumentHidden]);

  // Immediate refetch when the pane expands.
  useEffect(() => {
    const prevExpanded = prevExpandedRef.current;
    prevExpandedRef.current = isExpanded;

    if (!prevExpanded && isExpanded) {
      if (sessionId && !isShellTerminalStatus(status) && isActiveTab && !isDocumentHidden) {
        doFetchRef.current();
      }
    }
  }, [isExpanded, sessionId, status, isActiveTab, isDocumentHidden]);

  useEffect(() => {
    if (interval <= 0 || !sessionId) {
      return;
    }

    const timerId = setInterval(() => {
      doFetchRef.current();
    }, interval);

    return () => {
      clearInterval(timerId);
    };
  }, [interval, sessionId]);

  useEffect(() => {
    return () => {
      if (activeRequestRef.current?.abort) {
        activeRequestRef.current.abort();
      }
    };
  }, []);

  const refetch = useCallback(() => {
    doFetchRef.current();
  }, []);

  const currentOutput = output || result.data?.output || '';
  const currentHash = hash || result.data?.hash || '';
  const isLoading =
    result.isLoading ||
    (Boolean(sessionId) && interval > 0 && lastUpdatedAt === null && result.isFetching);

  return {
    output: currentOutput,
    hash: currentHash,
    isLoading,
    isFetching: result.isFetching,
    lastUpdatedAt,
    polling: interval > 0,
    refetch,
  };
}
