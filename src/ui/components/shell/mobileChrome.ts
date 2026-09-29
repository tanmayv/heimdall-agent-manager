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
 * 56px tab bar it normally clears is still mounted underneath it. Both the shell that
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
 * written against. Only used when the bar has not published its real height.
 */
export const MOBILE_TAB_BAR_HEIGHT_PX = 56;

/**
 * `MobileTabBar` publishes its REAL measured height (safe-area padding included) on the
 * document root as `--ui-bottom-chrome`, precisely so bottom-docking surfaces can sit above
 * it, and clears it when it unmounts. The composer was clearing a hardcoded 56px against a
 * bar that measures 53px on a 390x844 viewport, leaving a 3px strip of the transcript
 * visible between the two; reading the variable closes that and follows the bar through any
 * future height change.
 */
export const MOBILE_BOTTOM_CHROME_VAR = `var(--ui-bottom-chrome, ${MOBILE_TAB_BAR_HEIGHT_PX}px)`;

export type KeyboardAwareBottomInput = {
  /** `useKeyboardInset()` — how much of the viewport the soft keyboard covers. */
  keyboardInset: number;
  /** `focusSuppressesMobileChrome(document.activeElement)` — is the tab bar unmounted? */
  holdsKeyboardFocus: boolean;
};

/**
 * REQ-SHELL-28: where a bottom-pinned composer's bottom edge belongs, in px.
 *
 * Two independent signals decide it, and the naive `keyboardInset + tab bar height` is
 * wrong in every row but one. Do NOT "simplify" this back to a sum.
 *
 *   keyboard up,   focus held  -> keyboardInset  the tab bar is unmounted, so the inset is
 *                                                the whole distance; adding 56 would leave a
 *                                                56px gap above the keyboard.
 *   keyboard down, focus held  -> 0              iOS lets the keyboard be dismissed (swipe-down,
 *                                                or the dismiss key) WITHOUT blurring the field.
 *                                                Focus still suppresses the tab bar, so there is
 *                                                nothing underneath to clear.
 *   keyboard down, no focus    -> the tab bar's own measured height: the ordinary resting
                                 state. `var(--ui-bottom-chrome, 56px)` rather than a
                                 hardcoded 56, which left a 3px transcript strip showing.
 *   keyboard up,   no focus    -> keyboardInset  should not occur here (this app only raises the
 *                                                keyboard by focusing the composer), but if it
 *                                                does, sitting under the keyboard is the worse
 *                                                failure, so the inset still wins.
 */
export function keyboardAwareBottomPx(input: KeyboardAwareBottomInput): string {
  if (input.keyboardInset > 0) return `${input.keyboardInset}px`;
  return input.holdsKeyboardFocus ? '0px' : MOBILE_BOTTOM_CHROME_VAR;
}
