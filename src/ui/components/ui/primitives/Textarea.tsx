/**
 * Textarea — the one multi-line free-text field.
 * ------------------------------------------------------------------
 * Purpose: the multi-line sibling of `Input`, folding the inline `<textarea>`
 * recipes scattered across the app (see the EL-024 cluster in
 * `docs/ui-audit/04-component-catalogue.md` › Input · Textarea) into one
 * token-driven field. Every one of those recipes was some flavour of
 * `w-full resize-y rounded-xl border border-white/10 bg-black/30 px-3 py-2 text-sm
 * outline-none focus:border-sky-400`; this replaces the whole family — including
 * the bare `outline-none` that left fields with no visible focus state.
 *
 * NOT for: single-line entry (use `Input`), choosing from a known option set
 * (`Select`/`Combobox`), or a rich text editor. If you need adornments, a code
 * editor, or per-key command handling beyond native `onKeyDown`, you want a
 * different component, not more props here.
 *
 * Layer: primitive. Spec: `docs/ui-audit/04-component-catalogue.md` › Input · Textarea.
 * Prop names follow the shared vocabulary in `../types` and match `Input` exactly
 * (`value`/`onChange`, `size`, `invalid`, `disabled`/`readOnly`, `width`,
 * `className`). Native `<textarea>` attributes (`rows`, `placeholder`, `id`,
 * `aria-*`, `data-*`, `onKeyDown`, `ref`, …) pass straight through via `rest`.
 *
 * Controlled only: `value` + `onChange(value)` are required. `onChange` receives
 * the string value (not the DOM event) — the shared `ChangeHandler<string>`
 * contract — so call sites read `onChange={setBody}`, never `e.target.value`.
 *
 * Accessibility (built in, not a prop):
 *   - Renders a real `<textarea>`; native typing/selection behaviour is preserved.
 *   - `focus-visible` shows a token focus ring (`shadow-focus`) — never removed,
 *     and never the bare `outline-none` this replaces.
 *   - `invalid` sets `aria-invalid` and switches the border + ring to the danger
 *     token.
 *   - The Textarea does NOT render its own label. The caller must associate one —
 *     via `FormField` (`htmlFor`/`id`) or an explicit `aria-label` (passed
 *     through `rest`). `placeholder` is never a label. Same contract as `Input`.
 *
 * Resize: vertical-only (`resize-y`) is built in — the common, layout-safe
 * default. Horizontal resize is intentionally not offered (it breaks column
 * layouts); to pin a height, pass a height utility through `className`.
 *
 * Tokens only: colour/radius/spacing/type/motion all resolve to tokens
 * (`src/ui/tokens.css` / the Tailwind token aliases). No raw hex or px.
 *
 * Escape hatch: `className` merges onto the root `<textarea>` only — an escape
 * hatch with a cost (it can break the token guarantees), not a styling API.
 */
import React from 'react';
import type {
  ChangeHandler,
  DisableableProps,
  InvalidatableProps,
  ReadOnlyProps,
  RootClassNameProps,
  Size,
  Width,
} from '../types';

const BASE =
  'block rounded-[var(--radius-md)] border bg-surface text-primary placeholder:text-faint ' +
  'transition duration-fast outline-none resize-y ' +
  'focus-visible:outline-none disabled:opacity-50 disabled:cursor-not-allowed';

/** Padding + type role per size. Mirrors `Input`'s scale. */
const SIZE_CLASSES: Record<Size, string> = {
  sm: 'px-2.5 py-1.5 text-[length:var(--text-body-sm-size)]',
  md: 'px-3 py-2 text-[length:var(--text-body-size)]',
  lg: 'px-3.5 py-2.5 text-[length:var(--text-body-size)]',
};

const VALID_CLASSES = 'border-subtle focus-visible:border-accent focus-visible:shadow-focus';
const INVALID_CLASSES = 'border-danger focus-visible:border-danger focus-visible:shadow-focus-danger';

export interface TextareaProps
  extends Omit<
      React.TextareaHTMLAttributes<HTMLTextAreaElement>,
      'value' | 'onChange' | 'className'
    >,
    DisableableProps,
    ReadOnlyProps,
    InvalidatableProps,
    RootClassNameProps {
  /** Controlled value. */
  value: string;
  /** Fired with the new string value (not the DOM event). */
  onChange: ChangeHandler<string>;
  /** Maps to spacing + type tokens. Default `md`. */
  size?: Size;
  /** `full` = stretches to the container. Default `content`. */
  width?: Width;
}

export const Textarea = React.forwardRef<HTMLTextAreaElement, TextareaProps>(function Textarea(
  {
    value,
    onChange,
    size = 'md',
    width = 'content',
    invalid = false,
    disabled,
    readOnly,
    className,
    ...rest
  },
  ref,
) {
  const textareaClassName = [
    BASE,
    SIZE_CLASSES[size],
    invalid ? INVALID_CLASSES : VALID_CLASSES,
    width === 'full' ? 'w-full' : '',
    className ?? '',
  ]
    .filter(Boolean)
    .join(' ')
    .replace(/\s+/g, ' ')
    .trim();

  return (
    <textarea
      ref={ref}
      value={value}
      onChange={(event) => onChange(event.target.value)}
      disabled={disabled}
      readOnly={readOnly}
      aria-invalid={invalid || undefined}
      className={textareaClassName}
      {...rest}
    />
  );
});

export default Textarea;
