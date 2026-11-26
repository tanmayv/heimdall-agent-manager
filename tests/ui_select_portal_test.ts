// REQ-TEST-VERIFY-1, REQ-FLEET-POLLING-1:
// Unit tests + regression guards for (a) the global portal dropdown in the
// Select primitive and (b) the elimination of fleet query polling loops in
// FleetManagementDrawer.
//
// Two complementary layers are used, matching the conventions of the other
// tests/ui_*_test.ts suites:
//   1. Static source contracts — the portal/positioning wiring lives inside a
//      React component and cannot be imported headlessly, so the wiring itself
//      (createPortal target, listener registration, ref checks) is asserted
//      against the source text.
//   2. Executable behaviour — `computeCoords` is module-private, so it is
//      extracted from the source and evaluated against synthetic viewports.
//      This exercises the REAL placement math (flip, clamp, height bounds)
//      rather than merely asserting that the code mentions it.
//
// RUN: node --test tests/ui_select_portal_test.ts

import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { readAppViewportHeight } from '../src/ui/utils/appViewportHeight.ts';
import './helpers/vaultEndpointHarness.ts';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const REPO_ROOT = path.resolve(__dirname, '..');

const SELECT_PATH = 'src/ui/components/ui/primitives/Select.tsx';

function readSource(relPath: string): string {
  const abs = path.join(REPO_ROOT, relPath);
  assert.ok(fs.existsSync(abs), `${relPath} must exist`);
  return fs.readFileSync(abs, 'utf8');
}

const selectSrc = readSource(SELECT_PATH);

