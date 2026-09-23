// REQ-LSP-UI-2: executable unit tests for the LSP session identity.
//
// RUN:  node --test tests/ui_lsp_session_key_test.ts
// (Node 24 strips TypeScript types natively — no test runner, no dependency, no
// build step. The module under test imports nothing, which is what makes this
// possible; see the header of src/ui/lsp/lspSessionKey.ts.)
//
// WHAT IS ACTUALLY BEING TESTED, AND WHY IT IS A FUNCTION AND NOT A HOOK.
// The defect these tests exist for lived in a React useEffect dependency array
// in useMonacoLsp.ts. This repo has no React test renderer, no jsdom and no test
// runner, deliberately — so a dependency array is structurally untestable here,
// and any test written against the hook would have passed just as happily with
// the defect present. The rule was therefore moved into lspSessionKey(), a pure
// function that the hook's dependency array now consists of. These tests drive
// that function, so reintroducing the defect in it makes them fail. See the
// VERIFICATION BOUNDARY note at the bottom for what that does and does not
// cover.
//
// THE SHAPE OF THE DEFECT, from the REQ-LSP-E2E-1 repro (observed by process
// inspection, not inferred):
//   Two Go files, one bridge, one language, TWO dir_prefix overrides:
//     /home/tanmay/ham-lsp-e2e/alpha  -> config cfg_alpha
//     /home/tanmay/ham-lsp-e2e/beta   -> config cfg_beta
//   Opening alpha/main.go started a gopls rooted at alpha. Opening beta/main.go
//   in the same session started NOTHING — the alpha-rooted gopls answered for
//   beta/main.go. The symptom was invisible: completion in beta/main.go returned
//   beta's own symbols, because they were declared in the buffer sent over
//   didOpen and a server rooted anywhere can answer from the text it was handed.
//
// EXPECTED VALUES ARE LITERAL AND KEYED ON IDENTITY, NEVER ON CONTENT. These
// tests assert WHICH CONFIG the session is keyed to. They never assert anything
// about completions, because completions looking right IS the symptom.

import { test } from 'node:test';
import assert from 'node:assert/strict';

import {
  LSP_NO_SESSION,
  lspFileServedBySession,
  lspNextSession,
  lspResolvedConfigId,
  lspSessionKey,
  type LspResolvedSession,
  type LspSessionIdentity,
} from '../src/ui/lsp/lspSessionKey.ts';

// The E2E repro, as data. Both files are Go, both on one bridge, one workspace
// root; they differ ONLY in which dir_prefix override the Hub resolved for them.
const ROOT = '/home/tanmay/ham-lsp-e2e';

const base: LspSessionIdentity = {
  enabled: true,
  active: true,
  bridgeId: 'brg_e2e',
  language: 'go',
  rootAbs: ROOT,
  configId: 'cfg_alpha',
};

// The three files of the repro, each carrying the path it was opened at.
//
// WHY filePath IS HERE WHEN LspSessionIdentity HAS NO SUCH FIELD. It is the trap
// for the LAZY FIX. Adding the file path to the session identity also makes the
// two-override defect go away — by restarting the language server on every
// single tab change, which trades a silent wrong answer for a visible
// performance regression. A test suite that only checks "the two overrides
// differ" accepts that fix happily.
//
// So the fixtures carry a path that the CORRECT implementation must ignore. It
// is invisible to lspSessionKey today (the extra property is simply not read),
// and the moment someone reads it the same-override test below goes red,
// because alphaMain and alphaHelper differ in nothing else. That makes the
// discriminator executable rather than merely asserted.
type OpenFile = LspSessionIdentity & { filePath: string };

const alphaMain: OpenFile = { ...base, configId: 'cfg_alpha', filePath: `${ROOT}/alpha/main.go` };
const alphaHelper: OpenFile = { ...base, configId: 'cfg_alpha', filePath: `${ROOT}/alpha/helper.go` };
const betaMain: OpenFile = { ...base, configId: 'cfg_beta', filePath: `${ROOT}/beta/main.go` };

// --- THE DEFECT: two overrides must not share one session --------------------

test('two same-language files under DIFFERENT dir_prefix overrides get DIFFERENT session keys', () => {
  // alpha/main.go resolved to cfg_alpha; beta/main.go resolved to cfg_beta.
  const alpha = lspSessionKey(alphaMain);
  const beta = lspSessionKey(betaMain);

  assert.notEqual(
    alpha,
    beta,
    'beta/main.go would be served by the alpha-rooted server — the REQ-LSP-UI-2 defect'
  );
  // Anchored on the literal, not merely on "they differ": a key that dropped the
  // config entirely would also satisfy notEqual against nothing.
  assert.equal(alpha, '["brg_e2e","go","/home/tanmay/ham-lsp-e2e","cfg_alpha"]');
  assert.equal(beta, '["brg_e2e","go","/home/tanmay/ham-lsp-e2e","cfg_beta"]');
});

