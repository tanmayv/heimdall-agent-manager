/**
 * Tabs — accessible tabbed navigation.
 * ------------------------------------------------------------------
 * Purpose: one tabs dialect (EL-061/063/079) with correct semantics, collapsing
 * the four ad-hoc tab styles into `variant='underline'|'segmented'|'pill'`. Fixes
 * the "tabs without tablist/roving keyboarding" defect.
 *
 * NOT for: page navigation (use links/router) or a menu (use `Menu`).
 *
 * Layer: composite. Spec: `docs/ui-audit/04-component-catalogue.md` › Tabs.
 *
 * API (composition): `<Tabs value onChange variant>` (uncontrolled via
 * `defaultValue`) wrapping `<Tabs.List>` of `<Tabs.Tab value>` and one
 * `<Tabs.Panel value>` per tab.
 *
 * Accessibility (built in): `role="tablist"` / `role="tab"` / `role="tabpanel"`;
 * roving `tabindex` (only the selected tab is tabbable); Left/Right (and Home/End)
 * move + activate; `aria-selected` + `aria-controls`/`aria-labelledby` wire tabs
 * to panels; panels are `hidden` when inactive and focusable for the panel-first
 * reading order.
 *
 * Tokens only: color/border/radius/type via tokens. No raw values.
 */
import React, { createContext, useContext, useId, useState } from 'react';
import type { RootClassNameProps } from '../types';

export type TabsVariant = 'underline' | 'segmented' | 'pill';

interface TabsCtx {
  value: string;
  setValue: (v: string) => void;
  variant: TabsVariant;
  baseId: string;
}
const TabsContext = createContext<TabsCtx | null>(null);
const useTabs = () => {
  const ctx = useContext(TabsContext);
  if (!ctx) throw new Error('Tabs.* must be used inside <Tabs>');
  return ctx;
};

const tabId = (base: string, v: string) => `${base}-tab-${v}`;
const panelId = (base: string, v: string) => `${base}-panel-${v}`;

export interface TabsProps extends RootClassNameProps {
  /** Controlled selected tab value. */
  value?: string;
  /** Uncontrolled initial value. */
  defaultValue?: string;
  /** Fired with the newly selected value. */
  onChange?: (value: string) => void;
  /** Visual style. Default `underline`. */
  variant?: TabsVariant;
  children?: React.ReactNode;
}

interface TabsComponent extends React.FC<TabsProps> {
  List: typeof TabsList;
  Tab: typeof Tab;
  Panel: typeof TabsPanel;
}

const TabsRoot: React.FC<TabsProps> = ({
  value: valueProp,
  defaultValue = '',
  onChange,
  variant = 'underline',
  className,
  children,
}) => {
  const isControlled = valueProp !== undefined;
  const [valueState, setValueState] = useState(defaultValue);
  const value = isControlled ? valueProp : valueState;
  const baseId = useId();

  const setValue = (v: string) => {
    if (!isControlled) setValueState(v);
    onChange?.(v);
  };

  return (
    <TabsContext.Provider value={{ value, setValue, variant, baseId }}>
      <div className={className}>{children}</div>
    </TabsContext.Provider>
  );
};

const LIST_VARIANT: Record<TabsVariant, string> = {
  underline: 'flex items-center gap-1 border-b border-subtle',
  segmented: 'inline-flex items-center gap-0.5 rounded-[var(--radius-md)] border border-subtle bg-surface p-0.5',
  pill: 'inline-flex items-center gap-1',
};

/** The row of tabs. */
export const TabsList: React.FC<{ children?: React.ReactNode; className?: string; label?: string }> = ({
  children,
  className,
  label,
}) => {
  const { variant } = useTabs();

  function onKeyDown(event: React.KeyboardEvent) {
    const tabs = Array.from(
      event.currentTarget.querySelectorAll<HTMLElement>('[role="tab"]:not([disabled])'),
    );
    if (tabs.length === 0) return;
    const idx = tabs.indexOf(document.activeElement as HTMLElement);
    let next = -1;
    if (event.key === 'ArrowRight' || event.key === 'ArrowDown') next = (idx + 1) % tabs.length;
    else if (event.key === 'ArrowLeft' || event.key === 'ArrowUp') next = (idx - 1 + tabs.length) % tabs.length;
    else if (event.key === 'Home') next = 0;
    else if (event.key === 'End') next = tabs.length - 1;
    if (next >= 0) {
      event.preventDefault();
      tabs[next].focus();
      tabs[next].click();
    }
  }

  return (
    <div role="tablist" aria-label={label} aria-orientation="horizontal" onKeyDown={onKeyDown} className={[LIST_VARIANT[variant], className].filter(Boolean).join(' ')}>
      {children}
    </div>
  );
};

function tabClasses(variant: TabsVariant, active: boolean): string {
  const base =
    'cursor-pointer rounded-[var(--radius-sm)] px-3 py-1.5 text-[length:var(--text-body-sm-size)] font-medium ' +
    'outline-none transition-colors duration-fast focus-visible:shadow-focus focus-visible:outline-none ' +
    'disabled:opacity-50 disabled:cursor-not-allowed';
  if (variant === 'underline') {
    return [
      base,
      '-mb-px rounded-none border-b-2 px-3',
      active ? 'border-accent text-primary' : 'border-transparent text-muted hover:text-primary',
    ].join(' ');
  }
  if (variant === 'segmented') {
    return [base, active ? 'bg-surface-raised text-primary shadow-panel' : 'text-muted hover:text-primary'].join(' ');
  }
  // pill
  return [
    base,
    'rounded-pill border',
    active ? 'border-accent bg-accent text-accent-fg' : 'border-subtle text-muted hover:text-primary',
  ].join(' ');
}

export interface TabProps
  extends Omit<React.ButtonHTMLAttributes<HTMLButtonElement>, 'className' | 'value'>,
    RootClassNameProps {
  /** The tab's value (matches its Panel). */
  value: string;
  children?: React.ReactNode;
}

/** A single tab. */
export const Tab: React.FC<TabProps> = ({ value, className, children, disabled, ...rest }) => {
  const { value: active, setValue, variant, baseId } = useTabs();
  const isActive = active === value;
  return (
    <button
      {...rest}
      type="button"
      role="tab"
      id={tabId(baseId, value)}
      aria-selected={isActive}
      aria-controls={panelId(baseId, value)}
      tabIndex={isActive ? 0 : -1}
      disabled={disabled}
      onClick={() => setValue(value)}
      className={[tabClasses(variant, isActive), className].filter(Boolean).join(' ')}
    >
      {children}
    </button>
  );
};

export interface TabsPanelProps extends RootClassNameProps {
  /** The panel's value (matches its Tab). */
  value: string;
  children?: React.ReactNode;
}

/** The content panel for a tab. */
export const TabsPanel: React.FC<TabsPanelProps> = ({ value, className, children }) => {
  const { value: active, baseId } = useTabs();
  const isActive = active === value;
  if (!isActive) return null;
  return (
    <div
      role="tabpanel"
      id={panelId(baseId, value)}
      aria-labelledby={tabId(baseId, value)}
      tabIndex={0}
      className={className}
    >
      {children}
    </div>
  );
};

export const Tabs = TabsRoot as TabsComponent;
Tabs.List = TabsList;
Tabs.Tab = Tab;
Tabs.Panel = TabsPanel;

export default Tabs;
