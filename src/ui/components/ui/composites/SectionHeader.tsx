/**
 * SectionHeader — the one section-title dialect used inside a page.
 * ------------------------------------------------------------------
 * Purpose: label a group/section within a page (a `Panel`, a form fieldset, a
 * list region) with one consistent title treatment + optional description and
 * actions, optionally collapsible. Replaces the uppercase-eyebrow / h2 / h3 mix
 * catalogued in `docs/ui-audit/` (finding #7).
 *
 * NOT for: the page's top-level header (use `PageShell`, which owns the single
 * `<h1>`). SectionHeader renders an `<h2>` — a subheading beneath that `<h1>`.
 *
 * Layer: composite. Spec: `docs/ui-audit/04-component-catalogue.md` › SectionHeader.
 *
 * Accessibility:
 *   - Renders an `<h2>` (subordinate to PageShell's `<h1>`).
 *   - When `collapsible`, the title is a `<button aria-expanded>` controlling the
 *     `aria-controls` region, with a built-in focus ring. Controlled via
 *     `expanded` + `onToggle`.
 *
 * Tokens only: type/spacing/color via the Tailwind token utilities. No raw values.
 *
 * Escape hatch: `className` passes through to the root only.
 */
import React from 'react';
import type { DescribableProps, ExpandableProps, RootClassNameProps } from '../types';

export interface SectionHeaderProps
  extends DescribableProps,
    ExpandableProps,
    RootClassNameProps {
  /** The section title. Rendered as an `<h2>`. */
  title: React.ReactNode;
  /** Right-aligned actions (buttons, menus) for this section. */
  actions?: React.ReactNode;
  /** When true, the title toggles a disclosure (`aria-expanded`). Controlled. */
  collapsible?: boolean;
  /** Disclosure state change (only when `collapsible`). */
  onToggle?: (expanded: boolean) => void;
  /** `id` of the region this header controls (`aria-controls`, when collapsible). */
  controls?: string;
}

export const SectionHeader: React.FC<SectionHeaderProps> = ({
  title,
  description,
  hint,
  actions,
  collapsible = false,
  expanded = false,
  onToggle,
  controls,
  className,
}) => {
  const rootClassName = ['flex items-start justify-between gap-3', className]
    .filter(Boolean)
    .join(' ');
  const subtitle = description ?? hint;

  const heading = collapsible ? (
    <button
      type="button"
      aria-expanded={expanded}
      aria-controls={controls}
      onClick={() => onToggle?.(!expanded)}
      className="flex items-center gap-1.5 rounded-md text-title text-primary focus-visible:shadow-focus focus-visible:outline-none"
    >
      <span
        aria-hidden="true"
        className="text-muted transition-transform duration-fast"
        style={{ transform: expanded ? 'rotate(90deg)' : 'none' }}
      >
        ▸
      </span>
      <h2 className="text-title text-primary">{title}</h2>
    </button>
  ) : (
    <h2 className="text-title text-primary">{title}</h2>
  );

  return (
    <div className={rootClassName}>
      <div className="min-w-0">
        {heading}
        {subtitle ? <p className="mt-1 text-body-sm text-muted">{subtitle}</p> : null}
      </div>
      {actions ? <div className="flex shrink-0 items-center gap-2">{actions}</div> : null}
    </div>
  );
};

export default SectionHeader;