test('the resolved config is what distinguishes them — everything else is identical', () => {
  // Spelling out the premise the test above rests on: these two identities agree
  // on bridge, language, root, enabled and active. If config_id were not in the
  // key, NOTHING would distinguish them and one session would serve both.
  const alpha = alphaMain;
  const beta = betaMain;

  for (const field of ['enabled', 'active', 'bridgeId', 'language', 'rootAbs'] as const) {
    assert.deepEqual(alpha[field], beta[field], `${field} is deliberately identical in this fixture`);
  }
  assert.notEqual(lspSessionKey(alpha), lspSessionKey(beta));
});

// --- THE OPTIMISATION THAT MUST SURVIVE THE FIX ------------------------------

test('THE DISCRIMINATOR: two files under the SAME override produce a BYTE-IDENTICAL key', () => {
  // alpha/main.go and alpha/helper.go differ ONLY in their path, and both
  // resolve to cfg_alpha. The running session must be reused.
  //
  // This is the test that separates the correct fix from the lazy one: it fails
  // the moment the file path reaches the key, which is exactly what the lazy fix
  // does. React compares the dependency with Object.is, so these must be equal
  // AS STRINGS, not merely equivalent.
  const first = lspSessionKey(alphaMain);
  const second = lspSessionKey(alphaHelper);

  assert.notEqual(alphaMain.filePath, alphaHelper.filePath, 'the fixture must differ by path or this proves nothing');
  assert.equal(
    Object.is(first, second),
    true,
    'React re-runs the effect unless Object.is holds — a language server restart on every tab change'
  );
  assert.equal(first.includes('main.go'), false, 'a file path in the key restarts the server per tab');
  assert.equal(second.includes('helper.go'), false);
  assert.equal(first, '["brg_e2e","go","/home/tanmay/ham-lsp-e2e","cfg_alpha"]');
});

// --- THE 404 PATH: the most-executed path in the whole feature ---------------

test('an unresolved config yields NO session, whatever made it unresolved', () => {
  // Most languages have no configured server, so the Hub answering 404 is the
  // normal case, not an error case. It must not start a session against a config
  // that does not exist, and an empty config_id must never behave like a valid
  // key. NOTE: 404, in-flight and a failed resolve all arrive here as '' — they
  // produce the same KEY but they are not the same STATE, and lspResolvedConfigId
  // is what tells them apart. See the D1/D2 tests below.
  assert.equal(lspSessionKey({ ...base, configId: '' }), '');
});

test('the empty key is the single gate for every reason not to connect', () => {
  assert.equal(lspSessionKey({ ...base, enabled: false }), '', 'experiment flag off');
  assert.equal(lspSessionKey({ ...base, active: false }), '', 'tab that must hold no session');
  assert.equal(lspSessionKey({ ...base, bridgeId: '' }), '', 'no bridge');
  assert.equal(lspSessionKey({ ...base, language: '' }), '', 'file has no LSP language');
  assert.equal(lspSessionKey({ ...base, rootAbs: '' }), '', 'no workspace root');
  assert.equal(lspSessionKey({ ...base, configId: '' }), '', 'nothing resolved');
});

test('a disabled experiment wins over an otherwise complete identity', () => {
  // Ordering matters: the flag is checked before anything else, so a fully
  // populated identity with the flag off is still no session. This is the gate
  // the hook's header calls load-bearing.
  assert.equal(lspSessionKey({ ...base, enabled: false, configId: 'cfg_alpha' }), '');
});

// --- key construction cannot collide -----------------------------------------

test('a root containing the separator cannot forge another identity', () => {
  // The key is JSON, not a delimiter join, because rootAbs is an arbitrary
  // filesystem path and may contain whatever character a join would use. Two
  // identities that differ only in where a field boundary falls must not
  // produce the same key.
  const a = lspSessionKey({ ...base, rootAbs: '/w/a', language: 'go', configId: 'c1' });
  const b = lspSessionKey({ ...base, rootAbs: '/w/a","go', language: 'go', configId: 'c1' });
  assert.notEqual(a, b);

  const spaced = lspSessionKey({ ...base, rootAbs: '/home/my projects/app' });
  assert.equal(spaced, '["brg_e2e","go","/home/my projects/app","cfg_alpha"]');
});

