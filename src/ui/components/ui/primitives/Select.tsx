/**
 * Select — the custom single-choice dropdown.
 * ------------------------------------------------------------------
 * Purpose: the one dropdown for choosing from a short, known option set. Per
 * team direction the UI does NOT use native form controls for this — Select is a
 * fully custom "select-only combobox" (a `<button>` trigger + a custom
 * `role="listbox"` popup), so it looks and behaves identically everywhere and can
 * be themed with tokens (a native `<select>`'s popup can't). It shares the a11y
 * pattern of `Combobox` (the searchable listbox), minus the text filter.
 *
 * NOT for: searchable / very long / multi-select lists (use `Combobox`), free
 * text (`Input`), or boolean/one-of controls (checkbox/radio/toggle).
 *
 * Layer: primitive. Spec: `docs/ui-audit/04-component-catalogue.md` › Select · Combobox.
 * Prop names follow the shared vocabulary in `../types` and match the previous
 * native Select EXACTLY (`value`/`onChange`, `size`, `invalid`, `disabled`,
 * `width`, `className`) so no call site changes: callers still author
 * `<option>` / `<optgroup>` children (dynamic `.map()`s, `${a} · ${b}` labels,
 * placeholder rows). Those children are parsed into the custom listbox — the
 * authoring model is unchanged, only the rendering is now custom.
 *
 * Controlled only: `value` + `onChange(value)` are required; `onChange` gets the
 * string value (the shared `ChangeHandler<string>` contract).
 *
 * Accessibility (built in — the select-only combobox ARIA pattern):
 *   - Trigger is `role="combobox"` `aria-haspopup="listbox"` `aria-expanded`
 *     `aria-controls`, with `aria-activedescendant` tracking the highlighted
 *     option while open; the popup is `role="listbox"`, each row `role="option"`
 *     with `aria-selected`. `<optgroup>` labels render as presentational
 *     separator rows (no call site uses optgroups today; add real `role="group"`
 *     if grouped options ever appear).
 *   - Full keyboard: Up/Down/Home/End move, Enter/Space select, Esc closes and
 *     restores focus to the trigger, type-ahead jumps by first letter; disabled
 *     options are skipped. Click-outside closes.
 *   - `focus-visible` shows a token focus ring (never removed). `invalid` sets
 *     `aria-invalid` + the danger border/ring. The caller supplies the label via
 *     `FormField`/`aria-label` (Select renders no label of its own — same as before).
 *   - A hidden input mirrors `name`/`value` so the control still participates in
 *     native form submission when a `name` is given.
 *
 * Tokens only: color/radius/spacing/type/motion resolve to tokens. No raw hex/px.
 *
 * Escape hatch: `className` merges onto the root wrapper `<div>`.
 */
import React, { useEffect, useId, useMemo, useRef, useState } from 'react';
import Icon from './Icon';
import type {
  ChangeHandler,
  DisableableProps,
  InvalidatableProps,
  RootClassNameProps,
  Size,
  Width,
} from '../types';

interface OptionItem {
  value: string;
  label: React.ReactNode;
  /** Plain-text label for type-ahead + the trigger display. */
  text: string;
  disabled: boolean;
  /** Group label when the option came from an `<optgroup>`. */
  group?: string;
}

/**
 * Data-driven option, an alternative to authoring `<option>` children. Use it
 * when the caller can't express options as literal `<option>` elements — e.g.
 * labels resolved from data or fetches, where a per-option wrapper component
 * would otherwise be needed (the custom listbox can't parse component children,
 * only literal `<option>`/`<optgroup>`). See CommandPalette/TaskChainOverview.
 */
export interface SelectOption {
  value: string;
  /** Rich label; falls back to `text`, then `value`. */
  label?: React.ReactNode;
  /** Plain-text label for type-ahead + trigger display; falls back to a text
   *  extraction of `label`, then `value`. */
  text?: string;
  disabled?: boolean;
  /** Optional group heading (renders a presentational separator, like optgroup). */
  group?: string;
}

