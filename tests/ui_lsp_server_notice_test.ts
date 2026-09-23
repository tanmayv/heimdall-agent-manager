// REQ-LSP-ENV-1: executable unit tests for the language-server notice filter.
//
// RUN:  node --test tests/ui_lsp_server_notice_test.ts
// (Node 24 strips TypeScript types natively — no test runner, no dependency, no
// build step. The module under test imports nothing, which is what makes this
// possible; same arrangement as tests/ui_lsp_session_key_test.ts.)
//
// THE DEFECT THESE TESTS EXIST FOR, as observed by the USER across two failed
// test rounds — not inferred. A gopls with no `go` on PATH started cleanly,
// completed the handshake, and answered every textDocument/completion with
// error {code:0, message:"no views"} while the UI showed a healthy session. The
// server was not silent about it. It said, over window/showMessage:
//     type=3 "Error loading packages: go command required, not found:
//             exec: \"go\": executable file not found in $PATH"
//     type=1 "Error loading workspace folders (expected 1, got 0)"
// Both frames were relayed intact by the bridge (lsp_session.odin:485-492 wraps
// every parsed message with no method inspection) and both reached the browser.
// Both were then discarded by a single line in useMonacoLsp.ts:
//     if (method !== 'textDocument/publishDiagnostics') return;
//
// WHY THIS IS A FUNCTION TEST AND NOT A HOOK TEST. This repo has no React test
// renderer, no jsdom and no test runner, deliberately — so hook internals are
// structurally untestable here and a test written against the hook would pass
// just as happily with the defect present. The RULE therefore lives in the pure
// lspServerNotice(), which the hook only calls. Reintroducing the defect in that
// function makes these tests fail. See the VERIFICATION BOUNDARY at the bottom
// for what that does and does not cover.

import { test } from 'node:test';
import assert from 'node:assert/strict';

import {
  LSP_MESSAGE_TYPE,
  lspNextNotices,
  lspServerNotice,
  lspServerNoticeKey,
} from '../src/ui/lsp/lspServerNotice.ts';

// The two frames from the repro, VERBATIM. These are the payloads the user's
// dead session actually produced.
const GOPLS_CAUSE =
  'Error loading packages: go command required, not found: exec: "go": executable file not found in $PATH';
const GOPLS_SYMPTOM = 'Error loading workspace folders (expected 1, got 0)';

// --- the repro: both frames must survive the filter -------------------------

test('the gopls CAUSE frame survives — this is the whole point of the task', () => {
  // NOTE THE SEVERITY: the sentence that names the missing binary, the only one
  // a user can act on, arrives at type=3 (Info). A type<=2 gate would drop it
  // and keep only the symptom below. That is why this module gates on CHANNEL,
  // not severity. If someone "tidies" the gate to type<=2, THIS test fails.
  const notice = lspServerNotice('window/showMessage', {
    type: LSP_MESSAGE_TYPE.Info,
    message: GOPLS_CAUSE,
  });
  assert.ok(notice, 'the toolchain-less cause message must not be discarded');
  assert.equal(notice.text, GOPLS_CAUSE, 'the server\'s own words, unmodified');
  assert.equal(notice.level, 'info', 'Info renders at lower weight, but IS shown');
  assert.match(notice.text, /go command required/, 'the actionable phrase is intact');
  assert.match(notice.text, /\$PATH/, 'the reason is intact and untruncated');
});

test('the gopls SYMPTOM frame survives as an error', () => {
  const notice = lspServerNotice('window/showMessage', {
    type: LSP_MESSAGE_TYPE.Error,
    message: GOPLS_SYMPTOM,
  });
  assert.ok(notice);
  assert.equal(notice.level, 'error');
  assert.equal(notice.text, GOPLS_SYMPTOM);
});

test('rust-analyzer without cargo has the same shape and is also surfaced', () => {
  const notice = lspServerNotice('window/showMessage', {
    type: LSP_MESSAGE_TYPE.Error,
    message: 'rust-analyzer failed to discover workspace: cargo not found in PATH',
  });
  assert.ok(notice);
  assert.equal(notice.level, 'error');
  assert.match(notice.text, /cargo not found/);
});

// --- the healthy path must NOT be flooded -----------------------------------
// The other half of the acceptance criteria: a working server emits routine
// traffic and must not turn the editor into a notification feed.

