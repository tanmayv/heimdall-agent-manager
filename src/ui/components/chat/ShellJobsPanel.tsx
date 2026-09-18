// ShellJobsPanel — the "Jobs" tab peer to Tasks/Files/Run dir.
//
// READ-ONLY, pull-model view of an agent INSTANCE's background shell jobs (REQ-16).
// Agents can run local shell commands on the bridge; when one exceeds 15s the hub
// records its status/metadata (never output). This panel lists those jobs for the
// current instance. A manual Refresh button re-pulls page 1, and the panel also
// auto-refreshes when the hub reports shell activity for this instance over the
// WebSocket (REQ-35). Command output lives only on the bridge host and is never
// shown here.

import { useEffect, useMemo, useRef, useState } from 'react';
import { useSelector } from 'react-redux';

import { Icon, IconButton, StatusPill } from '@ui';
import { useListShellJobsQuery, useFetchShellJobOutputQuery, type ShellJob, type ShellJobStatus } from '../../api/endpoints/shellJobs';
import { selectAgentLastActionAt } from '../../store/agentActivitySlice';

export type ShellJobsPanelProps = {
  agentInstanceId: string;
  rootLabel?: string;
  onClose?: () => void;
  isMobile?: boolean;
  debugPrefix?: string;
};

function statusTone(status: ShellJobStatus): 'info' | 'success' | 'danger' | 'neutral' {
  switch (status) {
    case 'running':
      return 'info';
    case 'completed':
      return 'success';
    case 'failed':
      return 'danger';
    default:
      return 'neutral';
  }
}

// RFC3339/ISO -> short local timestamp; empty/invalid renders as an em dash.
function fmtTime(s?: string): string {
  const v = String(s ?? '').trim();
  if (!v) return '—';
  const d = new Date(v);
  if (isNaN(d.getTime())) return v;
  return d.toLocaleString([], { month: 'short', day: 'numeric', hour: '2-digit', minute: '2-digit' });
}

function JobOutputSection({ agentInstanceId, execId }: { agentInstanceId: string; execId: string }) {
  const { data, isLoading, error } = useFetchShellJobOutputQuery(
    { instanceId: agentInstanceId, execId },
  );
  if (isLoading) return <p className="mt-2 font-mono text-[11px] text-muted">Loading output…</p>;
  if (error) return <p className="mt-2 text-[11px] text-danger">Failed to load output</p>;
  if (!data) return null;
  return (
    <div className="mt-2">
      {data.truncated ? (
        <p className="mb-1 text-[10px] text-muted">Output truncated — showing last 100 lines</p>
      ) : null}
      <pre className="max-h-64 overflow-y-auto whitespace-pre-wrap break-all rounded border border-subtle bg-surface-raised p-2 font-mono text-xs text-primary">{data.output}</pre>
    </div>
  );
}

