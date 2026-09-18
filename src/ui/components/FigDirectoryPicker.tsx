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
import { Badge, Button, Icon, IconButton, Input, Panel, StatusPill } from '@ui';

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
    <Panel data-debug-id={debugId} tone="raised" padding="md" className="w-full shadow-2xl">
      {/* ========================================================================= */}
      {/* STAGE 1: WORKSPACE SELECTION (when no active workspace or switcher active) */}
      {/* ========================================================================= */}
      {!activeWorkspace ? (
        <div>
          {/* Header */}
          <div className="mb-3 flex items-center justify-between gap-2">
            <div className="min-w-0">
              <div className="flex items-center gap-1.5 text-xs font-semibold text-primary">
                <Icon name="folder" size={14} className="text-warning" />
                <span>CitC Workspaces · Select Workspace</span>
                <StatusPill tone="warning" emphasis="soft">CitC</StatusPill>
              </div>
              <div className="mt-0.5 truncate text-xs text-muted">
                Choose a Client in the Cloud workspace on this bridge machine
              </div>
            </div>
            <div className="flex shrink-0 items-center gap-1.5">
              <Button
                data-debug-id={`${debugId}-new-workspace-btn`}
                variant="secondary"
                size="sm"
                onClick={() => {
                  setShowNewWs((v) => !v);
                  setCreateWsError('');
                }}
                leading={<Icon name="plus" size={12} />}
              >
                New CitC Workspace
              </Button>
              {onClose ? (
                <IconButton
                  data-debug-id={`${debugId}-close-btn`}
                  icon="close"
                  label="Close"
                  size="sm"
                  onClick={onClose}
                />
              ) : null}
            </div>
          </div>

          {/* Inline New Workspace Form */}
          {showNewWs ? (
            <form onSubmit={handleCreateWorkspaceSubmit} className="mb-3 rounded-xl border border-subtle bg-surface p-3">
              <div className="text-xs font-semibold text-primary mb-2">Create New CitC Workspace (<code>g4 citc</code>)</div>
              <div className="flex items-center gap-2">
                <Input
                  data-debug-id={`${debugId}-new-ws-input`}
                  value={newWsInput}
                  onChange={setNewWsInput}
                  placeholder="e.g. bugfix-cloudtop-agent"
                  size="sm"
                  className="flex-1 font-mono"
                />
                <Button
                  data-debug-id={`${debugId}-create-ws-btn`}
                  type="submit"
                  variant="primary"
                  size="sm"
                  disabled={createWsState.isLoading || !newWsInput.trim()}
                  loading={createWsState.isLoading}
                >
                  {createWsState.isLoading ? 'Creating…' : 'Create'}
                </Button>
                <Button
                  variant="ghost"
                  size="sm"
                  onClick={() => setShowNewWs(false)}
                >
                  Cancel
                </Button>
              </div>
              {createWsError ? (
                <p className="mt-1.5 text-xs text-danger">{createWsError}</p>
              ) : null}
            </form>
          ) : null}

          {/* Search-as-you-type input */}
          <div className="mb-2 relative">
            <Input
              data-debug-id={`${debugId}-workspace-filter`}
              value={wsSearch}
              onChange={setWsSearch}
              placeholder="Search workspaces by name (e.g. heimdall, bob-agent)…"
              width="full"
              className="font-mono text-xs"
            />
            {isWsFetching ? (
              <span className="absolute right-3 top-2.5 text-[10px] text-muted animate-pulse font-mono">
                Filtering…
              </span>
            ) : null}
          </div>

          {/* Workspaces List */}
          <div data-debug-id={`${debugId}-workspaces-list`} className="max-h-[260px] overflow-y-auto rounded-xl border border-subtle bg-surface p-1 space-y-0.5">
            {isWsLoading && workspaces.length === 0 ? (
              <div data-debug-id={`${debugId}-workspaces-loading`} className="p-6 text-center text-xs text-muted">
                Loading CitC workspaces…
              </div>
            ) : wsQueryError ? (
              <div className="p-4 text-center text-xs text-muted">
                CitC workspace discovery failed.
                <Button
                  variant="ghost"
                  size="sm"
                  onClick={() => refetchWs()}
                  className="ml-2 text-accent"
                >
                  Retry
                </Button>
              </div>
            ) : workspaces.length === 0 ? (
              <div data-debug-id={`${debugId}-workspaces-empty`} className="p-6 text-center text-xs text-faint">
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
                  className="flex w-full items-center justify-between gap-3 px-3 py-2 rounded-lg hover:bg-surface-raised transition cursor-pointer text-left group"
                >
                  <div className="flex items-center gap-2.5 min-w-0">
                    <Icon name="folder" size={15} className="shrink-0 text-warning group-hover:scale-105 transition-transform" />
                    <span className="text-primary text-sm font-medium font-mono truncate">
                      {ws.name}
                    </span>
                  </div>
                  <div className="flex items-center gap-3 shrink-0">
                    {ws.last_sync_head_change ? (
                      <Badge tone="neutral" emphasis="soft" className="font-mono text-xs">
                        CL {ws.last_sync_head_change}
                      </Badge>
                    ) : null}
                    {ws.age_text ? (
                      <Badge tone="neutral" emphasis="soft" className="font-mono text-xs">
                        {ws.age_text}
                      </Badge>
                    ) : null}
                    <Icon name="chevron-right" size={14} className="text-faint group-hover:text-muted transition-colors" />
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
              <div className="flex items-center gap-1.5 text-xs font-semibold text-primary">
                <Icon name="folder" size={14} className="text-warning" />
                <span>CitC Browse</span>
                <StatusPill tone="warning" emphasis="soft">{activeWorkspace}</StatusPill>
              </div>
              <div className="mt-0.5 truncate font-mono text-xs text-muted">
                /google/src/cloud/…/{activeWorkspace}/google3{cwd ? `/${cwd}` : ''}
              </div>
            </div>
            <div className="flex shrink-0 items-center gap-1.5">
              <Button
                data-debug-id={`${debugId}-root-btn`}
                variant="secondary"
                size="sm"
                onClick={() => void load('')}
                title="Go to google3 root"
              >
                google3
              </Button>
              <Button
                data-debug-id={`${debugId}-switch-ws-btn`}
                variant="secondary"
                size="sm"
                onClick={() => setActiveWorkspace('')}
                title="Switch CitC Workspace"
              >
                Switch Workspace
              </Button>
              {onClose ? (
                <IconButton
                  data-debug-id={`${debugId}-close-btn`}
                  icon="close"
                  label="Close"
                  size="sm"
                  onClick={onClose}
                />
              ) : null}
            </div>
          </div>

          {/* Breadcrumb Navigation: 'CitC Workspaces > [activeWorkspace] > [subdirs]' */}
          <div data-debug-id={`${debugId}-breadcrumb`} className="mb-2.5 flex flex-wrap items-center gap-1 text-xs text-muted">
            <button
              data-debug-id={`${debugId}-crumb-workspaces`}
              type="button"
              onClick={() => setActiveWorkspace('')}
              className="flex items-center gap-1 rounded px-1.5 py-0.5 font-medium text-primary hover:bg-neutral-soft transition"
              title="Click to switch workspace"
            >
              CitC Workspaces
            </button>
            <Icon name="chevron-right" size={12} className="text-faint" />
            <button
              data-debug-id={`${debugId}-crumb-ws-root`}
              type="button"
              onClick={() => void load('')}
              className="max-w-[160px] truncate rounded px-1.5 py-0.5 font-mono text-xs font-medium text-primary hover:bg-neutral-soft transition"
              title="google3 root"
            >
              {activeWorkspace} (google3)
            </button>
            {crumbs.map((c, i) => (
              <span key={c.path} className="flex items-center gap-1">
                <Icon name="chevron-right" size={12} className="text-faint" />
                <button
                  data-debug-id={`${debugId}-crumb-${i}`}
                  type="button"
                  onClick={() => void load(c.path)}
                  className="max-w-[160px] truncate rounded px-1.5 py-0.5 font-mono text-xs text-muted hover:bg-neutral-soft hover:text-primary transition"
                >
                  {c.label}
                </button>
              </span>
            ))}
          </div>

          {/* Single clean search / filter input */}
          <div className="mb-2.5">
            <Input
              data-debug-id={`${debugId}-filter-input`}
              value={dirFilterText}
              onChange={setDirFilterText}
              onKeyDown={(e) => {
                if (e.key === 'Enter') {
                  e.preventDefault();
                  handleJumpSubmit();
                }
              }}
              placeholder="Search or jump to path (e.g. cloud/security)…"
              width="full"
              className="font-mono text-xs"
            />
          </div>

          {/* Directory Entry List */}
          <div data-debug-id={`${debugId}-list`} className="max-h-[220px] overflow-y-auto rounded-xl border border-subtle bg-surface">
            {listState.isFetching && entries.length === 0 ? (
              <div data-debug-id={`${debugId}-loading`} className="p-4 text-center text-xs text-muted">
                Loading google3 directory…
              </div>
            ) : visibleEntries.length === 0 ? (
              <div data-debug-id={`${debugId}-empty`} className="p-4 text-center text-xs text-faint">
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
                    className={`flex w-full items-center justify-between gap-3 px-3 py-2 text-left transition border-b border-subtle last:border-b-0 ${
                      e.is_dir ? 'hover:bg-surface-raised cursor-pointer group' : 'cursor-default opacity-60'
                    }`}
                  >
                    <div className="flex items-center gap-2.5 min-w-0">
                      <Icon
                        name={e.is_dir ? 'folder' : 'file'}
                        size={15}
                        className={`shrink-0 ${e.is_dir ? 'text-warning group-hover:scale-105 transition-transform' : 'text-faint'}`}
                      />
                      <span className="min-w-0 truncate font-mono text-xs text-primary">{e.name}</span>
                    </div>
                    <div className="flex items-center gap-3 shrink-0">
                      {e.modified_at ? (
                        <Badge tone="neutral" emphasis="soft" className="font-mono text-xs">
                          {formatRelativeAge(e.modified_at)}
                        </Badge>
                      ) : null}
                      {e.is_dir && <Icon name="chevron-right" size={14} className="shrink-0 text-faint group-hover:text-muted transition-colors" />}
                    </div>
                  </button>
                ))}

                {/* Pagination: Load More */}
                {hasMore ? (
                  <div className="p-2 text-center border-t border-subtle">
                    <Button
                      data-debug-id={`${debugId}-load-more-btn`}
                      variant="secondary"
                      size="sm"
                      disabled={isLoadingMore}
                      loading={isLoadingMore}
                      onClick={loadMore}
                    >
                      {isLoadingMore ? 'Loading more…' : `Load more entries (${entries.length} loaded)`}
                    </Button>
                  </div>
                ) : null}
              </div>
            )}
          </div>

          {dirError ? <p data-debug-id={`${debugId}-error`} className="mt-2 text-xs text-danger">{dirError}</p> : null}

          {/* Selected path preview and Action buttons */}
          <div className="mt-3 flex flex-col sm:flex-row sm:items-center justify-between gap-2 pt-2 border-t border-subtle">
            <div className="min-w-0 truncate text-xs text-muted">
              Selected: <span className="font-mono text-primary">/{activeWorkspace}/google3{cwd ? `/${cwd}` : ''}</span>
            </div>
            <div className="flex items-center gap-2">
              <Button
                data-debug-id={`${debugId}-pick-root-btn`}
                variant="secondary"
                size="md"
                onClick={() => onPick('', activeWorkspace)}
              >
                Select google3 Root
              </Button>
              <Button
                data-debug-id={`${debugId}-pick-btn`}
                variant="primary"
                size="md"
                onClick={() => onPick(cwd, activeWorkspace)}
              >
                Select This Folder
              </Button>
            </div>
          </div>
        </div>
      )}
    </Panel>
  );
}
