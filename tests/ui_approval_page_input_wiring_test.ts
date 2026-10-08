// REQ-FIX-1: Regression tests for approval-page text-input wiring
//
// DEFECT: BridgeEnrollmentApprovalPage.tsx used `(e: any) => setState(e?.target?.value ?? '')`
// on two Input components whose onChange prop is ChangeHandler<string> — a function called
// with a string value, not a DOM event. The `.target` dereference always resolves to
// undefined, the ?? '' makes every keystroke set state to '', and because the inputs are
// controlled, React restores the DOM value to blank on every render. Result: both text
// fields are permanently blank, the Deliver button stays permanently disabled.
//
// These source-invariant tests fail against the broken code and pass after the fix.
// They guard against the exact anti-pattern being re-introduced.
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
// 1. No onChange on a primitive Input/Textarea accesses .target.value
//    (the anti-pattern that caused REQ-FIX-1)
// ---------------------------------------------------------------------------

test('REQ-FIX-1: no onChange handler in the approval page accesses e.target.value via optional chaining', () => {
  // The broken pattern: `e?.target?.value` where e is already a string.
  // Must not exist anywhere in this file on an Input/Textarea onChange.
  assert.doesNotMatch(
    content,
    /onChange=\{\s*\([^)]*\)\s*=>\s*\w+\([^)]*\?\s*\.\s*target\s*\?\s*\.\s*value/,
    'A ChangeHandler<string> onChange must not access .target.value — the handler receives the value directly',
  );
});

test('REQ-FIX-1: no onChange handler on this page carries a bare `: any` annotation', () => {
  // `: any` on an onChange arg hides the type mismatch that the compiler would otherwise catch.
  assert.doesNotMatch(
    content,
    /onChange=\{\s*\(\s*\w+\s*:\s*any\s*\)/,
    'onChange handlers must not be annotated `: any` — that defeats type-checking of ChangeHandler<T>',
  );
});

// ---------------------------------------------------------------------------
// 2. The master-password Input uses a direct value pass-through
// ---------------------------------------------------------------------------

test('REQ-FIX-1: setMasterPassword onChange passes the string value directly', () => {
  // Positive control: the fixed pattern must be present.
  // Matches: onChange={(value) => setMasterPassword(value)}
  assert.match(
    content,
    /onChange=\{\s*\(\s*value\s*\)\s*=>\s*setMasterPassword\(\s*value\s*\)/,
    'masterPassword Input onChange must be `(value) => setMasterPassword(value)` — not an event-shaped accessor',
  );
});

// ---------------------------------------------------------------------------
// 3. The device-code (codeInput) Input uses a direct value pass-through
// ---------------------------------------------------------------------------

test('REQ-FIX-1: setCodeInput onChange passes the string value directly', () => {
  assert.match(
    content,
    /onChange=\{\s*\(\s*value\s*\)\s*=>\s*setCodeInput\(\s*value\s*\)/,
    'codeInput Input onChange must be `(value) => setCodeInput(value)` — not an event-shaped accessor',
  );
});

// ---------------------------------------------------------------------------
// 4. Deliver vault key button is disabled by !masterPassword
//    If masterPassword is always reset to '' (the broken behaviour), the button
//    stays permanently disabled. This assertion documents the gating logic so a
//    refactor that changes the disabling condition is noticed.
// ---------------------------------------------------------------------------

test('REQ-FIX-1: Deliver vault key button is gated on !masterPassword', () => {
  assert.match(
    content,
    /disabled=\{!masterPassword\}/,
    'Deliver vault key button must be disabled={!masterPassword} — if state is always "" the button stays disabled',
  );
  assert.match(
    content,
    /Deliver vault key/,
    'The Deliver vault key button label must be present',
  );
});

// ---------------------------------------------------------------------------
// 5. ChangeHandler<T> contract: Input.tsx must call onChange with the value, not the event
// ---------------------------------------------------------------------------

test('REQ-FIX-1: Input.tsx calls onChange(event.target.value) — passes value, not DOM event', () => {
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
