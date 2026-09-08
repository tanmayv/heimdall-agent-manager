// FigDirectoryPicker — a unified bridge- and CitC-aware workspace & directory browser.
//
// Stage 1: Discovers and lists CitC workspaces sorted by recency descending,
// with search-as-you-type, relative age badges, and last sync from head CL badges.
// Stage 2: Browses the google3 hierarchy of the selected workspace with
// paginated directory browsing, search/filter, and breadcrumb navigation.
// Seamlessly switch workspaces anytime via breadcrumbs ('CitC Workspaces').

import { useEffect, useMemo, useState } from 'react';
import {
  useListBridgeFigWorkspacesQuery,
  useCreateBridgeFigWorkspaceMutation,
  useLazyListBridgeFigFsQuery,
  type FigFsEntry,
} from '../api/endpoints/bridgeFig';
import Icon from './Icon';

function str(v: any): string { return String(v ?? '').trim(); }

function normalizeGoogle3Path(raw: string): string {
  const clean = String(raw ?? '').trim().replace(/^(google3\/?)+/, '');
  const segments = clean.split('/').filter(Boolean);
  const resolved: string[] = [];
  for (const seg of segments) {
    if (seg === '.' || seg === 'google3') continue;
    if (seg === '..') {
      resolved.pop();
    } else {
      resolved.push(seg);
    }
  }
  return resolved.join('/');
}

function formatRelativeAge(iso?: string): string {
  if (!iso) return '';
  const d = new Date(iso);
  const t = d.getTime();
  if (isNaN(t)) return '';
  const diffSec = Math.floor((Date.now() - t) / 1000);
  if (diffSec < 0 || diffSec < 30) return 'just now';
  if (diffSec < 60) return `${diffSec}s ago`;
  const diffMin = Math.floor(diffSec / 60);
  if (diffMin < 60) return `${diffMin}m ago`;
  const diffHr = Math.floor(diffMin / 60);
  if (diffHr < 24) return `${diffHr}h ago`;
  const diffDays = Math.floor(diffHr / 24);
  if (diffDays < 30) return `${diffDays}d ago`;
  const diffMo = Math.floor(diffDays / 30);
  if (diffMo < 12) return `${diffMo}mo ago`;
  return `${Math.floor(diffDays / 365)}y ago`;
}