// --- READING THE RESOLVE QUERY (review finding D1) ---------------------------
//
// These cover the defect the REQ-LSP-UI-2 review found in the wiring: RTK
// Query's `data` is deliberately stale across an arg change, so keying on it
// reintroduces this very task's bug through an ordinary 500.
//
// THE FIXTURES ARE THE TRAP, exactly as with filePath above: every one of them
// supplies a STALE `data` holding the PREVIOUS file's config. A correct
// implementation must ignore it. An implementation that reads `data` — which is
// what the code did when the review caught it — returns cfg_alpha and these go
// red. That is what makes this executable rather than asserted.

const STALE = { config: { config_id: 'cfg_alpha' } }; // the previous file's result

test('D1: a FAILED resolve yields no config — never the previous file`s', () => {
  // Measured RTK Query state for a 500 on the second file: data falls back to
  // alpha, currentData is undefined, isError is true. Keying on data here leaves
  // the alpha-rooted server serving beta silently and indefinitely.
  assert.equal(
    lspResolvedConfigId({ data: STALE, currentData: undefined, isError: true }),
    '',
    'a 500 must not look like a stale success — the wrong server would serve the file'
  );
});

test('D1: a failed resolve produces an EMPTY SESSION KEY, not the previous session', () => {
  // End to end through both functions, which is the combination the hook uses.
  const configId = lspResolvedConfigId({ data: STALE, currentData: undefined, isError: true });
  assert.equal(lspSessionKey({ ...base, configId }), '', 'no session while the resolve is failing');
});

test('isError WINS over any config present — pinning intent, not observed state', () => {
  // HONEST NOTE ON WHAT THIS TEST IS FOR. On the RTK Query version installed
  // here, a failed resolve leaves currentData UNDEFINED, so reading currentData
  // alone already yields '' and the isError check is not what closes D1. I
  // verified that by injection: dropping the isError check leaves all other
  // tests green.
  //
  // The check is kept anyway, and this test is what stops it from being dead
  // code someone later deletes as redundant. It pins the INTENT — a failed
  // resolve must never produce a session key, whatever data happens to be
  // sitting in the query state — so the rule survives an RTK version where a
  // stale currentData could outlive an error.
  assert.equal(
    lspResolvedConfigId({ data: STALE, currentData: { config: { config_id: 'cfg_alpha' } }, isError: true }),
    '',
    'an error must beat any config in the state, however it got there'
  );
});

test('D2: a resolve IN FLIGHT yields no config — in-flight is not a stale success', () => {
  // The claim "in flight behaves like a 404" was true only for the FIRST resolve,
  // because before it there was no previous result to go stale. currentData makes
  // it true in general.
  assert.equal(lspResolvedConfigId({ data: STALE, currentData: undefined, isError: false }), '');
});

test('a settled, successful resolve yields the CURRENT file`s config', () => {
  assert.equal(
    lspResolvedConfigId({ data: STALE, currentData: { config: { config_id: 'cfg_beta' } }, isError: false }),
    'cfg_beta',
    'must be the config for the CURRENT args, not the previous ones'
  );
});

test('a 404 (no config matched) yields no config', () => {
  // The endpoint maps 404 to `{ config: null }` — a normal answer, and the most
  // executed one, since most languages have no configured server.
  assert.equal(lspResolvedConfigId({ data: STALE, currentData: { config: null }, isError: false }), '');
  assert.equal(lspResolvedConfigId({ currentData: { config: null } }), '');
});

test('a skipped query yields no config', () => {
  assert.equal(lspResolvedConfigId({}), '');
});

test('THE FULL CROSS-OVERRIDE SWITCH, state by state', () => {
  // alpha/main.go is open and served by cfg_alpha. The user opens beta/main.go.
  // Walk the three states its resolve passes through and assert the session key
  // at each one. This is the sequence the defect hid in.
  const keyFor = (st: Parameters<typeof lspResolvedConfigId>[0]) =>
    lspSessionKey({ ...base, configId: lspResolvedConfigId(st) });

  // 1. in flight — we do not yet know which server serves beta.
  assert.equal(keyFor({ data: STALE, currentData: undefined, isError: false }), '', 'no session while unknown');
  // 2a. it resolves to the beta override -> a DIFFERENT key -> correct server starts.
  assert.equal(
    keyFor({ data: STALE, currentData: { config: { config_id: 'cfg_beta' } } }),
    '["brg_e2e","go","/home/tanmay/ham-lsp-e2e","cfg_beta"]'
  );
  // 2b. or it FAILS -> still no session. NOT a silent fallback to alpha.
  assert.equal(keyFor({ data: STALE, currentData: undefined, isError: true }), '', 'a 500 must not fall back');
});

