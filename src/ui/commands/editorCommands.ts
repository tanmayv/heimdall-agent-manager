// Strongly-typed Action Registry & Command Palette commands (REQ-EDITOR-COMMAND-PALETTE-1, REQ-SEARCH-SHORTCUTS-1)

export type CommandCategory = 'LSP' | 'Search' | 'File' | 'View' | 'Directory';

export const COMMAND_CATEGORIES: CommandCategory[] = ['LSP', 'Search', 'File', 'View', 'Directory'];

export interface EditorCommandContext {
  /** Active Monaco editor instance */
  editor?: any;
  /** Monaco namespace */
  monaco?: any;
  /** Currently active tab in editor */
  activeTab?: {
    path: string;
    content?: string;
    isReadOnly?: boolean;
    isImage?: boolean;
    isUnviewable?: boolean;
  } | null;
  /** Trigger open Search in Files drawer */
  openSearchInFiles?: () => void;
  /** Trigger open Quick Open modal */
  openQuickOpen?: () => void;
  /** Save active file */
  saveActiveFile?: () => void | Promise<void>;
  /** Save all open files */
  saveAllFiles?: () => void | Promise<void>;
  /** Toggle word wrap */
  toggleWordWrap?: () => void;
  /** Toggle minimap */
  toggleMinimap?: () => void;
  /** Is word wrap currently enabled */
  isWordWrap?: boolean;
  /** Is minimap currently enabled */
  isMinimapEnabled?: boolean;
  /** Restart language server session */
  restartLsp?: () => void;
  /** Switch directory scope callback */
  switchDirectoryScope?: () => void;
  /** Switch directory by id */
  switchDirectory?: (directoryId: string) => void;
  /** Available directories in chain */
  availableDirectories?: Array<{
    id: string;
    label?: string;
    path?: string;
    bridgeId?: string;
    kind?: string;
    agentInstanceId?: string;
  }>;
  /** Active directory id */
  activeDirectoryId?: string;
}

export interface EditorCommand {
  id: string;
  title: string;
  description?: string;
  category: CommandCategory;
  shortcut?: string;
  run: (ctx: EditorCommandContext) => void | Promise<void>;
  isEnabled?: (ctx: EditorCommandContext) => boolean;
}

function runMonacoAction(editor: any, actionId: string) {
  if (!editor) return;
  try {
    editor.focus?.();
    const action = editor.getAction?.(actionId);
    if (action && (typeof action.isSupported !== 'function' || action.isSupported())) {
      action.run();
    } else {
      editor.trigger?.('commandPalette', actionId, null);
    }
  } catch (err) {
    // eslint-disable-next-line no-console
    console.error(`[CommandPalette] Failed to run Monaco action ${actionId}:`, err);
  }
}

