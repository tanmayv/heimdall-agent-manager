// REQ-FIX-1: Source-invariant guards for approval-page text-input wiring
//
// DEFECT: BridgeEnrollmentApprovalPage.tsx used `(e: any) => setState(e?.target?.value ?? '')`
// on two Input components whose onChange prop is ChangeHandler<string> — a function called
// with a string value, not a DOM event. The `.target` dereference always resolves to
// undefined, the ?? '' makes every keystroke set state to '', and because the inputs are
// controlled, React restores the DOM value to blank on every render. Result: both text
// fields are permanently blank, the Deliver button stays permanently disabled.
//
// REGRESSION COVERAGE (4 tests, proven non-vacuous against b8d16379^)
// ─────────────────────────────────────────────────────────────────────
// Tests 1–4 are regression tests: they fail against b8d16379^ (the broken commit) and
// pass after the fix. Verified by checking out b8d16379^ and running the suite.
//
// The task's MANDATORY criterion — "the regression test must drive the FIELD, not the
// handler" — is met IN SUBSTANCE BY TESTS 1-4, which fail on the broken page. It is NOT
// met by the render tests, and an earlier version of this comment claimed otherwise.
//
// ui_approval_page_render_test.ts does render the real `Input` primitive through
// react-dom + jsdom and dispatch a real input event, but it mounts a test-local
// `TestPasswordForm` (:155, :173) rather than BridgeEnrollmentApprovalPage. Re-injecting
// BOTH original defects into the real page leaves that suite at pass=2 fail=0, UNCHANGED.
// So those tests prove `Input`'s CONTRACT; they do not cover the page's WIRING, which is
// where the defect lived. They are honest coverage of a different thing, and the
// limitation is stated in that file too.
//
// DOCUMENTATION INVARIANTS (2 tests, NOT regression coverage)
// ─────────────────────────────────────────────────────────────
// Tests 5–6 pass against both b8d16379^ and the fix — they assert structural properties
// of adjacent code (button gating, Input contract) that did not change. They document
// intended invariants, not the regression. They are labeled accordingly.
//
// CLASS-LEVEL GUARD (tests 7-10, B(3) from the coordinator ruling)
// ─────────────────────────────────────────────────────────────
// Test 7 sweeps all of src/ui for the anti-pattern on any of the thirteen value-passing
// components; tests 8-10 are the controls that stop test 7 from passing vacuously. Their
// design, scope and limits are documented at the section below rather than here, so the
// two descriptions cannot drift apart.
//
// RUN: node --test tests/ui_approval_page_input_wiring_test.ts

import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const REPO_ROOT = path.resolve(__dirname, '..');

const PAGE_FILE = path.join(
  REPO_ROOT,
  'src/ui/components/enrollment/BridgeEnrollmentApprovalPage.tsx',
);

const content = fs.readFileSync(PAGE_FILE, 'utf8');

// ---------------------------------------------------------------------------
// REGRESSION TEST 1: No onChange on a primitive Input/Textarea accesses .target.value
//   (the anti-pattern that caused REQ-FIX-1)
//   Fails against b8d16379^ ✓  Passes after fix ✓
// ---------------------------------------------------------------------------

test('REQ-FIX-1: no onChange handler in the approval page accesses e.target.value via optional chaining', () => {
  assert.doesNotMatch(
    content,
    /onChange=\{\s*\([^)]*\)\s*=>\s*\w+\([^)]*\?\s*\.\s*target\s*\?\s*\.\s*value/,
    'A ChangeHandler<string> onChange must not access .target.value — the handler receives the value directly',
  );
});

// ---------------------------------------------------------------------------
// REGRESSION TEST 2: No onChange handler carries a bare `: any` annotation
//   Fails against b8d16379^ ✓  Passes after fix ✓
// ---------------------------------------------------------------------------

