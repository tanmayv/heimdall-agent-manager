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

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const REPO_ROOT = path.resolve(__dirname, '..');

const SELECT_PATH = 'src/ui/components/ui/primitives/Select.tsx';
const FLEET_DRAWER_PATH = 'src/ui/components/tasks/FleetManagementDrawer.tsx';

function readSource(relPath: string): string {
  const abs = path.join(REPO_ROOT, relPath);
  assert.ok(fs.existsSync(abs), `${relPath} must exist`);
  return fs.readFileSync(abs, 'utf8');
}

const selectSrc = readSource(SELECT_PATH);
const fleetSrc = readSource(FLEET_DRAWER_PATH);

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
  // REQ-VIEWPORT-SWEEP-1: `computeCoords` now calls `readAppViewportHeight`. The REAL
  // function is injected rather than a stand-in, so these cases exercise the production
  // visual-viewport logic (including its pinch-zoom fallback) and not a second copy of it.
  const factory = new Function(
    'window',
    'readAppViewportHeight',
    `${consts}\n${body}\nreturn computeCoords;`,
  );
  return factory(win, readAppViewportHeight) as (rect: FakeRect) => Coords;
}

// -----------------------------------------------------------------------------
// 1. Portal wiring (REQ-TEST-VERIFY-1)
// -----------------------------------------------------------------------------

test('Select.tsx imports createPortal from react-dom and portals the listbox into document.body', () => {
  assert.match(
    selectSrc,
    /import \{ createPortal \} from 'react-dom';/,
    'Select must import { createPortal } from react-dom',
  );

  // The listbox must actually be portaled, and document.body must be the target
  // argument of that createPortal call (not merely mentioned elsewhere).
  const call = extractCreatePortalCall(selectSrc);
  assert.match(call, /role="listbox"/, 'the portaled subtree must be the role="listbox" popup');
  assert.match(
    call,
    /,\s*document\.body,?\s*\)$/,
    'createPortal must target document.body',
  );

  // Guard against SSR/non-DOM evaluation of the portal.
  assert.match(
    selectSrc,
    /typeof document !== 'undefined'/,
    'the portal render must be guarded on document being available',
  );

  // The popup must not be rendered inline inside the wrapper (which would keep
  // it inside ancestor clipping contexts) — createPortal is the only path.
  assert.equal(
    (selectSrc.match(/createPortal\(/g) ?? []).length,
    1,
    'exactly one createPortal call is expected',
  );
});

/** Source text of the single `createPortal(...)` call, parens balanced. */
function extractCreatePortalCall(src: string): string {
  const start = src.indexOf('createPortal(');
  assert.ok(start >= 0, 'Select must call createPortal');
  const open = src.indexOf('(', start);
  let depth = 0;
  for (let i = open; i < src.length; i++) {
    const ch = src[i];
    if (ch === '(') depth++;
    else if (ch === ')') {
      depth--;
      if (depth === 0) return src.slice(start, i + 1);
    }
  }
  assert.fail('unbalanced parens while extracting the createPortal call');
}

test('Select.tsx positions the portaled listbox with fixed coords derived from the trigger rect', () => {
  const call = extractCreatePortalCall(selectSrc);

  assert.match(call, /position: 'fixed'/, 'the popup must be position: fixed');
  assert.match(call, /left: coords\.left/, 'left must come from the computed coords');
  assert.match(call, /top: coords\.top/, 'top must come from the computed coords');
  assert.match(call, /bottom: coords\.bottom/, 'bottom must come from the computed coords');
  assert.match(call, /width: coords\.width/, 'width must come from the computed coords');
  assert.match(call, /maxHeight: coords\.maxHeight/, 'maxHeight must come from the computed coords');

  // Coords are produced from the trigger's viewport rect, recomputed in a
  // layout effect so the first paint is already placed correctly.
  assert.match(
    selectSrc,
    /useLayoutEffect\(/,
    'placement must run in a layout effect (pre-paint)',
  );
  assert.match(
    selectSrc,
    /computeCoords\(trigger\.getBoundingClientRect\(\)\)/,
    'coords must be computed from the trigger getBoundingClientRect()',
  );

  // Re-place on capture-phase scroll (so inner scrollers count) and on resize.
  assert.match(
    selectSrc,
    /window\.addEventListener\('scroll', update, true\)/,
    'scroll listener must be registered in the capture phase',
  );
  assert.match(
    selectSrc,
    /window\.removeEventListener\('scroll', update, true\)/,
    'the capture-phase scroll listener must be cleaned up',
  );
  assert.match(
    selectSrc,
    /window\.addEventListener\('resize', update\)/,
    'resize listener must be registered',
  );
  assert.match(
    selectSrc,
    /window\.removeEventListener\('resize', update\)/,
    'the resize listener must be cleaned up',
  );
});

// -----------------------------------------------------------------------------
// 2. Executable placement math: width, flipping, clamping (REQ-TEST-VERIFY-1)
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
  // The REQ-KBD-1 device with the keyboard up: the layout viewport holds at 812 while the
  // visible region collapses to 409. The trigger sits at 330..360, just above the fold.
  const win = { innerWidth: 390, innerHeight: 812, visualViewport: { height: 409, scale: 1 } };
  const computeCoords = compileComputeCoords(win);

  const coords = computeCoords({ top: 330, bottom: 360, left: 20, width: 200 });

  // Against `innerHeight` the room below reads as 452px — ample — so the popup opened
  // downwards from y=368 into a region the user cannot see. Against the visible height it is
  // 49px, below FLIP_THRESHOLD, with 330px above: it flips.
  assert.equal(coords.top, undefined, 'must not open downwards into the keyboard dead zone');
  assert.equal(
    coords.bottom,
    // Still measured from the LAYOUT viewport's bottom edge, because that is what `bottom`
    // means for a `position: fixed` box. See the comment on this line in Select.tsx.
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
  // `visualViewport.height` reports the zoomed-in slice here. `readAppViewportHeight` falls
  // back to `innerHeight` above its unzoomed-scale threshold, so placement is unchanged.
  const win = { innerWidth: 1280, innerHeight: 1000, visualViewport: { height: 300, scale: 2 } };
  const computeCoords = compileComputeCoords(win);

  const coords = computeCoords({ top: 100, bottom: 130, left: 50, width: 200 });

  assert.equal(coords.top, 130 + gap, 'pinch-zoom must not flip the popup');
});

