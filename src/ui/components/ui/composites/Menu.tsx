/**
 * Menu — a popover list of actions from a trigger.
 * ------------------------------------------------------------------
 * Purpose: the one dropdown menu of actions (EL-057), fixing the "menu without
 * menu keyboarding" defect — it implements the ARIA menu-button pattern (roving
 * focus, arrow keys, Home/End, Esc, focus restore) once, for every kebab/overflow
 * dropdown.
 *
 * NOT for: choosing a value from options (use `Select`/`Combobox`), or a dialog
 * (`Modal`). Menu items DO things; they are not form values.
 *
 * Layer: composite. Spec: `docs/ui-audit/04-component-catalogue.md` › Menu.
 *
 * API: pass the `trigger` element (it is cloned to get `aria-haspopup="menu"` +
 * `aria-expanded` + the toggle handler) and `Menu.Item` children. Uncontrolled by
 * default; pass `open`/`onOpenChange` to control it. Give the menu an accessible
 * name via `label` (or the trigger's own text).
 *
 * Accessibility (built in): trigger gets `aria-haspopup`/`aria-expanded`; the
 * popup is `role="menu"` and each item `role="menuitem"` with roving `tabindex`
 * (focus moves to the active item). Down/Up move, Home/End jump, Enter/Space (or
 * click) activate + close, Esc closes and restores focus to the trigger, Tab
 * closes, outside-click closes.
 *
 * Tokens only: `z-dropdown`, `color-surface-raised`, `radius-md`, `shadow-overlay`,
 * spacing. No raw values.
 *
 * Escape hatch: `className` merges onto the popup.
 */
import React, {
  createContext,
  useCallback,
  useContext,
  useEffect,
  useRef,
  useState,
} from 'react';
import type { OpenChangeHandler, RootClassNameProps } from '../types';

interface MenuCtx {
  close: (restoreFocus?: boolean) => void;
}
const MenuContext = createContext<MenuCtx | null>(null);

const MENUITEM_SELECTOR = '[role="menuitem"]:not([aria-disabled="true"])';

export interface MenuProps extends RootClassNameProps {
  /** The trigger element (cloned to add aria-haspopup/expanded + toggle). */
  trigger: React.ReactElement;
  /** Menu.Item children. */
  children?: React.ReactNode;
  /** Accessible name for the menu (when the trigger has no text of its own). */
  label?: string;
  /** Controlled open state (omit for uncontrolled). */
  open?: boolean;
  /** Fired when the open state should change. */
  onOpenChange?: OpenChangeHandler;
  /** Popup alignment relative to the trigger. Default `start` (left-aligned). */
  align?: 'start' | 'end';
}

const MenuRoot: React.FC<MenuProps> = ({
  trigger,
  children,
  label,
  open: openProp,
  onOpenChange,
  align = 'start',
  className,
}) => {
  const isControlled = openProp !== undefined;
  const [openState, setOpenState] = useState(false);
  const open = isControlled ? openProp : openState;

  const rootRef = useRef<HTMLDivElement | null>(null);
  const triggerRef = useRef<HTMLElement | null>(null);
  const menuRef = useRef<HTMLDivElement | null>(null);

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

  const items = useCallback(
    () => Array.from(menuRef.current?.querySelectorAll<HTMLElement>(MENUITEM_SELECTOR) ?? []),
    [],
  );

  // Focus the first item on open.
  useEffect(() => {
    if (!open) return;
    const first = items()[0];
    first?.focus();
    const onDown = (e: MouseEvent) => {
      if (rootRef.current && !rootRef.current.contains(e.target as Node)) setOpen(false);
    };
    document.addEventListener('mousedown', onDown);
    return () => document.removeEventListener('mousedown', onDown);
  }, [open, items, setOpen]);

  function onMenuKeyDown(event: React.KeyboardEvent) {
    const list = items();
    if (list.length === 0) return;
    const idx = list.indexOf(document.activeElement as HTMLElement);
    switch (event.key) {
      case 'ArrowDown':
        event.preventDefault();
        list[(idx + 1) % list.length]?.focus();
        break;
      case 'ArrowUp':
        event.preventDefault();
        list[(idx - 1 + list.length) % list.length]?.focus();
        break;
      case 'Home':
        event.preventDefault();
        list[0]?.focus();
        break;
      case 'End':
        event.preventDefault();
        list[list.length - 1]?.focus();
        break;
      case 'Escape':
        event.preventDefault();
        close();
        break;
      case 'Tab':
        close(false);
        break;
      default:
    }
  }

  // Clone the trigger to wire aria + toggle + ref.
  const triggerEl = React.cloneElement(trigger, {
    'aria-haspopup': 'menu',
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

  const menuClassName = [
    'absolute z-dropdown mt-1 min-w-[12rem] rounded-[var(--radius-md)] border border-subtle',
    'bg-surface-raised py-1 shadow-overlay outline-none',
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
          ref={menuRef}
          role="menu"
          aria-label={label}
          onKeyDown={onMenuKeyDown}
          className={menuClassName}
        >
          <MenuContext.Provider value={{ close }}>{children}</MenuContext.Provider>
        </div>
      ) : null}
    </div>
  );
};

export interface MenuItemProps
  extends Omit<React.ButtonHTMLAttributes<HTMLButtonElement>, 'className'>,
    RootClassNameProps {
  /** Marks a destructive action (danger styling). */
  danger?: boolean;
}

/** A single actionable row in a Menu. */
export const MenuItem: React.FC<MenuItemProps> = ({
  danger = false,
  disabled,
  onClick,
  className,
  children,
  ...rest
}) => {
  const ctx = useContext(MenuContext);
  return (
    <button
      {...rest}
      type="button"
      role="menuitem"
      tabIndex={-1}
      aria-disabled={disabled || undefined}
      disabled={disabled}
      onClick={(e) => {
        onClick?.(e);
        ctx?.close();
      }}
      className={[
        'flex w-full items-center gap-2 px-3 py-1.5 text-left text-[length:var(--text-body-sm-size)]',
        'outline-none focus-visible:bg-surface-overlay hover:bg-surface-overlay',
        'disabled:opacity-50 disabled:cursor-not-allowed',
        danger ? 'text-danger' : 'text-primary',
        className ?? '',
      ]
        .filter(Boolean)
        .join(' ')
        .replace(/\s+/g, ' ')
        .trim()}
    >
      {children}
    </button>
  );
};

interface MenuComponent extends React.FC<MenuProps> {
  Item: typeof MenuItem;
}
export const Menu = MenuRoot as MenuComponent;
Menu.Item = MenuItem;

export default Menu;
