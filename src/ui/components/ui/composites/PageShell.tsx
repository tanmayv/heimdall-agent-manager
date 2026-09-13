/**
 * PageShell — the single page frame every route renders into.
 * ------------------------------------------------------------------
 * Purpose: give every page one identical header dialect (eyebrow + the page's
 * single `<h1>` + description + a right-aligned actions slot), one content-width
 * ramp, and standard loading/error handling — so pages feel like one app instead
 * of one-per-author. Replaces the 6 hand-built header dialects and the 10+ page
 * max-width variants catalogued in `docs/ui-audit/` (finding #7).
 *
 * NOT for: section-level headers inside a page (use `SectionHeader`) or content
 * containers (use `Panel`).
 *
 * Layer: composite. Spec: `docs/ui-audit/04-component-catalogue.md` › PageShell.
 *
 * Accessibility contract:
 *   - Renders a `<section id="main-content" tabIndex={-1} aria-labelledby={h1}>`
 *     region — labelled by its `<h1>` (the single top-level heading; callers must
 *     not render another `<h1>`). It is a labelled region, NOT a `<main>`: the app
 *     shell owns the single `<main>` landmark, so PageShell nests inside it
 *     without creating a second `<main>` (avoids the double-landmark defect,
 *     regardless of how many pages have adopted PageShell yet).
 *   - Ships a keyboard-only "Skip to content" link (visible on focus-visible)
 *     that targets the region (`#main-content`), plus a visible focus ring from
 *     the `--shadow-focus` token.
 *   Callers supply only the title/labels; focus and roles are built in.
 *
 * Tokens only: spacing/typography/color come from the Tailwind token utilities
 * (`px-4`/`sm:px-6` → `--space-*`, `text-display`/`text-overline`/`text-body`,
 * `text-primary`/`text-muted`, `border-subtle`); layout + the content-width ramp
 * live in `./PageShell.css`. No raw hex/px in this component.
 *
 * Escape hatch: `className` passes through to the `<section>` root only.
 */
import React from 'react';
import './PageShell.css';
import type { RootClassNameProps } from '../types';

/** PageShell's content-width ramp. Superset of the shared `Width` (adds `wide`). */
export type PageShellWidth = 'content' | 'wide' | 'full';

export interface PageShellProps extends RootClassNameProps {
  /** The page's single `<h1>`. Required — every page has exactly one. */
  title: React.ReactNode;
  /** Uppercase overline above the title (e.g. the section the page belongs to). */
  eyebrow?: string;
  /** Subtitle rendered under the title. */
  description?: React.ReactNode;
  /** Toolbar slot, rendered right-aligned next to the title (e.g. a primary action). */
  actions?: React.ReactNode;
  /** Content-width ramp. `content` (default) · `wide` · `full` (full-bleed). */
  width?: PageShellWidth;
  /** When true, renders a standard loading state in the body instead of children. */
  loading?: boolean;
  /**
   * When set, renders a standard error state in the body instead of children.
   * `true` shows a generic message; a node shows that content (announced via
   * `role="alert"`).
   */
  error?: React.ReactNode | boolean;
  /** The page body. */
  children?: React.ReactNode;
}

export const PageShell: React.FC<PageShellProps> = ({
  title,
  eyebrow,
  description,
  actions,
  width = 'content',
  loading = false,
  error,
  className,
  children,
}) => {
  const rootClassName = ['ui-pageshell', className].filter(Boolean).join(' ');
  const titleId = React.useId();

  let body: React.ReactNode;
  if (loading) {
    body = (
      <div role="status" aria-live="polite" className="ui-pageshell-status">
        Loading…
      </div>
    );
  } else if (error) {
    body = (
      <div role="alert" className="ui-pageshell-error">
        {typeof error === 'boolean' ? 'Something went wrong. Please try again.' : error}
      </div>
    );
  } else {
    body = children;
  }

  return (
    <section
      id="main-content"
      tabIndex={-1}
      aria-labelledby={titleId}
      data-width={width}
      className={rootClassName}
    >
      <a className="ui-pageshell-skip" href="#main-content">
        Skip to content
      </a>
      <div className="ui-pageshell-container">
        <header className="px-4 py-4 sm:px-6 sm:py-6">
          {eyebrow ? (
            <p className="mb-1 text-overline uppercase text-muted">{eyebrow}</p>
          ) : null}
          <div className="flex items-start justify-between gap-3">
            <div className="min-w-0">
              <h1 id={titleId} className="text-display text-primary">{title}</h1>
              {description ? <p className="mt-1 text-body text-muted">{description}</p> : null}
            </div>
            {actions ? (
              <div className="flex shrink-0 items-center gap-2">{actions}</div>
            ) : null}
          </div>
        </header>
        <div className="ui-pageshell-body">{body}</div>
      </div>
    </section>
  );
};

export default PageShell;
