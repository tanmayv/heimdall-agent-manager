// ProjectVcsPanel — the "Changes" sub-tab peer to the file tree inside the Files
// panel (VCS Integration — REQ-VCS-8/9, REQ-UI-1/2, REQ-STAT-1/2, REQ-VCS-DIFF-TARGETS, REQ-VCS-FILE-ACTIONS).
//
// GitHub-style single scrolling column: each changed file is a row (chevron +
// status badge + path + +N/-N add/del counts + staged badge + actions) whose unified diff
// is rendered inline directly beneath it, expanded by default and collapsible by
// clicking the header. Supports diff target selection (HEAD, cached, p4base, etc.),
// diff viewing for added and deleted files, and per-file stage/add and revert actions.

import { useCallback, useEffect, useRef, useState } from 'react';

import {
  useLazyGetVcsCapabilitiesQuery,
  useLazyListVcsFilesQuery,
  useLazyGetVcsDiffQuery,
  useGetVcsTargetsQuery,
  useExecuteVcsActionMutation,
  type VcsChangedFile,
  type VcsDiffHunk,
  type VcsFileStatus,
  type VcsFilesResult,
  type VcsDiffResult,
} from '../../api/endpoints/projectVcs';
import { Select } from '@ui';
import MonacoDiffViewer from './MonacoDiffViewer';

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
  const { data: targetsData } = useGetVcsTargetsQuery({ projectId, bridgeId }, { skip: !projectId });
  const [executeAction, { isLoading: isActionLoading }] = useExecuteVcsActionMutation();

  const targets = targetsData?.targets || [];
  const [selectedTarget, setSelectedTarget] = useState<string>('');
  const [confirmRevertFile, setConfirmRevertFile] = useState<string | null>(null);

  // Sync default target if available
  useEffect(() => {
    if (targets.length > 0 && !selectedTarget) {
      const defaultTarget = targets.find((t) => t.is_default);
      if (defaultTarget) {
        setSelectedTarget(defaultTarget.id);
      } else if (targets[0]) {
        setSelectedTarget(targets[0].id);
      }
    }
  }, [targets, selectedTarget]);

  // Capabilities: null = loading, then { provider, supports_staging } once resolved.
  const [caps, setCaps] = useState<{ provider: string; supports_staging?: boolean } | null>(null);
  const [capsLoading, setCapsLoading] = useState(true);
  const [error, setError] = useState('');

  // Changed-files list (accumulated across paged loads).
  const [files, setFiles] = useState<VcsChangedFile[]>([]);
  const [filesCursor, setFilesCursor] = useState<string | null>(null);
  const [filesHasMore, setFilesHasMore] = useState(false);
  const [filesLoading, setFilesLoading] = useState(false);
  const [filesLoadingMore, setFilesLoadingMore] = useState(false);
  const [sideBySide, setSideBySide] = useState(false);

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
    async (file: string, target?: string) => {
      if (!projectId || !file) return;
      const effTarget = target !== undefined ? target : selectedTarget;
      setFileStates((prev) => ({ ...prev, [file]: { ...(prev[file] ?? newFileState()), loading: true, error: '' } }));
      try {
        const res: VcsDiffResult = await getDiff({ projectId, bridgeId, file, target: effTarget, cursor: null }).unwrap();
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
    [projectId, bridgeId, getDiff, selectedTarget],
  );

  // loadMoreDiff appends the next diff page for a file (driven by its sentinel).
  const loadMoreDiff = useCallback(
    async (file: string, target?: string) => {
      if (!projectId || !file) return;
      const effTarget = target !== undefined ? target : selectedTarget;
      const cur = fileStatesRef.current[file];
      if (!cur || cur.loadingMore || !cur.hasMore) return;
      setFileStates((prev) => ({ ...prev, [file]: { ...(prev[file] ?? newFileState()), loadingMore: true } }));
      try {
        const res: VcsDiffResult = await getDiff({ projectId, bridgeId, file, target: effTarget, cursor: cur.cursor ?? null }).unwrap();
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
    [projectId, bridgeId, getDiff, selectedTarget],
  );

  const toggleCollapse = useCallback((path: string) => {
    setFileStates((prev) => ({ ...prev, [path]: { ...(prev[path] ?? newFileState()), collapsed: !prev[path]?.collapsed } }));
  }, []);

  // ---- Changed files --------------------------------------------------------

  const loadFiles = useCallback(
    async (opts?: { cursor?: string | null; append?: boolean; target?: string }) => {
      if (!projectId) return;
      const append = Boolean(opts?.append);
      const effTarget = opts?.target !== undefined ? opts.target : selectedTarget;
      setError('');
      if (append) setFilesLoadingMore(true);
      else setFilesLoading(true);
      try {
        const res: VcsFilesResult = await listFiles({
          projectId,
          bridgeId,
          target: effTarget,
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
        for (const f of incoming) void loadDiff(f.path, effTarget);
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
    [projectId, bridgeId, listFiles, loadDiff, selectedTarget],
  );

  const handleTargetChange = (newTarget: string) => {
    setSelectedTarget(newTarget);
    void loadFiles({ target: newTarget, append: false });
  };

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
        setCaps({ provider: res.provider, supports_staging: res.supports_staging });
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
      {/* Top toolbar with target dropdown and side-by-side vs unified diff toggle */}
      <div data-debug-id={`${debugPrefix}-toolbar`} className="flex shrink-0 items-center justify-between border-b border-subtle bg-surface px-3 py-1.5 text-caption gap-2">
        <div className="flex items-center gap-2 min-w-0">
          <span className="font-medium text-muted shrink-0">
            {files.length} changed {files.length === 1 ? 'file' : 'files'}
          </span>
          {targets.length > 0 ? (
            <div className="flex items-center gap-1 min-w-0">
              <span className="text-[11px] text-faint shrink-0">Diff:</span>
              <Select
                data-debug-id={`${debugPrefix}-target-select`}
                value={selectedTarget}
                onChange={(val) => handleTargetChange(val)}
                size="sm"
              >
                {targets.map((t) => (
                  <option key={t.id} value={t.id}>
                    {t.label}{t.is_default ? ' (default)' : ''}
                  </option>
                ))}
              </Select>
            </div>
          ) : null}
        </div>
        <button
          type="button"
          data-debug-id={`${debugPrefix}-diff-mode-toggle`}
          onClick={() => setSideBySide((prev) => !prev)}
          className={`rounded border px-2 py-0.5 text-caption font-medium transition-colors shrink-0 ${
            sideBySide
              ? 'border-accent bg-accent/20 text-accent'
              : 'border-subtle bg-neutral-soft text-muted hover:text-primary'
          }`}
          title={sideBySide ? 'Switch to Unified diff' : 'Switch to Side-by-Side diff'}
        >
          {sideBySide ? 'Side-by-Side' : 'Unified'}
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
                <div
                  data-debug-id={`${debugPrefix}-file-header-${f.path}`}
                  className="flex w-full items-center gap-2 px-3 py-2 text-left hover:bg-neutral-soft cursor-pointer select-none"
                  onClick={() => toggleCollapse(f.path)}
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

                  {/* Actions: Add / Stage and Revert / Discard */}
                  <div className="ml-2 flex shrink-0 items-center gap-1" onClick={(e) => e.stopPropagation()}>
                    <button
                      type="button"
                      data-debug-id={`${debugPrefix}-action-add-${f.path}`}
                      title={f.staged ? 'Already staged' : 'Stage / Add file'}
                      disabled={isActionLoading || f.staged}
                      onClick={async (e) => {
                        e.stopPropagation();
                        try {
                          await executeAction({ projectId, bridgeId, action: 'add', file: f.path }).unwrap();
                          void loadFiles();
                        } catch (err: any) {
                          setError(str(err?.message || err) || 'Failed to add file');
                        }
                      }}
                      className="rounded border border-subtle bg-surface-raised px-1.5 py-0.5 text-[10.5px] font-medium text-muted hover:bg-neutral-soft hover:text-primary transition-colors disabled:opacity-40"
                    >
                      Add
                    </button>

                    {confirmRevertFile === f.path ? (
                      <span className="flex items-center gap-1">
                        <span className="text-[10px] text-danger font-medium">Discard?</span>
                        <button
                          type="button"
                          data-debug-id={`${debugPrefix}-action-revert-confirm-${f.path}`}
                          title="Confirm revert"
                          disabled={isActionLoading}
                          onClick={async (e) => {
                            e.stopPropagation();
                            setConfirmRevertFile(null);
                            try {
                              await executeAction({ projectId, bridgeId, action: 'revert', file: f.path }).unwrap();
                              void loadFiles();
                            } catch (err: any) {
                              setError(str(err?.message || err) || 'Failed to revert file');
                            }
                          }}
                          className="rounded bg-danger px-1.5 py-0.5 text-[10px] font-semibold text-white hover:opacity-90"
                        >
                          Yes
                        </button>
                        <button
                          type="button"
                          data-debug-id={`${debugPrefix}-action-revert-cancel-${f.path}`}
                          title="Cancel revert"
                          onClick={(e) => {
                            e.stopPropagation();
                            setConfirmRevertFile(null);
                          }}
                          className="rounded px-1 py-0.5 text-[10px] text-muted hover:text-primary"
                        >
                          No
                        </button>
                      </span>
                    ) : (
                      <button
                        type="button"
                        data-debug-id={`${debugPrefix}-action-revert-${f.path}`}
                        title="Revert / Discard changes"
                        disabled={isActionLoading}
                        onClick={(e) => {
                          e.stopPropagation();
                          setConfirmRevertFile(f.path);
                        }}
                        className="rounded border border-subtle bg-surface-raised px-1.5 py-0.5 text-[10.5px] font-medium text-muted hover:bg-danger/10 hover:text-danger hover:border-danger/30 transition-colors disabled:opacity-40"
                      >
                        Revert
                      </button>
                    )}
                  </div>
                </div>

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
                      <MonacoDiffViewer hunks={fs.hunks} filePath={f.path} status={f.status} sideBySide={sideBySide} />
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
