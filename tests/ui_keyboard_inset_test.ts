import test from 'node:test';
import assert from 'node:assert/strict';
import {
  KEYBOARD_INSET_MIN,
  MOBILE_MAX,
  keyboardInsetFrom,
  type KeyboardInsetReading,
} from '../src/ui/components/ui/hooks/useViewport.ts';
import {
  MOBILE_CHROME_HIDE_ON_FOCUS_SELECTOR,
  MOBILE_BOTTOM_CHROME_VAR,
  MOBILE_TAB_BAR_HEIGHT_PX,
  SAFE_AREA_BOTTOM_CSS,
  focusSuppressesMobileChrome,
  keyboardAwareBottomPx,
} from '../src/ui/components/shell/mobileChrome.ts';

// ---------------------------------------------------------------------------
// REQ-SHELL-28: keyboardInsetFrom — the arithmetic behind useKeyboardInset().
//
// A headless browser has no software keyboard, so `visualViewport` never shrinks
// and the defect this guards cannot be reproduced by screenshotting. The pure
// function IS executable, so the truth table below is what is actually verified:
// the desktop short-circuit, the hysteresis threshold, the offsetTop term, and
// the clamp. It does NOT verify iOS behaviour.
// ---------------------------------------------------------------------------

const reading = (over: Partial<KeyboardInsetReading> = {}): KeyboardInsetReading => ({
  innerWidth: 390,
  innerHeight: 844,
  visualHeight: 844,
  visualOffsetTop: 0,
  ...over,
});

test('keyboardInsetFrom returns 0 above the mobile breakpoint even with a shrunken visual viewport', () => {
  // Desktop window resize / devtools docked at the bottom must never lift a bar.
  assert.equal(keyboardInsetFrom(reading({ innerWidth: MOBILE_MAX + 1, visualHeight: 500 })), 0);
  assert.equal(keyboardInsetFrom(reading({ innerWidth: 1440, innerHeight: 900, visualHeight: 500 })), 0);
});

test('keyboardInsetFrom still reports at exactly the mobile breakpoint', () => {
  // MOBILE_MAX is inclusive of mobile, so the cutoff is `> MOBILE_MAX`, not `>=`.
  assert.equal(keyboardInsetFrom(reading({ innerWidth: MOBILE_MAX, visualHeight: 500 })), 344);
});

test('keyboardInsetFrom reports the full gap for an open soft keyboard', () => {
  // 844 layout - 508 visual = a 336px keyboard; the bar must lift by exactly that.
  assert.equal(keyboardInsetFrom(reading({ visualHeight: 508 })), 336);
});

test('keyboardInsetFrom returns 0 with no keyboard up', () => {
  assert.equal(keyboardInsetFrom(reading()), 0);
});

test('keyboardInsetFrom applies hysteresis at the threshold', () => {
  const at = (gap: number) => keyboardInsetFrom(reading({ visualHeight: 844 - gap }));
  // Strictly greater than the threshold reports; at or below it is swallowed, so a
  // collapsing URL bar does not jitter the composer.
  assert.equal(at(KEYBOARD_INSET_MIN - 1), 0, 'below threshold is browser chrome, not a keyboard');
  assert.equal(at(KEYBOARD_INSET_MIN), 0, 'the threshold itself is exclusive');
  assert.equal(at(KEYBOARD_INSET_MIN + 1), KEYBOARD_INSET_MIN + 1, 'one past the threshold reports in full');
});

test('keyboardInsetFrom subtracts visualOffsetTop so a pinch-panned viewport does not inflate the inset', () => {
  // Keyboard up (336px) AND the visual viewport scrolled down 100px: the gap BELOW the
  // visual viewport is 236, not 336. Ignoring offsetTop would lift the bar 100px too far.
  assert.equal(keyboardInsetFrom(reading({ visualHeight: 508, visualOffsetTop: 100 })), 236);
});

test('keyboardInsetFrom never returns a negative inset', () => {
  // visualViewport can momentarily exceed the layout viewport mid-rotation; a negative
  // `bottom` would push the composer off-screen downwards.
  assert.equal(keyboardInsetFrom(reading({ innerHeight: 844, visualHeight: 900 })), 0);
  assert.equal(keyboardInsetFrom(reading({ visualHeight: 508, visualOffsetTop: 900 })), 0);
});

// ---------------------------------------------------------------------------
// REQ-SHELL-28: keyboardAwareBottomPx — where the bottom-pinned composer's bottom
// edge belongs. The four rows the coordinator called out, pinned so the next reader
// cannot "simplify" this into `keyboardInset + MOBILE_TAB_BAR_HEIGHT_PX`.
// ---------------------------------------------------------------------------

