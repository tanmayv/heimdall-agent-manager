/**
 * FilterBar — the filter row, collapsing to a Drawer on mobile, disable-able wholesale.
 * ------------------------------------------------------------------
 * Purpose: every resource list has a row of filters, and every one of them needs the
 * same two behaviours that nothing in `@ui` provides: it must collapse into a sheet at
 * ≤767px, and it must be **disable-able as a whole with a visible explanation**. The
 * controls themselves are `Select` / `Combobox` / `Input` and stay the caller's; the
 * assembly is what repeats, so the assembly is what lives here.
 *
 * NOT for: a form (use `FormField`), or a single filter control on its own.
 *
 * Layer: composite. Product-agnostic — it holds no filter, no option list and no
 * default; `children` are whatever the resource filters on.
 *
 * REQ-UI-5 — search wins over filters. When a search query is active the server
 * disregards filters, so the UI must say so. `disabled` + `disabledReason` render the
 * bar **dimmed and inert with the reason in an `Alert` above it — disabled, never
 * hidden.** Hiding the controls would leave the user unable to see the filter state
 * that is being held for them, which is precisely the state they need to reason about.
 * The controls are inert via a real `<fieldset disabled>`, so every control inside is
 * natively non-interactive and out of the tab order — no per-control `disabled`
 * plumbing, and nothing an inner component can forget to honour.
 *
 * Collapsed by default, on EVERY viewport (`layout="collapsed"`). Five permanent
 * dropdowns are a lot of standing furniture for controls most users touch rarely, so
 * the controls live in a `Drawer` (a bottom sheet on mobile, a side panel on desktop)
 * behind a **Filters** button carrying a dot when any filter is off its default
 * (`active`). What stays on the page is the `summary` slot — chips naming only the
 * NON-DEFAULT filters — so the page shows the filter state that actually exists
 * rather than five controls that mostly read "All". `layout="inline"` keeps the old
 * always-open row for a list where filtering is the primary act.
 *
 * `note` is the slot for an explanation of what the filters MEAN (memory's "scope
 * filters show memories that apply to…"). It rides inside the drawer with the
 * controls it describes, instead of costing the page a permanent band.
 *
 * When the bar is disabled the button stays visible and disabled, with the same
 * `Alert` inline — the REQ-UI-5 rule holds on both viewports.
 *
 * Accessibility (built in): the bar is a labelled `role="group"`; the reason `Alert`
 * is referenced by the fieldset via `aria-describedby`, so a screen reader hears WHY
 * the controls are inert rather than just finding them unreachable; the mobile drawer
 * brings `Drawer`'s full focus-trap contract with it.
 *
 * Tokens only. Escape hatch: `className` merges onto the root.
 */
import React from 'react';
import { Alert } from './Alert';
import { Drawer } from './Drawer';
import { Popover } from './Popover';
import type { DrawerSide } from './Drawer';
import { Button } from '../primitives/Button';
import { IconButton } from '../primitives/IconButton';
import { Text } from '../primitives/Text';
import { useIsMobile, TOUCH_TARGET_CLASS } from '../hooks/useViewport';
import type { RootClassNameProps } from '../types';

export interface FilterBarProps extends RootClassNameProps {
  /** The filter controls. */
  children?: React.ReactNode;
  /**
   * Disable every control at once, with `disabledReason` shown. The REQ-UI-5 case:
   * a search query is active and the server disregards filters.
   */
  disabled?: boolean;
  /**
   * Why the controls are inert, and ideally how to get them back (a one-click
   * restore belongs in `actions`). Rendered in an `Alert` — required reading, not a
   * tooltip. Shown only while `disabled`.
   */
  disabledReason?: React.ReactNode;
  /** True when any filter is off its default — marks the Filters button. */
  active?: boolean;
  /**
   * How many filters are applied. Rendered as a count on the Filters button, which
   * says more than a dot for the same space: "Filters 2" tells a user how much of
   * what they are looking at is being withheld. Falls back to a dot when omitted.
   */
  activeCount?: number;
  /**
   * Render the collapsed trigger as an ICON button — the user's ruling: the Filters
   * control sits as an icon immediately right of the search field. The accessible
   * name is still the full label plus the count; collapsing to a glyph never drops
   * the name, on any viewport.
   */
  iconTrigger?: boolean;
  /**
   * A short `title` for the trigger while the bar is disabled — the quiet form of
   * `disabledReason` for a caller that does not want the `Alert` on the page. The
   * control being inert is the visible signal; this is the explanation for anyone
   * who hovers it.
   */
  disabledTitle?: string;
  /** Trailing slot: a Clear filters / Restore button. Stays usable while disabled. */
  actions?: React.ReactNode;
  /**
   * Chips (or any summary) for the filters that are OFF their default, rendered
   * beside the Filters button. Make them removable — a chip you cannot click is just
   * a second label.
   */
  summary?: React.ReactNode;
  /**
   * An explanation of what these filters mean, shown with the controls inside the
   * drawer (collapsed layout) or under the row (inline layout).
   */
  note?: React.ReactNode;
  /**
   * `collapsed` (default) — a Filters button + panel at every width.
   * `inline` — the always-open control row on desktop, still a panel on mobile.
   */
  layout?: 'collapsed' | 'inline';
  /**
   * Which surface the collapsed controls open in: a `popover` anchored to the button
   * (right on desktop, where the button has a place on screen) or a `sheet` — the
   * `Drawer` — which is right on touch. Default: `sheet` on mobile, `popover` above it.
   */
  surface?: 'popover' | 'sheet';
  /** Accessible name for the group and the mobile drawer. Default `'Filters'`. */
  label?: string;
  /** Which edge the mobile drawer anchors to. Default `'bottom'`. */
  side?: DrawerSide;
}

