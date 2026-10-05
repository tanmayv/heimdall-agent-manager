/**
 * appViewportHeight — drive the app shell's height from the VISUAL viewport.
 * ---------------------------------------------------------------------------
 * REQ-KBD-2. Root cause established on device in REQ-KBD-1 (artifact
 * `art_18db9abe5a639a40` §1): on iOS a software keyboard shrinks only the VISUAL
 * viewport. `window.innerHeight` — and therefore `100dvh`, `100lvh` and `100vh` —
 * does not move. Measured in the installed home-screen app with the keyboard up:
 *
 *     innerHeight = 812   visualViewport.height = 409   visualOffsetTop = 0
 *
 * The shell was sized `100dvh`, so its bottom edge stayed nailed at 812 while the
 * visible region collapsed to 0..409. The composer sat at 540..776 — entirely inside
 * the invisible 403px. Scrolling cannot rescue a box whose container's bottom edge is
 * pinned to a viewport the keyboard never shrinks.
 *
 * The fix is to stop sizing the shell from a viewport unit and size it from
 * `visualViewport.height` instead, published as the CSS custom property
 * `--app-viewport-height` on `<html>`. Everything that used to say `100dvh` says
 * `var(--app-viewport-height)`; the shell then ends where the keyboard begins and the
 * browser's own scroll-into-view does the rest.
 *
 * Two requirements below are NOT obvious and are both load-bearing. They come from
 * measurement, not taste. Read the comments before changing either.
 */

/** The custom property this module owns. Nothing else may write it. */
export const APP_VIEWPORT_HEIGHT_VAR = '--app-viewport-height';

/**
 * REQUIREMENT 1 — RE-READ ON A SETTLING TICK, NOT ONLY ON EVENTS.
 *
 * `visualViewport` events on this surface fire only MID-TRANSIENT. The complete event
 * log for one keyboard raise (REQ-KBD-1 §3) is two events at `10:10:03.180/.181`, both
 * taken while the viewport was still moving; the SETTLED state then held for SIX SECONDS
 * and fired nothing at all. `window.resize` never fired once. An event-only listener
 * latches the transient and never sees the steady state — that is precisely the defect
 * that made the former `useKeyboardInset()` hook report 0 forever (deleted in REQ-KBD-3).
 *
 * So every event schedules a ladder of re-reads after itself, AND a standing poll runs
 * regardless of whether any event ever arrives. Writes are suppressed when the value is
 * unchanged (see `installAppViewportHeightSync`), which is what makes the poll free: the
 * steady state costs two property reads and an integer compare per tick.
 */
export const APP_VIEWPORT_SETTLE_DELAYS_MS: readonly number[] = [50, 150, 300, 600, 1000];

/** Standing re-read interval. Covers keyboard transitions longer than the ladder. */
export const APP_VIEWPORT_POLL_MS = 250;

/**
 * Above this `visualViewport.scale` the user has pinch-zoomed in. `visualViewport.height`
 * then reports the zoomed-in slice, which is not a keyboard and must not shrink the shell.
 * Falling back to `innerHeight` there keeps pinch-zoom a pure magnifier.
 */
export const APP_VIEWPORT_MAX_UNZOOMED_SCALE = 1.01;

export type AppViewportReading = {
  /** `window.innerHeight` — the LAYOUT viewport height. A soft keyboard does NOT shrink it. */
  innerHeight: number;
  /** `visualViewport.height`, or `null` where `visualViewport` is unavailable. */
  visualHeight: number | null;
  /** `visualViewport.scale`, or `null` where unavailable. Only used to detect pinch-zoom. */
  scale: number | null;
};

/**
 * The height the app shell should occupy, in CSS pixels.
 *
 * REQUIREMENT 2 — THIS FUNCTION DOES NOT READ `visualViewport.offsetTop`, AND MUST NOT.
 *
 * The mechanism it replaces computed `innerHeight - visualHeight - visualOffsetTop`.
 * Across 350 focused device samples on a valid standalone surface, `visualOffsetTop`
 * ranged **-111 to +466** for one physically constant 403px keyboard, and that formula
 * produced **40 distinct values** (0, 41, 99, 105, 127, 221, …, 403, …, 456) — because
 * the visual viewport pans continuously while the keyboard is up. Any quantity derived by
 * subtracting a continuously-panning offset is non-deterministic by construction. The
 * height we want is simply "how tall is the visible region", which is `visualHeight`
 * alone. (REQ-KBD-1 §5, H5.)
 */
