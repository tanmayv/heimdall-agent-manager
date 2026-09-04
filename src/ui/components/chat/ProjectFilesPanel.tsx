// ProjectFilesPanel — the "Files" tab peer to the Task Chain panel.
//
// Project-scoped directory browser for the current conversation's project, built
// against the LOCKED API contract (art_18d23e8bfc65311a). Single-directory
// listing + breadcrumb to project root (not an expand-tree), server-side hidden
// filtering via one toggle, cursor pagination ("Load more"), and the four
// mutations: create file, create dir, rename/move, delete. A read-only bounded
// file view (size cap + type gate) is available by clicking a file.
//
// Cache is keyed by (projectId, bridgeId, path) in projectFs.ts, so navigating or
// mutating only refetches the affected directory.

import { useCallback, useEffect, useMemo, useState } from 'react';
import Icon from '../Icon';
import {
  useLazyListProjectDirQuery,
  useLazyReadProjectFileQuery,
  useCreateProjectFileMutation,
  useCreateProjectDirMutation,
  useMoveProjectPathMutation,
  useDeleteProjectPathMutation,
  type FsEntry,
  type FsListResult,
  type FsReadFileResult,
} from '../../api/endpoints/projectFs';

function str(v: any): string {
  return String(v ?? '').trim();
}

// Human-friendly byte size for the entry rows + file viewer header.
function formatBytes(value: number): string {
  const n = Number(value) || 0;
  if (n <= 0) return '0 B';
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  const i = Math.min(units.length - 1, Math.floor(Math.log(n) / Math.log(1024)));
  const scaled = n / Math.pow(1024, i);
  return `${scaled >= 100 || i === 0 ? Math.round(scaled) : scaled.toFixed(1)} ${units[i]}`;
}

// Compact relative time (falls back to the raw string if unparseable).
function formatModified(iso: string): string {
  const s = str(iso);
  if (!s) return '';
  const t = Date.parse(s);
  if (Number.isNaN(t)) return s;
  const diff = Date.now() - t;
  const min = Math.floor(diff / 60000);
  if (min < 1) return 'just now';
  if (min < 60) return `${min}m ago`;
  const hr = Math.floor(min / 60);
  if (hr < 24) return `${hr}h ago`;
  const day = Math.floor(hr / 24);
  if (day < 30) return `${day}d ago`;
  return new Date(t).toLocaleDateString();
}

// Join a project-root-relative dir with a child name.
function joinPath(dir: string, name: string): string {
  return dir ? `${dir}/${name}` : name;
}

// Parent of a project-root-relative path ('' = project root).
function parentPath(path: string): string {
  const clean = str(path).replace(/\/+$/, '');
  const idx = clean.lastIndexOf('/');
  return idx <= 0 ? '' : clean.slice(0, idx);
}

// Basename of a path.
function baseName(path: string): string {
  const clean = str(path).replace(/\/+$/, '');
  const idx = clean.lastIndexOf('/');
  return idx < 0 ? clean : clean.slice(idx + 1);
}

const LIST_LIMIT = 200;

type PendingAction =
  | { kind: 'new-file' }
  | { kind: 'new-dir' }
  | { kind: 'rename'; entry: FsEntry }
  | null;

export type ProjectFilesPanelProps = {
  projectId: string;
  bridgeId?: string;
  projectName?: string;
  onClose?: () => void;
  isMobile?: boolean;
  debugPrefix?: string;
};

