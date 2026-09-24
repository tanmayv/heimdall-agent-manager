// REQ-LSP-UI-1: LSP wire types, JSON-RPC framing, and LSP <-> Monaco converters.
//
// DELIBERATELY DEPENDENCY-FREE. This module imports nothing — not React, not
// monaco-editor, not even monaco's TYPES. Two reasons, both load-bearing:
//
//  1. It is the unit under test. tests/ui_lsp_position_test.ts runs it directly
//     under `node --test` (Node strips the TS types natively), which only works
//     while the module resolves to nothing at runtime. An `import type` from
//     monaco-editor would still be erased, but a later careless edit turning it
//     into a value import would break the test run with no type error to catch
//     it. Structural types instead — see Monaco_Position below.
//  2. The converters are the classic bug source in this adapter (0-based LSP vs
//     1-based Monaco). Keeping them in a leaf module means they can be reasoned
//     about, and exercised, without standing up an editor.
//
// The hook that consumes this (useMonacoLsp.ts) casts these structural shapes
// to the real monaco types at the boundary. The shapes are structurally
// identical to monaco's, so the cast is a naming formality, not a lie.

// --- LSP wire types (only the subset this adapter sends or reads) -----------

export type LspPosition = { line: number; character: number };
export type LspRange = { start: LspPosition; end: LspPosition };
export type LspLocation = { uri: string; range: LspRange };
export type LspLocationLink = { targetUri: string; targetSelectionRange?: LspRange; targetRange: LspRange };
export type LspSymbolKind = number;

export type LspDocumentSymbol = {
  name: string;
  detail?: string;
  kind: LspSymbolKind;
  tags?: number[];
  deprecated?: boolean;
  range: LspRange;
  selectionRange: LspRange;
  children?: LspDocumentSymbol[];
};

export type LspSymbolInformation = {
  name: string;
  kind: LspSymbolKind;
  tags?: number[];
  deprecated?: boolean;
  location: LspLocation;
  containerName?: string;
};

export type LspMarkupContent = { kind: 'plaintext' | 'markdown'; value: string };
export type LspMarkedString = string | { language: string; value: string };

export type LspHover = {
  contents: LspMarkupContent | LspMarkedString | LspMarkedString[];
  range?: LspRange;
};

export type LspCompletionItem = {
  label: string;
  kind?: number;
  detail?: string;
  documentation?: string | LspMarkupContent;
  insertText?: string;
  insertTextFormat?: number; // 1 = PlainText, 2 = Snippet
  filterText?: string;
  sortText?: string;
  textEdit?: { range: LspRange; newText: string };
};

export type LspCompletionList = { isIncomplete: boolean; items: LspCompletionItem[] };

export type LspDiagnostic = {
  range: LspRange;
  severity?: number; // 1 Error, 2 Warning, 3 Information, 4 Hint
  code?: string | number;
  source?: string;
  message: string;
};

// --- Monaco-shaped structural types ----------------------------------------
// Field-for-field identical to monaco.IPosition / IRange / editor.IMarkerData.

export type Monaco_Position = { lineNumber: number; column: number };
export type Monaco_Range = {
  startLineNumber: number;
  startColumn: number;
  endLineNumber: number;
  endColumn: number;
};
export type Monaco_Location = {
  uri: any;
  range: Monaco_Range;
};
export type Monaco_DocumentSymbol = {
  name: string;
  detail: string;
  kind: number;
  tags: readonly number[];
  containerName?: string;
  range: Monaco_Range;
  selectionRange: Monaco_Range;
  children?: Monaco_DocumentSymbol[];
};

// Monaco's MarkerSeverity enum values. Hardcoded rather than imported so this
// module stays dependency-free; asserted against the live enum in
// useMonacoLsp.ts at registration time so a monaco upgrade that renumbered them
// could not pass silently.
export const MONACO_MARKER_SEVERITY = {
  Hint: 1,
  Info: 2,
  Warning: 4,
  Error: 8,
} as const;

