import { useCallback, useEffect, useRef, useState } from 'react';
import type { Terminal as TerminalType } from '@xterm/xterm';
import type { FitAddon as FitAddonType } from '@xterm/addon-fit';
import * as xtermModule from '@xterm/xterm';
import * as fitAddonModule from '@xterm/addon-fit';

const xtermObj = xtermModule as Record<string, any>;
const Terminal = (xtermObj.Terminal || xtermObj['default']?.Terminal || xtermObj['default']) as typeof TerminalType;
const fitAddonObj = fitAddonModule as Record<string, any>;
const FitAddon = (fitAddonObj.FitAddon || fitAddonObj['default']?.FitAddon || fitAddonObj['default']) as typeof FitAddonType;

import Icon from '../Icon';
import { useTheme } from '../../store/themeSlice';
import { useShellPaneSubscription } from '../../hooks/useShellPaneSubscription';
import { useFetchExperimentsQuery } from '../../api/endpoints/settings';
import { useShellStream } from './useShellStream';
import {
  useSendShellInputMutation,
  useSendShellResizeMutation,
} from '../../api/endpoints/shells';
import type { ShellSession } from '../../api/endpoints/shells';

interface ShellTerminalPaneProps {
  session: ShellSession;
  isBridgeUnreachable?: boolean;
  onClose?: () => void;
}

