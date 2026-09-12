/**
 * Combobox — the one searchable option picker (single or multi choice).
 * ------------------------------------------------------------------
 * Purpose: a single primitive for choosing one — or, with `multiple`, several —
 * values from a known but LONG option set that needs type-ahead. It consolidates
 * the two hand-rolled widgets the app grew organically (`SearchableSelect`, the
 * single-select typeahead, and `SearchableMultiSelect`, its chip-based multi
 * sibling) into one token-driven, accessible listbox. See the EL-026 / EL-027 /
 * EL-031 cluster in `docs/ui-audit/04-component-catalogue.md` › Select · Combobox.
 *
 * NOT for: short, fully-known option sets (use the native-backed `Select` — it
 * keeps built-in keyboard + mobile pickers), free-text entry (`Input`), or
 * boolean / one-of controls (checkbox/radio/toggle). If the list is short enough
 * that type-ahead beyond the browser's first-letter match adds nothing, you want
 * `Select`, not this.
 *
 * Layer: primitive. Spec: `docs/ui-audit/04-component-catalogue.md` › Select · Combobox.
 * Prop names follow the shared vocabulary in `../types` (`value`/`onChange`,
 * `size`, `invalid`, `disabled`, `width`, `className`). `options` carries the rich
 * row shape the real call sites already build (title + tag + subtitle + id +
 * hidden keywords), so migrating from the two widgets needs no data reshaping.
 *
 * Single vs. multiple — one component, two shapes, selected by the `multiple`
 * boolean. The prop types are a discriminated union, so TypeScript enforces the
 * right pair at each call site:
 *   - default (single):  `value: string`   + `onChange: (value: string) => void`
 *   - `multiple`:        `value: string[]` + `onChange: (values: string[]) => void`
 * Single mode commits and closes on select; multiple mode toggles membership,
 * keeps the popup open, and renders the selection as removable chips.
 *
 * Controlled only: `value` + `onChange` are required and own the selection. The
 * open/typed/highlighted state is internal (uncontrolled) — callers never manage
 * the popup. This matches `Input`/`Select` (controlled value, internal UI state).
 *
 * Accessibility (built in, not a prop):
 *   - The popup search field is the ARIA 1.2 combobox: `role="combobox"`,
 *     `aria-expanded`, `aria-controls` → the listbox, `aria-autocomplete="list"`,
 *     and **`aria-activedescendant`** tracking the highlighted option (the gap in
 *     the widgets this replaces — highlight was visual only, invisible to SRs).
 *   - The popup is `role="listbox"` (`aria-multiselectable` when `multiple`); each
 *     row is `role="option"` with `aria-selected`. Rows are not focusable — focus
 *     stays on the combobox input and moves the active option via keyboard.
 *   - Keyboard: ↑/↓ move the active option, Home/End jump to first/last, Enter
 *     selects (single) or toggles (multiple), Esc closes and returns focus to the
 *     trigger, typing filters, and — in `multiple` — Backspace on an empty query
 *     removes the last chip. The trigger opens on Enter/Space/↓.
 *   - `focus-visible` shows a token focus ring on the trigger; chip remove buttons
 *     carry an `aria-label`.
 *   - The Combobox does NOT render its own field label. The caller must supply one
 *     (a visible label alongside it, or `aria-label` via `label`). Same contract
 *     as `Input`/`Select`.
 *
 * Tokens only: colour/radius/spacing/type/shadow/z all resolve to tokens
 * (`src/ui/tokens.css` / the Tailwind token aliases). No raw hex or px — the one
 * sanctioned exception is `chipClassName` (see below).
 *
 * Escape hatches:
 *   - `className` merges onto the root wrapper only — an escape hatch with a cost
 *     (it can break token guarantees), not a styling API.
 *   - `chipClassName` (multiple only) overrides the chip colour. It exists solely
 *     to keep the memory-scope selector's per-dimension chip colours during the
 *     @ui migration; it is a documented, temporary escape hatch that the future
 *     `ScopeField` pattern will absorb. Prefer NOT to use it.
 */
import React, { useEffect, useId, useMemo, useRef, useState } from 'react';
import Icon from '../../Icon';
import type {
  DisableableProps,
  InvalidatableProps,
  LoadableProps,
  RootClassNameProps,
  Size,
  Width,
} from '../types';

/**
 * A selectable row. The rich shape (title + optional tag/subtitle/id/keywords) is
 * carried verbatim from the consolidated widgets so call sites keep rendering
 * distinguishing metadata for near-identically-named options.
 */