export const FilterBar: React.FC<FilterBarProps> = ({
  children,
  disabled = false,
  disabledReason,
  active = false,
  activeCount,
  iconTrigger = false,
  disabledTitle,
  actions,
  summary,
  note,
  layout = 'collapsed',
  surface,
  label = 'Filters',
  side = 'bottom',
  className,
}) => {
  const isMobile = useIsMobile();
  const [open, setOpen] = React.useState(false);
  const reasonId = React.useId();

  const showReason = disabled && disabledReason !== undefined && disabledReason !== null;

  // `Alert` takes no `id` (one `className` escape hatch, no attribute passthrough),
  // so the id that `aria-describedby` points at lives on a wrapper.
  const reason = showReason ? (
    <div id={reasonId} className="mb-3">
      <Alert tone="info">{disabledReason}</Alert>
    </div>
  ) : null;

  // A real `<fieldset disabled>`: every control inside goes inert and leaves the tab
  // order natively, whatever it is made of.
  const controls = (
    <fieldset
      disabled={disabled}
      aria-describedby={showReason ? reasonId : undefined}
      className={[
        'min-w-0 border-0 p-0',
        disabled ? 'opacity-60' : '',
        // In the collapsed layout the controls live in a drawer, where a column of
        // full-width controls is the right shape at any viewport.
        isMobile || layout === 'collapsed' ? 'flex flex-col gap-3' : 'flex flex-wrap items-center gap-2',
      ]
        .filter(Boolean)
        .join(' ')}
    >
      <legend className="sr-only">{label}</legend>
      {children}
    </fieldset>
  );

  const noteBlock = note ? (
    <Text role="body-sm" tone="muted" className="ui-measure">
      {note}
    </Text>
  ) : null;

  if (isMobile || layout === 'collapsed') {
    // Popover on desktop, sheet on touch — a popover anchored to a button the thumb
    // cannot comfortably reach is worse than a sheet, and a sheet on desktop covers
    // the list the filters are about.
    const usePopover = (surface ?? (isMobile ? 'sheet' : 'popover')) === 'popover';
    const count = activeCount ?? 0;
    const marker = active && !disabled
      ? count > 0
        ? (
          <span
            aria-hidden="true"
            className="inline-flex min-w-4 items-center justify-center rounded-pill bg-accent px-1 text-caption font-semibold text-accent-fg"
          >
            {count}
          </span>
        )
        : <span aria-hidden="true" className="inline-block h-1.5 w-1.5 rounded-pill bg-accent" />
      : undefined;

    // `IconButton` owns its own `title` (it mirrors the accessible name), so the
    // disabled explanation rides on the wrapper instead of fighting it.
    const triggerButton = iconTrigger ? (
      <span className="relative inline-flex shrink-0" title={disabled && disabledTitle ? disabledTitle : undefined}>
        <IconButton
          icon="layers"
          label={active && !disabled && count > 0 ? `${label} (${count} applied)` : label}
          variant="ghost"
          size={isMobile ? 'md' : 'sm'}
          disabled={disabled}
          onClick={usePopover ? undefined : () => setOpen(true)}
          aria-describedby={showReason ? reasonId : undefined}
          data-debug-id="filterbar-trigger"
        />
        {/* The count rides on the icon as a badge; it is decorative, because the
            same number is already in the control's accessible name. */}
        {marker ? <span className="pointer-events-none absolute -right-1 -top-1">{marker}</span> : null}
      </span>
    ) : (
      <Button
        data-debug-id="filterbar-trigger"
        variant="secondary"
        size={isMobile ? 'md' : 'sm'}
        disabled={disabled}
        onClick={usePopover ? undefined : () => setOpen(true)}
        aria-describedby={showReason ? reasonId : undefined}
        title={disabled && disabledTitle ? disabledTitle : undefined}
        className={isMobile ? TOUCH_TARGET_CLASS : undefined}
        trailing={marker}
      >
        {label}
        {active && !disabled ? (
          <span className="sr-only">{count > 0 ? ` (${count} applied)` : ' (filters applied)'}</span>
        ) : null}
      </Button>
    );

    return (
      <div role="group" aria-label={label} className={className}>
        {reason}
        <div className="flex flex-wrap items-center gap-2">
          {usePopover ? (
            <Popover
              open={open}
              onOpenChange={setOpen}
              label={label}
              align="end"
              trigger={triggerButton}
            >
              <div className="flex w-[280px] flex-col gap-4">
                {controls}
                {noteBlock}
              </div>
            </Popover>
          ) : (
            triggerButton
          )}
          {/* The filter state that EXISTS, on the page; the controls that mostly read
              "All" stay behind the button. */}
          {summary}
          {actions ? <div className="ml-auto flex shrink-0 items-center gap-2">{actions}</div> : null}
        </div>
        {usePopover ? null : (
          <Drawer open={open} onOpenChange={setOpen} title={label} side={side}>
            <Drawer.Body>
              <div className="flex flex-col gap-4">
                {controls}
                {noteBlock}
              </div>
            </Drawer.Body>
          </Drawer>
        )}
      </div>
    );
  }

  return (
    <div role="group" aria-label={label} className={className}>
      {reason}
      <div className="flex flex-wrap items-center gap-2">
        {controls}
        {actions ? <div className="ml-auto flex shrink-0 items-center gap-2">{actions}</div> : null}
      </div>
      {noteBlock ? <div className="mt-2">{noteBlock}</div> : null}
    </div>
  );
};

export default FilterBar;
