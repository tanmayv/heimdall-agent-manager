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

test('showMessageRequest is treated like showMessage', () => {
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
