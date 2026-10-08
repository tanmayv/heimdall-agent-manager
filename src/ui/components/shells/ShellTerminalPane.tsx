import { useCallback, useEffect, useRef, useState } from 'react';
import type { Terminal as TerminalType } from '@xterm/xterm';
import type { FitAddon as FitAddonType } from '@xterm/addon-fit';
import type { SerializeAddon as SerializeAddonType } from '@xterm/addon-serialize';
import * as xtermModule from '@xterm/xterm';
import * as fitAddonModule from '@xterm/addon-fit';
import * as serializeAddonModule from '@xterm/addon-serialize';
import { terminalSessionRegistry } from './terminalSessionRegistry';

const xtermObj = xtermModule as Record<string, any>;
const Terminal = (xtermObj.Terminal || xtermObj['default']?.Terminal || xtermObj['default']) as typeof TerminalType;
const fitAddonObj = fitAddonModule as Record<string, any>;
const FitAddon = (fitAddonObj.FitAddon || fitAddonObj['default']?.FitAddon || fitAddonObj['default']) as typeof FitAddonType;
const serializeAddonObj = serializeAddonModule as Record<string, any>;
const SerializeAddon = (serializeAddonObj.SerializeAddon || serializeAddonObj['default']?.SerializeAddon || serializeAddonObj['default']) as typeof SerializeAddonType;

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

/**
 * CALLERS MUST KEY THIS BY SESSION ID: `<ShellTerminalPane key={s.session_id} session={s} />`
 * (REQ-SHELL-18)
 *
 * The xterm `Terminal` is built in a mount effect with an EMPTY dependency array, so swapping the
 * `session` prop switches the STREAM while leaving the previous session's scrollback on screen —
 * the bleed the user reported when switching tabs in the bottom dock. A `key` makes a session
 * change a remount, which is what this component needs rather than a targeted reset: it owns five
 * mutable refs (terminalRef, fitAddonRef, sessionIdRef, lastWrittenOutputRef, userScrolledUpRef)
 * that must all agree with the new session, and a remount cannot forget one of them.
 *
 * A remount also re-runs the initial fit, which is the only thing that pushes geometry to a
 * freshly-selected session: geometry is sent from just two places, `term.onResize` (which fires
 * only when xterm's own dimensions CHANGE — switching sessions does not resize the pane) and
 * `dispatchResize` (mount-effect only). Without the remount, a switched-to PTY is never told its
 * size at all.
 *
 * tests/ui_shell_streaming_test.ts asserts every call site passes the key, because a fourth call
 * site that forgets it reintroduces the bleed silently.
 */

