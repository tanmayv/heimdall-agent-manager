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
import Editor, { type OnMount, type EditorProps } from '@monaco-editor/react';

import MarkdownBody from '../MarkdownBody';
import ProjectVcsPanel from './ProjectVcsPanel';
import { highlightToLines, languageForFile, type CodeToken } from '../../utils/codeHighlight';
import { useTheme } from '../../store/themeSlice';
import { Icon, IconButton } from '@ui';
import {
  useLazyListProjectDirQuery,
  useLazyReadProjectFileQuery,
  useCreateProjectFileMutation,
  useCreateProjectDirMutation,
  useMoveProjectPathMutation,
  useDeleteProjectPathMutation,
  useWriteProjectFileMutation,
  useBatchWriteProjectFilesMutation,
  type FsEntry,
  type FsListResult,
  type FsReadFileResult,
} from '../../api/endpoints/projectFs';
import { useLazyGetVcsCapabilitiesQuery } from '../../api/endpoints/projectVcs';

export type EditorTab = {
  path: string;
  content: string;
  initialContent: string;
  isDirty: boolean;
  isNew?: boolean;
  isImage?: boolean;
  mime?: string;
  isUnviewable?: boolean;
  unviewableReason?: string;
};

function getLanguageForMonaco(filePath: string): string {
  const lang = languageForFile(filePath);
  const map: Record<string, string> = {
    bash: 'shell',
    zsh: 'shell',
    sh: 'shell',
    fish: 'shell',
    docker: 'dockerfile',
    yml: 'yaml',
    yaml: 'yaml',
    js: 'javascript',
    ts: 'typescript',
    tsx: 'typescript',
    jsx: 'javascript',
    md: 'markdown',
    markdown: 'markdown',
    py: 'python',
    rb: 'ruby',
    rs: 'rust',
    cs: 'csharp',
    go: 'go',
    json: 'json',
    jsonc: 'json',
    html: 'html',
    xml: 'xml',
    css: 'css',
    scss: 'scss',
    less: 'less',
    sql: 'sql',
    graphql: 'graphql',
    proto: 'protobuf',
    odin: 'c',
    zig: 'c',
    toml: 'ini',
    ini: 'ini',
  };
  return map[lang] || lang || 'plaintext';
}

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
      if (c.line > 0) {
        parts.push(`- L${c.line}: \`${c.lineText.trim()}\``);
      } else {
        // Line 0 = file/folder-level comment (no specific line).
        parts.push(`- (${c.lineText.trim() || 'general'})`);
      }
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
  const [getVcsCapabilities] = useLazyGetVcsCapabilitiesQuery();

  // Sub-tab state: the file tree ('files') vs the VCS Changes view ('changes').
  // The Changes tab is only offered when the project root has a detected VCS
  // provider (probed once on mount / project change).
  const [activeTab, setActiveTab] = useState<'files' | 'changes'>('files');
  const [vcsProvider, setVcsProvider] = useState('');
  const [createFile, createFileState] = useCreateProjectFileMutation();
  const [createDir, createDirState] = useCreateProjectDirMutation();
  const [movePath, moveState] = useMoveProjectPathMutation();
  const [deletePath, deleteState] = useDeleteProjectPathMutation();
  const [writeProjectFile, writeState] = useWriteProjectFileMutation();
  const [batchWriteProjectFiles, batchWriteState] = useBatchWriteProjectFilesMutation();
  const { theme } = useTheme();

  // Multi-file editor state
  const [openTabs, setOpenTabs] = useState<EditorTab[]>([]);
  const [activeTabPath, setActiveTabPath] = useState<string>('');
  const [isEditMode, setIsEditMode] = useState<boolean>(false);
  const [saveFeedback, setSaveFeedback] = useState<{
    type: 'success' | 'warning' | 'error';
    message: string;
  } | null>(null);
  const [confirmClosePath, setConfirmClosePath] = useState<string | null>(null);
  const [openingInEditor, setOpeningInEditor] = useState<string>('');

  // Split-pane & explorer collapse/resizing state (REQ-IDE-SPLIT-PANE, REQ-IDE-FILE-TREE)
  const [isExplorerCollapsed, setIsExplorerCollapsed] = useState<boolean>(false);
  const [explorerWidth, setExplorerWidth] = useState<number>(280);
  const [isResizing, setIsResizing] = useState<boolean>(false);
  const resizerRef = useRef<{ startX: number; startWidth: number } | null>(null);

  const startResizing = useCallback(
    (e: React.MouseEvent) => {
      e.preventDefault();
      setIsResizing(true);
      resizerRef.current = { startX: e.clientX, startWidth: explorerWidth };
    },
    [explorerWidth]
  );

  useEffect(() => {
    if (!isResizing) return;
    const handleMouseMove = (e: MouseEvent) => {
      if (!resizerRef.current) return;
      const delta = e.clientX - resizerRef.current.startX;
      const newWidth = Math.max(200, Math.min(600, resizerRef.current.startWidth + delta));
      setExplorerWidth(newWidth);
    };
    const handleMouseUp = () => {
      setIsResizing(false);
      resizerRef.current = null;
    };
    window.addEventListener('mousemove', handleMouseMove);
    window.addEventListener('mouseup', handleMouseUp);
    return () => {
      window.removeEventListener('mousemove', handleMouseMove);
      window.removeEventListener('mouseup', handleMouseUp);
    };
  }, [isResizing]);

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

  // Path-level (file/folder) comment composer: the target path (or null when
  // closed) and its draft. line 0 marks a path-scoped comment.
  const [pathCommentFor, setPathCommentFor] = useState<{ path: string; label: string } | null>(null);
  const [pathCommentDraft, setPathCommentDraft] = useState('');

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
    setPending(null);
    setOpenTabs([]);
    setActiveTabPath('');
    setIsEditMode(false);
    setSaveFeedback(null);
    setConfirmClosePath(null);
    void load('');
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [projectId, bridgeId]);

  // Probe VCS capabilities once per project/bridge to decide whether the "Changes"
  // sub-tab is offered. Reset to the file tree when the project/bridge changes so a
  // stale Changes selection never carries over to a project without VCS.
  useEffect(() => {
    let cancelled = false;
    setActiveTab('files');
    setVcsProvider('');
    if (!projectId) return;
    (async () => {
      try {
        const res = await getVcsCapabilities({ projectId, bridgeId }).unwrap();
        if (!cancelled && res.ok && str(res.provider)) setVcsProvider(res.provider);
      } catch {
        // No VCS / bridge offline: leave the Changes tab hidden.
      }
    })();
    return () => {
      cancelled = true;
    };
  }, [projectId, bridgeId, getVcsCapabilities]);

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
      setPending(null);
      void load(path);
    },
    [load],
  );

  const refresh = useCallback(() => {
    void load(cwd);
  }, [cwd, load]);

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

  // Auto-dismiss save feedback after 3s
  useEffect(() => {
    if (saveFeedback) {
      const timer = setTimeout(() => {
        setSaveFeedback(null);
      }, 3000);
      return () => clearTimeout(timer);
    }
  }, [saveFeedback]);

  const activeEditorTab = useMemo(
    () => openTabs.find((t) => t.path === activeTabPath),
    [openTabs, activeTabPath]
  );

  // Fetch full file content across all byte pages before editing
  const fetchAllFileContent = useCallback(
    async (
      filePath: string
    ): Promise<{
      content: string;
      isImage?: boolean;
      mime?: string;
      isUnviewable?: boolean;
      unviewableReason?: string;
    }> => {
      let acc = '';
      let offset = 0;
      let eof = false;
      let iterations = 0;
      let isImage = false;
      let mime = '';

      while (!eof && iterations < 100) {
        iterations++;
        const res: FsReadFileResult = await readFile({
          projectId,
          bridgeId,
          path: filePath,
          offset,
        }).unwrap();

        if (!res.ok) {
          throw new Error(res.error?.message || 'Could not read file');
        }

        if (iterations === 1) {
          mime = res.mime || '';
          if (res.viewable && res.encoding === 'base64') {
            return {
              content: res.content || '',
              isImage: true,
              mime: res.mime || 'image/png',
            };
          }
          if (!res.viewable) {
            return {
              content: '',
              isUnviewable: true,
              unviewableReason:
                res.error?.code === 'file_too_large'
                  ? `This file is too large to preview (${formatBytes(res.size || 0)}).`
                  : res.error?.code === 'unsupported_type'
                    ? 'This file type cannot be previewed.'
                    : str(res.error?.message) || 'This file cannot be previewed.',
            };
          }
        }

        acc += res.content || '';
        const bytesReturned = Number(
          res.bytes_returned ?? (res.content ? res.content.length : 0)
        );
        offset = Number(res.offset ?? 0) + bytesReturned;
        eof = res.eof !== false || bytesReturned === 0;
      }
      return { content: acc, isImage, mime };
    },
    [readFile, projectId, bridgeId]
  );

  const openFileInEditor = useCallback(
    async (inputPath: string) => {
      setError('');
      const filePath =
        cwd && !inputPath.includes('/') && !inputPath.startsWith(cwd)
          ? joinPath(cwd, inputPath)
          : inputPath;

      const existing = openTabs.find((t) => t.path === filePath);
      if (existing) {
        setActiveTabPath(filePath);
        setIsEditMode(true);
        if (isMobile) setIsExplorerCollapsed(true);
        return;
      }
      setOpeningInEditor(filePath);
      try {
        const fileRes = await fetchAllFileContent(filePath);
        const newTab: EditorTab = {
          path: filePath,
          content: fileRes.content,
          initialContent: fileRes.content,
          isDirty: false,
          isNew: false,
          isImage: fileRes.isImage,
          mime: fileRes.mime,
          isUnviewable: fileRes.isUnviewable,
          unviewableReason: fileRes.unviewableReason,
        };
        setOpenTabs((prev) => [...prev, newTab]);
        setActiveTabPath(filePath);
        setIsEditMode(true);
        if (isMobile) setIsExplorerCollapsed(true);
      } catch (e: any) {
        setError(str(e?.message) || 'Could not open file in editor');
      } finally {
        setOpeningInEditor('');
      }
    },
    [cwd, openTabs, fetchAllFileContent, isMobile]
  );

  const handleEditorNewFile = useCallback(
    async (inputPath: string) => {
      setError('');
      const raw = inputPath.trim().replace(/^\/+/, '');
      if (!raw) return;
      const targetPath = cwd && !raw.includes('/') ? joinPath(cwd, raw) : raw;

      const existing = openTabs.find((t) => t.path === targetPath);
      if (existing) {
        setActiveTabPath(targetPath);
        setIsEditMode(true);
        if (isMobile) setIsExplorerCollapsed(true);
        return;
      }

      setOpeningInEditor(targetPath);
      try {
        const fileRes = await fetchAllFileContent(targetPath);
        const newTab: EditorTab = {
          path: targetPath,
          content: fileRes.content,
          initialContent: fileRes.content,
          isDirty: false,
          isNew: false,
          isImage: fileRes.isImage,
          mime: fileRes.mime,
          isUnviewable: fileRes.isUnviewable,
          unviewableReason: fileRes.unviewableReason,
        };
        setOpenTabs((prev) => [...prev, newTab]);
        setActiveTabPath(targetPath);
        setIsEditMode(true);
        if (isMobile) setIsExplorerCollapsed(true);
      } catch {
        const newTab: EditorTab = {
          path: targetPath,
          content: '',
          initialContent: '',
          isDirty: true,
          isNew: true,
        };
        setOpenTabs((prev) => [...prev, newTab]);
        setActiveTabPath(targetPath);
        setIsEditMode(true);
        if (isMobile) setIsExplorerCollapsed(true);
      } finally {
        setOpeningInEditor('');
      }
    },
    [cwd, openTabs, fetchAllFileContent, isMobile]
  );

  // When no tabs are open, pressing '+' creates a new file (REQ-IDE-SPLIT-PANE)
  useEffect(() => {
    if (openTabs.length > 0) return;
    const handleKeyDown = (e: KeyboardEvent) => {
      const target = e.target as HTMLElement | null;
      const isInput = target && (target.tagName === 'INPUT' || target.tagName === 'TEXTAREA');
      if (!isInput && (e.key === '+' || e.key === '=')) {
        e.preventDefault();
        void handleEditorNewFile('untitled.txt');
      }
    };
    window.addEventListener('keydown', handleKeyDown);
    return () => window.removeEventListener('keydown', handleKeyDown);
  }, [openTabs.length, handleEditorNewFile]);

  const saveActiveFile = useCallback(async () => {
    if (!activeEditorTab || activeEditorTab.isImage || activeEditorTab.isUnviewable || writeState.isLoading) return;
    setSaveFeedback(null);
    try {
      const res = await writeProjectFile({
        projectId,
        bridgeId,
        path: activeEditorTab.path,
        content: activeEditorTab.content,
        encoding: 'utf8',
      }).unwrap();

      if (res.ok) {
        setOpenTabs((prev) =>
          prev.map((t) =>
            t.path === activeEditorTab.path
              ? { ...t, initialContent: t.content, isDirty: false, isNew: false }
              : t
          )
        );
        setSaveFeedback({
          type: 'success',
          message: `Saved ${baseName(activeEditorTab.path)}`,
        });
        void load(cwd);
      } else {
        setSaveFeedback({
          type: 'error',
          message: res.error_code || res.message || res.error?.message || 'Failed to save file',
        });
      }
    } catch (err: any) {
      setSaveFeedback({
        type: 'error',
        message: str(err?.message || err?.error) || 'Failed to save file',
      });
    }
  }, [activeEditorTab, writeState.isLoading, writeProjectFile, projectId, bridgeId, cwd, load]);

  const saveAllFiles = useCallback(async () => {
    const dirtyTabs = openTabs.filter((t) => t.isDirty && !t.isImage && !t.isUnviewable);
    if (dirtyTabs.length === 0 || batchWriteState.isLoading) return;
    setSaveFeedback(null);
    try {
      const res = await batchWriteProjectFiles({
        projectId,
        bridgeId,
        files: dirtyTabs.map((t) => ({ path: t.path, content: t.content })),
      }).unwrap();

      if (res.ok) {
        const errorPaths = new Set((res.errors || []).map((e) => e.path));
        setOpenTabs((prev) =>
          prev.map((t) => {
            if (dirtyTabs.some((d) => d.path === t.path) && !errorPaths.has(t.path)) {
              return { ...t, initialContent: t.content, isDirty: false, isNew: false };
            }
            return t;
          })
        );
        void load(cwd);
        if (res.errors && res.errors.length > 0) {
          setSaveFeedback({
            type: 'warning',
            message: `Saved ${res.saved?.length || 0} files with ${res.errors.length} errors`,
          });
        } else {
          setSaveFeedback({
            type: 'success',
            message: `Saved all ${dirtyTabs.length} modified file${dirtyTabs.length === 1 ? '' : 's'}`,
          });
        }
      } else {
        setSaveFeedback({
          type: 'error',
          message: res.error_code || res.message || res.error?.message || 'Failed to save files',
        });
      }
    } catch (err: any) {
      setSaveFeedback({
        type: 'error',
        message: str(err?.message || err?.error) || 'Failed to save files',
      });
    }
  }, [openTabs, batchWriteState.isLoading, batchWriteProjectFiles, projectId, bridgeId, cwd, load]);

  const handleContentChange = useCallback(
    (path: string, newContent: string) => {
      setOpenTabs((prev) =>
        prev.map((t) => {
          if (t.path !== path) return t;
          const isDirty = t.isNew ? true : newContent !== t.initialContent;
          return { ...t, content: newContent, isDirty };
        })
      );
    },
    []
  );

  const selectTab = useCallback((path: string) => {
    setActiveTabPath(path);
  }, []);

  const closeTab = useCallback(
    (path: string, force = false) => {
      const tab = openTabs.find((t) => t.path === path);
      if (!tab) return;
      if (!force && tab.isDirty) {
        setConfirmClosePath(path);
        return;
      }
      setOpenTabs((prev) => {
        const next = prev.filter((t) => t.path !== path);
        if (activeTabPath === path) {
          if (next.length > 0) {
            const idx = prev.findIndex((t) => t.path === path);
            const nextActive = next[Math.min(idx, next.length - 1)].path;
            setActiveTabPath(nextActive);
          } else {
            setActiveTabPath('');
            setIsEditMode(false);
          }
        }
        return next;
      });
    },
    [openTabs, activeTabPath]
  );

  // Global keyboard shortcuts for Cmd+S / Ctrl+S and Cmd+Shift+S / Ctrl+Shift+S
  useEffect(() => {
    if (!isEditMode) return;
    const handleKeyDown = (e: KeyboardEvent) => {
      if ((e.metaKey || e.ctrlKey) && (e.key === 's' || e.key === 'S')) {
        e.preventDefault();
        e.stopPropagation();
        if (e.shiftKey) {
          void saveAllFiles();
        } else {
          void saveActiveFile();
        }
      }
    };
    window.addEventListener('keydown', handleKeyDown, true);
    return () => window.removeEventListener('keydown', handleKeyDown, true);
  }, [isEditMode, saveActiveFile, saveAllFiles]);

  // ---- Mutations ------------------------------------------------------------

  async function submitPending() {
    const name = nameDraft.trim();
    if (!pending) return;
    setError('');
    try {
      if (pending.kind === 'new-file') {
        if (!name) return;
        const targetPath = joinPath(cwd, name);
        const res = await createFile({ projectId, bridgeId, path: targetPath }).unwrap();
        if (!res.ok) return setError(mutationError(res.error?.code, res.error?.message) || 'Could not create file');
        setPending(null);
        setNameDraft('');
        await load(cwd);
        void openFileInEditor(targetPath);
        return;
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

  const wrapperCls = 'relative flex h-full min-h-0 w-full flex-col bg-surface';

  return (
    <div data-debug-id={`${debugPrefix}-panel`} className={wrapperCls}>

      {/* Sub-tabs: file tree vs VCS Changes. The Changes pill is only offered
          when the project root has a detected VCS provider. */}
      {vcsProvider ? (
        <div data-debug-id={`${debugPrefix}-subtabs`} className="flex items-center gap-1.5 border-b border-subtle px-3 py-2">
          <button
            data-debug-id={`${debugPrefix}-tab-files`}
            type="button"
            onClick={() => setActiveTab('files')}
            aria-pressed={activeTab === 'files' ? 'true' : 'false'}
            className={`rounded-full border px-2.5 py-1 text-caption ${activeTab === 'files' ? 'border-accent bg-accent/20 text-accent' : 'border-subtle text-muted hover:bg-neutral-soft hover:text-primary'}`}
          >
            📁 Files
          </button>
          <button
            data-debug-id={`${debugPrefix}-tab-changes`}
            type="button"
            onClick={() => setActiveTab('changes')}
            aria-pressed={activeTab === 'changes' ? 'true' : 'false'}
            className={`rounded-full border px-2.5 py-1 text-caption ${activeTab === 'changes' ? 'border-accent bg-accent/20 text-accent' : 'border-subtle text-muted hover:bg-neutral-soft hover:text-primary'}`}
          >
            ± Changes
          </button>
        </div>
      ) : null}

      {activeTab === 'changes' && vcsProvider ? (
        <div className="flex min-h-0 flex-1 flex-col">
          <ProjectVcsPanel projectId={projectId} bridgeId={bridgeId} onClose={onClose ?? (() => {})} isMobile={isMobile} />
        </div>
      ) : (
      <>
      {/* Pending review comments bar — spans ALL files in this conversation. */}
      {comments.length > 0 ? (
        <div data-debug-id={`${debugPrefix}-comments-bar`} className="flex items-center gap-2 border-b border-accent/30 bg-accent/10 px-3 py-2">
          <div data-debug-id={`${debugPrefix}-comments-count`} className="min-w-0 flex-1 text-[11.5px] text-accent">
            {comments.length} comment{comments.length === 1 ? '' : 's'} on {filesWithComments} file{filesWithComments === 1 ? '' : 's'}
            {publishError ? <span className="ml-2 text-danger">{publishError}</span> : null}
          </div>
          <button
            data-debug-id={`${debugPrefix}-comments-clear-btn`}
            type="button"
            onClick={() => { setComments([]); setPublishError(''); }}
            disabled={publishing}
            className="shrink-0 rounded-lg border border-subtle px-2 py-1 text-caption text-muted hover:bg-neutral-soft hover:text-primary disabled:opacity-50"
          >
            Clear
          </button>
          <button
            data-debug-id={`${debugPrefix}-comments-send-btn`}
            type="button"
            onClick={() => void publishComments()}
            disabled={publishing || !onPublishComments}
            className="shrink-0 rounded-lg bg-accent px-2.5 py-1 text-caption font-semibold text-accent-fg hover:opacity-90 disabled:opacity-50"
            title={onPublishComments ? 'Send all comments to the agent' : 'Sending is unavailable here'}
          >
            {publishing ? 'Sending…' : 'Send to agent'}
          </button>
        </div>
      ) : null}

      {!projectId ? (
        <div data-debug-id={`${debugPrefix}-no-project`} className="grid flex-1 place-items-center p-6 text-center text-xs text-muted">
          No project is associated with this conversation.
        </div>
      ) : (
        <div data-debug-id={`${debugPrefix}-split-container`} className="flex min-h-0 flex-1 w-full flex-row overflow-hidden">
          {/* Left Column: Directory Explorer */}
          <div
            data-debug-id={`${debugPrefix}-explorer-pane`}
            style={!isExplorerCollapsed && !isMobile ? { width: explorerWidth } : undefined}
            className={`${
              isExplorerCollapsed ? 'hidden' : 'flex'
            } min-h-0 flex-col border-r border-subtle bg-surface shrink-0 ${isMobile ? 'w-full' : ''}`}
          >
            {/* Breadcrumb */}
            <div data-debug-id={`${debugPrefix}-breadcrumb`} className="flex items-center justify-between gap-1 border-b border-subtle px-3 py-1.5 text-[12px] text-muted">
              <div className="flex min-w-0 flex-1 flex-wrap items-center gap-0.5">
                {(() => {
                  const folderCount = comments.filter((c) => c.path === (cwd || '/') && c.line === 0).length;
                  return (
                    <button
                      data-debug-id={`${debugPrefix}-folder-comment-btn`}
                      type="button"
                      onClick={() => { setPathCommentDraft(''); setPathCommentFor({ path: cwd || '/', label: `folder: ${cwd || 'project root'}` }); }}
                      title="Comment on this folder"
                      aria-label="Comment on this folder"
                      className={`mr-1 relative grid h-6 w-6 shrink-0 place-items-center rounded border ${folderCount > 0 ? 'border-accent bg-accent/20 text-accent' : 'border-subtle text-muted hover:bg-neutral-soft hover:text-primary'}`}
                    >
                      <Icon name="chat" size={12} />
                      {folderCount > 0 ? <span className="absolute -right-1 -top-1 grid h-3.5 min-w-3.5 place-items-center rounded-full bg-accent px-0.5 text-[8px] font-bold text-accent-fg">{folderCount}</span> : null}
                    </button>
                  );
                })()}
                {crumbs.map((c, i) => (
                  <span key={c.path || 'root'} className="flex items-center gap-0.5">
                    {i > 0 ? <Icon name="chevron-right" size={12} className="text-faint" /> : null}
                    <button
                      data-debug-id={`${debugPrefix}-crumb-${i}`}
                      type="button"
                      onClick={() => openDir(c.path)}
                      disabled={i === crumbs.length - 1}
                      className="max-w-[160px] truncate rounded px-1 py-0.5 hover:bg-neutral-soft hover:text-primary disabled:cursor-default disabled:text-primary disabled:hover:bg-transparent"
                    >
                      {c.label}
                    </button>
                  </span>
                ))}
              </div>
              <IconButton
                icon="refresh"
                label={lastRefreshed ? `Refresh (last: ${new Date(lastRefreshed).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' })})` : 'Refresh'}
                variant="solid"
                size="sm"
                data-debug-id={`${debugPrefix}-refresh-btn`}
                onClick={refresh}
                className="shrink-0"
              />
            </div>

            {/* Toolbar */}
            <div className="flex flex-wrap items-center gap-1.5 border-b border-subtle px-3 py-2">
              <button
                data-debug-id={`${debugPrefix}-explorer-toggle-btn`}
                type="button"
                onClick={() => setIsExplorerCollapsed(true)}
                title="Collapse file explorer (maximize editor)"
                aria-label="Collapse file explorer"
                className="inline-flex items-center gap-1 rounded-lg border border-subtle px-2 py-1 text-caption text-muted hover:bg-neutral-soft hover:text-primary"
              >
                <Icon name="panel-left" size={12} />
                <span className="hidden sm:inline">Collapse</span>
              </button>
              <button
                data-debug-id={`${debugPrefix}-new-file-btn`}
                type="button"
                onClick={() => beginAction({ kind: 'new-file' })}
                className="inline-flex items-center gap-1 rounded-lg border border-subtle px-2 py-1 text-caption text-muted hover:bg-neutral-soft hover:text-primary"
              >
                <Icon name="file" size={12} /> New file
              </button>
              <button
                data-debug-id={`${debugPrefix}-new-dir-btn`}
                type="button"
                onClick={() => beginAction({ kind: 'new-dir' })}
                className="inline-flex items-center gap-1 rounded-lg border border-subtle px-2 py-1 text-caption text-muted hover:bg-neutral-soft hover:text-primary"
              >
                <Icon name="folder" size={12} /> New folder
              </button>
              {openTabs.length > 0 ? (
                <button
                  data-debug-id={`${debugPrefix}-toolbar-editor-btn`}
                  type="button"
                  onClick={() => {
                    setIsEditMode(true);
                    if (isMobile) setIsExplorerCollapsed(true);
                  }}
                  className="inline-flex items-center gap-1 rounded-lg border border-accent/40 bg-accent/10 px-2 py-1 text-caption font-medium text-accent hover:bg-accent/20"
                  title="Return to code editor"
                >
                  <Icon name="pencil" size={12} /> Editor ({openTabs.length}){openTabs.some((t) => t.isDirty) ? ' •' : ''}
                </button>
              ) : null}
              <button
                data-debug-id={`${debugPrefix}-hidden-toggle`}
                type="button"
                onClick={() => setIncludeHidden((v) => !v)}
                aria-pressed={includeHidden ? 'true' : 'false'}
                title={includeHidden ? 'Hide dotfiles (names starting with ".")' : 'Show hidden dotfiles (names starting with ".")'}
                className={`ml-auto rounded-lg border px-2 py-1 text-caption ${includeHidden ? 'border-accent bg-accent/10 text-accent' : 'border-subtle text-muted hover:bg-neutral-soft hover:text-primary'}`}
              >
                {includeHidden ? 'Hide hidden' : 'Show hidden'}
              </button>
            </div>

            {/* Inline create/rename input */}
            {pending ? (
              <div data-debug-id={`${debugPrefix}-name-editor`} className="flex items-center gap-1.5 border-b border-subtle bg-surface-raised px-3 py-2">
                <Icon name={pending.kind === 'new-dir' ? 'folder' : 'file'} size={13} className="text-muted" />
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
                  className="min-w-0 flex-1 rounded-lg border border-subtle bg-surface-raised px-2 py-1 text-[12px] text-primary placeholder:text-muted focus:border-accent focus:outline-none"
                />
                <button
                  data-debug-id={`${debugPrefix}-name-submit-btn`}
                  type="button"
                  disabled={mutating || !nameDraft.trim()}
                  onClick={() => void submitPending()}
                  className="rounded-lg bg-accent px-2 py-1 text-caption font-semibold text-accent-fg hover:opacity-90 disabled:opacity-50"
                >
                  {pending.kind === 'rename' ? 'Rename' : 'Create'}
                </button>
                <button
                  type="button"
                  onClick={() => { setPending(null); setNameDraft(''); }}
                  className="rounded-lg px-1.5 py-1 text-caption text-muted hover:text-primary"
                >
                  Cancel
                </button>
              </div>
            ) : null}

            {/* Directory list */}
            <div data-debug-id={`${debugPrefix}-list`} className="min-h-0 flex-1 overflow-y-auto">
              {loading ? (
                <div data-debug-id={`${debugPrefix}-loading`} className="p-4 text-center text-xs text-muted">Loading…</div>
              ) : error && sortedEntries.length === 0 ? (
                // Don't show the misleading "empty folder" placeholder when the load
                // actually FAILED (e.g. project not configured on this bridge, or the
                // bridge is offline). The error banner below carries the reason.
                <div data-debug-id={`${debugPrefix}-load-error`} className="p-6 text-center text-xs text-muted">Couldn’t load files — see the message below.</div>
              ) : sortedEntries.length === 0 ? (
                <div data-debug-id={`${debugPrefix}-empty`} className="p-6 text-center text-xs text-faint">This folder is empty.</div>
              ) : (
                <ul>
                  {sortedEntries.map((e) => {
                    const isOpening = !e.is_dir && openingInEditor === joinPath(cwd, e.name);
                    const isActiveFile = !e.is_dir && activeTabPath === joinPath(cwd, e.name);
                    return (
                    <li key={`${e.is_dir ? 'd' : 'f'}:${e.name}`} className={`group flex items-center gap-2 border-b border-subtle/40 px-3 py-1.5 ${isActiveFile ? 'bg-accent/10 border-accent/20' : 'hover:bg-neutral-soft'}`}>
                      <button
                        data-debug-id={`${debugPrefix}-entry-${e.name}`}
                        type="button"
                        disabled={isOpening}
                        onClick={() => (e.is_dir ? openDir(joinPath(cwd, e.name)) : void openFileInEditor(joinPath(cwd, e.name)))}
                        className="flex min-w-0 flex-1 items-center gap-2 text-left"
                      >
                        {isOpening ? (
                          <Icon name="refresh" size={15} className="shrink-0 animate-spin text-accent" title="Loading file…" />
                        ) : (
                          <Icon name={e.is_dir ? 'folder' : 'file'} size={15} className={`shrink-0 ${e.is_dir ? 'text-accent' : isActiveFile ? 'text-accent' : 'text-muted'}`} />
                        )}
                        <span className={`min-w-0 flex-1 truncate text-[13px] ${isActiveFile ? 'font-medium text-accent' : e.hidden ? 'text-faint' : 'text-primary'}`}>{e.name}</span>
                        {e.has_git ? <span className="shrink-0 rounded bg-success-soft px-1.5 py-0.5 text-[9px] font-bold text-success">git</span> : null}
                        {!e.is_dir ? <span className="shrink-0 text-[10px] tabular-nums text-faint">{formatBytes(e.size)}</span> : null}
                        {e.modified_at ? <span className="hidden shrink-0 text-[10px] text-faint sm:inline">{formatModified(e.modified_at)}</span> : null}
                        {e.is_dir ? <Icon name="chevron-right" size={13} className="shrink-0 text-faint" /> : null}
                      </button>
                      {/* Row actions (edit / rename / delete) — visible on hover/focus. */}
                      <div className="flex shrink-0 items-center gap-0.5 opacity-0 transition-opacity group-hover:opacity-100 focus-within:opacity-100">
                        {!e.is_dir ? (
                          <button
                            data-debug-id={`${debugPrefix}-edit-${e.name}`}
                            type="button"
                            onClick={() => void openFileInEditor(joinPath(cwd, e.name))}
                            title={`Edit ${e.name}`}
                            aria-label={`Edit ${e.name}`}
                            className="grid h-7 w-7 place-items-center rounded-lg text-muted hover:bg-neutral-soft hover:text-primary"
                          >
                            <Icon name="pencil" size={13} />
                          </button>
                        ) : null}
                        <IconButton icon="pencil" label={`Rename ${e.name}`} size="sm" data-debug-id={`${debugPrefix}-rename-${e.name}`} onClick={() => beginAction({ kind: 'rename', entry: e })} />
                        <button
                          data-debug-id={`${debugPrefix}-delete-${e.name}`}
                          type="button"
                          disabled={mutating}
                          onClick={() => void removeEntry(e)}
                          title={`Delete ${e.name}`}
                          aria-label={`Delete ${e.name}`}
                          className="grid h-7 w-7 place-items-center rounded-lg text-muted hover:bg-danger-soft hover:text-danger disabled:opacity-40"
                        >
                          <Icon name="trash" size={13} />
                        </button>
                      </div>
                    </li>
                    );
                  })}
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
                    className="rounded-lg border border-subtle px-3 py-1.5 text-caption text-muted hover:bg-neutral-soft hover:text-primary disabled:opacity-50"
                  >
                    {loadingMore ? 'Loading…' : 'Load more'}
                  </button>
                </div>
              ) : null}
              {truncated ? (
                <div data-debug-id={`${debugPrefix}-truncated`} className="px-3 pb-3 text-center text-[10px] text-warning">
                  Listing truncated to the server maximum.
                </div>
              ) : null}
            </div>
          </div>

          {/* Resizer Divider */}
          {!isExplorerCollapsed && !isMobile ? (
            <div
              data-debug-id={`${debugPrefix}-resizer`}
              onMouseDown={startResizing}
              className="w-1 cursor-col-resize hover:bg-accent/40 active:bg-accent transition-colors shrink-0 select-none bg-subtle/20"
              title="Drag to resize explorer"
            />
          ) : null}

          {/* Right Column: Monaco Editor or Empty State */}
          <div
            data-debug-id={`${debugPrefix}-editor-pane`}
            className={`flex min-h-0 flex-1 flex-col overflow-hidden bg-surface ${
              isMobile && !isExplorerCollapsed ? 'hidden' : 'flex'
            }`}
          >
            {openTabs.length > 0 && activeEditorTab ? (
              <MonacoMultiFileEditor
                tabs={openTabs}
                activeTab={activeEditorTab}
                onSelectTab={selectTab}
                onCloseTab={closeTab}
                onContentChange={handleContentChange}
                onSaveActive={saveActiveFile}
                onSaveAll={saveAllFiles}
                isSaving={writeState.isLoading}
                isBatchSaving={batchWriteState.isLoading}
                saveFeedback={saveFeedback}
                onBackToFiles={() => setIsExplorerCollapsed((prev) => !prev)}
                onToggleExplorer={() => setIsExplorerCollapsed((prev) => !prev)}
                isExplorerCollapsed={isExplorerCollapsed}
                onNewFile={handleEditorNewFile}
                cwd={cwd}
                debugPrefix={debugPrefix}
                themeAppearance={theme?.appearance}
                comments={commentsForPath(activeEditorTab.path)}
                onAddComment={(line, lineText, body) => addComment(activeEditorTab.path, line, lineText, body)}
                onEditComment={editComment}
                onDeleteComment={deleteComment}
                onCommentFile={() => {
                  setPathCommentDraft('');
                  setPathCommentFor({
                    path: activeEditorTab.path,
                    label: `file: ${baseName(activeEditorTab.path)}`,
                  });
                }}
              />
            ) : (
              <div
                data-debug-id={`${debugPrefix}-editor-empty-state`}
                className="flex min-h-0 flex-1 flex-col bg-surface"
              >
                {isExplorerCollapsed ? (
                  <div className="flex items-center border-b border-subtle px-3 py-1.5 bg-surface">
                    <button
                      data-debug-id={`${debugPrefix}-explorer-toggle-btn`}
                      type="button"
                      onClick={() => setIsExplorerCollapsed(false)}
                      className="inline-flex items-center gap-1.5 rounded-lg border border-subtle px-2 py-1 text-caption text-muted hover:bg-neutral-soft hover:text-primary"
                      title="Expand file explorer"
                    >
                      <Icon name="panel-left" size={13} /> Files
                    </button>
                  </div>
                ) : null}
                <div className="flex min-h-0 flex-1 flex-col items-center justify-center p-8 text-center">
                  <div className="flex h-14 w-14 items-center justify-center rounded-2xl bg-neutral-soft text-muted mb-3">
                    <Icon name="file" size={28} />
                  </div>
                  <h3 className="text-body font-semibold text-primary mb-1">No Files Open</h3>
                  <p
                    data-debug-id={`${debugPrefix}-empty-prompt`}
                    className="max-w-md text-caption text-muted mb-4"
                  >
                    Select a file from the explorer to view or edit, or press + to create a new file
                  </p>
                  <button
                    data-debug-id={`${debugPrefix}-empty-new-file-btn`}
                    type="button"
                    onClick={() => void handleEditorNewFile('untitled.txt')}
                    className="inline-flex items-center gap-1.5 rounded-lg bg-accent px-3 py-1.5 text-caption font-semibold text-accent-fg hover:opacity-90"
                    title="Create new file (+)"
                  >
                    <Icon name="plus" size={14} /> + New File
                  </button>
                </div>
              </div>
            )}
          </div>
        </div>
      )}

      {/* Path-level (file/folder) comment composer overlay. */}
      {pathCommentFor ? (
        <div className="absolute inset-x-0 bottom-0 z-10 border-t border-accent/40 bg-surface p-3 shadow-panel">
          <div data-debug-id={`${debugPrefix}-path-composer`} className="mx-auto max-w-2xl">
            <div className="mb-1 text-caption text-muted">Comment on {pathCommentFor.label}</div>
            <textarea
              data-debug-id={`${debugPrefix}-path-composer-input`}
              autoFocus
              value={pathCommentDraft}
              onChange={(e) => setPathCommentDraft(e.target.value)}
              onKeyDown={(e) => {
                if (e.key === 'Escape') { e.preventDefault(); setPathCommentFor(null); }
                if ((e.metaKey || e.ctrlKey) && e.key === 'Enter' && pathCommentDraft.trim()) {
                  e.preventDefault();
                  addComment(pathCommentFor.path, 0, pathCommentFor.label, pathCommentDraft);
                  setPathCommentFor(null);
                }
              }}
              rows={3}
              placeholder={`Comment on ${pathCommentFor.label}… (Cmd/Ctrl+Enter to save)`}
              className="w-full resize-y rounded border border-subtle bg-surface-raised p-2 text-[12px] text-primary placeholder:text-muted focus:border-accent focus:outline-none"
            />
            <div className="mt-1.5 flex justify-end gap-1.5">
              <button data-debug-id={`${debugPrefix}-path-composer-cancel`} type="button" onClick={() => setPathCommentFor(null)} className="rounded-lg border border-subtle px-2.5 py-1 text-caption text-muted hover:bg-neutral-soft hover:text-primary">Cancel</button>
              <button
                data-debug-id={`${debugPrefix}-path-composer-save`}
                type="button"
                disabled={!pathCommentDraft.trim()}
                onClick={() => { addComment(pathCommentFor.path, 0, pathCommentFor.label, pathCommentDraft); setPathCommentFor(null); }}
                className="rounded-lg bg-accent px-2.5 py-1 text-caption font-semibold text-accent-fg hover:opacity-90 disabled:opacity-50"
              >
                Comment
              </button>
            </div>
          </div>
        </div>
      ) : null}

      {error ? (
        <div data-debug-id={`${debugPrefix}-error`} className="border-t border-danger/30 bg-danger-soft px-3 py-2 text-caption text-danger">
          {error}
        </div>
      ) : null}
      </>
      )}

      {/* Confirmation modal for closing dirty tabs */}
      {confirmClosePath ? (
        <div
          data-debug-id={`${debugPrefix}-close-confirm-modal`}
          className="absolute inset-0 z-50 flex items-center justify-center bg-canvas/80 backdrop-blur-sm p-4"
        >
          <div className="w-full max-w-sm rounded-xl border border-subtle bg-surface-raised p-4 shadow-xl">
            <div className="flex items-center gap-2 text-warning mb-2">
              <Icon name="alert" size={16} />
              <h4 className="text-body font-semibold text-primary">Unsaved Changes</h4>
            </div>
            <p className="text-caption text-muted mb-4">
              You have unsaved changes in{' '}
              <span className="font-mono text-primary font-medium">
                {baseName(confirmClosePath)}
              </span>
              . Are you sure you want to discard your changes and close this tab?
            </p>
            <div className="flex justify-end gap-2">
              <button
                data-debug-id={`${debugPrefix}-confirm-close-cancel`}
                type="button"
                onClick={() => setConfirmClosePath(null)}
                className="rounded-lg border border-subtle px-3 py-1.5 text-caption text-muted hover:bg-neutral-soft hover:text-primary"
              >
                Cancel
              </button>
              <button
                data-debug-id={`${debugPrefix}-confirm-close-discard`}
                type="button"
                onClick={() => {
                  closeTab(confirmClosePath, true);
                  setConfirmClosePath(null);
                }}
                className="rounded-lg bg-danger px-3 py-1.5 text-caption font-semibold text-accent-fg hover:opacity-90"
              >
                Discard & Close
              </button>
            </div>
          </div>
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

// ---- Multi-file Monaco Code Editor ------------------------------------------

function MonacoMultiFileEditor({
  tabs,
  activeTab,
  onSelectTab,
  onCloseTab,
  onContentChange,
  onSaveActive,
  onSaveAll,
  isSaving,
  isBatchSaving,
  saveFeedback,
  onBackToFiles,
  onToggleExplorer,
  isExplorerCollapsed = false,
  onNewFile,
  debugPrefix,
  themeAppearance,
  cwd,
  comments = [],
  onAddComment,
  onEditComment,
  onDeleteComment,
  onCommentFile,
}: {
  tabs: EditorTab[];
  activeTab: EditorTab;
  onSelectTab: (path: string) => void;
  onCloseTab: (path: string) => void;
  onContentChange: (path: string, content: string) => void;
  onSaveActive: () => void;
  onSaveAll: () => void;
  isSaving: boolean;
  isBatchSaving: boolean;
  saveFeedback: { type: 'success' | 'warning' | 'error'; message: string } | null;
  onBackToFiles: () => void;
  onToggleExplorer?: () => void;
  isExplorerCollapsed?: boolean;
  onNewFile: (path: string) => void;
  debugPrefix: string;
  themeAppearance?: string;
  cwd?: string;
  comments?: FileLineComment[];
  onAddComment?: (line: number, lineText: string, body: string) => void;
  onEditComment?: (id: string, body: string) => void;
  onDeleteComment?: (id: string) => void;
  onCommentFile?: () => void;
}) {
  const monacoTheme = themeAppearance === 'light' ? 'light' : 'vs-dark';
  const language = useMemo(() => getLanguageForMonaco(activeTab.path), [activeTab.path]);
  const dirtyCount = useMemo(() => tabs.filter((t) => t.isDirty).length, [tabs]);
  const fileLevelCount = useMemo(() => comments.filter((c) => c.line === 0).length, [comments]);

  const [isPromptingNewFile, setIsPromptingNewFile] = useState(false);
  const [newFileName, setNewFileName] = useState('');

  const onSaveActiveRef = useRef(onSaveActive);
  const onSaveAllRef = useRef(onSaveAll);
  useEffect(() => {
    onSaveActiveRef.current = onSaveActive;
  }, [onSaveActive]);
  useEffect(() => {
    onSaveAllRef.current = onSaveAll;
  }, [onSaveAll]);

  const handleEditorMount: OnMount = (editor, monaco) => {
    editor.addCommand(monaco.KeyMod.CtrlCmd | monaco.KeyCode.KeyS, () => {
      onSaveActiveRef.current();
    });
    editor.addCommand(
      monaco.KeyMod.CtrlCmd | monaco.KeyMod.Shift | monaco.KeyCode.KeyS,
      () => {
        onSaveAllRef.current();
      }
    );
  };

  const options: EditorProps['options'] = {
    minimap: { enabled: true },
    wordWrap: 'on',
    lineNumbers: 'on',
    scrollBeyondLastLine: false,
    automaticLayout: true,
    fontSize: 13,
    fontFamily:
      'ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, "Liberation Mono", "Courier New", monospace',
    tabSize: 2,
    renderWhitespace: 'selection',
    smoothScrolling: true,
  };

  return (
    <div
      data-debug-id={`${debugPrefix}-monaco-editor`}
      className="flex min-h-0 flex-1 flex-col bg-surface"
    >
      {/* Editor Header */}
      <div className="flex flex-wrap items-center justify-between gap-2 border-b border-subtle px-3 py-1.5 bg-surface">
        <div className="flex items-center gap-2 min-w-0">
          <button
            data-debug-id={`${debugPrefix}-editor-back-files-btn`}
            type="button"
            onClick={onBackToFiles}
            className="inline-flex items-center gap-1 rounded-lg border border-subtle px-2 py-1 text-caption text-muted hover:bg-neutral-soft hover:text-primary"
            title={isExplorerCollapsed ? 'Show file explorer' : 'Toggle file explorer'}
          >
            <Icon name={isExplorerCollapsed ? 'panel-left' : 'chevron-left'} size={13} /> Files
          </button>
          <button
            data-debug-id={`${debugPrefix}-explorer-toggle-btn`}
            type="button"
            onClick={onToggleExplorer || onBackToFiles}
            className="inline-flex items-center justify-center rounded-lg border border-subtle p-1 text-caption text-muted hover:bg-neutral-soft hover:text-primary"
            title={isExplorerCollapsed ? 'Expand file explorer' : 'Collapse file explorer (maximize editor)'}
            aria-label={isExplorerCollapsed ? 'Expand file explorer' : 'Collapse file explorer'}
          >
            <Icon name="panel-left" size={13} />
          </button>
          <button
            data-debug-id={`${debugPrefix}-editor-new-file-btn`}
            type="button"
            onClick={() => setIsPromptingNewFile(true)}
            className="inline-flex items-center gap-1 rounded-lg border border-subtle px-2 py-1 text-caption text-muted hover:bg-neutral-soft hover:text-primary"
            title="Create new file"
          >
            <Icon name="plus" size={12} /> New
          </button>
          <div className="text-[12px] font-mono text-faint truncate" title={activeTab.path}>
            {activeTab.path}
          </div>
        </div>

        <div className="flex items-center gap-1.5 ml-auto">
          {onCommentFile ? (
            <button
              data-debug-id={`${debugPrefix}-file-comment-btn`}
              type="button"
              onClick={onCommentFile}
              title="Comment on this file"
              aria-label="Comment on this file"
              className={`relative shrink-0 grid h-7 w-7 place-items-center rounded-lg border ${
                fileLevelCount > 0
                  ? 'border-accent bg-accent/20 text-accent'
                  : 'border-subtle text-muted hover:bg-neutral-soft hover:text-primary'
              }`}
            >
              <Icon name="chat" size={13} />
              {fileLevelCount > 0 ? (
                <span className="absolute -right-1 -top-1 grid h-3.5 min-w-3.5 place-items-center rounded-full bg-accent px-0.5 text-[8px] font-bold text-accent-fg">
                  {fileLevelCount}
                </span>
              ) : null}
            </button>
          ) : null}

          {saveFeedback ? (
            <div
              data-debug-id={`${debugPrefix}-save-toast`}
              className={`inline-flex items-center gap-1 px-2 py-0.5 rounded text-caption font-medium transition-all ${
                saveFeedback.type === 'success'
                  ? 'bg-success-soft text-success border border-success/30'
                  : saveFeedback.type === 'warning'
                  ? 'bg-warning-soft text-warning border border-warning/30'
                  : 'bg-danger-soft text-danger border border-danger/30'
              }`}
            >
              <Icon name={saveFeedback.type === 'success' ? 'check' : 'alert'} size={12} />
              <span>{saveFeedback.message}</span>
            </div>
          ) : null}

          <button
            data-debug-id={`${debugPrefix}-editor-save-btn`}
            type="button"
            disabled={isSaving || !activeTab.isDirty || activeTab.isImage || activeTab.isUnviewable}
            onClick={onSaveActive}
            className="inline-flex items-center gap-1 rounded-lg bg-accent px-2.5 py-1 text-caption font-semibold text-accent-fg hover:opacity-90 disabled:opacity-40"
            title="Save active file (Cmd+S / Ctrl+S)"
          >
            {isSaving ? <Icon name="refresh" size={12} className="animate-spin" /> : null}
            Save
          </button>

          <button
            data-debug-id={`${debugPrefix}-editor-save-all-btn`}
            type="button"
            disabled={isBatchSaving || dirtyCount === 0}
            onClick={onSaveAll}
            className="inline-flex items-center gap-1 rounded-lg border border-accent/40 bg-accent/10 px-2.5 py-1 text-caption font-semibold text-accent hover:bg-accent/20 disabled:opacity-40"
            title="Save all modified files (Cmd+Shift+S / Ctrl+Shift+S)"
          >
            {isBatchSaving ? <Icon name="refresh" size={12} className="animate-spin" /> : null}
            Save All {dirtyCount > 0 ? `(${dirtyCount})` : ''}
          </button>
        </div>
      </div>

      {/* Tab Strip */}
      <div
        data-debug-id={`${debugPrefix}-tab-strip`}
        className="flex items-center overflow-x-auto border-b border-subtle bg-surface-raised px-1 py-1 gap-1 text-[12px] select-none"
      >
        {tabs.map((tab) => {
          const isActive = tab.path === activeTab.path;
          const name = baseName(tab.path);
          return (
            <div
              key={tab.path}
              data-debug-id={`${debugPrefix}-editor-tab-${name}`}
              data-active={isActive ? 'true' : 'false'}
              onClick={() => onSelectTab(tab.path)}
              title={tab.path}
              className={`group relative flex items-center gap-1.5 rounded-md px-2.5 py-1 cursor-pointer transition-colors ${
                isActive
                  ? 'bg-surface text-primary font-medium border border-subtle shadow-sm'
                  : 'text-muted hover:bg-neutral-soft hover:text-primary border border-transparent'
              }`}
            >
              <Icon name="file" size={12} className={isActive ? 'text-accent' : 'text-muted'} />
              <span className="max-w-[140px] truncate">{name}</span>
              {tab.isDirty ? (
                <span
                  data-debug-id={`${debugPrefix}-tab-dirty-bullet-${name}`}
                  className="text-accent font-bold text-[14px] leading-none"
                  title="Unsaved changes"
                >
                  •
                </span>
              ) : null}
              <button
                data-debug-id={`${debugPrefix}-tab-close-btn-${name}`}
                type="button"
                onClick={(e) => {
                  e.stopPropagation();
                  onCloseTab(tab.path);
                }}
                title={tab.isDirty ? 'Close (unsaved changes)' : 'Close'}
                className="grid h-4 w-4 place-items-center rounded hover:bg-neutral-soft text-muted hover:text-primary ml-0.5 opacity-60 group-hover:opacity-100"
              >
                <Icon name="close" size={10} />
              </button>
            </div>
          );
        })}

        {/* Tab strip new file prompt / plus button */}
        {isPromptingNewFile ? (
          <div
            data-debug-id={`${debugPrefix}-new-file-inline-prompt`}
            className="flex items-center gap-1 rounded bg-surface border border-accent/40 px-1.5 py-0.5 shadow-sm"
          >
            <Icon name="file" size={12} className="text-accent" />
            <input
              data-debug-id={`${debugPrefix}-new-file-input`}
              autoFocus
              type="text"
              value={newFileName}
              onChange={(e) => setNewFileName(e.target.value)}
              onKeyDown={(e) => {
                if (e.key === 'Enter') {
                  const target = newFileName.trim();
                  if (target) {
                    onNewFile(target);
                    setIsPromptingNewFile(false);
                    setNewFileName('');
                  }
                } else if (e.key === 'Escape') {
                  setIsPromptingNewFile(false);
                  setNewFileName('');
                }
              }}
              placeholder={cwd ? `${cwd}/filename` : 'path/to/file'}
              className="w-36 bg-transparent text-[12px] text-primary placeholder:text-muted focus:outline-none"
            />
            <button
              data-debug-id={`${debugPrefix}-new-file-confirm-btn`}
              type="button"
              disabled={!newFileName.trim()}
              onClick={() => {
                const target = newFileName.trim();
                if (target) {
                  onNewFile(target);
                  setIsPromptingNewFile(false);
                  setNewFileName('');
                }
              }}
              className="text-accent hover:text-accent/80 p-0.5 disabled:opacity-40"
              title="Create"
            >
              <Icon name="check" size={12} />
            </button>
            <button
              data-debug-id={`${debugPrefix}-new-file-cancel-btn`}
              type="button"
              onClick={() => {
                setIsPromptingNewFile(false);
                setNewFileName('');
              }}
              className="text-muted hover:text-primary p-0.5"
              title="Cancel"
            >
              <Icon name="close" size={10} />
            </button>
          </div>
        ) : (
          <button
            data-debug-id={`${debugPrefix}-new-tab-btn`}
            type="button"
            onClick={() => setIsPromptingNewFile(true)}
            title="New file"
            className="grid h-6 w-6 place-items-center rounded hover:bg-neutral-soft text-muted hover:text-primary transition-colors ml-0.5"
          >
            <Icon name="plus" size={12} />
          </button>
        )}
      </div>

      {/* File-level & line comments for active tab */}
      {comments.length > 0 && onEditComment && onDeleteComment ? (
        <div data-debug-id={`${debugPrefix}-file-comments`} className="border-b border-subtle bg-surface-raised p-2 max-h-36 overflow-y-auto">
          {comments.map((c) => (
            <LineComment
              key={c.id}
              comment={c}
              debugPrefix={debugPrefix}
              gutterWidthCh={0}
              onEdit={onEditComment}
              onDelete={onDeleteComment}
            />
          ))}
        </div>
      ) : null}

      {/* Monaco Editor Canvas or Image / Unviewable Preview */}
      <div className="relative min-h-0 flex-1 overflow-hidden">
        {activeTab.isImage ? (
          <div
            data-debug-id={`${debugPrefix}-image-preview`}
            className="flex h-full w-full items-center justify-center overflow-auto bg-canvas p-4"
          >
            <img
              data-debug-id={`${debugPrefix}-file-image`}
              src={`data:${activeTab.mime || 'image/png'};base64,${activeTab.content}`}
              alt={baseName(activeTab.path)}
              className="max-h-full max-w-full rounded-lg object-contain shadow-sm"
            />
          </div>
        ) : activeTab.isUnviewable ? (
          <div
            data-debug-id={`${debugPrefix}-file-unviewable`}
            className="grid h-full place-items-center p-6 text-center text-xs text-muted"
          >
            {activeTab.unviewableReason || 'This file cannot be previewed or edited.'}
          </div>
        ) : (
          <Editor
            path={activeTab.path}
            value={activeTab.content}
            language={language}
            theme={monacoTheme}
            options={options}
            onChange={(val) => onContentChange(activeTab.path, val ?? '')}
            onMount={handleEditorMount}
            loading={
              <div className="p-4 text-center text-xs text-muted">
                Loading editor…
              </div>
            }
          />
        )}
      </div>
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
            <div className="group flex items-start hover:bg-neutral-soft">
              {/* Gutter: line number + hover comment button */}
              <div
                className="relative flex shrink-0 select-none items-center justify-end border-r border-subtle bg-surface pr-2 text-right text-faint"
                style={{ width: `calc(${gutterWidthCh}ch + 22px)` }}
              >
                <button
                  data-debug-id={`${debugPrefix}-line-comment-btn-${lineNo}`}
                  type="button"
                  onClick={() => setComposerLine((v) => (v === lineNo ? null : lineNo))}
                  title="Comment on this line"
                  aria-label={`Comment on line ${lineNo}`}
                  className={`absolute left-1 grid h-4 w-4 place-items-center rounded text-accent ${lineComments.length > 0 ? 'opacity-100' : 'opacity-0 group-hover:opacity-100'} hover:bg-accent/20`}
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
                  className="cursor-pointer tabular-nums hover:text-primary"
                >
                  {lineNo}
                </button>
              </div>
              {/* Code cell */}
              <div className={`min-w-0 flex-1 overflow-x-auto px-3 text-primary ${wrap ? 'whitespace-pre-wrap break-words' : 'whitespace-pre'}`}>
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
      <div data-debug-id={`${debugPrefix}-line-comment-${comment.id}`} className="my-1 mr-3 min-w-0 flex-1 rounded-lg border border-accent/30 bg-accent/10 px-2.5 py-1.5 font-sans text-[12px]">
        {editing ? (
          <div>
            <textarea
              data-debug-id={`${debugPrefix}-line-comment-edit-input-${comment.id}`}
              value={draft}
              onChange={(e) => setDraft(e.target.value)}
              rows={2}
              className="w-full resize-y rounded border border-subtle bg-surface-raised p-1.5 text-[12px] text-primary focus:border-accent focus:outline-none"
            />
            <div className="mt-1 flex justify-end gap-1.5">
              <button type="button" onClick={() => { setDraft(comment.body); setEditing(false); }} className="rounded border border-subtle px-2 py-0.5 text-caption text-muted hover:bg-neutral-soft hover:text-primary">Cancel</button>
              <button data-debug-id={`${debugPrefix}-line-comment-edit-save-${comment.id}`} type="button" onClick={() => { onEdit(comment.id, draft); setEditing(false); }} className="rounded bg-accent px-2 py-0.5 text-caption font-semibold text-accent-fg hover:opacity-90">Save</button>
            </div>
          </div>
        ) : (
          <div className="flex items-start gap-2">
            <div className="min-w-0 flex-1 whitespace-pre-wrap break-words text-primary">{comment.body}</div>
            <div className="flex shrink-0 items-center gap-1">
              <button data-debug-id={`${debugPrefix}-line-comment-edit-${comment.id}`} type="button" onClick={() => { setDraft(comment.body); setEditing(true); }} title="Edit" className="grid h-5 w-5 place-items-center rounded text-muted hover:bg-neutral-soft hover:text-primary"><Icon name="pencil" size={12} /></button>
              <button data-debug-id={`${debugPrefix}-line-comment-delete-${comment.id}`} type="button" onClick={() => onDelete(comment.id)} title="Delete" className="grid h-5 w-5 place-items-center rounded text-muted hover:bg-danger-soft hover:text-danger"><Icon name="trash" size={12} /></button>
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
          className="w-full resize-y rounded border border-subtle bg-surface-raised p-1.5 text-[12px] text-primary placeholder:text-muted focus:border-accent focus:outline-none"
        />
        <div className="mt-1 flex justify-end gap-1.5">
          <button data-debug-id={`${debugPrefix}-line-composer-cancel-${lineNo}`} type="button" onClick={onCancel} className="rounded border border-subtle px-2 py-0.5 text-caption text-muted hover:bg-neutral-soft hover:text-primary">Cancel</button>
          <button data-debug-id={`${debugPrefix}-line-composer-save-${lineNo}`} type="button" onClick={() => { if (draft.trim()) onSave(draft); }} disabled={!draft.trim()} className="rounded bg-accent px-2 py-0.5 text-caption font-semibold text-accent-fg hover:opacity-90 disabled:opacity-50">Comment</button>
        </div>
      </div>
    </div>
  );
}
