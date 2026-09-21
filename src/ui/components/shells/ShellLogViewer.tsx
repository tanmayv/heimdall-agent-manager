import { useEffect, useRef, useState } from 'react';
import {
  useGetShellLogQuery,
  useKillShellMutation,
  useRestartShellMutation,
} from '../../api/endpoints/shells';
import type { ShellLogResponse, ShellSession } from '../../api/endpoints/shells';

interface ShellLogViewerProps {
  session: ShellSession;
  onClose?: () => void;
}

const PAGE_SIZE = 100;

// GET /shells/{id}/log pages from the HEAD of the file: `offset` skips lines and
// `limit` caps how many come back (bridge_shell_page, src/bridge/shell_cmd.odin). There
// is no tail mode, so "show me the end of the log" has to be expressed as an offset.
// Note that bridge_shell_page's documented "limit <= 0 means no cap" escape hatch is NOT
// reachable from here: shell_session_get_log rewrites a non-positive limit to 100
// (src/hub/service/shell_session/shell_session_service.odin), so every request from the
// UI is capped and the window has to be sized explicitly. Verified against a live hub.
//
// The viewer therefore runs in one of two modes (REQ-SHELL-UI-2):
//
//   FOLLOW (default) — show the newest PAGE_SIZE lines and keep up as the session runs.
//     The request starts one page back from the end but asks for FOLLOW_LIMIT lines,
//     i.e. a window with a spare page of headroom past the current end of the file. That
//     headroom is what makes following cheap: new output lands inside the window the
//     viewer is already asking for, so the offset only has to be resynced once that
//     headroom runs low — not on every one of the 1/second polls, which would change the
//     query key (and so refetch from scratch) every tick.
//     The offset for the very first request is unknown, because it is derived from the
//     line count that only the first response carries. Rather than paint the head of the
//     file and then jump, the first request is a one-line probe whose body is discarded:
//     it exists only to learn `total`.
//
//   BROWSE — the user pressed "Load earlier". The window is pinned to a fixed
//     `offset`/PAGE_SIZE page, so the poll keeps refreshing without dragging the reader
//     back to the bottom. "Jump to latest" returns to FOLLOW.
const FOLLOW_LIMIT = PAGE_SIZE * 2;
// Resync once half the headroom is gone rather than waiting for the window to fill: a
// full window may have been cut off at the cap, which would hold the newest lines back
// for one poll. Measured against a live server emitting ~18 lines/second, this resyncs
// on roughly 1 poll in 3 and the window never fills.
const FOLLOW_RESYNC_AT = PAGE_SIZE / 2;
// A grep filter has no equivalent of `total` to aim at (see the note on ShellLogResponse),
// so a filtered follow asks for a deliberately generous window and walks forward from the
// first match until the whole match set fits inside it.
const GREP_FOLLOW_LIMIT = PAGE_SIZE * 10;
const PROBE_LIMIT = 1;

