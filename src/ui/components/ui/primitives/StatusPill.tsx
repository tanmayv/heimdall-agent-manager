/**
 * StatusPill — a labeled semantic state.
 * ------------------------------------------------------------------
 * Purpose: the pill that names a STATE the user reads as status — "Running",
 * "Offline", "In flight", "Completed" (EL-048). It maps the ~10 ad-hoc status
 * colors scattered across the app onto the 6-value `tone` set and the `/opacity`
 * forks onto `emphasis`, sharing the exact tone language as `Badge` (see
 * `toneStyles.ts`).
 *
 * NOT for: a count or a decorative tag (use `Badge` — the inert metadata pill), a
 * bare liveness dot (`StatusDot`), or a clickable control (`Button`). The split
 * from Badge is semantic: Badge is inert metadata; StatusPill names a state.
 * Where a state needs a leading liveness dot, compose `StatusDot` + StatusPill
 * (the `ConnectionBadge` pattern) rather than adding a dot prop here.
 *
 * Layer: primitive. Spec: `docs/ui-audit/04-component-catalogue.md` › Badge · StatusPill · StatusDot.
 * Prop names follow the shared vocabulary in `../types` (`tone`, `emphasis`,
 * `className`). Native `<span>` attributes (`title`, `data-*`, `id`, …) pass
 * through via `rest`.
 *
 * Accessibility: the state is carried by the visible text label — colorblind / SR
 * users get the state from the words, never from color alone (this is the whole
 * reason it is a labeled pill and not a bare dot). The caller MUST give it a text
 * label (children); an empty StatusPill is a misuse.
 *
 * Tokens only: `tone` + `emphasis` resolve to the semantic + soft-tint tokens via
 * the shared `toneClasses` map. No raw hex / px / opacity forks.
 *
 * Escape hatch: `className` merges onto the root `<span>` — an escape hatch with a
 * cost, not a styling API.
 */
import React from 'react';
import type { Emphasis, RootClassNameProps, Tone } from '../types';
import { toneClasses } from './toneStyles';

const BASE =
  'inline-flex items-center gap-1 rounded-pill px-2 py-0.5 ' +
  'text-[length:var(--text-caption-size)] font-semibold leading-none whitespace-nowrap';

export interface StatusPillProps
  extends Omit<React.HTMLAttributes<HTMLSpanElement>, 'className'>,
    RootClassNameProps {
  /** Semantic state intent. Default `neutral`. */
  tone?: Tone;
  /** How strongly the tone is painted. Default `soft`. */
  emphasis?: Emphasis;
  /** The visible state label (required — the state must be readable, not color-only). */
  children: React.ReactNode;
}

export const StatusPill = React.forwardRef<HTMLSpanElement, StatusPillProps>(function StatusPill(
  { tone = 'neutral', emphasis = 'soft', className, children, ...rest },
  ref,
) {
  const rootClassName = [BASE, toneClasses(tone, emphasis), className ?? '']
    .filter(Boolean)
    .join(' ')
    .replace(/\s+/g, ' ')
    .trim();

  return (
    <span ref={ref} className={rootClassName} {...rest}>
      {children}
    </span>
  );
});

export default StatusPill;
