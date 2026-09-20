import { useState } from 'react';
import { useListShellsQuery } from '../../api/endpoints/shells';
import type { ShellSession, ShellSessionKind, ShellSessionStatus } from '../../api/endpoints/shells';
import { NewShellDialog } from './NewShellDialog';
import { ShellTerminalPane } from './ShellTerminalPane';
import { ShellLogViewer } from './ShellLogViewer';
import { ShellPreviewPanel } from './ShellPreviewPanel';

interface ShellsPanelProps {
  chainId: string;
  bridgeId?: string;
}

const KIND_BADGE_COLORS: Record<ShellSessionKind, string> = {
  agent: 'bg-accent/20 text-accent',
  interactive: 'bg-success/20 text-success',
  server: 'bg-warning/20 text-warning',
  command: 'bg-neutral-soft text-muted',
};

function statusDotClass(status: ShellSessionStatus): string {
  switch (status) {
    case 'running':
      return 'bg-success animate-pulse';
    case 'starting':
      return 'bg-warning animate-pulse';
    case 'killed':
    case 'failed':
      return 'bg-danger';
    case 'exited':
    default:
      return 'bg-faint';
  }
}

function relativeTime(iso: string): string {
  if (!iso) return '';
  const diff = Math.floor((Date.now() - new Date(iso).getTime()) / 1000);
  if (diff < 60) return `${diff}s`;
  if (diff < 3600) return `${Math.floor(diff / 60)}m`;
  return `${Math.floor(diff / 3600)}h`;
}

type ActivePane =
  | { type: 'terminal'; session: ShellSession }
  | { type: 'log'; session: ShellSession }
  | { type: 'preview'; session: ShellSession }
  | null;