export default function FigDirectoryPicker({
  bridgeId,
  workspace: initialWorkspace = '',
  initialPath = '',
  onPick,
  onSelectWorkspace,
  onClose,
  debugId,
}: {
  bridgeId: string;
  workspace?: string;
  initialPath?: string;
  onPick: (path: string, workspaceName?: string) => void;
  onSelectWorkspace?: (workspaceName: string) => void;
  onClose?: () => void;
  debugId: string;
}) {
  const [activeWorkspace, setActiveWorkspace] = useState(initialWorkspace);
  const [wsSearch, setWsSearch] = useState('');
  const [debouncedSearch, setDebouncedSearch] = useState('');
  const [showNewWs, setShowNewWs] = useState(false);
  const [newWsInput, setNewWsInput] = useState('');
  const [createWsError, setCreateWsError] = useState('');

  useEffect(() => {
    const timer = setTimeout(() => {
      setDebouncedSearch(wsSearch.trim());
    }, 200);
    return () => clearTimeout(timer);
  }, [wsSearch]);

  // Workspaces query (search-as-you-type in API with 200ms debounce)
  const {
    data: wsData,
    isLoading: isWsLoading,
    isFetching: isWsFetching,
    error: wsQueryError,
    refetch: refetchWs,
  } = useListBridgeFigWorkspacesQuery(
    { bridgeId, query: debouncedSearch },
    { skip: !bridgeId }
  );

  const [createWorkspace, createWsState] = useCreateBridgeFigWorkspaceMutation();
  const [listFigFs, listState] = useLazyListBridgeFigFsQuery();

  // Directory browsing state for Stage 2
  const [cwd, setCwd] = useState(initialPath);
  const [entries, setEntries] = useState<FigFsEntry[]>([]);
  const [nextCursor, setNextCursor] = useState('');
  const [hasMore, setHasMore] = useState(false);
  const [dirError, setDirError] = useState('');
  const [dirFilterText, setDirFilterText] = useState('');
  const [jumpInput, setJumpInput] = useState(initialPath);
  const [isLoadingMore, setIsLoadingMore] = useState(false);

  // Concurrency guard
  const reqSeqRef = useState(() => ({ current: 0 }))[0];
  const activePathRef = useState(() => ({ current: initialPath }))[0];

  // Sync activeWorkspace if initialWorkspace prop updates
  useEffect(() => {
    if (initialWorkspace && initialWorkspace !== activeWorkspace) {
      setActiveWorkspace(initialWorkspace);
    }
  }, [initialWorkspace]);

  // Load directory inside activeWorkspace
  async function load(path: string) {
    if (!activeWorkspace) return;
    const cleanPath = normalizeGoogle3Path(path);
    const reqSeq = ++reqSeqRef.current;
    activePathRef.current = cleanPath;
    setDirError('');
    setDirFilterText('');
    setJumpInput(cleanPath);
    setCwd(cleanPath);
    setEntries([]);
    setNextCursor('');
    setHasMore(false);
    try {
      const res = await listFigFs({
        bridgeId,
        workspace: activeWorkspace,
        path: cleanPath,
        cursor: '',
        limit: 50,
      }).unwrap();

      if (reqSeq !== reqSeqRef.current) return;

      if (!res.ok) {
        setDirError(str(res.message) || res.error_code || 'Could not open directory');
        return;
      }

      setEntries(res.entries || []);
      setNextCursor(res.next_cursor || '');
      setHasMore(Boolean(res.has_more));
    } catch (e: any) {
      if (reqSeq !== reqSeqRef.current) return;
      setDirError(str(e?.data?.error?.message || e?.error || e?.message) || 'Bridge unavailable');
    }
  }

  // Load more directory entries
  async function loadMore() {
    if (!hasMore || !nextCursor || isLoadingMore || !activeWorkspace) return;
    const targetPath = activePathRef.current;
    const reqSeq = reqSeqRef.current;
    setIsLoadingMore(true);
    setDirError('');
    try {
      const res = await listFigFs({
        bridgeId,
        workspace: activeWorkspace,
        path: targetPath,
        cursor: nextCursor,
        limit: 50,
      }).unwrap();

      if (reqSeq !== reqSeqRef.current || activePathRef.current !== targetPath) {
        return;
      }

      if (!res.ok) {
        setDirError(str(res.message) || res.error_code || 'Could not load more items');
        return;
      }

      setEntries((prev) => [...prev, ...(res.entries || [])]);
      setNextCursor(res.next_cursor || '');
      setHasMore(Boolean(res.has_more));
    } catch (e: any) {
      if (reqSeq !== reqSeqRef.current || activePathRef.current !== targetPath) return;
      setDirError(str(e?.data?.error?.message || e?.error || e?.message) || 'Failed to load more');
    } finally {
      setIsLoadingMore(false);
    }
  }

  // Initial load when activeWorkspace changes
  useEffect(() => {
    if (activeWorkspace && bridgeId) {
      void load(initialPath);
    }
  }, [bridgeId, activeWorkspace]);

  // Handle workspace creation
  async function handleCreateWorkspaceSubmit(e?: React.FormEvent) {
    if (e) e.preventDefault();
    const name = newWsInput.trim();
    if (!name) return;
    setCreateWsError('');
    try {
      const res = await createWorkspace({ bridgeId, name }).unwrap();
      if (!res.ok) {
        setCreateWsError(str(res.message) || res.error_code || 'Could not create workspace');
        return;
      }
      setNewWsInput('');
      setShowNewWs(false);
      setActiveWorkspace(res.name);
      onSelectWorkspace?.(res.name);
      void load('');
    } catch (err: any) {
      setCreateWsError(str(err?.data?.error?.message || err?.error || err?.message) || 'Failed to create workspace');
    }
  }

  // Stage 2 Breadcrumbs: [path parts...]
  const crumbs = useMemo(() => {
    if (!cwd) return [] as { label: string; path: string }[];
    const parts = cwd.split('/').filter(Boolean);
    let acc = '';
    const out: { label: string; path: string }[] = [];
    for (const part of parts) {
      acc = acc ? `${acc}/${part}` : part;
      out.push({ label: part, path: acc });
    }
    return out;
  }, [cwd]);

  // Stage 2 Filtered Entries
  const visibleEntries = useMemo(() => {
    const q = dirFilterText.trim().toLowerCase();
    let list = entries;
    if (q) {
      list = list.filter((e) => e.name.toLowerCase().includes(q));
    }
    return [...list].sort((a, b) => {
      if (a.is_dir !== b.is_dir) return a.is_dir ? -1 : 1;
      return a.name.localeCompare(b.name);
    });
  }, [entries, dirFilterText]);

  function handleJumpSubmit(e?: React.FormEvent) {
    if (e) e.preventDefault();
    const query = dirFilterText.trim();
    if (!query) return;
    const target = query.replace(/^google3\/?/, '').replace(/^\/+|\/+$/g, '');
    void load(target);
  }

  const workspaces = wsData?.workspaces || [];

  return (
    <div data-debug-id={debugId} className="w-full rounded-xl border border-white/10 bg-[#121214] p-4 shadow-2xl">
      {/* ========================================================================= */}
      {/* STAGE 1: WORKSPACE SELECTION (when no active workspace or switcher active) */}
      {/* ========================================================================= */}
      {!activeWorkspace ? (
        <div>
          {/* Header */}
          <div className="mb-3 flex items-center justify-between gap-2">
            <div className="min-w-0">
              <div className="flex items-center gap-1.5 text-xs font-semibold text-zinc-300">
                <Icon name="folder" size={14} className="text-amber-400" />
                <span>CitC Workspaces · Select Workspace</span>
              </div>
              <div className="mt-0.5 truncate text-xs text-zinc-500">
                Choose a Client in the Cloud workspace on this bridge machine
              </div>
            </div>
            <div className="flex shrink-0 items-center gap-1.5">
              <button
                data-debug-id={`${debugId}-new-workspace-btn`}
                type="button"
                onClick={() => {
                  setShowNewWs((v) => !v);
                  setCreateWsError('');
                }}
                className="rounded-lg border border-white/10 bg-white/[0.05] px-3 py-1.5 text-xs font-semibold text-zinc-300 hover:bg-white/[0.1] transition"
              >
                + New CitC Workspace
              </button>
              {onClose ? (
                <button
                  data-debug-id={`${debugId}-close-btn`}
                  type="button"
                  onClick={onClose}
                  aria-label="Close"
                  className="rounded-lg p-1.5 text-zinc-400 hover:bg-white/10 hover:text-white transition"
                >
                  <Icon name="close" size={15} />
                </button>
              ) : null}
            </div>
          </div>

          {/* Inline New Workspace Form */}
          {showNewWs ? (
            <form onSubmit={handleCreateWorkspaceSubmit} className="mb-3 rounded-xl border border-white/10 bg-black/40 p-3">
              <div className="text-xs font-semibold text-zinc-300 mb-2">Create New CitC Workspace (<code>g4 citc</code>)</div>
              <div className="flex items-center gap-2">
                <input
                  data-debug-id={`${debugId}-new-ws-input`}
                  value={newWsInput}
                  onChange={(e) => setNewWsInput(e.target.value)}
                  placeholder="e.g. bugfix-cloudtop-agent"
                  className="flex-1 rounded-lg border border-white/10 bg-black/40 px-3 py-1.5 font-mono text-xs text-zinc-100 placeholder:text-zinc-500 outline-none focus:border-sky-500"
                />
                <button
                  data-debug-id={`${debugId}-create-ws-btn`}
                  type="submit"
                  disabled={createWsState.isLoading || !newWsInput.trim()}
                  className="rounded-lg bg-sky-600 hover:bg-sky-500 px-3.5 py-1.5 text-xs font-semibold text-white transition disabled:opacity-50"
                >
                  {createWsState.isLoading ? 'Creating…' : 'Create'}
                </button>
                <button
                  type="button"
                  onClick={() => setShowNewWs(false)}
                  className="rounded-lg bg-zinc-800 hover:bg-zinc-700 text-zinc-300 px-3 py-1.5 text-xs font-semibold transition"
                >
                  Cancel
                </button>
              </div>
              {createWsError ? (
                <p className="mt-1.5 text-xs text-red-400">{createWsError}</p>
              ) : null}
            </form>
          ) : null}

          {/* Search-as-you-type input */}
          <div className="mb-2 relative">
            <input
              data-debug-id={`${debugId}-workspace-filter`}
              value={wsSearch}
              onChange={(e) => setWsSearch(e.target.value)}
              placeholder="Search workspaces by name (e.g. heimdall, bob-agent)…"
              className="w-full rounded-lg border border-white/10 bg-black/40 px-3 py-2 text-xs text-zinc-100 placeholder:text-zinc-500 focus:border-sky-500 outline-none font-mono transition"
            />
            {isWsFetching ? (
              <span className="absolute right-3 top-2.5 text-[10px] text-zinc-400 animate-pulse font-mono">
                Filtering…
              </span>
            ) : null}
          </div>

          {/* Workspaces List */}
          <div data-debug-id={`${debugId}-workspaces-list`} className="max-h-[260px] overflow-y-auto rounded-xl border border-white/10 bg-black/20 p-1 space-y-0.5">
            {isWsLoading && workspaces.length === 0 ? (
              <div data-debug-id={`${debugId}-workspaces-loading`} className="p-6 text-center text-xs text-zinc-500">
                Loading CitC workspaces…
              </div>
            ) : wsQueryError ? (
              <div className="p-4 text-center text-xs text-zinc-400">
                CitC workspace discovery failed.
                <button
                  type="button"
                  onClick={() => refetchWs()}
                  className="ml-2 text-sky-400 underline hover:text-sky-300"
                >
                  Retry
                </button>
              </div>
            ) : workspaces.length === 0 ? (
              <div data-debug-id={`${debugId}-workspaces-empty`} className="p-6 text-center text-xs text-zinc-500">
                {wsSearch ? `No CitC workspaces matching "${wsSearch}".` : 'No CitC workspaces found.'}
              </div>
            ) : (
              workspaces.map((ws) => (
                <button
                  key={ws.name}
                  data-debug-id={`${debugId}-ws-${ws.name}`}
                  type="button"
                  onClick={() => {
                    setActiveWorkspace(ws.name);
                    onSelectWorkspace?.(ws.name);
                    void load('');
                  }}
                  className="flex w-full items-center justify-between gap-3 px-3 py-2 rounded-lg hover:bg-white/[0.04] transition cursor-pointer text-left group"
                >
                  <div className="flex items-center gap-2.5 min-w-0">
                    <Icon name="folder" size={15} className="shrink-0 text-amber-400 group-hover:scale-105 transition-transform" />
                    <span className="text-zinc-200 text-sm font-medium font-mono truncate group-hover:text-white transition-colors">
                      {ws.name}
                    </span>
                  </div>
                  <div className="flex items-center gap-3 shrink-0">
                    {ws.last_sync_head_change ? (
                      <span className="text-zinc-500 font-mono text-xs">
                        CL {ws.last_sync_head_change}
                      </span>
                    ) : null}
                    {ws.age_text ? (
                      <span className="text-zinc-500 text-xs font-mono">
                        {ws.age_text}
                      </span>
                    ) : null}
                    <Icon name="chevron-right" size={14} className="text-zinc-600 group-hover:text-zinc-400 transition-colors" />
                  </div>
                </button>
              ))
            )}
          </div>
        </div>
      ) : (
        /* ========================================================================= */
        /* STAGE 2: GOOGLE3 DIRECTORY BROWSING & ACTIONS */
        /* ========================================================================= */
        <div>
          {/* Header */}
          <div className="mb-3 flex items-center justify-between gap-2">
            <div className="min-w-0">
              <div className="flex items-center gap-1.5 text-xs font-semibold text-zinc-300">
                <Icon name="folder" size={14} className="text-amber-400" />
                <span>CitC Browse · {activeWorkspace}</span>
              </div>
              <div className="mt-0.5 truncate font-mono text-xs text-zinc-500">
                /google/src/cloud/…/{activeWorkspace}/google3{cwd ? `/${cwd}` : ''}
              </div>
            </div>
            <div className="flex shrink-0 items-center gap-1.5">
              <button
                data-debug-id={`${debugId}-root-btn`}
                type="button"
                onClick={() => void load('')}
                title="Go to google3 root"
                className="rounded-lg border border-white/10 px-2.5 py-1 text-xs text-zinc-300 hover:bg-white/10 transition"
              >
                google3
              </button>
              <button
                data-debug-id={`${debugId}-switch-ws-btn`}
                type="button"
                onClick={() => setActiveWorkspace('')}
                title="Switch CitC Workspace"
                className="rounded-lg border border-white/10 bg-white/[0.05] px-2.5 py-1 text-xs font-semibold text-zinc-300 hover:bg-white/[0.1] transition"
              >
                Switch Workspace
              </button>
              {onClose ? (
                <button
                  data-debug-id={`${debugId}-close-btn`}
                  type="button"
                  onClick={onClose}
                  aria-label="Close"
                  className="rounded-lg p-1.5 text-zinc-400 hover:bg-white/10 hover:text-white transition"
                >
                  <Icon name="close" size={15} />
                </button>
              ) : null}
            </div>
          </div>

          {/* Breadcrumb Navigation: 'CitC Workspaces > [activeWorkspace] > [subdirs]' */}
          <div data-debug-id={`${debugId}-breadcrumb`} className="mb-2.5 flex flex-wrap items-center gap-1 text-xs text-zinc-400">
            <button
              data-debug-id={`${debugId}-crumb-workspaces`}
              type="button"
              onClick={() => setActiveWorkspace('')}
              className="flex items-center gap-1 rounded px-1.5 py-0.5 font-medium text-zinc-300 hover:bg-white/10 hover:text-white transition"
              title="Click to switch workspace"
            >
              CitC Workspaces
            </button>
            <Icon name="chevron-right" size={12} className="text-zinc-600" />
            <button
              data-debug-id={`${debugId}-crumb-ws-root`}
              type="button"
              onClick={() => void load('')}
              className="max-w-[160px] truncate rounded px-1.5 py-0.5 font-mono text-xs font-medium text-zinc-200 hover:bg-white/10 hover:text-white transition"
              title="google3 root"
            >
              {activeWorkspace} (google3)
            </button>
            {crumbs.map((c, i) => (
              <span key={c.path} className="flex items-center gap-1">
                <Icon name="chevron-right" size={12} className="text-zinc-600" />
                <button
                  data-debug-id={`${debugId}-crumb-${i}`}
                  type="button"
                  onClick={() => void load(c.path)}
                  className="max-w-[160px] truncate rounded px-1.5 py-0.5 font-mono text-xs text-zinc-400 hover:bg-white/10 hover:text-white transition"
                >
                  {c.label}
                </button>
              </span>
            ))}
          </div>

          {/* Single clean search / filter input */}
          <div className="mb-2.5">
            <input
              data-debug-id={`${debugId}-filter-input`}
              value={dirFilterText}
              onChange={(e) => setDirFilterText(e.target.value)}
              onKeyDown={(e) => {
                if (e.key === 'Enter') {
                  e.preventDefault();
                  handleJumpSubmit();
                }
              }}
              placeholder="Search or jump to path (e.g. cloud/security)…"
              className="w-full rounded-lg border border-white/10 bg-black/40 px-3 py-2 text-xs text-zinc-100 placeholder:text-zinc-500 focus:border-sky-500 outline-none transition font-mono"
            />
          </div>

          {/* Directory Entry List */}
          <div data-debug-id={`${debugId}-list`} className="max-h-[220px] overflow-y-auto rounded-xl border border-white/10 bg-black/20">
            {listState.isFetching && entries.length === 0 ? (
              <div data-debug-id={`${debugId}-loading`} className="p-4 text-center text-xs text-zinc-500">
                Loading google3 directory…
              </div>
            ) : visibleEntries.length === 0 ? (
              <div data-debug-id={`${debugId}-empty`} className="p-4 text-center text-xs text-zinc-600">
                {dirFilterText ? 'No matching entries in this folder.' : 'Empty directory.'}
              </div>
            ) : (
              <div>
                {visibleEntries.map((e) => (
                  <button
                    key={e.name}
                    data-debug-id={`${debugId}-entry-${e.name}`}
                    type="button"
                    onClick={() => {
                      if (e.is_dir) {
                        void load(e.path || (cwd ? `${cwd}/${e.name}` : e.name));
                      }
                    }}
                    disabled={!e.is_dir}
                    className={`flex w-full items-center justify-between gap-3 px-3 py-2 text-left transition border-b border-white/[0.04] last:border-b-0 ${
                      e.is_dir ? 'hover:bg-white/[0.04] cursor-pointer group' : 'cursor-default opacity-60'
                    }`}
                  >
                    <div className="flex items-center gap-2.5 min-w-0">
                      <Icon
                        name={e.is_dir ? 'folder' : 'file'}
                        size={15}
                        className={`shrink-0 ${e.is_dir ? 'text-amber-400 group-hover:scale-105 transition-transform' : 'text-zinc-600'}`}
                      />
                      <span className="min-w-0 truncate font-mono text-xs text-zinc-200 group-hover:text-white transition-colors">{e.name}</span>
                    </div>
                    <div className="flex items-center gap-3 shrink-0">
                      {e.modified_at ? (
                        <span className="text-zinc-500 text-xs font-mono">
                          {formatRelativeAge(e.modified_at)}
                        </span>
                      ) : null}
                      {e.is_dir && <Icon name="chevron-right" size={14} className="shrink-0 text-zinc-600 group-hover:text-zinc-400 transition-colors" />}
                    </div>
                  </button>
                ))}

                {/* Pagination: Load More */}
                {hasMore ? (
                  <div className="p-2 text-center border-t border-white/[0.06]">
                    <button
                      data-debug-id={`${debugId}-load-more-btn`}
                      type="button"
                      disabled={isLoadingMore}
                      onClick={loadMore}
                      className="rounded-lg bg-white/[0.08] px-3.5 py-1.5 text-xs font-medium text-zinc-300 hover:bg-white/[0.14] disabled:opacity-50 transition"
                    >
                      {isLoadingMore ? 'Loading more…' : `Load more entries (${entries.length} loaded)`}
                    </button>
                  </div>
                ) : null}
              </div>
            )}
          </div>

          {dirError ? <p data-debug-id={`${debugId}-error`} className="mt-2 text-xs text-red-400">{dirError}</p> : null}

          {/* Selected path preview and Action buttons */}
          <div className="mt-3 flex flex-col sm:flex-row sm:items-center justify-between gap-2 pt-2 border-t border-white/10">
            <div className="min-w-0 truncate text-xs text-zinc-400">
              Selected: <span className="font-mono text-zinc-200">/{activeWorkspace}/google3{cwd ? `/${cwd}` : ''}</span>
            </div>
            <div className="flex items-center gap-2">
              <button
                data-debug-id={`${debugId}-pick-root-btn`}
                type="button"
                onClick={() => onPick('', activeWorkspace)}
                className="rounded-lg bg-zinc-800 hover:bg-zinc-700 text-zinc-300 px-3.5 py-2 text-xs font-semibold transition"
              >
                Select google3 Root
              </button>
              <button
                data-debug-id={`${debugId}-pick-btn`}
                type="button"
                onClick={() => onPick(cwd, activeWorkspace)}
                className="rounded-lg bg-sky-600 hover:bg-sky-500 text-white px-4 py-2 text-xs font-semibold transition"
              >
                Select This Folder
              </button>
            </div>
          </div>
        </div>
      )}
    </div>
  );
}
