// SearchableSelect — a scalable single-select for the conversations-first rework.
//
// Plain <select> dropdowns don't scale to 10–50 agents/projects and can't show a
// distinguishing description or id. This is a searchable, keyboard-navigable
// popover list where each row can render a title + subtitle + trailing id, so
// similar/identically-named options stay distinguishable.
//
// Backed by whatever data the caller passes; no data-fetching here.

import { useEffect, useMemo, useRef, useState } from 'react';
import Icon from './Icon';

export type SearchableOption = {
  value: string;
  title: string;
  // Short badge shown next to the title (e.g. role/template).
  tag?: string;
  // Secondary line (e.g. description or path).
  subtitle?: string;
  // Monospace trailing identifier (e.g. agt_… / proj_…).
  id?: string;
  // Extra text folded into the search index but not displayed.
  keywords?: string;
};

export default function SearchableSelect({
  options,
  value,
  onChange,
  debugId,
  placeholder = 'Search…',
  buttonPlaceholder = 'Choose…',
  disabled = false,
  emptyLabel = 'No matches.',
  loading = false,
}: {
  options: SearchableOption[];
  value: string;
  onChange: (value: string) => void;
  debugId: string;
  placeholder?: string;
  buttonPlaceholder?: string;
  disabled?: boolean;
  emptyLabel?: string;
  loading?: boolean;
}) {
  const [open, setOpen] = useState(false);
  const [query, setQuery] = useState('');
  const [activeIndex, setActiveIndex] = useState(0);
  const rootRef = useRef<HTMLDivElement | null>(null);
  const inputRef = useRef<HTMLInputElement | null>(null);

  const selected = useMemo(() => options.find((o) => o.value === value) || null, [options, value]);

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
      // Focus the search field once the popover mounts.
      const t = window.setTimeout(() => inputRef.current?.focus(), 0);
      return () => window.clearTimeout(t);
    }
    return undefined;
  }, [open]);

  useEffect(() => { setActiveIndex(0); }, [query]);

  function commit(option: SearchableOption) {
    onChange(option.value);
    setOpen(false);
  }

  function onKeyDown(event: React.KeyboardEvent) {
    if (event.key === 'ArrowDown') { event.preventDefault(); setActiveIndex((i) => Math.min(i + 1, filtered.length - 1)); }
    else if (event.key === 'ArrowUp') { event.preventDefault(); setActiveIndex((i) => Math.max(i - 1, 0)); }
    else if (event.key === 'Enter') { event.preventDefault(); const opt = filtered[activeIndex]; if (opt) commit(opt); }
    else if (event.key === 'Escape') { event.preventDefault(); setOpen(false); }
  }

  return (
    <div ref={rootRef} className="relative">
      <button
        type="button"
        data-debug-id={debugId}
        disabled={disabled}
        aria-haspopup="listbox"
        aria-expanded={open ? 'true' : 'false'}
        onClick={() => setOpen((o) => !o)}
        className="mt-2 flex w-full items-center gap-2 rounded-2xl border border-white/10 bg-black/30 px-3 py-3 text-left text-base text-white disabled:cursor-not-allowed disabled:opacity-50 sm:text-sm"
      >
        <span className="min-w-0 flex-1 truncate">
          {selected ? (
            <span className="flex min-w-0 items-center gap-2">
              <span className="truncate font-semibold">{selected.title}</span>
              {selected.tag ? <span className="shrink-0 rounded-full bg-sky-400/15 px-2 py-0.5 text-[10px] font-bold text-sky-200">{selected.tag}</span> : null}
            </span>
          ) : (
            <span className="text-zinc-500">{buttonPlaceholder}</span>
          )}
        </span>
        <Icon name="chevron-down" size={16} className="shrink-0 text-zinc-500" />
      </button>

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
          <div data-debug-id={`${debugId}-list`} role="listbox" className="max-h-[240px] overflow-y-auto">
            {loading ? (
              <div data-debug-id={`${debugId}-loading`} className="px-3 py-4 text-center text-xs text-zinc-500">Loading…</div>
            ) : filtered.length === 0 ? (
              <div data-debug-id={`${debugId}-empty`} className="px-3 py-4 text-center text-xs text-zinc-500">{emptyLabel}</div>
            ) : filtered.map((option, index) => (
              <button
                key={option.value}
                type="button"
                role="option"
                aria-selected={option.value === value}
                data-debug-id={`${debugId}-option-${option.value}`}
                onMouseEnter={() => setActiveIndex(index)}
                onClick={() => commit(option)}
                className={`flex w-full items-center gap-3 border-b border-white/[0.04] px-3 py-2.5 text-left last:border-b-0 ${index === activeIndex ? 'bg-white/[0.06]' : ''} ${option.value === value ? 'shadow-[inset_2px_0_0_theme(colors.sky.400)]' : ''}`}
              >
                <span className="grid h-8 w-8 shrink-0 place-items-center rounded-lg bg-gradient-to-br from-sky-400/80 to-violet-400/80 text-xs font-black text-black">{option.title.slice(0, 1).toUpperCase()}</span>
                <span className="min-w-0 flex-1">
                  <span className="flex items-center gap-2">
                    <span className="truncate text-[13.5px] font-semibold text-zinc-100">{option.title}</span>
                    {option.tag ? <span className="shrink-0 rounded-full bg-sky-400/15 px-2 py-0.5 text-[10px] font-bold text-sky-200">{option.tag}</span> : null}
                  </span>
                  {option.subtitle ? <span className="mt-0.5 block truncate text-[11.5px] text-zinc-400">{option.subtitle}</span> : null}
                  {option.id ? <span className="mt-0.5 block truncate font-mono text-[10.5px] text-zinc-600">{option.id}</span> : null}
                </span>
                {option.value === value ? <Icon name="arrow-right" size={14} className="shrink-0 text-sky-300" /> : null}
              </button>
            ))}
          </div>
          <div data-debug-id={`${debugId}-count`} className="border-t border-white/10 px-3 py-1.5 text-[11px] text-zinc-500">{filtered.length} of {options.length}</div>
        </div>
      ) : null}
    </div>
  );
}