// --- HOLDING THE SESSION vs SYNCING THE FILE ---------------------------------
//
// The second review round found that keying the session on the CURRENT file's
// resolution is correct but restarts the language server on the first open of
// every file (measured: 5 starts and 4 teardowns where 1 start is right).
// lspNextSession holds the running session across an unresolved file, and
// lspFileServedBySession makes that safe by refusing to describe the file to a
// server that does not own it.

const PROJECT = { bridgeId: 'brg_e2e', rootAbs: ROOT };
const ALPHA: LspResolvedSession = { ...PROJECT, language: 'go', configId: 'cfg_alpha' };

test('a fresh successful resolution wins', () => {
  assert.deepEqual(
    lspNextSession(LSP_NO_SESSION, { ...PROJECT, language: 'go', configId: 'cfg_alpha' }),
    ALPHA
  );
  assert.deepEqual(
    lspNextSession(ALPHA, { ...PROJECT, language: 'go', configId: 'cfg_beta' }),
    { ...PROJECT, language: 'go', configId: 'cfg_beta' }
  );
});

test('an UNRESOLVED file HOLDS the running session — this is the teardown fix', () => {
  // In flight, failed, and no-config all arrive as configId ''. None of them may
  // pull the running server down: we do not know the session is wrong, only that
  // this file is not yet known to belong to it.
  for (const why of ['in flight', 'failed (500)', 'no config (404)']) {
    assert.equal(
      lspNextSession(ALPHA, { ...PROJECT, language: 'go', configId: '' }),
      ALPHA,
      `${why} must hold the session, and hold the SAME OBJECT`
    );
  }
});

test('an unchanged resolution returns the SAME OBJECT — no React re-render loop', () => {
  // Identity, not equality: lspNextSession feeds a useState setter, so returning
  // a fresh object with identical fields would re-render forever.
  const again = lspNextSession(ALPHA, { ...PROJECT, language: 'go', configId: 'cfg_alpha' });
  assert.equal(Object.is(again, ALPHA), true, 'a new object here is an infinite render loop');
});

test('a DIFFERENT project holds nothing — a config_id must not cross a root', () => {
  // config_ids are resolved against one bridge. Carrying alpha's into another
  // project would key a session on a server that does not serve that root.
  assert.deepEqual(lspNextSession(ALPHA, { ...PROJECT, rootAbs: '/other/root', language: 'go', configId: '' }), LSP_NO_SESSION);
  assert.deepEqual(lspNextSession(ALPHA, { ...PROJECT, bridgeId: 'brg_other', language: 'go', configId: '' }), LSP_NO_SESSION);
});

test('THE SYNC GATE: a file is described only to the server that owns it', () => {
  assert.equal(lspFileServedBySession('cfg_alpha', 'cfg_alpha'), true, 'resolved to the running session');
  assert.equal(lspFileServedBySession('cfg_beta', 'cfg_alpha'), false, 'resolved ELSEWHERE — must not be synced');
  assert.equal(lspFileServedBySession('', 'cfg_alpha'), false, 'in flight / failed / no config — must not be synced');
  assert.equal(lspFileServedBySession('cfg_alpha', ''), false, 'no session to sync into');
  assert.equal(lspFileServedBySession('', ''), false);
});

// --- THE RENDER SEQUENCE, AS DATA --------------------------------------------
//
// WHY THIS TEST EXISTS AND WHAT IT CANNOT DO. The regression that got through
// review lived in a SEQUENCE OF RENDERS, not in any single rule: every rule test
// stayed green while the session key blanked for one render per new file and
// cost a server restart. A pure-function test cannot see that, so this one
// replays an ordered sequence of resolve states and asserts the session key AND
// the sync gate at each step, counting the server starts that result.
//
// It is NOT React. It models the order in which the hook's values arrive, and it
// would not catch a defect in how the hook wires them. Measuring real session
// starts is still the check that matters after changing this — see the note at
// the session effect in useMonacoLsp.ts.

function replay(steps: Array<{ file: string; language: string; configId: string }>) {
  let session = LSP_NO_SESSION;
  let key = '';
  let starts = 0;
  let teardowns = 0;
  const synced: string[] = [];

  for (const step of steps) {
    session = lspNextSession(session, { ...PROJECT, language: step.language, configId: step.configId });
    const nextKey = lspSessionKey({ enabled: true, active: true, bridgeId: session.bridgeId, language: session.language, rootAbs: session.rootAbs, configId: session.configId });
    if (nextKey !== key) {
      if (key !== '') teardowns++;
      if (nextKey !== '') starts++;
      key = nextKey;
    }
    if (lspFileServedBySession(step.configId, session.configId)) synced.push(step.file);
  }
  return { starts, teardowns, synced, key };
}

