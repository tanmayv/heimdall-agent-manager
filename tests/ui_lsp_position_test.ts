// REQ-LSP-UI-1: executable unit tests for the LSP <-> Monaco converters.
//
// RUN:  node --test tests/ui_lsp_position_test.ts
// (Node 24 strips TypeScript types natively — no test runner, no dependency, no
// build step. The module under test imports nothing, which is what makes this
// possible; see the header of src/ui/lsp/lspProtocol.ts.)
//
// WHY THESE ASSERTIONS LOOK REDUNDANT AND ARE NOT.
// Every expected value below is a LITERAL, pinned to the specification that
// defines it — never computed from another converter in the module under test.
// That is the whole design of this file:
//
//   A round-trip test (LSP -> Monaco -> LSP) proves the two functions are
//   INVERSES OF EACH OTHER. That is strictly weaker than either being correct.
//   An off-by-one present in BOTH directions cancels exactly, and a round-trip
//   suite stays green while every position in the editor is wrong by a line.
//
// So each direction is anchored independently against absolute known-good
// values: LSP {line:0,character:0} IS Monaco {lineNumber:1,column:1}, because
// LSP is 0-based and Monaco is 1-based. The round-trip test at the end is kept
// as a bonus property, explicitly labelled as insufficient on its own.
//
// SOURCES FOR THE LITERALS (read, not remembered):
//   - LSP 3.17 spec: CompletionItemKind 1..25, DiagnosticSeverity 1..4.
//   - node_modules/monaco-editor/esm/vs/editor/editor.api.d.ts @ 0.45.0:
//     MarkerSeverity (line 90) and languages.CompletionItemKind (line 6723),
//     verified against the installed package at the time of writing.

import { test } from 'node:test';
import assert from 'node:assert/strict';

import {
  fileUriToPath,
  lspDiagnosticToMarker,
  lspHoverToMarkdownStrings,
  lspLanguageIdForPath,
  lspToMonacoCompletionKind,
  lspToMonacoPosition,
  lspToMonacoRange,
  lspToMonacoSeverity,
  monacoToLspPosition,
  monacoToLspRange,
  normaliseDefinitionResult,
  pathToFileUri,
  isJsonRpcNotification,
  isJsonRpcResponse,
  isJsonRpcServerRequest,
} from '../src/ui/lsp/lspProtocol.ts';

// --- positions: each direction anchored on its own ---------------------------

test('lspToMonacoPosition anchors the origin: LSP 0,0 is Monaco 1,1', () => {
  assert.deepEqual(lspToMonacoPosition({ line: 0, character: 0 }), { lineNumber: 1, column: 1 });
});

test('lspToMonacoPosition shifts both axes by exactly one', () => {
  assert.deepEqual(lspToMonacoPosition({ line: 4, character: 9 }), { lineNumber: 5, column: 10 });
  assert.deepEqual(lspToMonacoPosition({ line: 41, character: 0 }), { lineNumber: 42, column: 1 });
  assert.deepEqual(lspToMonacoPosition({ line: 0, character: 7 }), { lineNumber: 1, column: 8 });
});

test('monacoToLspPosition anchors the origin: Monaco 1,1 is LSP 0,0', () => {
  assert.deepEqual(monacoToLspPosition({ lineNumber: 1, column: 1 }), { line: 0, character: 0 });
});

test('monacoToLspPosition shifts both axes by exactly one', () => {
  assert.deepEqual(monacoToLspPosition({ lineNumber: 5, column: 10 }), { line: 4, character: 9 });
  assert.deepEqual(monacoToLspPosition({ lineNumber: 42, column: 1 }), { line: 41, character: 0 });
});

// The specific defect this pins: a converter that shifts the line but forgets
// the column (or vice versa) is the most common hand-written-adapter bug, and it
// survives any test that only ever moves one axis at a time.
test('both axes convert — a shift on only one axis is caught', () => {
  const monaco = lspToMonacoPosition({ line: 3, character: 3 });
  assert.equal(monaco.lineNumber, 4, 'line must shift');
  assert.equal(monaco.column, 4, 'column must shift too');
});

// --- ranges ------------------------------------------------------------------

