// ProjectVcsPanel — the "Changes" sub-tab peer to the file tree inside the Files
// panel (VCS Integration — REQ-VCS-8/9).
//
// Two-pane layout: a left list of changed files (status badge + path, cursor
// paginated via "Load more") and a right diff viewer that shows the selected
// file's hunks (monospace, +green/-red/ context, "Load more hunks" pagination).
//
// On mount it detects the VCS provider (getVcsCapabilities); when none is present
// it shows "No VCS detected". Otherwise it loads the first page of changed files
// (limit 100). Diffs are fetched lazily per selected file and appended page by page.

import { useCallback, useEffect, useState } from 'react';

import { Icon } from '@ui';
import {
  useLazyGetVcsCapabilitiesQuery,
  useLazyListVcsFilesQuery,
  useLazyGetVcsDiffQuery,
  type VcsChangedFile,
  type VcsDiffHunk,
  type VcsFileStatus,
  type VcsFilesResult,
  type VcsDiffResult,
} from '../../api/endpoints/projectVcs';

function str(v: any): string {
  return String(v ?? '').trim();
}

const FILES_LIMIT = 100;

// Status badge styling per change kind (task spec: added=green, modified=amber,
// deleted=red, renamed=sky, untracked=zinc).
const STATUS_BADGE: Record<VcsFileStatus, { label: string; cls: string }> = {
  added: { label: 'A', cls: 'bg-emerald-400/15 text-emerald-300' },
  modified: { label: 'M', cls: 'bg-amber-400/15 text-amber-300' },
  deleted: { label: 'D', cls: 'bg-red-400/15 text-red-300' },
  renamed: { label: 'R', cls: 'bg-sky-400/15 text-sky-300' },
  untracked: { label: 'U', cls: 'bg-zinc-400/15 text-zinc-300' },
};

function statusBadge(status: string): { label: string; cls: string } {
  return STATUS_BADGE[status as VcsFileStatus] ?? { label: '?', cls: 'bg-zinc-400/15 text-zinc-300' };
}

export type ProjectVcsPanelProps = {
  projectId: string;
  bridgeId?: string;
  onClose: () => void;
  isMobile: boolean;
  debugPrefix?: string;
};

