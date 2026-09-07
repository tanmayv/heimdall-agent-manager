// SearchableMultiSelect — the multi-select sibling of SearchableSelect.
//
// The memory targeting model is a LIST per dimension (empty = applies to all),
// so scope controls need to add/remove several ids. This reuses SearchableSelect's
// searchable, keyboard-navigable popover and row markup, but:
//   - takes values: string[] + onChange(next),
//   - toggles membership on row click (a check marks selected rows) without closing,
//   - renders selected values as removable chips in the control,
//   - shows an "All …" placeholder when the list is empty (the empty=all affordance).
//
// Backed by whatever options the caller passes; no data-fetching here.

import { useEffect, useMemo, useRef, useState } from 'react';
import Icon from './Icon';
import type { SearchableOption } from './SearchableSelect';

export default function SearchableMultiSelect({
  options,
  values,
  onChange,
  debugId,
  placeholder = 'Search…',
  allLabel = 'All',
  chipClassName = 'border-white/15 bg-white/[0.06] text-zinc-200',
  disabled = false,
  emptyLabel = 'No matches.',
  loading = false,
}: {
  options: SearchableOption[];
  values: string[];
  onChange: (values: string[]) => void;
  debugId: string;
  placeholder?: string;
  // Shown (muted) in the control when nothing is selected — the empty=all hint.
  allLabel?: string;
  // Full Tailwind class string for the selected chips (per-dimension coloring).
  chipClassName?: string;
  disabled?: boolean;
  emptyLabel?: string;
  loading?: boolean;
}) {
  const [open, setOpen] = useState(false);
  const [query, setQuery] = useState('');
  const [activeIndex, setActiveIndex] = useState(0);
  const rootRef = useRef<HTMLDivElement | null>(null);
  const inputRef = useRef<HTMLInputElement | null>(null);

  const selectedSet = useMemo(() => new Set(values), [values]);
  const optionById = useMemo(() => new Map(options.map((o) => [o.value, o])), [options]);

  const filtered = useMemo(() => {
    const q = query.trim().toLowerCase();
    if (!q) return options;
    return options.filter((o) => [o.title, o.tag, o.subtitle, o.id, o.keywords].filter(Boolean).join(' ').toLowerCase().includes(q));
  }, [options, query]);

  // Close on outside click / Escape.
  useEffect(() => {
    if (!open) return;
    const onPointer = (event: PointerEvent) => {
      if (!rootRef.current?.contains(event.target as Node)) setOpen(false);
    };
    document.addEventListener('pointerdown', onPointer);
    return () => document.removeEventListener('pointerdown', onPointer);
  }, [open]);

  useEffect(() => {
    if (open) {
      setQuery('');
      setActiveIndex(0);
      const t = window.setTimeout(() => inputRef.current?.focus(), 0);
      return () => window.clearTimeout(t);
    }
    return undefined;
  }, [open]);

  useEffect(() => { setActiveIndex(0); }, [query]);

  function toggle(value: string) {
    if (selectedSet.has(value)) onChange(values.filter((v) => v !== value));
    else onChange([...values, value]);
  }

  function remove(value: string) {
    onChange(values.filter((v) => v !== value));
  }

  function onKeyDown(event: React.KeyboardEvent) {
    if (event.key === 'ArrowDown') { event.preventDefault(); setActiveIndex((i) => Math.min(i + 1, filtered.length - 1)); }
    else if (event.key === 'ArrowUp') { event.preventDefault(); setActiveIndex((i) => Math.max(i - 1, 0)); }
    else if (event.key === 'Enter') { event.preventDefault(); const opt = filtered[activeIndex]; if (opt) toggle(opt.value); }
    else if (event.key === 'Escape') { event.preventDefault(); setOpen(false); }
  }

  return (
    <div ref={rootRef} className="relative">
      <div
        data-debug-id={debugId}
        className={`flex min-h-[2.5rem] w-full flex-wrap items-center gap-1.5 rounded-xl border border-white/10 bg-black/30 px-2 py-1.5 text-left ${disabled ? 'cursor-not-allowed opacity-50' : ''}`}
      >
        {values.length === 0 ? (
          <button
            type="button"
            data-debug-id={`${debugId}-all`}
            disabled={disabled}
            onClick={() => setOpen((o) => !o)}
            className="flex-1 truncate px-1 text-left text-sm text-zinc-500"
          >
            {allLabel}
          </button>
        ) : (
          values.map((value) => {
            const option = optionById.get(value);
            return (
              <span key={value} data-debug-id={`${debugId}-chip-${value}`} title={value} className={`inline-flex max-w-full items-center gap-1 rounded-full border px-2 py-0.5 text-[11.5px] ${chipClassName}`}>
                <span className="truncate">{option?.title || value}</span>
                {!disabled ? (
                  <button type="button" aria-label="Remove" data-debug-id={`${debugId}-chip-remove-${value}`} onClick={() => remove(value)} className="shrink-0 opacity-70 hover:opacity-100">
                    <Icon name="close" size={12} />
                  </button>
                ) : null}
              </span>
            );
          })
        )}
        <button
          type="button"
          aria-label="Add"
          data-debug-id={`${debugId}-add`}
          disabled={disabled}
          aria-haspopup="listbox"
          aria-expanded={open ? 'true' : 'false'}
          onClick={() => setOpen((o) => !o)}
          className="ml-auto grid h-6 w-6 shrink-0 place-items-center rounded-lg text-zinc-400 hover:bg-white/10 hover:text-zinc-100"
        >
          <Icon name={open ? 'chevron-down' : 'plus'} size={14} />
        </button>
      </div>

      {open ? (
        <div
          data-debug-id={`${debugId}-popover`}
          className="absolute left-0 right-0 z-50 mt-2 overflow-hidden rounded-2xl border border-white/15 bg-[#12151c] shadow-2xl shadow-black/70"
        >
          <div className="flex items-center gap-2 border-b border-white/10 px-3 py-2 text-zinc-500">
            <Icon name="search" size={15} />
            <input
              ref={inputRef}
              data-debug-id={`${debugId}-search-input`}
              value={query}
              onChange={(e) => setQuery(e.target.value)}
              onKeyDown={onKeyDown}
              placeholder={placeholder}
              className="w-full bg-transparent text-sm text-white outline-none placeholder:text-zinc-600"
            />
          </div>
          <div data-debug-id={`${debugId}-list`} role="listbox" aria-multiselectable="true" className="max-h-[240px] overflow-y-auto">
            {loading ? (
              <div data-debug-id={`${debugId}-loading`} className="px-3 py-4 text-center text-xs text-zinc-500">Loading…</div>
            ) : filtered.length === 0 ? (
              <div data-debug-id={`${debugId}-empty`} className="px-3 py-4 text-center text-xs text-zinc-500">{emptyLabel}</div>
            ) : filtered.map((option, index) => {
              const checked = selectedSet.has(option.value);
              return (
                <button
                  key={option.value}
                  type="button"
                  role="option"
                  aria-selected={checked}
                  data-debug-id={`${debugId}-option-${option.value}`}
                  onMouseEnter={() => setActiveIndex(index)}
                  onClick={() => toggle(option.value)}
                  className={`flex w-full items-center gap-3 border-b border-white/[0.04] px-3 py-2.5 text-left last:border-b-0 ${index === activeIndex ? 'bg-white/[0.06]' : ''} ${checked ? 'shadow-[inset_2px_0_0_theme(colors.sky.400)]' : ''}`}
                >
                  <span className={`grid h-5 w-5 shrink-0 place-items-center rounded-md border ${checked ? 'border-sky-400 bg-sky-400 text-black' : 'border-white/20 text-transparent'}`}>
                    <Icon name="check" size={12} />
                  </span>
                  <span className="min-w-0 flex-1">
                    <span className="flex items-center gap-2">
                      <span className="truncate text-[13.5px] font-semibold text-zinc-100">{option.title}</span>
                      {option.tag ? <span className="shrink-0 rounded-full bg-sky-400/15 px-2 py-0.5 text-[10px] font-bold text-sky-200">{option.tag}</span> : null}
                    </span>
                    {option.subtitle ? <span className="mt-0.5 block truncate text-[11.5px] text-zinc-400">{option.subtitle}</span> : null}
                    {option.id ? <span className="mt-0.5 block truncate font-mono text-[10.5px] text-zinc-600">{option.id}</span> : null}
                  </span>
                </button>
              );
            })}
          </div>
          <div className="flex items-center justify-between border-t border-white/10 px-3 py-1.5 text-[11px] text-zinc-500">
            <span data-debug-id={`${debugId}-count`}>{values.length} selected · {filtered.length} of {options.length}</span>
            {values.length > 0 ? (
              <button type="button" data-debug-id={`${debugId}-clear`} onClick={() => onChange([])} className="text-zinc-400 hover:text-zinc-100">Clear</button>
            ) : null}
          </div>
        </div>
      ) : null}
    </div>
  );
}