test('window/logMessage below Error is dropped — this is where the firehose is', () => {
  // gopls and rust-analyzer both log continuously at Info and below on a
  // perfectly healthy session. Admitting these would spam every user.
  for (const type of [LSP_MESSAGE_TYPE.Warning, LSP_MESSAGE_TYPE.Info, LSP_MESSAGE_TYPE.Log, LSP_MESSAGE_TYPE.Debug]) {
    assert.equal(
      lspServerNotice('window/logMessage', { type, message: 'go/packages.Load ... completed in 1.2s' }),
      null,
      `logMessage type=${type} must be dropped`
    );
  }
});

test('window/logMessage at Error IS surfaced', () => {
  const notice = lspServerNotice('window/logMessage', {
    type: LSP_MESSAGE_TYPE.Error,
    message: 'internal error: panic recovered',
  });
  assert.ok(notice);
  assert.equal(notice.level, 'error');
});

test('showMessage at Log/Debug is dropped', () => {
  for (const type of [LSP_MESSAGE_TYPE.Log, LSP_MESSAGE_TYPE.Debug]) {
    assert.equal(
      lspServerNotice('window/showMessage', { type, message: 'verbose detail' }),
      null,
      `showMessage type=${type} must be dropped`
    );
  }
});

test('routine server-initiated traffic is ignored entirely', () => {
  // These are the methods a healthy session emits constantly. Before the fix
  // they were dropped by the publishDiagnostics check; they must STILL be
  // dropped, or the fix trades a silent failure for an unusable editor.
  const routine = [
    ['$/progress', { token: 'x', value: { kind: 'report', message: 'loading' } }],
    ['window/workDoneProgress/create', { token: 'x' }],
    ['telemetry/event', { data: 1 }],
    ['client/registerCapability', { registrations: [] }],
    ['textDocument/publishDiagnostics', { uri: 'file:///a.go', diagnostics: [] }],
  ] as const;
  for (const [method, params] of routine) {
    assert.equal(lspServerNotice(method, params), null, `${method} must be ignored`);
  }
});

test('publishDiagnostics is never converted into a notice', () => {
  // It has its own rendering path (monaco markers). Surfacing it here too would
  // double-report every squiggle as a banner.
  assert.equal(
    lspServerNotice('textDocument/publishDiagnostics', {
      uri: 'file:///a.go',
      diagnostics: [{ message: 'undefined: foo' }],
    }),
    null
  );
});

// --- malformed input --------------------------------------------------------

test('empty, whitespace and non-string messages yield nothing to show', () => {
  for (const message of ['', '   ', '\n\t ', null, undefined, 42, {}]) {
    assert.equal(
      lspServerNotice('window/showMessage', { type: LSP_MESSAGE_TYPE.Error, message }),
      null,
      `message ${JSON.stringify(message)} must not produce an empty banner`
    );
  }
});

test('absent params does not throw', () => {
  assert.equal(lspServerNotice('window/showMessage', null), null);
  assert.equal(lspServerNotice('window/showMessage', undefined), null);
  assert.equal(lspServerNotice('', { type: 1, message: 'x' }), null);
});

test('a missing type on the SHOW channel is surfaced, not swallowed', () => {
  // `type` is required by the spec, so its absence is malformed. The safe
  // failure direction for THIS defect is to show it: the entire bug was a
  // server's explanation being silently dropped.
  const notice = lspServerNotice('window/showMessage', { message: 'something is broken' });
  assert.ok(notice, 'a malformed show frame must not vanish');
  assert.equal(notice.level, 'error');
});

test('a missing type on the LOG channel is dropped', () => {
  // Unknown severity on the firehose is assumed to be ordinary log noise.
  assert.equal(lspServerNotice('window/logMessage', { message: 'trace' }), null);
});

// NOT RUNTIME COVERAGE — READ THE COMMENT BEFORE TRUSTING THIS TEST.
// window/showMessageRequest is a server-initiated REQUEST, and lspClient.ts:273-284
// replies -32601 and returns BEFORE onNotification runs, so this classification is
// never exercised in production. This test pins the pure function's behaviour only.
// It passes today and would keep passing if the feature were entirely absent from
// the app, which is exactly the kind of false confidence this task exists to remove.
test('showMessageRequest is classified like showMessage (pure function only)', () => {
  const notice = lspServerNotice('window/showMessageRequest', {
    type: LSP_MESSAGE_TYPE.Error,
    message: GOPLS_SYMPTOM,
  });
  assert.ok(notice);
  assert.equal(notice.level, 'error');
});

