// REQ-LSP-UI-2: the identity of an LSP session — WHICH server is serving the editor.
//
// DELIBERATELY DEPENDENCY-FREE, for the same two reasons as lspProtocol.ts, plus
// a third that is specific to this module:
//
//  1. It is the unit under test. tests/ui_lsp_session_key_test.ts runs it
//     directly under `node --test` (Node strips the TS types natively), which
//     only works while this module resolves to nothing at runtime.
//  2. Keeping it a leaf means the rule can be reasoned about, and exercised,
//     without standing up an editor, a store, or a socket.
//  3. THIS IS THE THIRD REASON AND IT IS THE LOAD-BEARING ONE. The decision this
//     module makes used to live inside a React useEffect dependency array in
//     useMonacoLsp.ts. A dependency array cannot be unit-tested in this repo —
//     there is no React test renderer, no jsdom and no test runner, by design
//     (see the header of tests/ui_lsp_position_test.ts). So a defect in the
//     session key was, structurally, untestable: any test written against the
//     hook would have passed just as happily with the key reverted. Moving the
//     whole rule into a pure function is what makes it possible to reintroduce
//     the defect and watch a test fail.
//
// --- THE RULE, AND THE BUG IT EXISTS TO PREVENT ------------------------------
//
// The Hub decides which language server to run by LONGEST MATCHING dir_prefix of
// the file path (src/hub/domain/lsp_server_config.odin:31). Two files of the
// SAME language can therefore need DIFFERENT servers, with different toolchains
// and different project roots, if they live under different dir_prefix
// overrides.
//
// The session key must NOT contain the file path. Excluding it is deliberate and
// correct: opening another file of the same language inside one project must
// reuse the running server rather than pay a cold start on every tab change.
//
// The session key MUST contain the RESOLVED CONFIG ID, which is the Hub's own
// answer to "which server serves this path". That is the whole fix:
//
//   same language, same override      -> same config_id      -> SAME key, so
//                                        nothing tears down and the
//                                        optimisation above is intact
//   same language, different override -> different config_id -> DIFFERENT key,
//                                        so the old session is disposed and the
//                                        correct server starts
//
// Before this, the second case silently reused whichever server the FIRST file
// opened. It was invisible, because completions for symbols declared in the open
// buffer still look right — a server rooted anywhere can answer from the text it
// was handed in didOpen. It fails on anything needing real project context:
// cross-file navigation, imports, module and toolchain resolution. Confirmed by
// process inspection in REQ-LSP-E2E-1, not inferred from reading source.
//
// DO NOT add the file path to this key "for safety". That would restart the
// language server on every tab change and trade a silent wrong answer for a
// visible performance regression. tests/ui_lsp_session_key_test.ts has a case
// that fails if you do.

// --- reading the resolve query, which is trickier than it looks --------------
//
// REQ-LSP-UI-2 review finding D1. RTK Query's `data` is DELIBERATELY STALE
// ACROSS AN ARG CHANGE: it holds the last successful result for ANY args, not
// the result for the current ones. The installed source is explicit —
//   node_modules/@reduxjs/toolkit/dist/query/react/rtk-query-react.modern.mjs:146
//   let data = currentState.isSuccess ? currentState.data : lastResult?.data;
//
// Reading `data` therefore reintroduces THIS TASK'S OWN DEFECT through an
// ordinary failure: if the resolve for beta/main.go returns 500, `data` falls
// back to alpha's config, the session key never changes, the alpha-rooted server
// stays up, and beta is didOpened into it — silently, and for as long as the tab
// is open. Measured, not argued: with a 500 on the second file, `data` reports
// cfg_alpha, `currentData` is undefined and `isError` is true.
//
// `currentData` is the result FOR THE CURRENT ARGS, which is what a session key
// needs. Two consequences worth stating because neither is obvious:
//
//  - IN FLIGHT IS NOT THE SAME AS 404, and an earlier version of this comment
//    claimed it was. That claim held only for the FIRST resolve. `currentData`
//    makes it true in general: it is undefined while a NEVER-RESOLVED file
//    resolves, so the key is empty and no session runs against an unknown server.
//  - THE PRICE IS A TEARDOWN ON FIRST OPEN OF EACH FILE. While that first resolve
//    is in flight the key is empty, so a running session is disposed and cold
//    started. Revisiting an already-resolved file does NOT pay this: the cache
//    entry is fulfilled, `currentData` is immediate, and the key never blanks.
//    Verified against a real store, both directions.
//
// A FAILED resolve and an ABSENT config both yield no session, but the endpoint
// keeps them distinguishable on purpose (settings.ts: a dropped connection must
// not look like a deliberate absence of config). This function honours that
// distinction by consulting isError explicitly rather than inferring absence
// from a missing config.

