import { useState } from 'react';
import { useDispatch } from 'react-redux';
import { useListShellsQuery } from '../../api/endpoints/shells';
import type { ShellSession, ShellSessionKind, ShellSessionStatus } from '../../api/endpoints/shells';
import { TOUCH_TARGET_CLASS } from '../shell/responsive';
import { NewShellDialog } from './NewShellDialog';
import { ShellTerminalPane } from './ShellTerminalPane';
import { ShellLogViewer } from './ShellLogViewer';
import { openTab } from '../../store/previewTabsSlice';

interface ShellsPanelProps {
  // Empty means "every chain": the panel lists unscoped, and new shells are then
  // tagged with whichever chain the main view has focused (see NewShellDialog).
  chainId?: string;
  bridgeId?: string;
  // T11-UI-1: true when the panel IS the whole surface (the sidebar's Shells tab)
  // rather than a section appended below other content (the chain overview). The
  // section form keeps the rule that separates it from what sits above it; the
  // standalone form takes the same shape as its peer tab, ShellJobsPanel.
  standalone?: boolean;
  // Accepted for parity with the sibling sidebar panels. The layout is responsive
  // through CSS alone (table at sm+, cards below), so nothing branches on it.
  isMobile?: boolean;
}

// T11-UI-5: a session is previewable exactly when the hub has a live port to proxy.
export function canPreview(session: ShellSession): boolean {
  return session.kind === 'server' && session.status === 'running' && session.server_port > 0;
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

function previewTitle(session: ShellSession): string {
  return canPreview(session)
    ? 'Open in the preview sidebar'
    : `Preview needs a running server with a port (${session.status}${session.server_port > 0 ? '' : ' · no port'})`;
}

// The row's own identity, shared by the table and the card list so the two views
// can never drift apart on what a session is called.
function SessionTitle({ session }: { session: ShellSession }) {
  return (
    <>
      <div className="truncate font-medium text-primary">
        {session.label || session.cmd || (
          <span className="font-mono text-[10px] text-faint">{session.session_id.slice(0, 12)}…</span>
        )}
      </div>
      {session.label && session.cmd && (
        <div className="truncate font-mono text-[10px] text-faint">{session.cmd}</div>
      )}
    </>
  );
}

function StatusCell({ session }: { session: ShellSession }) {
  return (
    <div className="flex items-center gap-1.5">
      <span className={`h-2 w-2 shrink-0 rounded-full ${statusDotClass(session.status)}`} title={session.status} />
      <span className="text-[10px] text-muted">{session.status}</span>
    </div>
  );
}

function KindBadge({ session }: { session: ShellSession }) {
  return (
    <span
      className={`rounded px-1.5 py-0.5 text-[10px] font-semibold ${KIND_BADGE_COLORS[session.kind] ?? 'bg-neutral-soft text-muted'}`}
    >
      {session.kind}
    </span>
  );
}

// `touch` widens the hit area to the 44px minimum for the card list; the table
// variant stays compact because a pointer is already precise.
function PreviewButton({
  session,
  onOpen,
  touch = false,
}: {
  session: ShellSession;
  onOpen: () => void;
  touch?: boolean;
}) {
  return (
    <button
      type="button"
      data-debug-id={`shells-panel-open-preview-${session.session_id}`}
      disabled={!canPreview(session)}
      title={previewTitle(session)}
      // The row itself is clickable; don't also fire its handler.
      onClick={(e) => { e.stopPropagation(); onOpen(); }}
      className={`rounded border border-subtle text-[10px] font-semibold text-accent hover:bg-accent/10 disabled:cursor-not-allowed disabled:border-subtle/50 disabled:text-faint disabled:hover:bg-transparent ${
        touch ? `${TOUCH_TARGET_CLASS} inline-flex items-center justify-center px-3` : 'px-2 py-0.5'
      }`}
    >
      Open Preview
    </button>
  );
}

type ActivePane =
  | { type: 'terminal'; session: ShellSession }
  | { type: 'log'; session: ShellSession }
  | null;

export function ShellsPanel({ chainId, bridgeId, standalone = false, isMobile = false }: ShellsPanelProps) {
  void isMobile;

  const dispatch = useDispatch();
  const [showNewShell, setShowNewShell] = useState(false);
  const [activePane, setActivePane] = useState<ActivePane>(null);

  const { data, isFetching, refetch } = useListShellsQuery(
    { chainId: chainId || undefined },
    { pollingInterval: 5000, refetchOnMountOrArgChange: true },
  );

  const sessions = data?.sessions ?? [];

  // Previewable servers open in the right-hand sidebar rather than an inline pane,
  // so the preview survives navigating away from this table.
  const handleRowClick = (session: ShellSession) => {
    if (
      (session.kind === 'interactive' || session.kind === 'agent') &&
      (session.status === 'running' || session.status === 'starting')
    ) {
      setActivePane({ type: 'terminal', session });
    } else if (canPreview(session)) {
      dispatch(openTab(session));
    } else {
      setActivePane({ type: 'log', session });
    }
  };

  const handleNewShellCreated = (_sessionId: string) => {
    void refetch();
    // The list re-reads rather than auto-opening a pane; the new row appears with
    // its own controls.
  };

  // Standalone (sidebar tab) takes the same shape as its peer tab ShellJobsPanel:
  // a fixed header over one scrolling body. The section form keeps its top rule and
  // flows with the page it is appended to.
  const wrapperCls = standalone
    ? 'relative flex h-full min-h-0 w-full flex-col bg-surface'
    : 'mt-4 border-t border-subtle pt-4';
  const headerCls = standalone
    ? 'flex shrink-0 items-center justify-between gap-2 border-b border-subtle px-3 py-1.5'
    : 'flex items-center justify-between gap-2 px-4 py-2 sm:px-6';
  const bodyCls = standalone ? 'min-h-0 flex-1 overflow-y-auto p-3' : 'px-4 sm:px-6';

  return (
    <div data-debug-id="shells-panel" className={wrapperCls}>
      {/* Shells header */}
      <div className={headerCls}>
        <h3 className="text-xs font-bold uppercase tracking-wider text-muted">
          Shells {sessions.length > 0 ? `(${sessions.length})` : ''}
        </h3>
        <div className="flex items-center gap-2">
          {isFetching && (
            <span className="text-[10px] text-faint">refreshing…</span>
          )}
          {/* T11-UI-2: the bridge is chosen inside the dialog now, so there is no
              raw-id field here and the button is never gated on one. */}
          <button
            type="button"
            data-debug-id="shells-panel-new-shell-btn"
            onClick={() => setShowNewShell(true)}
            title="Open new shell"
            className={`${TOUCH_TARGET_CLASS} inline-flex items-center justify-center rounded border border-accent/50 bg-accent/10 px-2.5 text-xs font-semibold text-accent hover:bg-accent/20`}
          >
            + New Shell
          </button>
        </div>
      </div>

      {/* Sessions */}
      <div className={bodyCls}>
        {sessions.length === 0 ? (
          <div className="rounded-lg border border-dashed border-subtle p-4 text-center text-xs text-muted">
            {chainId ? 'No shell sessions in this chain.' : 'No shell sessions yet.'} Click "+ New Shell" to start one.
          </div>
        ) : (
          <>
            {/* Mobile widths: cards, so nothing has to scroll sideways and every
                control clears the 44px touch target. Mirrors ShellJobsPanel's list.
                The md split is deliberate — it is where useIsMobile() (<=767px, the
                app's one mobile boundary) flips, so this panel and PreviewSidebar
                change shape at the same width. */}
            <div data-debug-id="shells-panel-cards" className="space-y-2 md:hidden">
              {sessions.map((session) => (
                <div
                  key={session.session_id}
                  data-debug-id={`shells-panel-card-${session.session_id}`}
                  role="button"
                  tabIndex={0}
                  onClick={() => handleRowClick(session)}
                  onKeyDown={(e) => { if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); handleRowClick(session); } }}
                  className="rounded-xl border border-subtle bg-surface-raised p-3 text-xs transition-colors hover:bg-neutral-soft"
                >
                  <div className="flex items-start justify-between gap-2">
                    <div className="min-w-0 flex-1"><SessionTitle session={session} /></div>
                    <KindBadge session={session} />
                  </div>
                  <div className="mt-2 flex items-center justify-between gap-2">
                    <div className="flex items-center gap-3 text-[10px] text-faint">
                      <StatusCell session={session} />
                      <span>{session.started_at ? relativeTime(session.started_at) : '—'}</span>
                      <span>{session.server_port > 0 ? `:${session.server_port}` : '—'}</span>
                    </div>
                    {session.kind === 'server' ? (
                      <PreviewButton session={session} onOpen={() => dispatch(openTab(session))} touch />
                    ) : null}
                  </div>
                </div>
              ))}
            </div>

            {/* Pointer widths: the denser table. */}
            <table data-debug-id="shells-panel-table" className="hidden w-full text-xs md:table">
              <thead>
                <tr className="border-b border-subtle text-left text-[10px] font-semibold uppercase tracking-wider text-faint">
                  <th className="pb-1.5 pr-3">Status</th>
                  <th className="pb-1.5 pr-3">Kind</th>
                  <th className="pb-1.5 pr-3">Label / Command</th>
                  <th className="pb-1.5 pr-3">Uptime</th>
                  <th className="pb-1.5 pr-3">Port</th>
                  <th className="pb-1.5">Preview</th>
                </tr>
              </thead>
              <tbody>
                {sessions.map((session) => (
                  <tr
                    key={session.session_id}
                    data-debug-id={`shells-panel-row-${session.session_id}`}
                    onClick={() => handleRowClick(session)}
                    className="cursor-pointer border-b border-subtle/50 transition-colors hover:bg-surface-raised/60"
                  >
                    <td className="py-2 pr-3"><StatusCell session={session} /></td>
                    <td className="py-2 pr-3"><KindBadge session={session} /></td>
                    <td className="max-w-[200px] py-2 pr-3"><SessionTitle session={session} /></td>
                    <td className="py-2 pr-3 text-faint">
                      {session.started_at ? relativeTime(session.started_at) : '—'}
                    </td>
                    <td className="py-2 pr-3 text-faint">
                      {session.server_port > 0 ? `:${session.server_port}` : '—'}
                    </td>
                    <td className="py-2">
                      {session.kind === 'server' ? (
                        <PreviewButton session={session} onOpen={() => dispatch(openTab(session))} />
                      ) : (
                        <span className="text-faint">—</span>
                      )}
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </>
        )}

        {/* Active pane */}
        {activePane && (
          <div className="mt-3">
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
          </div>
        )}
      </div>

      {/* New shell dialog */}
      {showNewShell && (
        <NewShellDialog
          bridgeId={bridgeId}
          chainId={chainId}
          onClose={() => setShowNewShell(false)}
          onCreated={handleNewShellCreated}
        />
      )}
    </div>
  );
}
