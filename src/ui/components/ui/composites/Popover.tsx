/**
 * Popover — a non-modal floating panel anchored to a trigger.
 * ------------------------------------------------------------------
 * Purpose: the one anchored panel for RICH content next to a control — a set of
 * form controls, a details card, a mini-editor — where `Menu` (a list of
 * actions) and `Modal` (a centered, focus-trapped dialog) are both wrong. It
 * standardizes the hand-rolled "click a chip → a bordered dark panel appears"
 * overlays (e.g. the conversation runtime bridge/provider/tier controls).
 *
 * NOT for: a list of actions (use `Menu`), a value picker (`Select`/`Combobox`),
 * or a blocking dialog (`Modal`). It is non-modal: the page behind stays live.
 *
 * Layer: composite. Built to mirror `Menu`'s trigger/placement API so the two
 * feel the same.
 *
 * API: `trigger` (cloned for aria-haspopup="dialog" + aria-expanded + toggle),
 * `open`/`onOpenChange` (omit to run uncontrolled), `align` (start|end),
 * `side` (bottom|top), `label` (accessible name), and `children` (the content).
 *
 * Accessibility: the panel is `role="dialog"` with `aria-label`; focus moves to
 * its first focusable on open and is restored to the trigger on close; Esc and
 * outside-pointer-down close it. Non-modal, so focus is NOT trapped.
 *
 * Tokens only: `z-dropdown`, `color-surface-raised`, `radius-md`, `shadow-overlay`,
 * spacing. Escape hatch: `className` merges onto the panel.
 */
import React, { useCallback, useEffect, useRef, useState } from 'react';
import type { OpenChangeHandler, RootClassNameProps } from '../types';

const FOCUSABLE =
  'a[href],area[href],input:not([disabled]),select:not([disabled]),textarea:not([disabled]),' +
  'button:not([disabled]),[tabindex]:not([tabindex="-1"]),[contenteditable="true"]';

export interface PopoverProps extends RootClassNameProps {
  /** The trigger element (cloned to add aria-haspopup/expanded + toggle). */
  trigger: React.ReactElement;
  /** Panel content. */
  children?: React.ReactNode;
  /** Accessible name for the panel. */
  label?: string;
  /** Controlled open state (omit for uncontrolled). */
  open?: boolean;
  /** Fired when the open state should change. */
  onOpenChange?: OpenChangeHandler;
  /** Horizontal alignment relative to the trigger. Default `start`. */
  align?: 'start' | 'end';
  /** Which side of the trigger the panel opens on. Default `bottom`. */
  side?: 'bottom' | 'top';
}

const PopoverRoot: React.FC<PopoverProps> = ({
  trigger,
  children,
  label,
  open: openProp,
  onOpenChange,
  align = 'start',
  side = 'bottom',
  className,
}) => {
  const isControlled = openProp !== undefined;
  const [openState, setOpenState] = useState(false);
  const open = isControlled ? openProp : openState;

  const rootRef = useRef<HTMLDivElement | null>(null);
  const triggerRef = useRef<HTMLElement | null>(null);
  const panelRef = useRef<HTMLDivElement | null>(null);

  const setOpen = useCallback(
    (next: boolean) => {
      if (!isControlled) setOpenState(next);
      onOpenChange?.(next);
    },
    [isControlled, onOpenChange],
  );

  const close = useCallback(
    (restoreFocus = true) => {
      setOpen(false);
      if (restoreFocus) triggerRef.current?.focus();
    },
    [setOpen],
  );

  // Read the latest setOpen without re-running the open effect (avoids the
  // controlled-inline-handler focus-steal seen in Menu/Modal).
  const setOpenRef = useRef(setOpen);
  useEffect(() => {
    setOpenRef.current = setOpen;
  });

  // On open: focus the first focusable in the panel; close on outside pointer-down.
  useEffect(() => {
    if (!open) return;
    const panel = panelRef.current;
    panel?.querySelector<HTMLElement>(FOCUSABLE)?.focus();
    const onDown = (e: MouseEvent) => {
      if (rootRef.current && !rootRef.current.contains(e.target as Node)) setOpenRef.current(false);
    };
    document.addEventListener('mousedown', onDown);
    return () => document.removeEventListener('mousedown', onDown);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [open]);

  const triggerEl = React.cloneElement(trigger, {
    'aria-haspopup': 'dialog',
    'aria-expanded': open,
    onClick: (e: React.MouseEvent) => {
      (trigger.props as { onClick?: (e: React.MouseEvent) => void }).onClick?.(e);
      setOpen(!open);
    },
    ref: (node: HTMLElement | null) => {
      triggerRef.current = node;
      const r = (trigger as unknown as { ref?: React.Ref<HTMLElement> }).ref;
      if (typeof r === 'function') r(node);
      else if (r && typeof r === 'object') (r as React.MutableRefObject<HTMLElement | null>).current = node;
    },
  } as Record<string, unknown>);

  const panelClassName = [
    'absolute z-dropdown min-w-[16rem] rounded-[var(--radius-md)] border border-subtle',
    'bg-surface-raised p-3 text-primary shadow-overlay outline-none',
    side === 'top' ? 'bottom-full mb-1' : 'top-full mt-1',
    align === 'end' ? 'right-0' : 'left-0',
    className ?? '',
  ]
    .filter(Boolean)
    .join(' ')
    .replace(/\s+/g, ' ')
    .trim();

  return (
    <div ref={rootRef} className="relative inline-block">
      {triggerEl}
      {open ? (
        <div
          ref={panelRef}
          role="dialog"
          aria-label={label}
          onKeyDown={(e) => {
            if (e.key === 'Escape') {
              e.preventDefault();
              close();
            }
          }}
          className={panelClassName}
        >
          {children}
        </div>
      ) : null}
    </div>
  );
};

export const Popover = PopoverRoot;
export default Popover;