// --- Position conversion ----------------------------------------------------
//
// THE ONE RULE THIS WHOLE FILE EXISTS TO GET RIGHT:
//   LSP     line/character are 0-BASED.
//   Monaco  lineNumber/column are 1-BASED.
// So both fields shift by exactly one, in opposite directions.
//
// Note what is NOT true: this is not a round-trip-safe abstraction you can test
// by composing the two functions. An off-by-one duplicated in BOTH directions
// composes to the identity and a round-trip test passes while every real
// position is wrong by a line. The tests therefore anchor absolute values
// ({line:0,character:0} <-> {lineNumber:1,column:1}) in each direction
// independently.

export function lspToMonacoPosition(p: LspPosition): Monaco_Position {
  return { lineNumber: p.line + 1, column: p.character + 1 };
}

export function monacoToLspPosition(p: Monaco_Position): LspPosition {
  return { line: p.lineNumber - 1, character: p.column - 1 };
}

export function lspToMonacoRange(r: LspRange): Monaco_Range {
  return {
    startLineNumber: r.start.line + 1,
    startColumn: r.start.character + 1,
    endLineNumber: r.end.line + 1,
    endColumn: r.end.character + 1,
  };
}

export function monacoToLspRange(r: Monaco_Range): LspRange {
  return {
    start: { line: r.startLineNumber - 1, character: r.startColumn - 1 },
    end: { line: r.endLineNumber - 1, character: r.endColumn - 1 },
  };
}

// --- Severity / kind mapping ------------------------------------------------

// LSP DiagnosticSeverity (1..4, Error highest) -> Monaco MarkerSeverity (bit
// flags, Error highest). Not a shared scale and not monotonic in the same
// direction as a naive cast would assume, hence the explicit table.
//
// An absent severity means "the server did not say". LSP leaves that to the
// client; we surface it as Error, because the alternative (silently downgrading
// to Hint) hides real problems behind a barely visible squiggle.
export function lspToMonacoSeverity(severity?: number): number {
  switch (severity) {
    case 1:
      return MONACO_MARKER_SEVERITY.Error;
    case 2:
      return MONACO_MARKER_SEVERITY.Warning;
    case 3:
      return MONACO_MARKER_SEVERITY.Info;
    case 4:
      return MONACO_MARKER_SEVERITY.Hint;
    default:
      return MONACO_MARKER_SEVERITY.Error;
  }
}

// Monaco marker shape, structurally. `owner` is supplied at setModelMarkers time,
// not here.
export type Monaco_MarkerData = Monaco_Range & {
  severity: number;
  message: string;
  source?: string;
  code?: string;
};

export function lspDiagnosticToMarker(d: LspDiagnostic): Monaco_MarkerData {
  const range = lspToMonacoRange(d.range);
  return {
    ...range,
    severity: lspToMonacoSeverity(d.severity),
    message: d.message,
    ...(d.source ? { source: d.source } : {}),
    ...(d.code !== undefined && d.code !== null ? { code: String(d.code) } : {}),
  };
}

// LSP CompletionItemKind (1..25) -> Monaco languages.CompletionItemKind.
//
// These two enums are NOT the same numbering — a straight pass-through is the
// single most common bug in hand-written adapters and shows up as every
// completion wearing the wrong icon. The table is indexed by the LSP value; the
// value is Monaco's. Monaco's enum is hardcoded (same dependency-free reason as
// MONACO_MARKER_SEVERITY) from monaco-editor 0.45
// languages.CompletionItemKind.
const MONACO_COMPLETION_KIND = {
  Method: 0,
  Function: 1,
  Constructor: 2,
  Field: 3,
  Variable: 4,
  Class: 5,
  Struct: 6,
  Interface: 7,
  Module: 8,
  Property: 9,
  Event: 10,
  Operator: 11,
  Unit: 12,
  Value: 13,
  Constant: 14,
  Enum: 15,
  EnumMember: 16,
  Keyword: 17,
  Text: 18,
  Color: 19,
  File: 20,
  Reference: 21,
  Customcolor: 22,
  Folder: 23,
  TypeParameter: 24,
  User: 25,
  Issue: 26,
  Snippet: 27,
} as const;

