/**
 * Select — the native single-choice dropdown for short, known option sets.
 * ------------------------------------------------------------------
 * Purpose: the native-`<select>` analog of `Input`, folding the inline
 * `<select>` recipes scattered across the app (the EL-025 cluster in
 * `docs/ui-audit/04-component-catalogue.md` › Select · Combobox) into one
 * token-driven field. Every one of those recipes was some flavour of
 * `rounded border border-white/10 bg-black/30 px-3 py-2 text-sm outline-none
 * focus:border-sky-400` wrapped around a stack of `<option>`s — plus the
 * inconsistent, un-themeable native dropdown arrow. This replaces the whole
 * family, including the bare `outline-none` that left fields with no visible
 * focus state, and paints a token-styled chevron over the native arrow.
 *
 * NOT for: searchable / long / multi-select lists (use `Combobox` — the custom
 * searchable listbox), free-text entry
 * (`Input`), or boolean / one-of controls (checkbox/radio/toggle). If the list
 * is long enough to want type-ahead beyond the browser's built-in first-letter
 * match, you want `Combobox`, not more props here.
 *
 * Layer: primitive. Spec: `docs/ui-audit/04-component-catalogue.md` › Select · Combobox.
 * Prop names follow the shared vocabulary in `../types` and match `Input`
 * exactly (`value`/`onChange`, `size`, `invalid`, `disabled`, `width`,
 * `className`). Native `<select>` attributes (`id`, `name`, `required`, `title`,
 * `aria-*`, `data-*`, `ref`, …) pass straight through via `rest`.
 *
 * Options via children, not a prop: callers write `<option>` (and `<optgroup>`)
 * elements as children — that is how every real call site is authored (dynamic
 * `.map()`s, concatenated labels like `${name} · ${status}`, numeric values,
 * placeholder rows). This keeps native `<select>` semantics intact and needs no
 * data-shape translation at the call site. A data-driven `options` prop was
 * intentionally NOT added because no call site uses that shape.
 *
 * Controlled only: `value` + `onChange(value)` are required. `onChange` receives
 * the string value (not the DOM event) — the shared `ChangeHandler<string>`
 * contract — so call sites read `onChange={setTier}`, never `e.target.value`.
 *
 * Accessibility (built in, not a prop):
 *   - Renders a real `<select>`; native keyboard, type-ahead, and mobile pickers
 *     are preserved. The painted chevron is `aria-hidden` and does not intercept
 *     pointer events, so clicks fall through to the select.
 *   - `focus-visible` shows a token focus ring (`shadow-focus`) — never removed,
 *     and never the bare `outline-none` this replaces.
 *   - `invalid` sets `aria-invalid` and switches the border + ring to the danger
 *     token.
 *   - The Select does NOT render its own label. The caller must associate one —
 *     via `FormField` (`htmlFor`/`id`) or an explicit `aria-label` (passed
 *     through `rest`). Same contract as `Input`.
 *
 * Tokens only: colour/radius/spacing/type/motion all resolve to tokens
 * (`src/ui/tokens.css` / the Tailwind token aliases). No raw hex or px.
 *
 * Escape hatch: `className` merges onto the root wrapper `<span>` only (the
 * chevron is positioned relative to it) — an escape hatch with a cost (it can
 * break the token guarantees), not a styling API.
 */
import React from 'react';
import type {
  ChangeHandler,
  DisableableProps,
  InvalidatableProps,
  RootClassNameProps,
  Size,
  Width,
} from '../types';

const BASE =
  'block appearance-none rounded-[var(--radius-md)] border bg-surface text-primary ' +
  'transition duration-fast outline-none cursor-pointer ' +
  'focus-visible:outline-none disabled:opacity-50 disabled:cursor-not-allowed';

/** Vertical padding + type role per size. Mirrors `Input`'s scale. */
const SIZE_CLASSES: Record<Size, string> = {
  sm: 'py-1 text-[length:var(--text-body-sm-size)]',
  md: 'py-2 text-[length:var(--text-body-size)]',
  lg: 'py-2.5 text-[length:var(--text-body-size)]',
};

/** Left padding per size (mirrors `Input`). Right padding always leaves room for the chevron. */
const PL: Record<Size, string> = { sm: 'pl-2.5', md: 'pl-3', lg: 'pl-3.5' };
const PR: Record<Size, string> = { sm: 'pr-8', md: 'pr-9', lg: 'pr-9' };

const VALID_CLASSES = 'border-subtle focus-visible:border-accent focus-visible:shadow-focus';
const INVALID_CLASSES = 'border-danger focus-visible:border-danger focus-visible:shadow-focus-danger';

export interface SelectProps
  extends Omit<
      React.SelectHTMLAttributes<HTMLSelectElement>,
      'value' | 'onChange' | 'size' | 'className' | 'multiple'
    >,
    DisableableProps,
    InvalidatableProps,
    RootClassNameProps {
  /** Controlled value. */
  value: string;
  /** Fired with the new string value (not the DOM event). */
  onChange: ChangeHandler<string>;
  /** The `<option>` / `<optgroup>` elements to choose from. */
  children: React.ReactNode;
  /** Maps to spacing + type tokens. Default `md`. */
  size?: Size;
  /** `full` = stretches to the container. Default `content`. */
  width?: Width;
}

export const Select = React.forwardRef<HTMLSelectElement, SelectProps>(function Select(
  {
    value,
    onChange,
    children,
    size = 'md',
    width = 'content',
    invalid = false,
    disabled,
    className,
    ...rest
  },
  ref,
) {
  const selectClassName = [
    BASE,
    SIZE_CLASSES[size],
    PL[size],
    PR[size],
    invalid ? INVALID_CLASSES : VALID_CLASSES,
    width === 'full' ? 'w-full' : '',
  ]
    .filter(Boolean)
    .join(' ')
    .replace(/\s+/g, ' ')
    .trim();

  const wrapperClassName = [
    'relative inline-flex items-center',
    width === 'full' ? 'w-full' : '',
    className ?? '',
  ]
    .filter(Boolean)
    .join(' ')
    .replace(/\s+/g, ' ')
    .trim();

  return (
    <span className={wrapperClassName}>
      <select
        ref={ref}
        value={value}
        onChange={(event) => onChange(event.target.value)}
        disabled={disabled}
        aria-invalid={invalid || undefined}
        className={selectClassName}
        {...rest}
      >
        {children}
      </select>
      <span
        aria-hidden="true"
        className="pointer-events-none absolute inset-y-0 right-0 flex items-center pr-2.5 text-muted"
      >
        <svg width="16" height="16" viewBox="0 0 16 16" fill="none" aria-hidden="true">
          <path
            d="M4 6l4 4 4-4"
            stroke="currentColor"
            strokeWidth="1.5"
            strokeLinecap="round"
            strokeLinejoin="round"
          />
        </svg>
      </span>
    </span>
  );
});

export default Select;
