/**
 * Panel — the standard content container.
 * ------------------------------------------------------------------
 * Purpose: one boxed surface for grouping content inside a page — one radius
 * (`--radius-lg`), one border, one raised/sunken surface pair. Replaces the
 * drifting card opacities and the "panel wraps itself in a card" pattern
 * catalogued in `docs/ui-audit/` (finding #7).
 *
 * NOT for: interactive rows (that is `Card`'s interactive variant) or the page
 * frame (use `PageShell`).
 *
 * Layer: composite. Spec: `docs/ui-audit/04-component-catalogue.md` › Panel.
 *
 * Accessibility: a plain container (`<section>`). When `title` is given it renders
 * a `SectionHeader` (`<h2>`); otherwise pass an accessible name via `aria-label`
 * (or `aria-labelledby`) if the region is meaningful on its own.
 *
 * Tokens only: surface/border/radius/spacing via tokens. No raw values.
 *
 * Escape hatch: `className` passes through to the root only.
 */
import React from 'react';
import type { RootClassNameProps } from '../types';
import { SectionHeader } from './SectionHeader';

/** Inner padding scale (maps to `--space-*`). */
export type PanelPadding = 'none' | 'sm' | 'md' | 'lg';

/** `raised` sits above the page surface; `sunken` recesses into it. */
export type PanelTone = 'raised' | 'sunken';

export interface PanelProps extends RootClassNameProps {
  /** Optional section title (rendered via `SectionHeader` as an `<h2>`). */
  title?: React.ReactNode;
  /** Right-aligned actions for the panel header (only used with `title`). */
  actions?: React.ReactNode;
  /** Inner padding. Default `md`. */
  padding?: PanelPadding;
  /** Surface elevation. Default `raised`. */
  tone?: PanelTone;
  children?: React.ReactNode;
}

const PADDING_CLASS: Record<PanelPadding, string> = {
  none: '',
  sm: 'p-3',
  md: 'p-4',
  lg: 'p-6',
};

const TONE_CLASS: Record<PanelTone, string> = {
  raised: 'bg-surface-raised',
  sunken: 'bg-canvas',
};

export const Panel: React.FC<PanelProps> = ({
  title,
  actions,
  padding = 'md',
  tone = 'raised',
  className,
  children,
}) => {
  const rootClassName = [
    'border border-subtle rounded-[var(--radius-lg)]',
    TONE_CLASS[tone],
    PADDING_CLASS[padding],
    className,
  ]
    .filter(Boolean)
    .join(' ');

  return (
    <section className={rootClassName}>
      {title ? (
        <SectionHeader title={title} actions={actions} className="mb-3" />
      ) : null}
      {children}
    </section>
  );
};

export default Panel;
