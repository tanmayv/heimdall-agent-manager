/**
 * Panel — the standard content container.
 * ------------------------------------------------------------------
 * Purpose: one boxed surface for grouping content inside a page — one radius
 * (`--radius-lg`), one border, one raised/sunken surface pair. Replaces the
 * drifting card opacities and the "panel wraps itself in a card" pattern
 * catalogued in `docs/ui-audit/` (finding #7).
 *
 * NOT for: the page frame (use `PageShell`).
 *
 * Interactive variant (this is where `Card` merges in — the audit rejects a
 * separate `Card`, see `04-component-catalogue.md` rejected-promotion list): pass
 * `href` to render a clickable `<a>` row, or `onClick` to render a `<button>`
 * row — never a click-handler on a bare `<div>`. It then gains hover + a
 * focus-visible ring and is keyboard-reachable. A non-interactive Panel is a
 * plain `<section>`.
 *
 * Layer: composite. Spec: `docs/ui-audit/04-component-catalogue.md` › Panel · Card.
 *
 * Accessibility: a plain container (`<section>`) by default; a real `<a>`/
 * `<button>` when interactive (native keyboard + focus). When `title` is given it
 * renders a `SectionHeader` (`<h2>`); otherwise pass an accessible name via
 * `aria-label`/`aria-labelledby` if the region is meaningful on its own.
 *
 * Tokens only: surface/border/radius/spacing via tokens. No raw values.
 *
 * Escape hatch: `className` passes through to the root only.
 */
import React from 'react';
import type { ClickHandler, RootClassNameProps } from '../types';
import { SectionHeader } from './SectionHeader';

/** Inner padding scale (maps to `--space-*`). */
export type PanelPadding = 'none' | 'sm' | 'md' | 'lg';

/** `raised` sits above the page surface; `sunken` recesses into it. */
export type PanelTone = 'raised' | 'sunken';

export interface PanelProps
  extends Omit<React.HTMLAttributes<HTMLElement>, 'title' | 'onClick'>,
    RootClassNameProps {
  /** Optional section title (rendered via `SectionHeader` as an `<h2>`). */
  title?: React.ReactNode;
  /** Right-aligned actions for the panel header (only used with `title`). */
  actions?: React.ReactNode;
  /** Inner padding. Default `md`. */
  padding?: PanelPadding;
  /** Surface elevation. Default `raised`. */
  tone?: PanelTone;
  /** Interactive row: render a clickable `<a href>`. Mutually exclusive with `onClick`. */
  href?: string;
  /** Interactive row: render a `<button>` with this handler. */
  onClick?: ClickHandler;
  /** Disable the interactive (`onClick`) row. */
  disabled?: boolean;
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

const INTERACTIVE_CLASS =
  'block w-full text-left cursor-pointer transition duration-fast hover:brightness-125 ' +
  'focus-visible:outline-none focus-visible:shadow-focus disabled:opacity-50 disabled:cursor-not-allowed';

export const Panel: React.FC<PanelProps> = ({
  title,
  actions,
  padding = 'md',
  tone = 'raised',
  href,
  onClick,
  disabled,
  className,
  children,
  ...rest
}) => {
  const interactive = Boolean(href || onClick);
  const rootClassName = [
    'border border-subtle rounded-[var(--radius-lg)]',
    TONE_CLASS[tone],
    PADDING_CLASS[padding],
    interactive ? INTERACTIVE_CLASS : '',
    className,
  ]
    .filter(Boolean)
    .join(' ');

  const header = title ? (
    <SectionHeader title={title} actions={actions} className="mb-3" />
  ) : null;

  // Interactive row -> a real <a>/<button>; otherwise a plain <section>. Never a
  // click handler on a bare container (the Card interactive-variant contract).
  if (href) {
    return (
      <a href={href} className={rootClassName} {...rest}>
        {header}
        {children}
      </a>
    );
  }
  if (onClick) {
    return (
      <button type="button" onClick={onClick} disabled={disabled} className={rootClassName} {...rest}>
        {header}
        {children}
      </button>
    );
  }
  return (
    <section className={rootClassName} {...rest}>
      {header}
      {children}
    </section>
  );
};

export default Panel;
