/**
 * FormField — label + control + hint + error, correctly wired.
 * ------------------------------------------------------------------
 * Purpose: the one wrapper every form control lives in (EL-073). It fixes the
 * pervasive gap the audit found — sibling labels with no `htmlFor`, inline errors
 * with no `aria-describedby` — by generating the id and wiring the association
 * onto the control for you.
 *
 * NOT for: a bare control with its own external label, or a non-form layout.
 *
 * Layer: composite. Spec: `docs/ui-audit/04-component-catalogue.md` › FormField.
 * Prop names follow the shared vocabulary in `../types` (`hint`, `error`,
 * `required`, `className`).
 *
 * How it wires up: pass a single @ui form control as `children`. FormField
 * generates an `id` (or reuses the child's), renders a `<label htmlFor>`, and
 * clones the child to set `id`, `aria-describedby` (hint and/or error), and — when
 * `error` is set — `invalid` (which drives the control's error styling +
 * `aria-invalid`). `error` implies `invalid`; you do not set both.
 *
 * Accessibility (the whole point): the label is programmatically associated with
 * the control, and hint/error text is announced via `aria-describedby`. `required`
 * shows a marker and sets `aria-required` on the control.
 *
 * Tokens only: type/color/spacing via tokens. No raw values.
 *
 * Escape hatch: `className` merges onto the field's root `<div>`.
 */
import React from 'react';
import type { DescribableProps, RootClassNameProps } from '../types';

export interface FormFieldProps
  extends Pick<DescribableProps, 'hint'>,
    RootClassNameProps {
  /** The field label (required, associated with the control via `htmlFor`). */
  label: React.ReactNode;
  /** Error message. When set, implies `invalid` on the control + `aria-invalid`. */
  error?: React.ReactNode;
  /** Marks the field required (visible marker + `aria-required`). */
  required?: boolean;
  /** The form control (a single @ui field element: Input/Select/Textarea/…). */
  children: React.ReactElement;
  /** Optional explicit id (else one is generated). */
  id?: string;
}

export const FormField: React.FC<FormFieldProps> = ({
  label,
  hint,
  error,
  required = false,
  children,
  id,
  className,
}) => {
  const generatedId = React.useId();
  const childProps = children.props as Record<string, unknown>;
  const fieldId = id ?? (childProps.id as string | undefined) ?? generatedId;
  const hintId = hint ? `${fieldId}-hint` : undefined;
  const errorId = error ? `${fieldId}-error` : undefined;

  const describedBy = [childProps['aria-describedby'] as string | undefined, hintId, errorId]
    .filter(Boolean)
    .join(' ') || undefined;

  const control = React.cloneElement(children, {
    id: fieldId,
    'aria-describedby': describedBy,
    'aria-required': required || undefined,
    ...(error ? { invalid: true } : null),
  } as Record<string, unknown>);

  const rootClassName = ['flex flex-col gap-1', className].filter(Boolean).join(' ');

  return (
    <div className={rootClassName}>
      <label htmlFor={fieldId} className="text-[length:var(--text-label-size)] font-medium text-primary">
        {label}
        {required ? (
          <span className="text-danger" aria-hidden="true">
            {' '}
            *
          </span>
        ) : null}
      </label>
      {control}
      {hint && !error ? (
        <p id={hintId} className="text-[length:var(--text-caption-size)] text-muted">
          {hint}
        </p>
      ) : null}
      {error ? (
        <p id={errorId} className="text-[length:var(--text-caption-size)] text-danger">
          {error}
        </p>
      ) : null}
    </div>
  );
};

export default FormField;