/** Normalize the `options` data prop into internal OptionItems. */
function normalizeOptions(options: SelectOption[]): OptionItem[] {
  return options.map((o) => {
    const label = o.label ?? o.text ?? o.value;
    return {
      value: String(o.value ?? ''),
      label,
      text: o.text ?? nodeText(label),
      disabled: Boolean(o.disabled),
      group: o.group,
    };
  });
}

/** Best-effort plain text of an option's children (for type-ahead + trigger). */
function nodeText(node: React.ReactNode): string {
  if (node == null || node === false || node === true) return '';
  if (typeof node === 'string' || typeof node === 'number') return String(node);
  if (Array.isArray(node)) return node.map(nodeText).join('');
  if (React.isValidElement(node)) return nodeText((node.props as { children?: React.ReactNode }).children);
  return '';
}

/** Flatten `<option>` / `<optgroup>` children into a list of option items. */
function parseOptions(children: React.ReactNode): OptionItem[] {
  const items: OptionItem[] = [];
  React.Children.forEach(children, (child) => {
    if (!React.isValidElement(child)) return;
    if (child.type === 'optgroup') {
      const groupProps = child.props as { label?: string; children?: React.ReactNode };
      React.Children.forEach(groupProps.children, (opt) => {
        if (!React.isValidElement(opt) || opt.type !== 'option') return;
        const p = opt.props as { value?: string; children?: React.ReactNode; disabled?: boolean };
        items.push({
          value: String(p.value ?? ''),
          label: p.children,
          text: nodeText(p.children),
          disabled: Boolean(p.disabled),
          group: groupProps.label,
        });
      });
      return;
    }
    if (child.type === 'option') {
      const p = child.props as { value?: string; children?: React.ReactNode; disabled?: boolean };
      items.push({
        value: String(p.value ?? ''),
        label: p.children,
        text: nodeText(p.children),
        disabled: Boolean(p.disabled),
      });
    }
  });
  return items;
}

const TRIGGER_BASE =
  'flex w-full items-center justify-between gap-2 rounded-[var(--radius-md)] border bg-surface ' +
  'text-left text-primary transition duration-fast outline-none cursor-pointer ' +
  'focus-visible:outline-none disabled:opacity-50 disabled:cursor-not-allowed';

const SIZE_CLASSES: Record<Size, string> = {
  sm: 'py-1 pl-2.5 pr-2 text-[length:var(--text-body-sm-size)]',
  md: 'py-2 pl-3 pr-2.5 text-[length:var(--text-body-size)]',
  lg: 'py-2.5 pl-3.5 pr-2.5 text-[length:var(--text-body-size)]',
};

const VALID_CLASSES = 'border-subtle focus-visible:border-accent focus-visible:shadow-focus';
const INVALID_CLASSES = 'border-danger focus-visible:border-danger focus-visible:shadow-focus-danger';

export interface SelectProps
  extends Omit<
      React.HTMLAttributes<HTMLButtonElement>,
      'onChange' | 'className' | 'children'
    >,
    DisableableProps,
    InvalidatableProps,
    RootClassNameProps {
  /** Controlled value. */
  value: string;
  /** Fired with the new string value. */
  onChange: ChangeHandler<string>;
  /**
   * The `<option>` / `<optgroup>` elements to choose from. Optional when
   * `options` (the data prop) is supplied instead; provide exactly one.
   */
  children?: React.ReactNode;
  /**
   * Data-driven options, an alternative to `<option>` children — for labels that
   * come from data/fetches and can't be authored as literal `<option>`s. When
   * present, it takes precedence over `children`.
   */
  options?: SelectOption[];
  /** Maps to spacing + type tokens. Default `md`. */
  size?: Size;
  /** `full` = stretches to the container. Default `content`. */
  width?: Width;
  /** Placeholder shown when the value matches no option. */
  placeholder?: string;
  /** Optional form field name (mirrored to a hidden input for form submission). */
  name?: string;
}

