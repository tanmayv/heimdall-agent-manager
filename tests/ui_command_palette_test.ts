// REQ-EDITOR-COMMAND-PALETTE-1, REQ-SEARCH-SHORTCUTS-1: executable unit tests for Command Palette & Action Registry.
//
// RUN:  node --test tests/ui_command_palette_test.ts

import { test } from 'node:test';
import assert from 'node:assert/strict';

import {
  DEFAULT_EDITOR_COMMANDS,
  COMMAND_CATEGORIES,
  cleanCommandQuery,
  subsequenceFuzzyMatch,
  fuzzyMatchScore,
  filterEditorCommands,
  type EditorCommand,
  type EditorCommandContext,
} from '../src/ui/commands/editorCommands.ts';

// -----------------------------------------------------------------------------
// 1. Registry Completeness & Category Mapping
// -----------------------------------------------------------------------------

test('registry defines all 5 required categories', () => {
  assert.deepEqual(COMMAND_CATEGORIES, ['LSP', 'Search', 'File', 'View', 'Directory']);
});

test('registry contains all required LSP commands with exact titles and shortcuts', () => {
  const lspCommands = DEFAULT_EDITOR_COMMANDS.filter((c) => c.category === 'LSP');
  const titles = lspCommands.map((c) => c.title);

  assert.ok(titles.includes('Find References'));
  assert.ok(titles.includes('Go to Implementation'));
  assert.ok(titles.includes('Go to Definition'));
  assert.ok(titles.includes('Go to Symbol in File'));
  assert.ok(titles.includes('Go to Symbol in Workspace'));
  assert.ok(titles.includes('Format Document'));
  assert.ok(titles.includes('Rename Symbol'));
  assert.ok(titles.includes('Restart Language Server'));

  const findRefs = lspCommands.find((c) => c.title === 'Find References');
  assert.equal(findRefs?.shortcut, 'Shift+F12');

  const goToImpl = lspCommands.find((c) => c.title === 'Go to Implementation');
  assert.equal(goToImpl?.shortcut, 'Cmd+F12');

  const goToDef = lspCommands.find((c) => c.title === 'Go to Definition');
  assert.equal(goToDef?.shortcut, 'F12');

  const symbolInFile = lspCommands.find((c) => c.title === 'Go to Symbol in File');
  assert.equal(symbolInFile?.shortcut, 'Cmd+Shift+O');

  const symbolInWorkspace = lspCommands.find((c) => c.title === 'Go to Symbol in Workspace');
  assert.equal(symbolInWorkspace?.shortcut, 'Cmd+T');

  const formatDoc = lspCommands.find((c) => c.title === 'Format Document');
  assert.equal(formatDoc?.shortcut, 'Shift+Alt+F');

  const rename = lspCommands.find((c) => c.title === 'Rename Symbol');
  assert.equal(rename?.shortcut, 'F2');

  const restart = lspCommands.find((c) => c.title === 'Restart Language Server');
  assert.equal(restart?.shortcut, undefined);
});

test('registry contains Search command with Cmd+Shift+F shortcut', () => {
  const searchCommands = DEFAULT_EDITOR_COMMANDS.filter((c) => c.category === 'Search');
  const findInFiles = searchCommands.find((c) => c.title === 'Find in Files');
  assert.ok(findInFiles);
  assert.equal(findInFiles?.shortcut, 'Cmd+Shift+F');
});

test('registry contains File commands Quick Open (Cmd+P) and Save File (Cmd+S)', () => {
  const fileCommands = DEFAULT_EDITOR_COMMANDS.filter((c) => c.category === 'File');
  const quickOpen = fileCommands.find((c) => c.title === 'Quick Open');
  const saveFile = fileCommands.find((c) => c.title === 'Save File');

  assert.ok(quickOpen);
  assert.equal(quickOpen?.shortcut, 'Cmd+P');

  assert.ok(saveFile);
  assert.equal(saveFile?.shortcut, 'Cmd+S');
});

test('registry contains View commands Toggle Word Wrap (Alt+Z) and Toggle Minimap', () => {
  const viewCommands = DEFAULT_EDITOR_COMMANDS.filter((c) => c.category === 'View');
  const toggleWrap = viewCommands.find((c) => c.title === 'Toggle Word Wrap');
  const toggleMinimap = viewCommands.find((c) => c.title === 'Toggle Minimap');

  assert.ok(toggleWrap);
  assert.equal(toggleWrap?.shortcut, 'Alt+Z');

  assert.ok(toggleMinimap);
});

test('registry contains Directory command Switch Directory Scope', () => {
  const dirCommands = DEFAULT_EDITOR_COMMANDS.filter((c) => c.category === 'Directory');
  const switchScope = dirCommands.find((c) => c.title === 'Switch Directory Scope');
  assert.ok(switchScope);
});

// -----------------------------------------------------------------------------
// 2. Command Execution & Context Injection
// -----------------------------------------------------------------------------