const LSP_TO_MONACO_COMPLETION_KIND: Record<number, number> = {
  1: MONACO_COMPLETION_KIND.Text,
  2: MONACO_COMPLETION_KIND.Method,
  3: MONACO_COMPLETION_KIND.Function,
  4: MONACO_COMPLETION_KIND.Constructor,
  5: MONACO_COMPLETION_KIND.Field,
  6: MONACO_COMPLETION_KIND.Variable,
  7: MONACO_COMPLETION_KIND.Class,
  8: MONACO_COMPLETION_KIND.Interface,
  9: MONACO_COMPLETION_KIND.Module,
  10: MONACO_COMPLETION_KIND.Property,
  11: MONACO_COMPLETION_KIND.Unit,
  12: MONACO_COMPLETION_KIND.Value,
  13: MONACO_COMPLETION_KIND.Enum,
  14: MONACO_COMPLETION_KIND.Keyword,
  15: MONACO_COMPLETION_KIND.Snippet,
  16: MONACO_COMPLETION_KIND.Color,
  17: MONACO_COMPLETION_KIND.File,
  18: MONACO_COMPLETION_KIND.Reference,
  19: MONACO_COMPLETION_KIND.Folder,
  20: MONACO_COMPLETION_KIND.EnumMember,
  21: MONACO_COMPLETION_KIND.Constant,
  22: MONACO_COMPLETION_KIND.Struct,
  23: MONACO_COMPLETION_KIND.Event,
  24: MONACO_COMPLETION_KIND.Operator,
  25: MONACO_COMPLETION_KIND.TypeParameter,
};

// Unknown or absent kind falls back to Text — the neutral icon. Never throw: a
// server sending a kind from a newer LSP revision must not break completion.
export function lspToMonacoCompletionKind(kind?: number): number {
  if (kind === undefined || kind === null) return MONACO_COMPLETION_KIND.Text;
  const mapped = LSP_TO_MONACO_COMPLETION_KIND[kind];
  return mapped === undefined ? MONACO_COMPLETION_KIND.Text : mapped;
}

// LSP SymbolKind (1..26) -> Monaco languages.SymbolKind (0..25).
// LSP is 1-based, Monaco is 0-based across all 26 symbol types.
export const MONACO_SYMBOL_KIND = {
  File: 0,
  Module: 1,
  Namespace: 2,
  Package: 3,
  Class: 4,
  Method: 5,
  Property: 6,
  Field: 7,
  Constructor: 8,
  Enum: 9,
  Interface: 10,
  Function: 11,
  Variable: 12,
  Constant: 13,
  String: 14,
  Number: 15,
  Boolean: 16,
  Array: 17,
  Object: 18,
  Key: 19,
  Null: 20,
  EnumMember: 21,
  Struct: 22,
  Event: 23,
  Operator: 24,
  TypeParameter: 25,
} as const;

export const LSP_TO_MONACO_SYMBOL_KIND: Record<number, number> = {
  1: MONACO_SYMBOL_KIND.File,
  2: MONACO_SYMBOL_KIND.Module,
  3: MONACO_SYMBOL_KIND.Namespace,
  4: MONACO_SYMBOL_KIND.Package,
  5: MONACO_SYMBOL_KIND.Class,
  6: MONACO_SYMBOL_KIND.Method,
  7: MONACO_SYMBOL_KIND.Property,
  8: MONACO_SYMBOL_KIND.Field,
  9: MONACO_SYMBOL_KIND.Constructor,
  10: MONACO_SYMBOL_KIND.Enum,
  11: MONACO_SYMBOL_KIND.Interface,
  12: MONACO_SYMBOL_KIND.Function,
  13: MONACO_SYMBOL_KIND.Variable,
  14: MONACO_SYMBOL_KIND.Constant,
  15: MONACO_SYMBOL_KIND.String,
  16: MONACO_SYMBOL_KIND.Number,
  17: MONACO_SYMBOL_KIND.Boolean,
  18: MONACO_SYMBOL_KIND.Array,
  19: MONACO_SYMBOL_KIND.Object,
  20: MONACO_SYMBOL_KIND.Key,
  21: MONACO_SYMBOL_KIND.Null,
  22: MONACO_SYMBOL_KIND.EnumMember,
  23: MONACO_SYMBOL_KIND.Struct,
  24: MONACO_SYMBOL_KIND.Event,
  25: MONACO_SYMBOL_KIND.Operator,
  26: MONACO_SYMBOL_KIND.TypeParameter,
};