export default function ShellJobsPanel({
  agentInstanceId,
  rootLabel,
  onClose,
  isMobile = false,
  debugPrefix = 'shell-jobs',
}: ShellJobsPanelProps) {
  void isMobile; // accepted for parity with the sibling panels; layout is responsive via CSS.

  const [cursor, setCursor] = useState<string>('');
  const [accJobs, setAccJobs] = useState<ShellJob[]>([]);
  // Monotonic counter bumped on every user-triggered / auto refresh. It is a
  // dependency of the accumulation effect below so a refresh always re-runs the
  // page-1 replacement branch — even when RTK Query's structuralSharing returns
  // the SAME `data` reference (identical response), which would otherwise leave
  // the effect dormant and the freshly-cleared list empty (REQ-35).
  const [refreshKey, setRefreshKey] = useState(0);
  const prevInstanceId = useRef<string>('');

  const { data, isLoading, isFetching, error, refetch } = useListShellJobsQuery(
    { instanceId: agentInstanceId, cursor },
    { skip: !agentInstanceId },
  );

  useEffect(() => {
    if (prevInstanceId.current !== agentInstanceId) {
      prevInstanceId.current = agentInstanceId;
      setCursor('');
      setAccJobs([]);
      // Fall through: populate from cached data if available, so a remount
      // (e.g. returning to the Jobs tab) doesn't leave the list empty until
      // the user manually refreshes.
    }
    if (data?.jobs) {
      if (!cursor) {
        setAccJobs(data.jobs);
      } else {
        setAccJobs((prev) => {
          const seen = new Set(prev.map((j) => j.exec_id));
          return [...prev, ...data.jobs.filter((j) => !seen.has(j.exec_id))];
        });
      }
    }
    // refreshKey is intentionally a dep: it forces the page-1 replacement branch
    // to re-run after a refresh even when `data` keeps the same reference.
  }, [data, agentInstanceId, cursor, refreshKey]);

  const [showOutput, setShowOutput] = useState<Record<string, boolean>>({});

  const jobs: ShellJob[] = useMemo(() => accJobs, [accJobs]);
  const errorText = error ? String((error as any)?.error || (error as any)?.data || 'Failed to load background jobs') : '';

  function handleRefresh() {
    // Reset to page 1 and force a network re-pull. Bumping refreshKey guarantees
    // the accumulation effect re-runs its replacement branch even if the fetch
    // returns a structurally-identical response (same `data` reference).
    setCursor('');
    setRefreshKey((k) => k + 1);
    void refetch();
  }

  // Auto-refresh (REQ-35): the hub broadcasts an `agent_action` WS event with
  // action `shell_cmd_report` whenever a background job starts (>=15s running
  // report) or finishes; wsInvalidation routes it into the transient
  // agentActivity slice, bumping this instance's lastActionAt. When that time
  // advances while the panel is mounted, re-pull page 1 so new/updated jobs
  // appear without a manual click. Other agent_action kinds also bump the same
  // clock — an occasional harmless extra list refresh, never a stale panel.
  const lastActionAt = useSelector((s) => selectAgentLastActionAt(s, agentInstanceId));
  const seenActionAt = useRef<number>(0);
  useEffect(() => {
    // Prime the baseline on (re)mount / instance switch so we don't refetch for
    // activity that predates the panel being opened.
    seenActionAt.current = lastActionAt;
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [agentInstanceId]);
  useEffect(() => {
    if (!agentInstanceId) return;
    if (lastActionAt > seenActionAt.current) {
      seenActionAt.current = lastActionAt;
      handleRefresh();
    }
    // handleRefresh is stable enough for this effect; only the clock matters.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [lastActionAt, agentInstanceId]);

  const wrapperCls = 'relative flex h-full min-h-0 w-full flex-col bg-surface';

  return (
    <div data-debug-id={`${debugPrefix}-panel`} className={wrapperCls}>
      {/* Header */}
      <div className="flex items-center justify-between gap-2 border-b border-subtle px-3 py-2.5">
        <div className="flex min-w-0 items-center gap-2">
          <Icon name="terminal" className="shrink-0 text-muted" />
          <div className="min-w-0">
            <div className="truncate text-sm font-semibold text-primary">Background Jobs</div>
            {rootLabel ? <div className="truncate text-[11px] text-muted">{rootLabel}</div> : null}
          </div>
        </div>
        <div className="flex shrink-0 items-center gap-1">
          <button
            type="button"
            data-debug-id={`${debugPrefix}-refresh-btn`}
            onClick={handleRefresh}
            disabled={isFetching}
            className="rounded-lg border border-accent/40 bg-accent/10 px-2.5 py-1 text-xs text-accent transition-colors hover:bg-accent/20 disabled:cursor-not-allowed disabled:opacity-50"
          >
            {isFetching ? 'Refreshing…' : 'Refresh'}
          </button>
          {onClose ? (
            <IconButton icon="close" label="Close background jobs panel" size="sm" data-debug-id={`${debugPrefix}-close-btn`} onClick={onClose} />
          ) : null}
        </div>
      </div>

      {/* Body */}
      <div className="min-h-0 flex-1 overflow-y-auto p-3">
        {isLoading && accJobs.length === 0 ? (
          <div data-debug-id={`${debugPrefix}-loading`} className="animate-pulse space-y-3">
            <div className="h-16 rounded-xl bg-neutral-soft" />
            <div className="h-16 rounded-xl bg-neutral-soft" />
            <div className="h-16 rounded-xl bg-neutral-soft" />
          </div>
        ) : errorText ? (
          <div data-debug-id={`${debugPrefix}-error`} className="rounded-xl border border-danger/30 bg-danger-soft px-3 py-2 text-sm text-danger">
            {errorText}
          </div>
        ) : jobs.length === 0 ? (
          <div data-debug-id={`${debugPrefix}-empty`} className="rounded-xl border border-dashed border-subtle p-8 text-center">
            <p className="text-muted">No background jobs</p>
            <p className="mt-1 text-xs text-faint">Shell commands that run longer than 15s appear here.</p>
          </div>
        ) : (
          <div data-debug-id={`${debugPrefix}-list`} className="space-y-3">
            {jobs.map((job) => (
              <div
                key={job.exec_id}
                data-debug-id={`${debugPrefix}-row`}
                className="rounded-xl border border-subtle bg-surface-raised p-3 transition-colors hover:bg-neutral-soft"
              >
                <div className="flex items-start justify-between gap-2">
                  <code className="min-w-0 flex-1 truncate font-mono text-xs text-primary" title={job.cmd}>{job.cmd || '(no command)'}</code>
                  <StatusPill tone={statusTone(job.status)} className="shrink-0 uppercase">{job.status}</StatusPill>
                </div>
                <div className="mt-1 truncate font-mono text-[11px] text-faint">{job.exec_id}</div>
                <div className="mt-2 flex flex-wrap items-center gap-x-4 gap-y-1 text-[11px] text-muted">
                  <span>started <span className="text-primary">{fmtTime(job.started_at)}</span></span>
                  {job.finished_at ? <span>finished <span className="text-primary">{fmtTime(job.finished_at)}</span></span> : null}
                  {typeof job.exit_code === 'number' ? (
                    <span>exit <span className={job.exit_code === 0 ? 'text-success' : 'text-danger'}>{job.exit_code}</span></span>
                  ) : null}
                  <button
                    type="button"
                    className="ml-auto text-[11px] text-muted hover:text-primary"
                    onClick={() => setShowOutput((prev) => ({ ...prev, [job.exec_id]: !prev[job.exec_id] }))}
                  >
                    {showOutput[job.exec_id] ? 'Hide Output' : 'View Output'}
                  </button>
                </div>
                {showOutput[job.exec_id] ? (
                  <JobOutputSection agentInstanceId={agentInstanceId} execId={job.exec_id} />
                ) : null}
              </div>
            ))}
            {data?.has_more ? (
              <button
                type="button"
                data-debug-id={`${debugPrefix}-load-more-btn`}
                onClick={() => { if (data?.next_cursor) setCursor(data.next_cursor); }}
                disabled={isFetching}
                className="w-full rounded-lg border border-subtle py-2 text-xs text-muted transition-colors hover:bg-neutral-soft disabled:cursor-not-allowed disabled:opacity-50"
              >
                {isFetching ? 'Loading…' : 'Load More'}
              </button>
            ) : null}
          </div>
        )}
      </div>
    </div>
  );
}