test('LSP commands invoke Monaco editor action runners', () => {
  const executedActions: string[] = [];
  let focusCalled = false;

  const mockEditor = {
    focus: () => {
      focusCalled = true;
    },
    getAction: (actionId: string) => ({
      isSupported: () => true,
      run: () => {
        executedActions.push(actionId);
      },
    }),
    trigger: (_source: string, actionId: string) => {
      executedActions.push(actionId);
    },
  };

  const ctx: EditorCommandContext = {
    editor: mockEditor,
    activeTab: { path: 'src/main.ts', isReadOnly: false },
  };

  const findRefs = DEFAULT_EDITOR_COMMANDS.find((c) => c.id === 'lsp.findReferences');
  findRefs?.run(ctx);
  assert.ok(focusCalled);
  assert.ok(executedActions.includes('editor.action.referenceSearch.trigger'));

  const goToDef = DEFAULT_EDITOR_COMMANDS.find((c) => c.id === 'lsp.goToDefinition');
  goToDef?.run(ctx);
  assert.ok(executedActions.includes('editor.action.revealDefinition'));

  const formatDoc = DEFAULT_EDITOR_COMMANDS.find((c) => c.id === 'lsp.formatDocument');
  formatDoc?.run(ctx);
  assert.ok(executedActions.includes('editor.action.formatDocument'));

  const rename = DEFAULT_EDITOR_COMMANDS.find((c) => c.id === 'lsp.renameSymbol');
  rename?.run(ctx);
  assert.ok(executedActions.includes('editor.action.rename'));
});

test('Restart Language Server command executes ctx.restartLsp', () => {
  let restartCalled = false;
  const ctx: EditorCommandContext = {
    restartLsp: () => {
      restartCalled = true;
    },
  };

  const restartCmd = DEFAULT_EDITOR_COMMANDS.find((c) => c.id === 'lsp.restartServer');
  restartCmd?.run(ctx);
  assert.equal(restartCalled, true);
});

test('Find in Files command executes ctx.openSearchInFiles', () => {
  let searchCalled = false;
  const ctx: EditorCommandContext = {
    openSearchInFiles: () => {
      searchCalled = true;
    },
  };

  const findCmd = DEFAULT_EDITOR_COMMANDS.find((c) => c.id === 'search.findInFiles');
  findCmd?.run(ctx);
  assert.equal(searchCalled, true);
});

test('Quick Open command executes ctx.openQuickOpen', () => {
  let quickOpenCalled = false;
  const ctx: EditorCommandContext = {
    openQuickOpen: () => {
      quickOpenCalled = true;
    },
  };

  const quickOpenCmd = DEFAULT_EDITOR_COMMANDS.find((c) => c.id === 'file.quickOpen');
  quickOpenCmd?.run(ctx);
  assert.equal(quickOpenCalled, true);
});

test('Save File command executes ctx.saveActiveFile', async () => {
  let saveCalled = false;
  const ctx: EditorCommandContext = {
    saveActiveFile: () => {
      saveCalled = true;
    },
  };

  const saveCmd = DEFAULT_EDITOR_COMMANDS.find((c) => c.id === 'file.saveFile');
  await saveCmd?.run(ctx);
  assert.equal(saveCalled, true);
});

test('Toggle Word Wrap and Toggle Minimap invoke their respective callbacks', () => {
  let wrapToggled = false;
  let minimapToggled = false;

  const ctx: EditorCommandContext = {
    toggleWordWrap: () => {
      wrapToggled = true;
    },
    toggleMinimap: () => {
      minimapToggled = true;
    },
  };

  const wrapCmd = DEFAULT_EDITOR_COMMANDS.find((c) => c.id === 'view.toggleWordWrap');
  wrapCmd?.run(ctx);
  assert.equal(wrapToggled, true);

  const minimapCmd = DEFAULT_EDITOR_COMMANDS.find((c) => c.id === 'view.toggleMinimap');
  minimapCmd?.run(ctx);
  assert.equal(minimapToggled, true);
});

test('Switch Directory Scope executes switchDirectoryScope or cycles directories', () => {
  let customScopeCalled = false;
  const ctxWithScope: EditorCommandContext = {
    switchDirectoryScope: () => {
      customScopeCalled = true;
    },
  };

  const dirCmd = DEFAULT_EDITOR_COMMANDS.find((c) => c.id === 'directory.switchScope');
  dirCmd?.run(ctxWithScope);
  assert.equal(customScopeCalled, true);

  let switchedToId = '';
  const ctxWithDirs: EditorCommandContext = {
    availableDirectories: [
      { id: 'primary', label: 'Primary' },
      { id: 'chain_dir_1', label: 'Dir 1' },
      { id: 'chain_dir_2', label: 'Dir 2' },
    ],
    activeDirectoryId: 'primary',
    switchDirectory: (id) => {
      switchedToId = id;
    },
  };

  dirCmd?.run(ctxWithDirs);
  assert.equal(switchedToId, 'chain_dir_1');
});

