/**
 * Toast — a transient notification card.
 * ------------------------------------------------------------------
 * Purpose: the one toast card (EL-075) — a raised, dismissible notification with
 * the correct live-region announcement and an optional auto-dismiss. This is the
 * PRESENTATIONAL card; a viewport (a fixed, portalled stack) renders a queue of
 * these. It is intentionally product-agnostic — it does not own the queue, so it
 * works with the app's existing toast store (map each item to a `<Toast>`).
 *
 * NOT for: an inline banner tied to content (use `Alert`), or a modal.
 *
 * Layer: composite. Spec: `docs/ui-audit/04-component-catalogue.md` › Toast.
 * Prop names follow the shared vocabulary in `../types` (`tone`, `className`).
 *
 * Accessibility (built in): `role="status"` + `aria-live="polite"` by default so
 * screen readers announce it; a `danger` toast escalates to `role="alert"` +
 * `aria-live="assertive"`. The tone icon is decorative; the dismiss button is
 * labelled.
 *
 * Auto-dismiss: pass `duration` (ms) and `onDismiss` — the card calls `onDismiss`
 * after the delay (paused while hovered/focused). Omit `duration` for a sticky
 * toast the user must dismiss.
 *
 * Tokens only: surface/shadow/radius/tone via tokens. No raw values.
 *
 * Escape hatch: `className` merges onto the root.
 */
import React, { useEffect, useRef, useState } from 'react';
import { Icon, type IconName } from '../primitives/Icon';
import { IconButton } from '../primitives/IconButton';
import type { RootClassNameProps, Tone } from '../types';

const TONE_ICON: Record<Tone, IconName> = {
  neutral: 'info',
  info: 'info',
  success: 'check',
  warning: 'alert',
  danger: 'alert',
  pending: 'clock',
};

const TONE_ICON_COLOR: Record<Tone, string> = {
  neutral: 'text-muted',
  info: 'text-info',
  success: 'text-success',
  warning: 'text-warning',
  danger: 'text-danger',
  pending: 'text-warning',
};

export interface ToastProps extends RootClassNameProps {
  /** Semantic intent. Default `neutral`. */
  tone?: Tone;
  /** Title line. */
  title: React.ReactNode;
  /** Optional secondary message. */
  children?: React.ReactNode;
  /** Override the tone icon; `null` hides it. */
  icon?: IconName | null;
  /** Auto-dismiss after this many ms (paused on hover/focus). Omit = sticky. */
  duration?: number;
  /** Called on dismiss (auto or via the close button). */
  onDismiss?: () => void;
}

export const Toast: React.FC<ToastProps> = ({
  tone = 'neutral',
  title,
  children,
  icon,
  duration,
  onDismiss,
  className,
}) => {
  const [paused, setPaused] = useState(false);
  const onDismissRef = useRef(onDismiss);
  useEffect(() => {
    onDismissRef.current = onDismiss;
  });

  useEffect(() => {
    if (!duration || paused) return;
    const t = window.setTimeout(() => onDismissRef.current?.(), duration);
    return () => window.clearTimeout(t);
  }, [duration, paused]);

  const iconName = icon === null ? null : icon ?? TONE_ICON[tone];
  const rootClassName = [
    'pointer-events-auto flex w-full max-w-sm items-start gap-3 rounded-[var(--radius-md)]',
    'border border-subtle bg-surface-overlay px-3 py-2.5 text-[length:var(--text-body-sm-size)]',
    'text-primary shadow-overlay',
    className ?? '',
  ]
    .filter(Boolean)
    .join(' ')
    .replace(/\s+/g, ' ')
    .trim();

  return (
    <div
      role={tone === 'danger' ? 'alert' : 'status'}
      aria-live={tone === 'danger' ? 'assertive' : 'polite'}
      className={rootClassName}
      onMouseEnter={() => setPaused(true)}
      onMouseLeave={() => setPaused(false)}
      onFocusCapture={() => setPaused(true)}
      onBlurCapture={() => setPaused(false)}
    >
      {iconName ? <Icon name={iconName} size="sm" className={`mt-0.5 shrink-0 ${TONE_ICON_COLOR[tone]}`} /> : null}
      <div className="min-w-0 flex-1">
        <div className="font-semibold">{title}</div>
        {children ? <div className="mt-0.5 text-muted">{children}</div> : null}
      </div>
      {onDismiss ? (
        <IconButton icon="close" label="Dismiss" size="sm" onClick={onDismiss} className="-mr-1 -mt-0.5 shrink-0" />
      ) : null}
    </div>
  );
};

export default Toast;
