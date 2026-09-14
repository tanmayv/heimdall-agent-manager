/**
 * Spinner — the one loading glyph.
 * ------------------------------------------------------------------
 * Purpose: a single indeterminate loading indicator (EL-067/068), folding the
 * hand-rolled `border-2 … border-t-… animate-spin` rings and the bare "Loading…"
 * text into one control with a built-in `role="status"` accessible name.
 *
 * NOT for: determinate progress (use `ProgressBar`), or the in-button busy state
 * (Button/IconButton own that via `loading`).
 *
 * Layer: primitive. Spec: `docs/ui-audit/04-component-catalogue.md` › Link · Spinner · Kbd · Avatar.
 * Prop names follow the shared vocabulary in `../types` (`size`, `className`).
 *
 * Color: the ring is drawn in `currentColor` (a spinning gap), so it inherits the
 * surrounding text color by default — set the tone with a text-color utility on
 * the caller (`className="text-accent"`) when you want it to stand out.
 *
 * Accessibility (built in): renders `role="status"` with an `aria-label` (default
 * "Loading…"), so assistive tech announces the loading state. The visual ring is
 * inside it. Motion: spins only under `motion-safe` (reduced-motion users see a
 * static ring).
 *
 * Tokens only: sizing via the spacing scale; no raw hex. (Border width uses
 * Tailwind's `border-2`, matching the existing rings.)
 *
 * Escape hatch: `className` merges onto the root — use it for color/margin.
 */
import React from 'react';
import type { RootClassNameProps, Size } from '../types';

/** Ring diameter per size. */
const RING_SIZE: Record<Size, string> = {
  sm: 'h-4 w-4',
  md: 'h-5 w-5',
  lg: 'h-8 w-8',
};

export interface SpinnerProps extends RootClassNameProps {
  /** Ring diameter. Default `md`. */
  size?: Size;
  /** Accessible loading label. Default "Loading…". */
  label?: string;
}

export function Spinner({ size = 'md', label = 'Loading…', className }: SpinnerProps) {
  const ringClassName = [
    'inline-block rounded-full border-2 border-current border-t-transparent motion-safe:animate-spin',
    RING_SIZE[size],
    className ?? '',
  ]
    .filter(Boolean)
    .join(' ')
    .replace(/\s+/g, ' ')
    .trim();

  return <span role="status" aria-label={label} className={ringClassName} />;
}

export default Spinner;