export default function ProjectVcsPanel({
  projectId,
  bridgeId = '',
  onClose,
  isMobile = false,
  debugPrefix = 'project-vcs',
}: ProjectVcsPanelProps) {
  const [getCapabilities] = useLazyGetVcsCapabilitiesQuery();
  const [listFiles] = useLazyListVcsFilesQuery();
  const [getDiff] = useLazyGetVcsDiffQuery();

  // Capabilities: null = loading, then { provider } once resolved.
  const [caps, setCaps] = useState<{ provider: string } | null>(null);
  const [capsLoading, setCapsLoading] = useState(true);
  const [error, setError] = useState('');

  // Changed-files list (accumulated across paged loads).
  const [files, setFiles] = useState<VcsChangedFile[]>([]);
  const [filesCursor, setFilesCursor] = useState<string | null>(null);
  const [filesHasMore, setFilesHasMore] = useState(false);
  const [filesLoading, setFilesLoading] = useState(false);
  const [filesLoadingMore, setFilesLoadingMore] = useState(false);

  // Selected file + its (accumulated) diff hunks.
  const [selected, setSelected] = useState<string>('');
  const [hunks, setHunks] = useState<VcsDiffHunk[]>([]);
  const [diffCursor, setDiffCursor] = useState<string | null>(null);
  const [diffHasMore, setDiffHasMore] = useState(false);
  const [diffLoading, setDiffLoading] = useState(false);
  const [diffLoadingMore, setDiffLoadingMore] = useState(false);
  const [diffError, setDiffError] = useState('');

  // ---- Changed files --------------------------------------------------------

  const loadFiles = useCallback(
    async (opts?: { cursor?: string | null; append?: boolean }) => {
      if (!projectId) return;
      const append = Boolean(opts?.append);
      setError('');
      if (append) setFilesLoadingMore(true);
      else setFilesLoading(true);
      try {
        const res: VcsFilesResult = await listFiles({
          projectId,
          bridgeId,
          cursor: opts?.cursor ?? null,
          limit: FILES_LIMIT,
        }).unwrap();
        if (!res.ok) {
          setError(str(res.error?.message) || 'Could not list changed files');
          if (!append) setFiles([]);
          return;
        }
        setFilesHasMore(Boolean(res.has_more));
        setFilesCursor(res.next_cursor ?? null);
        setFiles((prev) => (append ? [...prev, ...(res.files || [])] : res.files || []));
      } catch (e: any) {
        setError(str(e?.error || e?.message) || 'Bridge unavailable');
        if (!append) setFiles([]);
      } finally {
        if (append) setFilesLoadingMore(false);
        else setFilesLoading(false);
      }
    },
    [projectId, bridgeId, listFiles],
  );

  // ---- Diff -----------------------------------------------------------------

  const loadDiff = useCallback(
    async (file: string, opts?: { cursor?: string | null; append?: boolean }) => {
      if (!projectId || !file) return;
      const append = Boolean(opts?.append);
      setDiffError('');
      if (append) setDiffLoadingMore(true);
      else setDiffLoading(true);
      try {
        const res: VcsDiffResult = await getDiff({
          projectId,
          bridgeId,
          file,
          cursor: opts?.cursor ?? null,
        }).unwrap();
        if (!res.ok) {
          setDiffError(str(res.error?.message) || 'Could not read diff');
          if (!append) setHunks([]);
          return;
        }
        setDiffHasMore(Boolean(res.has_more));
        setDiffCursor(res.next_cursor ?? null);
        setHunks((prev) => (append ? [...prev, ...(res.hunks || [])] : res.hunks || []));
      } catch (e: any) {
        setDiffError(str(e?.error || e?.message) || 'Could not read diff');
        if (!append) setHunks([]);
      } finally {
        if (append) setDiffLoadingMore(false);
        else setDiffLoading(false);
      }
    },
    [projectId, bridgeId, getDiff],
  );

  const selectFile = useCallback(
    (file: string) => {
      setSelected(file);
      setHunks([]);
      setDiffCursor(null);
      setDiffHasMore(false);
      void loadDiff(file);
    },
    [loadDiff],
  );

  // ---- Mount: detect provider, then load the first page of changed files ----

  useEffect(() => {
    let cancelled = false;
    setCaps(null);
    setCapsLoading(true);
    setError('');
    setFiles([]);
    setSelected('');
    setHunks([]);
    (async () => {
      if (!projectId) {
        if (!cancelled) setCapsLoading(false);
        return;
      }
      try {
        const res = await getCapabilities({ projectId, bridgeId }).unwrap();
        if (cancelled) return;
        if (!res.ok || !str(res.provider)) {
          setCaps({ provider: '' });
          return;
        }
        setCaps({ provider: res.provider });
        void loadFiles();
      } catch (e: any) {
        if (!cancelled) setError(str(e?.error || e?.message) || 'Could not detect VCS');
      } finally {
        if (!cancelled) setCapsLoading(false);
      }
    })();
    return () => {
      cancelled = true;
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [projectId, bridgeId]);

  // ---- Render ---------------------------------------------------------------

  const wrapperCls = 'relative flex h-full min-h-0 w-full flex-col bg-[#0b0d11]';

  if (!projectId) {
    return (
      <div data-debug-id={`${debugPrefix}-panel`} className={wrapperCls}>
        <div data-debug-id={`${debugPrefix}-no-project`} className="grid flex-1 place-items-center p-6 text-center text-xs text-zinc-500">
          No project is associated with this conversation.
        </div>
      </div>
    );
  }

  if (capsLoading) {
    return (
      <div data-debug-id={`${debugPrefix}-panel`} className={wrapperCls}>
        <div data-debug-id={`${debugPrefix}-caps-loading`} className="grid flex-1 place-items-center p-6 text-center text-xs text-zinc-500">
          Loading…
        </div>
      </div>
    );
  }

  if (!caps || !caps.provider) {
    return (
      <div data-debug-id={`${debugPrefix}-panel`} className={wrapperCls}>
        <div data-debug-id={`${debugPrefix}-no-vcs`} className="grid flex-1 place-items-center p-6 text-center text-xs text-zinc-500">
          No VCS detected for this project.
        </div>
      </div>
    );
  }

  return (
    <div data-debug-id={`${debugPrefix}-panel`} className={`${wrapperCls} ${isMobile ? 'flex-col' : 'flex-row'}`}>
      {/* Left pane: changed-files list */}
      <div
        data-debug-id={`${debugPrefix}-file-list`}
        className={`flex min-h-0 flex-col overflow-y-auto border-white/10 ${isMobile ? 'max-h-[45%] w-full border-b' : 'w-[240px] shrink-0 border-r'}`}
      >
        <div className="flex items-center justify-between gap-2 border-b border-white/[0.06] px-3 py-2">
          <span className="truncate text-[11px] font-semibold uppercase tracking-wide text-zinc-400" title={`Provider: ${caps.provider}`}>
            Changes · {caps.provider}
          </span>
          <button
            data-debug-id={`${debugPrefix}-refresh-btn`}
            type="button"
            onClick={() => void loadFiles()}
            className="shrink-0 rounded-lg border border-white/10 px-2 py-0.5 text-caption text-zinc-300 hover:bg-white/10"
          >
            Refresh
          </button>
        </div>

        {filesLoading ? (
          <div data-debug-id={`${debugPrefix}-files-loading`} className="p-4 text-center text-xs text-zinc-500">Loading…</div>
        ) : files.length === 0 ? (
          <div data-debug-id={`${debugPrefix}-files-empty`} className="p-6 text-center text-xs text-zinc-600">
            {error ? 'Couldn’t load changes — see the message below.' : 'No changes.'}
          </div>
        ) : (
          <ul>
            {files.map((f) => {
              const badge = statusBadge(f.status);
              const isSel = selected === f.path;
              return (
                <li key={`${f.path}:${f.staged ? 's' : 'u'}`}>
                  <button
                    data-debug-id={`${debugPrefix}-file-${f.path}`}
                    type="button"
                    onClick={() => selectFile(f.path)}
                    className={`flex w-full items-center gap-2 border-b border-white/[0.04] px-3 py-1.5 text-left hover:bg-white/[0.05] ${isSel ? 'bg-sky-400/10' : ''}`}
                  >
                    <span
                      className={`grid h-4 w-4 shrink-0 place-items-center rounded text-[9px] font-bold ${badge.cls}`}
                      title={f.status}
                    >
                      {badge.label}
                    </span>
                    <span className={`min-w-0 flex-1 truncate text-[12.5px] ${isSel ? 'text-zinc-100' : 'text-zinc-300'}`} title={f.path}>
                      {f.path}
                    </span>
                    {f.staged ? (
                      <span className="shrink-0 rounded bg-emerald-400/15 px-1 py-0.5 text-[8px] font-bold text-emerald-300" title="Staged">staged</span>
                    ) : null}
                  </button>
                </li>
              );
            })}
          </ul>
        )}

        {filesHasMore ? (
          <div className="p-3 text-center">
            <button
              data-debug-id={`${debugPrefix}-files-load-more-btn`}
              type="button"
              disabled={filesLoadingMore}
              onClick={() => void loadFiles({ cursor: filesCursor, append: true })}
              className="rounded-lg border border-white/10 px-3 py-1.5 text-caption text-zinc-300 hover:bg-white/10 disabled:opacity-50"
            >
              {filesLoadingMore ? 'Loading…' : 'Load more'}
            </button>
          </div>
        ) : null}
      </div>

      {/* Right pane: diff viewer */}
      <div data-debug-id={`${debugPrefix}-diff`} className="flex min-h-0 flex-1 flex-col overflow-hidden">
        {!selected ? (
          <div data-debug-id={`${debugPrefix}-diff-empty`} className="grid flex-1 place-items-center p-6 text-center text-xs text-zinc-500">
            Select a file to view its diff
          </div>
        ) : (
          <>
            <div className="flex items-center gap-2 border-b border-white/[0.06] px-3 py-2">
              <Icon name="file" size={13} className="shrink-0 text-zinc-500" />
              <span className="min-w-0 flex-1 truncate text-[12.5px] font-semibold text-zinc-100" title={selected}>{selected}</span>
            </div>
            <div data-debug-id={`${debugPrefix}-diff-body`} className="min-h-0 flex-1 overflow-auto bg-[#090909] font-mono text-[12px] leading-5">
              {diffLoading ? (
                <div className="p-4 text-center text-xs text-zinc-500">Loading…</div>
              ) : diffError && hunks.length === 0 ? (
                <div data-debug-id={`${debugPrefix}-diff-error`} className="p-6 text-center text-xs text-zinc-500">Couldn’t load diff — see the message below.</div>
              ) : hunks.length === 0 ? (
                <div data-debug-id={`${debugPrefix}-diff-no-hunks`} className="p-6 text-center text-xs text-zinc-600">No diff to show for this file.</div>
              ) : (
                hunks.map((h, hi) => (
                  <div key={`${h.old_start}-${h.new_start}-${hi}`} data-debug-id={`${debugPrefix}-hunk-${hi}`}>
                    <div className="bg-sky-400/[0.08] px-3 py-0.5 text-sky-300/80">
                      @@ -{h.old_start},{h.old_len} +{h.new_start},{h.new_len} @@
                    </div>
                    {h.lines.map((ln, li) => {
                      const bg =
                        ln.op === '+' ? 'bg-emerald-400/[0.12] text-emerald-200'
                        : ln.op === '-' ? 'bg-red-400/[0.12] text-red-200'
                        : 'text-zinc-300';
                      return (
                        <div key={li} className={`flex whitespace-pre px-3 ${bg}`}>
                          <span className="w-3 shrink-0 select-none text-zinc-500">{ln.op === ' ' ? ' ' : ln.op}</span>
                          <span className="min-w-0 flex-1">{ln.text || ' '}</span>
                        </div>
                      );
                    })}
                  </div>
                ))
              )}

              {diffHasMore ? (
                <div className="flex justify-center py-2">
                  <button
                    data-debug-id={`${debugPrefix}-diff-load-more-btn`}
                    type="button"
                    disabled={diffLoadingMore}
                    onClick={() => void loadDiff(selected, { cursor: diffCursor, append: true })}
                    className="rounded-lg border border-white/10 px-3 py-1.5 font-sans text-caption text-zinc-300 hover:bg-white/10 disabled:opacity-50"
                  >
                    {diffLoadingMore ? 'Loading…' : 'Load more hunks'}
                  </button>
                </div>
              ) : null}
            </div>
            {diffError ? (
              <div data-debug-id={`${debugPrefix}-diff-error-bar`} className="border-t border-red-400/20 bg-red-400/[0.06] px-3 py-2 text-caption text-red-300">
                {diffError}
              </div>
            ) : null}
          </>
        )}
      </div>

      {error ? (
        <div data-debug-id={`${debugPrefix}-error`} className="absolute inset-x-0 bottom-0 border-t border-red-400/20 bg-red-400/[0.06] px-3 py-2 text-caption text-red-300">
          {error}
        </div>
      ) : null}
    </div>
  );
}
