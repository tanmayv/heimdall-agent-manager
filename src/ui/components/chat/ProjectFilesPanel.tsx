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
import Editor, { DiffEditor, useMonaco, type OnMount, type DiffOnMount, type EditorProps, type DiffEditorProps } from '@monaco-editor/react';
import { initVimMode, VimMode } from 'monaco-vim';

import MarkdownBody from '../MarkdownBody';
import { highlightToLines, languageForFile, type CodeToken } from '../../utils/codeHighlight';
import { useTheme } from '../../store/themeSlice';
import { Icon, IconButton, Select } from '@ui';
import { useDialogA11y } from '../ui/composites/useDialogA11y';
import {
  useLazyListProjectDirQuery,
  useLazyReadProjectFileQuery,
  useLazyQuickOpenProjectFilesQuery,
  useCreateProjectFileMutation,
  useCreateProjectDirMutation,
  useMoveProjectPathMutation,
  useDeleteProjectPathMutation,
  useWriteProjectFileMutation,
  useBatchWriteProjectFilesMutation,
  type FsEntry,
  type FsListResult,
  type FsReadFileResult,
  type FsQuickOpenResult,
} from '../../api/endpoints/projectFs';
import {
  useGetProjectVcsStatusQuery,
  useGetVcsTargetsQuery,
  useGetVcsLogQuery,
  useLazyGetVcsFileContentQuery,
  useListVcsFilesQuery,
  useExecuteVcsActionMutation,
  useCommitVcsMutation,
  type VcsDiffTarget,
  type VcsLogEntry,
  type VcsFileStatus,
} from '../../api/endpoints/projectVcs';

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

// Subsequence fuzzy match: checks if all characters of pattern appear in text in order.
// Satisfies Duckie recommendation: e.g. 'RTK' matches 'ReducerToolKit.ts'.
export function subsequenceFuzzyMatch(pattern: string, text: string): boolean {
  if (!pattern) return true;
  const p = pattern.toLowerCase();
  const t = text.toLowerCase();
  let pIdx = 0;
  for (let tIdx = 0; tIdx < t.length; tIdx++) {
    if (t[tIdx] === p[pIdx]) {
      pIdx++;
      if (pIdx === p.length) return true;
    }
  }
  return false;
}