test('SEQUENCE: five first-opens under ONE override cost exactly ONE server start', () => {
  // Each file renders twice: once while its resolve is in flight (configId ''),
  // once settled. This is the exact shape that produced 5 starts / 4 teardowns.
  const steps = [];
  for (const f of ['a.go', 'b.go', 'c.go', 'd.go', 'e.go']) {
    steps.push({ file: f, language: 'go', configId: '' });          // in flight
    steps.push({ file: f, language: 'go', configId: 'cfg_alpha' }); // settled
  }
  const r = replay(steps);
  assert.equal(r.starts, 1, 'the server must start ONCE, not once per file');
  assert.equal(r.teardowns, 0, 'nothing may tear down — this is the regression');
  assert.deepEqual(r.synced, ['a.go', 'b.go', 'c.go', 'd.go', 'e.go'], 'every file still gets synced, once resolved');
});

test('SEQUENCE: crossing an override boundary restarts exactly once, and never mis-syncs', () => {
  const r = replay([
    { file: 'alpha/main.go', language: 'go', configId: '' },
    { file: 'alpha/main.go', language: 'go', configId: 'cfg_alpha' },
    { file: 'beta/main.go', language: 'go', configId: '' },          // in flight
    { file: 'beta/main.go', language: 'go', configId: 'cfg_beta' },  // resolves elsewhere
  ]);
  assert.equal(r.starts, 2, 'alpha, then beta');
  assert.equal(r.teardowns, 1, 'alpha is disposed when beta takes over');
  assert.deepEqual(r.synced, ['alpha/main.go', 'beta/main.go']);
  assert.equal(r.key, `["brg_e2e","go","${ROOT}","cfg_beta"]`);
});

test('SEQUENCE: a FAILED resolve leaves the session up and the file UNSYNCED', () => {
  // The coordinator's explicit question. A 500 on the second file must not pull
  // the running server down, and must not put that file into it either.
  const r = replay([
    { file: 'alpha/main.go', language: 'go', configId: '' },
    { file: 'alpha/main.go', language: 'go', configId: 'cfg_alpha' },
    { file: 'beta/main.go', language: 'go', configId: '' }, // 500 — stays '' indefinitely
  ]);
  assert.equal(r.starts, 1, 'no restart');
  assert.equal(r.teardowns, 0, 'the running session survives a failed resolve');
  assert.deepEqual(r.synced, ['alpha/main.go'], 'beta/main.go is NEVER synced into the alpha server');
});

test('SEQUENCE: an unconfigured file leaves the session up harmlessly', () => {
  // The coordinator's other explicit question: open a README in a Go project.
  const r = replay([
    { file: 'main.go', language: 'go', configId: '' },
    { file: 'main.go', language: 'go', configId: 'cfg_alpha' },
    { file: 'README.md', language: 'markdown', configId: '' },  // 404, no config
    { file: 'main.go', language: 'go', configId: 'cfg_alpha' }, // back again
  ]);
  assert.equal(r.starts, 1, 'gopls must not be torn down because someone glanced at a README');
  assert.equal(r.teardowns, 0);
  assert.deepEqual(r.synced, ['main.go', 'main.go'], 'the README is never synced into gopls');
});

// --- VERIFICATION BOUNDARY ---------------------------------------------------
//
// WHAT THESE TESTS PROVE: that the session identity distinguishes two
// dir_prefix overrides, does NOT distinguish two files under one override, and
// is empty whenever no session should exist. Both failure directions are
// EXECUTABLE, not merely asserted: dropping configId from the key fails the
// first test, and reading the fixture's filePath into the key fails the
// discriminator.
//
// They ALSO now prove how the resolve query must be read — the surface the
// REQ-LSP-UI-2 review found the defect in. That surface used to be uncoverable
// because the decision sat in the hook; moving it into lspResolvedConfigId made
// it testable, and the fixtures feed a stale `data` so an implementation that
// reads it goes red.
//
// WHAT THEY STILL DO NOT PROVE: that useMonacoLsp.ts actually calls these two
// functions and hands the result to React. That is three lines — the
// useResolveLspServerConfigQuery call, `lspResolvedConfigId(resolveState)`, and
// `}, [sessionKey, monaco]);` — and none can be covered here, because rendering a
// hook needs a renderer this repo does not have. They are verified by reading,
// not by execution. The review found the last defect in exactly this gap, so it
// is worth being precise about how much of it is left: the RULES are now covered,
// the WIRING is not.