export function ShellsPanel({ chainId, bridgeId }: ShellsPanelProps) {
  const [showNewShell, setShowNewShell] = useState(false);
  const [activePane, setActivePane] = useState<ActivePane>(null);
  const [selectedBridgeId, setSelectedBridgeId] = useState(bridgeId || '');

  const { data, isFetching, refetch } = useListShellsQuery(
    { chainId },
    { pollingInterval: 5000, refetchOnMountOrArgChange: true },
  );

  const sessions = data?.sessions ?? [];

  const handleRowClick = (session: ShellSession) => {
    if (
      (session.kind === 'interactive' || session.kind === 'agent') &&
      (session.status === 'running' || session.status === 'starting')
    ) {
      setActivePane({ type: 'terminal', session });
    } else if (
      session.kind === 'server' &&
      session.preview_enabled &&
      session.status === 'running'
    ) {
      setActivePane({ type: 'preview', session });
    } else {
      setActivePane({ type: 'log', session });
    }
  };

  const handleNewShellCreated = (sessionId: string) => {
    void refetch();
    // Auto-open pane for newly created sessions via refresh
  };

  const effectiveBridgeId = selectedBridgeId || bridgeId || '';

  return (
    <div data-debug-id="shells-panel" className="mt-4 border-t border-subtle pt-4">
      {/* Shells header */}
      <div className="flex items-center justify-between px-4 py-2 sm:px-6">
        <h3 className="text-xs font-bold uppercase tracking-wider text-muted">
          Shells {sessions.length > 0 ? `(${sessions.length})` : ''}
        </h3>
        <div className="flex items-center gap-2">
          {isFetching && (
            <span className="text-[10px] text-faint">refreshing…</span>
          )}
          {!effectiveBridgeId && (
            <input
              type="text"
              placeholder="Bridge ID for new shell"
              value={selectedBridgeId}
              onChange={(e) => setSelectedBridgeId(e.target.value)}
              className="rounded border border-subtle bg-surface px-2 py-1 text-[10px] placeholder:text-faint focus:outline-none focus:ring-1 focus:ring-accent w-48"
            />
          )}
          <button
            type="button"
            data-debug-id="shells-panel-new-shell-btn"
            onClick={() => setShowNewShell(true)}
            disabled={!effectiveBridgeId}
            title={!effectiveBridgeId ? 'Enter a bridge ID first' : 'Open new shell'}
            className="rounded border border-accent/50 bg-accent/10 px-2.5 py-1 text-xs font-semibold text-accent hover:bg-accent/20 disabled:cursor-not-allowed disabled:opacity-50"
          >
            + New Shell
          </button>
        </div>
      </div>

      {/* Sessions table */}
      <div className="px-4 sm:px-6">
        {sessions.length === 0 ? (
          <div className="rounded-lg border border-dashed border-subtle p-4 text-center text-xs text-muted">
            No shell sessions in this chain. Click "+ New Shell" to start one.
          </div>
        ) : (
          <div className="overflow-x-auto">
            <table className="w-full text-xs">
              <thead>
                <tr className="border-b border-subtle text-left text-[10px] font-semibold uppercase tracking-wider text-faint">
                  <th className="pb-1.5 pr-3">Status</th>
                  <th className="pb-1.5 pr-3">Kind</th>
                  <th className="pb-1.5 pr-3">Label / Command</th>
                  <th className="pb-1.5 pr-3">Uptime</th>
                  <th className="pb-1.5">Port</th>
                </tr>
              </thead>
              <tbody>
                {sessions.map((session) => (
                  <tr
                    key={session.session_id}
                    data-debug-id={`shells-panel-row-${session.session_id}`}
                    onClick={() => handleRowClick(session)}
                    className="cursor-pointer border-b border-subtle/50 hover:bg-surface-raised/60 transition-colors"
                  >
                    <td className="py-2 pr-3">
                      <div className="flex items-center gap-1.5">
                        <span
                          className={`h-2 w-2 rounded-full ${statusDotClass(session.status)}`}
                          title={session.status}
                        />
                        <span className="text-[10px] text-muted">{session.status}</span>
                      </div>
                    </td>
                    <td className="py-2 pr-3">
                      <span
                        className={`rounded px-1.5 py-0.5 text-[10px] font-semibold ${KIND_BADGE_COLORS[session.kind] ?? 'bg-neutral-soft text-muted'}`}
                      >
                        {session.kind}
                      </span>
                    </td>
                    <td className="py-2 pr-3 max-w-[200px]">
                      <div className="truncate text-primary font-medium">
                        {session.label || session.cmd || (
                          <span className="font-mono text-faint text-[10px]">
                            {session.session_id.slice(0, 12)}…
                          </span>
                        )}
                      </div>
                      {session.label && session.cmd && (
                        <div className="truncate text-[10px] text-faint font-mono">{session.cmd}</div>
                      )}
                    </td>
                    <td className="py-2 pr-3 text-faint">
                      {session.started_at ? relativeTime(session.started_at) : '—'}
                    </td>
                    <td className="py-2 text-faint">
                      {session.server_port > 0 ? `:${session.server_port}` : '—'}
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
      </div>

      {/* Active pane */}
      {activePane && (
        <div className="mt-3 px-4 sm:px-6">
          {activePane.type === 'terminal' && (
            <ShellTerminalPane
              session={activePane.session}
              onClose={() => setActivePane(null)}
            />
          )}
          {activePane.type === 'log' && (
            <ShellLogViewer
              session={activePane.session}
              onClose={() => setActivePane(null)}
            />
          )}
          {activePane.type === 'preview' && (
            <ShellPreviewPanel
              session={activePane.session}
              onClose={() => setActivePane(null)}
            />
          )}
        </div>
      )}

      {/* New shell dialog */}
      {showNewShell && (
        <NewShellDialog
          bridgeId={effectiveBridgeId}
          chainId={chainId}
          onClose={() => setShowNewShell(false)}
          onCreated={handleNewShellCreated}
        />
      )}
    </div>
  );
}
