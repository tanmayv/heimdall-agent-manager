// REQ-LSP-UI-1: wires an LspClient to the Monaco namespace already in hand.
//
// GATING IS THE FIRST THING THIS FILE DOES AND THE STRICTEST THING IT PROMISES.
// With the "lsp" experiment flag off, this hook mints no ticket, opens no
// socket, registers no provider and attaches no model listener — it returns
// before any of that exists. The editor is then byte-for-byte the editor it was
// before this feature landed: the difference is not "providers that answer
// nothing", it is no providers at all. Read the early return in the first
// effect below as the load-bearing line it is.
//
// The Hub enforces the same gate independently (lsp_session_stream_handler
// refuses the upgrade with 403 when the flag is off), so this is the first of
// two gates, not the only one.
//
// SCOPE: one language server session, bound to the ACTIVE editor tab's language.
// Switching to a file of another language tears the session down and starts the
// one that file needs. That is a deliberate simplification over a pool of
// concurrent servers: a pool multiplies bridge processes per open tab, and the
// relay gives one process per socket.

import { useEffect, useRef, useState } from 'react';

import { useFetchExperimentsQuery } from '../api/endpoints/settings';
import { LspClient, type LspClientStatus } from './lspClient';
import {
  fileUriToPath,
  lspDiagnosticToMarker,
  lspHoverToMarkdownStrings,
  lspLanguageIdForPath,
  lspToMonacoCompletionKind,
  lspToMonacoRange,
  monacoToLspPosition,
  normaliseDefinitionResult,
  pathToFileUri,
  MONACO_MARKER_SEVERITY,
  type LspCompletionItem,
  type LspCompletionList,
  type LspDiagnostic,
  type LspHover,
} from './lspProtocol';

// The experiment key the Hub gates the relay on (LSP_EXPERIMENT_KEY in
// lsp_session_handlers.odin:41). An absent key means disabled — the convention
// ExperimentalPanel.tsx already records.
const LSP_EXPERIMENT_KEY = 'lsp';

// Markers owner string. Scoped so setModelMarkers only ever clears OUR markers
// and never a future contributor's.
const MARKER_OWNER = 'heimdall-lsp';

// One textDocument/didChange per keystroke would swamp the tunnel — every
// character becomes a WS frame, a bridge write and a server reparse. 250ms is
// below the threshold where completion feels stale and far above per-keystroke.
const DID_CHANGE_DEBOUNCE_MS = 250;

export type UseMonacoLspArgs = {
  /** The monaco namespace from useMonaco(); null until it loads. */
  monaco: any;
  bridgeId: string;
  /** Absolute workspace root on the bridge host (FsListResult.root). */
  rootAbs: string;
  /** Active tab path, RELATIVE to rootAbs; '' when no file is open. */
  activePath: string;
  /** Monaco's language id for the active tab — what providers register against. */
  monacoLanguageId: string;
  /** Current editor text for the active tab. */
  content: string;
  /** Set false to keep the session down regardless of the flag (e.g. image tabs). */
  active?: boolean;
};

export type UseMonacoLspResult = {
  enabled: boolean;
  status: LspClientStatus;
  detail: string;
};

function joinAbs(rootAbs: string, relPath: string): string {
  if (!rootAbs) return relPath;
  if (!relPath) return rootAbs;
  const root = rootAbs.replace(/\/+$/, '');
  const rel = relPath.replace(/^\/+/, '');
  return `${root}/${rel}`;
}

/** Reads the "lsp" experiment flag. Absent key means disabled. */
export function useLspExperimentEnabled(): boolean {
  const { data } = useFetchExperimentsQuery();
  const flags = data?.flags ?? [];
  return flags.some((f) => f.key === LSP_EXPERIMENT_KEY && f.enabled);
}

