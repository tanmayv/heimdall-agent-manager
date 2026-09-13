/**
 * Alert — an inline status banner.
 * ------------------------------------------------------------------
 * Purpose: the one status banner (EL-070/071/072/073), replacing the red / rose /
 * amber / emerald banner forks with `tone` + `emphasis`, and fixing the "errors
 * not announced" defect by giving it the right live-region role.
 *
 * NOT for: a field-level inline error (that is `FormField`'s `error`), a transient
 * toast (use `Toast`), or a status pill (use `StatusPill`).
 *
 * Layer: composite. Spec: `docs/ui-audit/04-component-catalogue.md` › Alert.
 * Prop names follow the shared vocabulary in `../types` (`tone`, `emphasis`,
 * `className`); it shares Badge/StatusPill's tone language via `toneClasses`.
 *
 * Accessibility (built in): `role="alert"` (assertive) for `danger`, `role="status"`
 * (polite) otherwise — so screen readers announce it. A leading tone icon is
 * decorative (`aria-hidden`); the message text carries the meaning. `onDismiss`
 * adds a labelled close button.
 *
 * Tokens only: tone via the shared token map; spacing/radius via tokens. No raw
 * values.
 *
 * Escape hatch: `className` merges onto the root.
 */
import React from 'react';
import { Icon, type IconName } from '../primitives/Icon';
import { IconButton } from '../primitives/IconButton';
import { toneClasses } from '../primitives/toneStyles';
import type { Emphasis, RootClassNameProps, Tone } from '../types';

const DEFAULT_ICON: Record<Tone, IconName> = {
  neutral: 'info',
  info: 'info',
  success: 'check',
  warning: 'alert',
  danger: 'alert',
  pending: 'clock',
};

export interface AlertProps extends RootClassNameProps {
  /** Semantic intent. Default `info`. */
  tone?: Tone;
  /** How strongly the tone is painted. Default `soft`. */
  emphasis?: Emphasis;
  /** Optional bold heading above the message. */
  title?: React.ReactNode;
  /** The message body. */
  children?: React.ReactNode;
  /** Override the leading icon; `null` hides it. */
  icon?: IconName | null;
  /** When provided, shows a close button that calls this. */
  onDismiss?: () => void;
}

export const Alert: React.FC<AlertProps> = ({
  tone = 'info',
  emphasis = 'soft',
  title,
  children,
  icon,
  onDismiss,
  className,
}) => {
  const iconName = icon === null ? null : icon ?? DEFAULT_ICON[tone];
  const rootClassName = [
    'flex items-start gap-3 rounded-[var(--radius-md)] px-3 py-2.5 text-[length:var(--text-body-sm-size)]',
    toneClasses(tone, emphasis),
    className ?? '',
  ]
    .filter(Boolean)
    .join(' ')
    .replace(/\s+/g, ' ')
    .trim();

  return (
    <div role={tone === 'danger' ? 'alert' : 'status'} className={rootClassName}>
      {iconName ? <Icon name={iconName} size="sm" className="mt-0.5 shrink-0" /> : null}
      <div className="min-w-0 flex-1">
        {title ? <div className="font-semibold">{title}</div> : null}
        {children ? <div className={title ? 'mt-0.5' : ''}>{children}</div> : null}
      </div>
      {onDismiss ? (
        <IconButton icon="close" label="Dismiss" size="sm" onClick={onDismiss} className="-mr-1 -mt-0.5 shrink-0" />
      ) : null}
    </div>
  );
};

export default Alert;
