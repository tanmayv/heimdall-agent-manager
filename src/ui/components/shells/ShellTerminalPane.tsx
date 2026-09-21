import { useEffect, useRef } from 'react';
import type { Terminal as TerminalType } from '@xterm/xterm';
import type { FitAddon as FitAddonType } from '@xterm/addon-fit';
import * as xtermModule from '@xterm/xterm';
import * as fitAddonModule from '@xterm/addon-fit';

const xtermObj = xtermModule as Record<string, any>;
const Terminal = (xtermObj.Terminal || xtermObj['default']?.Terminal || xtermObj['default']) as typeof TerminalType;
const fitAddonObj = fitAddonModule as Record<string, any>;
const FitAddon = (fitAddonObj.FitAddon || fitAddonObj['default']?.FitAddon || fitAddonObj['default']) as typeof FitAddonType;

import { useTheme } from '../../store/themeSlice';
import Icon from '../Icon';
import { useShellPaneSubscription } from '../../hooks/useShellPaneSubscription';
import {
  useKillShellMutation,
  useRestartShellMutation,
  useSendShellInputMutation,
  useSendShellResizeMutation,
  useSignalShellMutation,
} from '../../api/endpoints/shells';
import type { ShellSession } from '../../api/endpoints/shells';

interface ShellTerminalPaneProps {
  session: ShellSession;
  onClose?: () => void;
}

function relativeTime(iso: string): string {
  if (!iso) return '';
  const diff = Math.floor((Date.now() - new Date(iso).getTime()) / 1000);
  if (diff < 60) return `${diff}s`;
  if (diff < 3600) return `${Math.floor(diff / 60)}m`;
  return `${Math.floor(diff / 3600)}h`;
}