test('computeCoords clamps the popup horizontally inside the viewport', () => {
  const innerWidth = 500;
  const computeCoords = compileComputeCoords({ innerWidth, innerHeight: 1000 });
  const margin = numericConst(selectSrc, 'VIEWPORT_MARGIN');

  // Trigger near the right edge: popup would overflow, so it is pulled left.
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

  // Trigger off the left edge: popup is pushed back to the margin.
  const leftEdge = computeCoords({ top: 10, bottom: 40, left: -30, width: 120 });
  assert.equal(leftEdge.left, margin, 'popup is pushed to VIEWPORT_MARGIN at the left edge');

  // A trigger comfortably inside the viewport is not moved.
  const inside = computeCoords({ top: 10, bottom: 40, left: 120, width: 200 });
  assert.equal(inside.left, 120, 'an unconstrained popup keeps the trigger left offset');
});

// -----------------------------------------------------------------------------
// 3. Click-outside across both subtrees (REQ-TEST-VERIFY-1)
// -----------------------------------------------------------------------------

test('Select.tsx closes on outside pointer-down, treating rootRef AND listboxRef as inside', () => {
  assert.match(
    selectSrc,
    /const rootRef = useRef<HTMLDivElement \| null>\(null\)/,
    'rootRef must exist for the trigger wrapper',
  );
  assert.match(
    selectSrc,
    /const listboxRef = useRef<HTMLUListElement \| null>\(null\)/,
    'listboxRef must exist for the portaled listbox',
  );
  assert.match(selectSrc, /<div ref=\{rootRef\}/, 'rootRef must be attached to the wrapper div');

  const portalCall = extractCreatePortalCall(selectSrc);
  assert.match(portalCall, /ref=\{listboxRef\}/, 'listboxRef must be attached to the portaled <ul>');

  // The portaled listbox is NOT a DOM descendant of rootRef, so BOTH subtrees
  // must count as "inside" or every click on an option would close the popup.
  assert.match(
    selectSrc,
    /rootRef\.current\?\.contains\(target\) \|\| listboxRef\.current\?\.contains\(target\)/,
    'outside detection must check rootRef.contains OR listboxRef.contains',
  );
  assert.match(
    selectSrc,
    /document\.addEventListener\('mousedown', onDown\)/,
    'outside detection must listen for mousedown on document',
  );
  assert.match(
    selectSrc,
    /document\.removeEventListener\('mousedown', onDown\)/,
    'the mousedown listener must be cleaned up',
  );
});

// -----------------------------------------------------------------------------
// 4. Fleet polling regression guard (REQ-FLEET-POLLING-1)
// -----------------------------------------------------------------------------

/** Argument text of every `<hookName>(...)` call, parens balanced. */
function extractCallArgs(src: string, hookName: string): string[] {
  const calls: string[] = [];
  const needle = `${hookName}(`;
  let from = 0;
  for (;;) {
    const start = src.indexOf(needle, from);
    if (start < 0) break;
    const open = start + needle.length - 1;
    let depth = 0;
    let end = -1;
    for (let i = open; i < src.length; i++) {
      const ch = src[i];
      if (ch === '(') depth++;
      else if (ch === ')') {
        depth--;
        if (depth === 0) {
          end = i;
          break;
        }
      }
    }
    assert.ok(end > open, `unbalanced parens in a ${hookName} call`);
    calls.push(src.slice(open + 1, end));
    from = end + 1;
  }
  return calls;
}

