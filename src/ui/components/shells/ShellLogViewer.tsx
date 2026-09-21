import { useEffect, useRef, useState } from 'react';
import {
  useGetShellLogQuery,
  useKillShellMutation,
  useRestartShellMutation,
} from '../../api/endpoints/shells';
import type { ShellSession } from '../../api/endpoints/shells';

interface ShellLogViewerProps {
  session: ShellSession;
  onClose?: () => void;
}

const PAGE_SIZE = 100;

export function ShellLogViewer({ session, onClose }: ShellLogViewerProps) {
  const [offset, setOffset] = useState(0);
  const [grep, setGrep] = useState('');
  const [grepInput, setGrepInput] = useState('');
  const logEndRef = useRef<HTMLDivElement | null>(null);

  const isRunning = session.status === 'running' || session.status === 'starting';

  const { data, isFetching, refetch } = useGetShellLogQuery(
    { sessionId: session.session_id, offset, limit: PAGE_SIZE, grep: grep || undefined },
    { pollingInterval: isRunning ? 1000 : 0 },
  );

  const [killShell, killState] = useKillShellMutation();
  const [restartShell, restartState] = useRestartShellMutation();

  // Auto-scroll to bottom when new data arrives (only when at offset 0)
  useEffect(() => {
    if (offset === 0) {
      logEndRef.current?.scrollIntoView({ block: 'end' });
    }
  }, [data, offset]);

  const handleLoadEarlier = () => {
    setOffset((prev) => Math.max(0, prev - PAGE_SIZE));
  };

  const handleGrepSubmit = (e: React.FormEvent) => {
    e.preventDefault();
    setGrep(grepInput);
    setOffset(0);
  };

  const handleKill = () => {
    killShell({ sessionId: session.session_id }).catch(() => {});
  };

  const handleRestart = () => {
    restartShell({ sessionId: session.session_id }).catch(() => {});
  };

  const lines = data?.lines ?? [];
  const total = data?.total ?? 0;

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
      data-debug-id={`shell-log-viewer-${session.session_id}`}
      className="overflow-hidden rounded-xl border border-subtle bg-surface"
    >
      {/* Header */}
      <div className="flex items-center justify-between border-b border-subtle bg-surface-raised px-3 py-1.5 text-xs text-muted">
        <div className="flex items-center gap-2">
          <span className={`h-2 w-2 rounded-full ${statusDotClass}`} title={session.status} />
          <span className="font-semibold text-primary truncate max-w-[180px]">
            {session.label || session.cmd || session.session_id}
          </span>
          <span className="rounded bg-neutral-soft px-1.5 py-0.5 text-[10px] font-mono text-muted">
            {session.kind} · {session.status}
          </span>
          {total > 0 && (
            <span className="text-[10px] text-faint">{total} lines</span>
          )}
        </div>

        <div className="flex items-center gap-1">
          {isRunning && (
            <>
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
          <button
            type="button"
            title="Refresh log"
            onClick={() => refetch()}
            disabled={isFetching}
            className="grid h-6 w-6 place-items-center rounded text-muted hover:bg-neutral-soft hover:text-primary disabled:opacity-40"
            aria-label="Refresh log"
          >
            {isFetching ? '…' : '↻'}
          </button>
          {onClose && (
            <button
              type="button"
              title="Close log viewer"
              onClick={onClose}
              className="grid h-6 w-6 place-items-center rounded text-muted hover:bg-neutral-soft hover:text-primary"
            >
              ×
            </button>
          )}
        </div>
      </div>

      {/* Grep filter */}
      <form
        onSubmit={handleGrepSubmit}
        className="flex items-center gap-2 border-b border-subtle px-3 py-1.5"
      >
        <input
          type="text"
          placeholder="Filter (grep)…"
          value={grepInput}
          onChange={(e) => setGrepInput(e.target.value)}
          className="flex-1 rounded border border-subtle bg-surface px-2 py-1 text-xs text-primary placeholder:text-faint focus:outline-none focus:ring-1 focus:ring-accent"
        />
        <button
          type="submit"
          className="rounded bg-neutral-soft px-2 py-1 text-xs font-semibold text-primary hover:opacity-80"
        >
          Apply
        </button>
        {grep && (
          <button
            type="button"
            onClick={() => { setGrep(''); setGrepInput(''); setOffset(0); }}
            className="rounded px-2 py-1 text-xs text-faint hover:text-primary"
          >
            Clear
          </button>
        )}
      </form>

      {/* Log output */}
      <div className="h-[320px] overflow-y-auto bg-surface p-2 font-mono text-[11px] text-primary">
        {offset > 0 && (
          <button
            type="button"
            onClick={handleLoadEarlier}
            className="mb-2 w-full rounded border border-dashed border-subtle py-1 text-xs text-muted hover:text-primary"
          >
            ↑ Load earlier (offset {Math.max(0, offset - PAGE_SIZE)}–{offset})
          </button>
        )}

        {lines.length === 0 && !isFetching && (
          <div className="text-xs text-faint italic">
            {grep ? 'No matching lines.' : 'No log output yet.'}
          </div>
        )}

        {lines.map((line, i) => (
          <div key={`${offset}-${i}`} className="whitespace-pre-wrap break-all leading-5">
            {line}
          </div>
        ))}

        <div ref={logEndRef} />
      </div>
    </div>
  );
}
