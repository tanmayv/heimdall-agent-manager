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
import { useShellStream } from './useShellStream';
import { useKillShellMutation, useRestartShellMutation, useSignalShellMutation } from '../../api/endpoints/shells';
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

  const { connected, sendInput, sendResize } = useShellStream({
    sessionId: isTerminal && isRunning ? session.session_id : null,
    onOutput: (bytes) => {
      const term = terminalRef.current;
      if (!term) return;
      term.write(bytes);
    },
    onStatus: (status) => {
      const term = terminalRef.current;
      if (!term) return;
      term.write(`\r\n\x1b[90m[session ${status}]\x1b[0m\r\n`);
    },
    onError: (msg) => {
      const term = terminalRef.current;
      if (!term) return;
      term.write(`\r\n\x1b[31m[stream error: ${msg}]\x1b[0m\r\n`);
    },
  });

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

    const dataDisposable = term.onData((data) => {
      sendInput(data);
    });

    const resizeDisposable = term.onResize(({ cols, rows }) => {
      sendResize(rows, cols);
    });

    const dispatchResize = () => {
      try {
        if (container.clientWidth > 0 && container.clientHeight > 0) {
          fitAddon.fit();
          if (term.cols === 0 || term.rows === 0) {
            term.resize(Math.max(term.cols, 80), Math.max(term.rows, 24));
          }
          sendResize(term.rows, term.cols);
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

    return () => {
      window.removeEventListener('resize', handleWindowResize);
      clearTimeout(timer);
      resizeObserver.disconnect();
      dataDisposable.dispose();
      resizeDisposable.dispose();
      term.dispose();
      terminalRef.current = null;
      fitAddonRef.current = null;
    };
  }, [sendInput, sendResize]);

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
          {connected ? (
            <span className="text-[10px] text-success">● live</span>
          ) : (
            <span className="text-[10px] text-faint">○ connecting…</span>
          )}
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
