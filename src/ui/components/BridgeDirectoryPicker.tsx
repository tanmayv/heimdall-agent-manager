// BridgeDirectoryPicker — a bridge-aware directory browser + creator.
//
// Lets the user pick (or create) a directory on a specific bridge's machine,
// sandboxed to that bridge's fs_root. Used for overriding a project's per-bridge
// path. Browse into dirs, breadcrumb up (bounded to root), toggle hidden entries,
// create a new folder, or create a typed-but-missing path.

import { useEffect, useMemo, useState } from 'react';
import { useLazyListBridgeDirQuery, useMkdirBridgePathMutation, type BridgeFsEntry } from '../api/endpoints/bridgeFs';
import Icon from './Icon';

function str(v: any): string { return String(v ?? '').trim(); }

export default function BridgeDirectoryPicker({
  bridgeId,
  bridgeLabel,
  initialPath = '',
  onPick,
  onClose,
  debugId,
}: {
  bridgeId: string;
  bridgeLabel?: string;
  initialPath?: string;
  onPick: (path: string) => void;
  onClose?: () => void;
  debugId: string;
}) {
  const [listDir, listState] = useLazyListBridgeDirQuery();
  const [mkdir, mkdirState] = useMkdirBridgePathMutation();

  const [cwd, setCwd] = useState('');            // canonical path currently shown
  const [root, setRoot] = useState('');
  const [parent, setParent] = useState('');
  const [entries, setEntries] = useState<BridgeFsEntry[]>([]);
  const [error, setError] = useState('');
  const [showHidden, setShowHidden] = useState(false);
  const [pathInput, setPathInput] = useState(initialPath);
  const [newFolder, setNewFolder] = useState('');
  const [showNewFolder, setShowNewFolder] = useState(false);

  async function load(path: string, opts?: { fromFallback?: boolean }) {
    setError('');
    try {
      const res = await listDir({ bridgeId, path }).unwrap();
      if (!res.ok) {
        // Friendlier: if the requested path is outside the bridge's allowed root
        // (or just missing), fall back to opening the root instead of erroring —
        // so the picker always shows something useful. Only note it, don't block.
        if (!opts?.fromFallback && (res.error?.code === 'path_outside_root' || res.error?.code === 'path_not_found')) {
          const reason = res.error?.code === 'path_outside_root' ? 'outside the allowed root' : 'not found';
          await load('', { fromFallback: true }); // '' => the bridge's root
          setError(`Opened the root — "${path}" is ${reason} on this device.`);
          return;
        }
        setError(str(res.error?.message) || 'Could not open directory');
        return;
      }
      setCwd(res.path); setRoot(res.root); setParent(res.parent); setEntries(res.entries || []);
      setPathInput(res.path);
    } catch (e: any) {
      setError(str(e?.error || e?.message) || 'Bridge unavailable');
    }
  }

  useEffect(() => { void load(initialPath); /* open at initial path, else falls back to root */ }, [bridgeId]);

  const visibleEntries = useMemo(() => {
    const dirs = entries.filter((e) => e.is_dir && (showHidden || !e.hidden));
    return dirs.sort((a, b) => a.name.localeCompare(b.name));
  }, [entries, showHidden]);

  async function createFolder() {
    const name = newFolder.trim();
    if (!name) return;
    setError('');
    try {
      const target = cwd ? `${cwd}/${name}` : name;
      const res = await mkdir({ bridgeId, path: target }).unwrap();
      if (!res.ok) { setError(str(res.error?.message) || 'Could not create folder'); return; }
      setNewFolder(''); setShowNewFolder(false);
      await load(cwd);
    } catch (e: any) {
      setError(str(e?.error || e?.message) || 'Create failed');
    }
  }

  async function createTypedPath() {
    const p = pathInput.trim();
    if (!p) return;
    setError('');
    try {
      const res = await mkdir({ bridgeId, path: p }).unwrap();
      if (!res.ok) { setError(str(res.error?.message) || 'Could not create path'); return; }
      onPick(res.path);
    } catch (e: any) {
      setError(str(e?.error || e?.message) || 'Create failed');
    }
  }

  // Breadcrumb crumbs from root -> cwd (bounded to root).
  const crumbs = useMemo(() => {
    if (!cwd || !root) return [] as { label: string; path: string }[];
    const out: { label: string; path: string }[] = [{ label: root.split('/').filter(Boolean).slice(-1)[0] || '/', path: root }];
    if (cwd !== root && cwd.startsWith(root)) {
      const rest = cwd.slice(root.length).split('/').filter(Boolean);
      let acc = root;
      for (const seg of rest) { acc = `${acc}/${seg}`; out.push({ label: seg, path: acc }); }
    }
    return out;
  }, [cwd, root]);

  return (
    <div data-debug-id={debugId} className="w-full rounded-2xl border border-white/12 bg-[#0f1115] p-3 shadow-2xl">
      <div className="mb-2 flex items-center justify-between gap-2">
        <div className="min-w-0">
          <div className="text-[11px] font-semibold uppercase tracking-[0.14em] text-zinc-500">Browse{bridgeLabel ? ` · ${bridgeLabel}` : ''}</div>
          {root ? <div className="mt-0.5 truncate font-mono text-[10px] text-zinc-600" title={`Allowed root: ${root}`}>root: {root}</div> : null}
        </div>
        <div className="flex shrink-0 items-center gap-1">
          <button data-debug-id={`${debugId}-home-btn`} type="button" onClick={() => void load('')} title="Go to root" className="rounded-lg border border-white/10 px-2 py-1 text-[11px] text-zinc-300 hover:bg-white/10">Root</button>
          {onClose ? <button data-debug-id={`${debugId}-close-btn`} type="button" onClick={onClose} aria-label="Close" className="rounded-lg p-1 text-zinc-500 hover:bg-white/10 hover:text-white"><Icon name="close" size={15} /></button> : null}
        </div>
      </div>

      {/* breadcrumb */}
      <div data-debug-id={`${debugId}-breadcrumb`} className="mb-2 flex flex-wrap items-center gap-1 text-[12px] text-zinc-400">
        {crumbs.map((c, i) => (
          <span key={c.path} className="flex items-center gap-1">
            {i > 0 ? <Icon name="chevron-right" size={12} className="text-zinc-600" /> : null}
            <button data-debug-id={`${debugId}-crumb-${i}`} type="button" onClick={() => void load(c.path)} className="max-w-[160px] truncate rounded px-1 py-0.5 hover:bg-white/10 hover:text-white">{c.label}</button>
          </span>
        ))}
      </div>

      {/* directory list */}
      <div data-debug-id={`${debugId}-list`} className="max-h-[240px] overflow-y-auto rounded-xl border border-white/8 bg-black/20">
        {listState.isFetching ? (
          <div data-debug-id={`${debugId}-loading`} className="p-4 text-center text-xs text-zinc-500">Loading…</div>
        ) : visibleEntries.length === 0 ? (
          <div data-debug-id={`${debugId}-empty`} className="p-4 text-center text-xs text-zinc-600">No subfolders here.</div>
        ) : visibleEntries.map((e) => (
          <button
            key={e.name}
            data-debug-id={`${debugId}-entry-${e.name}`}
            type="button"
            onClick={() => void load(cwd ? `${cwd}/${e.name}` : e.name)}
            className="flex w-full items-center gap-2 border-b border-white/[0.04] px-3 py-2 text-left text-[13px] text-zinc-200 last:border-b-0 hover:bg-white/[0.06]"
          >
            <Icon name="folder" size={15} className="shrink-0 text-sky-300/70" />
            <span className="min-w-0 flex-1 truncate">{e.name}</span>
            {e.has_git ? <span className="shrink-0 rounded bg-emerald-400/15 px-1.5 py-0.5 text-[9px] font-bold text-emerald-300">git</span> : null}
            {e.hidden ? <span className="shrink-0 text-[10px] text-zinc-600">hidden</span> : null}
            <Icon name="chevron-right" size={13} className="shrink-0 text-zinc-600" />
          </button>
        ))}
      </div>

      {/* controls row */}
      <div className="mt-2 flex flex-wrap items-center gap-2">
        <button data-debug-id={`${debugId}-hidden-toggle`} type="button" onClick={() => setShowHidden((v) => !v)} className="rounded-lg border border-white/10 px-2 py-1 text-[11px] text-zinc-400 hover:bg-white/10">{showHidden ? 'Hide hidden' : 'Show hidden'}</button>
        {showNewFolder ? (
          <div className="flex items-center gap-1.5">
            <input data-debug-id={`${debugId}-new-folder-input`} value={newFolder} onChange={(e) => setNewFolder(e.target.value)} placeholder="folder name" className="w-32 rounded-lg border border-white/10 bg-black/30 px-2 py-1 text-[12px] text-white" />
            <button data-debug-id={`${debugId}-new-folder-create-btn`} type="button" disabled={mkdirState.isLoading} onClick={createFolder} className="rounded-lg bg-sky-400 px-2 py-1 text-[11px] font-bold text-black hover:bg-sky-300 disabled:opacity-50">Create</button>
            <button type="button" onClick={() => { setShowNewFolder(false); setNewFolder(''); }} className="rounded-lg px-1.5 py-1 text-[11px] text-zinc-500 hover:text-white">Cancel</button>
          </div>
        ) : (
          <button data-debug-id={`${debugId}-new-folder-btn`} type="button" onClick={() => setShowNewFolder(true)} className="inline-flex items-center gap-1 rounded-lg border border-white/10 px-2 py-1 text-[11px] text-zinc-300 hover:bg-white/10"><Icon name="plus" size={12} /> New folder</button>
        )}
      </div>

      {/* path input + actions */}
      <div className="mt-2">
        <input data-debug-id={`${debugId}-path-input`} value={pathInput} onChange={(e) => setPathInput(e.target.value)} placeholder="~/path/on/this/device" className="w-full rounded-xl border border-white/10 bg-black/30 px-3 py-2 font-mono text-[12px] text-white" />
      </div>

      {error ? <p data-debug-id={`${debugId}-error`} className="mt-2 text-[11px] text-red-300">{error}</p> : null}

      <div className="mt-3 flex items-center justify-end gap-2">
        <button data-debug-id={`${debugId}-create-typed-btn`} type="button" onClick={createTypedPath} className="rounded-xl border border-white/10 px-3 py-2 text-[12px] text-zinc-300 hover:bg-white/10">Create typed path</button>
        <button data-debug-id={`${debugId}-pick-btn`} type="button" onClick={() => onPick(str(pathInput) || cwd)} className="rounded-xl bg-sky-400 px-4 py-2 text-[12px] font-bold text-black hover:bg-sky-300">Use this folder</button>
      </div>
    </div>
  );
}