/** The shape of the resolve response body: `{ config }`, null when none matched. */
export type LspResolvedConfigEnvelope = { config?: { config_id?: string } | null } | undefined;

export type LspResolveQueryState = {
  /**
   * RTK Query's `data`. DELIBERATELY STALE across an arg change — it may be the
   * PREVIOUS file's config. Present in this type only so the rule can be tested
   * against it; lspResolvedConfigId must never return a value derived from it.
   */
  data?: LspResolvedConfigEnvelope;
  /** RTK Query's `currentData`: the result for the CURRENT args, or undefined. */
  currentData?: LspResolvedConfigEnvelope;
  /** RTK Query's `isError`: the resolve for the current args FAILED (e.g. 500). */
  isError?: boolean;
};

/**
 * The config_id to key the session on, or '' when there is nothing to key on.
 *
 * '' is returned for a failed resolve, a resolve still in flight, and a 404 with
 * no matching config. All three mean "we do not know which server serves this
 * file", and the session key treats not knowing as no session — never as a
 * licence to keep using the server that served a different file.
 */
export function lspResolvedConfigId(state: LspResolveQueryState): string {
  // Fail closed. A 500 must not be allowed to look like a stale success.
  if (state.isError) return '';
  // currentData, NEVER data — see the note above.
  return state.currentData?.config?.config_id ?? '';
}

export type LspSessionIdentity = {
  /** The "lsp" experiment flag. False keeps the session down entirely. */
  enabled: boolean;
  /** False for tabs that must not hold a session (e.g. an image preview). */
  active: boolean;
  /** Bridge host the server runs on. */
  bridgeId: string;
  /** LSP language id, e.g. 'go'. */
  language: string;
  /** Workspace root, absolute on the bridge host. */
  rootAbs: string;
  /**
   * config_id of the server config the HUB resolved for the active file, from
   * GET /bridges/{id}/lsp-servers/resolve. Empty means unresolved — either the
   * query is still in flight, or the Hub answered 404 because nothing is
   * configured for this language and path. Both mean "no session"; see below.
   */
  configId: string;
};

/**
 * Returns the session identity as a single string, or '' when no session should
 * exist.
 *
 * THE EMPTY STRING IS THE GATE, NOT A KEY. Every reason not to have a session
 * collapses to '': flag off, tab inactive, no bridge, no language, no root, and
 * — the most-executed of them by far — no server config resolved for this file.
 * Most languages have no configured server, so 404-from-resolve is the normal
 * case rather than an error case. Folding it in here means there is no separate
 * configId variable at the call site that someone can forget to check, and no
 * way to hold a valid-looking key with no config behind it.
 *
 * A resolve still IN FLIGHT is treated exactly like a 404: configId is '', so no
 * session starts. The session starts when the answer arrives. We never open a
 * socket speculatively and let the Hub reject the start frame.
 */
export function lspSessionKey(identity: LspSessionIdentity): string {
  const { enabled, active, bridgeId, language, rootAbs, configId } = identity;
  if (!enabled || !active) return '';
  if (!bridgeId || !language || !rootAbs || !configId) return '';
  // JSON, not a delimiter join: rootAbs is an arbitrary filesystem path and may
  // contain whatever character you picked as a separator. JSON.stringify of a
  // fixed-length array of strings is unambiguous for every possible input, so no
  // two distinct identities can collide on one key.
  return JSON.stringify([bridgeId, language, rootAbs, configId]);
}

