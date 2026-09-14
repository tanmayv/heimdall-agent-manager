/**
 * Toggle — the switch for an immediate on/off setting.
 * ------------------------------------------------------------------
 * Purpose: one primitive for a switch control, folding the hand-rolled
 * `role="switch"` button and the sr-only-checkbox-styled-as-a-pill recipes
 * (the EL-019 / EL-030 cluster in
 * `docs/ui-audit/04-component-catalogue.md` › Checkbox · Radio · Toggle) into a
 * single token-driven switch. It renders a real `role="switch"` button with a
 * built-in focus ring — replacing the ad-hoc `bg-sky-400`/`bg-white/15` pills and
 * the `peer-focus:outline-none` variants that had no visible focus state.
 *
 * NOT for: a value submitted with a form (use `Checkbox` — a real
 * `<input type="checkbox">`), a one-of-many choice (`Radio`), or an action that
 * does something other than flip a persistent setting (`Button`). Use a Toggle
 * when flipping it takes effect immediately (a setting), a Checkbox when it is
 * one field in a form the user submits.
 *
 * Layer: primitive. Spec: `docs/ui-audit/04-component-catalogue.md` › Checkbox · Radio · Toggle.
 * Prop names follow the shared vocabulary in `../types` (`checked`/`onChange`,
 * `size`, `disabled`, `className`). Native `<button>` attributes — crucially the
 * accessible name (`aria-label` / `aria-labelledby`) plus `id`, `data-*`, `ref`,
 * … — pass straight through via `rest`.
 *
 * Controlled only: `checked` + `onChange(checked)` are required. `onChange`
 * receives the new boolean state (the component flips it for you), so call sites
 * read `onChange={setEnabled}`, never `onClick={() => setEnabled(!enabled)}`.
 *
 * Accessible name (required, via `rest`): a switch has no intrinsic text, so the
 * caller MUST supply one — `aria-label="Enable notifications"` for a standalone
 * switch, or `aria-labelledby={headingId}` when a visible heading names it (the
 * common layout: a label/description block on the left, the switch on the
 * right). There is deliberately no `label` prop — visible text is a sibling in
 * the caller's layout, not owned by the switch.
 *
 * Accessibility (built in, not a prop):
 *   - Renders `<button type="button" role="switch" aria-checked={checked}>`;
 *     native Space/Enter activation and tab order come for free.
 *   - `focus-visible` shows a token focus ring (`shadow-focus`) — never removed.
 *   - `disabled` dims the control, blocks the click, and drops it from tab order.
 *
 * Tokens only: colour/radius/spacing/type/motion all resolve to tokens
 * (`src/ui/tokens.css` / the Tailwind token aliases). No raw hex or px.
 *
 * Escape hatch: `className` merges onto the root `<button>` — an escape hatch
 * with a cost, not a styling API.
 */
import React from 'react';
import type {
  ChangeHandler,
  DisableableProps,
  RootClassNameProps,
  Size,
} from '../types';

/** Track dimensions per size. `md` mirrors the `h-6 w-11` the inline recipes used. */
const TRACK_SIZE: Record<Size, string> = {
  sm: 'h-5 w-9',
  md: 'h-6 w-11',
  lg: 'h-7 w-14',
};

/** Knob (thumb) dimensions per size. */
const KNOB_SIZE: Record<Size, string> = {
  sm: 'h-4 w-4',
  md: 'h-5 w-5',
  lg: 'h-6 w-6',
};

/** Knob travel when checked vs. resting inset (checked / unchecked). */
const KNOB_TRANSLATE: Record<Size, { on: string; off: string }> = {
  sm: { on: 'translate-x-4', off: 'translate-x-0.5' },
  md: { on: 'translate-x-5', off: 'translate-x-0.5' },
  lg: { on: 'translate-x-7', off: 'translate-x-0.5' },
};

const TRACK_BASE =
  'group relative inline-flex shrink-0 items-center rounded-pill border border-transparent ' +
  'transition-colors duration-fast outline-none ' +
  'focus-visible:shadow-focus disabled:opacity-50 disabled:cursor-not-allowed';

export interface ToggleProps
  extends Omit<
      React.ButtonHTMLAttributes<HTMLButtonElement>,
      'onChange' | 'type' | 'className' | 'children'
    >,
    DisableableProps,
    RootClassNameProps {
  /** Controlled on/off state. */
  checked: boolean;
  /** Fired with the new boolean state (the component flips it for you). */
  onChange: ChangeHandler<boolean>;
  /** Maps to spacing tokens. Default `md`. */
  size?: Size;
}

export const Toggle = React.forwardRef<HTMLButtonElement, ToggleProps>(function Toggle(
  { checked, onChange, size = 'md', disabled, className, ...rest },
  ref,
) {
  const trackClassName = [
    TRACK_BASE,
    TRACK_SIZE[size],
    checked ? 'bg-accent' : 'bg-strong',
    disabled ? '' : 'cursor-pointer',
    className ?? '',
  ]
    .filter(Boolean)
    .join(' ')
    .replace(/\s+/g, ' ')
    .trim();

  const knobClassName = [
    'pointer-events-none inline-block transform rounded-full bg-primary shadow transition-transform duration-fast',
    KNOB_SIZE[size],
    checked ? KNOB_TRANSLATE[size].on : KNOB_TRANSLATE[size].off,
  ].join(' ');

  return (
    <button
      ref={ref}
      type="button"
      role="switch"
      aria-checked={checked}
      disabled={disabled}
      onClick={() => onChange(!checked)}
      className={trackClassName}
      {...rest}
    >
      <span aria-hidden="true" className={knobClassName} />
    </button>
  );
});

export default Toggle;
