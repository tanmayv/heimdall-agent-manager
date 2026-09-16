// ShellJobsPanel — the "Jobs" tab peer to Tasks/Files/Run dir.
//
// READ-ONLY, pull-model view of an agent INSTANCE's background shell jobs (REQ-16).
// Agents can run local shell commands on the bridge; when one exceeds 15s the hub
// records its status/metadata (never output). This panel lists those jobs for the
// current instance with a manual Refresh button — there is NO auto-poll/streaming.
// Command output lives only on the bridge host and is never shown here.

import { useEffect, useMemo, useRef, useState } from 'react';

import { Icon, IconButton, StatusPill } from '@ui';
import { useListShellJobsQuery, useFetchShellJobOutputQuery, type ShellJob, type ShellJobStatus } from '../../api/endpoints/shellJobs';

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
  if (isLoading) return <p className="mt-2 font-mono text-[11px] text-zinc-400">Loading output…</p>;
  if (error) return <p className="mt-2 text-[11px] text-rose-400">Failed to load output</p>;
  if (!data) return null;
  return (
    <div className="mt-2">
      {data.truncated ? (
        <p className="mb-1 text-[10px] text-zinc-500">Output truncated — showing last 100 lines</p>
      ) : null}
      <pre className="max-h-64 overflow-y-auto whitespace-pre-wrap break-all rounded bg-zinc-900 p-2 font-mono text-xs text-zinc-100">{data.output}</pre>
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
      return;
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
  }, [data, agentInstanceId, cursor]);

  const [showOutput, setShowOutput] = useState<Record<string, boolean>>({});

  const jobs: ShellJob[] = useMemo(() => accJobs, [accJobs]);
  const errorText = error ? String((error as any)?.error || (error as any)?.data || 'Failed to load background jobs') : '';

  function handleRefresh() {
    setCursor('');
    setAccJobs([]);
    void refetch();
  }

  const wrapperCls = 'relative flex h-full min-h-0 w-full flex-col bg-[#0b0d11]';

  return (
    <div data-debug-id={`${debugPrefix}-panel`} className={wrapperCls}>
      {/* Header */}
      <div className="flex items-center justify-between gap-2 border-b border-white/10 px-3 py-2.5">
        <div className="flex min-w-0 items-center gap-2">
          <Icon name="terminal" className="shrink-0 text-zinc-400" />
          <div className="min-w-0">
            <div className="truncate text-sm font-semibold text-white">Background Jobs</div>
            {rootLabel ? <div className="truncate text-[11px] text-zinc-500">{rootLabel}</div> : null}
          </div>
        </div>
        <div className="flex shrink-0 items-center gap-1">
          <button
            type="button"
            data-debug-id={`${debugPrefix}-refresh-btn`}
            onClick={handleRefresh}
            disabled={isFetching}
            className="rounded-lg border border-sky-400/30 px-2.5 py-1 text-xs text-sky-100 transition-colors hover:bg-sky-400/10 disabled:cursor-not-allowed disabled:opacity-50"
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
            <div className="h-16 rounded-xl bg-white/5" />
            <div className="h-16 rounded-xl bg-white/5" />
            <div className="h-16 rounded-xl bg-white/5" />
          </div>
        ) : errorText ? (
          <div data-debug-id={`${debugPrefix}-error`} className="rounded-xl border border-red-400/30 bg-red-500/10 px-3 py-2 text-sm text-red-100">
            {errorText}
          </div>
        ) : jobs.length === 0 ? (
          <div data-debug-id={`${debugPrefix}-empty`} className="rounded-xl border border-dashed border-white/20 p-8 text-center">
            <p className="text-zinc-400">No background jobs</p>
            <p className="mt-1 text-xs text-zinc-500">Shell commands that run longer than 15s appear here.</p>
          </div>
        ) : (
          <div data-debug-id={`${debugPrefix}-list`} className="space-y-3">
            {jobs.map((job) => (
              <div
                key={job.exec_id}
                data-debug-id={`${debugPrefix}-row`}
                className="rounded-xl border border-white/10 bg-black/20 p-3 transition-colors hover:bg-white/[0.05]"
              >
                <div className="flex items-start justify-between gap-2">
                  <code className="min-w-0 flex-1 truncate font-mono text-xs text-zinc-100">{job.cmd || '(no command)'}</code>
                  <StatusPill tone={statusTone(job.status)} className="shrink-0 uppercase">{job.status}</StatusPill>
                </div>
                <div className="mt-1 truncate font-mono text-[11px] text-zinc-500">{job.exec_id}</div>
                <div className="mt-2 flex flex-wrap items-center gap-x-4 gap-y-1 text-[11px] text-zinc-500">
                  <span>started <span className="text-zinc-300">{fmtTime(job.started_at)}</span></span>
                  {job.finished_at ? <span>finished <span className="text-zinc-300">{fmtTime(job.finished_at)}</span></span> : null}
                  {typeof job.exit_code === 'number' ? (
                    <span>exit <span className={job.exit_code === 0 ? 'text-emerald-300' : 'text-rose-300'}>{job.exit_code}</span></span>
                  ) : null}
                  <button
                    type="button"
                    className="ml-auto text-[11px] text-zinc-500 hover:text-zinc-300"
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
                className="w-full rounded-lg border border-white/10 py-2 text-xs text-zinc-400 transition-colors hover:bg-white/[0.05] disabled:cursor-not-allowed disabled:opacity-50"
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