export interface ComboboxOption {
  /** The stable value committed through `onChange`. */
  value: string;
  /** Primary line (and the avatar seed). */
  title: string;
  /** Short badge next to the title (e.g. role/status). */
  tag?: string;
  /** Secondary line (e.g. description or path). */
  subtitle?: string;
  /** Monospace trailing identifier (e.g. `agt_…` / `proj_…`). */
  id?: string;
  /** Extra text folded into the search index but never displayed. */
  keywords?: string;
}

interface ComboboxBaseProps
  extends DisableableProps,
    InvalidatableProps,
    LoadableProps,
    RootClassNameProps {
  /** The rows to choose from. */
  options: ComboboxOption[];
  /** Trigger placeholder shown when nothing is selected. Never a substitute for a label. */
  placeholder?: string;
  /** Popup search-field placeholder + its accessible name. Default `Search…`. */
  searchPlaceholder?: string;
  /** Shown when the filtered list is empty. Default `No matches.`. */
  emptyLabel?: string;
  /** Maps to spacing + type tokens. Default `md`. */
  size?: Size;
  /** `full` = stretches to the container. Default `full` (comboboxes are block controls). */
  width?: Width;
  /**
   * Optional debug/test hook. When set, the root carries `data-debug-id={debugId}`
   * and its parts derive stable ids (`…-search-input`, `…-option-<value>`, …),
   * matching the widgets this replaces so existing hooks keep working.
   */
  debugId?: string;
}

interface ComboboxSingleProps extends ComboboxBaseProps {
  multiple?: false;
  /** Controlled selected value (single mode). */
  value: string;
  /** Fired with the newly selected value; the popup then closes. */
  onChange: (value: string) => void;
}

interface ComboboxMultipleProps extends ComboboxBaseProps {
  multiple: true;
  /** Controlled selected values (multiple mode). */
  value: string[];
  /** Fired with the full next selection; the popup stays open. */
  onChange: (values: string[]) => void;
  /** Escape hatch: full class string for the selected chips. See the file header. */
  chipClassName?: string;
}

export type ComboboxProps = ComboboxSingleProps | ComboboxMultipleProps;

/** Join class fragments, dropping falsy ones and collapsing whitespace. */
function cx(...parts: Array<string | false | null | undefined>): string {
  return parts.filter(Boolean).join(' ').replace(/\s+/g, ' ').trim();
}

const CONTROL_BASE =
  'flex w-full items-center gap-2 rounded-[var(--radius-md)] border bg-surface text-left text-primary ' +
  'transition duration-fast';

/** Vertical padding + type role per size. Mirrors `Input`/`Select`. */
const SIZE_CLASSES: Record<Size, string> = {
  sm: 'px-2.5 py-1 text-[length:var(--text-body-sm-size)]',
  md: 'px-3 py-2 text-[length:var(--text-body-size)]',
  lg: 'px-3.5 py-2.5 text-[length:var(--text-body-size)]',
};

const VALID_CLASSES = 'border-subtle focus-within:border-accent focus-within:shadow-focus';
const INVALID_CLASSES = 'border-danger focus-within:border-danger focus-within:shadow-focus-danger';

