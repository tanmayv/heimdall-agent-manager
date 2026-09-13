/**
 * Link — a navigation text link.
 * ------------------------------------------------------------------
 * Purpose: the one anchor for NAVIGATION (EL-016) — it renders a real `<a>` with
 * a built-in focus ring and consistent underline behavior, folding the ad-hoc
 * `text-sky-*`/`text-zinc-* hover:…` link recipes into `variant` + `tone`.
 *
 * NOT for: an action (something that mutates state / opens a dialog / submits) —
 * that is a `Button` (use `variant="ghost"` for a text-styled action). If your
 * "link" has an `onClick` and no meaningful `href`, you almost certainly want
 * `Button`, not `Link`. Link is for going somewhere.
 *
 * Layer: primitive. Spec: `docs/ui-audit/04-component-catalogue.md` › Link.
 * Prop names follow the shared vocabulary in `../types`. Native `<a>` attributes
 * (`href`, `target`, `rel`, `onClick`, `data-*`, `aria-*`, `ref`, …) pass through
 * via `rest` — the caller owns `href` and, for `target="_blank"`, `rel`.
 *
 * variant: `inline` sits inside a run of text (always underlined so it is
 * distinguishable without color); `standalone` is a link on its own line
 * (underline on hover/focus). tone: `accent` (default) or `muted` for a
 * low-emphasis nav link (back/breadcrumb).
 *
 * Accessibility (built in): a real `<a>`; `focus-visible` shows a token focus
 * ring (never removed). The caller supplies the link text (accessible name) and
 * a real destination.
 *
 * Tokens only: color/radius/motion resolve to tokens. No raw hex/px.
 *
 * Escape hatch: `className` merges onto the `<a>` — use it for layout (e.g.
 * `inline-flex items-center gap-1` around an icon), never to re-set link color.
 */
import React from 'react';
import type { RootClassNameProps } from '../types';

export type LinkVariant = 'inline' | 'standalone';
export type LinkTone = 'accent' | 'muted';

const BASE =
  'rounded-[var(--radius-sm)] underline-offset-2 transition-colors duration-fast ' +
  'focus-visible:outline-none focus-visible:shadow-focus';

const TONE_CLASSES: Record<LinkTone, string> = {
  accent: 'text-accent hover:brightness-110',
  muted: 'text-muted hover:text-primary',
};

const VARIANT_CLASSES: Record<LinkVariant, string> = {
  inline: 'underline',
  standalone: 'hover:underline',
};

export interface LinkProps
  extends Omit<React.AnchorHTMLAttributes<HTMLAnchorElement>, 'className'>,
    RootClassNameProps {
  /** `inline` (in a text run, always underlined) or `standalone`. Default `inline`. */
  variant?: LinkVariant;
  /** `accent` (default) or `muted` low-emphasis nav link. */
  tone?: LinkTone;
  children?: React.ReactNode;
}

export const Link = React.forwardRef<HTMLAnchorElement, LinkProps>(function Link(
  { variant = 'inline', tone = 'accent', className, children, ...rest },
  ref,
) {
  const rootClassName = [BASE, TONE_CLASSES[tone], VARIANT_CLASSES[variant], className ?? '']
    .filter(Boolean)
    .join(' ')
    .replace(/\s+/g, ' ')
    .trim();

  return (
    <a ref={ref} className={rootClassName} {...rest}>
      {children}
    </a>
  );
});

export default Link;