export const DEFAULT_EDITOR_COMMANDS: EditorCommand[] = [
  // --- LSP Commands ---
  {
    id: 'lsp.findReferences',
    title: 'Find References',
    description: 'Find all references for symbol at cursor',
    category: 'LSP',
    shortcut: 'Shift+F12',
    run: (ctx) => {
      runMonacoAction(ctx.editor, 'editor.action.referenceSearch.trigger');
    },
    isEnabled: (ctx) => Boolean(ctx.editor && ctx.activeTab && !ctx.activeTab.isImage && !ctx.activeTab.isUnviewable),
  },
  {
    id: 'lsp.goToImplementation',
    title: 'Go to Implementation',
    description: 'Go to implementation of symbol at cursor',
    category: 'LSP',
    shortcut: 'Cmd+F12',
    run: (ctx) => {
      runMonacoAction(ctx.editor, 'editor.action.goToImplementation');
    },
    isEnabled: (ctx) => Boolean(ctx.editor && ctx.activeTab && !ctx.activeTab.isImage && !ctx.activeTab.isUnviewable),
  },
  {
    id: 'lsp.goToDefinition',
    title: 'Go to Definition',
    description: 'Go to definition of symbol at cursor',
    category: 'LSP',
    shortcut: 'F12',
    run: (ctx) => {
      runMonacoAction(ctx.editor, 'editor.action.revealDefinition');
    },
    isEnabled: (ctx) => Boolean(ctx.editor && ctx.activeTab && !ctx.activeTab.isImage && !ctx.activeTab.isUnviewable),
  },
  {
    id: 'lsp.goToSymbolInFile',
    title: 'Go to Symbol in File',
    description: 'Navigate to symbols within current file',
    category: 'LSP',
    shortcut: 'Cmd+Shift+O',
    run: (ctx) => {
      runMonacoAction(ctx.editor, 'editor.action.quickOutline');
    },
    isEnabled: (ctx) => Boolean(ctx.editor && ctx.activeTab && !ctx.activeTab.isImage && !ctx.activeTab.isUnviewable),
  },
  {
    id: 'lsp.goToSymbolInWorkspace',
    title: 'Go to Symbol in Workspace',
    description: 'Navigate to symbols across entire workspace',
    category: 'LSP',
    shortcut: 'Cmd+T',
    run: (ctx) => {
      runMonacoAction(ctx.editor, 'workbench.action.showAllSymbols');
    },
    isEnabled: (ctx) => Boolean(ctx.editor),
  },
  {
    id: 'lsp.formatDocument',
    title: 'Format Document',
    description: 'Format active document using language server',
    category: 'LSP',
    shortcut: 'Shift+Alt+F',
    run: (ctx) => {
      runMonacoAction(ctx.editor, 'editor.action.formatDocument');
    },
    isEnabled: (ctx) => Boolean(ctx.editor && ctx.activeTab && !ctx.activeTab.isReadOnly && !ctx.activeTab.isImage),
  },
  {
    id: 'lsp.renameSymbol',
    title: 'Rename Symbol',
    description: 'Rename symbol at cursor across files',
    category: 'LSP',
    shortcut: 'F2',
    run: (ctx) => {
      runMonacoAction(ctx.editor, 'editor.action.rename');
    },
    isEnabled: (ctx) => Boolean(ctx.editor && ctx.activeTab && !ctx.activeTab.isReadOnly && !ctx.activeTab.isImage),
  },
  {
    id: 'lsp.restartServer',
    title: 'Restart Language Server',
    description: 'Restart language server session for current language',
    category: 'LSP',
    run: (ctx) => {
      ctx.restartLsp?.();
    },
  },

  // --- Search Commands ---
  {
    id: 'search.findInFiles',
    title: 'Find in Files',
    description: 'Search text across project, task chain, and run directories',
    category: 'Search',
    shortcut: 'Cmd+Shift+F',
    run: (ctx) => {
      ctx.openSearchInFiles?.();
    },
  },

  // --- File Commands ---
  {
    id: 'file.quickOpen',
    title: 'Quick Open',
    description: 'Search and open files by name or path',
    category: 'File',
    shortcut: 'Cmd+P',
    run: (ctx) => {
      ctx.openQuickOpen?.();
    },
  },
  {
    id: 'file.saveFile',
    title: 'Save File',
    description: 'Save current active file changes',
    category: 'File',
    shortcut: 'Cmd+S',
    run: (ctx) => {
      void ctx.saveActiveFile?.();
    },
    isEnabled: (ctx) => Boolean(ctx.activeTab && !ctx.activeTab.isReadOnly && !ctx.activeTab.isImage),
  },

  // --- View Commands ---
  {
    id: 'view.toggleWordWrap',
    title: 'Toggle Word Wrap',
    description: 'Toggle editor soft line wrapping on or off',
    category: 'View',
    shortcut: 'Alt+Z',
    run: (ctx) => {
      ctx.toggleWordWrap?.();
    },
  },
  {
    id: 'view.toggleMinimap',
    title: 'Toggle Minimap',
    description: 'Toggle code overview minimap visibility',
    category: 'View',
    run: (ctx) => {
      ctx.toggleMinimap?.();
    },
  },

  // --- Directory Commands ---
  {
    id: 'directory.switchScope',
    title: 'Switch Directory Scope',
    description: 'Switch between primary project and task chain directories',
    category: 'Directory',
    run: (ctx) => {
      if (ctx.switchDirectoryScope) {
        ctx.switchDirectoryScope();
      } else if (
        ctx.availableDirectories &&
        ctx.availableDirectories.length > 1 &&
        ctx.switchDirectory
      ) {
        const currentIdx = ctx.availableDirectories.findIndex((d) => d.id === ctx.activeDirectoryId);
        const nextIdx = (currentIdx + 1) % ctx.availableDirectories.length;
        ctx.switchDirectory(ctx.availableDirectories[nextIdx].id);
      }
    },
    isEnabled: (ctx) => Boolean(ctx.switchDirectoryScope || (ctx.availableDirectories && ctx.availableDirectories.length > 1)),
  },
];

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

export function fuzzyMatchScore(pattern: string, text: string): number {
  if (!pattern) return 1;
  const p = pattern.toLowerCase();
  const t = text.toLowerCase();
  if (t === p) return 1000;
  if (t.startsWith(p)) return 500;
  if (t.includes(p)) return 300;
  if (subsequenceFuzzyMatch(pattern, text)) {
    return 100 - Math.min(text.length - pattern.length, 90);
  }
  return 0;
}

export function cleanCommandQuery(query: string): string {
  const trimmed = query.trim();
  if (trimmed.startsWith('>')) {
    return trimmed.slice(1).trim();
  }
  return trimmed;
}

export function filterEditorCommands(
  commands: EditorCommand[],
  query: string,
  category?: CommandCategory | 'ALL',
  ctx?: EditorCommandContext
): EditorCommand[] {
  const clean = cleanCommandQuery(query);
  const activeCategory = category && category !== 'ALL' ? category : null;

  return commands
    .filter((cmd) => {
      if (activeCategory && cmd.category !== activeCategory) {
        return false;
      }
      if (ctx && cmd.isEnabled && !cmd.isEnabled(ctx)) {
        return false;
      }
      if (!clean) {
        return true;
      }
      const titleMatch = subsequenceFuzzyMatch(clean, cmd.title);
      const descMatch = cmd.description ? subsequenceFuzzyMatch(clean, cmd.description) : false;
      const catMatch = subsequenceFuzzyMatch(clean, cmd.category);
      const shortcutMatch = cmd.shortcut ? subsequenceFuzzyMatch(clean, cmd.shortcut) : false;
      return titleMatch || descMatch || catMatch || shortcutMatch;
    })
    .sort((a, b) => {
      if (!clean) return 0;
      const scoreA = Math.max(
        fuzzyMatchScore(clean, a.title),
        a.description ? fuzzyMatchScore(clean, a.description) * 0.5 : 0
      );
      const scoreB = Math.max(
        fuzzyMatchScore(clean, b.title),
        b.description ? fuzzyMatchScore(clean, b.description) * 0.5 : 0
      );
      return scoreB - scoreA;
    });
}