// --- WHICH SESSION RUNS vs WHICH FILE IT HAS BEEN TOLD ABOUT -----------------
//
// REQ-LSP-UI-2, second review round. Keying the session directly on the CURRENT
// file's resolution is correct but slow: `currentData` is undefined while a
// never-before-opened file resolves, so the key blanks for one render, the
// effect cleanup disposes the client, and the bridge spawns a fresh language
// server ~1ms later. MEASURED on 5 first-opens under ONE override, where the
// right answer is one server:
//     keying on the current file's resolution : 5 starts, 4 teardowns
//     holding the last resolved session       : 1 start,  0 teardowns
// A gopls cold start is ~50ms on a toy module and SECONDS of re-indexing on a
// real repository, so that difference is the feature feeling broken.
//
// THE SPLIT THAT FIXES BOTH: these are two different questions and they belong
// at two different layers.
//   WHICH SERVER RUNS    -> lspNextSession: the last SUCCESSFULLY RESOLVED
//                           session, held across a file whose resolve has not
//                           landed yet. Nothing tears down.
//   WHICH FILE IT KNOWS  -> lspFileServedBySession: a document is sent only once
//                           its OWN resolve has settled AND names the config the
//                           running session was built for.
// A file can therefore never be described to a server that does not own it, and
// a server never restarts merely because we do not know yet.

export type LspResolvedSession = {
  bridgeId: string;
  rootAbs: string;
  language: string;
  configId: string;
};

/** No session. Also what a project change collapses to — see lspNextSession. */
export const LSP_NO_SESSION: LspResolvedSession = { bridgeId: '', rootAbs: '', language: '', configId: '' };

/**
 * The session that should be running, given the previous one and the current
 * file's resolution.
 *
 *  - configId present  -> a fresh SUCCESSFUL resolution always wins.
 *  - configId empty    -> in flight, failed, or no config for this file. HOLD the
 *                         previous session: we do not know that it is wrong, only
 *                         that this file is not yet known to belong to it. The
 *                         sync gate is what keeps that safe, not a teardown.
 *  - different bridge or root -> hold NOTHING. A config_id is resolved against a
 *                         specific bridge, so carrying one into another project
 *                         would key a session on a server that does not serve
 *                         this root. Collapse to no session instead.
 *
 * Returns `prev` UNCHANGED (same object) whenever nothing moved, so a React
 * dependency on the result is stable and cannot drive a re-render loop.
 */
export function lspNextSession(
  prev: LspResolvedSession,
  current: { bridgeId: string; rootAbs: string; language: string; configId: string }
): LspResolvedSession {
  const sameProject = prev.bridgeId === current.bridgeId && prev.rootAbs === current.rootAbs;

  if (!current.configId) {
    // Unresolved: hold the previous session, but only within the same project.
    return sameProject ? prev : LSP_NO_SESSION;
  }
  if (
    sameProject &&
    prev.language === current.language &&
    prev.configId === current.configId
  ) {
    return prev; // identical — preserve identity so React sees no change.
  }
  return {
    bridgeId: current.bridgeId,
    rootAbs: current.rootAbs,
    language: current.language,
    configId: current.configId,
  };
}

/**
 * Whether the ACTIVE FILE may be described to the RUNNING session — the gate on
 * textDocument/didOpen and textDocument/didChange.
 *
 * True only when the file's own resolve has settled successfully AND named the
 * very config the running session was built for. Every other state is false:
 *
 *  - resolve IN FLIGHT      -> currentConfigId '' -> false. The session stays up
 *                              and simply is not told about this file yet.
 *  - resolve FAILED (500)   -> currentConfigId '' -> false. THIS IS THE IMPORTANT
 *                              ONE: a session is up, but a file we could not
 *                              resolve is never synced into it, so a transient
 *                              failure cannot put the wrong server back.
 *  - NO config for the file -> currentConfigId '' -> false. Opening a README in a
 *                              Go project leaves gopls running, untouched, and
 *                              does not sync the README into it.
 *  - resolved ELSEWHERE     -> ids differ -> false, until lspNextSession swaps the
 *                              session over to that config on the next render.
 */
export function lspFileServedBySession(currentConfigId: string, sessionConfigId: string): boolean {
  if (!currentConfigId || !sessionConfigId) return false;
  return currentConfigId === sessionConfigId;
}
