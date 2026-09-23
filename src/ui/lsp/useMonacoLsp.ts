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

import { useCallback, useEffect, useRef, useState } from 'react';

import { useFetchExperimentsQuery, useResolveLspServerConfigQuery } from '../api/endpoints/settings';
import { LspClient, type LspClientStatus } from './lspClient';
import {
  LSP_NO_SESSION,
  lspFileServedBySession,
  lspNextSession,
  lspResolvedConfigId,
  lspSessionKey,
  type LspResolvedSession,
} from './lspSessionKey';
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
import {
  lspServerNotice,
  lspServerNoticeKey,
  type LspServerNotice,
} from './lspServerNotice';

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
  /**
   * REQ-LSP-ENV-1: the server's own last complaint, or null when it has none.
   * Null is the normal state of a healthy session. A CALLER THAT IGNORES THIS
   * REINTRODUCES THE DEFECT — a toolchain-less server explains itself here and
   * nowhere else the user can see.
   */
  notice: LspServerNotice | null;
  /** Clears the current notice and suppresses that exact complaint if repeated. */
  dismissNotice: () => void;
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

  // REQ-LSP-ENV-1: the language server's own last complaint, or null.
  // A toolchain-less server explains itself over window/showMessage and then
  // answers every request with an error. Before this, that explanation reached
  // the browser and was dropped by the method check in onNotification below, so
  // the session looked healthy while returning nothing. See lspServerNotice.ts.
  const [notice, setNotice] = useState<LspServerNotice | null>(null);
  // Last notice shown, so a server that repeats itself does not re-alarm a user
  // who has already dismissed it. gopls re-reports the same load failure on
  // every request that touches the broken view.
  const dismissedNoticeKeyRef = useRef<string>('');

  const clientRef = useRef<LspClient | null>(null);
  // Document version per URI, as textDocument/didChange requires: it must
  // increase on every change or a conforming server rejects the edit.
  const versionsRef = useRef<Map<string, number>>(new Map());
  const openUriRef = useRef<string>('');
  // Flushes the pending debounced didChange immediately. Installed by the
  // didChange effect; null when nothing is pending. Position-sensitive requests
  // call it so the server never answers about a document it has not yet seen.
  const flushDidChangeRef = useRef<(() => void) | null>(null);
  // The exact text last sent in a didChange. Lets a pre-request sync skip when
  // the server is already in step, and keeps the debounce and the sync from
  // sending the same body twice.
  const lastSentTextRef = useRef<string>('');
  // Latest text, read by the debounced didChange. Held in a ref so the debounce
  // timer does not capture a stale closure of `content`.
  const contentRef = useRef(content);
  contentRef.current = content;

  const lspLanguage = activePath ? lspLanguageIdForPath(activePath) : '';
  const absPath = activePath ? joinAbs(rootAbs, activePath) : '';

  // --- which server serves this file ----------------------------------------
  // REQ-LSP-UI-2. Asks the Hub to run its own resolver over (bridge, language,
  // absPath) and tell us the config_id it picked. We ask rather than compute
  // because the Hub's rule has a path-boundary subtlety and two implementations
  // of one rule drift; see the header of lspSessionKey.ts.
  //
  // This is cached per (bridgeId, language, path), so it is one request per
  // DISTINCT FILE opened — not one per project, and not one per tab switch back
  // to a file already visited, which is served from cache with no network.
  // heimdallApi sets keepUnusedDataFor: 30 (heimdallApi.ts:101), so a file left
  // unopened for more than 30s costs one more resolve when you return to it.
  const resolveState = useResolveLspServerConfigQuery(
    { bridgeId, language: lspLanguage, path: absPath },
    { skip: !enabled || !active || !bridgeId || !lspLanguage || !absPath }
  );
  // MUST go through lspResolvedConfigId, which reads `currentData` and consults
  // `isError`. Reading `resolveState.data` here would be this task's own defect:
  // RTK Query's `data` is stale across an arg change, so a failed resolve for the
  // NEW file would silently keep the PREVIOUS file's config and leave the wrong
  // server serving it. That module owns the rule and the tests that pin it.
  //
  // '' covers: skipped, in flight, resolve FAILED, and the Hub answered 404
  // because nothing is configured for this language and path. All of them mean
  // "we do not know which server serves this file" — lspSessionKey folds them
  // into one empty key, and an empty key means no session.
  const lspConfigId = lspResolvedConfigId(resolveState);

  // --- session lifecycle ----------------------------------------------------
  // KEYED ON WHICH SERVER, WHICH IS NOT THE SAME AS WHICH FILE.
  //
  // The key is bridge + language + root + the config_id the HUB RESOLVED for the
  // active file. The file path is deliberately NOT part of it: opening another
  // file of the same language inside one project resolves to the same config_id,
  // produces a byte-identical key, and therefore reuses the running session
  // instead of paying a cold start on every tab change.
  //
  // The config_id is what stops that reuse from being WRONG. Two same-language
  // files under different dir_prefix overrides resolve to different configs and
  // genuinely need different servers; keying on the resolved config restarts the
  // session exactly when an override boundary is crossed, and never merely
  // because the file changed. Empty key means no session at all — see
  // lspSessionKey.ts, which owns this rule and is where its tests point.
  //
  // MEASURE AFTER TOUCHING THIS. DO NOT TRUST A GREEN SUITE ALONE.
  // This effect has already shipped one defect that every test passed straight
  // through, and the shape is worth knowing because it will recur here. Keying
  // the session on the CURRENT file's resolution is a perfectly correct RULE —
  // the discriminator test in ui_lsp_session_key_test.ts stayed green under it —
  // and it still cost 5 language-server starts where 1 was right, because the
  // key blanked for a single render while each new file resolved. The defect did
  // not live in the rule. It lived in the SEQUENCE OF RENDERS, which a test of a
  // pure function cannot see and a measurement finds immediately.
  // The sequence test in that file is an attempt to pin the common cases as
  // ordered data; it is not React, and it does not remove the need to count
  // actual session starts when you change what this effect keys on.
  // WHICH SERVER RUNS — the session is held across a file whose resolve has not
  // landed yet, so opening a never-before-opened file does NOT tear the server
  // down. lspNextSession owns that rule; it returns the previous object
  // unchanged when nothing moved, which is what keeps this effect from looping.
  const [session, setSession] = useState<LspResolvedSession>(LSP_NO_SESSION);
  useEffect(() => {
    setSession((prev) => lspNextSession(prev, {
      bridgeId,
      rootAbs,
      language: lspLanguage,
      configId: lspConfigId,
    }));
  }, [bridgeId, rootAbs, lspLanguage, lspConfigId]);

  const sessionKey = lspSessionKey({
    enabled,
    active,
    bridgeId: session.bridgeId,
    language: session.language,
    rootAbs: session.rootAbs,
    configId: session.configId,
  });

  // WHICH FILE THE SERVER HAS BEEN TOLD ABOUT — the gate on didOpen/didChange.
  // False while this file's own resolve is in flight, false if it FAILED, and
  // false if it resolved to a different config than the one running. A document
  // is never described to a server that does not own it.
  const fileServed = lspFileServedBySession(lspConfigId, session.configId);

  useEffect(() => {
    // THE GATE. Nothing below this line runs with the flag off — an empty
    // sessionKey is exactly that gate, plus every other reason not to connect.
    if (!sessionKey) return;

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
        // REQ-LSP-ENV-1. THIS WAS ONE LINE — `if (method !== 'textDocument/
        // publishDiagnostics') return;` — and it was the entire discard. Every
        // server-initiated notification that was not a diagnostic died here,
        // including the one where a toolchain-less gopls says, in band, exactly
        // what is wrong with it. The user saw a green session answering nothing.
        // Diagnostics keep their original path unchanged; everything else now
        // gets a look before it is dropped.
        if (method !== 'textDocument/publishDiagnostics') {
          const next = lspServerNotice(method, params);
          if (!next) return;
          // Dedupe against what the user already dismissed, not against the
          // previous notice: a repeat they have NOT dismissed should still show.
          if (lspServerNoticeKey(next) === dismissedNoticeKeyRef.current) return;
          setNotice(next);
          return;
        }
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
      // A complaint belongs to the session that produced it. Carrying it across
      // a restart would pin a stale "go not found" banner over a server that has
      // since been fixed and restarted — the mirror of the stale-markers bug the
      // block below already guards against.
      setNotice(null);
      dismissedNoticeKeyRef.current = '';
      // Our markers outlive the session that produced them otherwise — stale
      // squiggles on a file nothing is analysing any more.
      if (monaco) {
        for (const model of monaco.editor.getModels()) {
          monaco.editor.setModelMarkers(model, MARKER_OWNER, []);
        }
      }
    };
    // sessionKey carries enabled/active/bridgeId/lspLanguage/rootAbs and the
    // resolved config_id, so it is the whole session identity in one value.
    // absPath is NOT here and must not be: see lspSessionKey.ts.
    // monaco is intentionally a dependency: providers and markers need the
    // namespace, and it arrives asynchronously.
  }, [sessionKey, monaco]);

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
    // THE SYNC GATE. Until this file's own resolve says it belongs to the running
    // server, it is not described to it — see lspFileServedBySession.
    if (!fileServed) return;

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
  }, [enabled, active, absPath, lspLanguage, status, fileServed]);

  // didChange, debounced. Full-text sync (TextDocumentSyncKind.Full) is used
  // deliberately: incremental sync needs an exact mirror of the server's buffer
  // and a single dropped or reordered delta desynchronises it silently, which
  // shows up as diagnostics pointing at the wrong lines. Full text is a few more
  // bytes per debounce window and cannot drift.
  useEffect(() => {
    if (!enabled || !active) return;
    const client = clientRef.current;
    if (!client || !client.isReady()) return;
    // Gated for a reason that is NOT obvious: this effect takes its URI from
    // openUriRef and its TEXT from contentRef. While a newly opened file is still
    // resolving, openUriRef still names the PREVIOUS file but contentRef already
    // holds the new one, so an ungated keystroke would send the new file's body
    // under the old file's URI and corrupt that document on the server.
    if (!fileServed) return;
    const uri = openUriRef.current;
    if (!uri) return;

    const send = () => {
      const version = (versionsRef.current.get(uri) ?? 1) + 1;
      versionsRef.current.set(uri, version);
      lastSentTextRef.current = contentRef.current;
      client.notify('textDocument/didChange', {
        textDocument: { uri, version },
        contentChanges: [{ text: contentRef.current }],
      });
    };

    const timer = setTimeout(() => {
      if (flushDidChangeRef.current === flush) flushDidChangeRef.current = null;
      send();
    }, DID_CHANGE_DEBOUNCE_MS);

    // THE DEBOUNCE MUST NOT OUTRANK A REQUEST THAT DEPENDS ON IT. Monaco fires
    // completion/hover/definition the instant a trigger or word character is
    // typed, which is always INSIDE this 250ms window — so without a flush the
    // server is asked about a position in a document it has not been told about
    // yet. It then answers for the stale buffer and Monaco falls back to its own
    // word list, which looks exactly like "the language server is dead".
    // Measured: completion went out 279ms AHEAD of the didChange describing the
    // text it was asking about, and the suggest widget showed file word
    // fragments; flushing first returns real gopls symbols for the same edit.
    const flush = () => {
      clearTimeout(timer);
      if (flushDidChangeRef.current === flush) flushDidChangeRef.current = null;
      send();
    };
    flushDidChangeRef.current = flush;

    return () => {
      clearTimeout(timer);
      // Only disown the flush if it is still ours: a newer effect may already
      // have installed its own.
      if (flushDidChangeRef.current === flush) flushDidChangeRef.current = null;
    };
  }, [enabled, active, content, status, fileServed]);

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

    // Pushes the model's CURRENT text to the server immediately, cancelling any
    // pending debounced send so the two cannot fight. A no-op when the server is
    // already in step, so ordinary typing still costs one debounced send.
    const syncModelNow = (model: any) => {
      const uri = openUriRef.current;
      if (!uri || !client.isReady()) return;
      let text: string;
      try {
        text = String(model.getValue());
      } catch {
        return;
      }
      if (text === lastSentTextRef.current) return;
      flushDidChangeRef.current = null; // the debounce's body is now stale
      const version = (versionsRef.current.get(uri) ?? 1) + 1;
      versionsRef.current.set(uri, version);
      lastSentTextRef.current = text;
      client.notify('textDocument/didChange', {
        textDocument: { uri, version },
        contentChanges: [{ text }],
      });
    };

    // TRIGGER CHARACTERS COME FROM THE SERVER, NOT FROM US. Without this Monaco
    // only consults the provider on word characters, so completion after a DOT
    // (`http.`, `strings.`) never reaches the language server at all and the user
    // silently gets Monaco's built-in word list instead — indistinguishable from
    // "LSP is dead", which is exactly how it was reported. gopls advertises what
    // it wants in its initialize response; hardcoding "." would be a guess that
    // is wrong for other languages.
    const triggerCharacters: string[] = Array.isArray(
      client.getCapabilities()?.completionProvider?.triggerCharacters,
    )
      ? client.getCapabilities().completionProvider.triggerCharacters
      : [];

    const completion = monaco.languages.registerCompletionItemProvider(monacoLanguageId, {
      triggerCharacters,
      provideCompletionItems: async (model: any, position: any) => {
        if (!client.isReady() || !isSessionModel(model)) return { suggestions: [] };
        // Sync the buffer BEFORE asking about a position in it. Read the text
        // from the MODEL, not from React state: Monaco fires this provider
        // synchronously on the keystroke, before React has re-rendered with the
        // new `content`, so a flush of the debounced effect would have nothing
        // pending yet and would send the PREVIOUS text. The model is the only
        // source that is already current at this instant. Measured before this
        // fix: completion went out 278ms ahead of the didChange describing the
        // text it asked about, and the suggest widget showed word fragments
        // instead of gopls symbols.
        syncModelNow(model);
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

  // REQ-LSP-ENV-1: dismissing records the notice's identity, so the same text
  // repeated by a server that keeps failing stays dismissed, while a DIFFERENT
  // complaint still gets through.
  const dismissNotice = useCallback(() => {
    setNotice((current) => {
      if (current) dismissedNoticeKeyRef.current = lspServerNoticeKey(current);
      return null;
    });
  }, []);

  // CALLERS MUST USE THIS RETURN VALUE. ProjectFilesPanel.tsx called this hook as
  // a bare statement for its whole life, so `status` and `detail` were computed
  // and dropped on the floor — which is why routing the server's complaint into
  // `detail` would have reproduced this task's own defect instead of fixing it.
  return { enabled, status, detail, notice, dismissNotice };
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