test('Home opt-in choice sheet preserves controlled choices, keyboard, dismissal, focus and resize; other Selects retain popups', async () => {
  const { JSDOM } = await import('jsdom');
  const React = await import('react');
  const { act } = React;
  const dom = new JSDOM('<!doctype html><div id="root"></div><button id="fallback">Home</button>', { url: 'http://localhost/' });
  const win = dom.window as any;
  let narrow = true;
  const listeners = new Set<() => void>();
  win.matchMedia = () => ({ get matches() { return narrow; }, addEventListener(_type: string, cb: () => void) { listeners.add(cb); }, removeEventListener(_type: string, cb: () => void) { listeners.delete(cb); } });
  win.HTMLElement.prototype.scrollIntoView = function () {};
  win.CSS = { escape: (value: string) => value.replace(/[^a-zA-Z0-9_-]/g, (c: string) => '\\' + c) };
  const saved = new Map(['window', 'document', 'HTMLElement', 'Node', 'CSS', 'IS_REACT_ACT_ENVIRONMENT'].map((key) => [key, (globalThis as any)[key]]));
  Object.assign(globalThis, { window: win, document: win.document, HTMLElement: win.HTMLElement, Node: win.Node, CSS: win.CSS, IS_REACT_ACT_ENVIRONMENT: true });
  const { createRoot } = await import('react-dom/client');
  const { Select } = await import('../src/ui/components/ui/primitives/Select.tsx');
  const root = createRoot(win.document.getElementById('root'));
  const doc = win.document;
  let value = 'unavailable';
  const changes: string[] = [];
  let opts = [{ value: 'unavailable', label: 'Saved profile (unavailable)', disabled: true }, { value: 'a', label: 'Profile A' }, { value: 'disabled', label: 'Disabled', disabled: true }, { value: 'b', label: 'Profile B with a very long model label' }];
  const render = () => act(async () => root.render(React.createElement(React.Fragment, null,
    React.createElement(Select, { value, options: opts, mobileSheet: true, name: 'runtime', 'aria-label': 'Default provider', 'data-debug-id': 'home-test', sheetFocusFallback: () => doc.getElementById('fallback'), onChange: (next: string) => { changes.push(next); value = next; } }),
    React.createElement(Select, { value: 'a', options: opts, 'aria-label': 'Unrelated', 'data-debug-id': 'other-test', onChange() {} }))));
  const trigger = () => doc.querySelector('[data-debug-id="home-test"]') as HTMLButtonElement;
  const list = () => doc.querySelector('[role="listbox"]') as HTMLElement;
  const open = () => act(async () => { trigger().focus(); trigger().click(); });
  const key = (name: string) => act(async () => doc.activeElement!.dispatchEvent(new win.KeyboardEvent('keydown', { key: name, bubbles: true, cancelable: true })));
  const finish = () => act(async () => { doc.querySelector('[role="dialog"]')?.dispatchEvent(new win.Event('animationend', { bubbles: true })); });
  try {
    await render(); await open();
    const dialog = doc.querySelector('[role="dialog"]')!;
    assert.equal(dialog.getAttribute('aria-modal'), 'true');
    assert.ok(dialog.textContent!.includes('Default provider'));
    assert.equal(doc.body.style.overflow, 'hidden');
    assert.equal(doc.activeElement, list());
    assert.equal(trigger().hasAttribute('aria-activedescendant'), false, 'trigger never references a choice while focus is in the sheet');
    assert.equal(doc.getElementById(list().getAttribute('aria-activedescendant')!).textContent, 'Profile A');
    assert.equal(list().querySelector('[aria-selected="true"]')!.getAttribute('aria-disabled'), 'true');
    await key('ArrowDown');
    assert.match(doc.getElementById(list().getAttribute('aria-activedescendant')!).textContent, /Profile B/);
    await key('Home'); await key('End'); await key('Enter'); await render();
    assert.deepEqual(changes, ['b'], 'single choice commits once');
    assert.equal(trigger().getAttribute('aria-expanded'), 'false');
    assert.equal(doc.activeElement, trigger());
    assert.equal(doc.querySelector('input[name="runtime"]').value, 'b');
    assert.equal(doc.body.style.overflow, '');
    await finish(); await open(); await key('ArrowUp'); await key('Escape'); await finish();
    assert.deepEqual(changes, ['b'], 'Escape leaves value unchanged');
    await open();
    await act(async () => doc.querySelector('[role="dialog"]')!.parentElement!.dispatchEvent(new win.MouseEvent('mousedown', { bubbles: true })));
    await finish(); assert.deepEqual(changes, ['b'], 'backdrop leaves value unchanged');
    await open();
    await act(async () => { narrow = false; listeners.forEach((cb) => cb()); });
    assert.equal(doc.querySelector('[role="dialog"]'), null);
    assert.equal(doc.querySelector('[role="listbox"]'), null);
    assert.equal(doc.body.style.overflow, '');
    await open();
    assert.equal(doc.querySelector('[role="dialog"]'), null);
    assert.equal(list().style.position, 'fixed', 'desktop stays anchored');
    await key('Escape');
    await act(async () => { narrow = true; listeners.forEach((cb) => cb()); });
    await act(async () => (doc.querySelector('[data-debug-id="other-test"]') as HTMLElement).click());
    assert.equal(doc.querySelector('[role="dialog"]'), null, 'unrelated mobile consumer keeps the popup');
    await act(async () => (doc.querySelector('[data-debug-id="other-test"]') as HTMLElement).dispatchEvent(new win.KeyboardEvent('keydown', { key: 'Escape', bubbles: true })));
    opts = []; await render(); await open();
    assert.match(list().textContent!, /No options available/);
    assert.equal(list().hasAttribute('aria-activedescendant'), false);
    await key('Enter'); assert.deepEqual(changes, ['b']);
    await act(async () => root.unmount());
    assert.equal(doc.querySelector('[role="dialog"]'), null);
    assert.equal(doc.body.style.overflow, '');
    assert.equal(doc.activeElement, doc.getElementById('fallback'));
    assert.equal(listeners.size, 0);
  } finally {
    await act(async () => root.unmount());
    dom.window.close();
    for (const [key, previous] of saved) (globalThis as any)[key] = previous;
  }
});

// -----------------------------------------------------------------------------
// Helpers: slice a top-level function out of the source by brace matching.
// -----------------------------------------------------------------------------

