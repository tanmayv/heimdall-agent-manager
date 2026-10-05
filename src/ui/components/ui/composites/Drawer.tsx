/**
 * Drawer — a focus-managed edge sheet.
 * ------------------------------------------------------------------
 * Purpose: the edge-anchored sibling of `Modal` (EL-058) — a full-height panel
 * that slides in from the left or right. It shares Modal's exact focus-management
 * contract via `useDialogA11y` (portal, focus trap, Esc, focus restore, scroll
 * lock, backdrop close) — the finding #2 fix, implemented once.
 *
 * NOT for: a centered dialog (use `Modal`), a menu/popover, or a persistent
 * sidebar (that is layout, not an overlay).
 *
 * Layer: composite. Spec: `docs/ui-audit/04-component-catalogue.md` › Modal · Drawer.
 *
 * API mirrors Modal: `open` + `onOpenChange` (controlled) · `title` (required →
 * `aria-labelledby`) · `size` · `side` (`right` default | `left` | `bottom`) ·
 * `children` (compose `Drawer.Body` / `Drawer.Footer`). `bottom` is a full-width
 * slide-up sheet (height-capped) for mobile inspector/detail surfaces.
 *
 * Accessibility (built in): portal; `role="dialog"` `aria-modal` `aria-labelledby`;
 * focus trapped and restored; Esc + backdrop close; background scroll locked.
 *
 * Tokens only: `z-modal`, `color-surface-overlay`, `shadow-overlay`, spacing.
 *
 * Escape hatch: `className` merges onto the panel.
 */
import React, { useCallback, useId, useRef } from 'react';
import { createPortal } from 'react-dom';
import type { OpenChangeHandler, RootClassNameProps } from '../types';
import { IconButton } from '../primitives/IconButton';
import { ModalBody, ModalFooter } from './Modal';
import { useDialogA11y } from './useDialogA11y';

export type DrawerSize = 'sm' | 'md' | 'lg';
export type DrawerSide = 'left' | 'right' | 'bottom';

const SIZE_W: Record<DrawerSize, string> = {
  sm: 'max-w-sm',
  md: 'max-w-md',
  lg: 'max-w-lg',
};

// Per-side panel shape. left/right are full-height edge sheets (width-capped by
// `size`); `bottom` is a full-width slide-up sheet (height-capped), for the
// mobile inspector/detail sheets that a side drawer can't model.
//
// REQ-MODAL-2: the `bottom` cap is against `--app-viewport-height` (the visible region), and
// it only works because the overlay below is re-anchored off `inset-0`. `items-end` is the
// worst case in the OVERLAYS note in `src/ui/styles.css`: it pins the sheet's bottom edge to
// the layout viewport, so a bottom sheet sat entirely behind the keyboard and shrinking its
// cap moved it not at all. Both edits are load-bearing; neither works alone.
// `left`/`right` take `h-full`, which now resolves against the visible region too.
const SIDE_CLASS: Record<DrawerSide, string> = {
  left: 'h-full w-full mr-auto border-r',
  right: 'h-full w-full ml-auto border-l',
  bottom: 'mt-auto w-full max-h-[calc(var(--app-viewport-height)*0.85)] border-t rounded-t-[var(--radius-lg)]',
};

export interface DrawerProps
  extends Omit<React.HTMLAttributes<HTMLDivElement>, 'title' | 'children'>,
    RootClassNameProps {
  /** Whether the drawer is open (controlled). */
  open: boolean;
  /** Fired with the requested open state (Esc, backdrop, close button). */
  onOpenChange: OpenChangeHandler;
  /** Accessible title — becomes the heading + `aria-labelledby`. */
  title: React.ReactNode;
  /** Panel max width. Default `md`. */
  size?: DrawerSize;
  /** Which edge it anchors to. Default `right`. */
  side?: DrawerSide;
  /** Suppress the default header bar (title and close button). */
  hideHeader?: boolean;
  /** On side='bottom', expand to full viewport height instead of max-h-[calc(var(--app-viewport-height)*0.85)]. */
  fullHeight?: boolean;
  children?: React.ReactNode;
}

interface DrawerComponent extends React.FC<DrawerProps> {
  Body: typeof ModalBody;
  Footer: typeof ModalFooter;
}

const DrawerBase: React.FC<DrawerProps> = ({
  open,
  onOpenChange,
  title,
  size = 'md',
  side = 'right',
  hideHeader = false,
  fullHeight = false,
  className,
  children,
  ...rest
}) => {
  const panelRef = useRef<HTMLDivElement | null>(null);
  const titleId = useId();

  const close = useCallback(() => onOpenChange(false), [onOpenChange]);
  useDialogA11y(open, close, panelRef);

  if (!open) return null;

  const isBottom = side === 'bottom';
  const sideClass = isBottom
    ? (fullHeight ? 'h-full max-h-full w-full rounded-none border-t-0' : SIDE_CLASS.bottom)
    : SIDE_CLASS[side];

  const accessibleLabel = typeof title === 'string' ? title : (typeof title === 'number' ? String(title) : (rest['aria-label'] || 'Drawer'));

  return createPortal(
    <div
      // REQ-MODAL-2: `app-viewport-height`, not `inset-0`. See the SIDE_CLASS note above.
      className={['fixed inset-x-0 top-0 app-viewport-height z-modal flex bg-surface-overlay/80 backdrop-blur-sm', isBottom ? 'items-end' : '']
        .filter(Boolean)
        .join(' ')}
      onMouseDown={(e) => {
        if (e.target === e.currentTarget) close();
      }}
    >
      <div
        {...rest}
        ref={panelRef}
        role="dialog"
        aria-modal="true"
        aria-labelledby={hideHeader ? undefined : titleId}
        aria-label={hideHeader ? accessibleLabel : rest['aria-label']}
        tabIndex={-1}
        className={[
          'flex flex-col overflow-hidden border-subtle bg-surface-overlay text-primary shadow-overlay outline-none',
          isBottom ? '' : SIZE_W[size],
          sideClass,
          className,
        ]
          .filter(Boolean)
          .join(' ')}
      >
        {!hideHeader && (
          <div className="flex items-start justify-between gap-3 px-5 pt-4 pb-3">
            <h2 id={titleId} className="text-title text-primary">
              {title}
            </h2>
            <IconButton icon="close" label="Close" size="sm" onClick={close} className="-mr-1.5 -mt-0.5" />
          </div>
        )}
        <div className="min-h-0 flex-1 overflow-auto">{children}</div>
      </div>
    </div>,
    document.body,
  );
};

export const Drawer = DrawerBase as DrawerComponent;
Drawer.Body = ModalBody;
Drawer.Footer = ModalFooter;

export default Drawer;
