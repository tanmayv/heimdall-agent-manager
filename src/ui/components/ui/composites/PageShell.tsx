/**
 * PageShell — the single page frame every route renders into.
 * ------------------------------------------------------------------
 * Purpose: give every page one identical header dialect (eyebrow + the page's
 * single `<h1>` + description + a right-aligned actions slot), one content-width
 * ramp, and standard loading/error handling — so pages feel like one app instead
 * of one-per-author. Replaces the 6 hand-built header dialects and the 10+ page
 * max-width variants catalogued in `docs/ui-audit/` (finding #7).
 *
 * THE TITLE IS THE TERMINAL CRUMB (convention, all five resources). A list page's
 * trail is a single crumb reading exactly what the `<h1>` reads, so rendering both
 * printed the page's name twice. PageShell therefore renders only the trail's
 * ANCESTORS and lets the `<h1>` be the current level: `/memory` shows one "Memory"
 * heading and no trail; `/memory/:id` shows "Memory /" above the record's title.
 * Pages keep passing their FULL trail — the deduplication is the shell's job, not
 * something five pages have to remember — and `aria-current="page"` is not lost,
 * because the current page is now announced as the region's `<h1>` instead.
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
import { Breadcrumbs } from './Breadcrumbs';
import type { Crumb } from './Breadcrumbs';
import type { RootClassNameProps } from '../types';

/** PageShell's content-width ramp. Superset of the shared `Width` (adds `wide`). */
export type PageShellWidth = 'content' | 'wide' | 'full';

export interface PageShellProps extends RootClassNameProps {
  /** The page's single `<h1>`. Required — every page has exactly one. */
  title: React.ReactNode;
  /**
   * The breadcrumb trail, rendered above the eyebrow/title (REQ-UI-14). The page
   * states its own trail rather than the shell inferring one from the path, which is
   * the only way a trail can name the record it is on ("Memory / Prefer nix …").
   */
  breadcrumbs?: Crumb[];
  /** Uppercase overline above the title (e.g. the section the page belongs to). */
  eyebrow?: string;
  /**
   * Subtitle rendered under the title. Capped to a readable measure — prose running
   * the full width of a 1440px window is a large part of what reads as unpolished.
   */
  description?: React.ReactNode;
  /** Toolbar slot, rendered right-aligned next to the title (e.g. a primary action). */
  actions?: React.ReactNode;
  /** Content-width ramp. `content` (default) · `wide` · `full` (full-bleed). */
  width?: PageShellWidth;
  /**
   * Vertical rhythm for the body. `banded` — the rebuild's convention — gives the
   * body the page's own inline padding and ONE gap between bands, so a page never
   * tunes spacing element by element and the body lines up with the header instead
   * of running flush to the window edge. `legacy` (the default) leaves the body
   * unstyled, which is what the not-yet-migrated pages still expect; migrate a page
   * and its hand-rolled gaps come out at the same time.
   */
  rhythm?: 'banded' | 'legacy';
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
  breadcrumbs,
  eyebrow,
  description,
  actions,
  width = 'content',
  rhythm = 'legacy',
  loading = false,
  error,
  className,
  children,
}) => {
  const rootClassName = ['ui-pageshell', className].filter(Boolean).join(' ');
  const titleId = React.useId();

  // The terminal crumb IS the title, so only the ancestors are a trail. A page that
  // passes a single crumb (every list page) gets no trail at all, which is the
  // point: one element, one job, no page printed twice.
  const ancestorCrumbs = breadcrumbs ? breadcrumbs.slice(0, -1) : [];

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
      data-rhythm={rhythm}
      className={rootClassName}
    >
      <a className="ui-pageshell-skip" href="#main-content">
        Skip to content
      </a>
      <div className="ui-pageshell-container">
        <header className="ui-pageshell-header">
          {ancestorCrumbs.length > 0 ? (
            <Breadcrumbs crumbs={ancestorCrumbs} className="mb-1" />
          ) : null}
          {eyebrow ? (
            <p className="mb-1 text-overline uppercase text-muted">{eyebrow}</p>
          ) : null}
          {/* Wraps rather than squeezing: at ≤767px a page with two or three header
              actions would otherwise crush the title and description into a
              one-word-per-line column (REQ-UI-13). `basis` keeps them side by side
              wherever there is room, which is every desktop width. */}
          <div className="flex flex-wrap items-start justify-between gap-3 min-w-0 max-w-full">
            <div className="min-w-0 flex-1 basis-64 max-w-full">
              <h1 id={titleId} className="text-display text-primary break-words">{title}</h1>
              {description ? (
                <p className="ui-measure mt-1 text-body-sm text-muted">{description}</p>
              ) : null}
            </div>
            {actions ? (
              <div className="flex flex-wrap items-center gap-2 max-w-full sm:shrink-0">{actions}</div>
            ) : null}
          </div>
        </header>
        <div className="ui-pageshell-body">{body}</div>
      </div>
    </section>
  );
};

export default PageShell;
