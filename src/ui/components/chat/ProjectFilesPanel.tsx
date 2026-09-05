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
//
// PHASE-4 FOLLOW-UP (Spec 4.3/6 — list virtualization): large directories are
// currently bounded by the contract's cursor pagination (limit 200 + "Load more"
// via next_cursor/has_more) inside a scroll container, which keeps the mounted
// DOM small in practice. True windowing (react-window/equiv) is deferred because
// the pinned virtualizers require React 19 while this app is on React 18 (the
// @vimee/* deps hold the React-19 peer); adding one needs either a React-18
// compatible virtualizer or a React bump. Tracked as a Phase-4 follow-up.

import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import Icon from '../Icon';
import MarkdownBody from '../MarkdownBody';
import { highlightToLines, languageForFile, type CodeToken } from '../../utils/codeHighlight';
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

// Format all pending line comments into a single markdown chat message, grouped
// by file and ordered by line, with the source line as context.
function formatCommentsMarkdown(comments: FileLineComment[]): string {
  const byPath = new Map<string, FileLineComment[]>();
  for (const c of comments) {
    const list = byPath.get(c.path) || [];
    list.push(c);
    byPath.set(c.path, list);
  }
  const parts: string[] = ['Code review comments:', ''];
  for (const [path, list] of byPath) {
    parts.push(`**${path}**`);
    for (const c of [...list].sort((a, b) => a.line - b.line || a.createdAt - b.createdAt)) {
      const code = c.lineText.trim();
      parts.push(`- L${c.line}: \`${code}\``);
      for (const bodyLine of c.body.split('\n')) parts.push(`  > ${bodyLine}`);
    }
    parts.push('');
  }
  return parts.join('\n').trim();
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

// A single line comment (UI-local, in-memory), anchored to a file path + line.
export type FileLineComment = {
  id: string;
  path: string; // project-root-relative file path
  line: number; // 1-based
  lineText: string; // snapshot of the source line for message context
  body: string;
  createdAt: number;
};

export type ProjectFilesPanelProps = {
  projectId: string;
  bridgeId?: string;
  projectName?: string;
  // Scope key for the in-memory comment store: comments reset when this changes
  // (e.g. switching conversations) so review notes never leak across chats.
  conversationKey?: string;
  // Publish the collected comments as a single chat message. Returns true on
  // success (the panel then clears the local store). Parent owns the send.
  onPublishComments?: (markdown: string) => Promise<boolean>;
  onClose?: () => void;
  isMobile?: boolean;
  debugPrefix?: string;
};

export default function ProjectFilesPanel({
  projectId,
  bridgeId = '',
  projectName,
  conversationKey = '',
  onPublishComments,
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
  // Timestamp of the last successful listing fetch, shown as "refreshed HH:MM".
  const [lastRefreshed, setLastRefreshed] = useState<number | null>(null);

  const [pending, setPending] = useState<PendingAction>(null);
  const [nameDraft, setNameDraft] = useState('');

  // The file currently open in the read-only viewer (null = list view).
  const [viewFile, setViewFile] = useState<FsReadFileResult | null>(null);

  // In-memory review comments, tracked ACROSS all files in this conversation.
  // Reset when the conversation scope changes so notes never leak between chats.
  const [comments, setComments] = useState<FileLineComment[]>([]);
  const [publishing, setPublishing] = useState(false);
  const [publishError, setPublishError] = useState('');
  useEffect(() => {
    setComments([]);
    setPublishError('');
  }, [conversationKey, projectId]);

  const addComment = useCallback((path: string, line: number, lineText: string, body: string) => {
    const text = str(body);
    if (!text) return;
    setComments((prev) => [
      ...prev,
      { id: `flc_${Date.now().toString(36)}_${Math.random().toString(36).slice(2, 8)}`, path, line, lineText, body: text, createdAt: Date.now() },
    ]);
  }, []);
  const editComment = useCallback((id: string, body: string) => {
    const text = str(body);
    setComments((prev) => prev.map((c) => (c.id === id ? { ...c, body: text } : c)).filter((c) => c.body));
  }, []);
  const deleteComment = useCallback((id: string) => {
    setComments((prev) => prev.filter((c) => c.id !== id));
  }, []);

  const commentsForPath = useCallback(
    (path: string) => comments.filter((c) => c.path === path),
    [comments],
  );
  const filesWithComments = useMemo(() => new Set(comments.map((c) => c.path)).size, [comments]);

  const publishComments = useCallback(async () => {
    if (!onPublishComments || comments.length === 0) return;
    setPublishError('');
    setPublishing(true);
    try {
      const ok = await onPublishComments(formatCommentsMarkdown(comments));
      if (ok) setComments([]);
      else setPublishError('Could not send comments.');
    } catch (e: any) {
      setPublishError(str(e?.message) || 'Could not send comments.');
    } finally {
      setPublishing(false);
    }
  }, [onPublishComments, comments]);

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
        setLastRefreshed(Date.now());
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

  // Reset to the project ROOT only when the project/bridge changes, so we never
  // show a stale directory carried over from another project. The hidden toggle
  // must NOT reset here (Spec 4.2/4.3 — it refetches the CURRENT dir; see below).
  useEffect(() => {
    setViewFile(null);
    setPending(null);
    void load('');
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [projectId, bridgeId]);

  // Show/hide-hidden refetches the CURRENT directory in place (Spec 4.2/4.3) —
  // it must not jump back to root. Skip the initial mount so this doesn't
  // double-fire alongside the project/bridge effect on first render.
  const hiddenMounted = useRef(false);
  useEffect(() => {
    if (!hiddenMounted.current) {
      hiddenMounted.current = true;
      return;
    }
    void load(cwd);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [includeHidden]);

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

  // Accumulated viewer content across paged reads. `viewFile` holds the metadata
  // + first chunk; `viewContent` is the stitched text; `viewNextOffset`/`viewEof`
  // drive lazy paging. We assume the file doesn't change between pages.
  const [viewContent, setViewContent] = useState('');
  const [viewNextOffset, setViewNextOffset] = useState(0);
  const [viewEof, setViewEof] = useState(true);
  const [loadingMoreFile, setLoadingMoreFile] = useState(false);

  const openFile = useCallback(
    async (path: string) => {
      setError('');
      try {
        const res: FsReadFileResult = await readFile({ projectId, bridgeId, path, offset: 0 }).unwrap();
        setViewFile(res);
        if (res.viewable && res.encoding === 'utf8') {
          setViewContent(res.content || '');
          setViewNextOffset(Number(res.offset || 0) + Number(res.bytes_returned || (res.content ? res.content.length : 0)));
          setViewEof(res.eof !== false);
        } else {
          // Images / non-viewable: no paging.
          setViewContent(res.content || '');
          setViewNextOffset(0);
          setViewEof(true);
        }
        if (!res.ok && res.error?.message) setError(str(res.error.message));
      } catch (e: any) {
        setError(str(e?.error || e?.message) || 'Could not read file');
      }
    },
    [projectId, bridgeId, readFile],
  );

  const loadMoreFile = useCallback(async () => {
    if (!viewFile || viewEof || loadingMoreFile) return;
    setLoadingMoreFile(true);
    try {
      const res: FsReadFileResult = await readFile({ projectId, bridgeId, path: viewFile.path, offset: viewNextOffset }).unwrap();
      if (res.ok && res.viewable) {
        setViewContent((prev) => prev + (res.content || ''));
        setViewNextOffset(Number(res.offset || 0) + Number(res.bytes_returned || (res.content ? res.content.length : 0)));
        setViewEof(res.eof !== false);
      } else if (res.error?.message) {
        setError(str(res.error.message));
        setViewEof(true);
      }
    } catch (e: any) {
      setError(str(e?.error || e?.message) || 'Could not load more of this file');
      setViewEof(true);
    } finally {
      setLoadingMoreFile(false);
    }
  }, [projectId, bridgeId, readFile, viewFile, viewNextOffset, viewEof, loadingMoreFile]);

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
            {lastRefreshed && !viewFile ? (
              <div data-debug-id={`${debugPrefix}-last-refreshed`} className="text-[10px] text-zinc-600">refreshed {new Date(lastRefreshed).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' })}</div>
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

      {/* Pending review comments bar — spans ALL files in this conversation. */}
      {comments.length > 0 ? (
        <div data-debug-id={`${debugPrefix}-comments-bar`} className="flex items-center gap-2 border-b border-sky-400/20 bg-sky-400/[0.06] px-3 py-2">
          <div data-debug-id={`${debugPrefix}-comments-count`} className="min-w-0 flex-1 text-[11.5px] text-sky-100">
            {comments.length} comment{comments.length === 1 ? '' : 's'} on {filesWithComments} file{filesWithComments === 1 ? '' : 's'}
            {publishError ? <span className="ml-2 text-red-300">{publishError}</span> : null}
          </div>
          <button
            data-debug-id={`${debugPrefix}-comments-clear-btn`}
            type="button"
            onClick={() => { setComments([]); setPublishError(''); }}
            disabled={publishing}
            className="shrink-0 rounded-lg border border-white/10 px-2 py-1 text-[11px] text-zinc-300 hover:bg-white/10 disabled:opacity-50"
          >
            Clear
          </button>
          <button
            data-debug-id={`${debugPrefix}-comments-send-btn`}
            type="button"
            onClick={() => void publishComments()}
            disabled={publishing || !onPublishComments}
            className="shrink-0 rounded-lg bg-sky-600 px-2.5 py-1 text-[11px] font-semibold text-white hover:bg-sky-500 disabled:opacity-50"
            title={onPublishComments ? 'Send all comments to the agent' : 'Sending is unavailable here'}
          >
            {publishing ? 'Sending…' : 'Send to agent'}
          </button>
        </div>
      ) : null}

      {!projectId ? (
        <div data-debug-id={`${debugPrefix}-no-project`} className="grid flex-1 place-items-center p-6 text-center text-xs text-zinc-500">
          No project is associated with this conversation.
        </div>
      ) : viewFile ? (
        <FileView
          file={viewFile}
          content={viewContent}
          hasMore={!viewEof}
          loadingMore={loadingMoreFile}
          onLoadMore={loadMoreFile}
          fetching={readState.isFetching}
          debugPrefix={debugPrefix}
          comments={commentsForPath(viewFile.path)}
          onAddComment={(line, lineText, body) => addComment(viewFile.path, line, lineText, body)}
          onEditComment={editComment}
          onDeleteComment={deleteComment}
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
              title={includeHidden ? 'Hide dotfiles (names starting with ".")' : 'Show hidden dotfiles (names starting with ".")'}
              className={`ml-auto rounded-lg border px-2 py-1 text-[11px] ${includeHidden ? 'border-sky-400/40 bg-sky-400/10 text-sky-200' : 'border-white/10 text-zinc-400 hover:bg-white/10'}`}
            >
              {includeHidden ? 'Hide hidden' : 'Show hidden'}
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
            ) : error && sortedEntries.length === 0 ? (
              // Don't show the misleading "empty folder" placeholder when the load
              // actually FAILED (e.g. project not configured on this bridge, or the
              // bridge is offline). The error banner below carries the reason.
              <div data-debug-id={`${debugPrefix}-load-error`} className="p-6 text-center text-xs text-zinc-500">Couldn’t load files — see the message below.</div>
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

function isMarkdownFile(pathOrName: string): boolean {
  const n = String(pathOrName || '').toLowerCase();
  return n.endsWith('.md') || n.endsWith('.markdown') || n.endsWith('.mdx');
}

function FileView({
  file,
  content,
  hasMore,
  loadingMore,
  onLoadMore,
  fetching,
  debugPrefix,
  comments,
  onAddComment,
  onEditComment,
  onDeleteComment,
  onBack,
}: {
  file: FsReadFileResult;
  content: string; // stitched text content across paged reads
  hasMore: boolean; // more of this file remains to load
  loadingMore: boolean;
  onLoadMore: () => void;
  fetching: boolean;
  debugPrefix: string;
  comments: FileLineComment[];
  onAddComment: (line: number, lineText: string, body: string) => void;
  onEditComment: (id: string, body: string) => void;
  onDeleteComment: (id: string) => void;
  onBack: () => void;
}) {
  const name = baseName(file.path);
  const isImage = file.viewable && file.encoding === 'base64';
  const dataUri = isImage ? `data:${file.mime || 'application/octet-stream'};base64,${file.content || ''}` : '';
  const isText = file.viewable && !isImage;
  const isMarkdown = isText && isMarkdownFile(file.path);

  // View modes for markdown: "rendered" (MarkdownBody) or "source" (highlighted).
  const [mdRendered, setMdRendered] = useState(true);
  // Soft-wrap toggle for the code/source view (off = horizontal scroll).
  const [wrap, setWrap] = useState(false);
  const showCode = isText && !(isMarkdown && mdRendered);

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
        {/* View controls */}
        {isMarkdown ? (
          <button
            data-debug-id={`${debugPrefix}-file-md-toggle-btn`}
            type="button"
            onClick={() => setMdRendered((v) => !v)}
            className="shrink-0 rounded-lg border border-white/10 px-2 py-1 text-[11px] text-zinc-300 hover:bg-white/10"
            title={mdRendered ? 'View source' : 'View rendered'}
          >
            {mdRendered ? 'Source' : 'Rendered'}
          </button>
        ) : null}
        {showCode ? (
          <button
            data-debug-id={`${debugPrefix}-file-wrap-toggle-btn`}
            type="button"
            onClick={() => setWrap((v) => !v)}
            aria-pressed={wrap ? 'true' : 'false'}
            className={`shrink-0 rounded-lg border px-2 py-1 text-[11px] ${wrap ? 'border-sky-400/50 bg-sky-400/20 text-sky-100' : 'border-white/10 text-zinc-300 hover:bg-white/10'}`}
            title={wrap ? 'Disable soft wrap' : 'Enable soft wrap'}
          >
            Wrap
          </button>
        ) : null}
      </div>

      <div
        className="min-h-0 flex-1 overflow-auto bg-[#090909]"
        onScroll={(e) => {
          if (!hasMore || loadingMore) return;
          const el = e.currentTarget;
          // Near-bottom (within ~600px) => fetch the next byte page.
          if (el.scrollHeight - el.scrollTop - el.clientHeight < 600) onLoadMore();
        }}
      >
        {fetching && !content ? (
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
        ) : isMarkdown && mdRendered ? (
          <div data-debug-id={`${debugPrefix}-file-markdown`} className="p-3">
            <MarkdownBody source={content} className="text-zinc-200" />
          </div>
        ) : (
          <>
            <CodeLines
              content={content}
              path={file.path}
              wrap={wrap}
              debugPrefix={debugPrefix}
              comments={comments}
              onAddComment={onAddComment}
              onEditComment={onEditComment}
              onDeleteComment={onDeleteComment}
            />
            {hasMore ? (
              <div className="flex justify-center py-2">
                <button
                  data-debug-id={`${debugPrefix}-file-load-more-btn`}
                  type="button"
                  onClick={onLoadMore}
                  disabled={loadingMore}
                  className="rounded-lg border border-white/10 px-3 py-1.5 text-[11px] text-zinc-300 hover:bg-white/10 disabled:opacity-50"
                >
                  {loadingMore ? 'Loading…' : 'Load more of this file'}
                </button>
              </div>
            ) : null}
          </>
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

// CodeLines renders text/code as ONE ROW PER LINE (gutter cell + highlighted code
// cell), which enables the interactive line gutter (hover comment button) and
// inline comment widgets that a monolithic <pre> can't host. Highlighting comes
// from Shiki per-line tokens; it degrades gracefully to plain text (same row
// structure) while tokens resolve or when the language is unknown/unsupported.
function CodeLines({
  content,
  path,
  wrap,
  debugPrefix,
  comments,
  onAddComment,
  onEditComment,
  onDeleteComment,
}: {
  content: string;
  path: string;
  wrap: boolean;
  debugPrefix: string;
  comments: FileLineComment[];
  onAddComment: (line: number, lineText: string, body: string) => void;
  onEditComment: (id: string, body: string) => void;
  onDeleteComment: (id: string) => void;
}) {
  const [tokenLines, setTokenLines] = useState<CodeToken[][] | null>(null);
  const lang = useMemo(() => languageForFile(path), [path]);

  // Raw source split into lines (the fallback + the source-of-truth for line text
  // used in the published message). Drop a single trailing empty line so a final
  // newline doesn't render a phantom row.
  const rawLines = useMemo(() => {
    const arr = (content || '').split('\n');
    if (arr.length > 1 && arr[arr.length - 1] === '') arr.pop();
    return arr;
  }, [content]);

  useEffect(() => {
    let cancelled = false;
    setTokenLines(null);
    if (!content || !lang) return;
    highlightToLines(content, lang).then((out) => {
      if (!cancelled) setTokenLines(out);
    });
    return () => {
      cancelled = true;
    };
  }, [content, lang]);

  // line (1-based) -> comments; and which line has an open composer.
  const commentsByLine = useMemo(() => {
    const m = new Map<number, FileLineComment[]>();
    for (const c of comments) {
      const list = m.get(c.line) || [];
      list.push(c);
      m.set(c.line, list);
    }
    return m;
  }, [comments]);
  const [composerLine, setComposerLine] = useState<number | null>(null);

  const lineCount = Math.max(1, rawLines.length);
  const gutterWidthCh = Math.max(2, String(lineCount).length) + 1;

  return (
    <div data-debug-id={`${debugPrefix}-file-code`} className="min-w-0 py-2 font-mono text-[12px] leading-5">
      {Array.from({ length: lineCount }, (_, i) => {
        const lineNo = i + 1;
        const lineText = rawLines[i] ?? '';
        const tokens = tokenLines?.[i];
        const lineComments = commentsByLine.get(lineNo) || [];
        return (
          <div key={lineNo} data-debug-id={`${debugPrefix}-line-${lineNo}`}>
            <div className="group flex items-start hover:bg-white/[0.03]">
              {/* Gutter: line number + hover comment button */}
              <div
                className="relative flex shrink-0 select-none items-center justify-end border-r border-white/[0.06] bg-white/[0.02] pr-2 text-right text-zinc-600"
                style={{ width: `calc(${gutterWidthCh}ch + 22px)` }}
              >
                <button
                  data-debug-id={`${debugPrefix}-line-comment-btn-${lineNo}`}
                  type="button"
                  onClick={() => setComposerLine((v) => (v === lineNo ? null : lineNo))}
                  title="Comment on this line"
                  aria-label={`Comment on line ${lineNo}`}
                  className={`absolute left-1 grid h-4 w-4 place-items-center rounded text-sky-300 ${lineComments.length > 0 ? 'opacity-100' : 'opacity-0 group-hover:opacity-100'} hover:bg-sky-400/20`}
                >
                  {lineComments.length > 0 ? (
                    <span className="text-[9px] font-bold">{lineComments.length}</span>
                  ) : (
                    <Icon name="chat" size={11} />
                  )}
                </button>
                <button
                  type="button"
                  onClick={() => setComposerLine((v) => (v === lineNo ? null : lineNo))}
                  className="cursor-pointer tabular-nums hover:text-zinc-300"
                >
                  {lineNo}
                </button>
              </div>
              {/* Code cell */}
              <div className={`min-w-0 flex-1 overflow-x-auto px-3 text-zinc-200 ${wrap ? 'whitespace-pre-wrap break-words' : 'whitespace-pre'}`}>
                {tokens ? (
                  tokens.length > 0 ? (
                    tokens.map((t, ti) => (
                      <span key={ti} style={t.color ? { color: t.color } : undefined}>{t.content}</span>
                    ))
                  ) : (
                    // Preserve blank-line height.
                    <span>{'\u00a0'}</span>
                  )
                ) : (
                  <span>{lineText || '\u00a0'}</span>
                )}
              </div>
            </div>

            {/* Existing comments for this line */}
            {lineComments.map((c) => (
              <LineComment
                key={c.id}
                comment={c}
                debugPrefix={debugPrefix}
                gutterWidthCh={gutterWidthCh}
                onEdit={onEditComment}
                onDelete={onDeleteComment}
              />
            ))}

            {/* Inline composer for a new comment */}
            {composerLine === lineNo ? (
              <LineComposer
                debugPrefix={debugPrefix}
                lineNo={lineNo}
                gutterWidthCh={gutterWidthCh}
                onCancel={() => setComposerLine(null)}
                onSave={(body) => {
                  onAddComment(lineNo, lineText, body);
                  setComposerLine(null);
                }}
              />
            ) : null}
          </div>
        );
      })}
    </div>
  );
}

// A saved line comment bubble with edit/delete, indented under its line.
function LineComment({
  comment,
  debugPrefix,
  gutterWidthCh,
  onEdit,
  onDelete,
}: {
  comment: FileLineComment;
  debugPrefix: string;
  gutterWidthCh: number;
  onEdit: (id: string, body: string) => void;
  onDelete: (id: string) => void;
}) {
  const [editing, setEditing] = useState(false);
  const [draft, setDraft] = useState(comment.body);
  return (
    <div className="flex" style={{ paddingLeft: `calc(${gutterWidthCh}ch + 22px)` }}>
      <div data-debug-id={`${debugPrefix}-line-comment-${comment.id}`} className="my-1 mr-3 min-w-0 flex-1 rounded-lg border border-sky-400/20 bg-sky-400/[0.06] px-2.5 py-1.5 font-sans text-[12px]">
        {editing ? (
          <div>
            <textarea
              data-debug-id={`${debugPrefix}-line-comment-edit-input-${comment.id}`}
              value={draft}
              onChange={(e) => setDraft(e.target.value)}
              rows={2}
              className="w-full resize-y rounded border border-white/10 bg-black/30 p-1.5 text-[12px] text-zinc-100 focus:border-sky-500 focus:outline-none"
            />
            <div className="mt-1 flex justify-end gap-1.5">
              <button type="button" onClick={() => { setDraft(comment.body); setEditing(false); }} className="rounded border border-white/10 px-2 py-0.5 text-[11px] text-zinc-300 hover:bg-white/10">Cancel</button>
              <button data-debug-id={`${debugPrefix}-line-comment-edit-save-${comment.id}`} type="button" onClick={() => { onEdit(comment.id, draft); setEditing(false); }} className="rounded bg-sky-600 px-2 py-0.5 text-[11px] font-semibold text-white hover:bg-sky-500">Save</button>
            </div>
          </div>
        ) : (
          <div className="flex items-start gap-2">
            <div className="min-w-0 flex-1 whitespace-pre-wrap break-words text-zinc-100">{comment.body}</div>
            <div className="flex shrink-0 items-center gap-1">
              <button data-debug-id={`${debugPrefix}-line-comment-edit-${comment.id}`} type="button" onClick={() => { setDraft(comment.body); setEditing(true); }} title="Edit" className="grid h-5 w-5 place-items-center rounded text-zinc-400 hover:bg-white/10 hover:text-zinc-200"><Icon name="pencil" size={12} /></button>
              <button data-debug-id={`${debugPrefix}-line-comment-delete-${comment.id}`} type="button" onClick={() => onDelete(comment.id)} title="Delete" className="grid h-5 w-5 place-items-center rounded text-zinc-400 hover:bg-red-500/20 hover:text-red-300"><Icon name="trash" size={12} /></button>
            </div>
          </div>
        )}
      </div>
    </div>
  );
}

// Inline new-comment composer, indented under its line.
function LineComposer({
  debugPrefix,
  lineNo,
  gutterWidthCh,
  onSave,
  onCancel,
}: {
  debugPrefix: string;
  lineNo: number;
  gutterWidthCh: number;
  onSave: (body: string) => void;
  onCancel: () => void;
}) {
  const [draft, setDraft] = useState('');
  const ref = useRef<HTMLTextAreaElement | null>(null);
  useEffect(() => { ref.current?.focus(); }, []);
  return (
    <div data-debug-id={`${debugPrefix}-line-composer-${lineNo}`} className="flex" style={{ paddingLeft: `calc(${gutterWidthCh}ch + 22px)` }}>
      <div className="my-1 mr-3 min-w-0 flex-1 font-sans">
        <textarea
          ref={ref}
          data-debug-id={`${debugPrefix}-line-composer-input-${lineNo}`}
          value={draft}
          onChange={(e) => setDraft(e.target.value)}
          onKeyDown={(e) => {
            if (e.key === 'Escape') { e.preventDefault(); onCancel(); }
            if ((e.metaKey || e.ctrlKey) && e.key === 'Enter') { e.preventDefault(); if (draft.trim()) onSave(draft); }
          }}
          rows={2}
          placeholder={`Comment on line ${lineNo}… (Cmd/Ctrl+Enter to save)`}
          className="w-full resize-y rounded border border-white/10 bg-black/30 p-1.5 text-[12px] text-zinc-100 placeholder:text-zinc-600 focus:border-sky-500 focus:outline-none"
        />
        <div className="mt-1 flex justify-end gap-1.5">
          <button data-debug-id={`${debugPrefix}-line-composer-cancel-${lineNo}`} type="button" onClick={onCancel} className="rounded border border-white/10 px-2 py-0.5 text-[11px] text-zinc-300 hover:bg-white/10">Cancel</button>
          <button data-debug-id={`${debugPrefix}-line-composer-save-${lineNo}`} type="button" onClick={() => { if (draft.trim()) onSave(draft); }} disabled={!draft.trim()} className="rounded bg-sky-600 px-2 py-0.5 text-[11px] font-semibold text-white hover:bg-sky-500 disabled:opacity-50">Comment</button>
        </div>
      </div>
    </div>
  );
}