// Ranking score for fuzzy search results (higher score = better match)
export function fuzzyMatchScore(pattern: string, text: string): number {
  if (!pattern) return 1;
  const p = pattern.toLowerCase();
  const t = text.toLowerCase();
  const base = baseName(text).toLowerCase();
  if (base === p) return 1000;
  if (base.startsWith(p)) return 500;
  if (base.includes(p)) return 300;
  if (t.includes(p)) return 200;
  if (subsequenceFuzzyMatch(pattern, text)) {
    return 100 - Math.min(text.length - pattern.length, 90);
  }
  return 0;
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

// Status badge styling per change kind
const STATUS_BADGE: Record<string, { label: string; cls: string }> = {
  added: { label: 'A', cls: 'bg-success-soft text-success' },
  modified: { label: 'M', cls: 'bg-warning-soft text-warning' },
  deleted: { label: 'D', cls: 'bg-danger-soft text-danger' },
  renamed: { label: 'R', cls: 'bg-info-soft text-info' },
  untracked: { label: 'U', cls: 'bg-neutral-soft text-muted' },
};

function statusBadge(status: string): { label: string; cls: string } {
  return STATUS_BADGE[status] ?? { label: 'M', cls: 'bg-warning-soft text-warning' };
}

export type ProjectFilesPanelProps = {
  projectId: string;
  bridgeId?: string;
  projectName?: string;
  agentInstanceId?: string;
  // Scope key for the in-memory comment store: comments reset when this changes
  // (e.g. switching conversations) so review notes never leak across chats.
  conversationKey?: string;
  // Publish the collected comments as a single chat message. Returns true on
  // success (the panel then clears the local store). Parent owns the send.
  onPublishComments?: (markdown: string) => Promise<boolean>;
  onClose?: () => void;
  isMobile?: boolean;
  debugPrefix?: string;
  openFilePath?: string | null;
  onFileOpened?: () => void;
  onOpenQuickOpen?: () => void;
};

export default function ProjectFilesPanel({
  projectId,
  bridgeId = '',
  projectName,
  agentInstanceId,
  conversationKey = '',
  onPublishComments,
  onClose,
  isMobile = false,
  debugPrefix = 'project-files',
  openFilePath,
  onFileOpened,
  onOpenQuickOpen,
}: ProjectFilesPanelProps) {
  const [listDir] = useLazyListProjectDirQuery();
  const [readFile, readState] = useLazyReadProjectFileQuery();
  const monaco = useMonaco();

  const [createFile, createFileState] = useCreateProjectFileMutation();
  const [createDir, createDirState] = useCreateProjectDirMutation();
  const [movePath, moveState] = useMoveProjectPathMutation();
  const [deletePath, deleteState] = useDeleteProjectPathMutation();
  const [writeProjectFile, writeState] = useWriteProjectFileMutation();
  const [batchWriteProjectFiles, batchWriteState] = useBatchWriteProjectFilesMutation();
  const { theme } = useTheme();

  // VCS Integration (REQ-VCS-DIFF-TARGETS, REQ-VCS-FILE-CONTENT-API, REQ-VCS-STATUS-AND-LOG-INDICATORS, REQ-VCS-FILE-ACTIONS)
  const { data: vcsStatus } = useGetProjectVcsStatusQuery({ projectId, bridgeId }, { skip: !projectId });
  const { data: vcsTargetsData } = useGetVcsTargetsQuery({ projectId, bridgeId }, { skip: !projectId });
  const { data: vcsFilesData } = useListVcsFilesQuery({ projectId, bridgeId }, { skip: !projectId });
  const { data: vcsLogData } = useGetVcsLogQuery({ projectId, bridgeId, limit: 10 }, { skip: !projectId });
  const [getVcsFileContent] = useLazyGetVcsFileContentQuery();
  const [executeVcsAction, { isLoading: isVcsActionLoading }] = useExecuteVcsActionMutation();
  const [commitVcs, { isLoading: isCommitLoading }] = useCommitVcsMutation();

  const vcsTargets = vcsTargetsData?.targets || [];
  const [selectedDiffTarget, setSelectedDiffTarget] = useState<string>('');
  const [diffBaseContent, setDiffBaseContent] = useState<string>('');
  const [isFetchingBaseContent, setIsFetchingBaseContent] = useState<boolean>(false);

  // Commit modal state
  const [isCommitModalOpen, setIsCommitModalOpen] = useState<boolean>(false);
  const [commitMessage, setCommitMessage] = useState<string>('');
  const [isAmend, setIsAmend] = useState<boolean>(false);
  const [commitError, setCommitError] = useState<string>('');

  // Quick log popover state
  const [isLogPopoverOpen, setIsLogPopoverOpen] = useState<boolean>(false);
  const logPopoverRef = useRef<HTMLDivElement | null>(null);

  // Per-file revert confirm
  const [confirmRevertOpen, setConfirmRevertOpen] = useState<boolean>(false);

  // Quick Open Modal state (Cmd+P / Ctrl+P) (REQ-UI-GLOBAL-QUICK-OPEN)
  const [isQuickOpenOpen, setIsQuickOpenOpen] = useState(false);

  // Multi-file editor state (REQ-UI-INSTANCE-MONACO-PERSISTENCE)
  const [openTabs, setOpenTabs] = useState<EditorTab[]>(() => {
    if (!agentInstanceId || typeof window === 'undefined') return [];
    try {
      const raw = localStorage.getItem(`heimdall:editor:tabs:${agentInstanceId}`);
      if (raw) {
        const parsed = JSON.parse(raw);
        if (Array.isArray(parsed?.openTabs)) return parsed.openTabs;
        if (Array.isArray(parsed)) return parsed;
      }
    } catch {}
    return [];
  });
  const [activeTabPath, setActiveTabPath] = useState<string>(() => {
    if (!agentInstanceId || typeof window === 'undefined') return '';
    try {
      const raw = localStorage.getItem(`heimdall:editor:tabs:${agentInstanceId}`);
      if (raw) {
        const parsed = JSON.parse(raw);
        if (typeof parsed?.activeTabPath === 'string') return parsed.activeTabPath;
        if (Array.isArray(parsed?.openTabs) && parsed.openTabs.length > 0) return parsed.openTabs[0].path;
        if (Array.isArray(parsed) && parsed.length > 0) return parsed[0].path;
      }
    } catch {}
    return '';
  });
  const [isEditMode, setIsEditMode] = useState<boolean>(() => {
    if (!agentInstanceId || typeof window === 'undefined') return false;
    try {
      const raw = localStorage.getItem(`heimdall:editor:tabs:${agentInstanceId}`);
      if (raw) {
        const parsed = JSON.parse(raw);
        if (Array.isArray(parsed?.openTabs)) return parsed.openTabs.length > 0;
        if (Array.isArray(parsed)) return parsed.length > 0;
      }
    } catch {}
    return false;
  });
  const [saveFeedback, setSaveFeedback] = useState<{
    type: 'success' | 'warning' | 'error';
    message: string;
  } | null>(null);
  const [confirmClosePath, setConfirmClosePath] = useState<string | null>(null);
  const [openingInEditor, setOpeningInEditor] = useState<string>('');

  // Track active agentInstanceId for tab state to guard against cross-saving during instance transitions
  const activeInstanceRef = useRef(agentInstanceId);

  // Persist openTabs and activeTabPath per agentInstanceId (REQ-UI-INSTANCE-MONACO-PERSISTENCE)
  useEffect(() => {
    if (!agentInstanceId || typeof window === 'undefined') return;
    if (activeInstanceRef.current !== agentInstanceId) return;
    try {
      const payload = JSON.stringify({ openTabs, activeTabPath });
      localStorage.setItem(`heimdall:editor:tabs:${agentInstanceId}`, payload);
    } catch {}
  }, [agentInstanceId, openTabs, activeTabPath]);

  // Split-pane & explorer collapse/resizing state (REQ-IDE-SPLIT-PANE, REQ-IDE-FILE-TREE, REQ-UI-SIDEBAR-PERSISTENCE, REQ-UI-INSTANCE-TREE-PERSISTENCE)
  const [isExplorerCollapsed, setIsExplorerCollapsed] = useState<boolean>(() => {
    try {
      if (agentInstanceId) {
        const treeRaw = localStorage.getItem(`heimdall:editor:tree:${agentInstanceId}`);
        if (treeRaw) {
          const parsed = JSON.parse(treeRaw);
          if (typeof parsed?.isExplorerCollapsed === 'boolean') {
            return parsed.isExplorerCollapsed;
          }
        }
      }
      return localStorage.getItem('heimdall:editor:explorer_collapsed') === 'true';
    } catch {
      return false;
    }
  });

  const updateExplorerCollapsed = useCallback((nextOrUpdater: boolean | ((prev: boolean) => boolean)) => {
    setIsExplorerCollapsed((prev) => {
      const next = typeof nextOrUpdater === 'function' ? nextOrUpdater(prev) : nextOrUpdater;
      try {
        localStorage.setItem('heimdall:editor:explorer_collapsed', String(next));
        if (agentInstanceId) {
          const treeRaw = localStorage.getItem(`heimdall:editor:tree:${agentInstanceId}`);
          const parsed = treeRaw ? JSON.parse(treeRaw) : {};
          parsed.isExplorerCollapsed = next;
          localStorage.setItem(`heimdall:editor:tree:${agentInstanceId}`, JSON.stringify(parsed));
        }
      } catch {}
      return next;
    });
  }, [agentInstanceId]);
  const [explorerWidth, setExplorerWidth] = useState<number>(280);
  const [isDiffMode, setIsDiffMode] = useState<boolean>(false);
  const [isResizing, setIsResizing] = useState<boolean>(false);
  const resizerRef = useRef<{ startX: number; startWidth: number } | null>(null);

  // REQ-VIM-KEYBINDINGS: Persisted Vim mode toggle ('heimdall:editor:vim_mode')
  const [isVimMode, setIsVimMode] = useState<boolean>(() => {
    try {
      return localStorage.getItem('heimdall:editor:vim_mode') === 'true';
    } catch {
      return false;
    }
  });

  const toggleVimMode = useCallback(() => {
    setIsVimMode((prev) => {
      const next = !prev;
      try {
        localStorage.setItem('heimdall:editor:vim_mode', String(next));
      } catch {}
      return next;
    });
  }, []);

  // REQ-UI-RESPONSIVE-TOP-BAR: 3-dots overflow menu
  const [isOverflowOpen, setIsOverflowOpen] = useState<boolean>(false);
  const overflowRef = useRef<HTMLDivElement | null>(null);

  useEffect(() => {
    if (!isOverflowOpen) return;
    const handleClickOutside = (e: MouseEvent) => {
      if (overflowRef.current && !overflowRef.current.contains(e.target as Node)) {
        setIsOverflowOpen(false);
      }
    };
    document.addEventListener('mousedown', handleClickOutside);
    return () => document.removeEventListener('mousedown', handleClickOutside);
  }, [isOverflowOpen]);

  // REQ-UI-MOBILE-SINGLE-PANE: Viewport < 640px or sidebar width < 480px single-pane layout
  const [containerWidth, setContainerWidth] = useState<number>(800);
  const [viewportWidth, setViewportWidth] = useState<number>(1024);
  const panelRootRef = useRef<HTMLDivElement | null>(null);

  useEffect(() => {
    if (typeof window === 'undefined') return;
    const updateDimensions = () => {
      setViewportWidth(window.innerWidth);
      if (panelRootRef.current) {
        setContainerWidth(panelRootRef.current.clientWidth);
      }
    };
    updateDimensions();
    window.addEventListener('resize', updateDimensions);
    let ro: ResizeObserver | null = null;
    if (typeof ResizeObserver !== 'undefined' && panelRootRef.current) {
      ro = new ResizeObserver((entries) => {
        for (const entry of entries) {
          if (entry.contentRect) {
            setContainerWidth(entry.contentRect.width);
          }
        }
      });
      ro.observe(panelRootRef.current);
    }
    return () => {
      window.removeEventListener('resize', updateDimensions);
      ro?.disconnect();
    };
  }, []);

  const isSinglePane = isMobile || viewportWidth < 640 || containerWidth < 480;
  const isNarrowExplorer = isMobile || isSinglePane || explorerWidth < 320;
  const [activePane, setActivePane] = useState<'files' | 'editor'>('files');

  // REQ-UI-MOBILE-WORD-WRAP: Line wrapping in Monaco editor ('heimdall:editor:word_wrap'), defaults to 'on' in mobile view
  const [isWordWrap, setIsWordWrap] = useState<boolean>(() => {
    try {
      const stored = localStorage.getItem('heimdall:editor:word_wrap');
      if (stored !== null) return stored === 'true';
    } catch {}
    return true;
  });

  useEffect(() => {
    try {
      const stored = localStorage.getItem('heimdall:editor:word_wrap');
      if (stored === null && isSinglePane) {
        setIsWordWrap(true);
      }
    } catch {}
  }, [isSinglePane]);

  const toggleWordWrap = useCallback(() => {
    setIsWordWrap((prev) => {
      const next = !prev;
      try {
        localStorage.setItem('heimdall:editor:word_wrap', String(next));
      } catch {}
      return next;
    });
  }, []);

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

  const [cwd, setCwd] = useState<string>(() => {
    try {
      if (agentInstanceId) {
        const treeRaw = localStorage.getItem(`heimdall:editor:tree:${agentInstanceId}`);
        if (treeRaw) {
          const parsed = JSON.parse(treeRaw);
          if (typeof parsed?.cwd === 'string') {
            return parsed.cwd;
          }
        }
      }
    } catch {}
    return '';
  }); // project-root-relative path ('' = root)

  // Persist cwd and isExplorerCollapsed per agentInstanceId (REQ-UI-INSTANCE-TREE-PERSISTENCE)
  useEffect(() => {
    if (!agentInstanceId || typeof window === 'undefined') return;
    if (activeInstanceRef.current !== agentInstanceId) return;
    try {
      const treeRaw = localStorage.getItem(`heimdall:editor:tree:${agentInstanceId}`);
      const parsed = treeRaw ? JSON.parse(treeRaw) : {};
      parsed.cwd = cwd;
      parsed.isExplorerCollapsed = isExplorerCollapsed;
      localStorage.setItem(`heimdall:editor:tree:${agentInstanceId}`, JSON.stringify(parsed));
    } catch {}
  }, [agentInstanceId, cwd, isExplorerCollapsed]);
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

  // Restore / load directory and editor state for current project & instance (REQ-UI-INSTANCE-MONACO-PERSISTENCE, REQ-UI-INSTANCE-TREE-PERSISTENCE)
  const isProjectMountedRef = useRef(false);
  useEffect(() => {
    if (!isProjectMountedRef.current) {
      isProjectMountedRef.current = true;
      void load(cwd);
      return;
    }
    setPending(null);
    setSaveFeedback(null);
    setConfirmClosePath(null);

    let restoredTabs: EditorTab[] = [];
    let restoredActive = '';
    let restoredCwd = '';
    let restoredCollapsed = false;

    if (agentInstanceId && typeof window !== 'undefined') {
      try {
        const tabsRaw = localStorage.getItem(`heimdall:editor:tabs:${agentInstanceId}`);
        if (tabsRaw) {
          const parsed = JSON.parse(tabsRaw);
          if (Array.isArray(parsed?.openTabs)) {
            restoredTabs = parsed.openTabs;
            restoredActive = typeof parsed.activeTabPath === 'string' ? parsed.activeTabPath : (restoredTabs[0]?.path || '');
          } else if (Array.isArray(parsed)) {
            restoredTabs = parsed;
            restoredActive = restoredTabs[0]?.path || '';
          }
        }
        const treeRaw = localStorage.getItem(`heimdall:editor:tree:${agentInstanceId}`);
        if (treeRaw) {
          const parsed = JSON.parse(treeRaw);
          if (typeof parsed?.cwd === 'string') restoredCwd = parsed.cwd;
          if (typeof parsed?.isExplorerCollapsed === 'boolean') restoredCollapsed = parsed.isExplorerCollapsed;
        } else {
          restoredCollapsed = localStorage.getItem('heimdall:editor:explorer_collapsed') === 'true';
        }
      } catch {}
    }

    setOpenTabs(restoredTabs);
    setActiveTabPath(restoredActive);
    setIsEditMode(restoredTabs.length > 0);
    setCwd(restoredCwd);
    setIsExplorerCollapsed(restoredCollapsed);
    activeInstanceRef.current = agentInstanceId;
    void load(restoredCwd);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [projectId, bridgeId, agentInstanceId]);

  // Global keydown listener for Quick Open (Cmd+P / Ctrl+P) scoped to current project (REQ-UI-GLOBAL-QUICK-OPEN)
  useEffect(() => {
    if (!projectId) return;
    const handleQuickOpenKeyDown = (e: KeyboardEvent) => {
      if ((e.metaKey || e.ctrlKey) && (e.key === 'p' || e.key === 'P') && !e.shiftKey) {
        e.preventDefault();
        e.stopPropagation();
        if (onOpenQuickOpen) {
          onOpenQuickOpen();
        } else {
          setIsQuickOpenOpen((prev) => !prev);
        }
      }
    };
    window.addEventListener('keydown', handleQuickOpenKeyDown, true);
    return () => window.removeEventListener('keydown', handleQuickOpenKeyDown, true);
  }, [projectId, onOpenQuickOpen]);

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

  // VCS computed details
  const isVcsActive = Boolean(vcsStatus?.ok && vcsStatus?.provider);
  const branchName = vcsStatus?.branch || (vcsStatus?.provider ? 'default' : '');
  const isFig = vcsStatus?.provider === 'fig';
  const vcsLogEntries = vcsLogData?.entries || [];
  const currentCl =
    vcsLogEntries.find((e) => e.is_current && e.cl_number)?.cl_number ||
    vcsLogEntries.find((e) => e.cl_number)?.cl_number ||
    '';
  const ahead = vcsStatus?.ahead || 0;
  const behind = vcsStatus?.behind || 0;
  const modifiedFilesCount = vcsFilesData?.files?.length ?? 0;

  const activeFileVcsStatus = vcsFilesData?.files?.find((f) => f.path === activeEditorTab?.path)?.status;

  // Sync default diff target
  useEffect(() => {
    if (vcsTargets.length > 0 && !selectedDiffTarget) {
      const def = vcsTargets.find((t) => t.is_default);
      if (def) setSelectedDiffTarget(def.id);
      else if (vcsTargets[0]) setSelectedDiffTarget(vcsTargets[0].id);
    }
  }, [vcsTargets, selectedDiffTarget]);

  // Click outside for log popover
  useEffect(() => {
    if (!isLogPopoverOpen) return;
    const handleClickOutside = (e: MouseEvent) => {
      if (logPopoverRef.current && !logPopoverRef.current.contains(e.target as Node)) {
        setIsLogPopoverOpen(false);
      }
    };
    document.addEventListener('mousedown', handleClickOutside);
    return () => document.removeEventListener('mousedown', handleClickOutside);
  }, [isLogPopoverOpen]);

  // Fetch base file content for diff mode
  useEffect(() => {
    if (!isDiffMode || !activeEditorTab || !projectId) return;

    if (activeFileVcsStatus === 'added' || activeFileVcsStatus === 'untracked') {
      setDiffBaseContent('');
      return;
    }

    let cancelled = false;
    setIsFetchingBaseContent(true);

    getVcsFileContent({
      projectId,
      bridgeId,
      file: activeEditorTab.path,
      target: selectedDiffTarget,
      revision: selectedDiffTarget,
    })
      .unwrap()
      .then((res) => {
        if (!cancelled) {
          if (res.ok) {
            setDiffBaseContent(res.content ?? '');
          } else {
            setDiffBaseContent(activeEditorTab.initialContent);
          }
        }
      })
      .catch(() => {
        if (!cancelled) {
          setDiffBaseContent(activeEditorTab.initialContent);
        }
      })
      .finally(() => {
        if (!cancelled) setIsFetchingBaseContent(false);
      });

    return () => {
      cancelled = true;
    };
  }, [isDiffMode, activeEditorTab?.path, selectedDiffTarget, projectId, bridgeId, activeFileVcsStatus, getVcsFileContent]);

  const diffOriginalContent = useMemo(() => {
    if (activeFileVcsStatus === 'added' || activeFileVcsStatus === 'untracked') {
      return '';
    }
    return diffBaseContent !== undefined ? diffBaseContent : (activeEditorTab?.initialContent ?? '');
  }, [activeFileVcsStatus, diffBaseContent, activeEditorTab?.initialContent]);

  const diffModifiedContent = useMemo(() => {
    if (activeFileVcsStatus === 'deleted') {
      return '';
    }
    return activeEditorTab?.content ?? '';
  }, [activeFileVcsStatus, activeEditorTab?.content]);

  const handleStageActiveFile = useCallback(async () => {
    if (!activeEditorTab || !projectId) return;
    try {
      await executeVcsAction({
        projectId,
        bridgeId,
        action: 'add',
        file: activeEditorTab.path,
      }).unwrap();
      setSaveFeedback({ type: 'success', message: 'File staged' });
    } catch (e: any) {
      setSaveFeedback({ type: 'error', message: str(e?.message || e) || 'Failed to stage' });
    }
  }, [activeEditorTab, projectId, bridgeId, executeVcsAction]);

  const handleDiscardActiveFile = useCallback(async () => {
    if (!activeEditorTab || !projectId) return;
    try {
      await executeVcsAction({
        projectId,
        bridgeId,
        action: 'revert',
        file: activeEditorTab.path,
      }).unwrap();
      setConfirmRevertOpen(false);
      // Reload file from disk
      const res = await readFile({ projectId, bridgeId, path: activeEditorTab.path }).unwrap();
      if (res.ok) {
        const freshContent = res.content ?? '';
        setOpenTabs((prev) =>
          prev.map((t) =>
            t.path === activeEditorTab.path
              ? { ...t, content: freshContent, initialContent: freshContent, isDirty: false }
              : t
          )
        );
      }
      setSaveFeedback({ type: 'success', message: 'Changes discarded' });
    } catch (e: any) {
      setConfirmRevertOpen(false);
      setSaveFeedback({ type: 'error', message: str(e?.message || e) || 'Failed to discard' });
    }
  }, [activeEditorTab, projectId, bridgeId, executeVcsAction, readFile]);

  const handleCommit = useCallback(async () => {
    if (!projectId) return;
    if (!commitMessage.trim() && !isAmend) {
      setCommitError('Commit message is required');
      return;
    }
    setCommitError('');
    try {
      const res = await commitVcs({
        projectId,
        bridgeId,
        message: commitMessage,
        amend: isAmend,
      }).unwrap();
      if (!res.ok) {
        setCommitError(str(res.error?.message) || 'Commit failed');
        return;
      }
      setIsCommitModalOpen(false);
      setCommitMessage('');
      setIsAmend(false);
      setSaveFeedback({ type: 'success', message: 'Commit successful' });
    } catch (e: any) {
      setCommitError(str(e?.message || e) || 'Commit failed');
    }
  }, [projectId, bridgeId, commitMessage, isAmend, commitVcs]);

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
          if ((res.size || 0) > 5 * 1024 * 1024) {
            return {
              content: '',
              isUnviewable: true,
              unviewableReason: `This file is too large to edit (${formatBytes(res.size || 0)} > 5 MB).`,
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
        if (acc.length > 5 * 1024 * 1024) {
          return {
            content: '',
            isUnviewable: true,
            unviewableReason: 'This file exceeds the 5 MB editor safety threshold.',
          };
        }
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
      const filePath = inputPath;

      const existing = openTabs.find((t) => t.path === filePath);
      if (existing) {
        setActiveTabPath(filePath);
        setIsEditMode(true);
        setActivePane('editor');
        if (isMobile || isSinglePane) setIsExplorerCollapsed(true);
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
        setActivePane('editor');
        if (isMobile || isSinglePane) setIsExplorerCollapsed(true);
      } catch (e: any) {
        setError(str(e?.message) || 'Could not open file in editor');
      } finally {
        setOpeningInEditor('');
      }
    },
    [cwd, openTabs, fetchAllFileContent, isMobile, isSinglePane]
  );

  useEffect(() => {
    if (openFilePath) {
      void openFileInEditor(openFilePath);
      onFileOpened?.();
    }
  }, [openFilePath, openFileInEditor, onFileOpened]);

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
        setActivePane('editor');
        if (isMobile || isSinglePane) setIsExplorerCollapsed(true);
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
        setActivePane('editor');
        if (isMobile || isSinglePane) setIsExplorerCollapsed(true);
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
        setActivePane('editor');
        if (isMobile || isSinglePane) setIsExplorerCollapsed(true);
      } finally {
        setOpeningInEditor('');
      }
    },
    [cwd, openTabs, fetchAllFileContent, isMobile, isSinglePane]
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
    setActivePane('editor');
  }, []);

  const closeTab = useCallback(
    (path: string, force = false) => {
      const tab = openTabs.find((t) => t.path === path);
      if (!tab) return;
      if (!force && tab.isDirty) {
        setConfirmClosePath(path);
        return;
      }
      // Monaco Lifecycle: Dispose models matching this closed tab to prevent memory leaks
      if (monaco) {
        const models = monaco.editor.getModels();
        for (const model of models) {
          const modelPath = model.uri.path;
          if (
            modelPath === path ||
            modelPath.endsWith(`/${path}`) ||
            modelPath.endsWith(path) ||
            model.uri.toString().includes(encodeURIComponent(path))
          ) {
            model.dispose();
          }
        }
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
            setActivePane('files');
          }
        }
        return next;
      });
    },
    [openTabs, activeTabPath, monaco]
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

  const wrapperCls = 'relative flex h-full min-h-0 w-full flex-col overflow-hidden bg-surface';

  return (
    <div ref={panelRootRef} data-debug-id={`${debugPrefix}-panel`} className={wrapperCls}>

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
        <>
          {/* Unified 40px Top Icon Bar */}
          <div
            data-debug-id={`${debugPrefix}-unified-top-bar`}
            className="flex h-[40px] min-h-[40px] w-full shrink-0 items-center justify-between border-b border-subtle bg-surface px-2 gap-1.5 text-[12px] select-none"
          >
            {/* Left section: Strictly 3 primary icons + breadcrumb:
                1) Explorer / Back to Files toggle button
                2) Quick Open (search icon)
                3) Save active file (save icon, highlighted when dirty)
                4) Active file path breadcrumb (with ellipsis on narrow widths)
            */}
            <div className="flex min-w-0 flex-1 items-center gap-1.5 overflow-hidden">
              {/* 1) Explorer / Back to Files toggle button */}
              <button
                data-debug-id={`${debugPrefix}-explorer-toggle-btn`}
                type="button"
                onClick={() => {
                  if (isSinglePane) {
                    setActivePane((p) => (p === 'files' ? 'editor' : 'files'));
                  } else {
                    updateExplorerCollapsed((prev) => !prev);
                  }
                }}
                title={
                  isSinglePane
                    ? activePane === 'files'
                      ? 'Switch to editor'
                      : 'Back to files'
                    : isExplorerCollapsed
                    ? 'Expand file explorer'
                    : 'Collapse file explorer'
                }
                aria-label={
                  isSinglePane
                    ? activePane === 'files'
                      ? 'Switch to editor'
                      : 'Back to files'
                    : isExplorerCollapsed
                    ? 'Expand file explorer'
                    : 'Collapse file explorer'
                }
                className="grid h-8 w-8 shrink-0 place-items-center rounded-lg hover:bg-neutral-soft text-muted hover:text-primary transition-colors"
              >
                <Icon name="panel-left" size={17} />
              </button>

              {/* 2) Quick Open (search icon, Cmd+P / Ctrl+P) */}
              <button
                data-debug-id={`${debugPrefix}-quick-open-btn`}
                type="button"
                onClick={() => (onOpenQuickOpen ? onOpenQuickOpen() : setIsQuickOpenOpen(true))}
                title="Quick open file (Cmd+P / Ctrl+P)"
                aria-label="Quick open file"
                className="grid h-8 w-8 shrink-0 place-items-center rounded-lg hover:bg-neutral-soft text-muted hover:text-primary transition-colors"
              >
                <Icon name="search" size={17} />
              </button>

              {/* 3) Save active file (save icon, highlighted when dirty) */}
              <button
                data-debug-id="editor-save-btn"
                type="button"
                disabled={!activeEditorTab || writeState.isLoading || !activeEditorTab.isDirty || activeEditorTab.isImage || activeEditorTab.isUnviewable}
                onClick={saveActiveFile}
                className={`inline-flex items-center justify-center gap-1.5 h-8 px-2.5 rounded-lg text-[11px] font-semibold transition-colors disabled:opacity-40 shrink-0 ${
                  activeEditorTab?.isDirty
                    ? 'bg-accent text-accent-fg hover:opacity-90 shadow-xs'
                    : 'hover:bg-neutral-soft text-muted hover:text-primary'
                }`}
                title="Save active file (Cmd+S / Ctrl+S)"
                aria-label="Save active file"
              >
                {writeState.isLoading ? (
                  <Icon name="refresh" size={16} className="animate-spin" />
                ) : (
                  <Icon name="save" size={16} />
                )}
                <span className="hidden sm:inline">Save</span>
              </button>

              {/* Stage / Add active file */}
              {activeEditorTab ? (
                <button
                  data-debug-id="editor-stage-file-btn"
                  type="button"
                  disabled={isVcsActionLoading || activeEditorTab.isImage || activeEditorTab.isUnviewable}
                  onClick={handleStageActiveFile}
                  className="inline-flex items-center justify-center gap-1.5 h-8 px-2 rounded-lg text-[11px] font-medium text-muted hover:bg-neutral-soft hover:text-primary transition-colors disabled:opacity-40 shrink-0"
                  title="Stage / Add file (git add / hg add)"
                >
                  <Icon name="plus" size={16} />
                  <span className="hidden sm:inline">Stage</span>
                </button>
              ) : null}

              {/* Revert / Discard active file */}
              {activeEditorTab ? (
                confirmRevertOpen ? (
                  <div className="inline-flex items-center gap-1 bg-surface-raised border border-danger/40 rounded-lg px-2 h-8 shrink-0 shadow-xs">
                    <span className="text-[10px] text-danger font-semibold">Discard?</span>
                    <button
                      data-debug-id="editor-revert-confirm-btn"
                      type="button"
                      disabled={isVcsActionLoading}
                      onClick={handleDiscardActiveFile}
                      className="rounded bg-danger px-1.5 py-0.5 text-[10px] font-bold text-white hover:opacity-90"
                    >
                      Yes
                    </button>
                    <button
                      data-debug-id="editor-revert-cancel-btn"
                      type="button"
                      onClick={() => setConfirmRevertOpen(false)}
                      className="rounded px-1 text-[10px] text-muted hover:text-primary"
                    >
                      Cancel
                    </button>
                  </div>
                ) : (
                  <button
                    data-debug-id="editor-revert-file-btn"
                    type="button"
                    disabled={isVcsActionLoading || activeEditorTab.isImage || activeEditorTab.isUnviewable}
                    onClick={() => setConfirmRevertOpen(true)}
                    className="inline-flex items-center justify-center gap-1.5 h-8 px-2 rounded-lg text-[11px] font-medium text-muted hover:bg-danger/10 hover:text-danger hover:border-danger/30 transition-colors disabled:opacity-40 shrink-0"
                    title="Discard / Revert changes (git restore / hg revert)"
                  >
                    <Icon name="trash" size={16} />
                    <span className="hidden sm:inline">Revert</span>
                  </button>
                )
              ) : null}

              {/* In-Editor Diff Toggle */}
              {activeEditorTab ? (
                <button
                  data-debug-id="editor-toggle-diff-btn-toolbar"
                  type="button"
                  disabled={activeEditorTab.isImage || activeEditorTab.isUnviewable}
                  onClick={() => setIsDiffMode((prev) => !prev)}
                  className={`inline-flex items-center justify-center gap-1.5 h-8 px-2 rounded-lg text-[11px] font-medium transition-colors disabled:opacity-40 shrink-0 ${
                    isDiffMode
                      ? 'border border-accent bg-accent/15 text-accent font-semibold'
                      : 'hover:bg-neutral-soft text-muted hover:text-primary'
                  }`}
                  title={isDiffMode ? 'Switch to Standard Editor' : 'Toggle In-Editor Diff'}
                >
                  <span className="font-mono font-bold text-xs leading-none">±</span>
                  <span className="hidden sm:inline">Diff</span>
                </button>
              ) : null}

              {/* Diff Against Dropdown when in Diff Mode */}
              {isDiffMode && activeEditorTab && vcsTargets.length > 0 ? (
                <div
                  data-debug-id="editor-diff-target-container"
                  className="inline-flex items-center gap-1 rounded-lg bg-surface-raised border border-subtle px-1.5 h-8 text-[11px] shrink-0"
                >
                  <span className="text-muted text-[10.5px]">Diff against:</span>
                  <Select
                    data-debug-id="editor-diff-target-select"
                    value={selectedDiffTarget}
                    onChange={(val) => setSelectedDiffTarget(val)}
                    size="sm"
                  >
                    {vcsTargets.map((t) => (
                      <option key={t.id} value={t.id}>
                        {t.label}{t.is_default ? ' (default)' : ''}
                      </option>
                    ))}
                  </Select>
                  {isFetchingBaseContent ? (
                    <Icon name="refresh" size={10} className="animate-spin text-muted" />
                  ) : null}
                </div>
              ) : null}

              {/* 4) Active file path breadcrumb (with ellipsis on narrow widths) */}
              <div data-debug-id={`${debugPrefix}-breadcrumb`} className="flex min-w-0 flex-1 items-center gap-1 overflow-hidden truncate pl-1 text-[11.5px] text-muted">
                {activeEditorTab ? (
                  <span className="truncate font-mono text-[11.5px] text-primary/80" title={activeEditorTab.path}>
                    {activeEditorTab.path}
                  </span>
                ) : (
                  crumbs.map((c, i) => (
                    <span key={c.path || 'root'} className="flex shrink-0 items-center gap-0.5">
                      {i > 0 ? <Icon name="chevron-right" size={10} className="text-faint" /> : null}
                      <button
                        data-debug-id={`${debugPrefix}-crumb-${i}`}
                        type="button"
                        onClick={() => openDir(c.path)}
                        disabled={i === crumbs.length - 1}
                        className="max-w-[120px] truncate rounded px-1 py-0.5 hover:bg-neutral-soft hover:text-primary disabled:cursor-default disabled:text-primary disabled:hover:bg-transparent"
                      >
                        {c.label}
                      </button>
                    </span>
                  ))
                )}
              </div>
            </div>

            {/* Right section: Toast feedback, Persistent VCS chip, Commit button, Vim badge, and 3-dots overflow menu */}
            <div className="flex shrink-0 items-center gap-1.5 pl-2">
              {/* Save toast feedback */}
              {saveFeedback ? (
                <div
                  data-debug-id={`${debugPrefix}-save-toast`}
                  className={`inline-flex items-center gap-1 px-1.5 py-0.5 rounded text-[11px] font-medium transition-all shrink-0 ${
                    saveFeedback.type === 'success'
                      ? 'bg-success-soft text-success border border-success/30'
                      : saveFeedback.type === 'warning'
                      ? 'bg-warning-soft text-warning border border-warning/30'
                      : 'bg-danger-soft text-danger border border-danger/30'
                  }`}
                >
                  <Icon name={saveFeedback.type === 'success' ? 'check' : 'alert'} size={11} />
                  <span className="truncate max-w-[120px]">{saveFeedback.message}</span>
                </div>
              ) : null}

              {/* Persistent VCS Status Bar Chip */}
              {isVcsActive ? (
                <div className="relative shrink-0" ref={logPopoverRef}>
                  <div
                    data-debug-id={`${debugPrefix}-vcs-status-chip`}
                    onClick={() => setIsLogPopoverOpen((prev) => !prev)}
                    title="Click to view VCS log"
                    className="inline-flex items-center gap-1.5 rounded-md border border-subtle bg-surface-raised px-2 py-0.5 text-[11px] text-muted hover:bg-neutral-soft hover:text-primary cursor-pointer transition-colors select-none"
                  >
                    {/* Branch / Bookmark badge */}
                    <span data-debug-id="vcs-branch-badge" className="inline-flex items-center gap-1 font-medium text-primary">
                      <Icon name="folder" size={11} className="text-accent" />
                      <span className="max-w-[90px] truncate">{branchName}</span>
                    </span>

                    {/* CL number badge (if Fig) */}
                    {isFig && currentCl ? (
                      <span
                        data-debug-id="vcs-cl-badge"
                        className="rounded bg-accent/15 px-1 text-[10px] font-mono font-semibold text-accent"
                        title={`Current CL ${currentCl}`}
                      >
                        CL {currentCl}
                      </span>
                    ) : null}

                    {/* Ahead / behind */}
                    {ahead > 0 ? (
                      <span className="text-success text-[10px] font-semibold" title={`${ahead} commits ahead`}>
                        ↑{ahead}
                      </span>
                    ) : null}
                    {behind > 0 ? (
                      <span className="text-warning text-[10px] font-semibold" title={`${behind} commits behind`}>
                        ↓{behind}
                      </span>
                    ) : null}

                    {/* Modified file count badge */}
                    <span
                      data-debug-id="vcs-modified-badge"
                      className={`rounded-full px-1.5 py-0.2 text-[10px] font-bold ${
                        modifiedFilesCount > 0 ? 'bg-accent/20 text-accent' : 'bg-neutral-soft text-muted'
                      }`}
                      title={`${modifiedFilesCount} modified ${modifiedFilesCount === 1 ? 'file' : 'files'}`}
                    >
                      {modifiedFilesCount}
                    </span>
                  </div>

                  {/* Quick Log Popover */}
                  {isLogPopoverOpen ? (
                    <div
                      data-debug-id="vcs-quick-log-popover"
                      className="absolute right-0 top-full mt-1 w-80 rounded-lg border border-subtle bg-surface-raised p-2 shadow-xl z-50 text-[12px] flex flex-col gap-1.5 max-h-72 overflow-y-auto"
                    >
                      <div className="flex items-center justify-between border-b border-subtle pb-1 font-semibold text-primary text-[12px]">
                        <span>Recent VCS Log ({vcsStatus?.provider})</span>
                        <span className="text-[10px] text-muted">{branchName}</span>
                      </div>
                      {vcsLogEntries.length === 0 ? (
                        <div className="p-3 text-center text-xs text-muted">No log entries found.</div>
                      ) : (
                        vcsLogEntries.map((e, idx) => (
                          <div
                            key={`${e.revision}-${idx}`}
                            className={`flex flex-col gap-0.5 rounded p-1.5 text-[11px] ${
                              e.is_current ? 'bg-accent/10 border border-accent/30' : 'hover:bg-neutral-soft'
                            }`}
                          >
                            <div className="flex items-center justify-between">
                              <span className="font-mono font-bold text-accent">
                                {e.revision ? e.revision.slice(0, 8) : ''}
                                {e.cl_number ? ` (CL ${e.cl_number})` : ''}
                              </span>
                              {e.is_current ? (
                                <span className="rounded bg-accent px-1 py-0.2 text-[9px] font-bold text-white">
                                  Current
                                </span>
                              ) : null}
                              <span className="text-faint text-[10px]">{formatModified(e.timestamp)}</span>
                            </div>
                            <span className="text-primary truncate font-medium">{e.title || 'No message'}</span>
                            {e.author ? <span className="text-faint text-[10px]">by {e.author}</span> : null}
                          </div>
                        ))
                      )}
                    </div>
                  ) : null}
                </div>
              ) : null}

              {/* Commit Button */}
              {isVcsActive ? (
                <button
                  data-debug-id="editor-commit-btn"
                  type="button"
                  onClick={() => {
                    setCommitError('');
                    setIsCommitModalOpen(true);
                  }}
                  className="inline-flex items-center gap-1.5 rounded-lg bg-accent px-2.5 h-8 text-[11px] font-semibold text-accent-fg hover:opacity-90 transition-opacity shrink-0 shadow-xs"
                  title="Commit changes"
                >
                  <Icon name="check" size={16} />
                  <span>Commit{modifiedFilesCount > 0 ? ` (${modifiedFilesCount})` : ''}</span>
                </button>
              ) : null}

              {/* Optional compact VIM badge in top bar */}
              {isVimMode ? (
                <button
                  data-debug-id={`${debugPrefix}-vim-badge`}
                  type="button"
                  onClick={toggleVimMode}
                  title="Vim mode active (click to toggle)"
                  className="rounded-lg bg-accent/20 px-2 h-8 text-[10.5px] font-mono font-bold text-accent hover:bg-accent/30 transition-colors shrink-0"
                >
                  VIM
                </button>
              ) : null}

              {/* Clean 3-dots overflow dropdown menu */}
              <div className="relative shrink-0" ref={overflowRef}>
                <button
                  data-debug-id={`${debugPrefix}-overflow-menu-btn`}
                  type="button"
                  onClick={() => setIsOverflowOpen((prev) => !prev)}
                  aria-haspopup="true"
                  aria-expanded={isOverflowOpen ? 'true' : 'false'}
                  title="More actions"
                  aria-label="More actions"
                  className={`grid h-8 w-8 place-items-center rounded-lg transition-colors ${
                    isOverflowOpen ? 'bg-neutral-soft text-primary' : 'hover:bg-neutral-soft text-muted hover:text-primary'
                  }`}
                >
                  <Icon name="more-vertical" size={17} />
                </button>

                {isOverflowOpen ? (
                  <div
                    data-debug-id={`${debugPrefix}-overflow-dropdown`}
                    className="absolute right-0 top-full mt-1 w-56 rounded-lg border border-subtle bg-surface-raised p-1 shadow-lg z-50 text-[12px] flex flex-col gap-0.5"
                  >
                    {/* 1. New File */}
                    <button
                      data-debug-id={`${debugPrefix}-new-file-btn`}
                      type="button"
                      onClick={() => {
                        setIsOverflowOpen(false);
                        if (isExplorerCollapsed) updateExplorerCollapsed(false);
                        if (isSinglePane) setActivePane('files');
                        beginAction({ kind: 'new-file' });
                      }}
                      className="flex w-full items-center gap-2 rounded px-2 py-1.5 text-left text-muted hover:bg-neutral-soft hover:text-primary transition-colors"
                    >
                      <Icon name="plus" size={14} />
                      <span>New File</span>
                    </button>

                    {/* 2. New Folder */}
                    <button
                      data-debug-id={`${debugPrefix}-new-dir-btn`}
                      type="button"
                      onClick={() => {
                        setIsOverflowOpen(false);
                        if (isExplorerCollapsed) updateExplorerCollapsed(false);
                        if (isSinglePane) setActivePane('files');
                        beginAction({ kind: 'new-dir' });
                      }}
                      className="flex w-full items-center gap-2 rounded px-2 py-1.5 text-left text-muted hover:bg-neutral-soft hover:text-primary transition-colors"
                    >
                      <Icon name="folder" size={14} />
                      <span>New Folder</span>
                    </button>

                    {/* 3. Toggle Hidden Files */}
                    <button
                      data-debug-id={`${debugPrefix}-hidden-toggle`}
                      type="button"
                      onClick={() => {
                        setIsOverflowOpen(false);
                        setIncludeHidden((v) => !v);
                      }}
                      aria-pressed={includeHidden ? 'true' : 'false'}
                      className="flex w-full items-center gap-2 rounded px-2 py-1.5 text-left text-muted hover:bg-neutral-soft hover:text-primary transition-colors"
                    >
                      <Icon name={includeHidden ? 'eye' : 'eye-off'} size={14} />
                      <span>{includeHidden ? 'Hide Hidden Files' : 'Show Hidden Files'}</span>
                    </button>

                    {/* 4. Refresh Explorer */}
                    <button
                      data-debug-id={`${debugPrefix}-refresh-btn`}
                      type="button"
                      onClick={() => {
                        setIsOverflowOpen(false);
                        refresh();
                      }}
                      className="flex w-full items-center gap-2 rounded px-2 py-1.5 text-left text-muted hover:bg-neutral-soft hover:text-primary transition-colors"
                    >
                      <Icon name="refresh" size={14} />
                      <span>Refresh Explorer</span>
                    </button>

                    <div className="my-1 border-t border-subtle/60" />

                    {/* 5. Toggle In-Editor Diff */}
                    <button
                      data-debug-id="editor-toggle-diff-btn"
                      type="button"
                      disabled={!activeEditorTab || activeEditorTab.isImage || activeEditorTab.isUnviewable}
                      onClick={() => {
                        setIsOverflowOpen(false);
                        setIsDiffMode((prev) => !prev);
                      }}
                      aria-pressed={isDiffMode ? 'true' : 'false'}
                      className="flex w-full items-center gap-2 rounded px-2 py-1.5 text-left text-muted hover:bg-neutral-soft hover:text-primary transition-colors disabled:opacity-40"
                    >
                      <span className="font-mono font-bold text-xs leading-none">±</span>
                      <span>{isDiffMode ? 'Standard Editor' : 'Toggle In-Editor Diff'}</span>
                      {isDiffMode ? <Icon name="check" size={13} className="ml-auto text-accent" /> : null}
                    </button>

                    {/* 6. Toggle Vim Mode */}
                    <button
                      data-debug-id={`${debugPrefix}-toggle-vim-btn`}
                      type="button"
                      onClick={() => {
                        setIsOverflowOpen(false);
                        toggleVimMode();
                      }}
                      aria-pressed={isVimMode ? 'true' : 'false'}
                      className="flex w-full items-center gap-2 rounded px-2 py-1.5 text-left text-muted hover:bg-neutral-soft hover:text-primary transition-colors"
                    >
                      <span className="font-mono font-bold text-xs leading-none">V</span>
                      <span>Toggle Vim Mode</span>
                      {isVimMode ? <Icon name="check" size={13} className="ml-auto text-accent" /> : null}
                    </button>

                    {/* Toggle Word Wrap (REQ-UI-MOBILE-WORD-WRAP) */}
                    <button
                      data-debug-id={`${debugPrefix}-toggle-word-wrap-btn`}
                      type="button"
                      onClick={() => {
                        setIsOverflowOpen(false);
                        toggleWordWrap();
                      }}
                      aria-pressed={isWordWrap ? 'true' : 'false'}
                      className="flex w-full items-center gap-2 rounded px-2 py-1.5 text-left text-muted hover:bg-neutral-soft hover:text-primary transition-colors"
                    >
                      <Icon name="pencil" size={14} />
                      <span>Toggle Word Wrap</span>
                      {isWordWrap ? <Icon name="check" size={13} className="ml-auto text-accent" /> : null}
                    </button>

                    {/* 7. Save All Files */}
                    <button
                      data-debug-id="editor-save-all-btn"
                      type="button"
                      disabled={batchWriteState.isLoading || openTabs.filter((t) => t.isDirty).length === 0}
                      onClick={() => {
                        setIsOverflowOpen(false);
                        saveAllFiles();
                      }}
                      className="flex w-full items-center gap-2 rounded px-2 py-1.5 text-left text-muted hover:bg-neutral-soft hover:text-primary transition-colors disabled:opacity-40"
                    >
                      <Icon name="save" size={14} />
                      <span>Save All Files {openTabs.filter((t) => t.isDirty).length > 0 ? `(${openTabs.filter((t) => t.isDirty).length})` : ''}</span>
                    </button>

                    <div className="my-1 border-t border-subtle/60" />

                    {/* 8. Comment on Current File / Folder */}
                    {activeEditorTab ? (
                      <button
                        data-debug-id={`${debugPrefix}-file-comment-btn`}
                        type="button"
                        onClick={() => {
                          setIsOverflowOpen(false);
                          setPathCommentDraft('');
                          setPathCommentFor({
                            path: activeEditorTab.path,
                            label: `file: ${baseName(activeEditorTab.path)}`,
                          });
                        }}
                        className="flex w-full items-center gap-2 rounded px-2 py-1.5 text-left text-muted hover:bg-neutral-soft hover:text-primary transition-colors"
                      >
                        <Icon name="chat" size={14} />
                        <span>Comment on Active File</span>
                      </button>
                    ) : (
                      <button
                        data-debug-id={`${debugPrefix}-folder-comment-btn`}
                        type="button"
                        onClick={() => {
                          setIsOverflowOpen(false);
                          setPathCommentDraft('');
                          setPathCommentFor({
                            path: cwd || '/',
                            label: `folder: ${cwd || 'project root'}`,
                          });
                        }}
                        className="flex w-full items-center gap-2 rounded px-2 py-1.5 text-left text-muted hover:bg-neutral-soft hover:text-primary transition-colors"
                      >
                        <Icon name="chat" size={14} />
                        <span>Comment on Current Folder</span>
                      </button>
                    )}
                  </div>
                ) : null}
              </div>
            </div>
          </div>

          {/* Split Container */}
          <div data-debug-id={`${debugPrefix}-split-container`} className="flex min-h-0 flex-1 w-full flex-row overflow-hidden">
            {/* Left Column: Directory Explorer */}
            <div
              data-debug-id={`${debugPrefix}-explorer-pane`}
              style={!isSinglePane && !isExplorerCollapsed ? { width: explorerWidth } : undefined}
              className={`${
                isSinglePane
                  ? activePane === 'files'
                    ? 'w-full flex-1'
                    : 'hidden'
                  : isExplorerCollapsed
                  ? 'hidden'
                  : 'flex'
              } h-full max-h-full min-h-0 flex-col overflow-hidden border-r border-subtle bg-surface shrink-0`}
            >
              {/* Inline create/rename input */}
              {pending ? (
                <div data-debug-id={`${debugPrefix}-name-editor`} className="flex shrink-0 items-center gap-1.5 border-b border-subtle bg-surface-raised px-3 py-2">
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
              <div data-debug-id={`${debugPrefix}-list`} className="min-h-0 flex-1 overflow-y-auto overscroll-contain p-1" style={{ touchAction: 'pan-y' }}>
                {loading ? (
                  <div data-debug-id={`${debugPrefix}-loading`} className="p-4 text-center text-xs text-muted">Loading…</div>
                ) : error && sortedEntries.length === 0 ? (
                  <div data-debug-id={`${debugPrefix}-load-error`} className="p-6 text-center text-xs text-muted">Couldn’t load files — see the message below.</div>
                ) : sortedEntries.length === 0 && cwd === '' ? (
                  <div data-debug-id={`${debugPrefix}-empty`} className="p-6 text-center text-xs text-faint">This folder is empty.</div>
                ) : (
                  <ul className="space-y-0.5">
                    {/* Compact .. (parent folder) row when in subfolder */}
                    {cwd !== '' ? (
                      <li key="..-parent-folder" className="group flex items-center h-7 py-0.5 px-2 text-[12px] hover:bg-neutral-soft rounded cursor-pointer select-none">
                        <button
                          data-debug-id={`${debugPrefix}-parent-dir`}
                          type="button"
                          onClick={() => openDir(parentPath(cwd))}
                          className="flex min-w-0 flex-1 items-center gap-2 text-left text-muted hover:text-primary"
                          title="Navigate to parent folder"
                        >
                          <Icon name="folder" size={14} className="shrink-0 text-muted" />
                          <span className="min-w-0 flex-1 truncate font-medium">.. (parent folder)</span>
                        </button>
                      </li>
                    ) : null}

                    {sortedEntries.map((e) => {
                      const isOpening = !e.is_dir && openingInEditor === joinPath(cwd, e.name);
                      const isActiveFile = !e.is_dir && activeTabPath === joinPath(cwd, e.name);
                      return (
                        <li
                          key={`${e.is_dir ? 'd' : 'f'}:${e.name}`}
                          className={`group flex items-center h-7 py-0.5 px-2 text-[12px] rounded select-none ${
                            isActiveFile ? 'bg-accent/10 text-accent font-medium' : 'hover:bg-neutral-soft text-primary'
                          }`}
                        >
                          <button
                            data-debug-id={`${debugPrefix}-entry-${e.name}`}
                            type="button"
                            disabled={isOpening}
                            onClick={() => (e.is_dir ? openDir(joinPath(cwd, e.name)) : void openFileInEditor(joinPath(cwd, e.name)))}
                            className="flex min-w-0 flex-1 items-center gap-2 text-left"
                          >
                            {isOpening ? (
                              <Icon name="refresh" size={14} className="shrink-0 animate-spin text-accent" title="Loading file…" />
                            ) : (
                              <Icon name={e.is_dir ? 'folder' : 'file'} size={14} className={`shrink-0 ${e.is_dir ? 'text-accent' : isActiveFile ? 'text-accent' : 'text-muted'}`} />
                            )}
                            <span className={`min-w-0 flex-1 truncate text-[12px] ${isActiveFile ? 'font-medium text-accent' : e.hidden ? 'text-faint' : 'text-primary'}`}>{e.name}</span>
                            {e.has_git ? <span className="shrink-0 rounded bg-success-soft px-1.5 py-0.2 text-[9px] font-bold text-success">git</span> : null}
                            {!isNarrowExplorer && !e.is_dir ? <span className="shrink-0 text-[10px] tabular-nums text-faint">{formatBytes(e.size)}</span> : null}
                            {!isNarrowExplorer && e.modified_at ? <span className="hidden shrink-0 text-[10px] text-faint sm:inline">{formatModified(e.modified_at)}</span> : null}
                            {e.is_dir ? <Icon name="chevron-right" size={12} className="shrink-0 text-faint" /> : null}
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
                                className="grid h-6 w-6 place-items-center rounded text-muted hover:bg-neutral-soft hover:text-primary"
                              >
                                <Icon name="pencil" size={12} />
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
                              className="grid h-6 w-6 place-items-center rounded text-muted hover:bg-danger-soft hover:text-danger disabled:opacity-40"
                            >
                              <Icon name="trash" size={12} />
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
            {!isExplorerCollapsed && !isSinglePane ? (
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
              className={`${
                isSinglePane
                  ? activePane === 'editor'
                    ? 'w-full flex-1 flex'
                    : 'hidden'
                  : 'flex flex-1'
              } min-h-0 flex-col overflow-hidden bg-surface`}
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
                  onBackToFiles={() => {
                    if (isSinglePane) setActivePane('files');
                    else updateExplorerCollapsed((prev) => !prev);
                  }}
                  onToggleExplorer={() => {
                    if (isSinglePane) setActivePane('files');
                    else updateExplorerCollapsed((prev) => !prev);
                  }}
                  isExplorerCollapsed={isExplorerCollapsed}
                  onNewFile={handleEditorNewFile}
                  cwd={cwd}
                  debugPrefix={debugPrefix}
                  themeAppearance={theme?.appearance}
                  isVimMode={isVimMode}
                  isWordWrap={isWordWrap}
                  isMobile={isMobile}
                  isSinglePane={isSinglePane}
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
                  isDiffMode={isDiffMode}
                  onToggleDiff={() => setIsDiffMode((prev) => !prev)}
                  diffOriginalContent={diffOriginalContent}
                  diffModifiedContent={diffModifiedContent}
                  vcsTargets={vcsTargets}
                  selectedDiffTarget={selectedDiffTarget}
                  onSelectDiffTarget={setSelectedDiffTarget}
                  isFetchingBaseContent={isFetchingBaseContent}
                  activeFileVcsStatus={activeFileVcsStatus}
                  branchName={branchName}
                  clNumber={currentCl}
                  modifiedFilesCount={modifiedFilesCount}
                  isFig={isFig}
                />
              ) : (
                <div
                  data-debug-id={`${debugPrefix}-editor-empty-state`}
                  className="flex min-h-0 flex-1 flex-col bg-surface"
                >
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
        </>
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

      {/* Commit Modal */}
      {isCommitModalOpen ? (
        <div
          data-debug-id="editor-commit-modal-backdrop"
          className="fixed inset-0 z-50 flex items-center justify-center bg-black/50 p-4"
          onClick={() => setIsCommitModalOpen(false)}
        >
          <div
            data-debug-id="editor-commit-modal"
            className="w-full max-w-lg rounded-xl border border-subtle bg-surface p-5 shadow-2xl flex flex-col gap-4 text-primary"
            onClick={(e) => e.stopPropagation()}
          >
            <div className="flex items-center justify-between border-b border-subtle pb-3">
              <h3 className="text-base font-semibold">
                {isAmend ? 'Amend Commit / CL' : 'Commit Changes'}
              </h3>
              <button
                type="button"
                onClick={() => setIsCommitModalOpen(false)}
                className="grid h-6 w-6 place-items-center rounded hover:bg-neutral-soft text-muted hover:text-primary"
              >
                <Icon name="close" size={14} />
              </button>
            </div>

            {commitError ? (
              <div data-debug-id="editor-commit-error" className="rounded border border-danger/30 bg-danger-soft p-2.5 text-caption text-danger">
                {commitError}
              </div>
            ) : null}

            <div className="flex flex-col gap-1.5">
              <label className="text-caption font-medium text-muted">Commit Message</label>
              <textarea
                data-debug-id="editor-commit-message-input"
                autoFocus
                rows={4}
                value={commitMessage}
                onChange={(e) => setCommitMessage(e.target.value)}
                placeholder="Write a clear, concise commit message..."
                className="w-full rounded-lg border border-subtle bg-surface-raised p-2.5 text-body text-primary placeholder:text-muted focus:border-accent focus:outline-none font-mono text-[12.5px]"
              />
            </div>

            {/* Amend checkbox */}
            <label data-debug-id="editor-commit-amend-label" className="flex items-center gap-2 text-caption text-primary cursor-pointer select-none">
              <input
                data-debug-id="editor-commit-amend-checkbox"
                type="checkbox"
                checked={isAmend}
                onChange={(e) => setIsAmend(e.target.checked)}
                className="rounded border-subtle text-accent focus:ring-accent"
              />
              <span>Amend previous commit / CL ({isFig ? 'hg amend' : 'git commit --amend'})</span>
            </label>

            {/* Changed files list */}
            <div className="flex flex-col gap-1.5">
              <span className="text-caption font-medium text-muted">
                Files to commit ({vcsFilesData?.files?.length ?? 0}):
              </span>
              <div className="max-h-36 overflow-y-auto rounded-lg border border-subtle bg-surface-raised p-2 flex flex-col gap-1 text-[12px]">
                {vcsFilesData?.files && vcsFilesData.files.length > 0 ? (
                  vcsFilesData.files.map((f) => {
                    const badge = statusBadge(f.status);
                    return (
                      <div key={f.path} className="flex items-center gap-2 py-0.5">
                        <span className={`grid h-4 w-4 shrink-0 place-items-center rounded text-[9px] font-bold ${badge.cls}`}>
                          {badge.label}
                        </span>
                        <span className="truncate flex-1 font-mono text-[11.5px]">{f.path}</span>
                        <span className="flex shrink-0 gap-1 text-[10.5px] font-mono text-muted">
                          {f.additions > 0 ? <span className="text-success">+{f.additions}</span> : null}
                          {f.deletions > 0 ? <span className="text-danger">-{f.deletions}</span> : null}
                        </span>
                      </div>
                    );
                  })
                ) : (
                  <span className="text-muted p-2 text-center text-caption">No changed files detected.</span>
                )}
              </div>
            </div>

            {/* Modal actions */}
            <div className="flex items-center justify-end gap-2 pt-2 border-t border-subtle">
              <button
                data-debug-id="editor-commit-cancel-btn"
                type="button"
                onClick={() => setIsCommitModalOpen(false)}
                className="rounded-lg border border-subtle px-3 py-1.5 text-caption font-medium text-muted hover:bg-neutral-soft hover:text-primary transition-colors"
              >
                Cancel
              </button>
              <button
                data-debug-id="editor-commit-submit-btn"
                type="button"
                disabled={isCommitLoading || (!commitMessage.trim() && !isAmend)}
                onClick={handleCommit}
                className="inline-flex items-center gap-1.5 rounded-lg bg-accent px-4 py-1.5 text-caption font-semibold text-accent-fg hover:opacity-90 transition-opacity disabled:opacity-40"
              >
                {isCommitLoading ? <Icon name="refresh" size={13} className="animate-spin" /> : null}
                <span>{isAmend ? 'Amend Commit' : 'Commit'}</span>
              </button>
            </div>
          </div>
        </div>
      ) : null}

      {/* Quick Open Modal (Cmd+P / Ctrl+P) (REQ-UI-GLOBAL-QUICK-OPEN) */}
      <ProjectQuickOpenModal
        projectId={projectId}
        bridgeId={bridgeId}
        isOpen={isQuickOpenOpen}
        onClose={() => setIsQuickOpenOpen(false)}
        onSelectFile={(file) => void openFileInEditor(file)}
      />
    </div>
  );
}

export function ProjectQuickOpenModal({
  projectId,
  bridgeId = '',
  isOpen,
  onClose,
  onSelectFile,
}: {
  projectId: string;
  bridgeId?: string;
  isOpen: boolean;
  onClose: () => void;
  onSelectFile: (filePath: string) => void;
}) {
  const panelRef = useRef<HTMLDivElement | null>(null);
  const inputRef = useRef<HTMLInputElement | null>(null);
  const listRef = useRef<HTMLDivElement | null>(null);
  const [fetchQuickOpen, quickOpenState] = useLazyQuickOpenProjectFilesQuery();
  const [quickOpenQuery, setQuickOpenQuery] = useState('');
  const [quickOpenSelectedIndex, setQuickOpenSelectedIndex] = useState(0);
  const [quickOpenAllFiles, setQuickOpenAllFiles] = useState<string[]>([]);

  useDialogA11y(isOpen, onClose, panelRef);

  useEffect(() => {
    if (isOpen && projectId) {
      setQuickOpenQuery('');
      setQuickOpenSelectedIndex(0);
      window.setTimeout(() => inputRef.current?.focus(), 0);
      void fetchQuickOpen({ projectId, bridgeId, query: '', limit: 1000 })
        .unwrap()
        .then((res) => {
          if (res?.ok && Array.isArray(res.files)) {
            setQuickOpenAllFiles(res.files);
          }
        })
        .catch(() => {});
    }
  }, [isOpen, projectId, bridgeId, fetchQuickOpen]);

  useEffect(() => {
    if (!isOpen || !projectId) return;
    const q = quickOpenQuery.trim();
    if (!q) return;
    const timer = setTimeout(() => {
      void fetchQuickOpen({ projectId, bridgeId, query: q, limit: 500 })
        .unwrap()
        .then((res) => {
          if (res?.ok && Array.isArray(res.files)) {
            setQuickOpenAllFiles((prev) => {
              const set = new Set([...prev, ...res.files]);
              return Array.from(set);
            });
          }
        })
        .catch(() => {});
    }, 150);
    return () => clearTimeout(timer);
  }, [quickOpenQuery, isOpen, projectId, bridgeId, fetchQuickOpen]);

  useEffect(() => {
    if (!listRef.current) return;
    const el = listRef.current.querySelector<HTMLElement>(`[data-quick-open-index="${quickOpenSelectedIndex}"]`);
    el?.scrollIntoView({ block: 'nearest' });
  }, [quickOpenSelectedIndex]);

  const filteredQuickOpenFiles = useMemo(() => {
    if (!quickOpenQuery.trim()) return quickOpenAllFiles.slice(0, 50);
    const q = quickOpenQuery.trim();
    return quickOpenAllFiles
      .filter((file) => subsequenceFuzzyMatch(q, file))
      .sort((a, b) => fuzzyMatchScore(q, b) - fuzzyMatchScore(q, a))
      .slice(0, 50);
  }, [quickOpenAllFiles, quickOpenQuery]);

  if (!isOpen) return null;

  return (
    <div
      data-debug-id="project-quick-open-modal"
      role="presentation"
      className="fixed inset-0 z-modal flex items-start justify-center bg-surface-overlay/80 px-2 pt-[max(env(safe-area-inset-top),0.5rem)] backdrop-blur-sm sm:px-4 sm:pt-[12vh]"
      onClick={onClose}
    >
      <div
        ref={panelRef}
        tabIndex={-1}
        role="dialog"
        aria-modal="true"
        aria-label="Quick open files"
        className="flex max-h-[calc(100dvh-1rem)] w-full max-w-2xl flex-col overflow-hidden rounded-2xl border border-subtle bg-surface-overlay shadow-overlay outline-none sm:max-h-[70vh]"
        onClick={(e) => e.stopPropagation()}
      >
        <div className="flex items-center gap-3 border-b border-subtle px-4 py-3">
          <span aria-hidden="true" className="text-muted"><Icon name="search" size={16} /></span>
          <input
            ref={inputRef}
            data-debug-id="project-quick-open-input"
            type="text"
            value={quickOpenQuery}
            onChange={(e) => {
              setQuickOpenQuery(e.target.value);
              setQuickOpenSelectedIndex(0);
            }}
            onKeyDown={(e) => {
              if (e.key === 'ArrowDown') {
                e.preventDefault();
                setQuickOpenSelectedIndex((prev) =>
                  filteredQuickOpenFiles.length > 0 ? (prev + 1) % filteredQuickOpenFiles.length : 0
                );
              } else if (e.key === 'ArrowUp') {
                e.preventDefault();
                setQuickOpenSelectedIndex((prev) =>
                  filteredQuickOpenFiles.length > 0
                    ? (prev - 1 + filteredQuickOpenFiles.length) % filteredQuickOpenFiles.length
                    : 0
                );
              } else if (e.key === 'Enter') {
                e.preventDefault();
                if (filteredQuickOpenFiles.length > 0) {
                  const selected = filteredQuickOpenFiles[quickOpenSelectedIndex] || filteredQuickOpenFiles[0];
                  if (selected) {
                    onClose();
                    onSelectFile(selected);
                  }
                }
              }
            }}
            placeholder="Search files by name or path (Cmd+P / Ctrl+P)…"
            className="min-w-0 flex-1 bg-transparent text-[15px] text-primary outline-none placeholder:text-faint"
            autoComplete="off"
            spellCheck={false}
          />
          <kbd className="rounded border border-subtle bg-neutral-soft px-1.5 py-0.5 text-[10px] text-muted">esc</kbd>
        </div>

        <div
          ref={listRef}
          data-debug-id="project-quick-open-results"
          className="flex-1 overflow-y-auto p-2"
        >
          {filteredQuickOpenFiles.length === 0 ? (
            <div className="px-3 py-8 text-center text-sm text-muted">
              {quickOpenState.isLoading ? 'Searching project files…' : 'No matching files found.'}
            </div>
          ) : (
            filteredQuickOpenFiles.map((file, idx) => {
              const isSelected = idx === quickOpenSelectedIndex;
              const name = baseName(file);
              const dir = parentPath(file);
              return (
                <div
                  key={file}
                  data-debug-id={`quick-open-item-${file}`}
                  data-selected={isSelected ? 'true' : 'false'}
                  data-quick-open-index={idx}
                  onClick={() => {
                    onClose();
                    onSelectFile(file);
                  }}
                  onMouseEnter={() => setQuickOpenSelectedIndex(idx)}
                  className={`flex w-full cursor-pointer items-center gap-3 rounded-lg px-3 py-2 text-left text-sm ${
                    isSelected ? 'bg-neutral-soft text-primary font-semibold' : 'text-muted hover:bg-neutral-soft hover:text-primary'
                  }`}
                >
                  <span aria-hidden="true" className="grid w-5 place-items-center text-muted opacity-80">
                    <Icon name="file" size={16} className={isSelected ? 'text-primary' : 'text-muted'} />
                  </span>
                  <span className="flex min-w-0 flex-1 items-center gap-2">
                    <span className="truncate text-primary">{name}</span>
                    {dir ? <span className="truncate text-caption text-faint ml-auto font-mono text-[11px]">{dir}</span> : null}
                  </span>
                </div>
              );
            })
          )}
        </div>

        <div className="flex items-center justify-between border-t border-subtle bg-surface-raised px-4 py-2 text-[11px] text-muted">
          <span>{filteredQuickOpenFiles.length} file{filteredQuickOpenFiles.length === 1 ? '' : 's'}</span>
          <div className="flex items-center gap-2">
            <span><kbd className="rounded border border-subtle bg-neutral-soft px-1.5 py-0.5">↑↓</kbd> navigate</span>
            <span><kbd className="rounded border border-subtle bg-neutral-soft px-1.5 py-0.5">↵</kbd> select</span>
          </div>
        </div>
      </div>
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
  isSaving: _isSaving,
  isBatchSaving: _isBatchSaving,
  saveFeedback: _saveFeedback,
  onBackToFiles: _onBackToFiles,
  onToggleExplorer: _onToggleExplorer,
  isExplorerCollapsed: _isExplorerCollapsed = false,
  onNewFile,
  debugPrefix,
  themeAppearance,
  cwd,
  comments = [],
  onAddComment,
  onEditComment,
  onDeleteComment,
  onCommentFile: _onCommentFile,
  isDiffMode = false,
  onToggleDiff: _onToggleDiff,
  diffOriginalContent,
  diffModifiedContent,
  vcsTargets = [],
  selectedDiffTarget = '',
  onSelectDiffTarget,
  isFetchingBaseContent = false,
  activeFileVcsStatus,
  branchName = '',
  clNumber = '',
  modifiedFilesCount = 0,
  isFig = false,
  isVimMode = false,
  isWordWrap = true,
  isMobile = false,
  isSinglePane = false,
}: {
  tabs: EditorTab[];
  activeTab: EditorTab;
  onSelectTab: (path: string) => void;
  onCloseTab: (path: string) => void;
  onContentChange: (path: string, content: string) => void;
  onSaveActive: () => void;
  onSaveAll: () => void;
  isSaving?: boolean;
  isBatchSaving?: boolean;
  saveFeedback?: { type: 'success' | 'warning' | 'error'; message: string } | null;
  onBackToFiles?: () => void;
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
  isDiffMode?: boolean;
  onToggleDiff?: () => void;
  diffOriginalContent?: string;
  diffModifiedContent?: string;
  vcsTargets?: VcsDiffTarget[];
  selectedDiffTarget?: string;
  onSelectDiffTarget?: (target: string) => void;
  isFetchingBaseContent?: boolean;
  activeFileVcsStatus?: VcsFileStatus;
  branchName?: string;
  clNumber?: string;
  modifiedFilesCount?: number;
  isFig?: boolean;
  isVimMode?: boolean;
  isWordWrap?: boolean;
  isMobile?: boolean;
  isSinglePane?: boolean;
}) {
  const monaco = useMonaco();
  const monacoTheme = themeAppearance === 'light' ? 'light' : 'vs-dark';
  const language = useMemo(() => getLanguageForMonaco(activeTab.path), [activeTab.path]);

  const [isPromptingNewFile, setIsPromptingNewFile] = useState(false);
  const [newFileName, setNewFileName] = useState('');
  const diffListenerRef = useRef<{ dispose: () => void } | null>(null);

  const editorRef = useRef<any>(null);
  const [editorInstance, setEditorInstance] = useState<any>(null);
  const statusNodeRef = useRef<HTMLDivElement | null>(null);
  const vimModeRef = useRef<any>(null);

  useEffect(() => {
    return () => {
      diffListenerRef.current?.dispose();
    };
  }, []);

  const onSaveActiveRef = useRef(onSaveActive);
  const onSaveAllRef = useRef(onSaveAll);
  useEffect(() => {
    onSaveActiveRef.current = onSaveActive;
  }, [onSaveActive]);
  useEffect(() => {
    onSaveAllRef.current = onSaveAll;
  }, [onSaveAll]);

  const activeTabPathRef = useRef(activeTab.path);
  useEffect(() => {
    activeTabPathRef.current = activeTab.path;
  }, [activeTab.path]);

  const onCloseTabRef = useRef(onCloseTab);
  useEffect(() => {
    onCloseTabRef.current = onCloseTab;
  }, [onCloseTab]);

  // REQ-VIM-KEYBINDINGS: Wire custom Ex commands via Vim.defineEx:
  // ':w' -> onSaveActiveRef.current()
  // ':q' -> close active tab onCloseTab(activeTabPath)
  // ':wq' -> onSaveActiveRef.current() and close active tab
  useEffect(() => {
    const Vim = (VimMode as any)?.Vim;
    if (!Vim?.defineEx) return;
    try {
      Vim.defineEx('write', 'w', () => {
        onSaveActiveRef.current();
      });
    } catch {}
    try {
      Vim.defineEx('quit', 'q', () => {
        onCloseTabRef.current(activeTabPathRef.current);
      });
    } catch {}
    try {
      Vim.defineEx('wq', 'wq', () => {
        onSaveActiveRef.current();
        onCloseTabRef.current(activeTabPathRef.current);
      });
    } catch {}
  }, []);

  // REQ-VIM-INSERT-MODE-FIX: Single unified lifecycle hook for Monaco Vim mode.
  // Handles clean initialization and disposal on mode toggle, tab switch, and editor mount/unmount.
  useEffect(() => {
    if (!isVimMode || !editorInstance || !statusNodeRef.current) {
      if (vimModeRef.current) {
        vimModeRef.current.dispose();
        vimModeRef.current = null;
      }
      return;
    }

    if (vimModeRef.current) {
      vimModeRef.current.dispose();
      vimModeRef.current = null;
    }

    try {
      const vim = initVimMode(editorInstance, statusNodeRef.current);
      const origGetOption = vim.getOption;
      vim.getOption = function(key: string) {
        if (key === "readOnly") {
          const monacoEditorOption = (monaco as any)?.editor?.EditorOption?.readOnly;
          if (typeof monacoEditorOption === "number") {
            return Boolean(editorInstance.getOption(monacoEditorOption));
          }
          return Boolean(editorInstance.getRawOptions?.()?.readOnly);
        }
        return origGetOption.call(this, key);
      };
      vimModeRef.current = vim;
    } catch (e) {
      console.error('Failed to initialize monaco-vim:', e);
    }

    return () => {
      if (vimModeRef.current) {
        vimModeRef.current.dispose();
        vimModeRef.current = null;
      }
    };
  }, [isVimMode, activeTab.path, editorInstance]);

  const handleEditorMount: OnMount = (editor, monaco) => {
    editorRef.current = editor;
    setEditorInstance(editor);
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

  const handleDiffMount: DiffOnMount = (diffEditor, monaco) => {
    handleEditorMount(diffEditor.getModifiedEditor(), monaco);
    diffListenerRef.current?.dispose();
    const modifiedModel = diffEditor.getModifiedEditor().getModel();
    diffListenerRef.current = modifiedModel?.onDidChangeContent(() => {
      const val = diffEditor.getModifiedEditor().getValue();
      onContentChange(activeTab.path, val);
    }) ?? null;
  };

  const isNarrow = Boolean(isMobile || isSinglePane);

  const options: EditorProps['options'] = {
    minimap: { enabled: !isMobile && !isSinglePane },
    wordWrap: isWordWrap ? 'on' : 'off',
    lineNumbers: 'on',
    lineNumbersMinChars: isNarrow ? 2 : 3,
    lineDecorationsWidth: isNarrow ? 4 : 10,
    glyphMargin: !isNarrow,
    folding: !isNarrow,
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

      {/* Monaco Editor Canvas or Image / Unviewable Preview or DiffEditor */}
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
            className="flex h-full flex-col items-center justify-center p-6 text-center text-xs text-muted gap-2"
          >
            <div className="inline-flex items-center gap-1.5 rounded-full border border-warning/40 bg-warning/10 px-3 py-1 text-warning font-medium">
              <Icon name="alert" size={14} />
              <span>{activeTab.unviewableReason || 'This file cannot be previewed or edited.'}</span>
            </div>
            <p className="text-faint max-w-sm">Files larger than 5MB or with binary encodings are restricted from Monaco tokenization for safety and performance.</p>
          </div>
        ) : isDiffMode ? (
          <div className="relative flex min-h-0 flex-1 flex-col">
            {/* Diff mode sub-toolbar */}
            <div
              data-debug-id="editor-diff-toolbar"
              className="flex items-center justify-between border-b border-subtle bg-surface-raised px-2.5 py-1 text-[11px] text-muted shrink-0"
            >
              <div className="flex items-center gap-2">
                <span className="font-semibold text-accent flex items-center gap-1">
                  <span className="font-mono">±</span> Diff Mode
                </span>
                {activeFileVcsStatus ? (
                  <span className="rounded bg-neutral-soft px-1.5 py-0.5 text-[10px] font-bold capitalize text-primary">
                    {activeFileVcsStatus}
                  </span>
                ) : null}
                {vcsTargets && vcsTargets.length > 0 ? (
                  <div className="flex items-center gap-1">
                    <span className="text-muted">Against:</span>
                    <Select
                      data-debug-id="editor-diff-target-select"
                      value={selectedDiffTarget}
                      onChange={(val) => onSelectDiffTarget?.(val)}
                      size="sm"
                    >
                      {vcsTargets.map((t) => (
                        <option key={t.id} value={t.id}>
                          {t.label}{t.is_default ? ' (default)' : ''}
                        </option>
                      ))}
                    </Select>
                  </div>
                ) : null}
                {isFetchingBaseContent ? (
                  <span className="flex items-center gap-1 text-[10px] text-muted">
                    <Icon name="refresh" size={10} className="animate-spin" /> Fetching base…
                  </span>
                ) : null}
              </div>
              <div className="text-[10.5px] text-muted">
                Original (Base) ↔ Modified (Working)
              </div>
            </div>

            <div className="relative min-h-0 flex-1">
              <DiffEditor
                original={diffOriginalContent !== undefined ? diffOriginalContent : activeTab.initialContent}
                modified={diffModifiedContent !== undefined ? diffModifiedContent : activeTab.content}
                language={language}
                theme={monacoTheme}
                options={{
                  minimap: { enabled: !isMobile && !isSinglePane },
                  wordWrap: isWordWrap ? 'on' : 'off',
                  lineNumbers: 'on',
                  lineNumbersMinChars: isNarrow ? 2 : 3,
                  lineDecorationsWidth: isNarrow ? 4 : 10,
                  glyphMargin: !isNarrow,
                  folding: !isNarrow,
                  scrollBeyondLastLine: false,
                  automaticLayout: true,
                  fontSize: 13,
                  fontFamily:
                    'ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, "Liberation Mono", "Courier New", monospace',
                  renderWhitespace: 'selection',
                  smoothScrolling: true,
                  readOnly: false,
                  originalEditable: false,
                }}
                onMount={handleDiffMount}
                loading={
                  <div className="p-4 text-center text-xs text-muted">
                    Loading diff editor…
                  </div>
                }
              />
            </div>
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

      {/* Persistent editor status bar showing branch, CL (if Fig), modified count */}
      <div
        data-debug-id="editor-status-bar"
        className="flex h-[24px] min-h-[24px] max-h-[24px] w-full items-center justify-between border-t border-subtle bg-surface-raised px-3 text-[11px] text-muted select-none shrink-0"
      >
        <div className="flex items-center gap-3">
          {branchName ? (
            <span data-debug-id="editor-status-bar-branch" className="flex items-center gap-1 font-medium text-primary">
              <Icon name="folder" size={11} className="text-accent" />
              <span>{branchName}</span>
            </span>
          ) : null}
          {isFig && clNumber ? (
            <span data-debug-id="editor-status-bar-cl" className="rounded bg-accent/15 px-1.5 py-0.2 text-[10px] font-mono font-semibold text-accent">
              CL {clNumber}
            </span>
          ) : null}
          <span data-debug-id="editor-status-bar-modified" className="flex items-center gap-1">
            <span className="font-semibold text-primary">{modifiedFilesCount ?? 0}</span> modified
          </span>
          {isDiffMode ? (
            <span className="text-accent font-medium">
              Diff Mode{selectedDiffTarget ? ` (${selectedDiffTarget})` : ''}
            </span>
          ) : null}
        </div>
        <div className="flex items-center gap-2 font-mono text-[10.5px]">
          <span>{language}</span>
          <span>UTF-8</span>
        </div>
      </div>

      {/* REQ-VIM-KEYBINDINGS: Themed 20-22px Vim status line below Monaco Editor container */}
      <div
        ref={statusNodeRef}
        data-debug-id={`${debugPrefix}-vim-statusbar`}
        className={`${
          isVimMode ? '' : 'hidden'
        } h-[22px] min-h-[22px] max-h-[22px] w-full px-2 text-[11.5px] font-mono bg-surface-raised border-t border-subtle text-muted select-none overflow-hidden shrink-0 leading-[22px] [&_input]:bg-transparent [&_input]:border-none [&_input]:outline-none [&_input]:text-primary [&_input]:font-mono [&_input]:text-[11.5px] [&_input]:p-0 [&_input]:m-0`}
      />
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