/** Source text of `function <name>(...) { ... }`, braces balanced. */
function extractFunction(src: string, name: string): string {
  const start = src.indexOf(`function ${name}(`);
  assert.ok(start >= 0, `${name} must be declared in the source`);
  const open = src.indexOf('{', start);
  assert.ok(open > start, `${name} must have a body`);
  let depth = 0;
  for (let i = open; i < src.length; i++) {
    const ch = src[i];
    if (ch === '{') depth++;
    else if (ch === '}') {
      depth--;
      if (depth === 0) return src.slice(start, i + 1);
    }
  }
  assert.fail(`unbalanced braces while extracting ${name}`);
}

/** Numeric value of a module-level `const <name> = <int>;`. */
function numericConst(src: string, name: string): number {
  const match = src.match(new RegExp(`const ${name} = (-?\\d+);`));
  assert.ok(match, `${name} must be declared as a numeric constant`);
  return Number(match[1]);
}

const POSITIONING_CONSTANTS = [
  'TRIGGER_GAP',
  'VIEWPORT_MARGIN',
  'MAX_POPUP_HEIGHT',
  'FLIP_THRESHOLD',
  'MIN_POPUP_HEIGHT',
] as const;

interface FakeWindow {
  innerWidth: number;
  /** The LAYOUT viewport. A soft keyboard does NOT shrink this. */
  innerHeight: number;
  /** REQ-VIEWPORT-SWEEP-1: present only when a case models an occluded visual viewport. */
  visualViewport?: { height: number; scale?: number };
}

interface FakeRect {
  top: number;
  bottom: number;
  left: number;
  width: number;
}

interface Coords {
  left: number;
  width: number;
  maxHeight: number;
  top?: number;
  bottom?: number;
}

/**
 * Compile Select.tsx's private `computeCoords` against a synthetic `window`.
 * Type annotations are the only TS syntax in the function, so stripping them
 * yields plain JS that `new Function` can evaluate.
 */
function compileComputeCoords(win: FakeWindow): (rect: FakeRect) => Coords {
  const consts = POSITIONING_CONSTANTS
    .map((name) => `const ${name} = ${numericConst(selectSrc, name)};`)
    .join('\n');
  const body = extractFunction(selectSrc, 'computeCoords')
    .replace(/: DOMRect/g, '')
    .replace(/: PopupCoords/g, '');
  const factory = new Function(
    'window',
    'readAppViewportHeight',
    `${consts}\n${body}\nreturn computeCoords;`,
  );
  return factory(win, readAppViewportHeight) as (rect: FakeRect) => Coords;
}

// -----------------------------------------------------------------------------
// Executable placement math: width, flipping, clamping (REQ-TEST-VERIFY-1)
// -----------------------------------------------------------------------------

test('computeCoords opens downwards and mirrors the trigger width when there is room below', () => {
  const computeCoords = compileComputeCoords({ innerWidth: 1280, innerHeight: 1000 });
  const gap = numericConst(selectSrc, 'TRIGGER_GAP');
  const maxHeight = numericConst(selectSrc, 'MAX_POPUP_HEIGHT');

  const coords = computeCoords({ top: 100, bottom: 130, left: 50, width: 200 });

  assert.equal(coords.top, 130 + gap, 'popup sits a TRIGGER_GAP below the trigger');
  assert.equal(coords.bottom, undefined, 'a downward popup must not set bottom');
  assert.equal(coords.left, 50, 'popup is left-aligned with the trigger');
  assert.equal(coords.width, 200, 'popup width mirrors the trigger width exactly');
  assert.equal(coords.maxHeight, maxHeight, 'ample room below is bounded by MAX_POPUP_HEIGHT');
});

test('computeCoords auto-flips above the trigger when room below is cramped', () => {
  const innerHeight = 400;
  const computeCoords = compileComputeCoords({ innerWidth: 1280, innerHeight });
  const gap = numericConst(selectSrc, 'TRIGGER_GAP');

  // spaceBelow = 70 (< FLIP_THRESHOLD 180) and spaceAbove = 300 (> spaceBelow).
  const coords = computeCoords({ top: 300, bottom: 330, left: 20, width: 160 });

  assert.equal(coords.top, undefined, 'a flipped popup must not set top');
  assert.equal(
    coords.bottom,
    innerHeight - 300 + gap,
    'flipped popup is anchored a TRIGGER_GAP above the trigger top',
  );
  assert.equal(coords.width, 160, 'flipping does not change the mirrored width');
});

