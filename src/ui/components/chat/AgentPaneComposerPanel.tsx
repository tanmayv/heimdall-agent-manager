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
import Icon from '../Icon';

export interface AgentPaneComposerPanelProps {
  agentInstanceId?: string | null;
  isExpanded: boolean;
  onClose?: () => void;
  onToggleExpand?: () => void;
  isActiveTab?: boolean;
  runtimeStatus?: string;
  className?: string;
}

export function AgentPaneComposerPanel({
  agentInstanceId,
  isExpanded,
  onClose,
  onToggleExpand,
  isActiveTab = true,
  runtimeStatus,
  className = '',
}: AgentPaneComposerPanelProps) {
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

  useEffect(() => {
    agentInstanceIdRef.current = agentInstanceId;
  }, [agentInstanceId]);

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
      cursorBlink: true,
      cursorStyle: 'bar',
      fontFamily: 'ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, "Liberation Mono", "Courier New", monospace',
      fontSize: 12,
      lineHeight: 1.25,
      scrollback: 1000,
      theme: {
        background: '#09090b',
        foreground: '#e4e4e7',
        cursor: '#38bdf8',
        cursorAccent: '#09090b',
        selectionBackground: 'rgba(56, 189, 248, 0.3)',
        black: '#18181b',
        red: '#ef4444',
        green: '#22c55e',
        yellow: '#eab308',
        blue: '#3b82f6',
        magenta: '#a855f7',
        cyan: '#06b6d4',
        white: '#f4f4f5',
        brightBlack: '#71717a',
        brightRed: '#f87171',
        brightGreen: '#4ade80',
        brightYellow: '#fde047',
        brightBlue: '#60a5fa',
        brightMagenta: '#c084fc',
        brightCyan: '#22d3ee',
        brightWhite: '#ffffff',
      },
      allowProposedApi: true,
    });

    const fitAddon = new FitAddon();
    term.loadAddon(fitAddon);
    term.open(container);

    terminalRef.current = term;
    fitAddonRef.current = fitAddon;

    // Track scrolling within xterm buffer
    term.onScroll(() => {
      const buffer = term.buffer.active;
      userScrolledUpRef.current = buffer.viewportY < buffer.baseY;
    });

    // Keystroke input hook: dispatch to sendAgentPaneInput
    const dataDisposable = term.onData((data) => {
      const targetId = agentInstanceIdRef.current;
      if (targetId) {
        sendAgentPaneInput({ agentInstanceId: targetId, data }).catch(() => {});
      }
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
      term.write(output, () => {
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

  // Feed incoming ANSI output into terminal
  useEffect(() => {
    const term = terminalRef.current;
    if (!term || output === undefined) return;
    if (output === lastWrittenOutputRef.current) return;

    lastWrittenOutputRef.current = output;
    term.reset();
    term.write(output || '', () => {
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
  const intervalLabel = !agentInstanceId || isStopped || isActiveTab === false ? 'paused' : isExpanded ? '15s' : '5m';

  const handleClose = onClose || onToggleExpand;

  return (
    <div
      data-debug-id="agent-pane-composer-panel"
      className={`overflow-hidden rounded-xl border border-white/10 bg-black/40 ${className}`}
    >
      {/* Header controls */}
      <div
        data-debug-id="agent-pane-composer-header"
        className="flex items-center justify-between border-b border-white/10 bg-white/[0.03] px-3 py-1.5 text-xs text-zinc-300"
      >
        <div className="flex items-center gap-2">
          {/* Status indicator dot (pulsing green if updating/running) */}
          <span
            data-debug-id="agent-pane-status-dot"
            title={isUpdatingOrRunning ? 'Running / updating' : (isStopped ? 'Stopped' : 'Idle')}
            className={`h-2 w-2 rounded-full ${
              isUpdatingOrRunning
                ? 'bg-emerald-400 animate-pulse'
                : isStopped
                ? 'bg-zinc-600'
                : 'bg-emerald-500/70'
            }`}
          />
          <span data-debug-id="agent-pane-title" className="font-semibold text-zinc-200">
            Terminal Output
          </span>
          {/* Refresh interval tag */}
          <span
            data-debug-id="agent-pane-interval-tag"
            className="rounded bg-white/10 px-1.5 py-0.5 text-[10px] font-mono text-zinc-400"
          >
            {intervalLabel}
          </span>
        </div>

        <div className="flex items-center gap-1">
          {/* Manual refresh button */}
          <button
            type="button"
            data-debug-id="agent-pane-refresh-btn"
            title="Refresh terminal output"
            aria-label="Refresh terminal output"
            onClick={() => refetch()}
            disabled={isLoading || isFetching}
            className="grid h-6 w-6 place-items-center rounded text-zinc-400 hover:bg-white/10 hover:text-white disabled:cursor-not-allowed disabled:opacity-40"
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
              className="grid h-6 w-6 place-items-center rounded text-zinc-400 hover:bg-white/10 hover:text-white"
            >
              <Icon name="chevron-down" size={14} />
            </button>
          ) : null}
        </div>
      </div>

      {/* Interactive xterm terminal container */}
      <div
        ref={terminalContainerRef}
        data-debug-id="agent-pane-terminal"
        onClick={() => terminalRef.current?.focus()}
        tabIndex={0}
        role="region"
        aria-label="Interactive Terminal"
        className="chat-scrollbar relative h-[180px] sm:h-[260px] max-h-[180px] sm:max-h-[300px] w-full overflow-hidden p-2 font-mono text-xs cursor-text bg-[#09090b]/80 touch-manipulation focus:outline-none"
      />

      {/* Accessible fallback & static verification pre element */}
      <pre
        ref={preRef}
        onScroll={handleScroll}
        data-debug-id="agent-pane-output"
        aria-hidden="true"
        className="sr-only chat-scrollbar max-h-[180px] sm:max-h-[300px] overflow-auto whitespace-pre-wrap p-3 font-mono text-xs leading-5 text-zinc-200"
      >
        {output || (isLoading ? 'Loading terminal output…' : '')}
      </pre>
    </div>
  );
}

export default AgentPaneComposerPanel;