// -----------------------------------------------------------------------------
// 3. Command isEnabled Checks
// -----------------------------------------------------------------------------

test('Editor commands disable when active tab is read-only or image', () => {
  const saveCmd = DEFAULT_EDITOR_COMMANDS.find((c) => c.id === 'file.saveFile');
  const formatCmd = DEFAULT_EDITOR_COMMANDS.find((c) => c.id === 'lsp.formatDocument');

  const readOnlyCtx: EditorCommandContext = {
    editor: {},
    activeTab: { path: 'data.json', isReadOnly: true },
  };
  assert.equal(saveCmd?.isEnabled?.(readOnlyCtx), false);
  assert.equal(formatCmd?.isEnabled?.(readOnlyCtx), false);

  const imageCtx: EditorCommandContext = {
    editor: {},
    activeTab: { path: 'icon.png', isImage: true },
  };
  assert.equal(saveCmd?.isEnabled?.(imageCtx), false);
  assert.equal(formatCmd?.isEnabled?.(imageCtx), false);

  const normalCtx: EditorCommandContext = {
    editor: {},
    activeTab: { path: 'main.ts', isReadOnly: false },
  };
  assert.equal(saveCmd?.isEnabled?.(normalCtx), true);
  assert.equal(formatCmd?.isEnabled?.(normalCtx), true);
});

// -----------------------------------------------------------------------------
// 4. Query Cleaning & Prefix Handling
// -----------------------------------------------------------------------------

test('cleanCommandQuery strips leading > and trims whitespace', () => {
  assert.equal(cleanCommandQuery('>'), '');
  assert.equal(cleanCommandQuery('> format'), 'format');
  assert.equal(cleanCommandQuery('>   lsp'), 'lsp');
  assert.equal(cleanCommandQuery('find'), 'find');
  assert.equal(cleanCommandQuery('   > save   '), 'save');
});

// -----------------------------------------------------------------------------
// 5. Fuzzy Matching & Ranking
// -----------------------------------------------------------------------------

test('subsequenceFuzzyMatch matches sequential characters case-insensitively', () => {
  assert.equal(subsequenceFuzzyMatch('fmt', 'Format Document'), true);
  assert.equal(subsequenceFuzzyMatch('fif', 'Find in Files'), true);
  assert.equal(subsequenceFuzzyMatch('rls', 'Restart Language Server'), true);
  assert.equal(subsequenceFuzzyMatch('xyz', 'Find References'), false);
});

test('fuzzyMatchScore prioritizes exact match over partial and subsequence matches', () => {
  const exactScore = fuzzyMatchScore('save', 'save');
  const prefixScore = fuzzyMatchScore('save', 'save file');
  const infixScore = fuzzyMatchScore('file', 'save file now');
  const subseqScore = fuzzyMatchScore('sf', 'save file');

  assert.ok(exactScore > prefixScore);
  assert.ok(prefixScore > infixScore);
  assert.ok(infixScore > subseqScore);
});

test('filterEditorCommands filters by query and sorts best match first', () => {
  const matches = filterEditorCommands(DEFAULT_EDITOR_COMMANDS, 'format');
  assert.ok(matches.length > 0);
  assert.equal(matches[0].title, 'Format Document');

  const refMatches = filterEditorCommands(DEFAULT_EDITOR_COMMANDS, 'ref');
  assert.ok(refMatches.length > 0);
  assert.equal(refMatches[0].title, 'Find References');
});

test('filterEditorCommands supports > prefix in search query', () => {
  const matches = filterEditorCommands(DEFAULT_EDITOR_COMMANDS, '> quick');
  assert.ok(matches.length > 0);
  assert.equal(matches[0].title, 'Quick Open');
});

test('filterEditorCommands filters by Category chip', () => {
  const lspOnly = filterEditorCommands(DEFAULT_EDITOR_COMMANDS, '', 'LSP');
  assert.ok(lspOnly.length > 0);
  assert.ok(lspOnly.every((c) => c.category === 'LSP'));

  const fileOnly = filterEditorCommands(DEFAULT_EDITOR_COMMANDS, '', 'File');
  assert.ok(fileOnly.length > 0);
  assert.ok(fileOnly.every((c) => c.category === 'File'));

  const allCmds = filterEditorCommands(DEFAULT_EDITOR_COMMANDS, '', 'ALL');
  assert.equal(allCmds.length, DEFAULT_EDITOR_COMMANDS.length);
});

test('filterEditorCommands filters by shortcut text', () => {
  const f12Matches = filterEditorCommands(DEFAULT_EDITOR_COMMANDS, 'F12');
  assert.ok(f12Matches.some((c) => c.title === 'Go to Definition'));
  assert.ok(f12Matches.some((c) => c.title === 'Find References'));

  const altZMatches = filterEditorCommands(DEFAULT_EDITOR_COMMANDS, 'Alt+Z');
  assert.ok(altZMatches.some((c) => c.title === 'Toggle Word Wrap'));
});