export function ShellTerminalPane({ session, onClose }: ShellTerminalPaneProps) {
  const { theme } = useTheme();
  const terminalContainerRef = useRef<HTMLDivElement | null>(null);
  const terminalRef = useRef<TerminalType | null>(null);
  const fitAddonRef = useRef<FitAddonType | null>(null);

  const [killShell, killState] = useKillShellMutation();
  const [restartShell, restartState] = useRestartShellMutation();
  const [signalShell, signalState] = useSignalShellMutation();

  const isTerminal = session.kind === 'interactive' || session.kind === 'agent';
  const isRunning = session.status === 'running' || session.status === 'starting';

  // Output arrives by polled capture with since_hash diffing — the model the agent pane
  // uses — not by a PTY output stream. See useShellPaneSubscription.
  const paneSessionId = isTerminal && isRunning ? session.session_id : null;
  const { output, isFetching, lastUpdatedAt, polling, refetch } = useShellPaneSubscription({
    sessionId: paneSessionId,
    status: session.status,
  });

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
    terminalRef.current = term;
    fitAddonRef.current = fitAddon;

    // Keystrokes go to the HTTP input route, then a debounced refetch pulls the echo back
    // so typing feels immediate between poll ticks.
    const dataDisposable = term.onData((data) => {
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
    });

    const resizeDisposable = term.onResize(({ cols, rows }) => {
      const targetId = sessionIdRef.current;
      if (targetId) {
        sendShellResize({ sessionId: targetId, rows, cols }).catch(() => {});
      }
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
          const targetId = sessionIdRef.current;
          if (targetId) {
            sendShellResize({ sessionId: targetId, rows: term.rows, cols: term.cols }).catch(() => {});
          }
        }
      } catch { /* ignore */ }
    };

    dispatchResize();
    const timer = setTimeout(() => dispatchResize(), 150);

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

    // Paint whatever screen we already hold, so a remount is not blank until the next tick.
    if (output) {
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
  }, [sendShellInput, sendShellResize]);

  // Repaint on a changed screen snapshot. An unchanged poll leaves `output`
  // referentially identical, so this effect short-circuits and xterm is never touched.
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

  useEffect(() => {
    if (terminalRef.current) {
      terminalRef.current.options.theme = theme.terminal;
    }
  }, [theme]);

  const handleKill = () => {
    killShell({ sessionId: session.session_id }).catch(() => {});
  };

  const handleRestart = () => {
    restartShell({ sessionId: session.session_id }).catch(() => {});
  };

  const handleSigint = () => {
    signalShell({ sessionId: session.session_id, signal: 2 }).catch(() => {});
  };

  const statusDotClass =
    session.status === 'running'
      ? 'bg-success animate-pulse'
      : session.status === 'starting'
      ? 'bg-warning animate-pulse'
      : session.status === 'killed' || session.status === 'failed'
      ? 'bg-danger'
      : 'bg-faint';

  return (
    <div
      data-debug-id={`shell-terminal-pane-${session.session_id}`}
      className="overflow-hidden rounded-xl border border-subtle bg-surface"
    >
      {/* Header */}
      <div className="flex items-center justify-between border-b border-subtle bg-surface-raised px-3 py-1.5 text-xs text-muted">
        <div className="flex items-center gap-2">
          <span
            className={`h-2 w-2 rounded-full ${statusDotClass}`}
            title={session.status}
          />
          <span className="font-semibold text-primary truncate max-w-[180px]">
            {session.label || session.cmd || session.session_id}
          </span>
          <span className="rounded bg-neutral-soft px-1.5 py-0.5 text-[10px] font-mono text-muted">
            {session.status}
          </span>
          {session.started_at && (
            <span className="text-[10px] text-faint">
              up {relativeTime(session.started_at)}
            </span>
          )}
          {polling && lastUpdatedAt !== null ? (
            <span className="text-[10px] text-success">● live</span>
          ) : polling ? (
            <span className="text-[10px] text-faint">○ connecting…</span>
          ) : (
            <span className="text-[10px] text-faint">○ paused</span>
          )}
          {isFetching && <span className="sr-only">refreshing</span>}
        </div>

        <div className="flex items-center gap-1">
          {isRunning && (
            <>
              <button
                type="button"
                title="Send SIGINT (Ctrl+C)"
                onClick={handleSigint}
                disabled={signalState.isLoading}
                className="rounded px-2 py-0.5 text-[10px] font-semibold text-warning hover:bg-warning/10 disabled:opacity-40"
              >
                SIGINT
              </button>
              <button
                type="button"
                title="Restart shell"
                onClick={handleRestart}
                disabled={restartState.isLoading}
                className="rounded px-2 py-0.5 text-[10px] font-semibold text-accent hover:bg-accent/10 disabled:opacity-40"
              >
                {restartState.isLoading ? '…' : '↺ Restart'}
              </button>
              <button
                type="button"
                title="Kill shell"
                onClick={handleKill}
                disabled={killState.isLoading}
                className="rounded px-2 py-0.5 text-[10px] font-semibold text-danger hover:bg-danger/10 disabled:opacity-40"
              >
                {killState.isLoading ? '…' : '✕ Kill'}
              </button>
            </>
          )}
          {onClose && (
            <button
              type="button"
              title="Close terminal"
              onClick={onClose}
              className="grid h-6 w-6 place-items-center rounded text-muted hover:bg-neutral-soft hover:text-primary"
            >
              <Icon name="chevron-down" size={14} />
            </button>
          )}
        </div>
      </div>

      {/* xterm container */}
      <style>{`.xterm-cursor-layer, .xterm-cursor { display: none !important; }`}</style>
      <div
        ref={terminalContainerRef}
        data-debug-id={`shell-terminal-xterm-${session.session_id}`}
        onClick={() => terminalRef.current?.focus()}
        tabIndex={0}
        role="region"
        aria-label="Shell Terminal"
        style={{ backgroundColor: theme.terminal.background }}
        className="relative h-[360px] w-full overflow-hidden p-2 font-mono text-xs cursor-text focus:outline-none"
      />
    </div>
  );
}