test('lspToMonacoRange converts all four endpoints, start and end independently', () => {
  assert.deepEqual(
    lspToMonacoRange({ start: { line: 0, character: 0 }, end: { line: 2, character: 5 } }),
    { startLineNumber: 1, startColumn: 1, endLineNumber: 3, endColumn: 6 }
  );
});

test('monacoToLspRange converts all four endpoints back', () => {
  assert.deepEqual(
    monacoToLspRange({ startLineNumber: 1, startColumn: 1, endLineNumber: 3, endColumn: 6 }),
    { start: { line: 0, character: 0 }, end: { line: 2, character: 5 } }
  );
});

// A range whose endpoints were swapped, or whose end reused the start values,
// passes a careless test that uses the same numbers on both ends.
test('range endpoints are not interchangeable', () => {
  const r = lspToMonacoRange({ start: { line: 10, character: 2 }, end: { line: 11, character: 30 } });
  assert.equal(r.startLineNumber, 11);
  assert.equal(r.endLineNumber, 12);
  assert.equal(r.startColumn, 3);
  assert.equal(r.endColumn, 31);
});

// --- diagnostic severity: two unrelated scales -------------------------------
// LSP DiagnosticSeverity: 1 Error, 2 Warning, 3 Information, 4 Hint (ascending
// = less severe). Monaco MarkerSeverity: 1 Hint, 2 Info, 4 Warning, 8 Error
// (ascending = MORE severe). They run in opposite directions, so a pass-through
// turns every error into a hint.

test('lspToMonacoSeverity maps each LSP severity to the Monaco value from the spec', () => {
  assert.equal(lspToMonacoSeverity(1), 8, 'LSP Error -> Monaco Error');
  assert.equal(lspToMonacoSeverity(2), 4, 'LSP Warning -> Monaco Warning');
  assert.equal(lspToMonacoSeverity(3), 2, 'LSP Information -> Monaco Info');
  assert.equal(lspToMonacoSeverity(4), 1, 'LSP Hint -> Monaco Hint');
});

test('lspToMonacoSeverity is not a pass-through', () => {
  // The exact failure a naive `severity ?? 1` cast produces: LSP Error (1)
  // would surface as Monaco Hint (1) — an invisible squiggle on a real error.
  assert.notEqual(lspToMonacoSeverity(1), 1);
});

test('absent severity surfaces as Error, not as a silent hint', () => {
  assert.equal(lspToMonacoSeverity(undefined), 8);
});

test('lspDiagnosticToMarker carries range, severity, message, source and code', () => {
  const marker = lspDiagnosticToMarker({
    range: { start: { line: 0, character: 0 }, end: { line: 0, character: 4 } },
    severity: 2,
    code: 'E123',
    source: 'gopls',
    message: 'undefined: foo',
  });
  assert.equal(marker.startLineNumber, 1);
  assert.equal(marker.startColumn, 1);
  assert.equal(marker.endLineNumber, 1);
  assert.equal(marker.endColumn, 5);
  assert.equal(marker.severity, 4, 'Warning');
  assert.equal(marker.message, 'undefined: foo');
  assert.equal(marker.source, 'gopls');
  assert.equal(marker.code, 'E123');
});

test('lspDiagnosticToMarker stringifies a numeric code', () => {
  const marker = lspDiagnosticToMarker({
    range: { start: { line: 1, character: 1 }, end: { line: 1, character: 2 } },
    code: 2304,
    message: 'x',
  });
  assert.equal(marker.code, '2304');
});

// --- completion kinds: two enums that share no numbering ---------------------
// Left column = LSP 3.17 CompletionItemKind. Right column = monaco 0.45
// languages.CompletionItemKind. Both transcribed from their definitions.