export const Select = React.forwardRef<HTMLButtonElement, SelectProps>(function Select(
  {
    value,
    onChange,
    children,
    options: optionsProp,
    size = 'md',
    width = 'content',
    invalid = false,
    disabled = false,
    placeholder,
    name,
    className,
    ...rest
  },
  ref,
) {
  const options = useMemo(
    () => (optionsProp ? normalizeOptions(optionsProp) : parseOptions(children)),
    [optionsProp, children],
  );
  const enabledIndexes = useMemo(
    () => options.map((o, i) => (o.disabled ? -1 : i)).filter((i) => i >= 0),
    [options],
  );
  const selectedIndex = options.findIndex((o) => o.value === value);
  const selected = selectedIndex >= 0 ? options[selectedIndex] : null;

  const [open, setOpen] = useState(false);
  const [activeIndex, setActiveIndex] = useState(selectedIndex >= 0 ? selectedIndex : enabledIndexes[0] ?? 0);
  const rootRef = useRef<HTMLDivElement | null>(null);
  const buttonRef = useRef<HTMLButtonElement | null>(null);
  const listboxRef = useRef<HTMLUListElement | null>(null);
  const typeahead = useRef<{ str: string; at: number }>({ str: '', at: 0 });

  const baseId = useId();
  const listboxId = `${baseId}-listbox`;
  const optionDomId = (index: number) => `${baseId}-opt-${index}`;

  // Merge the forwarded ref with the internal button ref.
  const setButtonRef = (node: HTMLButtonElement | null) => {
    buttonRef.current = node;
    if (typeof ref === 'function') ref(node);
    else if (ref) (ref as React.MutableRefObject<HTMLButtonElement | null>).current = node;
  };

  function openList(toIndex?: number) {
    if (disabled) return;
    setActiveIndex(toIndex ?? (selectedIndex >= 0 ? selectedIndex : enabledIndexes[0] ?? 0));
    setOpen(true);
  }

  function closeList(restoreFocus = true) {
    setOpen(false);
    if (restoreFocus) buttonRef.current?.focus();
  }

  function commit(index: number) {
    const opt = options[index];
    if (!opt || opt.disabled) return;
    onChange(opt.value);
    closeList();
  }

  function moveActive(delta: number) {
    if (enabledIndexes.length === 0) return;
    const pos = enabledIndexes.indexOf(activeIndex);
    const nextPos = pos < 0
      ? (delta > 0 ? 0 : enabledIndexes.length - 1)
      : Math.min(enabledIndexes.length - 1, Math.max(0, pos + delta));
    setActiveIndex(enabledIndexes[nextPos]);
  }

  function onTypeahead(char: string) {
    const now = Date.now();
    typeahead.current.str = now - typeahead.current.at > 600 ? char : typeahead.current.str + char;
    typeahead.current.at = now;
    const needle = typeahead.current.str.toLowerCase();
    const match = options.findIndex((o) => !o.disabled && o.text.toLowerCase().startsWith(needle));
    if (match >= 0) {
      setActiveIndex(match);
      if (!open) commit(match);
    }
  }

  function onKeyDown(event: React.KeyboardEvent) {
    if (disabled) return;
    const key = event.key;
    if (!open) {
      if (key === 'ArrowDown' || key === 'ArrowUp' || key === 'Enter' || key === ' ') {
        event.preventDefault();
        openList();
      } else if (key.length === 1 && !event.metaKey && !event.ctrlKey && !event.altKey) {
        onTypeahead(key);
      }
      return;
    }
    switch (key) {
      case 'ArrowDown':
        event.preventDefault();
        moveActive(1);
        break;
      case 'ArrowUp':
        event.preventDefault();
        moveActive(-1);
        break;
      case 'Home':
        event.preventDefault();
        setActiveIndex(enabledIndexes[0] ?? 0);
        break;
      case 'End':
        event.preventDefault();
        setActiveIndex(enabledIndexes[enabledIndexes.length - 1] ?? 0);
        break;
      case 'Enter':
      case ' ':
        event.preventDefault();
        commit(activeIndex);
        break;
      case 'Escape':
        event.preventDefault();
        closeList();
        break;
      case 'Tab':
        closeList(false);
        break;
      default:
        if (key.length === 1 && !event.metaKey && !event.ctrlKey && !event.altKey) onTypeahead(key);
    }
  }

  // Close on outside pointer-down.
  useEffect(() => {
    if (!open) return;
    const onDown = (e: MouseEvent) => {
      if (rootRef.current && !rootRef.current.contains(e.target as Node)) setOpen(false);
    };
    document.addEventListener('mousedown', onDown);
    return () => document.removeEventListener('mousedown', onDown);
  }, [open]);

  // Keep the active option scrolled into view.
  useEffect(() => {
    if (!open) return;
    const el = listboxRef.current?.querySelector<HTMLElement>(`#${CSS.escape(optionDomId(activeIndex))}`);
    el?.scrollIntoView({ block: 'nearest' });
  }, [open, activeIndex]);

  const triggerClassName = [
    TRIGGER_BASE,
    SIZE_CLASSES[size],
    invalid ? INVALID_CLASSES : VALID_CLASSES,
  ]
    .join(' ')
    .replace(/\s+/g, ' ')
    .trim();

  const wrapperClassName = [
    'relative inline-block',
    width === 'full' ? 'w-full' : '',
    className ?? '',
  ]
    .filter(Boolean)
    .join(' ')
    .replace(/\s+/g, ' ')
    .trim();

  // Render options as a flat, valid listbox: each option is a direct <li> child;
  // an <optgroup> label becomes a presentational separator row before its group.
  const rows: React.ReactNode[] = [];
  let lastGroup: string | undefined;
  options.forEach((opt, index) => {
    if (opt.group && opt.group !== lastGroup) {
      rows.push(
        <li
          key={`grp-${index}`}
          role="presentation"
          className="px-3 pt-2 pb-1 text-[length:var(--text-caption-size)] uppercase tracking-wide text-faint"
        >
          {opt.group}
        </li>,
      );
    }
    lastGroup = opt.group;
    rows.push(renderOption(index));
  });

  function renderOption(index: number) {
    const opt = options[index];
    const isSelected = index === selectedIndex;
    const isActive = index === activeIndex;
    return (
      <li
        key={`${opt.value}-${index}`}
        id={optionDomId(index)}
        role="option"
        aria-selected={isSelected}
        aria-disabled={opt.disabled || undefined}
        onMouseEnter={() => !opt.disabled && setActiveIndex(index)}
        onMouseDown={(e) => e.preventDefault()}
        onClick={() => commit(index)}
        className={[
          'flex cursor-pointer items-center justify-between gap-2 px-3 py-1.5',
          'text-[length:var(--text-body-sm-size)]',
          opt.disabled ? 'cursor-not-allowed opacity-50' : '',
          isActive && !opt.disabled ? 'bg-surface-raised' : '',
          isSelected ? 'text-accent' : 'text-primary',
        ]
          .filter(Boolean)
          .join(' ')}
      >
        <span className="truncate">{opt.label}</span>
        {isSelected ? <Icon name="check" size="sm" className="text-accent" /> : null}
      </li>
    );
  }

  return (
    <div ref={rootRef} className={wrapperClassName}>
      <button
        {...rest}
        ref={setButtonRef}
        type="button"
        role="combobox"
        aria-haspopup="listbox"
        aria-expanded={open}
        aria-controls={open ? listboxId : undefined}
        aria-activedescendant={open ? optionDomId(activeIndex) : undefined}
        aria-invalid={invalid || undefined}
        disabled={disabled}
        onClick={() => (open ? closeList(false) : openList())}
        onKeyDown={onKeyDown}
        className={triggerClassName}
      >
        <span className={['block truncate', selected ? '' : 'text-muted'].join(' ')}>
          {selected ? selected.label : placeholder ?? ''}
        </span>
        <Icon name="chevron-down" size="sm" className="shrink-0 text-muted" />
      </button>

      {name ? <input type="hidden" name={name} value={value} /> : null}

      {open ? (
        <ul
          ref={listboxRef}
          id={listboxId}
          role="listbox"
          className="absolute left-0 right-0 z-dropdown mt-1 max-h-72 overflow-auto rounded-[var(--radius-md)] border border-subtle bg-surface-raised py-1 shadow-overlay"
        >
          {rows}
        </ul>
      ) : null}
    </div>
  );
});

export default Select;
