/**
 * Radio — the one one-of-many form-selection control.
 * ------------------------------------------------------------------
 * Purpose: a single primitive for a form radio button, folding the inline
 * `<input type="radio">` recipes (the EL-029 cluster in
 * `docs/ui-audit/04-component-catalogue.md` › Checkbox · Radio · Toggle) into one
 * token-driven control. Those recipes were bare native radios with no visible
 * focus state — the accessibility defect this fixes. Group members share a
 * `name`; the browser then enforces the single-selection + arrow-key roving that
 * radios guarantee.
 *
 * NOT for: a boolean on/off (use `Checkbox` for a form field, `Toggle` for an
 * immediate setting) or choosing from a long / searchable list (`Select` /
 * `Combobox`).
 *
 * Layer: primitive. Spec: `docs/ui-audit/04-component-catalogue.md` › Checkbox · Radio · Toggle.
 * Prop names follow the shared vocabulary in `../types` (`checked`/`onChange`,
 * `size`, `invalid`, `disabled`, `className`) and match `Checkbox` exactly. Native
 * `<input>` attributes (`name`, `value`, `required`, `aria-*`, `data-*`, `ref`, …)
 * pass straight through via `rest` — `name` is what groups radios together.
 *
 * Controlled only: `checked` + `onChange(checked)` are required. `onChange`
 * receives the boolean state (not the DOM event) — the shared
 * `ChangeHandler<boolean>` contract. For a radio, `onChange` fires with `true`
 * when this option becomes the selected one, so call sites read
 * `onChange={() => setValue(optionValue)}`.
 *
 * Label: pass `label` (or `children`) for the clickable text — the component then
 * wraps the dot + text in a `<label>`, so clicking the text selects the option.
 * With no label the component renders the dot alone; associate it with an
 * external `<label htmlFor>` / `FormField`, or a wrapping `<label>`, or an
 * `aria-label` (via `rest`).
 *
 * Accessibility (built in, not a prop):
 *   - Renders a real `<input type="radio">`; native single-selection, arrow-key
 *     roving, and label association are preserved.
 *   - `focus-visible` shows a token focus ring (`shadow-focus`) — never removed.
 *   - `invalid` sets `aria-invalid` and switches the border + ring to the danger
 *     token.
 *
 * Tokens only: colour/radius/spacing/type/motion all resolve to tokens
 * (`src/ui/tokens.css` / the Tailwind token aliases). No raw hex or px.
 *
 * Escape hatch: `className` merges onto the root element only (the `<label>` when
 * labelled, else the dot wrapper `<span>`) — an escape hatch with a cost, not a
 * styling API.
 */
import React from 'react';
import type {
  ChangeHandler,
  DisableableProps,
  InvalidatableProps,
  RootClassNameProps,
  Size,
} from '../types';

/** Control dimensions per size. `md` mirrors the `h-4 w-4` the inline recipes used. */
const DOT_SIZE: Record<Size, string> = {
  sm: 'h-3.5 w-3.5',
  md: 'h-4 w-4',
  lg: 'h-5 w-5',
};

/** Inner filled dot, shown when checked. */
const INNER_SIZE: Record<Size, string> = {
  sm: 'h-1.5 w-1.5',
  md: 'h-2 w-2',
  lg: 'h-2.5 w-2.5',
};

/** Label type role per size (mirrors `Checkbox`). */
const LABEL_SIZE: Record<Size, string> = {
  sm: 'text-[length:var(--text-body-sm-size)]',
  md: 'text-[length:var(--text-body-sm-size)]',
  lg: 'text-[length:var(--text-body-size)]',
};

const DOT_BASE =
  'peer appearance-none shrink-0 rounded-full border bg-surface ' +
  'transition duration-fast outline-none checked:bg-accent ' +
  'focus-visible:outline-none disabled:opacity-50 disabled:cursor-not-allowed';

const VALID_CLASSES = 'border-subtle checked:border-accent focus-visible:shadow-focus';
const INVALID_CLASSES = 'border-danger checked:border-danger focus-visible:shadow-focus-danger';

export interface RadioProps
  extends Omit<
      React.InputHTMLAttributes<HTMLInputElement>,
      'checked' | 'onChange' | 'size' | 'type' | 'className' | 'children'
    >,
    DisableableProps,
    InvalidatableProps,
    RootClassNameProps {
  /** Controlled checked state. Radios in a group share a `name` (via `rest`). */
  checked: boolean;
  /** Fired with the new boolean state (not the DOM event). Fires `true` on select. */
  onChange: ChangeHandler<boolean>;
  /** Clickable label text. Same meaning as `children`; use either. */
  label?: React.ReactNode;
  /** Clickable label text (alternative to `label`). */
  children?: React.ReactNode;
  /** Maps to spacing + type tokens. Default `md`. */
  size?: Size;
}

export const Radio = React.forwardRef<HTMLInputElement, RadioProps>(function Radio(
  { checked, onChange, label, children, size = 'md', invalid = false, disabled, className, ...rest },
  ref,
) {
  const dotClassName = [DOT_BASE, DOT_SIZE[size], invalid ? INVALID_CLASSES : VALID_CLASSES]
    .join(' ')
    .replace(/\s+/g, ' ')
    .trim();

  const control = (
    <span className="relative inline-flex shrink-0">
      <input
        ref={ref}
        type="radio"
        checked={checked}
        onChange={(event) => onChange(event.target.checked)}
        disabled={disabled}
        aria-invalid={invalid || undefined}
        className={dotClassName}
        {...rest}
      />
      <span
        aria-hidden="true"
        className={[
          'pointer-events-none absolute inset-0 m-auto rounded-full bg-accent-fg opacity-0 peer-checked:opacity-100',
          INNER_SIZE[size],
        ].join(' ')}
      />
    </span>
  );

  const text = label ?? children;

  if (text === undefined || text === null || text === false) {
    // Dot only: associate via an external `<label>` / `FormField` / `aria-label`.
    return React.cloneElement(control, {
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
      {control}
      <span>{text}</span>
    </label>
  );
});

export default Radio;