test('computeCoords stays below when room below is cramped but room above is smaller', () => {
  const computeCoords = compileComputeCoords({ innerWidth: 1280, innerHeight: 200 });
  const gap = numericConst(selectSrc, 'TRIGGER_GAP');
  const margin = numericConst(selectSrc, 'VIEWPORT_MARGIN');

  // spaceBelow = 140 (< FLIP_THRESHOLD) but spaceAbove = 30, so no flip.
  const coords = computeCoords({ top: 30, bottom: 60, left: 10, width: 120 });

  assert.equal(coords.top, 60 + gap, 'popup remains below the trigger');
  assert.equal(coords.bottom, undefined, 'no flip means no bottom anchor');
  assert.equal(
    coords.maxHeight,
    140 - gap - margin,
    'height is bounded by the room below, minus gap and viewport margin',
  );
});

test('computeCoords never shrinks the popup below MIN_POPUP_HEIGHT', () => {
  const computeCoords = compileComputeCoords({ innerWidth: 1280, innerHeight: 100 });
  const minHeight = numericConst(selectSrc, 'MIN_POPUP_HEIGHT');

  // Both sides are tiny: available height would be 28px if left unbounded.
  const coords = computeCoords({ top: 40, bottom: 70, left: 10, width: 120 });

  assert.equal(coords.maxHeight, minHeight, 'maxHeight floors at MIN_POPUP_HEIGHT');
});

test('REQ-VIEWPORT-SWEEP-1: computeCoords measures the room below against the VISIBLE viewport, so a Select near the keyboard flips instead of opening into the dead zone', () => {
  const gap = numericConst(selectSrc, 'TRIGGER_GAP');
  const margin = numericConst(selectSrc, 'VIEWPORT_MARGIN');
  const win = { innerWidth: 390, innerHeight: 812, visualViewport: { height: 409, scale: 1 } };
  const computeCoords = compileComputeCoords(win);

  const coords = computeCoords({ top: 330, bottom: 360, left: 20, width: 200 });

  assert.equal(coords.top, undefined, 'must not open downwards into the keyboard dead zone');
  assert.equal(
    coords.bottom,
    812 - 330 + gap,
    'the flipped anchor is a layout-viewport offset, not a visible-region one',
  );
  assert.ok(
    coords.maxHeight <= 330 - gap - margin,
    'height is bounded by the room actually visible above the trigger',
  );
});

test('REQ-VIEWPORT-SWEEP-1: a pinch-zoomed visual viewport is not treated as a keyboard', () => {
  const gap = numericConst(selectSrc, 'TRIGGER_GAP');
  const win = { innerWidth: 1280, innerHeight: 1000, visualViewport: { height: 300, scale: 2 } };
  const computeCoords = compileComputeCoords(win);

  const coords = computeCoords({ top: 100, bottom: 130, left: 50, width: 200 });

  assert.equal(coords.top, 130 + gap, 'pinch-zoom must not flip the popup');
});

test('computeCoords clamps the popup horizontally inside the viewport', () => {
  const innerWidth = 500;
  const computeCoords = compileComputeCoords({ innerWidth, innerHeight: 1000 });
  const margin = numericConst(selectSrc, 'VIEWPORT_MARGIN');

  const rightEdge = computeCoords({ top: 10, bottom: 40, left: 450, width: 200 });
  assert.equal(
    rightEdge.left,
    innerWidth - 200 - margin,
    'popup is pulled left so it keeps VIEWPORT_MARGIN from the right edge',
  );
  assert.ok(
    rightEdge.left + rightEdge.width <= innerWidth - margin,
    'clamped popup never crosses the right viewport edge',
  );

  const leftEdge = computeCoords({ top: 10, bottom: 40, left: -30, width: 120 });
  assert.equal(leftEdge.left, margin, 'popup is pushed to VIEWPORT_MARGIN at the left edge');

  const inside = computeCoords({ top: 10, bottom: 40, left: 120, width: 200 });
  assert.equal(inside.left, 120, 'an unconstrained popup keeps the trigger left offset');
});