export function lspToMonacoSymbolKind(kind?: number): number {
  if (kind === undefined || kind === null) return MONACO_SYMBOL_KIND.Variable;
  const mapped = LSP_TO_MONACO_SYMBOL_KIND[kind];
  return mapped === undefined ? MONACO_SYMBOL_KIND.Variable : mapped;
}

// --- Hover content normalisation --------------------------------------------

// LSP's Hover.contents has three legal shapes across protocol revisions:
// MarkupContent, MarkedString, and MarkedString[] — where a MarkedString is
// itself either a bare string or {language, value}. Monaco wants a flat list of
// {value: markdown}. Fenced code blocks are reconstructed for the
// {language, value} form so a signature still renders as code.
export function lspHoverToMarkdownStrings(hover: LspHover | null | undefined): string[] {
  if (!hover || hover.contents === undefined || hover.contents === null) return [];
  const contents = hover.contents;

  const one = (item: LspMarkedString): string => {
    if (typeof item === 'string') return item;
    if (item && typeof item === 'object' && typeof item.value === 'string') {
      return item.language ? '```' + item.language + '\n' + item.value + '\n```' : item.value;
    }
    return '';
  };

  if (Array.isArray(contents)) {
    return contents.map(one).filter((s) => s.length > 0);
  }
  // MarkupContent is distinguished from {language, value} by carrying `kind`.
  if (typeof contents === 'object' && 'kind' in contents) {
    const value = String((contents as LspMarkupContent).value ?? '');
    return value.length > 0 ? [value] : [];
  }
  const single = one(contents as LspMarkedString);
  return single.length > 0 ? [single] : [];
}

// --- Definition normalisation -----------------------------------------------

// textDocument/definition may answer with Location, Location[], LocationLink[],
// or null. Normalised to a flat list of {uri, range} so the provider has one
// shape to convert. LocationLink prefers targetSelectionRange (the identifier)
// over targetRange (the whole declaration body) — jumping to the name is what a
// reader expects.
export function normaliseDefinitionResult(
  result: LspLocation | LspLocation[] | LspLocationLink[] | null | undefined
): LspLocation[] {
  if (!result) return [];
  const items = Array.isArray(result) ? result : [result];
  const out: LspLocation[] = [];
  for (const item of items) {
    if (!item) continue;
    if ('uri' in item && item.uri) {
      out.push({ uri: item.uri, range: item.range });
      continue;
    }
    if ('targetUri' in item && item.targetUri) {
      out.push({ uri: item.targetUri, range: item.targetSelectionRange ?? item.targetRange });
    }
  }
  return out;
}

// --- URI <-> path -----------------------------------------------------------
//
// Language servers speak file: URIs; the rest of this app speaks absolute POSIX
// paths. encodeURI is deliberate over encodeURIComponent: the separators in a
// path must survive, only the characters that are illegal in a URI may be
// escaped.
export function pathToFileUri(absPath: string): string {
  const normalised = absPath.startsWith('/') ? absPath : '/' + absPath;
  return 'file://' + encodeURI(normalised);
}

export function fileUriToPath(uri: string): string {
  if (!uri.startsWith('file://')) return decodeURI(uri);
  return decodeURI(uri.slice('file://'.length));
}

