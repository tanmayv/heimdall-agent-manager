/**
 * radioGroup — keyboard behaviour shared by the panel's radiogroups (Runs on, the
 * provider list, the Connection cards): one tab stop (roving tabindex) and arrow keys
 * that move and select, skipping disabled options (WAI-ARIA radio group pattern).
 */
import type React from 'react';

export interface RadioItem {
  value: string;
  disabled?: boolean;
}

/** The value that owns the group's tab stop: the checked option, else the first enabled one. */
export function radioTabStop(items: RadioItem[], selected: string): string {
  const checked = items.find((i) => i.value === selected && !i.disabled);
  return checked ? checked.value : items.find((i) => !i.disabled)?.value ?? '';
}

/** The option an arrow/Home/End key moves to (null: the key is not a group key). */
export function radioKeyTarget(items: RadioItem[], selected: string, key: string): string | null {
  const enabled = items.filter((i) => !i.disabled).map((i) => i.value);
  if (enabled.length === 0) return null;
  const at = enabled.indexOf(selected);
  switch (key) {
    case 'ArrowDown':
    case 'ArrowRight':
      return enabled[at < 0 ? 0 : (at + 1) % enabled.length];
    case 'ArrowUp':
    case 'ArrowLeft':
      return enabled[at < 0 ? enabled.length - 1 : (at - 1 + enabled.length) % enabled.length];
    case 'Home':
      return enabled[0];
    case 'End':
      return enabled[enabled.length - 1];
    default:
      return null;
  }
}

/** onKeyDown for the radiogroup element; options carry `data-radio-value`. */
export function radioGroupKeyDown(items: RadioItem[], selected: string, onSelect: (value: string) => void) {
  return (event: React.KeyboardEvent<HTMLElement>) => {
    const next = radioKeyTarget(items, selected, event.key);
    if (next === null) return;
    event.preventDefault();
    if (next !== selected) onSelect(next);
    const target = Array.from(event.currentTarget.querySelectorAll<HTMLElement>('[data-radio-value]'))
      .find((el) => el.getAttribute('data-radio-value') === next);
    target?.focus();
  };
}
