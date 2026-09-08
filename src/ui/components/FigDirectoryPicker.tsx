// FigDirectoryPicker — a bridge- and CitC-aware directory browser.
//
// Browses the google3 hierarchy of a selected CitC workspace on a bridge host.
// Supports breadcrumbs navigation, direct path jump/search, and paginated lazy
// directory browsing (50 items per batch).

import { useEffect, useMemo, useState } from 'react';
import { useLazyListBridgeFigFsQuery, type FigFsEntry } from '../api/endpoints/bridgeFig';
import Icon from './Icon';

function str(v: any): string { return String(v ?? '').trim(); }

function normalizeGoogle3Path(raw: string): string {
  const clean = String(raw ?? '').trim().replace(/^google3\/?/, '');
  const segments = clean.split('/').filter(Boolean);
  const resolved: string[] = [];
  for (const seg of segments) {
    if (seg === '.') continue;
    if (seg === '..') {
      resolved.pop();
    } else {
      resolved.push(seg);
    }
  }
  return resolved.join('/');
}

export default function FigDirectoryPicker({
  bridgeId,
  workspace,
  initialPath = '',
  onPick,
  onClose,
  debugId,
}: {
  bridgeId: string;
  workspace: string;
  initialPath?: string;
  onPick: (path: string) => void;
  onClose?: () => void;
  debugId: string;
}) {
  const [listFigFs, listState] = useLazyListBridgeFigFsQuery();

  const [cwd, setCwd] = useState(initialPath);
  const [entries, setEntries] = useState<FigFsEntry[]>([]);
  const [nextCursor, setNextCursor] = useState('');
  const [hasMore, setHasMore] = useState(false);
  const [error, setError] = useState('');
  const [filterText, setFilterText] = useState('');
  const [jumpInput, setJumpInput] = useState(initialPath);
  const [isLoadingMore, setIsLoadingMore] = useState(false);

  // Guard against concurrency race conditions and out-of-order responses
  const reqSeqRef = useState(() => ({ current: 0 }))[0];
  const activePathRef = useState(() => ({ current: initialPath }))[0];

  // Load a directory (resets pagination to page 1)
  async function load(path: string) {
    const cleanPath = normalizeGoogle3Path(path);
    const reqSeq = ++reqSeqRef.current;
    activePathRef.current = cleanPath;
    setError('');
    setFilterText('');
    setJumpInput(cleanPath);
    setCwd(cleanPath);
    setEntries([]);
    setNextCursor('');
    setHasMore(false);
    try {
      const res = await listFigFs({
        bridgeId,
        workspace,
        path: cleanPath,
        cursor: '',
        limit: 50,
      }).unwrap();

      if (reqSeq !== reqSeqRef.current) return; // Discard obsolete response

      if (!res.ok) {
        setError(str(res.message) || res.error_code || 'Could not open directory');
        return;
      }

      setEntries(res.entries || []);
      setNextCursor(res.next_cursor || '');
      setHasMore(Boolean(res.has_more));
    } catch (e: any) {
      if (reqSeq !== reqSeqRef.current) return;
      setError(str(e?.data?.error?.message || e?.error || e?.message) || 'Bridge unavailable');
    }
  }

  // Load more entries using cursor (guards against directory switching during in-flight pagination)
  async function loadMore() {
    if (!hasMore || !nextCursor || isLoadingMore) return;
    const targetPath = activePathRef.current;
    const reqSeq = reqSeqRef.current;
    setIsLoadingMore(true);
    setError('');
    try {
      const res = await listFigFs({
        bridgeId,
        workspace,
        path: targetPath,
        cursor: nextCursor,
        limit: 50,
      }).unwrap();

      if (reqSeq !== reqSeqRef.current || activePathRef.current !== targetPath) {
        return; // Directory changed while paginating, discard stale page
      }

      if (!res.ok) {
        setError(str(res.message) || res.error_code || 'Could not load more items');
        return;
      }

      setEntries((prev) => [...prev, ...(res.entries || [])]);
      setNextCursor(res.next_cursor || '');
      setHasMore(Boolean(res.has_more));
    } catch (e: any) {
      if (reqSeq !== reqSeqRef.current || activePathRef.current !== targetPath) return;
      setError(str(e?.data?.error?.message || e?.error || e?.message) || 'Failed to load more');
    } finally {
      setIsLoadingMore(false);
    }
  }

  useEffect(() => {
    if (workspace && bridgeId) {
      void load(initialPath);
    }
  }, [bridgeId, workspace]);

  // Breadcrumbs: google3 root -> each segment
  const crumbs = useMemo(() => {
    const out: { label: string; path: string }[] = [{ label: 'google3', path: '' }];
    if (!cwd) return out;
    const parts = cwd.split('/').filter(Boolean);
    let acc = '';
    for (const part of parts) {
      acc = acc ? `${acc}/${part}` : part;
      out.push({ label: part, path: acc });
    }
    return out;
  }, [cwd]);

  // Filtered visible entries (dirs first, case-insensitive match on name)
  const visibleEntries = useMemo(() => {
    const q = filterText.trim().toLowerCase();
    let list = entries;
    if (q) {
      list = list.filter((e) => e.name.toLowerCase().includes(q));
    }
    return [...list].sort((a, b) => {
      if (a.is_dir !== b.is_dir) return a.is_dir ? -1 : 1;
      return a.name.localeCompare(b.name);
    });
  }, [entries, filterText]);

  function handleJumpSubmit(e?: React.FormEvent) {
    if (e) e.preventDefault();
    const target = jumpInput.trim().replace(/^google3\/?/, '').replace(/^\/+|\/+$/g, '');
    void load(target);
  }

  return (
    <div data-debug-id={debugId} className="w-full rounded-2xl border border-amber-500/20 bg-[#0f1115] p-3 shadow-2xl">
      <div className="mb-2 flex items-center justify-between gap-2">
        <div className="min-w-0">
          <div className="flex items-center gap-1.5 text-[11px] font-semibold uppercase tracking-[0.14em] text-amber-400">
            <Icon name="folder" size={13} className="text-amber-400" />
            <span>CitC Browse · {workspace}</span>
          </div>
          <div className="mt-0.5 truncate font-mono text-[10px] text-zinc-500">
            /google/src/cloud/…/{workspace}/google3{cwd ? `/${cwd}` : ''}
          </div>
        </div>
        <div className="flex shrink-0 items-center gap-1">
          <button
            data-debug-id={`${debugId}-root-btn`}
            type="button"
            onClick={() => void load('')}
            title="Go to google3 root"
            className="rounded-lg border border-white/10 px-2 py-1 text-[11px] text-zinc-300 hover:bg-white/10"
          >
            google3
          </button>
          {onClose ? (
            <button
              data-debug-id={`${debugId}-close-btn`}
              type="button"
              onClick={onClose}
              aria-label="Close"
              className="rounded-lg p-1 text-zinc-500 hover:bg-white/10 hover:text-white"
            >
              <Icon name="close" size={15} />
            </button>
          ) : null}
        </div>
      </div>

      {/* Breadcrumb Navigation */}
      <div data-debug-id={`${debugId}-breadcrumb`} className="mb-2 flex flex-wrap items-center gap-1 text-[12px] text-zinc-400">
        {crumbs.map((c, i) => (
          <span key={c.path || 'root'} className="flex items-center gap-1">
            {i > 0 ? <Icon name="chevron-right" size={12} className="text-zinc-600" /> : null}
            <button
              data-debug-id={`${debugId}-crumb-${i}`}
              type="button"
              onClick={() => void load(c.path)}
              className="max-w-[160px] truncate rounded px-1.5 py-0.5 font-mono text-[11px] hover:bg-white/10 hover:text-white"
            >
              {c.label}
            </button>
          </span>
        ))}
      </div>

      {/* Direct Jump & Filter Bar */}
      <div className="mb-2 grid grid-cols-1 sm:grid-cols-2 gap-2">
        <form onSubmit={handleJumpSubmit} className="flex items-center gap-1">
          <input
            data-debug-id={`${debugId}-jump-input`}
            value={jumpInput}
            onChange={(e) => setJumpInput(e.target.value)}
            placeholder="jump to path (e.g. cloud/security)"
            className="w-full rounded-lg border border-white/10 bg-black/30 px-2.5 py-1.5 font-mono text-[11.5px] text-white placeholder-zinc-600 focus:border-amber-400/60 outline-none"
          />
          <button
            data-debug-id={`${debugId}-jump-btn`}
            type="submit"
            className="shrink-0 rounded-lg bg-white/10 px-2.5 py-1.5 text-[11px] font-medium text-zinc-200 hover:bg-white/20"
          >
            Go
          </button>
        </form>
        <div className="relative">
          <input
            data-debug-id={`${debugId}-filter-input`}
            value={filterText}
            onChange={(e) => setFilterText(e.target.value)}
            placeholder="Filter current view…"
            className="w-full rounded-lg border border-white/10 bg-black/30 px-2.5 py-1.5 text-[11.5px] text-white placeholder-zinc-600 focus:border-amber-400/60 outline-none"
          />
        </div>
      </div>

      {/* Directory Entry List */}
      <div data-debug-id={`${debugId}-list`} className="max-h-[240px] overflow-y-auto rounded-xl border border-white/8 bg-black/20">
        {listState.isFetching && entries.length === 0 ? (
          <div data-debug-id={`${debugId}-loading`} className="p-4 text-center text-xs text-zinc-500">Loading google3 directory…</div>
        ) : visibleEntries.length === 0 ? (
          <div data-debug-id={`${debugId}-empty`} className="p-4 text-center text-xs text-zinc-600">
            {filterText ? 'No matching entries in this folder.' : 'Empty directory.'}
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
                className={`flex w-full items-center gap-2 border-b border-white/[0.04] px-3 py-1.5 text-left text-[12.5px] last:border-b-0 ${
                  e.is_dir ? 'text-zinc-200 hover:bg-white/[0.06] cursor-pointer' : 'text-zinc-500 cursor-default'
                }`}
              >
                <Icon
                  name={e.is_dir ? 'folder' : 'file'}
                  size={14}
                  className={`shrink-0 ${e.is_dir ? 'text-amber-400' : 'text-zinc-600'}`}
                />
                <span className="min-w-0 flex-1 truncate font-mono text-[12px]">{e.name}</span>
                {e.is_dir && <Icon name="chevron-right" size={13} className="shrink-0 text-zinc-600" />}
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
                  className="rounded-lg bg-white/[0.08] px-3 py-1 text-[11px] font-medium text-amber-300 hover:bg-white/[0.14] disabled:opacity-50"
                >
                  {isLoadingMore ? 'Loading more…' : `Load more entries (${entries.length} loaded)`}
                </button>
              </div>
            ) : null}
          </div>
        )}
      </div>

      {error ? <p data-debug-id={`${debugId}-error`} className="mt-2 text-[11px] text-red-300">{error}</p> : null}

      {/* Selected path and action button */}
      <div className="mt-3 flex items-center justify-between gap-2 pt-2 border-t border-white/10">
        <div className="min-w-0 truncate text-[11px] text-zinc-400">
          Selected: <span className="font-mono text-amber-300">google3/{cwd || ''}</span>
        </div>
        <button
          data-debug-id={`${debugId}-pick-btn`}
          type="button"
          onClick={() => onPick(cwd)}
          className="rounded-xl bg-amber-400 px-4 py-2 text-[12px] font-bold text-black hover:bg-amber-300"
        >
          Use this relative path
        </button>
      </div>
    </div>
  );
}