// --- Location & Document Symbol converters ----------------------------------

export const normaliseLocationResult = normaliseDefinitionResult;

export function findModelForPath(monaco: any, absPath: string, rootAbs?: string): any {
  if (!monaco || !absPath) return null;
  const root = (rootAbs || '').replace(/\/+$/, '');
  const rel = root && absPath.startsWith(root + '/') ? absPath.slice(root.length + 1) : absPath.replace(/^\/+/, '');
  if (!monaco.editor?.getModels) return null;
  for (const model of monaco.editor.getModels()) {
    const mPath = String(model?.uri?.path ?? '').replace(/^\/+/, '');
    if (mPath === rel) return model;
  }
  return null;
}

export function lspToMonacoLocation(
  loc: LspLocation,
  rootAbs?: string,
  monaco?: any
): Monaco_Location {
  const range = lspToMonacoRange(loc.range);
  const targetPath = fileUriToPath(loc.uri);
  if (monaco) {
    const existing = findModelForPath(monaco, targetPath, rootAbs);
    if (existing) {
      return { uri: existing.uri, range };
    }
    if (typeof monaco.Uri?.file === 'function') {
      return { uri: monaco.Uri.file(targetPath), range };
    }
  }
  return { uri: loc.uri, range };
}

export function normaliseDocumentSymbols(
  raw: LspDocumentSymbol[] | LspSymbolInformation[] | null | undefined
): Monaco_DocumentSymbol[] {
  if (!raw || !Array.isArray(raw) || raw.length === 0) return [];

  const hasLocation = raw.some((item) => item && typeof item === 'object' && 'location' in item);
  if (!hasLocation) {
    const convertOne = (sym: LspDocumentSymbol): Monaco_DocumentSymbol => ({
      name: sym.name,
      detail: sym.detail ?? '',
      kind: lspToMonacoSymbolKind(sym.kind),
      tags: sym.tags ?? (sym.deprecated ? [1] : []),
      containerName: undefined,
      range: lspToMonacoRange(sym.range),
      selectionRange: lspToMonacoRange(sym.selectionRange ?? sym.range),
      children: Array.isArray(sym.children) ? sym.children.map(convertOne) : [],
    });
    return (raw as LspDocumentSymbol[]).filter(Boolean).map(convertOne);
  }

  const flatItems = (raw as LspSymbolInformation[]).filter(
    (item) => item && typeof item === 'object' && item.location && item.location.range
  );

  const mapped: Array<{ symbol: Monaco_DocumentSymbol; containerName?: string }> = flatItems.map((item) => ({
    containerName: item.containerName,
    symbol: {
      name: item.name,
      detail: item.containerName ?? '',
      kind: lspToMonacoSymbolKind(item.kind),
      tags: item.tags ?? (item.deprecated ? [1] : []),
      containerName: item.containerName,
      range: lspToMonacoRange(item.location.range),
      selectionRange: lspToMonacoRange(item.location.range),
      children: [],
    },
  }));

  const byName = new Map<string, Monaco_DocumentSymbol>();
  for (const entry of mapped) {
    byName.set(entry.symbol.name, entry.symbol);
  }

  const result: Monaco_DocumentSymbol[] = [];
  for (const entry of mapped) {
    if (entry.containerName && byName.has(entry.containerName)) {
      const parent = byName.get(entry.containerName)!;
      if (parent !== entry.symbol) {
        parent.children = parent.children ?? [];
        parent.children.push(entry.symbol);
        continue;
      }
    }
    result.push(entry.symbol);
  }

  return result;
}

// --- JSON-RPC framing -------------------------------------------------------

export type JsonRpcRequest = { jsonrpc: '2.0'; id: number; method: string; params?: unknown };
export type JsonRpcNotification = { jsonrpc: '2.0'; method: string; params?: unknown };
export type JsonRpcResponse = {
  jsonrpc: '2.0';
  id: number | string | null;
  result?: unknown;
  error?: { code: number; message: string; data?: unknown };
};

