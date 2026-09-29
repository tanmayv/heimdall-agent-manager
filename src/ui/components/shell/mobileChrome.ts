/**
 * Opt-in marker for surfaces whose focused input should hide the mobile shell chrome
 * (top bar + bottom tab bar), because the software keyboard needs the room.
 */
export const MOBILE_CHROME_HIDE_ON_FOCUS_SELECTOR = '[data-mobile-shell-chrome="hide-on-focus"]';

/**
 * Does focus landing on `target` suppress the mobile shell chrome?
 *
 * Only KEYBOARD-BEARING fields inside an opted-in surface do (the on-screen keyboard is
 * what crowds the viewport). Tapping other focusable controls inside a composer — e.g. the
 * runtime status chip or the model switcher button — must NOT hide the tab bar, because
 * that reflow moves the element out from under the tap and eats the first click
 * (requiring a second tap).
 *
 * REQ-SHELL-28: shared with the bottom-pinned composer, which has to know whether the
 * tab bar it normally clears is still mounted underneath it. Both the shell that
 * unmounts the bar and the bar-clearing element must read the SAME predicate, or they
 * disagree about the bottom of the screen.
 */
export function focusSuppressesMobileChrome(target: EventTarget | null): boolean {
  const node = target as Element | null;
  if (!node?.closest?.(MOBILE_CHROME_HIDE_ON_FOCUS_SELECTOR)) return false;
  const el = node as HTMLElement;
  if (el.isContentEditable) return true;
  const tag = el.tagName;
  if (tag === 'TEXTAREA') return true;
  if (tag === 'INPUT') {
    const type = (el as HTMLInputElement).type;
    return !['button', 'submit', 'reset', 'checkbox', 'radio', 'range', 'file', 'color'].includes(type);
  }
  return false;
}


/**
 * Static fallback for the tab bar's height — the `bottom-14` utility the composer was
 * written against. Only used when the bar has not published its real height yet.
 */
export const MOBILE_TAB_BAR_HEIGHT_PX = 56;

/**
 * `MobileTabBar` publishes its REAL measured height on the document root as
 * `--ui-bottom-chrome`. That height does NOT include the safe area in this tree today: the bar
 * carries `ui-safe-bottom`, but that class is declared TWICE in styles.css — the working
 * `env(safe-area-inset-bottom)` rule inside `@supports` (:69) is overridden by a later, equal-
 * specificity `var(--ui-safe-bottom, 0px)` rule (:84), and `--ui-safe-bottom` is never set
 * anywhere, so the padding resolves to 0px on every device. Tracked as iss_18d9ba8109e2c28b.
 * The composer was clearing a hardcoded 56 against a bar that measures 53, leaving a 3px strip
 * of transcript at the seam; reading the variable closes that and follows the bar through any
 * future height change.
 *
 * No `max(…, env(safe-area-inset-bottom))` wrapper here, unlike the fifteen other consumers of
 * this variable — and the reason is testability, NOT inset coverage. Keeping this a bare `var()`
 * is what lets `keyboardAwareBottomPx` be asserted in node, where `max(var, env)` cannot be
 * resolved. The `56px` fallback does exceed a home indicator, but only the fallback; once the bar
 * publishes its real height this row clears the bar and nothing more, until
 * iss_18d9ba8109e2c28b is fixed.
 */
export const MOBILE_BOTTOM_CHROME_VAR = `var(--ui-bottom-chrome, ${MOBILE_TAB_BAR_HEIGHT_PX}px)`;

/**
 * What is left to clear once the tab bar has unmounted: the device's home-indicator strip,
 * and nothing else. `0px` on any device without one.
 *
 * Deliberately a LONE `env(...)` rather than the tree's usual
 * `max(var(--ui-bottom-chrome, 0px), env(safe-area-inset-bottom, 0px))`, and the reason is a
 * dependency worth naming: `useBottomChromeVar`'s cleanup (responsive.tsx) calls
 * `root.style.removeProperty('--ui-bottom-chrome')` when the bar unmounts, so in this row the
 * variable is GONE and there is nothing left to max against. Wrapping it would be equivalent
 * today — and would quietly depend on that cleanup continuing to run. Keeping the two rows as
 * two distinct strings is also what keeps `keyboardAwareBottomPx` node-testable: `max(var, env)`
 * cannot be resolved without a layout engine, so collapsing them would move the decision out of
 * the tests and into CSS that nothing here can check.
 */
export const SAFE_AREA_BOTTOM_CSS = 'env(safe-area-inset-bottom, 0px)';

export type KeyboardAwareBottomInput = {
  /** `useKeyboardInset()` — how much of the viewport the soft keyboard covers. */
  keyboardInset: number;
  /** `focusSuppressesMobileChrome(document.activeElement)` — is the tab bar unmounted? */
  holdsKeyboardFocus: boolean;
};

/**
 * REQ-SHELL-28: where a bottom-pinned composer's bottom edge belongs, as a CSS length.
 *
 * Two independent signals decide it, and the naive `keyboardInset + tab bar height` is
 * wrong in every row but one. Do NOT "simplify" this back to a sum, and do NOT collapse
 * the two zero-ish rows into a literal `0` — one of them is a home indicator.
 *
 *   keyboard up,   focus held  -> `${inset}px`  the tab bar is unmounted, so the inset is the
 *                                 whole distance; adding the bar's height would leave a gap
 *                                 above the keyboard. No safe-area term: the keyboard is
 *                                 drawn OVER the home indicator, so the inset already spans it.
 *   keyboard down, focus held  -> the safe area. iOS lets the keyboard be dismissed
 *                                 (swipe-down, or the dismiss key) WITHOUT blurring the field,
 *                                 so focus still suppresses the tab bar and there is no bar to
 *                                 clear — but the home indicator does not leave with it. A
 *                                 literal `0` here puts the send button inside the strip iOS
 *                                 owns the swipe in.
 *   keyboard down, no focus    -> the tab bar's own measured height (`--ui-bottom-chrome`).
 *                                 The ordinary resting state. NOTE: that height does not
 *                                 currently include the safe area — `ui-safe-bottom` resolves to
 *                                 0px tree-wide (iss_18d9ba8109e2c28b) — so the bar's own tabs
 *                                 sit in the home-indicator strip. The composer clears the bar,
 *                                 which is correct either way: once that issue is fixed the
 *                                 published height grows and this row follows it.
 *   keyboard up,   no focus    -> `${inset}px`  should not occur here (this app only raises the
 *                                 keyboard by focusing the composer), but if it does, sitting
 *                                 under the keyboard is the worse failure, so the inset wins.
 */
export function keyboardAwareBottomPx(input: KeyboardAwareBottomInput): string {
  if (input.keyboardInset > 0) return `${input.keyboardInset}px`;
  return input.holdsKeyboardFocus ? SAFE_AREA_BOTTOM_CSS : MOBILE_BOTTOM_CHROME_VAR;
}
