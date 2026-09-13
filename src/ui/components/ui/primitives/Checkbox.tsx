/**
 * Checkbox — the one boolean form-selection control.
 * ------------------------------------------------------------------
 * Purpose: a single primitive for a form checkbox, folding the inline
 * `<input type="checkbox">` recipes scattered across the app (the EL-028 cluster
 * in `docs/ui-audit/04-component-catalogue.md` › Checkbox · Radio · Toggle) into
 * one token-driven box. Every one of those recipes was some flavour of
 * `h-4 w-4 rounded border-zinc-700 bg-black/40 text-sky-500 focus:ring-0` — the
 * bare `focus:ring-0` being the accessibility defect this fixes (a checkbox with
 * no visible focus state).
 *
 * NOT for: an immediate on/off setting (use `Toggle`), a one-of-many choice (use
 * `Radio`), or free-text / option-list entry (`Input` / `Select`).
 *
 * Layer: primitive. Spec: `docs/ui-audit/04-component-catalogue.md` › Checkbox · Radio · Toggle.
 * Prop names follow the shared vocabulary in `../types` (`checked`/`onChange`,
 * `size`, `invalid`, `disabled`, `className`). Native `<input>` attributes
 * (`id`, `name`, `required`, `aria-*`, `data-*`, `ref`, …) pass straight through
 * via `rest`.
 *
 * Controlled only: `checked` + `onChange(checked)` are required. `onChange`
 * receives the boolean state (not the DOM event) — the shared
 * `ChangeHandler<boolean>` contract — so call sites read `onChange={setSel}`,
 * never `e.target.checked`.
 *
 * Label: pass `label` (or `children`) for the clickable text — the component then
 * wraps the box + text in a `<label>`, so clicking the text toggles the box. With
 * no label the component renders the box alone; associate it with an external
 * `<label htmlFor>` / `FormField`, or a wrapping `<label>` (both toggle the box
 * natively). `aria-label` (via `rest`) covers the box-only case with no visible
 * text.
 *
 * Accessibility (built in, not a prop):
 *   - Renders a real `<input type="checkbox">`; native Space toggle and label
 *     association are preserved.
 *   - `focus-visible` shows a token focus ring (`shadow-focus`) — never removed,
 *     and never the bare `focus:ring-0` this replaces.
 *   - `invalid` sets `aria-invalid` and switches the border + ring to the danger
 *     token.
 *
 * Tokens only: colour/radius/spacing/type/motion all resolve to tokens
 * (`src/ui/tokens.css` / the Tailwind token aliases). No raw hex or px.
 *
 * Escape hatch: `className` merges onto the root element only (the `<label>` when
 * labelled, else the box wrapper `<span>`) — an escape hatch with a cost (it can
 * break the token guarantees), not a styling API.
 */
import React from 'react';
import type {
  ChangeHandler,
  DisableableProps,
  InvalidatableProps,
  RootClassNameProps,
  Size,
} from '../types';

/** Box dimensions per size. `md` mirrors the `h-4 w-4` the inline recipes used. */
const BOX_SIZE: Record<Size, string> = {
  sm: 'h-3.5 w-3.5',
  md: 'h-4 w-4',
  lg: 'h-5 w-5',
};

/** Label type role per size (mirrors the sibling text-entry primitives). */
const LABEL_SIZE: Record<Size, string> = {
  sm: 'text-[length:var(--text-body-sm-size)]',
  md: 'text-[length:var(--text-body-sm-size)]',
  lg: 'text-[length:var(--text-body-size)]',
};

const BOX_BASE =
  'peer appearance-none shrink-0 rounded-[var(--radius-sm)] border bg-surface ' +
  'transition duration-fast outline-none checked:bg-accent ' +
  'focus-visible:outline-none disabled:opacity-50 disabled:cursor-not-allowed';

const VALID_CLASSES = 'border-subtle checked:border-accent focus-visible:shadow-focus';
const INVALID_CLASSES = 'border-danger checked:border-danger focus-visible:shadow-focus-danger';

export interface CheckboxProps
  extends Omit<
      React.InputHTMLAttributes<HTMLInputElement>,
      'checked' | 'onChange' | 'size' | 'type' | 'className' | 'children'
    >,
    DisableableProps,
    InvalidatableProps,
    RootClassNameProps {
  /** Controlled checked state. */
  checked: boolean;
  /** Fired with the new boolean state (not the DOM event). */
  onChange: ChangeHandler<boolean>;
  /** Clickable label text. Same meaning as `children`; use either. */
  label?: React.ReactNode;
  /** Clickable label text (alternative to `label`). */
  children?: React.ReactNode;
  /** Maps to spacing + type tokens. Default `md`. */
  size?: Size;
}

export const Checkbox = React.forwardRef<HTMLInputElement, CheckboxProps>(function Checkbox(
  { checked, onChange, label, children, size = 'md', invalid = false, disabled, className, ...rest },
  ref,
) {
  const boxClassName = [BOX_BASE, BOX_SIZE[size], invalid ? INVALID_CLASSES : VALID_CLASSES]
    .join(' ')
    .replace(/\s+/g, ' ')
    .trim();

  const box = (
    <span className="relative inline-flex shrink-0">
      <input
        ref={ref}
        type="checkbox"
        checked={checked}
        onChange={(event) => onChange(event.target.checked)}
        disabled={disabled}
        aria-invalid={invalid || undefined}
        className={boxClassName}
        {...rest}
      />
      <svg
        aria-hidden="true"
        viewBox="0 0 16 16"
        fill="none"
        className="pointer-events-none absolute inset-0 m-auto opacity-0 text-accent-fg peer-checked:opacity-100"
      >
        <path
          d="M13 4.5 6.5 11.5 3 8"
          stroke="currentColor"
          strokeWidth="2"
          strokeLinecap="round"
          strokeLinejoin="round"
        />
      </svg>
    </span>
  );

  const text = label ?? children;

  if (text === undefined || text === null || text === false) {
    // Box only: associate via an external `<label>` / `FormField` / `aria-label`.
    return React.cloneElement(box, {
      className: ['relative inline-flex shrink-0', className ?? ''].filter(Boolean).join(' ').trim(),
    });
  }

  const labelClassName = [
    'inline-flex items-center gap-2 text-primary',
    LABEL_SIZE[size],
    disabled ? 'cursor-not-allowed opacity-50' : 'cursor-pointer',
    className ?? '',
  ]
    .filter(Boolean)
    .join(' ')
    .replace(/\s+/g, ' ')
    .trim();

  return (
    <label className={labelClassName}>
      {box}
      <span>{text}</span>
    </label>
  );
});

export default Checkbox;
