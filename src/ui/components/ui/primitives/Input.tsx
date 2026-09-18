/**
 * Input — the one single-line free-text field.
 * ------------------------------------------------------------------
 * Purpose: a single primitive for single-line text entry, folding the ~140
 * inline `<input>` recipes scattered across the app (see
 * `docs/ui-audit/00-findings-memo.md` and the EL-020..EL-024 cluster) into one
 * token-driven field. Every one of those recipes was some flavour of
 * `rounded border border-subtle bg-surface px-3 py-2 text-sm outline-none focus:border-accent`;
 * this replaces the whole family — including the bare `outline-none` that left
 * fields with no visible focus state.
 *
 * NOT for: choosing from a known option set (use `Select`/`Combobox`), boolean
 * or one-of controls (checkbox/radio/toggle), file/color/range pickers, or a
 * rich text editor. Multi-line entry is `Textarea` (a sibling primitive), not a
 * `type` of this one.
 *
 * Layer: primitive. Spec: `docs/ui-audit/04-component-catalogue.md` › Input.
 * Prop names follow the shared vocabulary in `../types` (`value`/`onChange`,
 * `size`, `invalid`, `disabled`/`readOnly`, `leading`/`trailing`, `width`,
 * `className`).
 *
 * Controlled only: `value` + `onChange(value)` are required. `onChange` receives
 * the string value (not the DOM event) — the shared `ChangeHandler<string>`
 * contract — so call sites read `onChange={setName}`, never `e.target.value`.
 *
 * Accessibility (built in, not a prop):
 *   - Renders a real `<input>`; native typing/selection behaviour is preserved.
 *   - `focus-visible` shows a token focus ring (`shadow-focus`) — never removed,
 *     and never the bare `outline-none` this replaces.
 *   - `invalid` sets `aria-invalid` and switches the border + ring to the danger
 *     token.
 *   - The Input does NOT render its own label. The caller must associate one —
 *     via `FormField` (`htmlFor`/`id`) or an explicit `aria-label` (passed
 *     through `rest`). `placeholder` is never a label. This label contract is
 *     `FormField`'s job in a later task; until then callers supply the label.
 *
 * Tokens only: colour/radius/spacing/type/motion all resolve to tokens
 * (`src/ui/tokens.css` / the Tailwind token aliases). No raw hex or px.
 *
 * Escape hatch: `className` merges onto the root element only (the `<input>`, or
 * the positioning wrapper when `leading`/`trailing` are used) — an escape hatch
 * with a cost (it can break the token guarantees), not a styling API.
 */
import React from 'react';
import type {
  ChangeHandler,
  ContentProps,
  DisableableProps,
  InvalidatableProps,
  ReadOnlyProps,
  RootClassNameProps,
  Size,
  Width,
} from '../types';

/** The text-entry `type`s this primitive owns. Non-text inputs are other primitives. */
export type InputType = 'text' | 'search' | 'email' | 'password' | 'number' | 'tel' | 'url';

const BASE =
  'block rounded-[var(--radius-md)] border bg-surface text-primary placeholder:text-faint ' +
  'transition duration-fast outline-none ' +
  'focus-visible:outline-none disabled:opacity-50 disabled:cursor-not-allowed';

/** Vertical padding + type role per size. Horizontal padding is applied separately (`PL`/`PR`). */
const SIZE_CLASSES: Record<Size, string> = {
  sm: 'py-1 text-[length:var(--text-body-sm-size)]',
  md: 'py-2 text-[length:var(--text-body-size)]',
  lg: 'py-2.5 text-[length:var(--text-body-size)]',
};

// Horizontal padding kept as explicit left/right classes (not `px-*`) so an
// adornment can override one side without a same-specificity padding clash.
const PL: Record<Size, string> = { sm: 'pl-2.5', md: 'pl-3', lg: 'pl-3.5' };
const PR: Record<Size, string> = { sm: 'pr-2.5', md: 'pr-3', lg: 'pr-3.5' };

const VALID_CLASSES = 'border-subtle focus-visible:border-accent focus-visible:shadow-focus';
const INVALID_CLASSES = 'border-danger focus-visible:border-danger focus-visible:shadow-focus-danger';

export interface InputProps
  extends Omit<
      React.InputHTMLAttributes<HTMLInputElement>,
      'value' | 'onChange' | 'size' | 'type' | 'className'
    >,
    DisableableProps,
    ReadOnlyProps,
    InvalidatableProps,
    RootClassNameProps,
    Pick<ContentProps, 'leading' | 'trailing'> {
  /** Controlled value. */
  value: string;
  /** Fired with the new string value (not the DOM event). */
  onChange: ChangeHandler<string>;
  /** Text-entry type. Default `text`. */
  type?: InputType;
  /** Maps to spacing + type tokens. Default `md`. */
  size?: Size;
  /** `full` = stretches to the container. Default `content`. */
  width?: Width;
}

export const Input = React.forwardRef<HTMLInputElement, InputProps>(function Input(
  {
    value,
    onChange,
    type = 'text',
    size = 'md',
    width = 'content',
    invalid = false,
    disabled,
    readOnly,
    leading,
    trailing,
    className,
    ...rest
  },
  ref,
) {
  const inputClassName = [
    BASE,
    SIZE_CLASSES[size],
    leading ? 'pl-9' : PL[size],
    trailing ? 'pr-9' : PR[size],
    invalid ? INVALID_CLASSES : VALID_CLASSES,
    width === 'full' ? 'w-full' : '',
    // With adornments the root is the wrapper, so `className` lands there instead.
    leading || trailing ? '' : className ?? '',
  ]
    .filter(Boolean)
    .join(' ')
    .replace(/\s+/g, ' ')
    .trim();

  const input = (
    <input
      ref={ref}
      type={type}
      value={value}
      onChange={(event) => onChange(event.target.value)}
      disabled={disabled}
      readOnly={readOnly}
      aria-invalid={invalid || undefined}
      className={inputClassName}
      {...rest}
    />
  );

  if (!leading && !trailing) return input;

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
      {leading ? (
        <span className="pointer-events-none absolute inset-y-0 left-0 flex items-center pl-2.5 text-muted">
          {leading}
        </span>
      ) : null}
      {input}
      {trailing ? (
        <span className="absolute inset-y-0 right-0 flex items-center pr-2.5 text-muted">
          {trailing}
        </span>
      ) : null}
    </span>
  );
});

export default Input;
