/**
 * useViewport / useIsMobile / useKeyboardInset — the breakpoint primitives.
 * ------------------------------------------------------------------
 * Purpose: the responsive facts `@ui`'s own components need in order to be
 * responsive — which breakpoint we are at, and how much of the viewport a software
 * keyboard is covering. `DataList` swaps a table for cards at ≤767px and
 * `BulkActionBar` lifts itself above the keyboard; both need this, and neither may
 * reach up into the app shell to get it.
 *
 * Layer: hook. No product knowledge: a viewport width is not a Heimdall concept.
 *
 * These lived in `src/ui/components/shell/responsive.tsx`, which is app-level and
 * imports `@ui`. An `@ui` component importing from there would both invert the
 * layering the README sets out and close an import cycle. They are moved down here
 * instead; `shell/responsive.tsx` re-exports them, so every existing call site keeps
 * working unchanged and there is still exactly one implementation.
 *
 * Breakpoints (arch doc §6D): <768px mobile, 768–1024px tablet, >1024px desktop.
 */
import { useEffect, useState } from 'react';

export const MOBILE_MAX = 767;
export const TABLET_MAX = 1023;

export type Viewport = 'mobile' | 'tablet' | 'desktop';

function readViewport(): Viewport {
  if (typeof window === 'undefined') return 'desktop';
  const w = window.innerWidth;
  if (w <= MOBILE_MAX) return 'mobile';
  if (w <= TABLET_MAX) return 'tablet';
  return 'desktop';
}

export function useViewport(): Viewport {
  const [viewport, setViewport] = useState<Viewport>(() => readViewport());
  useEffect(() => {
    const update = () => setViewport(readViewport());
    update();
    window.addEventListener('resize', update);
    return () => window.removeEventListener('resize', update);
  }, []);
  return viewport;
}

export function useIsMobile(): boolean {
  return useViewport() === 'mobile';
}

/**
 * `TAILWIND_SM_MIN` / `useIsBelowTailwindSm` — the JS mirror of Tailwind's DEFAULT
 * `sm:` breakpoint, which is 640px. `tailwind.config.js` deliberately does not
 * override `theme.screens` (see the note in its header), so every `sm:` utility in
 * the app switches at 640 — not at 768.
 *
 * THIS IS DELIBERATELY NOT `MOBILE_MAX` (767). The two numbers genuinely disagree,
 * and that disagreement is a known pre-existing defect tracked as artifact art_18d7b91b4ac8743e item 9; it is
 * not settled here and must not be "corrected" to 767 in passing. Use this hook ONLY
 * where JS has to agree with a `sm:` class on the very same element — mounting a
 * subtree that a sibling `sm:hidden` / `hidden sm:flex` wrapper would otherwise hide.
 * For the app's mobile/tablet/desktop product breakpoints, use `useIsMobile`.
 */
export const TAILWIND_SM_MIN = 640;

export function useIsBelowTailwindSm(): boolean {
  const [below, setBelow] = useState<boolean>(
    () => typeof window !== 'undefined' && window.innerWidth < TAILWIND_SM_MIN,
  );
  useEffect(() => {
    const update = () => setBelow(window.innerWidth < TAILWIND_SM_MIN);
    update();
    window.addEventListener('resize', update);
    return () => window.removeEventListener('resize', update);
  }, []);
  return below;
}

/**
 * Keyboard-aware layout. Mobile soft keyboards shrink `window.visualViewport` without
 * resizing the layout viewport. We expose the gap as an inset so a bottom-pinned bar
 * can lift above the keyboard. Returns 0 on desktop or when no keyboard is visible.
 */
export function useKeyboardInset(): number {
  const [inset, setInset] = useState(0);
  useEffect(() => {
    if (typeof window === 'undefined') return;
    const vv: VisualViewport | undefined = window.visualViewport;
    if (!vv) return;
    const update = () => {
      if (window.innerWidth > MOBILE_MAX) { setInset(0); return; }
      const gap = window.innerHeight - vv.height - vv.offsetTop;
      // Hysteresis: ignore sub-threshold deltas (browser chrome/bouncing).
      setInset(gap > 24 ? Math.max(0, gap) : 0);
    };
    update();
    vv.addEventListener('resize', update);
    vv.addEventListener('scroll', update);
    window.addEventListener('resize', update);
    return () => {
      vv.removeEventListener('resize', update);
      vv.removeEventListener('scroll', update);
      window.removeEventListener('resize', update);
    };
  }, []);
  return inset;
}

/**
 * Touch-target floor: ≥44px where practical (arch doc §6D). Components compose this
 * with their own min-w/h utilities to guarantee the hit area.
 */
export const TOUCH_TARGET_CLASS = 'min-h-11 min-w-11';
