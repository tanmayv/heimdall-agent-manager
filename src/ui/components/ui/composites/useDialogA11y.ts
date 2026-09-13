/**
 * useDialogA11y — the shared overlay focus-management contract.
 * ------------------------------------------------------------------
 * The single implementation of finding #2's fix, used by both `Modal` and
 * `Drawer` (and any future focus-trapped overlay): while `open`, it moves focus
 * into the panel, TRAPS Tab/Shift+Tab within it, closes on Esc, locks background
 * scroll, and restores focus to the previously-focused element on close.
 *
 * Internal to the composites layer — not re-exported from `@ui`.
 *
 * Usage: give the panel a ref and `tabIndex={-1}`, then call
 * `useDialogA11y(open, onClose, panelRef)`. `onClose` should be stable
 * (`useCallback`).
 */
import { useEffect, useRef } from 'react';

const FOCUSABLE =
  'a[href],area[href],input:not([disabled]),select:not([disabled]),textarea:not([disabled]),' +
  'button:not([disabled]),[tabindex]:not([tabindex="-1"]),[contenteditable="true"]';

export function useDialogA11y(
  open: boolean,
  onClose: () => void,
  panelRef: React.RefObject<HTMLElement | null>,
): void {
  const restoreRef = useRef<HTMLElement | null>(null);

  useEffect(() => {
    if (!open) return;

    // Remember what to restore focus to, then move focus into the dialog.
    restoreRef.current = (document.activeElement as HTMLElement) ?? null;
    const panel = panelRef.current;
    const first = panel?.querySelector<HTMLElement>(FOCUSABLE);
    (first ?? panel)?.focus();

    // Lock background scroll.
    const prevOverflow = document.body.style.overflow;
    document.body.style.overflow = 'hidden';

    const onKeyDown = (event: KeyboardEvent) => {
      if (event.key === 'Escape') {
        event.stopPropagation();
        onClose();
        return;
      }
      if (event.key !== 'Tab' || !panel) return;
      const nodes = Array.from(panel.querySelectorAll<HTMLElement>(FOCUSABLE)).filter(
        (el) => el.offsetParent !== null || el === document.activeElement,
      );
      if (nodes.length === 0) {
        event.preventDefault();
        panel.focus();
        return;
      }
      const firstEl = nodes[0];
      const lastEl = nodes[nodes.length - 1];
      const active = document.activeElement as HTMLElement | null;
      if (event.shiftKey && (active === firstEl || active === panel)) {
        event.preventDefault();
        lastEl.focus();
      } else if (!event.shiftKey && active === lastEl) {
        event.preventDefault();
        firstEl.focus();
      }
    };

    document.addEventListener('keydown', onKeyDown, true);
    return () => {
      document.removeEventListener('keydown', onKeyDown, true);
      document.body.style.overflow = prevOverflow;
      restoreRef.current?.focus?.();
    };
  }, [open, onClose, panelRef]);
}