export function Combobox(props: ComboboxProps) {
  const {
    options,
    value,
    onChange,
    placeholder,
    searchPlaceholder = 'Search…',
    emptyLabel = 'No matches.',
    size = 'md',
    width = 'full',
    invalid = false,
    disabled = false,
    loading = false,
    className,
    debugId,
  } = props;
  const multiple = props.multiple === true;
  const chipClassName = props.multiple === true ? props.chipClassName : undefined;

  const [open, setOpen] = useState(false);
  const [query, setQuery] = useState('');
  const [activeIndex, setActiveIndex] = useState(0);
  const rootRef = useRef<HTMLDivElement | null>(null);
  const inputRef = useRef<HTMLInputElement | null>(null);
  const triggerRef = useRef<HTMLButtonElement | null>(null);

  const baseId = useId();
  const listboxId = `${baseId}-listbox`;
  const optionDomId = (index: number) => `${baseId}-opt-${index}`;

  // Selected values as an array in both modes (single = 0 or 1 entries).
  const selectedValues = useMemo<string[]>(
    () => (multiple ? (value as string[]) : value ? [value as string] : []),
    [multiple, value],
  );
  const selectedSet = useMemo(() => new Set(selectedValues), [selectedValues]);
  const optionByValue = useMemo(
    () => new Map(options.map((option) => [option.value, option])),
    [options],
  );
  const selectedSingle = multiple ? null : optionByValue.get(value as string) ?? null;

  const filtered = useMemo(() => {
    const q = query.trim().toLowerCase();
    if (!q) return options;
    return options.filter((option) =>
      [option.title, option.tag, option.subtitle, option.id, option.keywords]
        .filter(Boolean)
        .join(' ')
        .toLowerCase()
        .includes(q),
    );
  }, [options, query]);

  // Close on outside pointerdown.
  useEffect(() => {
    if (!open) return undefined;
    const onPointer = (event: PointerEvent) => {
      if (!rootRef.current?.contains(event.target as Node)) setOpen(false);
    };
    document.addEventListener('pointerdown', onPointer);
    return () => document.removeEventListener('pointerdown', onPointer);
  }, [open]);

  // Reset the query + highlight and focus the search field when the popup opens.
  useEffect(() => {
    if (!open) return undefined;
    setQuery('');
    setActiveIndex(0);
    const t = window.setTimeout(() => inputRef.current?.focus(), 0);
    return () => window.clearTimeout(t);
  }, [open]);

  // Typing narrows the list; re-anchor the highlight to the top.
  useEffect(() => {
    setActiveIndex(0);
  }, [query]);

  // Keep the active option in view during keyboard navigation.
  useEffect(() => {
    if (!open) return;
    const el = document.getElementById(optionDomId(activeIndex));
    el?.scrollIntoView({ block: 'nearest' });
  }, [activeIndex, open]); // eslint-disable-line react-hooks/exhaustive-deps

  function closeAndRefocus() {
    setOpen(false);
    triggerRef.current?.focus();
  }

  function selectOption(option: ComboboxOption) {
    if (multiple) {
      const next = selectedSet.has(option.value)
        ? selectedValues.filter((v) => v !== option.value)
        : [...selectedValues, option.value];
      (onChange as (values: string[]) => void)(next);
    } else {
      (onChange as (value: string) => void)(option.value);
      setOpen(false);
    }
  }

  function removeValue(target: string) {
    if (!multiple) return;
    (onChange as (values: string[]) => void)(selectedValues.filter((v) => v !== target));
  }

  function onTriggerKeyDown(event: React.KeyboardEvent) {
    if (event.key === 'ArrowDown' || event.key === 'Enter' || event.key === ' ') {
      event.preventDefault();
      setOpen(true);
    }
  }

  function onInputKeyDown(event: React.KeyboardEvent) {
    switch (event.key) {
      case 'ArrowDown':
        event.preventDefault();
        setActiveIndex((i) => Math.min(i + 1, filtered.length - 1));
        break;
      case 'ArrowUp':
        event.preventDefault();
        setActiveIndex((i) => Math.max(i - 1, 0));
        break;
      case 'Home':
        event.preventDefault();
        setActiveIndex(0);
        break;
      case 'End':
        event.preventDefault();
        setActiveIndex(filtered.length - 1);
        break;
      case 'Enter': {
        event.preventDefault();
        const option = filtered[activeIndex];
        if (option) selectOption(option);
        break;
      }
      case 'Escape':
        event.preventDefault();
        closeAndRefocus();
        break;
      case 'Backspace':
        if (multiple && query === '' && selectedValues.length > 0) {
          event.preventDefault();
          removeValue(selectedValues[selectedValues.length - 1]);
        }
        break;
      default:
        break;
    }
  }

  const controlClassName = cx(
    CONTROL_BASE,
    SIZE_CLASSES[size],
    invalid ? INVALID_CLASSES : VALID_CLASSES,
    disabled ? 'cursor-not-allowed opacity-50' : '',
  );

  const activeDescendant =
    open && filtered.length > 0 && activeIndex >= 0 && activeIndex < filtered.length
      ? optionDomId(activeIndex)
      : undefined;

  const rootClassName = cx('relative', width === 'full' ? 'w-full' : 'inline-block', className ?? '');

  return (
    <div ref={rootRef} className={rootClassName}>
      {multiple ? (
        <div
          data-debug-id={debugId}
          className={cx(controlClassName, 'flex-wrap gap-1.5 focus-within:outline-none')}
        >
          {selectedValues.length === 0 ? (
            <button
              type="button"
              disabled={disabled}
              aria-haspopup="listbox"
              aria-expanded={open}
              aria-controls={open ? listboxId : undefined}
              aria-invalid={invalid || undefined}
              data-debug-id={debugId ? `${debugId}-all` : undefined}
              onClick={() => setOpen((o) => !o)}
              onKeyDown={onTriggerKeyDown}
              ref={triggerRef}
              className="flex-1 truncate rounded-[var(--radius-sm)] text-left text-muted outline-none focus-visible:shadow-focus disabled:cursor-not-allowed"
            >
              {placeholder ?? 'All'}
            </button>
          ) : (
            selectedValues.map((v) => {
              const option = optionByValue.get(v);
              return (
                <span
                  key={v}
                  title={v}
                  data-debug-id={debugId ? `${debugId}-chip-${v}` : undefined}
                  className={cx(
                    'inline-flex max-w-full items-center gap-1 rounded-[var(--radius-pill)] border px-2 py-0.5 text-[length:var(--text-caption-size)]',
                    chipClassName ?? 'border-subtle bg-surface-raised text-primary',
                  )}
                >
                  <span className="truncate">{option?.title || v}</span>
                  {!disabled ? (
                    <button
                      type="button"
                      aria-label={`Remove ${option?.title || v}`}
                      data-debug-id={debugId ? `${debugId}-chip-remove-${v}` : undefined}
                      onClick={() => removeValue(v)}
                      className="shrink-0 rounded-[var(--radius-sm)] opacity-70 outline-none hover:opacity-100 focus-visible:opacity-100 focus-visible:shadow-focus"
                    >
                      <Icon name="close" size={12} />
                    </button>
                  ) : null}
                </span>
              );
            })
          )}
          {selectedValues.length > 0 ? (
            <button
              type="button"
              aria-label="Add"
              disabled={disabled}
              aria-haspopup="listbox"
              aria-expanded={open}
              aria-controls={open ? listboxId : undefined}
              data-debug-id={debugId ? `${debugId}-add` : undefined}
              onClick={() => setOpen((o) => !o)}
              onKeyDown={onTriggerKeyDown}
              ref={triggerRef}
              className="ml-auto grid h-6 w-6 shrink-0 place-items-center rounded-[var(--radius-sm)] text-muted outline-none transition duration-fast hover:bg-surface-raised hover:text-primary focus-visible:shadow-focus disabled:cursor-not-allowed"
            >
              <Icon name={open ? 'chevron-down' : 'plus'} size={14} />
            </button>
          ) : null}
        </div>
      ) : (
        <button
          type="button"
          disabled={disabled}
          aria-haspopup="listbox"
          aria-expanded={open}
          aria-controls={open ? listboxId : undefined}
          aria-invalid={invalid || undefined}
          data-debug-id={debugId}
          onClick={() => setOpen((o) => !o)}
          onKeyDown={onTriggerKeyDown}
          ref={triggerRef}
          className={cx(controlClassName, 'outline-none focus-visible:border-accent focus-visible:shadow-focus')}
        >
          <span className="min-w-0 flex-1 truncate">
            {selectedSingle ? (
              <span className="flex min-w-0 items-center gap-2">
                <span className="truncate font-semibold">{selectedSingle.title}</span>
                {selectedSingle.tag ? (
                  <span className="shrink-0 rounded-[var(--radius-pill)] bg-surface-raised px-2 py-0.5 text-[length:var(--text-caption-size)] font-semibold text-accent">
                    {selectedSingle.tag}
                  </span>
                ) : null}
              </span>
            ) : (
              <span className="text-muted">{placeholder ?? 'Choose…'}</span>
            )}
          </span>
          <Icon name="chevron-down" size={16} className="shrink-0 text-muted" />
        </button>
      )}

      {open ? (
        <div
          data-debug-id={debugId ? `${debugId}-popover` : undefined}
          className="absolute left-0 right-0 z-dropdown mt-2 overflow-hidden rounded-[var(--radius-lg)] border border-subtle bg-surface-overlay shadow-overlay"
        >
          <div className="flex items-center gap-2 border-b border-subtle px-3 py-2 text-muted">
            <Icon name="search" size={15} />
            <input
              ref={inputRef}
              role="combobox"
              aria-expanded={open}
              aria-controls={listboxId}
              aria-autocomplete="list"
              aria-activedescendant={activeDescendant}
              aria-label={searchPlaceholder}
              data-debug-id={debugId ? `${debugId}-search-input` : undefined}
              value={query}
              onChange={(event) => setQuery(event.target.value)}
              onKeyDown={onInputKeyDown}
              placeholder={searchPlaceholder}
              className="w-full bg-transparent text-[length:var(--text-body-sm-size)] text-primary outline-none placeholder:text-faint"
            />
          </div>
          <div
            id={listboxId}
            role="listbox"
            aria-multiselectable={multiple || undefined}
            data-debug-id={debugId ? `${debugId}-list` : undefined}
            className="max-h-[240px] overflow-y-auto"
          >
            {loading ? (
              <div
                data-debug-id={debugId ? `${debugId}-loading` : undefined}
                className="px-3 py-4 text-center text-[length:var(--text-label-size)] text-muted"
              >
                Loading…
              </div>
            ) : filtered.length === 0 ? (
              <div
                data-debug-id={debugId ? `${debugId}-empty` : undefined}
                className="px-3 py-4 text-center text-[length:var(--text-label-size)] text-muted"
              >
                {emptyLabel}
              </div>
            ) : (
              filtered.map((option, index) => {
                const isSelected = selectedSet.has(option.value);
                const isActive = index === activeIndex;
                return (
                  <div
                    key={option.value}
                    id={optionDomId(index)}
                    role="option"
                    aria-selected={isSelected}
                    data-debug-id={debugId ? `${debugId}-option-${option.value}` : undefined}
                    onMouseEnter={() => setActiveIndex(index)}
                    onClick={() => selectOption(option)}
                    className={cx(
                      'flex w-full cursor-pointer items-center gap-3 border-b border-subtle px-3 py-2.5 text-left last:border-b-0',
                      isActive ? 'bg-surface-raised' : '',
                      isSelected ? 'shadow-[inset_2px_0_0_var(--color-accent)]' : '',
                    )}
                  >
                    {multiple ? (
                      <span
                        className={cx(
                          'grid h-5 w-5 shrink-0 place-items-center rounded-[var(--radius-sm)] border',
                          isSelected
                            ? 'border-accent bg-accent text-accent-fg'
                            : 'border-subtle text-transparent',
                        )}
                      >
                        <Icon name="check" size={12} />
                      </span>
                    ) : (
                      <span className="grid h-8 w-8 shrink-0 place-items-center rounded-[var(--radius-sm)] bg-accent text-[length:var(--text-label-size)] font-bold text-accent-fg">
                        {option.title.slice(0, 1).toUpperCase()}
                      </span>
                    )}
                    <span className="min-w-0 flex-1">
                      <span className="flex items-center gap-2">
                        <span className="truncate text-[length:var(--text-body-sm-size)] font-semibold text-primary">
                          {option.title}
                        </span>
                        {option.tag ? (
                          <span className="shrink-0 rounded-[var(--radius-pill)] bg-surface-raised px-2 py-0.5 text-[length:var(--text-caption-size)] font-semibold text-accent">
                            {option.tag}
                          </span>
                        ) : null}
                      </span>
                      {option.subtitle ? (
                        <span className="mt-0.5 block truncate text-[length:var(--text-caption-size)] text-muted">
                          {option.subtitle}
                        </span>
                      ) : null}
                      {option.id ? (
                        <span className="mt-0.5 block truncate font-mono text-[length:var(--text-caption-size)] text-faint">
                          {option.id}
                        </span>
                      ) : null}
                    </span>
                    {!multiple && isSelected ? (
                      <Icon name="arrow-right" size={14} className="shrink-0 text-accent" />
                    ) : null}
                  </div>
                );
              })
            )}
          </div>
          <div className="flex items-center justify-between border-t border-subtle px-3 py-1.5 text-[length:var(--text-caption-size)] text-muted">
            <span data-debug-id={debugId ? `${debugId}-count` : undefined}>
              {multiple
                ? `${selectedValues.length} selected · ${filtered.length} of ${options.length}`
                : `${filtered.length} of ${options.length}`}
            </span>
            {multiple && selectedValues.length > 0 ? (
              <button
                type="button"
                data-debug-id={debugId ? `${debugId}-clear` : undefined}
                onClick={() => (onChange as (values: string[]) => void)([])}
                className="rounded-[var(--radius-sm)] text-muted outline-none hover:text-primary focus-visible:shadow-focus"
              >
                Clear
              </button>
            ) : null}
          </div>
        </div>
      ) : null}
    </div>
  );
}

export default Combobox;
