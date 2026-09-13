/**
 * Kbd — a keyboard-shortcut hint chip.
 * ------------------------------------------------------------------
 * Purpose: display a keyboard key / shortcut (EL-053), rendering a real `<kbd>`
 * so the markup is semantic, folding the `rounded border bg px text-[10/11]` chip
 * recipes (CommandPalette shortcut hints) into one token-driven chip.
 *
 * NOT for: running the shortcut (that is the caller's key handler) or general
 * inline code (use `Text role="code"` / a `<code>`).
 *
 * Layer: primitive. Spec: `docs/ui-audit/04-component-catalogue.md` › Link · Spinner · Kbd · Avatar.
 * Prop names follow the shared vocabulary in `../types`. Native `<kbd>`
 * attributes (`title`, `data-*`, …) pass through via `rest`.
 *
 * Compose multiple for a chord: `<span><Kbd>⌘</Kbd><Kbd>K</Kbd></span>` — one Kbd
 * per key.
 *
 * Accessibility: `<kbd>` is the semantic element for keyboard input; the visible
 * key text is the accessible content.
 *
 * Tokens only: color/radius/type resolve to tokens. No raw hex/px.
 *
 * Escape hatch: `className` merges onto the `<kbd>`.
 */
import React from 'react';
import type { RootClassNameProps } from '../types';

const BASE =
  'inline-flex items-center justify-center rounded-[var(--radius-sm)] border border-subtle ' +
  'bg-surface-raised px-1.5 py-0.5 text-[length:var(--text-caption-size)] font-medium ' +
  'leading-none text-muted';

export interface KbdProps
  extends Omit<React.HTMLAttributes<HTMLElement>, 'className'>,
    RootClassNameProps {
  children: React.ReactNode;
}

export const Kbd = React.forwardRef<HTMLElement, KbdProps>(function Kbd(
  { className, children, ...rest },
  ref,
) {
  const rootClassName = [BASE, className ?? ''].filter(Boolean).join(' ').replace(/\s+/g, ' ').trim();
  return (
    <kbd ref={ref} className={rootClassName} {...rest}>
      {children}
    </kbd>
  );
});

export default Kbd;
