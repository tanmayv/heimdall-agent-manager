// REQ-FIX-1: Behavioral render-and-type regression tests for the approval page input wiring.
//
// WHAT THESE TESTS PROVE
// ─────────────────────
// The defect (b8d16379^): BridgeEnrollmentApprovalPage.tsx used
//   onChange={(e: any) => setMasterPassword(e?.target?.value ?? '')}
// Input.tsx:138 calls `onChange(event.target.value)` — the handler receives a STRING.
// e?.target on a string is undefined; undefined?.value is undefined; ?? '' is always ''.
// State stayed '' → button disabled={!masterPassword} stayed disabled permanently.
//
// The fix: onChange={(value) => setMasterPassword(value)}
//
// These tests render the Input component in a jsdom DOM environment and simulate
// typing to assert that the correct wiring pattern updates state and enables the button.
// They are non-vacuous: if the handler is changed to the broken pattern
//   (e: any) => setState(e?.target?.value ?? '')
// the state never updates and the assertion `!button.disabled` fails.
//
// HOW TO PROVE NON-VACUITY AGAINST b8d16379^
// ─────────────────────────────────────────────
// Check out b8d16379^, change the onChange on line 797 of BridgeEnrollmentApprovalPage.tsx
// back to `(e: any) => setMasterPassword(e?.target?.value ?? '')`, copy that handler
// into the TestPasswordForm harness below, and re-run this test — the button assertion
// fails. (Rendering the full BridgeEnrollmentApprovalPage headlessly requires mocking
// Redux + RTK Query + multi-step user flow; see B(3) in ui_approval_page_input_wiring_test.ts
// which IS directly non-vacuous against b8d16379^.)
//
// RUN: node --test tests/ui_approval_page_render_test.ts
// (also matched by the glob in the `test` script in package.json)

import { createRequire, registerHooks } from 'node:module';
import { fileURLToPath, URL } from 'node:url';
import fs from 'node:fs';
import path from 'node:path';
import { test } from 'node:test';
import assert from 'node:assert/strict';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const REPO_ROOT = path.resolve(__dirname, '..');

// ── esbuild: TSX/TS transformation ─────────────────────────────────────────
// esbuild is a transitive devDependency via vite. We load it via createRequire
// (its main entry is CJS) to get synchronous transformSync for the load hook.
const _req = createRequire(REPO_ROOT + '/package.json');
const { transformSync } = _req('esbuild') as { transformSync: (code: string, opts: Record<string, unknown>) => { code: string } };

// ── Module hooks: tsx/ts transformation + extensionless imports ─────────────
// These must be registered before any tsx/ts dynamic imports below.
registerHooks({
  load(url: string, _ctx: unknown, nextLoad: (url: string, ctx: unknown) => unknown) {
    if (url.startsWith('file:') && /\.(ts|tsx)$/.test(url)) {
      const source = fs.readFileSync(fileURLToPath(url), 'utf8');
      const loader = url.endsWith('.tsx') ? 'tsx' : 'ts';
      const result = transformSync(source, {
        loader,
        format: 'esm',
        target: 'esnext',
        jsxFactory: 'React.createElement',
        jsxFragment: 'React.Fragment',
      });
      return { format: 'module', source: result.code, shortCircuit: true };
    }
    return nextLoad(url, _ctx);
  },
  resolve(specifier: string, ctx: { parentURL?: string }, nextResolve: (s: string, c: unknown) => unknown) {
    // Resolve extensionless relative imports (.ts / .tsx) used throughout src/ui
    if (specifier.startsWith('.') && ctx.parentURL) {
      const base = fileURLToPath(new URL(specifier, ctx.parentURL));
      for (const ext of ['.ts', '.tsx']) {
        if (fs.existsSync(base + ext)) {
          return { url: new URL(specifier + ext, ctx.parentURL).href, shortCircuit: true };
        }
      }
    }
    return nextResolve(specifier, ctx);
  },
});

// ── jsdom DOM environment ───────────────────────────────────────────────────
// Must be set up BEFORE React is loaded so React's feature detection sees a DOM.
const { JSDOM } = await import('jsdom');
const jsdom = new JSDOM('<!DOCTYPE html><html><body></body></html>', {
  url: 'http://localhost/',
});
const { window } = jsdom;

// Expose the jsdom globals React needs for event delegation and DOM operations.
// Some Node globals are read-only getters (e.g. navigator), so we use
// Object.defineProperty with force-overwrite where needed.
function setGlobal(key: string, value: unknown) {
  try {
    (globalThis as Record<string, unknown>)[key] = value;
  } catch {
    Object.defineProperty(globalThis, key, { value, writable: true, configurable: true });
  }
}
setGlobal('window', window);
setGlobal('document', window.document);
setGlobal('navigator', window.navigator);
setGlobal('Node', window.Node);
setGlobal('Element', window.Element);
setGlobal('HTMLElement', window.HTMLElement);
setGlobal('HTMLInputElement', window.HTMLInputElement);
setGlobal('HTMLButtonElement', window.HTMLButtonElement);
setGlobal('Event', window.Event);
setGlobal('InputEvent', window.InputEvent);
setGlobal('CustomEvent', window.CustomEvent);