test('keyboardAwareBottomPx: keyboard up + focus held -> the inset alone, never inset + tab bar', () => {
  const bottom = keyboardAwareBottomPx({ keyboardInset: 336, holdsKeyboardFocus: true });
  assert.equal(bottom, '336px');
  assert.notEqual(bottom, `${336 + MOBILE_TAB_BAR_HEIGHT_PX}px`, 'summing would leave a 56px gap above the keyboard');
});

test('keyboardAwareBottomPx: keyboard dismissed WITHOUT blur (iOS swipe-down) -> flush to the SAFE AREA, not to 0', () => {
  // The divergent row: focus still suppresses the tab bar, so there is no bar left to clear —
  // but the home indicator does not leave with it. The tab bar was the thing carrying
  // `ui-safe-bottom` (env(safe-area-inset-bottom)) on this edge, so when it unmounts the
  // composer inherits that job. A literal `0` here puts the send button inside the ~34px strip
  // iOS owns the swipe in. Falling back to the `bottom-14` class would strand it 56px up.
  const bottom = keyboardAwareBottomPx({ keyboardInset: 0, holdsKeyboardFocus: true });
  assert.equal(bottom, SAFE_AREA_BOTTOM_CSS);
  assert.equal(bottom, 'env(safe-area-inset-bottom, 0px)');
  assert.notEqual(bottom, '0px', 'a literal 0 drops the home indicator on the device this task came from');
});

test('keyboardAwareBottomPx: resting state clears the tab bar by its MEASURED height', () => {
  // The bar publishes `--ui-bottom-chrome` from its own offsetHeight; a hardcoded 56 against
  // a 53px bar is what left a 3px strip of transcript showing between the two.
  assert.equal(keyboardAwareBottomPx({ keyboardInset: 0, holdsKeyboardFocus: false }), MOBILE_BOTTOM_CHROME_VAR);
  assert.equal(MOBILE_BOTTOM_CHROME_VAR, 'var(--ui-bottom-chrome, 56px)', 'the fallback is the old `bottom-14` value');
  // The two zero-ish rows must stay DISTINCT strings: this one is a mounted bar, the other is
  // a home indicator. Collapsing them into one `max(var, env)` would make them
  // indistinguishable to every test in this file.
  assert.notEqual(MOBILE_BOTTOM_CHROME_VAR, SAFE_AREA_BOTTOM_CSS);
});

test('keyboardAwareBottomPx: keyboard up with no focus held still lifts above the keyboard', () => {
  // Should not occur in this app (only the composer raises the keyboard), but sitting
  // under the keyboard is the worse failure, so the inset wins over the tab bar.
  assert.equal(keyboardAwareBottomPx({ keyboardInset: 336, holdsKeyboardFocus: false }), '336px');
});

// ---------------------------------------------------------------------------
// focusSuppressesMobileChrome — the predicate AppShell uses to unmount the tab bar
// and the composer now uses to decide whether it must clear one. Same function, so
// the two cannot disagree about the bottom of the screen.
// ---------------------------------------------------------------------------

type FakeNode = { tagName?: string; type?: string; isContentEditable?: boolean; optedIn?: boolean };

const node = (over: FakeNode = {}) => ({
  tagName: 'TEXTAREA',
  isContentEditable: false,
  ...over,
  closest: (selector: string) =>
    selector === MOBILE_CHROME_HIDE_ON_FOCUS_SELECTOR && over.optedIn !== false ? {} : null,
}) as unknown as EventTarget;

test('focusSuppressesMobileChrome: only inside an opted-in surface', () => {
  assert.equal(focusSuppressesMobileChrome(null), false);
  assert.equal(focusSuppressesMobileChrome(node({ optedIn: false })), false, 'a textarea elsewhere must not hide the chrome');
  assert.equal(focusSuppressesMobileChrome(node()), true);
});

test('focusSuppressesMobileChrome: only for keyboard-bearing fields', () => {
  assert.equal(focusSuppressesMobileChrome(node({ tagName: 'TEXTAREA' })), true);
  assert.equal(focusSuppressesMobileChrome(node({ tagName: 'DIV', isContentEditable: true })), true);
  assert.equal(focusSuppressesMobileChrome(node({ tagName: 'INPUT', type: 'text' })), true);
  assert.equal(focusSuppressesMobileChrome(node({ tagName: 'INPUT', type: 'search' })), true);
  // The narrowing that keeps a tap on the model switcher from eating the first click.
  assert.equal(focusSuppressesMobileChrome(node({ tagName: 'BUTTON' })), false);
  // All EIGHT excluded input types, so a future edit that drops one from the list fails here
  // rather than shipping the two-tap bug the predicate's own comment warns about.
  for (const type of ['button', 'submit', 'reset', 'checkbox', 'radio', 'range', 'file', 'color']) {
    assert.equal(focusSuppressesMobileChrome(node({ tagName: 'INPUT', type })), false, `input[type=${type}] must not hide the chrome`);
  }
});