export function ShellTerminalPane({
  session,
  isBridgeUnreachable: propIsBridgeUnreachable,
}: ShellTerminalPaneProps) {
  const { theme } = useTheme();
  const terminalContainerRef = useRef<HTMLDivElement | null>(null);
  const terminalRef = useRef<TerminalType | null>(null);
  const fitAddonRef = useRef<FitAddonType | null>(null);
  const serializeAddonRef = useRef<SerializeAddonType | null>(null);
  const isExplicitlyClosedRef = useRef(false);
  const isSizedRef = useRef(false);
  const [isSized, setIsSized] = useState(false);
  const pendingStreamOutputRef = useRef<Uint8Array[]>([]);

  const isTerminal = session.kind === 'shell';
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
    // REQ-SHELL-18 & REQ-SHELL-DOCK-NO-VSCROLL-23 — read back by the hook from inside the socket's `onopen`,
    // and again on every reconnect. The mount-time fit below computes the right geometry and pushes it,
    // but the socket is not open yet at that point, so that frame is dropped; this is what makes the PTY
    // learn the pane's real size on create instead of sitting at its default until the user happens to
    // resize the window. Column floor applied here too, for the same reason handleResize applies it.
    getGeometry: () => {
      const term = terminalRef.current;
      const container = terminalContainerRef.current;
      const fitAddon = fitAddonRef.current;
      if (!term) return null;
      if (container && container.clientWidth > 0 && container.clientHeight > 0 && fitAddon && !isSizedRef.current) {
        try {
          fitAddon.fit();
          term.resize(Math.max(term.cols, 40), term.rows);
          isSizedRef.current = true;
          setIsSized(true);
        } catch { /* ignore */ }
      }
      if (!isSizedRef.current && (!container || container.clientWidth === 0 || container.clientHeight === 0)) {
        return null;
      }
      return { rows: Math.max(term.rows, 1), cols: Math.max(term.cols, 40) };
    },
    onOutput: (bytes) => {
      console.log('[ShellTerminalPane] onOutput received:', bytes.length, 'bytes, term attached:', Boolean(terminalRef.current));
      const term = terminalRef.current;
      if (!term) return;
      if (!isSizedRef.current) {
        console.log('[ShellTerminalPane] withholding stream chunk until container is sized:', bytes.length, 'bytes');
        pendingStreamOutputRef.current.push(bytes);
        return;
      }
      // term.write(bytes)
      term.write(bytes, () => {
        const buffer = term.buffer.active;
        if (!userScrolledUpRef.current && buffer.baseY > 0) {
          term.scrollToBottom();
        }
      });
    },
    onError: () => {
      console.error('[ShellTerminalPane] stream onError -> triggering setFallbackToPolling(true)');
      // Graceful fallback: If WebSocket encounters error, fall back to polling
      if (isStreamingExperimentEnabled) {
        setFallbackToPolling(true);
      }
    },
    onClose: () => {
      console.warn('[ShellTerminalPane] stream onClose -> triggering setFallbackToPolling(true)');
      // Graceful fallback: If WebSocket disconnects, fall back to polling
      if (isStreamingExperimentEnabled) {
        setFallbackToPolling(true);
      }
    },
  });

  const isStreamingActive = isStreamingExperimentEnabled && !fallbackToPolling;

  useEffect(() => {
    console.log('[ShellTerminalPane] Streaming state update:', {
      paneSessionId,
      isStreamingExperimentEnabled,
      streamConnected,
      fallbackToPolling,
      isStreamingActive,
    });
  }, [paneSessionId, isStreamingExperimentEnabled, streamConnected, fallbackToPolling, isStreamingActive]);

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
    console.log('[ShellTerminalPane] handleRetry clicked');
    setFallbackToPolling(false);
    reconnectStream();
    refetch();
  }, [reconnectStream, refetch]);

  // Unified input handler cleanly routing between streaming and legacy polling
  const handleInput = useCallback(
    (data: string) => {
      console.log('[ShellTerminalPane] handleInput:', {
        dataLength: data.length,
        isStreamingActive,
        fallbackToPolling,
        targetId: sessionIdRef.current,
      });
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
  //
  // REQ-SHELL-DOCK-NO-VSCROLL-23: The 40-col floor is a DELIBERATE MINIMUM, kept on purpose, not a
  // workaround for a mis-measured fit. It pairs with `overflow-x-auto` on the xterm container
  // below: on a narrow pane (< 40 cols), keep 40 usable columns and let the user scroll sideways, rather
  // than hand a TUI 20 columns and have it reflow into unreadability. No 24-row floor is enforced so terminal
  // rows fit the parent container directly via FitAddon, eliminating vertical scrolling across all view sizes.
  //
  // It is also provably innocent of "the new terminal does not fill the pane width":
  // `Math.max(n, 40)` is monotonic and binds ONLY below 40, so if the fit proposes 200 columns it
  // stays 200. No value of the floor can make a WIDE pane render narrow, which means the floor
  // cannot have been masking the geometry bug and changing it would not have fixed anything. That
  // bug was the dropped resize frame (see getGeometry below), and it is fixed there.
  const handleResize = useCallback(
    (rows: number, cols: number) => {
      const effectiveCols = Math.max(cols, 40);
      const effectiveRows = Math.max(rows, 1);
      console.log('[ShellTerminalPane] handleResize:', {
        rows: effectiveRows,
        cols: effectiveCols,
        isStreamingActive,
      });
      if (isStreamingActive) {
        sendStreamResize(effectiveRows, effectiveCols);
      } else {
        const targetId = sessionIdRef.current;
        if (targetId) {
          sendShellResize({ sessionId: targetId, rows: effectiveRows, cols: effectiveCols }).catch(() => {});
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

    if (paneSessionId) {
      terminalSessionRegistry.registerActiveSession(paneSessionId);
    }
    const restorationData = paneSessionId
      ? terminalSessionRegistry.consumeRestorationData(paneSessionId)
      : null;

    const term = new Terminal({
      convertEol: !isStreamingActive,
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
    const serializeAddon = new SerializeAddon();
    term.loadAddon(serializeAddon);
    serializeAddonRef.current = serializeAddon;
    if (paneSessionId) {
      terminalSessionRegistry.registerSerializeAddon(paneSessionId, serializeAddon);
    }

    term.open(container);
    term.focus();
    if (session.kind === 'shell') {
      term.write('\x1b[?25h');
    }
    terminalRef.current = term;
    fitAddonRef.current = fitAddon;

    // Restore saved snapshot and unmounted deltas if present
    if (restorationData) {
      if (restorationData.snapshot) {
        term.write(restorationData.snapshot, () => {
          if (restorationData.deltaChunks && restorationData.deltaChunks.length > 0) {
            for (const chunk of restorationData.deltaChunks) {
              term.write(chunk);
            }
          }
          if (restorationData.savedViewportY !== undefined && restorationData.savedViewportY >= 0) {
            try {
              term.scrollToLine(restorationData.savedViewportY);
              const buffer = term.buffer.active;
              userScrolledUpRef.current = buffer.viewportY < buffer.baseY;
            } catch { /* ignore */ }
          }
        });
      } else if (restorationData.deltaChunks && restorationData.deltaChunks.length > 0) {
        for (const chunk of restorationData.deltaChunks) {
          term.write(chunk);
        }
      }
    }

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

    const flushPendingOutput = (targetTerm: TerminalType) => {
      if (pendingStreamOutputRef.current.length > 0) {
        const queued = pendingStreamOutputRef.current;
        pendingStreamOutputRef.current = [];
        console.log(`[ShellTerminalPane] flushing ${queued.length} withheld stream chunks`);
        for (const chunk of queued) {
          // term.write(bytes)
          targetTerm.write(chunk, () => {
            const buffer = targetTerm.buffer.active;
            if (!userScrolledUpRef.current && buffer.baseY > 0) {
              targetTerm.scrollToBottom();
            }
          });
        }
      }
    };

    const dispatchResize = () => {
      try {
        if (container.clientWidth > 0 && container.clientHeight > 0) {
          fitAddon.fit();
          term.resize(Math.max(term.cols, 40), term.rows);
          handleResizeRef.current(term.rows, term.cols);
          term.focus();
          if (!isSizedRef.current) {
            isSizedRef.current = true;
            setIsSized(true);
            flushPendingOutput(term);
          }
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
          term.resize(Math.max(term.cols, 40), term.rows);
          if (!isSizedRef.current) {
            isSizedRef.current = true;
            setIsSized(true);
            handleResizeRef.current(term.rows, term.cols);
            flushPendingOutput(term);
          }
        }
      } catch { /* ignore */ }
    });
    resizeObserver.observe(container);

    const handleWindowResize = () => {
      try {
        if (container.clientWidth > 0 && container.clientHeight > 0) {
          fitAddon.fit();
          term.resize(Math.max(term.cols, 40), term.rows);
          if (!isSizedRef.current) {
            isSizedRef.current = true;
            setIsSized(true);
            handleResizeRef.current(term.rows, term.cols);
            flushPendingOutput(term);
          }
        }
      } catch { /* ignore */ }
    };
    window.addEventListener('resize', handleWindowResize);

    // Initial paint on mount for polled output if available
    if (!isStreamingActive && output) {
      term.reset();
      term.write(output);
      if (session.kind === 'shell') {
        term.write('\x1b[?25h');
      }
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

      const currentSessionId = sessionIdRef.current;
      if (currentSessionId) {
        if (!isExplicitlyClosedRef.current && terminalSessionRegistry.isSessionActive(currentSessionId) && serializeAddonRef.current && isSizedRef.current) {
          try {
            const serialized = serializeAddonRef.current.serialize();
            const viewportY = term.buffer.active.viewportY;
            terminalSessionRegistry.saveSnapshot(
              currentSessionId,
              serialized,
              viewportY,
              term.cols,
              term.rows
            );
          } catch (err) {
            console.warn('[ShellTerminalPane] failed to serialize snapshot on unmount:', err);
          }
        }
        terminalSessionRegistry.unregisterSerializeAddon(currentSessionId);
        terminalSessionRegistry.unregisterActiveSession(currentSessionId);
      }

      term.dispose();
      terminalRef.current = null;
      fitAddonRef.current = null;
      serializeAddonRef.current = null;
      lastWrittenOutputRef.current = '';
      isSizedRef.current = false;
      setIsSized(false);
      pendingStreamOutputRef.current = [];
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
    term.write(output || '', () => {
      if (session.kind === 'shell') {
        term.write('\x1b[?25h');
      }
      const buffer = term.buffer.active;
      if (!userScrolledUpRef.current && buffer.baseY > 0) {
        term.scrollToBottom();
      }
    });
  }, [output, isStreamingActive]);

  useEffect(() => {
    if (terminalRef.current) {
      terminalRef.current.options.theme = theme.terminal;
    }
  }, [theme]);

  // Synchronize terminal convertEol option with streaming status (disabled during streaming)
  useEffect(() => {
    if (terminalRef.current) {
      terminalRef.current.options.convertEol = !isStreamingActive;
    }
  }, [isStreamingActive]);

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
        className="chat-scrollbar relative flex-1 min-h-0 w-full overflow-x-auto p-2 font-mono text-xs cursor-text touch-manipulation focus:outline-none"
      />
    </div>
  );
}