export function ShellTerminalPane({
  session,
  isBridgeUnreachable: propIsBridgeUnreachable,
}: ShellTerminalPaneProps) {
  const { theme } = useTheme();
  const terminalContainerRef = useRef<HTMLDivElement | null>(null);
  const terminalRef = useRef<TerminalType | null>(null);
  const fitAddonRef = useRef<FitAddonType | null>(null);

  const isTerminal = session.kind === 'interactive' || session.kind === 'agent';
  const isRunning = session.status === 'running' || session.status === 'starting';
  const paneSessionId = isTerminal && isRunning ? session.session_id : null;

  // --------------------------------------------------------------------------
  // Experimental Flag & Dual-Mode Configuration (REQ-STREAM-IMPL-3)
  // --------------------------------------------------------------------------
  const { data: expData } = useFetchExperimentsQuery();
  const isStreamingExperimentEnabled = Boolean(
    expData?.flags?.find((f) => f.key === 'streaming_terminal_pane')?.enabled
  );

  const [fallbackToPolling, setFallbackToPolling] = useState(false);

  // --------------------------------------------------------------------------
  // STREAMING PATH: Low-latency WebSocket streaming without term.reset()
  // --------------------------------------------------------------------------
  const {
    connected: streamConnected,
    sendInput: sendStreamInput,
    sendResize: sendStreamResize,
    reconnect: reconnectStream,
  } = useShellStream({
    sessionId: paneSessionId,
    enabled: isStreamingExperimentEnabled && !fallbackToPolling,
    onOutput: (bytes) => {
      const term = terminalRef.current;
      if (!term) return;
      term.write(bytes);
      if (!userScrolledUpRef.current) {
        term.scrollToBottom();
      }
    },
    onError: () => {
      // Graceful fallback: If WebSocket encounters error, fall back to polling
      if (isStreamingExperimentEnabled) {
        setFallbackToPolling(true);
      }
    },
    onClose: () => {
      // Graceful fallback: If WebSocket disconnects, fall back to polling
      if (isStreamingExperimentEnabled) {
        setFallbackToPolling(true);
      }
    },
  });

  const isStreamingActive = isStreamingExperimentEnabled && streamConnected && !fallbackToPolling;

  // --------------------------------------------------------------------------
  // LEGACY POLLING PATH: 500ms polled capture with SHA-256 diff & term.reset()
  // Cleanly isolated so that removing legacy polling in the future only requires
  // deleting this block and the legacy branches in handleInput / handleResize.
  // --------------------------------------------------------------------------
  const {
    output,
    isLoading,
    isBridgeUnreachable: subIsBridgeUnreachable,
    refetch,
  } = useShellPaneSubscription({
    sessionId: (!isStreamingExperimentEnabled || fallbackToPolling) ? paneSessionId : null,
    status: session.status,
  });

  const isBridgeUnreachable = Boolean(propIsBridgeUnreachable || subIsBridgeUnreachable);

  const [sendShellInput] = useSendShellInputMutation();
  const [sendShellResize] = useSendShellResizeMutation();

  const sessionIdRef = useRef<string | null>(paneSessionId);
  useEffect(() => {
    sessionIdRef.current = paneSessionId;
  }, [paneSessionId]);

  const refetchRef = useRef(refetch);
  useEffect(() => {
    refetchRef.current = refetch;
  }, [refetch]);

  const keystrokeDebounceTimerRef = useRef<ReturnType<typeof setTimeout> | undefined>(undefined);
  const lastWrittenOutputRef = useRef<string>('');
  const userScrolledUpRef = useRef(false);

  // Unified retry handler that triggers both streaming reconnect and polling refetch
  const handleRetry = useCallback(() => {
    setFallbackToPolling(false);
    reconnectStream();
    refetch();
  }, [reconnectStream, refetch]);

  // Unified input handler cleanly routing between streaming and legacy polling
  const handleInput = useCallback(
    (data: string) => {
      if (isStreamingActive) {
        // STREAMING: Send keystrokes directly over WebSocket without debounce
        sendStreamInput(data);
      } else {
        // LEGACY POLLING: HTTP POST with 50ms debounced capture refetch
        const targetId = sessionIdRef.current;
        if (targetId) {
          sendShellInput({ sessionId: targetId, data }).catch(() => {});
        }
        if (keystrokeDebounceTimerRef.current) {
          clearTimeout(keystrokeDebounceTimerRef.current);
        }
        keystrokeDebounceTimerRef.current = setTimeout(() => {
          refetchRef.current?.();
        }, 50);
      }
    },
    [isStreamingActive, sendStreamInput, sendShellInput]
  );

  // Unified resize handler routing between streaming and legacy polling
  const handleResize = useCallback(
    (rows: number, cols: number) => {
      if (isStreamingActive) {
        sendStreamResize(rows, cols);
      } else {
        const targetId = sessionIdRef.current;
        if (targetId) {
          sendShellResize({ sessionId: targetId, rows, cols }).catch(() => {});
        }
      }
    },
    [isStreamingActive, sendStreamResize, sendShellResize]
  );

  const handleInputRef = useRef(handleInput);
  useEffect(() => {
    handleInputRef.current = handleInput;
  }, [handleInput]);

  const handleResizeRef = useRef(handleResize);
  useEffect(() => {
    handleResizeRef.current = handleResize;
  }, [handleResize]);

  // --------------------------------------------------------------------------
  // Terminal Lifecycle & Addon Management
  // --------------------------------------------------------------------------
  useEffect(() => {
    const container = terminalContainerRef.current;
    if (!container) return;

    const term = new Terminal({
      convertEol: true,
      cursorBlink: true,
      cursorStyle: 'bar',
      fontFamily: 'ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, "Liberation Mono", "Courier New", monospace',
      fontSize: 12,
      lineHeight: 1.25,
      scrollback: 5000,
      theme: theme.terminal,
      allowProposedApi: true,
    });
    const fitAddon = new FitAddon();
    term.loadAddon(fitAddon);
    term.open(container);
    term.focus();
    terminalRef.current = term;
    fitAddonRef.current = fitAddon;

    const dataDisposable = term.onData((data) => {
      handleInputRef.current(data);
    });

    const resizeDisposable = term.onResize(({ cols, rows }) => {
      handleResizeRef.current(rows, cols);
    });

    // Track manual scroll-up so a repaint does not yank the viewport back down.
    term.onScroll(() => {
      const buffer = term.buffer.active;
      userScrolledUpRef.current = buffer.viewportY < buffer.baseY;
    });

    const dispatchResize = () => {
      try {
        if (container.clientWidth > 0 && container.clientHeight > 0) {
          fitAddon.fit();
          if (term.cols === 0 || term.rows === 0) {
            term.resize(Math.max(term.cols, 80), Math.max(term.rows, 24));
          }
          handleResizeRef.current(term.rows, term.cols);
          term.focus();
        }
      } catch { /* ignore */ }
    };

    dispatchResize();
    const timer = setTimeout(() => {
      dispatchResize();
      term.focus();
    }, 150);

    const resizeObserver = new ResizeObserver(() => {
      try {
        if (container.clientWidth > 0 && container.clientHeight > 0) {
          fitAddon.fit();
          if (term.cols === 0 || term.rows === 0) {
            term.resize(Math.max(term.cols, 80), Math.max(term.rows, 24));
          }
        }
      } catch { /* ignore */ }
    });
    resizeObserver.observe(container);

    const handleWindowResize = () => {
      try {
        if (container.clientWidth > 0 && container.clientHeight > 0) {
          fitAddon.fit();
        }
      } catch { /* ignore */ }
    };
    window.addEventListener('resize', handleWindowResize);

    // Initial paint on mount for polled output if available
    if (!isStreamingActive && output) {
      term.reset();
      term.write('\x1b[?25l' + output);
      lastWrittenOutputRef.current = output;
    }

    return () => {
      window.removeEventListener('resize', handleWindowResize);
      if (keystrokeDebounceTimerRef.current) {
        clearTimeout(keystrokeDebounceTimerRef.current);
      }
      clearTimeout(timer);
      resizeObserver.disconnect();
      dataDisposable.dispose();
      resizeDisposable.dispose();
      term.dispose();
      terminalRef.current = null;
      fitAddonRef.current = null;
      lastWrittenOutputRef.current = '';
    };
  }, []);

  // --------------------------------------------------------------------------
  // LEGACY POLLING PATH: Snapshot Diff & Repaint
  // When streaming is active, incoming bytes bypass term.reset() and are written directly.
  // --------------------------------------------------------------------------
  useEffect(() => {
    if (isStreamingActive) return;

    const term = terminalRef.current;
    if (!term || output === undefined) return;
    if (output === lastWrittenOutputRef.current) return;

    lastWrittenOutputRef.current = output;
    term.reset();
    term.write('\x1b[?25l' + (output || ''), () => {
      if (!userScrolledUpRef.current) {
        term.scrollToBottom();
      }
    });
  }, [output, isStreamingActive]);

  useEffect(() => {
    if (terminalRef.current) {
      terminalRef.current.options.theme = theme.terminal;
    }
  }, [theme]);

  const showUnreachableOverlay = isBridgeUnreachable && !output && !streamConnected;
  const showUnreachableBanner = isBridgeUnreachable && (Boolean(output) || streamConnected);
  const showConnecting = !output && !streamConnected && (session.status === 'starting' || isLoading);

  return (
    <div
      data-debug-id={`shell-terminal-pane-${session.session_id}`}
      className="relative flex flex-col flex-1 h-full min-h-0 w-full overflow-hidden bg-canvas"
    >
      {showUnreachableBanner && (
        <div
          data-debug-id="shell-terminal-unreachable-banner"
          className="z-10 flex shrink-0 items-center justify-between gap-2 border-b border-warning/30 bg-warning-soft px-3 py-1.5 text-xs text-warning"
        >
          <div className="flex items-center gap-1.5">
            <Icon name="alert" size={14} className="shrink-0 text-warning" />
            <span>Bridge Unreachable. Showing cached output.</span>
          </div>
          <button
            type="button"
            data-debug-id="shell-terminal-unreachable-banner-retry-btn"
            onClick={handleRetry}
            className="inline-flex items-center gap-1 rounded px-2 py-0.5 text-[11px] font-medium text-warning hover:bg-warning/20 transition-colors cursor-pointer"
          >
            <Icon name="refresh" size={12} />
            <span>Retry</span>
          </button>
        </div>
      )}

      {showUnreachableOverlay ? (
        <div
          data-debug-id="shell-terminal-unreachable"
          className="absolute inset-0 z-20 flex flex-col items-center justify-center gap-3 bg-canvas/95 p-6 text-center text-xs"
        >
          <div className="grid h-10 w-10 place-items-center rounded-full bg-danger/10 text-danger">
            <Icon name="alert" size={20} />
          </div>
          <div className="max-w-xs space-y-1">
            <p className="font-semibold text-primary">Bridge Unreachable</p>
            <p className="text-muted">
              The bridge hosting this shell session is offline or unreachable. Terminal input and output are temporarily unavailable.
            </p>
          </div>
          <button
            type="button"
            data-debug-id="shell-terminal-unreachable-retry-btn"
            onClick={handleRetry}
            className="inline-flex items-center gap-1.5 rounded-lg bg-surface-raised px-3 py-1.5 font-medium text-primary hover:bg-neutral-soft border border-subtle transition-colors cursor-pointer"
          >
            <Icon name="refresh" size={12} />
            <span>Retry</span>
          </button>
        </div>
      ) : showConnecting ? (
        <div
          data-debug-id={`shell-terminal-loading-${session.session_id}`}
          className="absolute inset-0 z-10 flex flex-col items-center justify-center gap-2 bg-canvas/90 text-xs text-muted pointer-events-none"
        >
          <Icon name="refresh" className="animate-spin text-accent" size={18} />
          <span>Connecting to terminal…</span>
        </div>
      ) : null}

      {/* xterm container */}
      <div
        ref={terminalContainerRef}
        data-debug-id={`shell-terminal-xterm-${session.session_id}`}
        onClick={() => terminalRef.current?.focus()}
        tabIndex={0}
        role="region"
        aria-label="Shell Terminal"
        style={{ backgroundColor: theme.terminal.background }}
        className="relative flex-1 min-h-0 w-full overflow-hidden p-2 font-mono text-xs cursor-text focus:outline-none"
      />
    </div>
  );
}
