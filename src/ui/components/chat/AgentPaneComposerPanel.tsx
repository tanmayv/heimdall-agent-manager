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
import { useTheme } from '../../store/themeSlice';
import Icon from '../Icon';
import { readPinnedMonitorAgents, addPinnedMonitorAgent, removePinnedMonitorAgent } from '../../utils/clientPersistence';

export interface AgentPaneComposerPanelProps {
  agentInstanceId?: string | null;
  isExpanded: boolean;
  onClose?: () => void;
  onToggleExpand?: () => void;
  isActiveTab?: boolean;
  runtimeStatus?: string;
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
  className = '',
  hideHeader = false,
  onPin,
}: AgentPaneComposerPanelProps) {
  const { theme } = useTheme();
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

  const {
    output,
    isLoading,
    isFetching,
    refetch,
  } = useAgentPaneSubscription({
    agentInstanceId,
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

    const term = new Terminal({
      convertEol: true,
      cursorBlink: false,
      cursorInactiveStyle: 'none',
      cursorStyle: 'bar',
      fontFamily: 'ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, "Liberation Mono", "Courier New", monospace',
      fontSize: 12,
      lineHeight: 1.25,
      scrollback: 1000,
      theme: theme.terminal,
      allowProposedApi: true,
    });

    const fitAddon = new FitAddon();
    term.loadAddon(fitAddon);
    term.open(container);
    // Hide xterm's synthetic cursor layer so no trailing cursor sits at the end of the 25-line screen
    term.write('\x1b[?25l');

    terminalRef.current = term;
    fitAddonRef.current = fitAddon;

    // Track scrolling within xterm buffer
    term.onScroll(() => {
      const buffer = term.buffer.active;
      userScrolledUpRef.current = buffer.viewportY < buffer.baseY;
    });

    // Keystroke input hook: dispatch to sendAgentPaneInput and trigger debounced refetch (50ms)
    const dataDisposable = term.onData((data) => {
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
    });

    // Terminal resize hook: dispatch to sendAgentPaneResize and update dimensions
    const resizeDisposable = term.onResize(({ cols, rows }) => {
      const targetId = agentInstanceIdRef.current;
      if (targetId) {
        sendAgentPaneResize({ agentInstanceId: targetId, rows, cols }).catch(() => {});
      }
      setTerminalDimensions({ cols, rows });
    });

    const dispatchResize = () => {
      try {
        if (container.clientWidth > 0 && container.clientHeight > 0) {
          fitAddon.fit();
          // Guarantee minimum usable dimensions if fit produced 0 cols/rows
          if (term.cols === 0 || term.rows === 0) {
            term.resize(Math.max(term.cols, 80), Math.max(term.rows, 24));
          }
        }
        const targetId = agentInstanceIdRef.current;
        if (targetId && term.rows > 0 && term.cols > 0) {
          sendAgentPaneResize({
            agentInstanceId: targetId,
            rows: term.rows,
            cols: term.cols,
          }).catch(() => {});
          setTerminalDimensions({ cols: term.cols, rows: term.rows });
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
      try {
        if (container.clientWidth > 0 && container.clientHeight > 0) {
          fitAddon.fit();
          if (term.cols === 0 || term.rows === 0) {
            term.resize(Math.max(term.cols, 80), Math.max(term.rows, 24));
          }
        }
      } catch (e) {}
    });
    resizeObserver.observe(container);

    const handleWindowResize = () => {
      try {
        if (container.clientWidth > 0 && container.clientHeight > 0) {
          fitAddon.fit();
          if (term.cols === 0 || term.rows === 0) {
            term.resize(Math.max(term.cols, 80), Math.max(term.rows, 24));
          }
        }
      } catch (e) {}
    };
    if (typeof window !== 'undefined') {
      window.addEventListener('resize', handleWindowResize);
    }

    // Initial write if output already present
    if (output) {
      term.reset();
      term.write('\x1b[?25l' + output, () => {
        if (!userScrolledUpRef.current) {
          term.scrollToBottom();
        }
      });
      lastWrittenOutputRef.current = output;
    } else if (isLoading) {
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
  }, [isExpanded, sendAgentPaneInput, sendAgentPaneResize]);

  // Update terminal instance with active theme's terminal palette (REQ-THEME-EXTERNALS)
  useEffect(() => {
    if (terminalRef.current) {
      terminalRef.current.options.theme = theme.terminal;
    }
  }, [theme]);

  // Feed incoming ANSI output into terminal
  useEffect(() => {
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
  }, [output]);

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

  const isStopped = runtimeStatus === 'stopped' || runtimeStatus === 'failed';
  const isUpdatingOrRunning = Boolean(isFetching || runtimeStatus === 'running' || runtimeStatus === 'active');
  const intervalLabel = !agentInstanceId || isStopped || isActiveTab === false ? 'paused' : isExpanded ? '500ms continuous' : '5m';

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
          {/* Status indicator dot (pulsing green if updating/running) */}
          <span
            data-debug-id="agent-pane-status-dot"
            title={isUpdatingOrRunning ? 'Running / updating' : (isStopped ? 'Stopped' : 'Idle')}
            className={`h-2 w-2 rounded-full ${
              isUpdatingOrRunning
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
            className="rounded bg-neutral-soft px-1.5 py-0.5 text-[10px] font-mono text-muted"
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
            onClick={() => refetch()}
            disabled={isLoading || isFetching}
            className="grid h-6 w-6 place-items-center rounded text-muted hover:bg-neutral-soft hover:text-primary disabled:cursor-not-allowed disabled:opacity-40"
          >
            <Icon name="refresh" size={12} className={isFetching ? 'animate-spin' : ''} />
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

      {/* Interactive xterm terminal container */}
      <style>{`
        .xterm-cursor-layer, .xterm-cursor { display: none !important; }
      `}</style>
      <div
        ref={terminalContainerRef}
        data-debug-id="agent-pane-terminal"
        onClick={() => terminalRef.current?.focus()}
        tabIndex={0}
        role="region"
        aria-label="Interactive Terminal"
        style={{ backgroundColor: theme.terminal.background }}
        className="chat-scrollbar relative min-h-[280px] h-[280px] sm:min-h-[360px] sm:h-[360px] max-h-[280px] sm:max-h-[420px] w-full overflow-hidden p-2 font-mono text-xs cursor-text touch-manipulation focus:outline-none [&_.xterm-cursor-layer]:!hidden [&_.xterm-cursor]:!hidden"
      />

      {/* Accessible fallback & static verification pre element */}
      <pre
        ref={preRef}
        onScroll={handleScroll}
        data-debug-id="agent-pane-output"
        aria-hidden="true"
        className="sr-only chat-scrollbar max-h-[280px] sm:max-h-[420px] overflow-auto whitespace-pre-wrap p-3 font-mono text-xs leading-5 text-primary"
      >
        {output || (isLoading ? 'Loading terminal output…' : '')}
      </pre>
    </div>
  );
}

export default AgentPaneComposerPanel;
