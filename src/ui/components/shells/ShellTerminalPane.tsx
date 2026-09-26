import { useEffect, useRef } from 'react';
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
import {
  useSendShellInputMutation,
  useSendShellResizeMutation,
} from '../../api/endpoints/shells';
import type { ShellSession } from '../../api/endpoints/shells';

interface ShellTerminalPaneProps {
  session: ShellSession;
  onClose?: () => void;
}

export function ShellTerminalPane({ session }: ShellTerminalPaneProps) {
  const { theme } = useTheme();
  const terminalContainerRef = useRef<HTMLDivElement | null>(null);
  const terminalRef = useRef<TerminalType | null>(null);
  const fitAddonRef = useRef<FitAddonType | null>(null);

  const isTerminal = session.kind === 'interactive' || session.kind === 'agent';
  const isRunning = session.status === 'running' || session.status === 'starting';

  // Output arrives by polled capture with since_hash diffing — the model the agent pane
  // uses — not by a PTY output stream. See useShellPaneSubscription.
  const paneSessionId = isTerminal && isRunning ? session.session_id : null;
  const { output, isLoading, refetch } = useShellPaneSubscription({
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

  return (
    <div
      data-debug-id={`shell-terminal-pane-${session.session_id}`}
      className="relative flex flex-col flex-1 h-full min-h-0 w-full overflow-hidden bg-canvas"
    >
      {!output && (session.status === 'starting' || isLoading) && (
        <div
          data-debug-id={`shell-terminal-loading-${session.session_id}`}
          className="absolute inset-0 z-10 flex flex-col items-center justify-center gap-2 bg-canvas/90 text-xs text-muted pointer-events-none"
        >
          <Icon name="refresh" className="animate-spin text-accent" size={18} />
          <span>Connecting to terminal…</span>
        </div>
      )}

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
        className="relative flex-1 min-h-0 w-full overflow-hidden p-2 font-mono text-xs cursor-text focus:outline-none"
      />
    </div>
  );
}
