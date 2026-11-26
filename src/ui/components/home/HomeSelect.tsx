import { useContext, useLayoutEffect, useRef } from 'react';
import { Select, type SelectProps } from '../ui/primitives/Select';
import { WidgetLayoutContext } from './WidgetLayoutChrome';

/** Home-only opt-in; the parent continues to own every Fleet draft value. */
export function HomeSelect(props: SelectProps) {
  const editing = !!useContext(WidgetLayoutContext);
  const trigger = useRef<HTMLButtonElement>(null);
  const bridge = useRef<Element | null>(null);
  const dashboard = useRef<Element | null>(null);
  useLayoutEffect(() => {
    bridge.current = trigger.current?.closest('.home-fleet-bridge') ?? null;
    dashboard.current = trigger.current?.closest('.home-dashboard') ?? null;
  });
  const fallback = () => {
    const toggle = bridge.current?.querySelector<HTMLButtonElement>('.home-fleet-bridge-toggle');
    if (toggle?.isConnected) return toggle;
    const edit = dashboard.current?.querySelector<HTMLButtonElement>('[data-debug-id="home-layout-edit"]');
    return edit?.isConnected ? edit : document.querySelector<HTMLButtonElement>('[data-debug-id="home-layout-edit"]');
  };
  // Edit completion resets only transient Select state, never the editor draft.
  return <Select {...props} key={String(editing)} ref={trigger} mobileSheet sheetFocusFallback={fallback} />;
}
