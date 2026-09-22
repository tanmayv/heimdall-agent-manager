/**
 * Breadcrumbs — the trail showing where a page sits.
 * ------------------------------------------------------------------
 * Purpose: REQ-UI-14 makes a breadcrumb trail every resource page's contract, on all
 * five resources and on list, view and add/edit alike. A breadcrumb trail already
 * existed, but private to `AppShell` — promoting it into `@ui/composites` is what lets
 * a page carry its own trail (via `PageShell`'s `breadcrumbs` prop) instead of the
 * shell guessing one from a static path map.
 *
 * NOT for: tabs, a back button, or primary navigation.
 *
 * Layer: composite. Product-agnostic: a crumb is a label and an optional href.
 *
 * The last crumb is the current page: it is never a link, and carries
 * `aria-current="page"`. Earlier crumbs link only if given an `href` — a crumb with no
 * href renders as plain text, which is how an un-navigable ancestor (a grouping level
 * with no page of its own) is expressed.
 *
 * Accessibility (built in): a `<nav aria-label="Breadcrumb">` wrapping an ordered
 * list, so a screen reader announces both the landmark and the depth. Separators are
 * `aria-hidden` — they are decoration, not content.
 *
 * Tokens only. Escape hatch: `className` merges onto the `<nav>` root; other HTML
 * attributes (`data-debug-id`, …) pass through to it.
 */
import React from 'react';
import type { RootClassNameProps } from '../types';

export interface Crumb {
  /** Visible text for this level. */
  label: string;
  /**
   * Where this level navigates. Omit for an un-navigable ancestor. Ignored on the
   * last crumb, which is the current page and is never a link.
   */
  href?: string;
}

export interface BreadcrumbsProps
  extends Omit<React.HTMLAttributes<HTMLElement>, 'className' | 'children'>,
    RootClassNameProps {
  /** The trail, root first. The last entry is the current page. */
  crumbs: Crumb[];
  /** Accessible name for the landmark. Default `'Breadcrumb'`. */
  label?: string;
}

export const Breadcrumbs: React.FC<BreadcrumbsProps> = ({
  crumbs,
  label = 'Breadcrumb',
  className,
  ...rest
}) => {
  if (crumbs.length === 0) return null;

  return (
    <nav
      {...rest}
      aria-label={label}
      className={['flex flex-wrap items-center gap-2 text-body-sm text-muted', className]
        .filter(Boolean)
        .join(' ')}
    >
      <ol className="flex flex-wrap items-center gap-2">
        {crumbs.map((crumb, index) => {
          const isLast = index === crumbs.length - 1;
          return (
            <li key={`${crumb.label}-${index}`} className="inline-flex items-center gap-2">
              {index > 0 ? (
                <span aria-hidden="true" className="text-faint">
                  /
                </span>
              ) : null}
              {crumb.href && !isLast ? (
                <a
                  href={crumb.href}
                  className="rounded-[var(--radius-sm)] font-semibold text-muted hover:text-primary focus-visible:shadow-focus focus-visible:outline-none"
                >
                  {crumb.label}
                </a>
              ) : (
                <span aria-current={isLast ? 'page' : undefined} className="font-semibold text-primary">
                  {crumb.label}
                </span>
              )}
            </li>
          );
        })}
      </ol>
    </nav>
  );
};

export default Breadcrumbs;
