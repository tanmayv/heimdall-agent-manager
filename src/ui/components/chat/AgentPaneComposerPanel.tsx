import { useCallback, useEffect, useRef, useState } from 'react';
import type { Terminal as TerminalType } from '@xterm/xterm';
import type { FitAddon as FitAddonType } from '@xterm/addon-fit';
import * as xtermModule from '@xterm/xterm';
import * as fitAddonModule from '@xterm/addon-fit';

const xtermObj = xtermModule as Record<string, any>;
const Terminal = (xtermObj.Terminal || xtermObj['default']?.Terminal || xtermObj['default']) as typeof TerminalType;

const fitAddonObj = fitAddonModule as Record<string, any>;
const FitAddon = (fitAddonObj.FitAddon || fitAddonObj['default']?.FitAddon || fitAddonObj['default']) as typeof FitAddonType;
import { useAgentPaneSubscription } from '../../hooks/useAgentPaneSubscription';
import { useSendAgentPaneInputMutation, useSendAgentPaneResizeMutation } from '../../api/endpoints/agents';
import { useFetchExperimentsQuery } from '../../api/endpoints/settings';
import { useAgentStream } from './useAgentStream';
import { useTheme } from '../../store/themeSlice';
import Icon from '../Icon';
import { readPinnedMonitorAgents, addPinnedMonitorAgent, removePinnedMonitorAgent } from '../../utils/clientPersistence';

/**
 * Compute fitted font size for terminal container on narrow viewports (<500px).
 * Standard CLI layouts require 80 columns. On mobile screens (e.g. 360px - 390px),
 * normal 12px font (~7.2px/col) exceeds container width and causes horizontal scrollbars.
 * Scaling font size ensures 80 columns fit within available width (REQ-PANE-MOBILE-2).
 */
export function computeFittedFontSize(containerWidth: number): number {
  if (containerWidth >= 500) {
    return 12;
  }
  // Available width accounting for p-2 (16px) horizontal padding
  const availableWidth = Math.max(0, containerWidth - 16);
  // Monospace character aspect ratio is ~0.6 (charWidth ~= fontSize * 0.6)
  // For 80 columns: fontSize <= availableWidth / (80 * 0.6) = availableWidth / 48
  const calculated = Math.floor(availableWidth / (80 * 0.6));
  return Math.max(6, Math.min(12, calculated));
}

export interface AgentPaneComposerPanelProps {
  agentInstanceId?: string | null;
  isExpanded: boolean;
  onClose?: () => void;
  onToggleExpand?: () => void;
  isActiveTab?: boolean;
  runtimeStatus?: string;
  startupStatus?: string;
  isStarting?: boolean;
  runCount?: number;
  startedAt?: string;
  onStreamOutput?: () => void;
  onStreamReady?: (info?: any) => void;
  onStreamClosed?: (info?: any) => void;
  className?: string;
  hideHeader?: boolean;
  onPin?: (agentInstanceId: string) => void;
}