export function ShellLogViewer({ session, onClose }: ShellLogViewerProps) {
  const [follow, setFollow] = useState(true);
  // Request offset while following. Settled only after `total` is known.
  const [tailOffset, setTailOffset] = useState(0);
  // Request offset while browsing backwards.
  const [browseOffset, setBrowseOffset] = useState(0);
  const [settled, setSettled] = useState(false);
  const [grep, setGrep] = useState('');
  const [grepInput, setGrepInput] = useState('');
  const logEndRef = useRef<HTMLDivElement | null>(null);
  // Last response that was safe to render, kept so that changing the query key (a
  // follow resync, or a page step) does not blank the pane while the new one is in
  // flight. Probe responses never land here.
  const lastShownRef = useRef<ShellLogResponse | null>(null);

  const isRunning = session.status === 'running' || session.status === 'starting';

  const reqOffset = follow ? tailOffset : browseOffset;
  const followLimit = grep ? GREP_FOLLOW_LIMIT : FOLLOW_LIMIT;
  const reqLimit = follow ? (settled ? followLimit : PROBE_LIMIT) : PAGE_SIZE;

  const { data, isFetching, refetch } = useGetShellLogQuery(
    { sessionId: session.session_id, offset: reqOffset, limit: reqLimit, grep: grep || undefined },
    { pollingInterval: isRunning ? 1000 : 0 },
  );

  const [killShell, killState] = useKillShellMutation();
  const [restartShell, restartState] = useRestartShellMutation();

  // A different session means a different log: drop the window state and re-probe.
  useEffect(() => {
    setFollow(true);
    setTailOffset(0);
    setBrowseOffset(0);
    setSettled(false);
    lastShownRef.current = null;
  }, [session.session_id]);

  // Settle the follow offset onto the tail, then keep the window's headroom topped up
  // as the log grows.
  useEffect(() => {
    if (!data || !follow) return;

    if (grep) {
      // `total` counts every line in the file, not the matches, while `offset` indexes
      // matches — so it cannot locate the tail of a filtered view. Step forward by what
      // the server actually returned instead.
      if (!settled) {
        setSettled(true);
      } else if (data.lines.length >= GREP_FOLLOW_LIMIT) {
        // The window came back full, so there are probably matches past its end: step
        // forward, keeping the page that is on screen, until it no longer fills up.
        setTailOffset((prev) => prev + (data.lines.length - PAGE_SIZE));
      }
      return;
    }

    const desired = Math.max(0, data.total - PAGE_SIZE);
    if (!settled) {
      setTailOffset(desired);
      setSettled(true);
      return;
    }
    // Already tailing: new output lands in the window's spare page, so only resync once
    // that headroom is used up — or once the response comes back full, which means the
    // end of the file may have been cut off.
    if (desired - tailOffset >= FOLLOW_RESYNC_AT || data.lines.length >= FOLLOW_LIMIT) {
      if (desired !== tailOffset) setTailOffset(desired);
    }
  }, [data, follow, grep, settled, tailOffset]);

  // The probe's single line is never shown; everything else is worth keeping on screen.
  const isProbeResponse = data != null && data.limit === PROBE_LIMIT;
  const ready = !follow || settled;

  useEffect(() => {
    if (data && !isProbeResponse) lastShownRef.current = data;
  }, [data, isProbeResponse]);

  const view = ready ? (data && !isProbeResponse ? data : lastShownRef.current) : null;

  const lines = view?.lines ?? [];
  const total = view?.total ?? 0;
  // Index (0-based) of the first line on screen. While following, the window may hold
  // more than a page (that is its headroom), and only its last page is rendered.
  const windowStart = (view?.offset ?? 0) + (follow ? Math.max(0, lines.length - PAGE_SIZE) : 0);
  const visible = follow ? lines.slice(-PAGE_SIZE) : lines;
  const canLoadEarlier = windowStart > 0;

  // Stick to the bottom only while following; a reader paging through history is left
  // where they are.
  useEffect(() => {
    if (follow) logEndRef.current?.scrollIntoView({ block: 'end' });
  }, [view, follow]);

  const handleLoadEarlier = () => {
    setBrowseOffset(Math.max(0, windowStart - PAGE_SIZE));
    setFollow(false);
  };

  const handleJumpToLatest = () => {
    setFollow(true);
    setTailOffset(0);
    // With a grep active there is no `total` to settle onto, so follow restarts from the
    // first match and the generous window carries the rest.
    setSettled(grep !== '');
  };

  const handleGrepSubmit = (e: React.FormEvent) => {
    e.preventDefault();
    setGrep(grepInput);
    setFollow(true);
    setTailOffset(0);
    setBrowseOffset(0);
    setSettled(grepInput !== '');
    lastShownRef.current = null;
  };

  const handleKill = () => {
    killShell({ sessionId: session.session_id }).catch(() => {});
  };

  const handleRestart = () => {
    restartShell({ sessionId: session.session_id }).catch(() => {});
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
            <span className="text-[10px] text-faint">
              {/* Under a grep filter the window is indexed by matches while `total`
                  counts file lines, so the two must not be shown as one range. */}
              {!grep && visible.length > 0
                ? `${windowStart + 1}–${windowStart + visible.length} of ${total} lines`
                : `${total} lines`}
            </span>
          )}
          {!follow && (
            <span className="rounded bg-warning-soft px-1.5 py-0.5 text-[10px] font-semibold text-warning">
              paused
            </span>
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
            onClick={() => {
              setGrep('');
              setGrepInput('');
              setFollow(true);
              setTailOffset(0);
              setBrowseOffset(0);
              setSettled(false);
              lastShownRef.current = null;
            }}
            className="rounded px-2 py-1 text-xs text-faint hover:text-primary"
          >
            Clear
          </button>
        )}
      </form>

      {/* Log output */}
      <div className="h-[320px] overflow-y-auto bg-surface p-2 font-mono text-[11px] text-primary">
        {canLoadEarlier && (
          <button
            type="button"
            onClick={handleLoadEarlier}
            className="mb-2 w-full rounded border border-dashed border-subtle py-1 text-xs text-muted hover:text-primary"
          >
            ↑ Load earlier (lines {Math.max(0, windowStart - PAGE_SIZE) + 1}–{windowStart})
          </button>
        )}

        {!ready && (
          <div className="text-xs text-faint italic">Loading…</div>
        )}

        {ready && visible.length === 0 && !isFetching && (
          <div className="text-xs text-faint italic">
            {grep ? 'No matching lines.' : 'No log output yet.'}
          </div>
        )}

        {visible.map((line, i) => (
          <div key={`${windowStart}-${i}`} className="whitespace-pre-wrap break-all leading-5">
            {line}
          </div>
        ))}

        {!follow && (
          <button
            type="button"
            onClick={handleJumpToLatest}
            className="mt-2 w-full rounded border border-dashed border-subtle py-1 text-xs text-muted hover:text-primary"
          >
            ↓ Jump to latest
          </button>
        )}

        <div ref={logEndRef} />
      </div>
    </div>
  );
}