test('text is trimmed and pathological length is capped', () => {
  const padded = lspServerNotice('window/showMessage', {
    type: LSP_MESSAGE_TYPE.Error,
    message: `   ${GOPLS_SYMPTOM}   `,
  });
  assert.equal(padded.text, GOPLS_SYMPTOM);

  const huge = lspServerNotice('window/showMessage', {
    type: LSP_MESSAGE_TYPE.Error,
    message: 'x'.repeat(10_000),
  });
  assert.ok(huge.text.length <= 600, 'an unbounded string must not reach the renderer');
  assert.match(huge.text, /…$/, 'truncation is visible rather than silent');

  // The real cause message is well under the cap and must NOT be truncated —
  // truncating it is the exact failure mode of the 120px toolbar chip this
  // banner deliberately replaces.
  const cause = lspServerNotice('window/showMessage', {
    type: LSP_MESSAGE_TYPE.Info,
    message: GOPLS_CAUSE,
  });
  assert.equal(cause.text, GOPLS_CAUSE);
  assert.doesNotMatch(cause.text, /…/);
});

// --- dedupe -----------------------------------------------------------------

test('the dedupe key is stable for a repeat and distinct for a different complaint', () => {
  // gopls re-reports the same load failure on every request touching the broken
  // view. A user who dismissed it must not be re-alarmed by the repeat, but a
  // genuinely NEW complaint must still get through.
  const first = lspServerNotice('window/showMessage', { type: LSP_MESSAGE_TYPE.Info, message: GOPLS_CAUSE });
  const repeat = lspServerNotice('window/showMessage', { type: LSP_MESSAGE_TYPE.Info, message: GOPLS_CAUSE });
  const other = lspServerNotice('window/showMessage', { type: LSP_MESSAGE_TYPE.Error, message: GOPLS_SYMPTOM });

  assert.equal(lspServerNoticeKey(first), lspServerNoticeKey(repeat), 'a repeat must dedupe');
  assert.notEqual(lspServerNoticeKey(first), lspServerNoticeKey(other), 'a new complaint must not');
});

test('gopls CAUSE and SYMPTOM have distinct keys, so both can be held at once', () => {
  // The regression behind reviewer BLOCKING 1: the hook held ONE notice and the
  // symptom overwrote the cause, leaving the user the unactionable half. The hook
  // now keeps a list deduped on this key, so these two MUST NOT collide.
  const cause = lspServerNotice('window/showMessage', { type: LSP_MESSAGE_TYPE.Info, message: GOPLS_CAUSE });
  const symptom = lspServerNotice('window/showMessage', { type: LSP_MESSAGE_TYPE.Error, message: GOPLS_SYMPTOM });
  assert.notEqual(lspServerNoticeKey(cause), lspServerNoticeKey(symptom));
});

test('the key separator is NUL, so level and text cannot be confused for one another', () => {
  // NUL is used because it cannot occur in a server message, making the boundary
  // unambiguous. It must be written as the ESCAPE '\u0000' in source, never as a
  // literal byte: a raw NUL makes the file binary, which silently removes it from
  // `grep -rn` (no output, exit 1) and turns `git diff` into "Bin 0 -> N bytes".
  // That shipped once in this very file and made the change unreviewable.
  const notice = lspServerNotice('window/showMessage', { type: LSP_MESSAGE_TYPE.Error, message: 'x' });
  assert.ok(lspServerNoticeKey(notice).includes('\u0000'), 'separator must be NUL');
  assert.equal(lspServerNoticeKey(notice), 'error\u0000x');
});

// --- accumulation: REVIEWER BLOCKING 1 ---------------------------------------
// The defect these exist for shipped and passed a green 77-test suite. The hook
// held ONE notice in a `useState<LspServerNotice | null>` with an unconditional
// setter, so gopls' SYMPTOM overwrote its own CAUSE and the user was left with
// "Error loading workspace folders (expected 1, got 0)" — the one sentence they
// can do nothing with. The channel gate correctly ADMITTED the cause and React
// state threw it away milliseconds later. It was invisible to tests because it
// lived in a hook; the rule now lives in lspNextNotices so these can see it.