// ── React + react-dom ───────────────────────────────────────────────────────
// Dynamic imports after hooks and globals are set up.
const ReactModule = await import('react');
const React = ReactModule.default;
const { useState } = ReactModule;
const { createRoot } = await import('react-dom/client');
const { act } = await import('react');

// ── Input primitive ─────────────────────────────────────────────────────────
// Import the actual Input component from source.
// The load hook above transforms Input.tsx via esbuild.
const { Input } = await import(REPO_ROOT + '/src/ui/components/ui/primitives/Input.tsx') as {
  Input: React.ForwardRefExoticComponent<{ value: string; onChange: (v: string) => void; type?: string; [k: string]: unknown }>;
};

// ── Helper: fresh container ─────────────────────────────────────────────────
function makeContainer() {
  const el = window.document.createElement('div');
  window.document.body.appendChild(el);
  return el;
}

// ── Helper: simulate an input event ─────────────────────────────────────────
// Sets input.value then dispatches a bubbling 'input' event so React's synthetic
// onChange fires (React 18 maps DOM 'input' → synthetic onChange for <input>).
function fireInput(el: HTMLInputElement, value: string) {
  Object.defineProperty(el, 'value', { writable: true, configurable: true, value });
  el.dispatchEvent(new (window.Event as typeof Event)('input', { bubbles: true }));
}

// ────────────────────────────────────────────────────────────────────────────
// TEST A1: master-password field
// ────────────────────────────────────────────────────────────────────────────
//
// Harness mirrors the EXACT wiring from BridgeEnrollmentApprovalPage.tsx:797
// after the fix.  Proves non-vacuity by swapping the handler to the broken
// pattern (e: any) => setMasterPassword(e?.target?.value ?? '') — the
// button-enable assertion then fails.
//
// This is a REGRESSION test: it would also fail if Input.tsx changed to pass
// the DOM event to onChange instead of the string value.

test('REQ-FIX-1 render-A1: typing into master-password Input enables Deliver vault key button', async () => {
  const container = makeContainer();

  function TestPasswordForm() {
    const [masterPassword, setMasterPassword] = useState('');
    return React.createElement('div', null,
      React.createElement(Input, {
        type: 'password',
        value: masterPassword,
        // Fixed wiring: handler receives string value directly
        onChange: (value: string) => setMasterPassword(value),
      }),
      React.createElement('button', {
        type: 'submit',
        disabled: !masterPassword,
        'data-testid': 'deliver-btn',
      }, 'Deliver vault key'),
    );
  }

  await act(async () => {
    createRoot(container).render(React.createElement(TestPasswordForm));
  });

  const input = container.querySelector('input[type="password"]') as HTMLInputElement;
  const button = container.querySelector('[data-testid="deliver-btn"]') as HTMLButtonElement;

  assert.ok(input, 'password <input> must be rendered');
  assert.ok(button, '"Deliver vault key" <button> must be rendered');
  assert.ok(button.disabled, 'button must be disabled when password is empty');

  // Simulate the user typing a master password
  await act(async () => {
    fireInput(input, 'my-vault-password');
  });

  assert.strictEqual(
    button.disabled,
    false,
    'button must be enabled after typing a master password — ' +
    'fails with (e: any) => setState(e?.target?.value ?? \'\') because Input passes a string, not a DOM event',
  );
});

// ────────────────────────────────────────────────────────────────────────────
// TEST A2: device-code (codeInput) field
// ────────────────────────────────────────────────────────────────────────────
//
// Harness mirrors BridgeEnrollmentApprovalPage.tsx:607 after the fix.
// Proves typing is correctly reflected in state.

test('REQ-FIX-1 render-A2: typing into device-code Input updates state (value reaches controlled Input)', async () => {
  const container = makeContainer();

  let capturedValue = '';

  function TestDeviceCodeForm() {
    const [codeInput, setCodeInput] = useState('');
    capturedValue = codeInput;
    return React.createElement('div', null,
      React.createElement(Input, {
        type: 'text',
        value: codeInput,
        // Fixed wiring: handler receives string value directly
        onChange: (value: string) => setCodeInput(value),
      }),
      React.createElement('button', {
        type: 'button',
        disabled: !codeInput,
        'data-testid': 'continue-btn',
      }, 'Continue'),
    );
  }

  await act(async () => {
    createRoot(container).render(React.createElement(TestDeviceCodeForm));
  });

  const input = container.querySelector('input[type="text"]') as HTMLInputElement;
  const button = container.querySelector('[data-testid="continue-btn"]') as HTMLButtonElement;

  assert.ok(input, 'device-code <input> must be rendered');
  assert.ok(button, 'Continue <button> must be rendered');
  assert.ok(button.disabled, 'button must be disabled when code is empty');

  // Simulate the user entering a device code (e.g. "ABCD-1234")
  await act(async () => {
    fireInput(input, 'ABCD-1234');
  });

  assert.strictEqual(
    capturedValue,
    'ABCD-1234',
    'state must equal the typed value — ' +
    'fails with (e: any) => setState(e?.target?.value ?? \'\') because e is a string without a .target property',
  );
  assert.strictEqual(
    button.disabled,
    false,
    'Continue button must be enabled after the user types a valid code',
  );
});
