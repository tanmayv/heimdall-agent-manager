import { useState } from 'react';
import { useDispatch } from 'react-redux';
import { useKillShellMutation, useListShellsQuery } from '../../api/endpoints/shells';
import type { ShellSession, ShellSessionKind, ShellSessionStatus } from '../../api/endpoints/shells';
import { IconButton, Menu } from '@ui';
import { TOUCH_TARGET_CLASS } from '../shell/responsive';
import { NewShellDialog } from './NewShellDialog';
import { ShellTerminalPane } from './ShellTerminalPane';
import { ShellLogViewer } from './ShellLogViewer';
import { SetShellPortDialog } from './SetShellPortDialog';
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
// XM-8: kind is not part of the test. Any running session that declared a port at start
// is reachable — an interactive shell started with --port 3000 included — which matches
// the backend gate in shell_session_handlers.odin and bridge_proxy_relay.odin.
export function canPreview(session: ShellSession): boolean {
  return session.status === 'running' && session.server_port > 0;
}

// XM-8: whether the access affordance APPLIES to this session at all, as opposed to
// whether it can be used right now (canPreview). The two are deliberately different:
// a session with a port that is starting or exited is TRANSIENTLY unavailable, so it
// shows a disabled PreviewButton whose title says why; a portless session shows
// nothing, because a disabled button with no action that could enable it would lie
// about being actionable.
//
// XM-9 revisits the second half, as XM-8 flagged it would, and the premise it rested
// on is now false: a port CAN be declared after start. A running portless session is
// therefore TRANSIENTLY unavailable, not permanently — the same category as a session
// whose port is declared but which has not finished starting — so it gets the same
// rendering that category already has: a disabled button saying why, with the action
// that fixes it (Set server port) in the menu on the same row.
//
// What stays unrendered is the case that is still permanent: a portless session that
// has TERMINATED. A port cannot be declared on it — the hub refuses with 409 and the
// bridge has no live record to update — so nothing about it can ever become
// reachable, and a permanently disabled control there would lie about being actionable.
export function hasAccessAffordance(session: ShellSession): boolean {
  return session.server_port > 0 || !isTerminalStatus(session);
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

// Exported alongside the predicates so the row's user-visible REASONS can be checked
// as code over the status x port matrix, not read and believed.
export function previewTitle(session: ShellSession): string {
  return canPreview(session)
    ? 'Open in the preview sidebar'
    : `Preview needs a running session with a declared port (${session.status}${session.server_port > 0 ? '' : ' · no port — set one from the row menu'})`;
}

// XM-7: a session past these statuses has no process left to signal, so Kill is a no-op
// on it. Same set PreviewSidebar calls DEAD_STATUSES (:31); kept local rather than
// exported because the two panels read it for different reasons.
const TERMINAL_STATUSES: ReadonlySet<ShellSessionStatus> = new Set<ShellSessionStatus>([
  'exited',
  'killed',
  'failed',
]);

function isTerminalStatus(session: ShellSession): boolean {
  return TERMINAL_STATUSES.has(session.status);
}

// REQ-SHELL-UI-3: the URL a human can paste into a browser tab. It is the hub's own
// preview path — the very thing the preview iframe loads (previewTabsSlice.ts:110,
// PreviewSidebar.tsx:79) — made absolute against the origin the UI is served from,
// which is the hub, so it is same-origin and needs no extra host knowledge.
// Deliberately NOT the bridge local-proxy URL documented in `ham-ctl shell --help`:
// that one only resolves from a process running ON the bridge host and would be dead
// text in a browser, so it is not offered here.
function previewAccessUrl(session: ShellSession): string {
  const origin = typeof window === 'undefined' ? '' : window.location.origin;
  return `${origin}/api/v1/preview/${encodeURIComponent(session.session_id)}/`;
}

function copyUrlTitle(session: ShellSession): string {
  // Reuses the existing reason string rather than inventing a second wording for the
  // same condition — a disabled item that says why beats a hidden one.
  return canPreview(session)
    ? 'Copy the browser URL for this server'
    : `No access URL yet · ${previewTitle(session)}`;
}

// XM-9: the port is a property of a LIVE session — the bridge only holds a record to
// update while the process is running — so the item is offered on running and starting
// sessions and disabled once one is terminal, matching the hub's own 409.
export function setPortTitle(session: ShellSession): string {
  if (isTerminalStatus(session)) return `Already ${session.status} — a port cannot be declared on it`;
  return session.server_port > 0
    ? `Change or clear the declared port (currently ${session.server_port})`
    : 'Declare the port a server inside this session is listening on';
}

function killTitle(session: ShellSession): string {
  return isTerminalStatus(session)
    ? `Already ${session.status} — nothing to kill`
    : 'Terminate this session (asks first)';
}

type CopyOutcome = { ok: boolean; url: string } | null;

// XM-7: the per-row overflow menu, ONE component rendered by both the card list and the
// table so the two views cannot drift apart on what a row can do.
//
// The popover itself is not hand-rolled: `Menu` (ui/composites/Menu.tsx) already
// implements the ARIA menu-button pattern — roving focus, Arrow/Home/End, Escape closes
// and restores focus to the trigger, Tab closes, outside mousedown closes.
//
// Every interactive edge stops propagation, because the row around this menu is itself
// clickable (handleRowClick) and keyboard-activatable on Enter/Space: without the guards
// a menu click would ALSO open a pane, and Enter on a menu item would bubble into the
// card's own Enter handler. The wrapper catches both event kinds for the whole subtree;
// the trigger and each item stop them at the source as well.
function ShellRowMenu({
  session,
  onViewStdout,
  touch = false,
  side = 'bottom',
}: {
  session: ShellSession;
  onViewStdout: () => void;
  touch?: boolean;
  side?: 'bottom' | 'top';
}) {
  const [killShell] = useKillShellMutation();
  const [copied, setCopied] = useState<CopyOutcome>(null);
  const [killError, setKillError] = useState('');
  const [portDialogOpen, setPortDialogOpen] = useState(false);

  const canCopy = canPreview(session);
  const terminal = isTerminalStatus(session);

  const handleCopy = async () => {
    const url = previewAccessUrl(session);
    // navigator.clipboard is absent in an insecure context and writeText can reject on
    // a permissions denial. Either way the user is told, and told what the URL was so
    // they can take it by hand — the failure is never swallowed.
    try {
      if (!navigator.clipboard?.writeText) throw new Error('clipboard unavailable');
      await navigator.clipboard.writeText(url);
      setCopied({ ok: true, url });
      window.setTimeout(() => setCopied((c) => (c?.ok ? null : c)), 2000);
    } catch {
      // A failure stays on screen until the next attempt: it carries the URL the user
      // now has to copy manually, so auto-dismissing it would lose the only copy.
      setCopied({ ok: false, url });
    }
  };

  const handleKill = async () => {
    // A misclick here destroys running work, so it asks first. window.confirm is the
    // established destructive-confirm idiom in this codebase (UserTokensPanel.tsx:50,
    // ProjectVcsPanel.tsx:255, ProjectFilesPanel.tsx:1172).
    if (typeof window !== 'undefined') {
      const what = session.label || session.cmd || session.session_id;
      if (!window.confirm(`Kill shell session "${what}"? The process is terminated immediately.`)) return;
    }
    setKillError('');
    try {
      // The same hook ShellLogViewer.tsx:79 uses — no second code path to the kill API.
      await killShell({ sessionId: session.session_id }).unwrap();
    } catch (err: unknown) {
      setKillError(String((err as { message?: string })?.message || 'Kill failed'));
    }
  };

  return (
    <div
      className="relative inline-flex flex-col items-end gap-1"
      // Blanket guards for the whole menu subtree: the row must not also react.
      onClick={(e) => e.stopPropagation()}
      onKeyDown={(e) => e.stopPropagation()}
    >
      <Menu
        label={`Actions for ${session.label || session.cmd || session.session_id}`}
        align="end"
        side={side}
        trigger={
          <IconButton
            icon="more-vertical"
            label="Row actions"
            variant="ghost"
            // The card list is a touch context (44px box); the table has a pointer.
            size={touch ? 'md' : 'sm'}
            data-debug-id={`shells-panel-row-menu-${session.session_id}`}
            onClick={(e) => e.stopPropagation()}
          />
        }
      >
        <Menu.Item
          data-debug-id={`shells-panel-row-menu-copy-url-${session.session_id}`}
          disabled={!canCopy}
          title={copyUrlTitle(session)}
          onClick={(e) => { e.stopPropagation(); void handleCopy(); }}
        >
          Copy access URL
        </Menu.Item>
        <Menu.Item
          data-debug-id={`shells-panel-row-menu-set-port-${session.session_id}`}
          disabled={terminal}
          title={setPortTitle(session)}
          onClick={(e) => { e.stopPropagation(); setPortDialogOpen(true); }}
        >
          {session.server_port > 0 ? 'Change server port…' : 'Set server port…'}
        </Menu.Item>
        <Menu.Item
          data-debug-id={`shells-panel-row-menu-view-stdout-${session.session_id}`}
          title="Open the stdout log for this session"
          onClick={(e) => { e.stopPropagation(); onViewStdout(); }}
        >
          View stdout
        </Menu.Item>
        <Menu.Separator />
        <Menu.Item
          data-debug-id={`shells-panel-row-menu-kill-${session.session_id}`}
          danger
          disabled={terminal}
          title={killTitle(session)}
          onClick={(e) => { e.stopPropagation(); void handleKill(); }}
        >
          Kill
        </Menu.Item>
      </Menu>

      {copied ? (
        <div
          role="status"
          data-debug-id={`shells-panel-row-menu-copy-status-${session.session_id}`}
          className={`max-w-[220px] text-right text-[10px] ${copied.ok ? 'text-success' : 'text-danger'}`}
        >
          {copied.ok ? (
            'URL copied'
          ) : (
            <>
              Copy failed — copy manually:{' '}
              <span className="select-all break-all font-mono">{copied.url}</span>
            </>
          )}
        </div>
      ) : null}
      {portDialogOpen ? (
        <SetShellPortDialog session={session} onClose={() => setPortDialogOpen(false)} />
      ) : null}
      {killError ? (
        <div
          role="status"
          data-debug-id={`shells-panel-row-menu-kill-error-${session.session_id}`}
          className="max-w-[220px] break-words text-right text-[10px] text-danger"
        >
          {killError}
        </div>
      ) : null}
    </div>
  );
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

// The dropdown is absolutely positioned inside a body that scrolls (`bodyCls` is
// `overflow-y-auto` in the standalone panel), so a menu opened on one of the last rows
// would be clipped by the bottom edge. Those rows open upward instead. Only a heuristic
// on row position — the Menu composite has no collision detection — but it is the
// difference between a reachable menu and an unreachable one on the rows most likely to
// hold the newest session.
function menuSide(index: number, total: number): 'bottom' | 'top' {
  return total > 3 && index >= total - 2 ? 'top' : 'bottom';
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

  // The open pane must follow the LIVE session row, not the snapshot captured when the
  // row was clicked: the terminal pane pauses its polling on a terminal status, and a
  // frozen "running" snapshot would keep it polling forever after the shell died.
  // Falls back to the snapshot while the list is between refetches.
  const activePaneSession = activePane
    ? sessions.find((s) => s.session_id === activePane.session.session_id) ?? activePane.session
    : null;

  // BUG-12: the row click always opens a pane — the terminal for a live interactive or
  // agent session, the log for everything else. A running server used to take a preview
  // arm here, which left its stdout unreachable exactly while it mattered (startup banner,
  // bound port, crash trace) even though a dead server's log was one click away. The
  // preview is now an explicit opt-in via the Preview button, which still opens in the
  // right-hand sidebar so it survives navigating away from this table.
  const handleRowClick = (session: ShellSession) => {
    if (
      (session.kind === 'interactive' || session.kind === 'agent') &&
      (session.status === 'running' || session.status === 'starting')
    ) {
      setActivePane({ type: 'terminal', session });
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
              {sessions.map((session, index) => (
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
                    <div className="flex items-center gap-1">
                      {hasAccessAffordance(session) ? (
                        <PreviewButton session={session} onOpen={() => dispatch(openTab(session))} touch />
                      ) : null}
                      <ShellRowMenu
                        session={session}
                        onViewStdout={() => setActivePane({ type: 'log', session })}
                        side={menuSide(index, sessions.length)}
                        touch
                      />
                    </div>
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
                  <th className="pb-1.5 text-right">
                    <span className="sr-only">Actions</span>
                  </th>
                </tr>
              </thead>
              <tbody>
                {sessions.map((session, index) => (
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
                      {hasAccessAffordance(session) ? (
                        <PreviewButton session={session} onOpen={() => dispatch(openTab(session))} />
                      ) : (
                        <span className="text-faint">—</span>
                      )}
                    </td>
                    <td className="py-2 text-right align-top">
                      <ShellRowMenu
                        session={session}
                        onViewStdout={() => setActivePane({ type: 'log', session })}
                        side={menuSide(index, sessions.length)}
                      />
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
            {activePane.type === 'terminal' && activePaneSession && (
              <ShellTerminalPane
                session={activePaneSession}
                onClose={() => setActivePane(null)}
              />
            )}
            {activePane.type === 'log' && activePaneSession && (
              <ShellLogViewer
                session={activePaneSession}
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