test('FleetManagementDrawer.tsx invokes useGetTaskChainFleetsQuery without any pollingInterval', () => {
  const calls = extractCallArgs(fleetSrc, 'useGetTaskChainFleetsQuery');

  // Both consumers (FleetSlotChips and the drawer itself) must be covered.
  assert.equal(calls.length, 2, 'both useGetTaskChainFleetsQuery call sites must be present');

  calls.forEach((args, index) => {
    assert.ok(
      !/pollingInterval/.test(args),
      `useGetTaskChainFleetsQuery call #${index + 1} must not pass pollingInterval (args: ${args.trim()})`,
    );
    assert.match(
      args,
      /skip: !chainId/,
      `useGetTaskChainFleetsQuery call #${index + 1} must still skip when chainId is empty`,
    );
  });
});

test('FleetManagementDrawer.tsx documents the no-polling contract and keeps explicit refetch', () => {
  assert.match(
    fleetSrc,
    /REQ-FLEET-POLLING-1/,
    'the no-polling decision must be annotated with its REQ id',
  );

  // Freshness now comes from cache invalidation plus the explicit refetch after
  // an apply — the drawer must still destructure refetch.
  assert.match(
    fleetSrc,
    /const \{ data: rawFleets = \[\], refetch \} = useGetTaskChainFleetsQuery/,
    'the drawer must keep the explicit refetch handle',
  );

  // Boundary check: the unrelated bridges query keeps its slow poll, so the
  // assertion above is genuinely scoped to the fleet query and not to the file.
  assert.match(
    fleetSrc,
    /useListBridgesQuery\(undefined, \{ pollingInterval: 120000 \}\)/,
    'the unrelated bridges directory poll is intentionally retained',
  );
});

// -----------------------------------------------------------------------------
// 5. Active-option-visible-on-open invariant (coordinator directive
//    cmt_18d91e4a40abe74c, REQ-TEST-VERIFY-1)
//
// The listbox is gated on `coords`, which the layout effect sets in a SECOND
// commit. Under React 18 commit timing this passive effect runs after the FIRST
// commit, while listboxRef.current is still null — so `popupMounted` must appear
// in BOTH the guard and the dependency array or the active option is never
// revealed on open. This test pins that specific regression class.
// -----------------------------------------------------------------------------

/**
 * Source text of the `useEffect(...)` call whose body contains `needle`,
 * including its dependency array. Walks back to the nearest preceding
 * `useEffect(` and paren-matches forward from there.
 */
function extractEffectContaining(src: string, needle: string): string {
  const needleAt = src.indexOf(needle);
  assert.ok(needleAt >= 0, `the source must contain ${needle}`);
  const start = src.lastIndexOf('useEffect(', needleAt);
  assert.ok(start >= 0, `${needle} must live inside a useEffect`);
  const open = src.indexOf('(', start);
  let depth = 0;
  for (let i = open; i < src.length; i++) {
    const ch = src[i];
    if (ch === '(') depth++;
    else if (ch === ')') {
      depth--;
      if (depth === 0) return src.slice(start, i + 1);
    }
  }
  assert.fail(`unbalanced parens while extracting the useEffect around ${needle}`);
}

/** The `[a, b, c]` dependency array of an extracted effect, as tokens. */
function dependencyTokens(effectSrc: string): string[] {
  const match = effectSrc.match(/\}, *\[([^\]]*)\]\s*\)$/);
  assert.ok(match, 'the effect must end with a dependency array');
  return match[1]
    .split(',')
    .map((token) => token.trim())
    .filter(Boolean);
}

test('Select.tsx keeps the active option visible on open (popupMounted gates the scrollIntoView effect)', () => {
  // The second-commit flag itself must be derived from coords.
  assert.match(
    selectSrc,
    /const popupMounted = coords !== null;/,
    'popupMounted must be derived from coords being set',
  );

  const effect = extractEffectContaining(selectSrc, 'scrollIntoView');

  // Guard: the effect must bail out until BOTH the popup is open and mounted.
  assert.match(
    effect,
    /if \(!open \|\| !popupMounted\) return;/,
    'the effect must early-return on !open || !popupMounted',
  );

  // Behaviour: the active option is revealed with the least disruptive scroll.
  assert.match(
    effect,
    /scrollIntoView\(\{ block: 'nearest' \}\)/,
    "the effect must call scrollIntoView({ block: 'nearest' })",
  );

  // The lookup must target the active option inside the portaled listbox.
  assert.match(
    effect,
    /listboxRef\.current\?\.querySelector/,
    'the active option must be looked up inside the portaled listbox',
  );
  assert.match(
    effect,
    /optionDomId\(activeIndex\)/,
    'the lookup must resolve the ACTIVE option id',
  );

  // Dependencies: popupMounted is the load-bearing token — without it the effect
  // never re-runs after the second commit and the option stays off-screen.
  const deps = dependencyTokens(effect);
  assert.ok(
    deps.includes('popupMounted'),
    `the effect dependency array must include popupMounted (actual: [${deps.join(', ')}])`,
  );
  assert.ok(
    deps.includes('open'),
    `the effect dependency array must include open (actual: [${deps.join(', ')}])`,
  );
  assert.ok(
    deps.includes('activeIndex'),
    `the effect dependency array must include activeIndex (actual: [${deps.join(', ')}])`,
  );
  assert.deepEqual(
    deps,
    ['open', 'popupMounted', 'activeIndex'],
    'the effect must depend on exactly open, popupMounted and activeIndex',
  );
});
