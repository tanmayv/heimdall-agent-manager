/**
 * ActionButton — one action, labelled on desktop and icon-only on touch.
 * ------------------------------------------------------------------
 * Purpose: the user's ruling on the rebuild is "no icon-only buttons on desktop;
 * prefer icon buttons on mobile". That is one rule about one action rendered two
 * ways, so it belongs in ONE component rather than in a `useIsMobile()` fork copied
 * into all five resource pages. Row actions (`DataList`'s `rowActions`), bulk verbs
 * (`BulkActionBar`'s children) and any page-header verb render through this.
 *
 * NOT for: a page's single primary call-to-action (that is a `Button` with a real
 * label at every width), or a control with no sensible glyph — pass no `icon` and it
 * stays a labelled `Button` everywhere, which is the honest answer for those.
 *
 * Layer: composite. Product-agnostic: it knows a label, a glyph and an intent.
 *
 * Accessibility (built in): the label is the SAME string in both renderings — visible
 * text on desktop, `aria-label` + `title` on touch (via `IconButton`, which requires
 * it). Collapsing to a glyph never drops the accessible name; that rule does not
 * lapse on mobile because the screen got smaller.
 *
 * Tokens only. Escape hatch: `className` merges onto whichever root is rendered.
 */
import React from 'react';
import { Button } from '../primitives/Button';
import { IconButton } from '../primitives/IconButton';
import { Icon, type IconName } from '../primitives/Icon';
import { useIsMobile, TOUCH_TARGET_CLASS } from '../hooks/useViewport';
import type { ButtonVariant, RootClassNameProps } from '../types';

export interface ActionButtonProps
  extends Omit<React.ButtonHTMLAttributes<HTMLButtonElement>, 'className' | 'children'>,
    RootClassNameProps {
  /** The verb, in the user's words: "Edit", "Archive", "More". Always rendered or announced. */
  label: string;
  /** The glyph used at ≤767px. Omit to keep the labelled button on every viewport. */
  icon?: IconName;
  /** Visual weight + intent. Default `secondary` (a row verb is not a page's CTA). */
  variant?: ButtonVariant;
  /** Busy state — the spinner lands in whichever rendering is showing. */
  loading?: boolean;
  disabled?: boolean;
  /**
   * Show the glyph next to the text on desktop too. Off by default: a labelled verb
   * in a dense row reads better without one.
   */
  showIconOnDesktop?: boolean;
  /**
   * Collapse to the glyph on EVERY viewport. The desktop default is a labelled
   * button and stays that way for verbs; this exists for the one control the user
   * ruled otherwise — an overflow `…` menu trigger, where the glyph IS the
   * convention and a text label reads as a verb it is not. The accessible name is
   * still required and still the full label.
   */
  iconOnly?: boolean;
}

export const ActionButton = React.forwardRef<HTMLButtonElement, ActionButtonProps>(
  function ActionButton(
    { label, icon, variant = 'secondary', loading = false, disabled, showIconOnDesktop = false, iconOnly = false, className, ...rest },
    ref,
  ) {
    const isMobile = useIsMobile();

    if ((isMobile || iconOnly) && icon) {
      return (
        <IconButton
          ref={ref}
          icon={icon}
          // Same string as the desktop label — the accessible name survives the collapse.
          label={label}
          variant={variant === 'danger' ? 'danger' : variant === 'primary' ? 'solid' : 'ghost'}
          loading={loading}
          disabled={disabled}
          className={[TOUCH_TARGET_CLASS, className].filter(Boolean).join(' ')}
          {...rest}
        />
      );
    }

    return (
      <Button
        ref={ref}
        variant={variant}
        size="sm"
        loading={loading}
        disabled={disabled}
        leading={showIconOnDesktop && icon ? <Icon name={icon} size="sm" /> : undefined}
        className={className}
        {...rest}
      >
        {label}
      </Button>
    );
  },
);

export default ActionButton;