export function appViewportHeightFrom(reading: AppViewportReading): number {
  const { innerHeight, visualHeight, scale } = reading;
  const layout = Number.isFinite(innerHeight) && innerHeight > 0 ? innerHeight : 0;
  const isPinchZoomed = scale !== null && Number.isFinite(scale) && scale > APP_VIEWPORT_MAX_UNZOOMED_SCALE;
  if (visualHeight === null || !Number.isFinite(visualHeight) || visualHeight <= 0 || isPinchZoomed) {
    return Math.round(layout);
  }
  return Math.round(visualHeight);
}

/** The subset of `Window` this module touches, so tests can pass a fake. */
export type AppViewportWindow = {
  innerHeight: number;
  visualViewport?: {
    height: number;
    scale?: number;
    addEventListener: (type: string, listener: () => void) => void;
    removeEventListener: (type: string, listener: () => void) => void;
  } | null;
  document: { documentElement: { style: { setProperty: (name: string, value: string) => void } } };
  addEventListener: (type: string, listener: () => void, options?: unknown) => void;
  removeEventListener: (type: string, listener: () => void, options?: unknown) => void;
  setTimeout: (fn: () => void, ms: number) => unknown;
  clearTimeout: (handle: never) => void;
  setInterval: (fn: () => void, ms: number) => unknown;
  clearInterval: (handle: never) => void;
};

export function readAppViewportHeight(win: AppViewportWindow): number {
  const vv = win.visualViewport ?? null;
  return appViewportHeightFrom({
    innerHeight: win.innerHeight,
    visualHeight: vv ? vv.height : null,
    scale: vv && typeof vv.scale === 'number' ? vv.scale : null,
  });
}

/**
 * Publish `--app-viewport-height` on `<html>` and keep it current. Returns a teardown.
 *
 * Safe to call before React mounts — it only writes an inline custom property, which the
 * `:root { --app-viewport-height: 100dvh }` fallback in `styles.css` covers until the
 * first write lands.
 */
export function installAppViewportHeightSync(win: AppViewportWindow): () => void {
  const vv = win.visualViewport ?? null;
  const timers = new Set<unknown>();
  let lastWritten = -1;
  let stopped = false;

  const apply = () => {
    if (stopped) return;
    const height = readAppViewportHeight(win);
    // Suppressing no-op writes is what keeps the standing poll free, and it also keeps
    // us from invalidating layout 4x/second for a value that has not moved.
    if (height === lastWritten || height <= 0) return;
    lastWritten = height;
    win.document.documentElement.style.setProperty(APP_VIEWPORT_HEIGHT_VAR, `${height}px`);
  };

  const settle = () => {
    for (const delay of APP_VIEWPORT_SETTLE_DELAYS_MS) {
      const handle = win.setTimeout(() => {
        timers.delete(handle);
        apply();
      }, delay);
      timers.add(handle);
    }
  };

  // Read now (the transient), then again as it settles. See REQUIREMENT 1.
  const onEvent = () => {
    apply();
    settle();
  };

  apply();

  if (vv) {
    vv.addEventListener('resize', onEvent);
    vv.addEventListener('scroll', onEvent);
  }
  win.addEventListener('resize', onEvent);
  win.addEventListener('orientationchange', onEvent);
  // focusin/focusout are the only signals that reliably precede a keyboard transition.
  win.addEventListener('focusin', onEvent);
  win.addEventListener('focusout', onEvent);

  const poll = win.setInterval(apply, APP_VIEWPORT_POLL_MS);

  return () => {
    stopped = true;
    if (vv) {
      vv.removeEventListener('resize', onEvent);
      vv.removeEventListener('scroll', onEvent);
    }
    win.removeEventListener('resize', onEvent);
    win.removeEventListener('orientationchange', onEvent);
    win.removeEventListener('focusin', onEvent);
    win.removeEventListener('focusout', onEvent);
    win.clearInterval(poll as never);
    for (const handle of timers) win.clearTimeout(handle as never);
    timers.clear();
  };
}