export type JsonRpcIncoming = Partial<JsonRpcResponse> & Partial<JsonRpcNotification> & { id?: number | string | null };

export function jsonRpcRequest(id: number, method: string, params?: unknown): JsonRpcRequest {
  return { jsonrpc: '2.0', id, method, params };
}

export function jsonRpcNotification(method: string, params?: unknown): JsonRpcNotification {
  return { jsonrpc: '2.0', method, params };
}

// A message is a RESPONSE when it carries an id AND is not a method call.
// Servers also send REQUESTS (id + method, e.g. window/workDoneProgress/create)
// which must not be mistaken for responses to our own ids — the id spaces are
// independent, so a server request with id 1 would otherwise resolve our
// initialize promise with garbage.
export function isJsonRpcResponse(msg: JsonRpcIncoming): boolean {
  return msg !== null && typeof msg === 'object' && msg.id !== undefined && msg.id !== null && !msg.method;
}

export function isJsonRpcServerRequest(msg: JsonRpcIncoming): boolean {
  return msg !== null && typeof msg === 'object' && msg.id !== undefined && msg.id !== null && Boolean(msg.method);
}

export function isJsonRpcNotification(msg: JsonRpcIncoming): boolean {
  return msg !== null && typeof msg === 'object' && (msg.id === undefined || msg.id === null) && Boolean(msg.method);
}

// --- Language ids -----------------------------------------------------------
//
// Two different language ids are in play and conflating them is a real bug:
//   - The MONACO id selects the tokenizer and is what providers register
//     against. ProjectFilesPanel's getLanguageForMonaco maps odin -> 'c' to
//     borrow C highlighting, which is fine for colouring.
//   - The LSP id is what the Hub resolves an operator's server config by
//     (lsp_server_config.odin: keyed by (bridge_id, language, dir_prefix)) and
//     what textDocument/didOpen carries. It must be the REAL language: sending
//     'c' for an Odin file would resolve to the C server, or to nothing.
// So this map is intentionally NOT getLanguageForMonaco.
const LSP_LANGUAGE_BY_EXT: Record<string, string> = {
  ts: 'typescript',
  tsx: 'typescriptreact',
  mts: 'typescript',
  cts: 'typescript',
  js: 'javascript',
  mjs: 'javascript',
  cjs: 'javascript',
  jsx: 'javascriptreact',
  py: 'python',
  pyi: 'python',
  go: 'go',
  rs: 'rust',
  rb: 'ruby',
  java: 'java',
  kt: 'kotlin',
  c: 'c',
  h: 'c',
  cpp: 'cpp',
  cc: 'cpp',
  cxx: 'cpp',
  hpp: 'cpp',
  hxx: 'cpp',
  cs: 'csharp',
  swift: 'swift',
  php: 'php',
  lua: 'lua',
  sh: 'shellscript',
  bash: 'shellscript',
  zsh: 'shellscript',
  json: 'json',
  jsonc: 'jsonc',
  yaml: 'yaml',
  yml: 'yaml',
  toml: 'toml',
  md: 'markdown',
  markdown: 'markdown',
  html: 'html',
  css: 'css',
  scss: 'scss',
  less: 'less',
  sql: 'sql',
  graphql: 'graphql',
  gql: 'graphql',
  proto: 'proto',
  nix: 'nix',
  odin: 'odin',
  zig: 'zig',
  vue: 'vue',
  svelte: 'svelte',
};

export function lspLanguageIdForPath(filePath: string): string {
  const name = String(filePath || '').toLowerCase();
  const base = name.slice(name.lastIndexOf('/') + 1);
  if (base === 'dockerfile') return 'dockerfile';
  if (base === 'makefile') return 'makefile';
  const ext = base.includes('.') ? base.slice(base.lastIndexOf('.') + 1) : '';
  return LSP_LANGUAGE_BY_EXT[ext] || '';
}