export default function ProjectFilesPanel({
  projectId,
  bridgeId = '',
  projectName,
  onClose,
  isMobile = false,
  debugPrefix = 'project-files',
}: ProjectFilesPanelProps) {
  const [listDir] = useLazyListProjectDirQuery();
  const [readFile, readState] = useLazyReadProjectFileQuery();
  const [createFile, createFileState] = useCreateProjectFileMutation();
  const [createDir, createDirState] = useCreateProjectDirMutation();
  const [movePath, moveState] = useMoveProjectPathMutation();
  const [deletePath, deleteState] = useDeleteProjectPathMutation();

  const [cwd, setCwd] = useState(''); // project-root-relative path ('' = root)
  const [rootAbs, setRootAbs] = useState('');
  const [entries, setEntries] = useState<FsEntry[]>([]);
  const [nextCursor, setNextCursor] = useState<string | null>(null);
  const [hasMore, setHasMore] = useState(false);
  const [truncated, setTruncated] = useState(false);
  const [loading, setLoading] = useState(false);
  const [loadingMore, setLoadingMore] = useState(false);
  const [error, setError] = useState('');
  const [includeHidden, setIncludeHidden] = useState(false);

  const [pending, setPending] = useState<PendingAction>(null);
  const [nameDraft, setNameDraft] = useState('');

  // The file currently open in the read-only viewer (null = list view).
  const [viewFile, setViewFile] = useState<FsReadFileResult | null>(null);

  const mutating =
    createFileState.isLoading || createDirState.isLoading || moveState.isLoading || deleteState.isLoading;

  // Load a directory listing (optionally appending a paginated page).
  const load = useCallback(
    async (path: string, opts?: { cursor?: string | null; append?: boolean }) => {
      if (!projectId) return;
      const append = Boolean(opts?.append);
      setError('');
      if (append) setLoadingMore(true);
      else setLoading(true);
      try {
        const res: FsListResult = await listDir({
          projectId,
          bridgeId,
          path,
          includeHidden,
          cursor: opts?.cursor ?? null,
          limit: LIST_LIMIT,
        }).unwrap();
        if (!res.ok) {
          setError(str(res.error?.message) || 'Could not open directory');
          if (!append) setEntries([]);
          return;
        }
        setRootAbs(res.root || '');
        setTruncated(Boolean(res.truncated));
        setHasMore(Boolean(res.has_more));
        setNextCursor(res.next_cursor ?? null);
        setEntries((prev) => (append ? [...prev, ...(res.entries || [])] : res.entries || []));
        if (!append) setCwd(path);
      } catch (e: any) {
        setError(str(e?.error || e?.message) || 'Bridge unavailable');
        if (!append) setEntries([]);
      } finally {
        if (append) setLoadingMore(false);
        else setLoading(false);
      }
    },
    [projectId, bridgeId, includeHidden, listDir],
  );

  // Initial load + reload when project/bridge/hidden toggle changes. Resets to
  // the project root so we never show a stale directory from another project.
  useEffect(() => {
    setViewFile(null);
    setPending(null);
    void load('');
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [projectId, bridgeId, includeHidden]);

  const openDir = useCallback(
    (path: string) => {
      setViewFile(null);
      setPending(null);
      void load(path);
    },
    [load],
  );

  const refresh = useCallback(() => {
    if (viewFile) {
      void openFile(viewFile.path);
      return;
    }
    void load(cwd);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [cwd, viewFile, load]);

  // Breadcrumb crumbs: project root -> cwd.
  const crumbs = useMemo(() => {
    const out: { label: string; path: string }[] = [
      { label: projectName ? projectName : baseName(rootAbs) || 'project', path: '' },
    ];
    if (cwd) {
      const segs = cwd.split('/').filter(Boolean);
      let acc = '';
      for (const seg of segs) {
        acc = acc ? `${acc}/${seg}` : seg;
        out.push({ label: seg, path: acc });
      }
    }
    return out;
  }, [cwd, rootAbs, projectName]);

  // Dirs first, then files; names asc (server already sorts this way, but keep it
  // stable client-side for appended pages too).
  const sortedEntries = useMemo(() => {
    return [...entries].sort((a, b) => {
      if (a.is_dir !== b.is_dir) return a.is_dir ? -1 : 1;
      return a.name.localeCompare(b.name);
    });
  }, [entries]);

  // ---- File viewer ----------------------------------------------------------

  const openFile = useCallback(
    async (path: string) => {
      setError('');
      try {
        const res: FsReadFileResult = await readFile({ projectId, bridgeId, path }).unwrap();
        setViewFile(res);
        if (!res.ok && res.error?.message) setError(str(res.error.message));
      } catch (e: any) {
        setError(str(e?.error || e?.message) || 'Could not read file');
      }
    },
    [projectId, bridgeId, readFile],
  );

  // ---- Mutations ------------------------------------------------------------

  async function submitPending() {
    const name = nameDraft.trim();
    if (!pending) return;
    setError('');
    try {
      if (pending.kind === 'new-file') {
        if (!name) return;
        const res = await createFile({ projectId, bridgeId, path: joinPath(cwd, name) }).unwrap();
        if (!res.ok) return setError(mutationError(res.error?.code, res.error?.message) || 'Could not create file');
      } else if (pending.kind === 'new-dir') {
        if (!name) return;
        const res = await createDir({ projectId, bridgeId, path: joinPath(cwd, name) }).unwrap();
        if (!res.ok) return setError(mutationError(res.error?.code, res.error?.message) || 'Could not create folder');
      } else if (pending.kind === 'rename') {
        if (!name || name === pending.entry.name) {
          setPending(null);
          return;
        }
        const from = joinPath(cwd, pending.entry.name);
        const to = joinPath(cwd, name);
        const res = await movePath({ projectId, bridgeId, from, to }).unwrap();
        if (!res.ok) return setError(mutationError(res.error?.code, res.error?.message) || 'Could not rename');
      }
      setPending(null);
      setNameDraft('');
      await load(cwd);
    } catch (e: any) {
      setError(str(e?.error || e?.message) || 'Action failed');
    }
  }

  async function removeEntry(entry: FsEntry) {
    setError('');
    const target = joinPath(cwd, entry.name);
    const label = entry.is_dir ? 'folder' : 'file';
    // eslint-disable-next-line no-alert
    if (!window.confirm(`Delete ${label} "${entry.name}"?${entry.is_dir ? ' This removes everything inside it.' : ''}`)) {
      return;
    }
    try {
      const res = await deletePath({ projectId, bridgeId, path: target, recursive: entry.is_dir }).unwrap();
      if (!res.ok) {
        setError(mutationError(res.error?.code, res.error?.message) || 'Could not delete');
        return;
      }
      await load(cwd);
    } catch (e: any) {
      setError(str(e?.error || e?.message) || 'Delete failed');
    }
  }

  function beginAction(action: PendingAction) {
    setPending(action);
    setNameDraft(action?.kind === 'rename' ? action.entry.name : '');
  }

  // ---- Render ---------------------------------------------------------------

  const wrapperCls = isMobile
    ? 'flex h-full min-h-0 w-full flex-col bg-[#0b0d11]'
    : 'flex h-full min-h-0 w-full flex-col bg-[#0b0d11]';

  return (
    <div data-debug-id={`${debugPrefix}-panel`} className={wrapperCls}>
      {/* Header */}
      <div className="flex items-center justify-between gap-2 border-b border-white/10 px-3 py-2.5">
        <div className="flex min-w-0 items-center gap-2">
          <Icon name="folder" size={16} className="shrink-0 text-sky-300/80" />
          <div className="min-w-0">
            <div data-debug-id={`${debugPrefix}-title`} className="text-[12px] font-semibold text-zinc-100">Files</div>
            {rootAbs ? (
              <div className="truncate font-mono text-[10px] text-zinc-600" title={`Project root: ${rootAbs}`}>root: {rootAbs}</div>
            ) : null}
          </div>
        </div>
        <div className="flex shrink-0 items-center gap-1">
          <button
            data-debug-id={`${debugPrefix}-refresh-btn`}
            type="button"
            onClick={refresh}
            title="Refresh current directory"
            aria-label="Refresh"
            className="grid h-8 w-8 place-items-center rounded-lg border border-white/10 text-zinc-300 hover:bg-white/10"
          >
            <Icon name="refresh" size={14} />
          </button>
          {onClose ? (
            <button
              data-debug-id={`${debugPrefix}-close-btn`}
              type="button"
              onClick={onClose}
              aria-label="Close files panel"
              className="grid h-8 w-8 place-items-center rounded-lg text-zinc-500 hover:bg-white/10 hover:text-white"
            >
              <Icon name="close" size={15} />
            </button>
          ) : null}
        </div>
      </div>

      {!projectId ? (
        <div data-debug-id={`${debugPrefix}-no-project`} className="grid flex-1 place-items-center p-6 text-center text-xs text-zinc-500">
          No project is associated with this conversation.
        </div>
      ) : viewFile ? (
        <FileView
          file={viewFile}
          fetching={readState.isFetching}
          debugPrefix={debugPrefix}
          onBack={() => setViewFile(null)}
        />
      ) : (
        <>
          {/* Breadcrumb */}
          <div data-debug-id={`${debugPrefix}-breadcrumb`} className="flex flex-wrap items-center gap-0.5 border-b border-white/[0.06] px-3 py-2 text-[12px] text-zinc-400">
            {crumbs.map((c, i) => (
              <span key={c.path || 'root'} className="flex items-center gap-0.5">
                {i > 0 ? <Icon name="chevron-right" size={12} className="text-zinc-600" /> : null}
                <button
                  data-debug-id={`${debugPrefix}-crumb-${i}`}
                  type="button"
                  onClick={() => openDir(c.path)}
                  disabled={i === crumbs.length - 1}
                  className="max-w-[160px] truncate rounded px-1 py-0.5 hover:bg-white/10 hover:text-white disabled:cursor-default disabled:text-zinc-200 disabled:hover:bg-transparent"
                >
                  {c.label}
                </button>
              </span>
            ))}
          </div>

          {/* Toolbar */}
          <div className="flex flex-wrap items-center gap-1.5 border-b border-white/[0.06] px-3 py-2">
            <button
              data-debug-id={`${debugPrefix}-new-file-btn`}
              type="button"
              onClick={() => beginAction({ kind: 'new-file' })}
              className="inline-flex items-center gap-1 rounded-lg border border-white/10 px-2 py-1 text-[11px] text-zinc-300 hover:bg-white/10"
            >
              <Icon name="file" size={12} /> New file
            </button>
            <button
              data-debug-id={`${debugPrefix}-new-dir-btn`}
              type="button"
              onClick={() => beginAction({ kind: 'new-dir' })}
              className="inline-flex items-center gap-1 rounded-lg border border-white/10 px-2 py-1 text-[11px] text-zinc-300 hover:bg-white/10"
            >
              <Icon name="folder" size={12} /> New folder
            </button>
            <button
              data-debug-id={`${debugPrefix}-hidden-toggle`}
              type="button"
              onClick={() => setIncludeHidden((v) => !v)}
              aria-pressed={includeHidden ? 'true' : 'false'}
              className={`ml-auto rounded-lg border px-2 py-1 text-[11px] ${includeHidden ? 'border-sky-400/40 bg-sky-400/10 text-sky-200' : 'border-white/10 text-zinc-400 hover:bg-white/10'}`}
            >
              {includeHidden ? 'Hiding nothing' : 'Show hidden'}
            </button>
          </div>

          {/* Inline create/rename input */}
          {pending ? (
            <div data-debug-id={`${debugPrefix}-name-editor`} className="flex items-center gap-1.5 border-b border-white/[0.06] bg-white/[0.02] px-3 py-2">
              <Icon name={pending.kind === 'new-dir' ? 'folder' : 'file'} size={13} className="text-zinc-500" />
              <input
                data-debug-id={`${debugPrefix}-name-input`}
                autoFocus
                value={nameDraft}
                onChange={(e) => setNameDraft(e.target.value)}
                onKeyDown={(e) => {
                  if (e.key === 'Enter') void submitPending();
                  if (e.key === 'Escape') { setPending(null); setNameDraft(''); }
                }}
                placeholder={pending.kind === 'rename' ? 'new name' : pending.kind === 'new-dir' ? 'folder name' : 'file name'}
                className="min-w-0 flex-1 rounded-lg border border-white/10 bg-black/30 px-2 py-1 text-[12px] text-white"
              />
              <button
                data-debug-id={`${debugPrefix}-name-submit-btn`}
                type="button"
                disabled={mutating || !nameDraft.trim()}
                onClick={() => void submitPending()}
                className="rounded-lg bg-sky-400 px-2 py-1 text-[11px] font-bold text-black hover:bg-sky-300 disabled:opacity-50"
              >
                {pending.kind === 'rename' ? 'Rename' : 'Create'}
              </button>
              <button
                type="button"
                onClick={() => { setPending(null); setNameDraft(''); }}
                className="rounded-lg px-1.5 py-1 text-[11px] text-zinc-500 hover:text-white"
              >
                Cancel
              </button>
            </div>
          ) : null}

          {/* Directory list */}
          <div data-debug-id={`${debugPrefix}-list`} className="min-h-0 flex-1 overflow-y-auto">
            {loading ? (
              <div data-debug-id={`${debugPrefix}-loading`} className="p-4 text-center text-xs text-zinc-500">Loading…</div>
            ) : sortedEntries.length === 0 ? (
              <div data-debug-id={`${debugPrefix}-empty`} className="p-6 text-center text-xs text-zinc-600">This folder is empty.</div>
            ) : (
              <ul>
                {sortedEntries.map((e) => (
                  <li key={`${e.is_dir ? 'd' : 'f'}:${e.name}`} className="group flex items-center gap-2 border-b border-white/[0.04] px-3 py-1.5 hover:bg-white/[0.05]">
                    <button
                      data-debug-id={`${debugPrefix}-entry-${e.name}`}
                      type="button"
                      onClick={() => (e.is_dir ? openDir(joinPath(cwd, e.name)) : void openFile(joinPath(cwd, e.name)))}
                      className="flex min-w-0 flex-1 items-center gap-2 text-left"
                    >
                      <Icon name={e.is_dir ? 'folder' : 'file'} size={15} className={`shrink-0 ${e.is_dir ? 'text-sky-300/70' : 'text-zinc-500'}`} />
                      <span className={`min-w-0 flex-1 truncate text-[13px] ${e.hidden ? 'text-zinc-500' : 'text-zinc-200'}`}>{e.name}</span>
                      {e.has_git ? <span className="shrink-0 rounded bg-emerald-400/15 px-1.5 py-0.5 text-[9px] font-bold text-emerald-300">git</span> : null}
                      {!e.is_dir ? <span className="shrink-0 text-[10px] tabular-nums text-zinc-600">{formatBytes(e.size)}</span> : null}
                      {e.modified_at ? <span className="hidden shrink-0 text-[10px] text-zinc-600 sm:inline">{formatModified(e.modified_at)}</span> : null}
                      {e.is_dir ? <Icon name="chevron-right" size={13} className="shrink-0 text-zinc-600" /> : null}
                    </button>
                    {/* Row actions (rename / delete) — visible on hover/focus. */}
                    <div className="flex shrink-0 items-center gap-0.5 opacity-0 transition-opacity group-hover:opacity-100 focus-within:opacity-100">
                      <button
                        data-debug-id={`${debugPrefix}-rename-${e.name}`}
                        type="button"
                        onClick={() => beginAction({ kind: 'rename', entry: e })}
                        title={`Rename ${e.name}`}
                        aria-label={`Rename ${e.name}`}
                        className="grid h-7 w-7 place-items-center rounded-lg text-zinc-400 hover:bg-white/10 hover:text-white"
                      >
                        <Icon name="pencil" size={13} />
                      </button>
                      <button
                        data-debug-id={`${debugPrefix}-delete-${e.name}`}
                        type="button"
                        disabled={mutating}
                        onClick={() => void removeEntry(e)}
                        title={`Delete ${e.name}`}
                        aria-label={`Delete ${e.name}`}
                        className="grid h-7 w-7 place-items-center rounded-lg text-zinc-400 hover:bg-red-400/15 hover:text-red-300 disabled:opacity-40"
                      >
                        <Icon name="trash" size={13} />
                      </button>
                    </div>
                  </li>
                ))}
              </ul>
            )}

            {/* Load more (cursor pagination) */}
            {hasMore ? (
              <div className="p-3 text-center">
                <button
                  data-debug-id={`${debugPrefix}-load-more-btn`}
                  type="button"
                  disabled={loadingMore}
                  onClick={() => void load(cwd, { cursor: nextCursor, append: true })}
                  className="rounded-lg border border-white/10 px-3 py-1.5 text-[11px] text-zinc-300 hover:bg-white/10 disabled:opacity-50"
                >
                  {loadingMore ? 'Loading…' : 'Load more'}
                </button>
              </div>
            ) : null}
            {truncated ? (
              <div data-debug-id={`${debugPrefix}-truncated`} className="px-3 pb-3 text-center text-[10px] text-amber-300/70">
                Listing truncated to the server maximum.
              </div>
            ) : null}
          </div>
        </>
      )}

      {error ? (
        <div data-debug-id={`${debugPrefix}-error`} className="border-t border-red-400/20 bg-red-400/[0.06] px-3 py-2 text-[11px] text-red-300">
          {error}
        </div>
      ) : null}
    </div>
  );
}

// Map contract error codes to friendly messages, falling back to the server text.
function mutationError(code?: string, message?: string): string {
  switch (code) {
    case 'path_exists':
      return 'A file or folder with that name already exists.';
    case 'dest_exists':
      return 'The destination name is already taken.';
    case 'dir_not_empty':
      return 'That folder is not empty.';
    case 'cannot_delete_root':
      return 'The project root cannot be deleted.';
    case 'path_outside_root':
      return 'That path is outside the project root.';
    case 'path_not_found':
      return 'That path no longer exists.';
    default:
      return str(message);
  }
}

// ---- Read-only file viewer --------------------------------------------------

function FileView({
  file,
  fetching,
  debugPrefix,
  onBack,
}: {
  file: FsReadFileResult;
  fetching: boolean;
  debugPrefix: string;
  onBack: () => void;
}) {
  const name = baseName(file.path);
  const isImage = file.viewable && file.encoding === 'base64';
  const dataUri = isImage ? `data:${file.mime || 'application/octet-stream'};base64,${file.content || ''}` : '';

  return (
    <div data-debug-id={`${debugPrefix}-file-view`} className="flex min-h-0 flex-1 flex-col">
      <div className="flex items-center gap-2 border-b border-white/[0.06] px-3 py-2">
        <button
          data-debug-id={`${debugPrefix}-file-back-btn`}
          type="button"
          onClick={onBack}
          className="inline-flex items-center gap-1 rounded-lg border border-white/10 px-2 py-1 text-[11px] text-zinc-300 hover:bg-white/10"
        >
          <Icon name="chevron-left" size={13} /> Back
        </button>
        <div className="min-w-0 flex-1">
          <div className="truncate text-[12.5px] font-semibold text-zinc-100" title={file.path}>{name}</div>
          <div className="truncate text-[10px] text-zinc-600">
            {[file.mime, file.size != null ? formatBytes(file.size) : '', file.modified_at ? formatModified(file.modified_at) : '']
              .filter(Boolean)
              .join(' · ')}
          </div>
        </div>
      </div>

      <div className="min-h-0 flex-1 overflow-auto bg-[#090909]">
        {fetching ? (
          <div className="p-4 text-center text-xs text-zinc-500">Loading…</div>
        ) : !file.viewable ? (
          <div data-debug-id={`${debugPrefix}-file-unviewable`} className="grid h-full place-items-center p-6 text-center text-xs text-zinc-500">
            {file.error?.code === 'file_too_large'
              ? `This file is too large to preview (${formatBytes(file.size)}).`
              : file.error?.code === 'unsupported_type'
                ? 'This file type cannot be previewed.'
                : str(file.error?.message) || 'This file cannot be previewed.'}
          </div>
        ) : isImage ? (
          <div className="grid h-full place-items-center p-4">
            {/* eslint-disable-next-line jsx-a11y/img-redundant-alt */}
            <img data-debug-id={`${debugPrefix}-file-image`} src={dataUri} alt={name} className="max-h-full max-w-full rounded-lg object-contain" />
          </div>
        ) : (
          <pre data-debug-id={`${debugPrefix}-file-text`} className="whitespace-pre-wrap break-words p-3 font-mono text-[12px] leading-5 text-zinc-200">{file.content || ''}</pre>
        )}
      </div>

      {file.truncated ? (
        <div className="border-t border-amber-400/20 bg-amber-400/[0.06] px-3 py-1.5 text-center text-[10px] text-amber-300/80">
          Preview truncated.
        </div>
      ) : null}
    </div>
  );
}