const cause = () => lspServerNotice('window/showMessage', { type: LSP_MESSAGE_TYPE.Info, message: GOPLS_CAUSE });
const symptom = () => lspServerNotice('window/showMessage', { type: LSP_MESSAGE_TYPE.Error, message: GOPLS_SYMPTOM });
const NONE: ReadonlySet<string> = new Set();

test('BOTH gopls frames are held at once — the single-slot regression', () => {
  // THE REGRESSION TEST FOR BLOCKING 1. Arrival order is cause-then-symptom, as
  // observed. If accumulation ever reverts to last-writer-wins, this fails.
  let list = lspNextNotices([], cause(), NONE, 3);
  list = lspNextNotices(list, symptom(), NONE, 3);
  assert.equal(list.length, 2, 'the symptom must not evict the cause');
  const texts = list.map((n) => n.text);
  assert.ok(texts.includes(GOPLS_CAUSE), 'the ACTIONABLE sentence must survive');
  assert.ok(texts.includes(GOPLS_SYMPTOM));
});

test('the reverse arrival order is equally safe', () => {
  // Nothing guarantees gopls' ordering, so neither message may depend on it.
  let list = lspNextNotices([], symptom(), NONE, 3);
  list = lspNextNotices(list, cause(), NONE, 3);
  assert.equal(list.length, 2);
  assert.ok(list.map((n) => n.text).includes(GOPLS_CAUSE));
});

test('a repeated complaint does not stack up duplicates', () => {
  // gopls re-reports the same load failure on every request touching the broken
  // view, so without this the editor fills with copies of one message.
  let list = lspNextNotices([], cause(), NONE, 3);
  for (let i = 0; i < 20; i++) list = lspNextNotices(list, cause(), NONE, 3);
  assert.equal(list.length, 1);
});

test('a dismissed complaint stays dismissed', () => {
  const dismissed = new Set([lspServerNoticeKey(cause())]);
  const list = lspNextNotices([], cause(), dismissed, 3);
  assert.equal(list.length, 0, 'the user said they were done with this one');
  // But a DIFFERENT complaint still gets through.
  assert.equal(lspNextNotices([], symptom(), dismissed, 3).length, 1);
});

test('the cap bounds the list and evicts oldest-first', () => {
  let list: ReturnType<typeof lspNextNotices> = [];
  for (const msg of ['one', 'two', 'three', 'four']) {
    list = lspNextNotices(
      list,
      lspServerNotice('window/showMessage', { type: LSP_MESSAGE_TYPE.Error, message: msg }),
      NONE,
      3
    );
  }
  assert.equal(list.length, 3, 'a pathological server must not bury the editor');
  assert.deepEqual(list.map((n) => n.text), ['two', 'three', 'four']);
});

test('the cap never evicts the two-frame gopls case', () => {
  // The case this whole task exists for must never be lossy at the default cap.
  let list = lspNextNotices([], cause(), NONE, 3);
  list = lspNextNotices(list, symptom(), NONE, 3);
  assert.equal(list.length, 2);
});

// --- VERIFICATION BOUNDARY --------------------------------------------------
// WHAT THESE TESTS PROVE: that the filter admits the two frames the user's dead
// session actually produced, and that it still drops the routine traffic a
// healthy server emits. Reintroducing the old one-line filter, or narrowing the
// show channel to type<=2, makes them fail.
//
// WHAT THEY DO NOT PROVE: that the banner is on screen. These tests end at the
// pure function; the hook wiring (useMonacoLsp.ts) and the render site
// (ProjectFilesPanel.tsx) are React and cannot be driven from here. That gap is
// NOT theoretical in this codebase — it already contains two surfaces that look
// like they render and do not: the hook's own return value was discarded by a
// bare call statement at ProjectFilesPanel.tsx:1353, and ToastViewport.tsx is
// mounted nowhere while four call sites dispatch into its queue. A green run of
// this file is therefore necessary and NOT sufficient; the on-screen proof is
// recorded separately in the task's handoff comment.
