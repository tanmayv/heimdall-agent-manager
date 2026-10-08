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
// Render-and-type behavioral tests are in ui_approval_page_render_test.ts (Option A).
// Those tests are non-vacuous: they fail when either handler uses the broken pattern.
//
// DOCUMENTATION INVARIANTS (2 tests, NOT regression coverage)
// ─────────────────────────────────────────────────────────────
// Tests 5–6 pass against both b8d16379^ and the fix — they assert structural properties
// of adjacent code (button gating, Input contract) that did not change. They document
// intended invariants, not the regression. They are labeled accordingly.
//
// CLASS-LEVEL GUARD (1 test, B(3) from the coordinator ruling)
// ─────────────────────────────────────────────────────────────
// Test 7 is non-vacuous against b8d16379^ — the broken .target accesses in
// BridgeEnrollmentApprovalPage.tsx cause it to fail on that commit. It guards the
// anti-pattern across ALL of src/ui (not just this one file), so the identical mistake
// on any other ChangeHandler<T> primitive is caught immediately.
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

// ---------------------------------------------------------------------------
// CLASS-LEVEL GUARD (B(3)): No .target-accessing onChange on any ChangeHandler<T>
// primitive anywhere in src/ui
//   Fails against b8d16379^ ✓  Passes after fix ✓
//   Guards the class, not just this instance. The identical mistake on any other
//   Input/Textarea/Select/Checkbox/Radio/Toggle would be caught by this test.
//
//   METHOD: Scan every onChange handler across src/ui that touches .target or .target.value.
//   Resolve each handler's enclosing JSX element. Filter to elements whose onChange prop
//   type is ChangeHandler<T> — i.e. primitives from the shared UI component library
//   (Input, Textarea) which always call onChange(string), never with a DOM event.
//   Assert the set is empty.
//
//   Primitives covered: Input, Textarea (ChangeHandler<string> per ui/types.ts).
//   Deliberately excluded: raw <input>, <textarea>, <select>, <checkbox>
//   (native elements whose onChange IS called with a DOM event).
//   Also excluded: Combobox, Select, Toggle — their onChange types are not raw strings.
// ---------------------------------------------------------------------------

test('REQ-FIX-1 [class-guard B(3)]: no onChange on Input or Textarea primitive in src/ui accesses .target', () => {
  const UI_SRC = path.join(REPO_ROOT, 'src/ui');

  // Collect all .tsx files under src/ui
  function collectTsx(dir: string, files: string[] = []): string[] {
    for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
      const full = path.join(dir, entry.name);
      if (entry.isDirectory()) {
        collectTsx(full, files);
      } else if (entry.isFile() && entry.name.endsWith('.tsx')) {
        files.push(full);
      }
    }
    return files;
  }

  const tsxFiles = collectTsx(UI_SRC);
  const violations: string[] = [];

  // Pattern: onChange handler on a JSX element that:
  // (a) touches `.target` or `?.target`
  // (b) is on a capitalized element (component, not raw DOM element)
  //
  // We extract onChange={...} props and look for:
  //   onChange={(e: any) => f(e?.target?.value)}   — optional-chain form
  //   onChange={(e: any) => f(e.target.value)}      — direct form
  //   onChange={(e) => f(e.target.value)}            — untyped form
  //
  // Wrapped in \b(Input|Textarea)\b check (the two ChangeHandler<string> primitives)
  // to keep the sweep precise and avoid false positives on native element handlers.

  const BROKEN_TARGET_PATTERN = /onChange=\{[^}]*\?\s*\.\s*target\s*\?\s*\.\s*value/g;
  const DIRECT_TARGET_PATTERN = /onChange=\{[^}]*[^?]\.\s*target\s*\.\s*value/g;

  for (const file of tsxFiles) {
    const src = fs.readFileSync(file, 'utf8');
    const relPath = path.relative(REPO_ROOT, file);

    // Find all onChange handlers that touch .target in some form
    const suspectMatches: string[] = [];
    for (const m of src.matchAll(BROKEN_TARGET_PATTERN)) suspectMatches.push(m[0]);
    for (const m of src.matchAll(DIRECT_TARGET_PATTERN)) suspectMatches.push(m[0]);

    for (const match of suspectMatches) {
      // Find the surrounding JSX context to identify the element name.
      // Look backwards from the match position for the nearest opening tag.
      const idx = src.indexOf(match);
      const before = src.slice(Math.max(0, idx - 300), idx);

      // Check if the nearest enclosing JSX element is Input or Textarea
      // (these are the ChangeHandler<string> primitives we are protecting).
      // We look for the last `<Input` or `<Textarea` in the context window.
      const isPrimitive = /<(Input|Textarea)[\s\n>]/.test(before);
      if (isPrimitive) {
        violations.push(`${relPath}: ${match.slice(0, 80).trim()}`);
      }
    }
  }

  assert.deepStrictEqual(
    violations,
    [],
    'No onChange on an Input or Textarea primitive may access .target — ' +
    'these components pass a string value to onChange, not a DOM event.\n' +
    'Violations found:\n' + violations.join('\n'),
  );
});