test('lspToMonacoCompletionKind maps every LSP kind to the Monaco value', () => {
  const expected: Array<[number, number, string]> = [
    [1, 18, 'Text'],
    [2, 0, 'Method'],
    [3, 1, 'Function'],
    [4, 2, 'Constructor'],
    [5, 3, 'Field'],
    [6, 4, 'Variable'],
    [7, 5, 'Class'],
    [8, 7, 'Interface'],
    [9, 8, 'Module'],
    [10, 9, 'Property'],
    [11, 12, 'Unit'],
    [12, 13, 'Value'],
    [13, 15, 'Enum'],
    [14, 17, 'Keyword'],
    [15, 27, 'Snippet'],
    [16, 19, 'Color'],
    [17, 20, 'File'],
    [18, 21, 'Reference'],
    [19, 23, 'Folder'],
    [20, 16, 'EnumMember'],
    [21, 14, 'Constant'],
    [22, 6, 'Struct'],
    [23, 10, 'Event'],
    [24, 11, 'Operator'],
    [25, 24, 'TypeParameter'],
  ];
  for (const [lsp, monaco, name] of expected) {
    assert.equal(lspToMonacoCompletionKind(lsp), monaco, `LSP ${name}(${lsp}) -> Monaco ${monaco}`);
  }
});

test('completion kinds are genuinely renumbered, not passed through', () => {
  // If this ever passes trivially the map has been replaced by identity.
  const identical = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10].filter((k) => lspToMonacoCompletionKind(k) === k);
  assert.ok(identical.length < 10, 'a pass-through map would leave every kind unchanged');
});

test('unknown or absent completion kind falls back to Text rather than throwing', () => {
  assert.equal(lspToMonacoCompletionKind(undefined), 18);
  assert.equal(lspToMonacoCompletionKind(999), 18);
});

// --- hover normalisation -----------------------------------------------------

test('hover accepts MarkupContent', () => {
  assert.deepEqual(
    lspHoverToMarkdownStrings({ contents: { kind: 'markdown', value: '**doc**' } }),
    ['**doc**']
  );
});

test('hover accepts a bare MarkedString', () => {
  assert.deepEqual(lspHoverToMarkdownStrings({ contents: 'plain text' }), ['plain text']);
});

test('hover rebuilds a fenced code block for {language, value}', () => {
  assert.deepEqual(
    lspHoverToMarkdownStrings({ contents: { language: 'go', value: 'func Foo()' } }),
    ['```go\nfunc Foo()\n```']
  );
});

test('hover accepts a MarkedString[] and drops empties', () => {
  assert.deepEqual(
    lspHoverToMarkdownStrings({ contents: ['one', { language: 'ts', value: 'x' }, ''] }),
    ['one', '```ts\nx\n```']
  );
});

test('hover tolerates null and an absent contents field', () => {
  assert.deepEqual(lspHoverToMarkdownStrings(null), []);
  assert.deepEqual(lspHoverToMarkdownStrings(undefined), []);
});

// --- definition normalisation ------------------------------------------------

test('definition accepts a single Location', () => {
  const range = { start: { line: 1, character: 2 }, end: { line: 1, character: 5 } };
  assert.deepEqual(normaliseDefinitionResult({ uri: 'file:///a.go', range }), [
    { uri: 'file:///a.go', range },
  ]);
});

test('definition accepts a Location[]', () => {
  const range = { start: { line: 0, character: 0 }, end: { line: 0, character: 1 } };
  const out = normaliseDefinitionResult([
    { uri: 'file:///a.go', range },
    { uri: 'file:///b.go', range },
  ]);
  assert.equal(out.length, 2);
  assert.equal(out[1].uri, 'file:///b.go');
});

test('definition prefers targetSelectionRange over targetRange for a LocationLink', () => {
  const targetRange = { start: { line: 10, character: 0 }, end: { line: 20, character: 0 } };
  const targetSelectionRange = { start: { line: 10, character: 5 }, end: { line: 10, character: 8 } };
  const out = normaliseDefinitionResult([{ targetUri: 'file:///a.go', targetRange, targetSelectionRange }]);
  assert.deepEqual(out, [{ uri: 'file:///a.go', range: targetSelectionRange }]);
});

test('definition falls back to targetRange when there is no selection range', () => {
  const targetRange = { start: { line: 3, character: 0 }, end: { line: 4, character: 0 } };
  const out = normaliseDefinitionResult([{ targetUri: 'file:///a.go', targetRange }]);
  assert.deepEqual(out, [{ uri: 'file:///a.go', range: targetRange }]);
});

test('definition returns an empty list for null', () => {
  assert.deepEqual(normaliseDefinitionResult(null), []);
});

// --- uri <-> path ------------------------------------------------------------