export function AgentPaneComposerPanel({
  agentInstanceId,
  isExpanded,
  onClose,
  onToggleExpand,
  isActiveTab = true,
  runtimeStatus,
  startupStatus,
  isStarting = false,
  runCount,
  startedAt,
  onStreamOutput,
  onStreamReady,
  onStreamClosed,
  className = '',
  hideHeader = false,
  onPin,
}: AgentPaneComposerPanelProps) {
  const { theme } = useTheme();
  // Mobile maximize / restore state (REQ-PANE-MOBILE-1)
  const [isMobileMaximized, setIsMobileMaximized] = useState<boolean>(false);
  // Whether this agent is pinned to the /agent-monitor grid (per-browser localStorage).
  const [isPinned, setIsPinned] = useState<boolean>(false);
  useEffect(() => {
    setIsPinned(agentInstanceId ? readPinnedMonitorAgents().includes(agentInstanceId) : false);
  }, [agentInstanceId]);
  const handleTogglePin = useCallback(() => {
    if (!agentInstanceId) return;
    if (isPinned) {
      removePinnedMonitorAgent(agentInstanceId);
      setIsPinned(false);
    } else {
      addPinnedMonitorAgent(agentInstanceId);
      setIsPinned(true);
      // On first pin, surface the monitor grid so the user sees where it went.
      if (typeof window !== 'undefined') {
        window.open(window.location.origin + '/#/agent-monitor', 'agent-monitor');
      }
    }
    onPin?.(agentInstanceId);
  }, [agentInstanceId, isPinned, onPin]);
  const [terminalDimensions, setTerminalDimensions] = useState<{ cols: number; rows: number }>({
    cols: 80,
    rows: 120,
  });

  // --------------------------------------------------------------------------
  // Experimental Flag & Dual-Mode Configuration (REQ-STREAM-IMPL-4)
  // --------------------------------------------------------------------------
  const { data: expData } = useFetchExperimentsQuery();
  const isStreamingExperimentEnabled = Boolean(
    expData?.flags?.find((f) => f.key === 'streaming_terminal_pane')?.enabled
  );

  const [fallbackToPolling, setFallbackToPolling] = useState<boolean>(false);

  const [streamRuntimeStatus, setStreamRuntimeStatus] = useState<string | null>(null);

  useEffect(() => {
    setStreamRuntimeStatus(null);
  }, [agentInstanceId]);

  const onStreamOutputRef = useRef(onStreamOutput);
  useEffect(() => {
    onStreamOutputRef.current = onStreamOutput;
  }, [onStreamOutput]);

  const onStreamReadyRef = useRef(onStreamReady);
  useEffect(() => {
    onStreamReadyRef.current = onStreamReady;
  }, [onStreamReady]);

  const onStreamClosedRef = useRef(onStreamClosed);
  useEffect(() => {
    onStreamClosedRef.current = onStreamClosed;
  }, [onStreamClosed]);

  const hasReceivedOutputRef = useRef<boolean>(false);
  const streamBufferRef = useRef<Uint8Array[]>([]);

  useEffect(() => {
    hasReceivedOutputRef.current = false;
    streamBufferRef.current = [];
  }, [agentInstanceId]);

  useEffect(() => {
    if (isStarting) {
      hasReceivedOutputRef.current = false;
      streamBufferRef.current = [];
    }
  }, [isStarting]);

  // --------------------------------------------------------------------------
  // STREAMING PATH: Low-latency WebSocket streaming without term.reset()
  // --------------------------------------------------------------------------
  const {
    connected: streamConnected,
    isStreamReady,
    sendInput: sendStreamInput,
    sendResize: sendStreamResize,
    reconnect: reconnectStream,
  } = useAgentStream({
    agentInstanceId: (isExpanded || isStarting) && isActiveTab ? agentInstanceId : null,
    enabled: isStreamingExperimentEnabled && !fallbackToPolling,
    rows: terminalDimensions.rows,
    cols: terminalDimensions.cols,
    onConnect: () => {
      const term = terminalRef.current;
      if (!term) return;
      term.reset();
      term.write('\x1b[H');
      lastWrittenOutputRef.current = '';
    },
    onStreamReady: (info) => {
      onStreamReadyRef.current?.(info);
    },
    onStreamClosed: (info) => {
      onStreamClosedRef.current?.(info);
    },
    onOutput: (bytes) => {
      if (bytes && bytes.length > 0) {
        streamBufferRef.current.push(bytes);
        onStreamOutputRef.current?.();
      }
      const term = terminalRef.current;
      if (!term) return;
      if (!hasReceivedOutputRef.current) {
        hasReceivedOutputRef.current = true;
        term.reset();
      }
      term.write(bytes);
      if (!userScrolledUpRef.current) {
        term.scrollToBottom();
      }
    },
    onStatus: (status) => {
      if (status) {
        setStreamRuntimeStatus(status);
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

  // Track runCount, startedAt, and isStarting to reset stream on agent restart (REQ-STREAM-RECONNECT-27)
  const prevRunCountRef = useRef<number | undefined>(runCount);
  const prevStartedAtRef = useRef<string | undefined>(startedAt);
  const prevIsStartingRef = useRef<boolean>(isStarting);

  useEffect(() => {
    const runCountChanged = prevRunCountRef.current !== undefined && prevRunCountRef.current !== runCount;
    const startedAtChanged = prevStartedAtRef.current !== undefined && prevStartedAtRef.current !== startedAt;
    const isRestartStarting = !prevIsStartingRef.current && isStarting;

    prevRunCountRef.current = runCount;
    prevStartedAtRef.current = startedAt;
    prevIsStartingRef.current = isStarting;

    if (runCountChanged || startedAtChanged || isRestartStarting) {
      streamBufferRef.current = [];
      hasReceivedOutputRef.current = false;
      if (terminalRef.current) {
        terminalRef.current.reset();
      }
      reconnectStream();
    }
  }, [runCount, startedAt, isStarting, reconnectStream]);

  // --------------------------------------------------------------------------
  // LEGACY POLLING PATH: 500ms/5m polled capture with SHA-256 diff & term.reset()
  // Cleanly isolated so that removing legacy polling in the future only requires
  // deleting this block and the legacy branches in handleInput / handleResize.
  // --------------------------------------------------------------------------
  const {
    output,
    isLoading,
    isFetching,
    refetch,
  } = useAgentPaneSubscription({
    agentInstanceId: (!isStreamingExperimentEnabled || fallbackToPolling) ? agentInstanceId : null,
    isExpanded,
    isActiveTab,
    runtimeStatus,
    width: terminalDimensions.cols,
    lineLimit: terminalDimensions.rows,
  });

  const [sendAgentPaneInput] = useSendAgentPaneInputMutation();
  const [sendAgentPaneResize] = useSendAgentPaneResizeMutation();

  const terminalContainerRef = useRef<HTMLDivElement | null>(null);
  const terminalRef = useRef<TerminalType | null>(null);
  const fitAddonRef = useRef<FitAddonType | null>(null);
  const preRef = useRef<HTMLPreElement | null>(null);
  const userScrolledUpRef = useRef<boolean>(false);
  const lastWrittenOutputRef = useRef<string>('');
  const agentInstanceIdRef = useRef(agentInstanceId);
  const refetchRef = useRef(refetch);
  const keystrokeDebounceTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null);

  useEffect(() => {
    agentInstanceIdRef.current = agentInstanceId;
  }, [agentInstanceId]);

  useEffect(() => {
    refetchRef.current = refetch;
  }, [refetch]);

  // Unified input handler cleanly routing between streaming and legacy polling
  const handleInput = useCallback(
    (data: string) => {
      if (isStreamingActive) {
        // STREAMING: Send keystrokes directly over WebSocket without debounce (<10ms latency)
        sendStreamInput(data);
      } else {
        // LEGACY POLLING: HTTP POST with 50ms debounced capture refetch
        const targetId = agentInstanceIdRef.current;
        if (targetId) {
          sendAgentPaneInput({ agentInstanceId: targetId, data }).catch(() => {});
        }
        if (keystrokeDebounceTimerRef.current) {
          clearTimeout(keystrokeDebounceTimerRef.current);
        }
        keystrokeDebounceTimerRef.current = setTimeout(() => {
          refetchRef.current?.();
        }, 50);
      }
    },
    [isStreamingActive, sendStreamInput, sendAgentPaneInput]
  );

  // Unified resize handler routing between streaming and legacy polling
  const handleResize = useCallback(
    (rows: number, cols: number) => {
      const effectiveCols = Math.max(cols, 80);
      const effectiveRows = Math.max(rows, 24);
      if (isStreamingActive) {
        sendStreamResize(effectiveRows, effectiveCols);
      } else {
        const targetId = agentInstanceIdRef.current;
        if (targetId) {
          sendAgentPaneResize({ agentInstanceId: targetId, rows: effectiveRows, cols: effectiveCols }).catch(() => {});
        }
      }
      setTerminalDimensions({ cols: effectiveCols, rows: effectiveRows });
    },
    [isStreamingActive, sendStreamResize, sendAgentPaneResize]
  );

  const handleInputRef = useRef(handleInput);
  useEffect(() => {
    handleInputRef.current = handleInput;
  }, [handleInput]);

  const handleResizeRef = useRef(handleResize);
  useEffect(() => {
    handleResizeRef.current = handleResize;
  }, [handleResize]);

  // Detect manual scroll up on accessible fallback pre
  const handleScroll = useCallback(() => {
    const node = preRef.current;
    if (!node) return;
    const isAtBottom = node.scrollHeight - node.scrollTop - node.clientHeight <= 25;
    userScrolledUpRef.current = !isAtBottom;
  }, []);

  // Initialize @xterm/xterm Terminal instance when expanded
  useEffect(() => {
    if (!isExpanded || !terminalContainerRef.current) return;
    const container = terminalContainerRef.current;

    const initialFontSize = typeof container.clientWidth === 'number' && container.clientWidth > 0
      ? computeFittedFontSize(container.clientWidth)
      : 12;

    const term = new Terminal({
      convertEol: !isStreamingActive,
      cursorBlink: false,
      cursorInactiveStyle: 'none',
      cursorStyle: 'bar',
      fontFamily: 'ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, "Liberation Mono", "Courier New", monospace',
      fontSize: initialFontSize,
      lineHeight: 1.25,
      scrollback: 1000,
      theme: theme.terminal,
      allowProposedApi: true,
    });

    const fitAddon = new FitAddon();
    term.loadAddon(fitAddon);
    term.open(container);
    // Hide xterm's synthetic cursor layer in legacy polling mode where snapshots don't preserve cursor
    if (!isStreamingActive) {
      term.write('\x1b[?25l');
    }

    terminalRef.current = term;
    fitAddonRef.current = fitAddon;

    // Track scrolling within xterm buffer
    term.onScroll(() => {
      const buffer = term.buffer.active;
      userScrolledUpRef.current = buffer.viewportY < buffer.baseY;
    });

    // Keystroke input hook: dispatch to unified handleInputRef
    const dataDisposable = term.onData((data) => {
      handleInputRef.current(data);
    });

    // Terminal resize hook: dispatch to unified handleResizeRef
    const resizeDisposable = term.onResize(({ cols, rows }) => {
      handleResizeRef.current(rows, cols);
    });

    const dispatchResize = () => {
      try {
        if (container.clientWidth > 0 && container.clientHeight > 0) {
          // Mobile 80-column auto-fit (REQ-PANE-MOBILE-2)
          if (container.clientWidth < 500) {
            const fittedSize = computeFittedFontSize(container.clientWidth);
            if (term.options.fontSize !== fittedSize) {
              term.options.fontSize = fittedSize;
            }
          } else if (term.options.fontSize !== 12) {
            term.options.fontSize = 12;
          }
          fitAddon.fit();
          // If on a narrow viewport and measured cols is still under 80, decrement font size and re-fit
          if (container.clientWidth < 500 && term.cols < 80 && (term.options.fontSize ?? 12) > 6) {
            term.options.fontSize = Math.max(6, (term.options.fontSize ?? 12) - 1);
            fitAddon.fit();
          }
          // Guarantee minimum usable dimensions (minimum 80 cols, 24 rows)
          term.resize(Math.max(term.cols, 80), Math.max(term.rows, 24));
        }
        if (term.rows > 0 && term.cols > 0) {
          handleResizeRef.current(term.rows, term.cols);
        }
      } catch (e) {}
    };

    // Dispatch initial resize immediately after initial fitAddon.fit() on mount/expansion
    dispatchResize();

    // Initial fit with frame delay for container layout (animation may not be settled yet)
    const timer = setTimeout(() => {
      dispatchResize();
    }, 150);

    const resizeObserver = new ResizeObserver(() => {
      dispatchResize();
    });
    resizeObserver.observe(container);

    const handleWindowResize = () => {
      dispatchResize();
    };
    if (typeof window !== 'undefined') {
      window.addEventListener('resize', handleWindowResize);
    }

    // Initial write if output already present in streaming/legacy mode, or startup indicator
    if (streamBufferRef.current.length > 0) {
      hasReceivedOutputRef.current = true;
      for (const chunk of streamBufferRef.current) {
        term.write(chunk);
      }
      if (!userScrolledUpRef.current) {
        term.scrollToBottom();
      }
    } else if (!isStreamingActive && output) {
      term.reset();
      term.write('\x1b[?25l' + output, () => {
        if (!userScrolledUpRef.current) {
          term.scrollToBottom();
        }
      });
      lastWrittenOutputRef.current = output;
    } else if (isStarting && !output && streamBufferRef.current.length === 0) {
      term.write('\x1b[90mStarting agent…\x1b[0m');
    } else if (isLoading && !isStreamingActive) {
      term.write('\x1b[90mLoading terminal output…\x1b[0m');
    }

    return () => {
      if (typeof window !== 'undefined') {
        window.removeEventListener('resize', handleWindowResize);
      }
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
  }, [isExpanded]);

  // When pane is open but terminal is awaiting initial output during startup, show subtle 'Starting agent…' loading indicator
  useEffect(() => {
    if (isStarting && isExpanded && !hasReceivedOutputRef.current && streamBufferRef.current.length === 0 && !output) {
      const term = terminalRef.current;
      if (term) {
        term.reset();
        term.write('\x1b[90mStarting agent…\x1b[0m');
      }
    }
  }, [isStarting, isExpanded, output]);

  // Expand pane if legacy polling output arrives during startup
  useEffect(() => {
    if (isStarting && output) {
      onStreamOutputRef.current?.();
    }
  }, [isStarting, output]);

  // Update terminal instance with active theme's terminal palette (REQ-THEME-EXTERNALS)
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

  // Feed incoming ANSI output into terminal (LEGACY POLLING PATH)
  useEffect(() => {
    if (isStreamingActive) return; // Prevent clearing/redrawing buffer during active streaming
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

  // Auto-scroll to bottom on update for accessible fallback
  useEffect(() => {
    const node = preRef.current;
    if (!node) return;
    if (!userScrolledUpRef.current) {
      node.scrollTop = node.scrollHeight;
    }
  }, [output]);

  // Reset scroll on expand
  useEffect(() => {
    if (isExpanded) {
      userScrolledUpRef.current = false;
      terminalRef.current?.scrollToBottom();
      const node = preRef.current;
      if (node) {
        node.scrollTop = node.scrollHeight;
      }
    }
  }, [isExpanded]);

  if (!isExpanded) {
    return null;
  }

  const effectiveRuntimeStatus = streamRuntimeStatus || runtimeStatus;
  const isStopped = effectiveRuntimeStatus === 'stopped' || effectiveRuntimeStatus === 'failed';
  const isBlocked = effectiveRuntimeStatus === 'blocked' || effectiveRuntimeStatus === 'startup_blocked';
  const isUpdatingOrRunning = Boolean(isFetching || effectiveRuntimeStatus === 'running' || effectiveRuntimeStatus === 'active');
  const intervalLabel = !agentInstanceId || isStopped || isActiveTab === false
    ? 'paused'
    : isBlocked
    ? 'blocked'
    : isStarting
    ? 'starting'
    : isStreamingActive
    ? 'streaming'
    : isExpanded
    ? '500ms continuous'
    : '5m';

  const handleClose = onClose || onToggleExpand;

  return (
    <div
      data-debug-id="agent-pane-composer-panel"
      className={`overflow-hidden rounded-xl border border-subtle bg-surface ${className}`}
    >
      {/* Header controls */}
      {!hideHeader && (
      <div
        data-debug-id="agent-pane-composer-header"
        className="flex items-center justify-between border-b border-subtle bg-surface-raised px-3 py-1.5 text-xs text-muted"
      >
        <div className="flex items-center gap-2">
          {/* Status indicator dot (warning if blocked, pulsing green if updating/running) */}
          <span
            data-debug-id="agent-pane-status-dot"
            title={isBlocked ? 'Blocked' : isUpdatingOrRunning ? 'Running / updating' : (isStopped ? 'Stopped' : 'Idle')}
            className={`h-2 w-2 rounded-full ${
              isBlocked
                ? 'bg-warning shadow-glow-warning animate-soft-pulse'
                : isStarting
                ? 'bg-accent animate-pulse'
                : isUpdatingOrRunning
                ? 'bg-success animate-pulse'
                : isStopped
                ? 'bg-faint'
                : 'bg-success/70'
            }`}
          />
          <span data-debug-id="agent-pane-title" className="font-semibold text-primary">
            Terminal Output
          </span>
          {/* Refresh interval tag */}
          <span
            data-debug-id="agent-pane-interval-tag"
            className={`rounded px-1.5 py-0.5 text-[10px] font-mono ${
              isBlocked ? 'bg-warning/20 text-warning font-semibold' : 'bg-neutral-soft text-muted'
            }`}
          >
            {intervalLabel}
          </span>
        </div>

        <div className="flex items-center gap-1">
          {/* Pin to Agent Monitor grid */}
          {agentInstanceId ? (
            <button
              type="button"
              data-debug-id="agent-pane-pin-btn"
              title={isPinned ? 'Unpin from monitor' : 'Pin to Agent Monitor'}
              aria-label={isPinned ? 'Unpin from monitor' : 'Pin to Agent Monitor'}
              aria-pressed={isPinned}
              onClick={handleTogglePin}
              className={`grid h-6 w-6 place-items-center rounded hover:bg-neutral-soft ${isPinned ? 'text-accent' : 'text-muted hover:text-primary'}`}
            >
              <Icon name="grid" size={12} />
            </button>
          ) : null}

          {/* Manual refresh button */}
          <button
            type="button"
            data-debug-id="agent-pane-refresh-btn"
            title="Refresh terminal output"
            aria-label="Refresh terminal output"
            onClick={() => {
              if (isStreamingActive || (isStreamingExperimentEnabled && !fallbackToPolling)) {
                reconnectStream();
              }
              refetch();
            }}
            disabled={isLoading || isFetching}
            className="grid h-6 w-6 place-items-center rounded text-muted hover:bg-neutral-soft hover:text-primary disabled:cursor-not-allowed disabled:opacity-40"
          >
            <Icon name="refresh" size={12} className={isFetching ? 'animate-spin' : ''} />
          </button>

          {/* Maximize / restore toggle for mobile viewports (REQ-PANE-MOBILE-1) */}
          <button
            type="button"
            data-debug-id="agent-pane-maximize-btn"
            title={isMobileMaximized ? 'Restore compact terminal height' : 'Maximize terminal'}
            aria-label={isMobileMaximized ? 'Restore compact terminal height' : 'Maximize terminal'}
            aria-pressed={isMobileMaximized}
            onClick={() => setIsMobileMaximized((prev) => !prev)}
            className="grid h-6 w-6 place-items-center rounded text-muted hover:bg-neutral-soft hover:text-primary sm:hidden"
          >
            <Icon name={isMobileMaximized ? 'minimize' : 'maximize'} size={12} />
          </button>

          {/* Collapse chevron */}
          {handleClose ? (
            <button
              type="button"
              data-debug-id="agent-pane-collapse-btn"
              title="Collapse terminal output"
              aria-label="Collapse terminal output"
              onClick={handleClose}
              className="grid h-6 w-6 place-items-center rounded text-muted hover:bg-neutral-soft hover:text-primary"
            >
              <Icon name="chevron-down" size={14} />
            </button>
          ) : null}
        </div>
      </div>
      )}

      {/* Interactive xterm terminal container (REQ-PANE-MOBILE-1, REQ-PANE-MOBILE-2) */}
      <div
        ref={terminalContainerRef}
        data-debug-id="agent-pane-terminal"
        onClick={() => terminalRef.current?.focus()}
        tabIndex={0}
        role="region"
        aria-label="Interactive Terminal"
        style={{ backgroundColor: theme.terminal.background }}
        className={`chat-scrollbar relative w-full overflow-x-auto p-2 font-mono text-xs cursor-text touch-manipulation focus:outline-none sm:min-h-[360px] sm:h-[360px] sm:max-h-[420px] ${
          isMobileMaximized
            ? 'min-h-[360px] h-[360px] max-h-[420px]'
            : 'min-h-[140px] h-[140px] max-h-[200px]'
        }`}
      >
        {isStarting && !hasReceivedOutputRef.current && streamBufferRef.current.length === 0 && !output && (
          <div
            data-debug-id="agent-pane-starting-indicator"
            className="pointer-events-none absolute inset-0 flex items-center justify-center gap-2 font-sans text-xs text-muted"
          >
            <span className="h-2 w-2 rounded-full bg-accent animate-ping" />
            <span>Starting agent…</span>
          </div>
        )}
      </div>

      {/* Accessible fallback & static verification pre element */}
      <pre
        ref={preRef}
        onScroll={handleScroll}
        data-debug-id="agent-pane-output"
        aria-hidden="true"
        className={`sr-only chat-scrollbar overflow-auto whitespace-pre-wrap p-3 font-mono text-xs leading-5 text-primary sm:max-h-[420px] ${
          isMobileMaximized ? 'max-h-[420px]' : 'max-h-[200px]'
        }`}
      >
        {output || (isStarting && !hasReceivedOutputRef.current && streamBufferRef.current.length === 0 ? 'Starting agent…' : isLoading ? 'Loading terminal output…' : '')}
      </pre>
    </div>
  );
}

export default AgentPaneComposerPanel;
