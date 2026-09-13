/**
 * ProgressBar — a determinate or indeterminate progress track.
 * ------------------------------------------------------------------
 * Purpose: the one progress indicator (EL-074) — a determinate bar when you have
 * a value, an indeterminate animated track when you don't. Gives progress a real
 * `role="progressbar"` with the ARIA value attributes.
 *
 * NOT for: an indeterminate spinner glyph (use `Spinner`) — this is a horizontal
 * track, typically full-width.
 *
 * Layer: composite. Spec: `docs/ui-audit/04-component-catalogue.md` › ProgressBar.
 * Prop names follow the shared vocabulary in `../types` (`tone`, `size`, `className`).
 *
 * API: `value` (0–100) for determinate; omit for indeterminate. `label` names it
 * (required for a11y). `tone` colors the fill; `size` sets the track height.
 *
 * Accessibility (built in): `role="progressbar"` with `aria-valuemin=0`,
 * `aria-valuemax=100`, and `aria-valuenow` when determinate (omitted while
 * indeterminate); `aria-label` from `label`. The indeterminate animation runs
 * only under `motion-safe`.
 *
 * Tokens only: track/fill colors, radius, motion via tokens. No raw values.
 *
 * Escape hatch: `className` merges onto the root track.
 */
import React from 'react';
import type { RootClassNameProps } from '../types';

export type ProgressTone = 'accent' | 'success' | 'warning' | 'danger';

const FILL_TONE: Record<ProgressTone, string> = {
  accent: 'bg-accent',
  success: 'bg-success',
  warning: 'bg-warning',
  danger: 'bg-danger',
};

const TRACK_SIZE: Record<'sm' | 'md', string> = {
  sm: 'h-1',
  md: 'h-2',
};

export interface ProgressBarProps extends RootClassNameProps {
  /** 0–100 for determinate; omit for indeterminate. */
  value?: number;
  /** Accessible name (required). */
  label: string;
  /** Fill color. Default `accent`. */
  tone?: ProgressTone;
  /** Track height. Default `md`. */
  size?: 'sm' | 'md';
}

export const ProgressBar: React.FC<ProgressBarProps> = ({
  value,
  label,
  tone = 'accent',
  size = 'md',
  className,
}) => {
  const indeterminate = value === undefined;
  const clamped = indeterminate ? 0 : Math.max(0, Math.min(100, value));

  const trackClassName = [
    'w-full overflow-hidden rounded-pill bg-surface-raised',
    TRACK_SIZE[size],
    className ?? '',
  ]
    .filter(Boolean)
    .join(' ')
    .replace(/\s+/g, ' ')
    .trim();

  return (
    <div
      role="progressbar"
      aria-label={label}
      aria-valuemin={0}
      aria-valuemax={100}
      aria-valuenow={indeterminate ? undefined : clamped}
      className={trackClassName}
    >
      {indeterminate ? (
        <div className={`h-full w-full rounded-pill ${FILL_TONE[tone]} opacity-60 motion-safe:animate-pulse`} />
      ) : (
        <div
          className={`h-full rounded-pill ${FILL_TONE[tone]} transition-[width] duration-base`}
          style={{ width: `${clamped}%` }}
        />
      )}
    </div>
  );
};

export default ProgressBar;