export function useMonacoLsp({
  monaco,
  bridgeId,
  rootAbs,
  activePath,
  monacoLanguageId,
  content,
  active = true,
}: UseMonacoLspArgs): UseMonacoLspResult {
  const enabled = useLspExperimentEnabled();
  const [status, setStatus] = useState<LspClientStatus>('idle');
  const [detail, setDetail] = useState('');

  const clientRef = useRef<LspClient | null>(null);
  // Document version per URI, as textDocument/didChange requires: it must
  // increase on every change or a conforming server rejects the edit.
  const versionsRef = useRef<Map<string, number>>(new Map());
  const openUriRef = useRef<string>('');
  // Latest text, read by the debounced didChange. Held in a ref so the debounce
  // timer does not capture a stale closure of `content`.
  const contentRef = useRef(content);
  contentRef.current = content;

  const lspLanguage = activePath ? lspLanguageIdForPath(activePath) : '';
  const absPath = activePath ? joinAbs(rootAbs, activePath) : '';

  // --- session lifecycle ----------------------------------------------------
  // Keyed on the things that define WHICH server: bridge, language, root. The
  // file path is NOT a key — opening another file of the same language reuses
  // the session and only re-syncs the document.
  useEffect(() => {
    // THE GATE. Nothing below this line runs with the flag off.
    if (!enabled || !active) return;
    if (!bridgeId || !lspLanguage || !absPath) return;

    const client = new LspClient({
      bridgeId,
      language: lspLanguage,
      filePath: absPath,
      rootPath: rootAbs,
      onStatus: (s, d) => {
        setStatus(s);
        setDetail(d ?? '');
      },
      onNotification: (method, params) => {
        if (method !== 'textDocument/publishDiagnostics') return;
        const p = params as { uri?: string; diagnostics?: LspDiagnostic[] } | null;
        if (!p?.uri || !monaco) return;
        const model = findModelForPath(monaco, fileUriToPath(p.uri), rootAbs);
        if (!model) return;
        const markers = (p.diagnostics ?? []).map(lspDiagnosticToMarker);
        monaco.editor.setModelMarkers(model, MARKER_OWNER, markers);
      },
    });
    clientRef.current = client;
    versionsRef.current = new Map();
    openUriRef.current = '';
    void client.connect();

    return () => {
      clientRef.current = null;
      versionsRef.current = new Map();
      openUriRef.current = '';
      client.dispose();
      setStatus('idle');
      setDetail('');
      // Our markers outlive the session that produced them otherwise — stale
      // squiggles on a file nothing is analysing any more.
      if (monaco) {
        for (const model of monaco.editor.getModels()) {
          monaco.editor.setModelMarkers(model, MARKER_OWNER, []);
        }
      }
    };
    // monaco is intentionally a dependency: providers and markers need the
    // namespace, and it arrives asynchronously.
  }, [enabled, active, bridgeId, lspLanguage, rootAbs, monaco]);

  // --- MarkerSeverity sanity check -----------------------------------------
  // lspProtocol.ts hardcodes monaco's MarkerSeverity values to stay
  // dependency-free. If a monaco upgrade ever renumbered them, every diagnostic
  // would silently render at the wrong severity. Assert once against the live
  // enum so that failure is loud in development instead of invisible.
  useEffect(() => {
    if (!enabled || !monaco) return;
    const live = monaco.MarkerSeverity;
    if (!live) return;
    if (
      live.Hint !== MONACO_MARKER_SEVERITY.Hint ||
      live.Info !== MONACO_MARKER_SEVERITY.Info ||
      live.Warning !== MONACO_MARKER_SEVERITY.Warning ||
      live.Error !== MONACO_MARKER_SEVERITY.Error
    ) {
      // eslint-disable-next-line no-console
      console.error(
        '[heimdall-lsp] monaco.MarkerSeverity no longer matches the values hardcoded in lspProtocol.ts; diagnostics severities are wrong.'
      );
    }
  }, [monaco, enabled]);

  // --- document sync --------------------------------------------------------
  // didOpen when the active file changes; didClose for the one we leave.
  useEffect(() => {
    if (!enabled || !active) return;
    const client = clientRef.current;
    if (!client || !absPath || !lspLanguage) return;
    if (!client.isReady()) return;

    const uri = pathToFileUri(absPath);
    if (openUriRef.current === uri) return;

    if (openUriRef.current) {
      client.notify('textDocument/didClose', { textDocument: { uri: openUriRef.current } });
    }
    versionsRef.current.set(uri, 1);
    client.notify('textDocument/didOpen', {
      textDocument: { uri, languageId: lspLanguage, version: 1, text: contentRef.current },
    });
    openUriRef.current = uri;

    return () => {
      // Only the unmount//file-switch path closes the document; the session
      // teardown above handles the socket itself.
    };
  }, [enabled, active, absPath, lspLanguage, status]);

  // didChange, debounced. Full-text sync (TextDocumentSyncKind.Full) is used
  // deliberately: incremental sync needs an exact mirror of the server's buffer
  // and a single dropped or reordered delta desynchronises it silently, which
  // shows up as diagnostics pointing at the wrong lines. Full text is a few more
  // bytes per debounce window and cannot drift.
  useEffect(() => {
    if (!enabled || !active) return;
    const client = clientRef.current;
    if (!client || !client.isReady()) return;
    const uri = openUriRef.current;
    if (!uri) return;

    const timer = setTimeout(() => {
      const version = (versionsRef.current.get(uri) ?? 1) + 1;
      versionsRef.current.set(uri, version);
      client.notify('textDocument/didChange', {
        textDocument: { uri, version },
        contentChanges: [{ text: contentRef.current }],
      });
    }, DID_CHANGE_DEBOUNCE_MS);

    return () => clearTimeout(timer);
  }, [enabled, active, content, status]);

  // --- provider registration -----------------------------------------------
  // Registered only once the session is READY, and disposed together. A
  // registration that outlived its client would answer with a dead socket.
  useEffect(() => {
    if (!enabled || !active) return;
    if (!monaco || !monacoLanguageId) return;
    const client = clientRef.current;
    if (!client || status !== 'ready') return;

    // Every provider guards on the model belonging to the file this session
    // opened: providers fire for ANY model of this language, including ones this
    // server was never told about.
    const isSessionModel = (model: any): boolean => {
      const uri = pathToFileUri(joinAbs(rootAbs, modelRelPath(model)));
      return uri === openUriRef.current;
    };

    const completion = monaco.languages.registerCompletionItemProvider(monacoLanguageId, {
      provideCompletionItems: async (model: any, position: any) => {
        if (!client.isReady() || !isSessionModel(model)) return { suggestions: [] };
        try {
          const raw = await client.request('textDocument/completion', {
            textDocument: { uri: openUriRef.current },
            position: monacoToLspPosition({ lineNumber: position.lineNumber, column: position.column }),
          });
          const list = raw as LspCompletionList | LspCompletionItem[] | null;
          const items: LspCompletionItem[] = Array.isArray(list) ? list : (list?.items ?? []);
          // The replaced word, so an item without a textEdit still replaces the
          // prefix the user typed instead of appending to it.
          const word = model.getWordUntilPosition(position);
          const defaultRange = {
            startLineNumber: position.lineNumber,
            startColumn: word.startColumn,
            endLineNumber: position.lineNumber,
            endColumn: word.endColumn,
          };
          return {
            incomplete: Array.isArray(list) ? false : Boolean(list?.isIncomplete),
            suggestions: items.map((item) => ({
              label: item.label,
              kind: lspToMonacoCompletionKind(item.kind),
              detail: item.detail,
              documentation:
                typeof item.documentation === 'object' && item.documentation
                  ? { value: item.documentation.value }
                  : item.documentation,
              insertText: item.textEdit?.newText ?? item.insertText ?? item.label,
              filterText: item.filterText,
              sortText: item.sortText,
              range: item.textEdit ? lspToMonacoRange(item.textEdit.range) : defaultRange,
            })),
          };
        } catch {
          // A failed completion must never surface as an editor exception.
          return { suggestions: [] };
        }
      },
    });

    const hover = monaco.languages.registerHoverProvider(monacoLanguageId, {
      provideHover: async (model: any, position: any) => {
        if (!client.isReady() || !isSessionModel(model)) return null;
        try {
          const raw = (await client.request('textDocument/hover', {
            textDocument: { uri: openUriRef.current },
            position: monacoToLspPosition({ lineNumber: position.lineNumber, column: position.column }),
          })) as LspHover | null;
          const parts = lspHoverToMarkdownStrings(raw);
          if (parts.length === 0) return null;
          return {
            contents: parts.map((value) => ({ value })),
            ...(raw?.range ? { range: lspToMonacoRange(raw.range) } : {}),
          };
        } catch {
          return null;
        }
      },
    });

    const definition = monaco.languages.registerDefinitionProvider(monacoLanguageId, {
      provideDefinition: async (model: any, position: any) => {
        if (!client.isReady() || !isSessionModel(model)) return null;
        try {
          const raw = await client.request('textDocument/definition', {
            textDocument: { uri: openUriRef.current },
            position: monacoToLspPosition({ lineNumber: position.lineNumber, column: position.column }),
          });
          const locations = normaliseDefinitionResult(raw as any);
          return locations.map((loc) => {
            const targetPath = fileUriToPath(loc.uri);
            const existing = findModelForPath(monaco, targetPath, rootAbs);
            // A target in a file with no open model gets a monaco.Uri.file(...)
            // — Monaco opens a peek view with no contents rather than
            // navigating. Opening arbitrary files into tabs from a definition
            // jump is a panel concern, not an adapter one, and is out of scope
            // for this task.
            return {
              uri: existing ? existing.uri : monaco.Uri.file(targetPath),
              range: lspToMonacoRange(loc.range),
            };
          });
        } catch {
          return null;
        }
      },
    });

    return () => {
      completion.dispose();
      hover.dispose();
      definition.dispose();
    };
  }, [enabled, active, monaco, monacoLanguageId, rootAbs, status]);

  return { enabled, status, detail };
}

// Monaco models here are created by <Editor path={activeTab.path} />, so the
// model URI path is the project-RELATIVE tab path (with a leading slash added by
// monaco). Both helpers below work in that space.
function modelRelPath(model: any): string {
  try {
    return String(model?.uri?.path ?? '').replace(/^\/+/, '');
  } catch {
    return '';
  }
}

// Maps an absolute path from the language server back to an open Monaco model.
// Matching is on the path RELATIVE to the workspace root, because the server
// speaks absolute bridge-host paths and the models are keyed by project-relative
// ones.
function findModelForPath(monaco: any, absPath: string, rootAbs: string): any {
  if (!monaco || !absPath) return null;
  const root = rootAbs.replace(/\/+$/, '');
  const rel = root && absPath.startsWith(root + '/') ? absPath.slice(root.length + 1) : absPath.replace(/^\/+/, '');
  for (const model of monaco.editor.getModels()) {
    if (modelRelPath(model) === rel) return model;
  }
  return null;
}
