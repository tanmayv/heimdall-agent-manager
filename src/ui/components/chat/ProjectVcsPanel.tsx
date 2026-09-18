// ProjectVcsPanel — the "Changes" sub-tab peer to the file tree inside the Files
// panel (VCS Integration — REQ-VCS-8/9, REQ-UI-1/2, REQ-STAT-1/2).
//
// GitHub-style single scrolling column: each changed file is a row (chevron +
// status badge + path + +N/-N add/del counts + staged badge) whose unified diff
// is rendered inline directly beneath it, expanded by default and collapsible by
// clicking the header. There is no separate diff pane and no manual "Load more"
// button — an IntersectionObserver pages the file list and each file's diff hunks
// as their sentinels scroll into view. The layout is a single column at every
// viewport width (the isMobile prop is retained for signature compatibility but no
// longer drives layout).
//
// On mount it detects the VCS provider (getVcsCapabilities); when none is present
// it shows "No VCS detected". Otherwise it loads the first page of changed files
// (limit 100) and eagerly pre-loads each file's first diff page so diffs are
// visible without interaction.

import { useCallback, useEffect, useRef, useState } from 'react';

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

// Per-file diff state, keyed by file path in a Record. Holds the accumulated
// hunks, its own pagination cursor, and independent loading/error flags so each
// file's inline diff loads and pages on its own.
type FileState = {
  collapsed: boolean;
  hunks: VcsDiffHunk[];
  cursor: string | null;
  hasMore: boolean;
  loading: boolean;
  loadingMore: boolean;
  error: string;
};

// Fresh per-file state; loading:true so a not-yet-populated row renders "Loading…"
// rather than a spurious "No diff".
function newFileState(): FileState {
  return { collapsed: false, hunks: [], cursor: null, hasMore: false, loading: true, loadingMore: false, error: '' };
}

// Status badge styling per change kind (task spec: added=green, modified=amber,
// deleted=red, renamed=sky, untracked=zinc).
const STATUS_BADGE: Record<VcsFileStatus, { label: string; cls: string }> = {
  added: { label: 'A', cls: 'bg-success-soft text-success' },
  modified: { label: 'M', cls: 'bg-warning-soft text-warning' },
  deleted: { label: 'D', cls: 'bg-danger-soft text-danger' },
  renamed: { label: 'R', cls: 'bg-info-soft text-info' },
  untracked: { label: 'U', cls: 'bg-neutral-soft text-muted' },
};

function statusBadge(status: string): { label: string; cls: string } {
  return STATUS_BADGE[status as VcsFileStatus] ?? { label: '?', cls: 'bg-neutral-soft text-muted' };
}

