/**
 * ResourceEntryCard — selectable card row for master/detail list views.
 * ------------------------------------------------------------------
 * Purpose: Provides a standardized, highly reusable entry row for resource lists
 * (Issues, Memories, Agents, Projects, Actions) based on the look and feel of IssueRow.tsx.
 */
import React from 'react';
import { ActionButton } from './ActionButton';
import { Menu, MenuItem } from './Menu';
import { Text } from '../primitives/Text';
import type { RootClassNameProps } from '../types';

const BODY_TWO_LINES = 'calc(2 * var(--text-body-sm-size) * var(--text-body-sm-leading))';

export interface ResourceMenuAction {
  label: string;
  onClick: () => void;
  danger?: boolean;
  disabled?: boolean;
  debugId?: string;
}

export interface ResourceEntryCardProps
  extends RootClassNameProps,
    Omit<React.LiHTMLAttributes<HTMLLIElement>, 'title'> {
  /** Unique ID or key for this resource. */
  id?: string;
  /** Primary title of the resource. */
  title: React.ReactNode;
  /** Navigation href for the title link. */
  href?: string;
  /** Whether this card is currently selected/active. */
  active?: boolean;
  /** Callback fired when the row or title is activated. */
  onSelect?: () => void;

  /** Leading element before the card content (e.g. bulk selection Checkbox). */
  leading?: React.ReactNode;

  /** Description snippet or preview (clamped to 2 lines). */
  snippet?: React.ReactNode;
  /** Fallback placeholder when snippet is empty. Defaults to "<no description>". */
  emptySnippetText?: string;

  /** Status indicator node (e.g. StatusPill). */
  status?: React.ReactNode;
  /** Badges or pill nodes to display next to the status. */
  badges?: React.ReactNode;
  /** Extra interactive metadata controls (e.g. Vote button, Task Chain link, author tag). */
  metadata?: React.ReactNode;

  /** Relative or formatted timestamp displayed at the bottom right. */
  timestamp?: React.ReactNode;
  /** Absolute time tooltip for hover on timestamp. */
  timestampTooltip?: string;

  /** List of menu actions for the more options context menu. */
  menuActions?: ResourceMenuAction[];
  /** Custom menu or action slot override in the top right. */
  actionsMenu?: React.ReactNode;

  /** Optional data debug ID for testing. */
  dataDebugId?: string;
  /** Optional data debug ID for the body preview snippet. */
  bodyDebugId?: string;
  /** Optional data debug ID for the timestamp. */
  timeDebugId?: string;
  /** Extra content rendered inside the card body. */
  children?: React.ReactNode;
}

export function ResourceEntryCard({
  id,
  title,
  href,
  active = false,
  onSelect,
  leading,
  snippet,
  emptySnippetText = '<no description>',
  status,
  badges,
  metadata,
  timestamp,
  timestampTooltip,
  menuActions,
  actionsMenu,
  dataDebugId,
  bodyDebugId,
  timeDebugId,
  children,
  className,
  ...rest
}: ResourceEntryCardProps) {
  function handleRowClick(e: React.MouseEvent) {
    if (e.defaultPrevented || e.button !== 0) return;
    if (e.metaKey || e.ctrlKey || e.shiftKey || e.altKey) return;
    if ((e.target as HTMLElement).closest('[data-row-control]')) return;
    e.preventDefault();
    onSelect?.();
  }

  const titleString = typeof title === 'string' ? title : 'resource';
  const hasMenu = Boolean((menuActions && menuActions.length > 0) || actionsMenu);

  return (
    <li
      data-resource-entry={id}
      data-debug-id={dataDebugId || (id ? `resource-card-${id}` : undefined)}
      data-active={active || undefined}
      className={[
        'relative flex min-h-[72px] items-start gap-3 border-b border-subtle px-3 py-3 transition-colors duration-fast cursor-pointer',
        active ? 'bg-surface-raised' : 'hover:bg-surface',
        className,
      ]
        .filter(Boolean)
        .join(' ')}
      onClick={handleRowClick}
      {...rest}
    >
      {leading}
      <div className="min-w-0 flex-1">
        {/* Row 1: Title and actions menu */}
        <div className="flex items-start gap-2">
          <a
            href={href || '#'}
            onClick={(e) => {
              if (e.metaKey || e.ctrlKey || e.shiftKey || e.altKey || e.button !== 0) return;
              e.preventDefault();
              onSelect?.();
            }}
            className="min-w-0 flex-1 truncate rounded-[var(--radius-sm)] text-title text-primary focus-visible:shadow-focus focus-visible:outline-none"
          >
            {title}
          </a>

          {/* More options menu */}
          {hasMenu ? (
            <span data-row-control className="shrink-0">
              {actionsMenu ? (
                actionsMenu
              ) : (
                <Menu
                  label={`Actions for ${titleString}`}
                  align="end"
                  trigger={
                    <ActionButton
                      icon="more-horizontal"
                      label="More"
                      iconOnly
                      aria-label={`Actions for ${titleString}`}
                      data-debug-id={id ? `resource-card-menu-${id}` : undefined}
                    />
                  }
                >
                  {menuActions!.map((act, idx) => (
                    <MenuItem
                      key={idx}
                      danger={act.danger}
                      disabled={act.disabled}
                      data-debug-id={act.debugId}
                      onClick={act.onClick}
                    >
                      {act.label}
                    </MenuItem>
                  ))}
                </Menu>
              )}
            </span>
          ) : null}
        </div>

        {/* Rows 2-3: Description preview snippet */}
        <p
          className="mt-0.5 overflow-hidden text-body-sm text-muted [display:-webkit-box] [-webkit-box-orient:vertical] [-webkit-line-clamp:2]"
          style={{ minHeight: BODY_TWO_LINES }}
          data-debug-id={bodyDebugId || (id ? `resource-card-body-${id}` : undefined)}
        >
          {snippet && (typeof snippet !== 'string' || snippet.trim()) ? (
            snippet
          ) : (
            <span className="italic text-faint select-none">
              {emptySnippetText}
            </span>
          )}
        </p>

        {children}

        {/* Row 4: Status pill, badges, metadata controls, and timestamp */}
        {(status || badges || metadata || timestamp) ? (
          <div className="mt-1.5 flex items-end justify-between gap-3">
            <div className="flex min-w-0 flex-wrap items-center gap-2">
              {status}
              {badges}
              {metadata}
            </div>

            {timestamp ? (
              <Text
                as="span"
                role="caption"
                tone="muted"
                className="shrink-0 whitespace-nowrap"
                title={timestampTooltip}
                data-debug-id={timeDebugId || (id ? `resource-card-time-${id}` : undefined)}
              >
                {timestamp}
              </Text>
            ) : null}
          </div>
        ) : null}
      </div>
    </li>
  );
}

export default ResourceEntryCard;