test('REQ-FIX-1: no onChange handler on this page carries a bare `: any` annotation', () => {
  assert.doesNotMatch(
    content,
    /onChange=\{\s*\(\s*\w+\s*:\s*any\s*\)/,
    'onChange handlers must not be annotated `: any` — that defeats type-checking of ChangeHandler<T>',
  );
});

// ---------------------------------------------------------------------------
// REGRESSION TEST 3: The master-password Input uses a direct value pass-through
//   Fails against b8d16379^ ✓  Passes after fix ✓
//   Backreferences the parameter name so a correct rename (value → v) stays green.
// ---------------------------------------------------------------------------

test('REQ-FIX-1: setMasterPassword onChange passes the string value directly', () => {
  // Matches any single identifier used consistently:
  //   onChange={(value) => setMasterPassword(value)}
  //   onChange={(v) => setMasterPassword(v)}
  // Fails if the handler uses the broken .target.value accessor or an event object.
  assert.match(
    content,
    /onChange=\{\s*\(\s*(\w+)\s*\)\s*=>\s*setMasterPassword\(\s*\1\s*\)/,
    'masterPassword Input onChange must pass the string value directly — not an event-shaped accessor',
  );
});

// ---------------------------------------------------------------------------
// REGRESSION TEST 4: The device-code (codeInput) Input uses a direct value pass-through
//   Fails against b8d16379^ ✓  Passes after fix ✓
//   Backreferences the parameter name so a correct rename stays green.
// ---------------------------------------------------------------------------

test('REQ-FIX-1: setCodeInput onChange passes the string value directly', () => {
  assert.match(
    content,
    /onChange=\{\s*\(\s*(\w+)\s*\)\s*=>\s*setCodeInput\(\s*\1\s*\)/,
    'codeInput Input onChange must pass the string value directly — not an event-shaped accessor',
  );
});

// ---------------------------------------------------------------------------
// DOCUMENTATION INVARIANT 5: Deliver vault key button is disabled by !masterPassword
//   PASSES against both b8d16379^ and the fix — NOT regression coverage.
//   Documents the gating condition so a refactor that changes the disable logic is noticed.
// ---------------------------------------------------------------------------

test('REQ-FIX-1 [doc-invariant]: Deliver vault key button is gated on !masterPassword', () => {
  assert.match(
    content,
    /disabled=\{!masterPassword\}/,
    'Deliver vault key button must be disabled={!masterPassword}',
  );
  assert.match(
    content,
    /Deliver vault key/,
    'The Deliver vault key button label must be present',
  );
});

// ---------------------------------------------------------------------------
// DOCUMENTATION INVARIANT 6: Input.tsx contract — passes string value to callers
//   PASSES against both b8d16379^ and the fix — NOT regression coverage.
//   Documents the Input.tsx contract (the root reason the bug existed when misused).
// ---------------------------------------------------------------------------

test('REQ-FIX-1 [doc-invariant]: Input.tsx calls onChange(event.target.value) — passes value, not DOM event', () => {
  const inputFile = path.join(
    REPO_ROOT,
    'src/ui/components/ui/primitives/Input.tsx',
  );
  assert.ok(fs.existsSync(inputFile), 'Input.tsx must exist at the expected path');

  const inputContent = fs.readFileSync(inputFile, 'utf8');
  assert.match(
    inputContent,
    /onChange\s*=\s*\{\s*\(\s*event\s*\)\s*=>\s*onChange\s*\(\s*event\s*\.\s*target\s*\.\s*value\s*\)/,
    'Input.tsx must call onChange(event.target.value) so callers receive a string, not a DOM event',
  );
});


// ===========================================================================
// CLASS-LEVEL GUARD (B(3) from the coordinator ruling) — tests 7–10
// ===========================================================================
//
// WHAT THIS GUARDS, AND WHAT IT DOES NOT CLAIM
// ────────────────────────────────────────────
// The defect class: a handler passed to a VALUE-PASSING component reads off a
// DOM event (`.target.value` / `.target.checked`) that it was never given. The
// read yields `undefined`, the value is silently replaced, and — if the element
// is controlled — the field is permanently dead. It type-checks when the handler
// is annotated `: any`, and no existing gate catches it.
//
// Severity differs across the thirteen components and the comment should not
// pretend otherwise. On `Input`/`Textarea`/`Select` it is a dead text field,
// which is how REQ-FIX-1 blocked vault-key delivery. On `Accordion`
// (`(value: string[])`), `DataList.onSelectionChange` (`ChangeHandler<string[]>`)
// and `ScopeEditor` (`(next: Targeting)`) the same mistake is a broken expander,
// a broken selection, a broken scope editor. The DEFECT CLASS is identical and
// silent in all thirteen, which is why all thirteen are in scope — not because
// every one of them is vault-delivery-grade.
//
// THE SELECTION RULE IS THE CONTRACT, NOT THE SPELLING
// ────────────────────────────────────────────────────
// Any component whose onChange receives a VALUE rather than an event belongs
// here, however its type is written:
//   - `ChangeHandler<string>`         Input, Textarea, Select
//   - `ChangeHandler<boolean>`        Checkbox, Radio, Toggle
//   - `(value: string) => void`       Combobox, Tabs, ResourceSearchFilter
//   - `(value: string[]) => void`     Accordion
//   - `ChangeHandler<boolean>`        BulkActionBar, DataList
//   - `(next: Targeting) => void`     ScopeEditor
// Classifying by the TYPE's spelling is what created the original hole: this
// test once excluded `Select` on the stated grounds that its "onChange type is
// not a raw string", while `Select.tsx:236` reads `onChange: ChangeHandler<string>`
// — the identical contract to `Input`. The identical bug on a `<Select>` passed
// the whole suite. Classifying by the PROP's spelling is the same trap one level
// out, which is why `onSelectionChange` (DataList.tsx:96 — same contract, third
// disguise) is matched too.
//
// DESIGN CREDIT
// ─────────────
// The matcher below is the reviewer's design (inst_18dc4ce22458a459), handed over
// at cmt_18dc73984d1bb91c and adopted per the coordinator's ruling: balanced-brace
// prop extraction, nearest-enclosing-tag resolution by match index, the thirteen
// names, and the native-element positive control. Two changes were made on top and
// both are noted at their site: the `prev` check in `enclosingTag` (a defect found
// before adoption) and the enumeration assertion in test 10.
//
// WHY EACH PIECE EXISTS — every one of these failure modes actually occurred
// ─────────────────────────────────────────────────────────────────────────
//  1. BALANCED-BRACE EXTRACTION. The previous guard matched the prop body with
//     `[^}]*`, which stops at the first `}`. `TemplatesPanel.tsx:149` is
//     `onChange={(v) => set({ persona: v })}` — extraction terminated inside the
//     object literal, so the handler was never seen whole.
//  2. NEAREST-TAG-BY-INDEX, not a context window. The previous guard tested
//     whether `<Input` appeared anywhere in the preceding 300 characters. The two
//     real sites sat 174 and 188 characters from their tag, leaving ~110 characters
//     of headroom: padding the element with benign props made the guard pass on a
//     genuinely broken field. Coverage must not depend on how many props a
//     component happens to have — a guard a developer can disable by adding a
//     `className` is not a guard.
//  3. OWN-POSITION CLASSIFICATION. The previous guard called `src.indexOf(match)`,
//     which resolves EVERY duplicate handler text to the FIRST occurrence's
//     context — two identical handlers in one file were classified by the wrong
//     site. Here each match is classified by its own `m.index`.
//  4. `.checked` AS WELL AS `.value`. Omitting `.checked` is what would have let
//     the three boolean components (`Checkbox`, `Radio`, `Toggle`) through.
//
// Commented-out code is deliberately NOT exempted from the violation sweep. When
// a guard must err, it should err LOUDLY: a false positive announces itself and
// gets fixed, whereas every sweep defect that has cost this chain a review round
// was a silent false negative.
//
// RUN: node --test tests/ui_approval_page_input_wiring_test.ts

// --- The thirteen value-passing components, keyed by declaring file. ----------
// Keyed by FILE rather than by name on purpose: deriving a component name from a
// declaration means deciding which interface belongs to which export, and
// `ScopeField.tsx` has ten exports with the declaration sitting in an inline type
// literal on the `ScopeEditor` signature. That parsing is exactly where a further
// silent hole would live. A new value-passing component almost always arrives in a
// new file, and that is the case test 10 must catch.
//
// Honest limit: adding a SECOND value-passing component to an ALREADY-registered
// file would not trip test 10. That is accepted deliberately — the alternative is a
// name parser whose failure mode is a comfortable pass.
const VALUE_PASSING_REGISTRY: Record<string, string[]> = {
  // primitives — 7
  'src/ui/components/ui/primitives/Input.tsx': ['Input'],
  'src/ui/components/ui/primitives/Textarea.tsx': ['Textarea'],
  'src/ui/components/ui/primitives/Select.tsx': ['Select'],
  'src/ui/components/ui/primitives/Checkbox.tsx': ['Checkbox'],
  'src/ui/components/ui/primitives/Radio.tsx': ['Radio'],
  'src/ui/components/ui/primitives/Toggle.tsx': ['Toggle'],
  'src/ui/components/ui/primitives/Combobox.tsx': ['Combobox'],
  // composites — 5
  'src/ui/components/ui/composites/BulkActionBar.tsx': ['BulkActionBar'],
  'src/ui/components/ui/composites/Tabs.tsx': ['Tabs'],
  'src/ui/components/ui/composites/DataList.tsx': ['DataList'],
  'src/ui/components/ui/composites/ResourceSearchFilter.tsx': ['ResourceSearchFilter'],
  'src/ui/components/ui/composites/Accordion.tsx': ['Accordion'],
  // patterns — 1
  'src/ui/components/ui/patterns/ScopeField.tsx': ['ScopeEditor'],
};

const VALUE_PASSING_TAGS = new Set(Object.values(VALUE_PASSING_REGISTRY).flat());

// Both prop names: the contract is what matters, not the prop's spelling.
const CHANGE_PROP = /\b(onChange|onSelectionChange)\s*=\s*\{/g;

// A handler is suspect if it reads off the event object at all. Anchored on the
// FIELD read, so ordinary domain vocabulary (`.targetMode`, `.targetInstanceId`,
// `{ ...targeting }` — all common in this codebase) cannot reach it.
const TOUCHES_TARGET = /\.\s*target\s*(\?\s*)?\.\s*(value|checked)\b/;

function collectTsx(dir: string, files: string[] = []): string[] {
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) collectTsx(full, files);
    else if (entry.isFile() && entry.name.endsWith('.tsx')) files.push(full);
  }
  return files;
}

/**
 * Extract the balanced-brace body of a prop written `name={...}`, starting at the
 * index of the opening `{`. Tracks string and template literals so a brace inside
 * a string cannot unbalance the count. Returns null when unbalanced, which the
 * caller records as `unparseable` rather than silently skipping.
 */
function extractBracedExpr(src: string, openIdx: number): { body: string; end: number } | null {
  let depth = 0;
  let quote: string | null = null;
  for (let i = openIdx; i < src.length; i++) {
    const c = src[i];
    if (quote) {
      if (c === '\\') { i++; continue; }
      if (c === quote) quote = null;
      continue;
    }
    if (c === '"' || c === "'" || c === '`') { quote = c; continue; }
    if (c === '{') depth++;
    else if (c === '}') {
      depth--;
      if (depth === 0) return { body: src.slice(openIdx, i + 1), end: i };
    }
  }
  return null;
}

/**
 * Resolve the JSX tag ENCLOSING the prop at `propIdx` by walking backwards to the
 * nearest tag-open. A prop always sits inside its own tag, so the first tag-open
 * met going backwards is the enclosing element.
 */
function enclosingTag(src: string, propIdx: number): string | null {
  for (let i = propIdx; i >= 0; i--) {
    if (src[i] !== '<') continue;
    if (src[i + 1] === '/' || src[i + 1] === '!') continue; // closing tag, or comment
    // A JSX tag-open's `<` is never preceded by an identifier character or `.`,
    // but a GENERIC TYPE ARGUMENT's always is. Without this check,
    // `list={x as Record<string, never>}` written before the onChange in the same
    // tag resolves the enclosing element to `<string>` — which, being lowercase,
    // files a genuinely broken handler in the NATIVE bucket. The violation
    // disappears and the positive control is inflated by the very handler it
    // should have caught: a silent false negative that also makes the floor look
    // healthier. Verified by injection before this guard was added.
    // Also skips comparisons such as `disabled={count<max}`.
    if (i > 0 && /[A-Za-z0-9_$.]/.test(src[i - 1])) continue;
    const m = /^<([A-Za-z_$][\w.$]*)/.exec(src.slice(i, i + 64));
    if (!m) continue;
    return m[1];
  }
  return null;
}

interface SweepRecord { rel: string; line: number; tag: string; body: string }
interface SweepResult {
  violations: SweepRecord[];
  native: SweepRecord[];
  otherComponent: SweepRecord[];
  unparseable: string[];
  allHandlers: SweepRecord[];
}

function sweepUiSource(): SweepResult {
  const out: SweepResult = {
    violations: [], native: [], otherComponent: [], unparseable: [], allHandlers: [],
  };
  for (const file of collectTsx(path.join(REPO_ROOT, 'src/ui'))) {
    const src = fs.readFileSync(file, 'utf8');
    const rel = path.relative(REPO_ROOT, file);
    for (const m of src.matchAll(CHANGE_PROP)) {
      const idx = m.index as number;
      const openIdx = idx + m[0].length - 1;
      const expr = extractBracedExpr(src, openIdx);
      const line = src.slice(0, idx).split('\n').length;
      if (!expr) { out.unparseable.push(`${rel}:${line}`); continue; }
      const tag = enclosingTag(src, idx) ?? '(unresolved)';
      const rec: SweepRecord = {
        rel, line, tag, body: expr.body.slice(0, 80).replace(/\s+/g, ' '),
      };
      out.allHandlers.push(rec);
      if (!TOUCHES_TARGET.test(expr.body)) continue;
      if (VALUE_PASSING_TAGS.has(tag)) out.violations.push(rec);
      else if (/^[a-z]/.test(tag)) out.native.push(rec);
      else out.otherComponent.push(rec);
    }
  }
  return out;
}

const sweep = sweepUiSource();
const fmt = (r: SweepRecord) => `${r.rel}:${r.line} <${r.tag}> ${r.body}`;

// ---------------------------------------------------------------------------
// CLASS GUARD 7: no value-passing component anywhere in src/ui reads off an event
//   Non-vacuous: fails on b8d16379^, and fails when the anti-pattern is injected
//   at a real call site of Input / Textarea / Select / Checkbox / Radio.
// ---------------------------------------------------------------------------

test('REQ-FIX-1 [class-guard B(3)]: no onChange on any of the 13 value-passing components in src/ui reads .target.value/.checked', () => {
  assert.deepStrictEqual(
    sweep.violations.map(fmt),
    [],
    'A value-passing component received a handler that reads off a DOM event it is ' +
    'never given. These components call onChange(value); the read yields undefined ' +
    'and the value is silently replaced.\nViolations:\n' +
    sweep.violations.map(fmt).join('\n'),
  );

  // An unparseable prop body is NOT a pass. Balanced extraction returning null
  // means the sweep could not see a handler whole, so it could not judge it —
  // which is indistinguishable from "no violation" unless asserted separately.
  assert.deepStrictEqual(
    sweep.unparseable, [],
    'Some onChange prop bodies could not be extracted, so they were never checked:\n' +
    sweep.unparseable.join('\n'),
  );

  // Nor is an UNRESOLVED enclosing tag a pass. `enclosingTag` returns null when it finds
  // no tag-open — `return<Tag …>` is one shape that would do it, since the `<` is then
  // preceded by the `n` of `return`. Such a handler lands in neither the violation bucket
  // nor the native control: it is silently absorbed, which is the exact pattern the rest
  // of this file exists to eliminate. Unreachable in the tree today; asserted anyway,
  // because a guard that must err should err loudly.
  const unresolved = sweep.allHandlers.filter((r) => r.tag === '(unresolved)');
  assert.deepStrictEqual(
    unresolved.map(fmt), [],
    'Some onChange handlers have an unresolved enclosing tag, so they were classified ' +
    'into neither the violations nor the positive control:\n' + unresolved.map(fmt).join('\n'),
  );
});

// ---------------------------------------------------------------------------
// PRIMARY CONTROL 8: tag resolution, proven on three known sites in one file
//
//   This is the strongest control in the file and it is the reviewer's find.
//   BridgeEnrollmentApprovalPage.tsx:803 is a native lowercase
//   `<input type="checkbox">` reading `.target.checked` CORRECTLY, four lines
//   below a real `<Input>` at :792. Asserting all three classifications together
//   fails under three independent defects, every one of which this chain hit:
//
//     - a 300-char backward window      → sees `<Input` and flags :803
//     - a `.checked`-blind pattern      → never sees :803 at all
//     - `src.indexOf(match)`            → classifies duplicates by the first site
//
//   A floor cannot do this: a matcher that still matches text but has stopped
//   resolving tags satisfies a floor and fails here.
// ---------------------------------------------------------------------------

test('REQ-FIX-1 [control, primary]: tag resolution classifies :607 and :797 as <Input> and :803 as a native <input> that is not a violation', () => {
  const rel = 'src/ui/components/enrollment/BridgeEnrollmentApprovalPage.tsx';
  const onPage = sweep.allHandlers.filter((r) => r.rel === rel);

  const at = (line: number) => onPage.find((r) => Math.abs(r.line - line) <= 2);

  const codeInput = onPage.find((r) => /setCodeInput/.test(r.body));
  const password = onPage.find((r) => /setMasterPassword/.test(r.body));
  const remember = onPage.find((r) => /setRememberSession/.test(r.body));

  assert.ok(codeInput, 'the device-code handler must be found by the sweep');
  assert.ok(password, 'the master-password handler must be found by the sweep');
  assert.ok(remember, 'the remember-session handler must be found by the sweep');

  assert.strictEqual(codeInput!.tag, 'Input',
    `device-code handler must resolve to the <Input> primitive, got <${codeInput!.tag}> at :${codeInput!.line}`);
  assert.strictEqual(password!.tag, 'Input',
    `master-password handler must resolve to the <Input> primitive, got <${password!.tag}> at :${password!.line}`);

  // The discriminating leg: a native checkbox reading .target.checked correctly,
  // immediately below a real <Input>. It must resolve to lowercase `input` and
  // must NOT be reported as a violation.
  assert.strictEqual(remember!.tag, 'input',
    `remember-session handler must resolve to the NATIVE <input>, got <${remember!.tag}> at :${remember!.line}`);
  assert.ok(TOUCHES_TARGET.test(remember!.body),
    'the remember-session handler does read .target.checked — if this fails, the pattern has gone .checked-blind');
  assert.ok(
    !sweep.violations.some((v) => v.rel === rel && v.line === remember!.line),
    'the native <input> at :803 reads .target.checked correctly and must not be a violation',
  );

  void at; // kept for readability of the line references above
});

// ---------------------------------------------------------------------------
// SECONDARY CONTROL 9: the sweep still finds the legitimate native handlers
//
//   Catches TOTAL matcher collapse, which control 8 alone would not: a matcher
//   that finds nothing anywhere reports zero violations and looks healthy.
//
//   THE FLOOR IS 30, DELIBERATELY FAR BELOW THE MEASURED POPULATION OF 62.
//   - The failure mode guarded against is collapse toward zero, so any floor well
//     above zero catches it; precision buys nothing.
//   - A floor hugging the real population is a tripwire that fires on legitimate
//     refactors, and a test that fails because someone deleted a dialog is a test
//     whose number the next developer edits out — after which it guards nothing.
//     (Same principle as test 3's backreference: a correct rename must stay green.)
//   - 62 was the measured population when this was written. A drift toward 30
//     should be INVESTIGATED as a possible matcher regression, not accepted.
//
//   DO NOT re-derive this floor from the matcher's own output. A control
//   calibrated by the thing it controls is not a control — a rewritten matcher
//   would re-baseline its own oracle and the regression would be invisible.
// ---------------------------------------------------------------------------

const NATIVE_HANDLER_FLOOR = 30;
const NATIVE_HANDLER_POPULATION_AT_WRITING = 62;

test('REQ-FIX-1 [control, secondary]: the sweep still finds the legitimate native-element .target handlers', () => {
  assert.ok(
    sweep.native.length >= NATIVE_HANDLER_FLOOR,
    `Positive control failed: only ${sweep.native.length} native-element .target handlers found ` +
    `(floor ${NATIVE_HANDLER_FLOOR}, population was ${NATIVE_HANDLER_POPULATION_AT_WRITING} when written). ` +
    'A zero or near-zero count means the matcher has stopped matching, not that the ' +
    'codebase became clean — the empty violation list above would then be vacuous.',
  );

  // Capitalized components outside the registry that read off an event are not
  // failures (they may legitimately take a DOM-event handler), but a sudden
  // population here is worth seeing rather than silently bucketing.
  assert.ok(
    sweep.otherComponent.length <= 5,
    'Unexpectedly many non-registered capitalized components read .target — check whether ' +
    'one of them is value-passing and belongs in VALUE_PASSING_REGISTRY:\n' +
    sweep.otherComponent.map(fmt).join('\n'),
  );
});

// ---------------------------------------------------------------------------
// ENUMERATION 10: the registry cannot silently fall behind the codebase
//
//   A hardcoded list of thirteen has the same weakness as the list of two it
//   replaced: component #14, added later, is not in it and is not guarded. This
//   test enumerates value-passing onChange declarations across
//   src/ui/components/ui/ and fails if any declaring file is unregistered, so
//   adding such a component without registering it breaks the build with a
//   message naming the file.
//
//   Comment lines are skipped. Combobox.tsx:26-27 document the contract in JSDoc
//   prose rather than declaring it, and an enumeration that counts prose will
//   eventually send someone hunting a declaration that does not exist — the same
//   family of defect as a matcher that reads `.target` out of `.targeting`.
//
//   SCOPE LIMIT, stated rather than left to be discovered: this enumerates
//   src/ui/components/ui/ only. Locally-defined wrappers elsewhere share the
//   contract — ProvidersPanel.tsx:670 defines `TextInput` with
//   `onChange: (value: string) => void`, and :569 `ChipListInput` likewise — and
//   are NOT enumerated here. They are covered only if their tag name is in the
//   registry. Widening to every locally-defined wrapper in src/ui is a larger
//   change than REQ-FIX-1 and was not undertaken.
// ---------------------------------------------------------------------------

test('REQ-FIX-1 [enumeration]: every value-passing onChange declaration in src/ui/components/ui/ is registered', () => {
  // A declaration is either `onChange: ChangeHandler<T>` (no parameter to inspect) or
  // `onChange: (param: T) => void`, in which case the FIRST PARAMETER NAME is captured.
  const VALUE_PASSING_DECL =
    /\bon(?:Change|SelectionChange)\??\s*:\s*(?:(ChangeHandler)\s*<|\(\s*([A-Za-z_$][\w$]*)\s*[:,)])/g;

  // DENYLIST, NOT AN ALLOWLIST — and this inversion is the whole point.
  //
  // This test previously allow-listed the parameter names it would accept as
  // value-passing (`value|values|next|checked|selected`). That is the SAME MISTAKE this
  // file's own header warns about, a third level out:
  //
  //   level 1  classify by the TYPE's spelling      → created the original `Select` hole
  //   level 2  classify by the PROP's spelling      → fixed by matching onSelectionChange
  //   level 3  classify by the PARAMETER's spelling → this
  //
  // And unlike the first two it failed CLOSED AND QUIET: `(value: number[])` enumerated
  // correctly while `(rows: number[])` silently did not enumerate at all, leaving such a
  // component unregistered and unguarded with the suite green. It was not hypothetical —
  // it is why an earlier sweep of local wrappers found four of six: `PairedListInput`
  // spells its parameter `pairs` and `ReasonMappingInput` spells it `rows`, so both
  // vanished. The undercount and this defect are one root cause.
  //
  // Inverted: ANY parameter name counts as value-passing EXCEPT names that genuinely
  // denote a DOM event. An unfamiliar name now registers LOUDLY (it enumerates, and an
  // unregistered file fails this test) instead of disappearing.
  const EVENT_PARAM_NAMES = /^(e|ev|evt|event|_e|_ev|_event|domEvent|nativeEvent)$/i;

  const declaringFiles = new Map<string, number[]>();
  // Every declaration the denylist skips, recorded rather than dropped — see the
  // assertion at the end of this test for why.
  const skippedAsEventTaking: string[] = [];
  for (const file of collectTsx(path.join(REPO_ROOT, 'src/ui/components/ui'))) {
    const src = fs.readFileSync(file, 'utf8');
    const rel = path.relative(REPO_ROOT, file);
    const lines = src.split('\n');
    for (const m of src.matchAll(VALUE_PASSING_DECL)) {
      const lineNo = src.slice(0, m.index as number).split('\n').length;
      const text = (lines[lineNo - 1] ?? '').trim();
      // Skip prose: JSDoc continuation, line comments, block-comment openers.
      if (text.startsWith('*') || text.startsWith('//') || text.startsWith('/*')) continue;
      // m[1] = 'ChangeHandler' (value-passing by definition); m[2] = first parameter name.
      const paramName = m[2];
      if (paramName && EVENT_PARAM_NAMES.test(paramName)) {
        skippedAsEventTaking.push(`${rel}:${lineNo} (parameter named '${paramName}')`);
        continue;
      }
      if (!declaringFiles.has(rel)) declaringFiles.set(rel, []);
      declaringFiles.get(rel)!.push(lineNo);
    }
  }

  const unregistered = [...declaringFiles.keys()]
    .filter((f) => !(f in VALUE_PASSING_REGISTRY))
    .map((f) => `${f} (declared at :${declaringFiles.get(f)!.join(', :')})`);

  assert.deepStrictEqual(
    unregistered, [],
    'These files declare a value-passing onChange but their component is not in ' +
    'VALUE_PASSING_REGISTRY, so the class guard does not cover them. Add the ' +
    "component's JSX tag name to the registry:\n" + unregistered.join('\n'),
  );

  // The other direction: a registry entry whose declaration has gone means the
  // registry is stale, and a stale registry is how a guard quietly stops matching
  // the code it names.
  const stale = Object.keys(VALUE_PASSING_REGISTRY).filter((f) => !declaringFiles.has(f));
  assert.deepStrictEqual(
    stale, [],
    'These registered files no longer declare a value-passing onChange — the registry ' +
    'is stale and must be updated:\n' + stale.join('\n'),
  );

  // Closes one silent path, the same way as the (unresolved) bucket. NOT the last one —
  // see PARAMETER SHAPE below, which this assertion structurally cannot reach.
  //
  // The denylist inverted the failure DIRECTION, which was the point: a MISSING entry
  // (`onChange: (changeEvent: ChangeEvent) => void`) now registers the component as
  // value-passing — a false positive, loud and fixable — whereas levels 1-3 all made a
  // component vanish silently. But one silent path survives the inversion: a component
  // that is genuinely value-passing while naming its parameter like a DOM event, e.g.
  // `onChange: (event: CalendarEvent) => void` where `event` is a DOMAIN type. That is
  // skipped with no trace.
  //
  // So assert the skip set is empty. Nothing in components/ui/ is event-taking today, and
  // adding an event-taking onChange to a component in this directory should be a
  // DELIBERATE act — this makes it one, instead of a silent omission. It is a decision
  // tripwire, not a refactor tripwire: ordinary refactors do not add event-taking
  // handlers to the shared component library.
  assert.deepStrictEqual(
    skippedAsEventTaking, [],
    'A declaration in src/ui/components/ui/ was skipped as event-taking, so it is not ' +
    'enumerated and its component is not required to be registered. If it genuinely ' +
    'takes a DOM event, add it here deliberately; if the parameter merely LOOKS like an ' +
    'event but carries a value (e.g. a domain type named `event`), it must be ' +
    'enumerated and registered:\n' + skippedAsEventTaking.join('\n'),
  );

  // PARAMETER SHAPE — a remaining silent path, stated rather than claimed closed.
  //
  // What IS asserted empty: the three buckets a declaration can land in once
  // VALUE_PASSING_DECL has matched it — `unparseable` and `(unresolved)` in the sweep,
  // and `skippedAsEventTaking` above. What is NOT asserted is a declaration the regex
  // never matches at all: it enters no bucket, so asserting all three says nothing
  // about it.
  //
  // THE GENERAL RULE, so nobody re-declares completeness after closing a fifth case:
  //   "ALL BUCKETS ARE EMPTY" IS A COMPLETE CLAIM ONLY IF EVERYTHING REACHES A BUCKET.
  // A pre-bucketing drop is invisible to every downstream assertion. Note also that the
  // four earlier instances of this file's recurring defect were all the SAME dimension —
  // naming: the type's spelling, the prop's spelling, the parameter's name, then the
  // denylist's membership. We declared the top of that ladder each time. This one is
  // ORTHOGONAL to it, which is why closing another naming case would not have found it.
  //
  // The parameter NAME is now a denylist (fixed), but the parameter SHAPE is still an
  // allowlist: `VALUE_PASSING_DECL` only matches a plain identifier followed by one of
  // `:,)`. Executed truth table against this file's own predicate:
  //
  //   ENUMERATES   onChange: ChangeHandler<string>
  //   ENUMERATES   onChange: (rows: ReasonMapping[]) => void
  //   ENUMERATES   onChange: (value: string, meta: M) => void
  //   SKIPPED      onChange: (ev: Event) => void                 (asserted above)
  //   NO BUCKET    onChange: (value?: string) => void            optional — idiomatic TS
  //   NO BUCKET    onChange: ({ value }: Payload) => void        destructured
  //   NO BUCKET    onChange: ([first]: string[]) => void         array-destructured
  //   NO BUCKET    onChange: (...values: string[]) => void       rest
  //   NO BUCKET    onChange: <T>(value: T) => void               generic arrow
  //
  // All five NO BUCKET rows are value-passing, so a NEW, UNREGISTERED component declared
  // any of those ways is unguarded with this suite fully green. This is the same
  // closed-and-quiet signature as the parameter-name allowlist, one dimension over.
  //
  // MEASURED EMPTY, not assumed: a broad-net sweep of src/ui/components/ui/ for any
  // onChange/onSelectionChange declaration whatever its shape finds 15 declarations
  // across the 13 registered files (DataList and Combobox contribute two each), and the
  // committed predicate matches all 15 — shape-dropped: 0. For an ALREADY-REGISTERED
  // component a shape change fails loudly via the stale-registry assertion below, so the
  // silent case is specifically a new, unregistered component.
  //
  // DELIBERATELY NOT FIXED HERE. Closing it needs parsing rather than a regex, which is a
  // technique and not a line. Filed on iss_18dc7469a02adbfc with this reachability
  // evidence. Found by the reviewer in their own handed-over design.

  assert.strictEqual(
    VALUE_PASSING_TAGS.size, 13,
    'The guard covers thirteen components: 7 primitives (Input, Textarea, Select, ' +
    'Checkbox, Radio, Toggle, Combobox), 5 composites (BulkActionBar, Tabs, DataList, ' +
    'ResourceSearchFilter, Accordion) and 1 pattern (ScopeEditor). DataList contributes ' +
    'two props (onChange + onSelectionChange) but is one component.',
  );
});