// Small chevron that rotates -90° when its file is collapsed.
function ChevronIcon({ collapsed }: { collapsed: boolean }) {
  return (
    <svg
      width="10"
      height="10"
      viewBox="0 0 10 10"
      className="shrink-0 text-muted"
      style={{ transform: collapsed ? 'rotate(-90deg)' : 'none', transition: 'transform 0.1s' }}
    >
      <path d="M2 3l3 4 3-4" stroke="currentColor" strokeWidth="1.5" fill="none" strokeLinecap="round" strokeLinejoin="round" />
    </svg>
  );
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

  // Per-file inline diff state, keyed by path.
  const [fileStates, setFileStates] = useState<Record<string, FileState>>({});
  // Mirror of fileStates for reads inside IntersectionObserver callbacks (avoids
  // stale closures without re-creating the observers on every diff update).
  const fileStatesRef = useRef<Record<string, FileState>>({});
  useEffect(() => {
    fileStatesRef.current = fileStates;
  }, [fileStates]);

  // ---- Diff (per file) ------------------------------------------------------

  // loadDiff (re)loads the first page of a file's diff, preserving its collapsed
  // flag across a refresh.
  const loadDiff = useCallback(
    async (file: string) => {
      if (!projectId || !file) return;
      setFileStates((prev) => ({ ...prev, [file]: { ...(prev[file] ?? newFileState()), loading: true, error: '' } }));
      try {
        const res: VcsDiffResult = await getDiff({ projectId, bridgeId, file, cursor: null }).unwrap();
        if (!res.ok) {
          setFileStates((prev) => ({
            ...prev,
            [file]: { ...(prev[file] ?? newFileState()), loading: false, hunks: [], cursor: null, hasMore: false, error: str(res.error?.message) || 'Could not read diff' },
          }));
          return;
        }
        setFileStates((prev) => ({
          ...prev,
          [file]: { ...(prev[file] ?? newFileState()), loading: false, error: '', hunks: res.hunks || [], hasMore: Boolean(res.has_more), cursor: res.next_cursor ?? null },
        }));
      } catch (e: any) {
        setFileStates((prev) => ({
          ...prev,
          [file]: { ...(prev[file] ?? newFileState()), loading: false, hunks: [], cursor: null, hasMore: false, error: str(e?.error || e?.message) || 'Could not read diff' },
        }));
      }
    },
    [projectId, bridgeId, getDiff],
  );

  // loadMoreDiff appends the next diff page for a file (driven by its sentinel).
  const loadMoreDiff = useCallback(
    async (file: string) => {
      if (!projectId || !file) return;
      const cur = fileStatesRef.current[file];
      if (!cur || cur.loadingMore || !cur.hasMore) return;
      setFileStates((prev) => ({ ...prev, [file]: { ...(prev[file] ?? newFileState()), loadingMore: true } }));
      try {
        const res: VcsDiffResult = await getDiff({ projectId, bridgeId, file, cursor: cur.cursor ?? null }).unwrap();
        if (!res.ok) {
          setFileStates((prev) => ({ ...prev, [file]: { ...(prev[file] ?? newFileState()), loadingMore: false, error: str(res.error?.message) || 'Could not read diff' } }));
          return;
        }
        setFileStates((prev) => {
          const base = prev[file] ?? newFileState();
          return {
            ...prev,
            [file]: { ...base, loadingMore: false, error: '', hunks: [...base.hunks, ...(res.hunks || [])], hasMore: Boolean(res.has_more), cursor: res.next_cursor ?? null },
          };
        });
      } catch (e: any) {
        setFileStates((prev) => ({ ...prev, [file]: { ...(prev[file] ?? newFileState()), loadingMore: false, error: str(e?.error || e?.message) || 'Could not read diff' } }));
      }
    },
    [projectId, bridgeId, getDiff],
  );

  const toggleCollapse = useCallback((path: string) => {
    setFileStates((prev) => ({ ...prev, [path]: { ...(prev[path] ?? newFileState()), collapsed: !prev[path]?.collapsed } }));
  }, []);

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
          if (!append) {
            setFiles([]);
            setFileStates({});
          }
          return;
        }
        setFilesHasMore(Boolean(res.has_more));
        setFilesCursor(res.next_cursor ?? null);
        const incoming = res.files || [];
        setFiles((prev) => (append ? [...prev, ...incoming] : incoming));
        // On a fresh (non-append) load, drop stale per-file diff state so removed
        // files don't linger. Pre-load each incoming file's first diff page so it
        // renders inline immediately.
        if (!append) setFileStates({});
        for (const f of incoming) void loadDiff(f.path);
      } catch (e: any) {
        setError(str(e?.error || e?.message) || 'Bridge unavailable');
        if (!append) {
          setFiles([]);
          setFileStates({});
        }
      } finally {
        if (append) setFilesLoadingMore(false);
        else setFilesLoading(false);
      }
    },
    [projectId, bridgeId, listFiles, loadDiff],
  );

  // ---- IntersectionObserver wiring ------------------------------------------

  const diffObserversRef = useRef<Map<string, IntersectionObserver>>(new Map());
  const filesObserverRef = useRef<IntersectionObserver | null>(null);
  const scrollContainerRef = useRef<HTMLDivElement>(null);

  const attachDiffSentinel = useCallback(
    (el: HTMLDivElement | null, path: string) => {
      const prev = diffObserversRef.current.get(path);
      if (prev) {
        prev.disconnect();
        diffObserversRef.current.delete(path);
      }
      if (!el) return;
      const obs = new IntersectionObserver(
        ([entry]) => {
          if (entry.isIntersecting) void loadMoreDiff(path);
        },
        { root: scrollContainerRef.current, threshold: 0.1 },
      );
      obs.observe(el);
      diffObserversRef.current.set(path, obs);
    },
    [loadMoreDiff],
  );

  const attachFilesSentinel = useCallback(
    (el: HTMLDivElement | null) => {
      if (filesObserverRef.current) filesObserverRef.current.disconnect();
      if (!el) return;
      const obs = new IntersectionObserver(
        ([entry]) => {
          if (entry.isIntersecting) void loadFiles({ cursor: filesCursor, append: true });
        },
        { root: scrollContainerRef.current, threshold: 0.1 },
      );
      obs.observe(el);
      filesObserverRef.current = obs;
    },
    [loadFiles, filesCursor],
  );

  // Disconnect every observer on unmount.
  useEffect(() => {
    const diffObservers = diffObserversRef.current;
    return () => {
      diffObservers.forEach((o) => o.disconnect());
      diffObservers.clear();
      filesObserverRef.current?.disconnect();
    };
  }, []);

  // ---- Mount: detect provider, then load the first page of changed files ----

  useEffect(() => {
    let cancelled = false;
    setCaps(null);
    setCapsLoading(true);
    setError('');
    setFiles([]);
    setFileStates({});
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

  const wrapperCls = 'relative flex h-full min-h-0 w-full flex-col bg-surface';

  if (!projectId) {
    return (
      <div data-debug-id={`${debugPrefix}-panel`} className={wrapperCls}>
        <div data-debug-id={`${debugPrefix}-no-project`} className="grid flex-1 place-items-center p-6 text-center text-xs text-muted">
          No project is associated with this conversation.
        </div>
      </div>
    );
  }

  if (capsLoading) {
    return (
      <div data-debug-id={`${debugPrefix}-panel`} className={wrapperCls}>
        <div data-debug-id={`${debugPrefix}-caps-loading`} className="grid flex-1 place-items-center p-6 text-center text-xs text-muted">
          Loading…
        </div>
      </div>
    );
  }

  if (!caps || !caps.provider) {
    return (
      <div data-debug-id={`${debugPrefix}-panel`} className={wrapperCls}>
        <div data-debug-id={`${debugPrefix}-no-vcs`} className="grid flex-1 place-items-center p-6 text-center text-xs text-muted">
          No VCS detected for this project.
        </div>
      </div>
    );
  }

  return (
    <div data-debug-id={`${debugPrefix}-panel`} className={wrapperCls}>
      {/* Sticky header */}
      <div className="sticky top-0 z-10 flex items-center justify-between gap-2 border-b border-subtle bg-surface px-3 py-2">
        <span className="truncate text-[11px] font-semibold uppercase tracking-wide text-muted" title={`Provider: ${caps.provider}`}>
          Changes · {caps.provider}
        </span>
        <button
          data-debug-id={`${debugPrefix}-refresh-btn`}
          type="button"
          onClick={() => void loadFiles()}
          className="shrink-0 rounded-lg border border-subtle px-2 py-0.5 text-caption text-primary hover:bg-neutral-soft"
        >
          Refresh
        </button>
      </div>

      {/* Scrollable body: single column of files, each with its inline diff. */}
      <div ref={scrollContainerRef} data-debug-id={`${debugPrefix}-body`} className="min-h-0 flex-1 overflow-y-auto">
        {filesLoading ? (
          <div data-debug-id={`${debugPrefix}-files-loading`} className="p-4 text-center text-xs text-muted">Loading…</div>
        ) : files.length === 0 ? (
          <div data-debug-id={`${debugPrefix}-files-empty`} className="p-6 text-center text-xs text-muted">
            {error ? 'Couldn’t load changes — see the message below.' : 'No changes.'}
          </div>
        ) : (
          files.map((f) => {
            const badge = statusBadge(f.status);
            const fs = fileStates[f.path] ?? newFileState();
            return (
              <div key={`${f.path}:${f.staged ? 's' : 'u'}`} data-debug-id={`${debugPrefix}-file-${f.path}`} className="border-b border-subtle">
                {/* File header — click to collapse/expand its diff. */}
                <button
                  data-debug-id={`${debugPrefix}-file-header-${f.path}`}
                  type="button"
                  onClick={() => toggleCollapse(f.path)}
                  className="flex w-full items-center gap-2 px-3 py-2 text-left hover:bg-neutral-soft"
                >
                  <ChevronIcon collapsed={fs.collapsed} />
                  <span className={`grid h-4 w-4 shrink-0 place-items-center rounded text-[9px] font-bold ${badge.cls}`} title={f.status}>
                    {badge.label}
                  </span>
                  <span className="min-w-0 flex-1 truncate text-[12.5px] text-primary" title={f.path}>
                    {f.path}
                  </span>
                  <span className="ml-1 flex shrink-0 gap-1.5 font-mono text-[11px]">
                    {f.additions > 0 ? <span className="text-success">+{f.additions}</span> : null}
                    {f.deletions > 0 ? <span className="text-danger">-{f.deletions}</span> : null}
                  </span>
                  {f.staged ? (
                    <span className="shrink-0 rounded bg-success-soft px-1 py-0.5 text-[8px] font-bold text-success" title="Staged">staged</span>
                  ) : null}
                </button>

                {/* Inline diff — hidden when collapsed. */}
                {!fs.collapsed ? (
                  <div
                    data-debug-id={`${debugPrefix}-diff-${f.path}`}
                    className="border-t border-subtle bg-canvas font-mono text-[12px] leading-5"
                  >
                    {fs.loading ? (
                      <div className="p-3 text-center text-xs text-muted">Loading…</div>
                    ) : fs.error && fs.hunks.length === 0 ? (
                      <div data-debug-id={`${debugPrefix}-diff-error-${f.path}`} className="p-3 text-center text-xs text-muted">{fs.error}</div>
                    ) : fs.hunks.length === 0 ? (
                      <div data-debug-id={`${debugPrefix}-diff-no-hunks-${f.path}`} className="p-3 text-center text-xs text-muted">No diff to show.</div>
                    ) : (
                      fs.hunks.map((h, hi) => (
                        <div key={`${h.old_start}-${h.new_start}-${hi}`} data-debug-id={`${debugPrefix}-hunk-${f.path}-${hi}`}>
                          <div className="border-y border-info/30 bg-info-soft px-3 py-0.5 text-info">
                            @@ -{h.old_start},{h.old_len} +{h.new_start},{h.new_len} @@
                          </div>
                          {h.lines.map((ln, li) => {
                            const bg =
                              ln.op === '+' ? 'bg-success-soft text-success'
                              : ln.op === '-' ? 'bg-danger-soft text-danger'
                              : 'text-primary';
                            return (
                              <div key={li} className={`flex whitespace-pre px-3 ${bg}`}>
                                <span className="w-3 shrink-0 select-none text-muted">{ln.op === ' ' ? ' ' : ln.op}</span>
                                <span className="min-w-0 flex-1">{ln.text || ' '}</span>
                              </div>
                            );
                          })}
                        </div>
                      ))
                    )}

                    {/* Per-file diff infinite-scroll sentinel. */}
                    {fs.hasMore && !fs.loadingMore ? (
                      <div ref={(el) => attachDiffSentinel(el, f.path)} className="h-1" />
                    ) : null}
                    {fs.loadingMore ? <div className="p-2 text-center text-xs text-muted">Loading…</div> : null}
                  </div>
                ) : null}
              </div>
            );
          })
        )}

        {/* File-list infinite-scroll sentinel. */}
        {filesHasMore && !filesLoadingMore ? <div ref={attachFilesSentinel} className="h-1" /> : null}
        {filesLoadingMore ? (
          <div data-debug-id={`${debugPrefix}-files-loading-more`} className="p-3 text-center text-xs text-muted">Loading more files…</div>
        ) : null}
      </div>

      {error ? (
        <div data-debug-id={`${debugPrefix}-error`} className="absolute inset-x-0 bottom-0 border-t border-danger/30 bg-danger-soft px-3 py-2 text-caption text-danger">
          {error}
        </div>
      ) : null}
    </div>
  );
}