test('pathToFileUri produces a file: URI and preserves separators', () => {
  assert.equal(pathToFileUri('/home/u/p/main.go'), 'file:///home/u/p/main.go');
});

test('pathToFileUri escapes characters that are illegal in a URI', () => {
  assert.equal(pathToFileUri('/home/u/my file.go'), 'file:///home/u/my%20file.go');
});

test('fileUriToPath is anchored on absolute values, not only on round-tripping', () => {
  assert.equal(fileUriToPath('file:///home/u/p/main.go'), '/home/u/p/main.go');
  assert.equal(fileUriToPath('file:///home/u/my%20file.go'), '/home/u/my file.go');
});

// --- language ids ------------------------------------------------------------
// The LSP id is what the Hub resolves an operator's server config by. It must be
// the real language, NOT the Monaco tokenizer id — ProjectFilesPanel maps Odin
// to 'c' to borrow C highlighting, and sending that would resolve the C server.

test('lspLanguageIdForPath reports the real language, not the Monaco tokenizer id', () => {
  assert.equal(lspLanguageIdForPath('/p/main.odin'), 'odin');
  assert.equal(lspLanguageIdForPath('/p/main.zig'), 'zig');
});

test('lspLanguageIdForPath uses standard LSP ids', () => {
  assert.equal(lspLanguageIdForPath('/p/a.ts'), 'typescript');
  assert.equal(lspLanguageIdForPath('/p/a.tsx'), 'typescriptreact');
  assert.equal(lspLanguageIdForPath('/p/a.py'), 'python');
  assert.equal(lspLanguageIdForPath('/p/a.go'), 'go');
  assert.equal(lspLanguageIdForPath('/p/a.sh'), 'shellscript');
});

test('lspLanguageIdForPath handles extensionless well-known names', () => {
  assert.equal(lspLanguageIdForPath('/p/Dockerfile'), 'dockerfile');
  assert.equal(lspLanguageIdForPath('/p/Makefile'), 'makefile');
});

test('lspLanguageIdForPath returns empty for an unknown extension', () => {
  // Empty is the signal that keeps the session down: no language, no server.
  assert.equal(lspLanguageIdForPath('/p/notes.xyz'), '');
  assert.equal(lspLanguageIdForPath(''), '');
});

// --- JSON-RPC message classification -----------------------------------------
// A server REQUEST (id + method) must never be mistaken for a RESPONSE to one of
// ours. The id spaces are independent, so a server request with id 1 would
// otherwise resolve our own request 1 with garbage.

test('a response is id without method', () => {
  assert.equal(isJsonRpcResponse({ jsonrpc: '2.0', id: 1, result: {} }), true);
  assert.equal(isJsonRpcServerRequest({ jsonrpc: '2.0', id: 1, result: {} }), false);
  assert.equal(isJsonRpcNotification({ jsonrpc: '2.0', id: 1, result: {} }), false);
});

test('a server request is id WITH method and is not treated as a response', () => {
  const msg = { jsonrpc: '2.0' as const, id: 1, method: 'window/workDoneProgress/create' };
  assert.equal(isJsonRpcServerRequest(msg), true);
  assert.equal(isJsonRpcResponse(msg), false, 'would resolve our own request id 1 with garbage');
});

test('a notification is method without id', () => {
  const msg = { jsonrpc: '2.0' as const, method: 'textDocument/publishDiagnostics', params: {} };
  assert.equal(isJsonRpcNotification(msg), true);
  assert.equal(isJsonRpcResponse(msg), false);
});

test('an error response is still a response', () => {
  const msg = { jsonrpc: '2.0' as const, id: 7, error: { code: -32601, message: 'nope' } };
  assert.equal(isJsonRpcResponse(msg), true);
});

// --- round trip, kept only as a bonus property -------------------------------

test('round trip composes to identity — NOTE: insufficient on its own', () => {
  // This test would still pass if BOTH directions were wrong by the same
  // amount. It is here to catch asymmetric edits, not to establish
  // correctness; the anchored tests above are what do that.
  for (const p of [
    { line: 0, character: 0 },
    { line: 1, character: 0 },
    { line: 99, character: 42 },
  ]) {
    assert.deepEqual(monacoToLspPosition(lspToMonacoPosition(p)), p);
  }
});
