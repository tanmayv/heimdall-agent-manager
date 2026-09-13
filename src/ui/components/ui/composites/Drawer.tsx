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
 * `aria-labelledby`) · `size` · `side` (`right` default | `left`) · `children`
 * (compose `Drawer.Body` / `Drawer.Footer`).
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
export type DrawerSide = 'left' | 'right';

const SIZE_W: Record<DrawerSize, string> = {
  sm: 'max-w-sm',
  md: 'max-w-md',
  lg: 'max-w-lg',
};

const SIDE_CLASS: Record<DrawerSide, string> = {
  left: 'mr-auto border-r',
  right: 'ml-auto border-l',
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
  className,
  children,
  ...rest
}) => {
  const panelRef = useRef<HTMLDivElement | null>(null);
  const titleId = useId();

  const close = useCallback(() => onOpenChange(false), [onOpenChange]);
  useDialogA11y(open, close, panelRef);

  if (!open) return null;

  return createPortal(
    <div
      className="fixed inset-0 z-modal flex bg-black/70 backdrop-blur-sm"
      onMouseDown={(e) => {
        if (e.target === e.currentTarget) close();
      }}
    >
      <div
        {...rest}
        ref={panelRef}
        role="dialog"
        aria-modal="true"
        aria-labelledby={titleId}
        tabIndex={-1}
        className={[
          'flex h-full w-full flex-col overflow-hidden border-subtle bg-surface-overlay text-primary shadow-overlay outline-none',
          SIZE_W[size],
          SIDE_CLASS[side],
          className,
        ]
          .filter(Boolean)
          .join(' ')}
      >
        <div className="flex items-start justify-between gap-3 px-5 pt-4 pb-3">
          <h2 id={titleId} className="text-title text-primary">
            {title}
          </h2>
          <IconButton icon="close" label="Close" size="sm" onClick={close} className="-mr-1.5 -mt-0.5" />
        </div>
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
