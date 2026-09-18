/**
 * Modal — a focus-managed centered dialog.
 * ------------------------------------------------------------------
 * Purpose: the one centered overlay dialog (EL-055/059, standardizes the ~9
 * overlay families). It exists to fix finding #2 — overlays with no focus
 * management — ONCE, for every dialog: portal, `role="dialog"` + `aria-modal`,
 * focus trap, focus-on-open, Esc-to-close, focus restored to the trigger on
 * close, background scroll lock, backdrop-click close.
 *
 * NOT for: an edge sheet (use `Drawer`), a popover/menu (use `Menu`/`Popover`),
 * or a non-modal inline panel (`Panel`).
 *
 * Layer: composite. Spec: `docs/ui-audit/04-component-catalogue.md` › Modal · Drawer.
 *
 * API: `open` + `onOpenChange` (controlled) · `title` (required, becomes the
 * `aria-labelledby` heading) · `size` · `children`. Structure comes through
 * composition — `Modal.Body` and `Modal.Footer` — NOT through `headerText` /
 * `showCloseButton` / `footerButtonLabel` props.
 *
 * Accessibility contract (the whole point, built in):
 *   - Rendered in a portal; `role="dialog"` `aria-modal="true"`
 *     `aria-labelledby={titleId}`.
 *   - Focus moves into the dialog on open (first focusable, else the panel) and
 *     is TRAPPED (Tab / Shift+Tab cycle within); Esc closes; on close focus is
 *     restored to whatever was focused before it opened.
 *   - Background scroll is locked while open; a backdrop click closes.
 *
 * Tokens only: `z-modal`, `color-surface-overlay`, `radius-lg`, `shadow-overlay`,
 * spacing. No raw values.
 *
 * Escape hatch: `className` merges onto the panel.
 */
import React, { useCallback, useId, useRef } from 'react';
import { createPortal } from 'react-dom';
import type { OpenChangeHandler, RootClassNameProps } from '../types';
import { IconButton } from '../primitives/IconButton';
import { useDialogA11y } from './useDialogA11y';

export type ModalSize = 'sm' | 'md' | 'lg' | 'xl';

const SIZE_MAX_W: Record<ModalSize, string> = {
  sm: 'max-w-md',
  md: 'max-w-lg',
  lg: 'max-w-2xl',
  xl: 'max-w-4xl',
};

export interface ModalProps
  extends Omit<React.HTMLAttributes<HTMLDivElement>, 'title' | 'children'>,
    RootClassNameProps {
  /** Whether the dialog is open (controlled). */
  open: boolean;
  /** Fired with the requested open state (Esc, backdrop, close button). */
  onOpenChange: OpenChangeHandler;
  /** Accessible title — becomes the heading + `aria-labelledby`. */
  title: React.ReactNode;
  /** Max width. Default `md`. */
  size?: ModalSize;
  children?: React.ReactNode;
}

/** The scrollable content region of a Modal. */
export const ModalBody: React.FC<{ children?: React.ReactNode; className?: string }> = ({
  children,
  className,
}) => (
  <div className={['px-5 py-4', className].filter(Boolean).join(' ')}>{children}</div>
);

/** The action row of a Modal (right-aligned buttons). */
export const ModalFooter: React.FC<{ children?: React.ReactNode; className?: string }> = ({
  children,
  className,
}) => (
  <div
    className={['flex items-center justify-end gap-2 border-t border-subtle px-5 py-3', className]
      .filter(Boolean)
      .join(' ')}
  >
    {children}
  </div>
);

interface ModalComponent extends React.FC<ModalProps> {
  Body: typeof ModalBody;
  Footer: typeof ModalFooter;
}

const ModalBase: React.FC<ModalProps> = ({
  open,
  onOpenChange,
  title,
  size = 'md',
  className,
  children,
  ...rest
}) => {
  const panelRef = useRef<HTMLDivElement | null>(null);
  const titleId = useId();

  const close = useCallback(() => onOpenChange(false), [onOpenChange]);
  useDialogA11y(open, close, panelRef);

  // Pin Modal.Footer to the panel bottom: split it out of the scrolling body so
  // the action row stays visible while the body scrolls (tall dialogs like the
  // project launcher). Non-footer children scroll; footer(s) render below.
  const kids = React.Children.toArray(children);
  const footer = kids.filter((k) => React.isValidElement(k) && k.type === ModalFooter);
  const body = kids.filter((k) => !(React.isValidElement(k) && k.type === ModalFooter));

  if (!open) return null;

  return createPortal(
    <div
      className="fixed inset-0 z-modal flex items-center justify-center bg-surface-overlay/80 p-4 backdrop-blur-sm"
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
          'flex max-h-[calc(100vh-2rem)] w-full flex-col overflow-hidden rounded-[var(--radius-lg)]',
          'border border-subtle bg-surface-overlay text-primary shadow-overlay outline-none',
          SIZE_MAX_W[size],
          className,
        ]
          .filter(Boolean)
          .join(' ')}
      >
        <div className="flex items-start justify-between gap-3 px-5 pt-4 pb-3">
          <h2 id={titleId} className="text-title text-primary">
            {title}
          </h2>
          <IconButton icon="close" label="Close dialog" size="sm" onClick={close} className="-mr-1.5 -mt-0.5" />
        </div>
        <div className="min-h-0 flex-1 overflow-auto">{body}</div>
        {footer.length ? <div className="shrink-0">{footer}</div> : null}
      </div>
    </div>,
    document.body,
  );
};

export const Modal = ModalBase as ModalComponent;
Modal.Body = ModalBody;
Modal.Footer = ModalFooter;

export default Modal;
