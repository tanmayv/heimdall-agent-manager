/**
 * ResourceContainer — unified 2-pane master/detail desktop container with mobile drill-down.
 * ------------------------------------------------------------------
 * Purpose: Provides a standardized, highly reusable master/detail layout for resource pages
 * (Memories, Issues, Agents, Projects, Actions).
 *
 * Layout:
 * - Desktop: 2-pane layout with <=420px left list column and right detail pane separated
 *   by `border-l border-subtle pl-4`, each with independent scrolling (`overflow-y-auto min-h-0`).
 * - Mobile / Tablet: Responsive single-pane drill-down switching. Renders the list view when
 *   no item is selected; renders the detail view with a back trigger when an item is selected.
 *
 * Wrapped in PageShell with standard title, description, breadcrumbs, and header actions.
 */
import React from 'react';
import { PageShell } from './PageShell';
import type { Crumb } from './Breadcrumbs';
import { Text } from '../primitives/Text';
import { useViewport } from '../hooks/useViewport';
import type { RootClassNameProps } from '../types';

export interface ResourceContainerProps extends RootClassNameProps {
  /** Page title for the master list view. */
  title: React.ReactNode;
  /** Page description for the master list view. */
  description?: React.ReactNode;
  /** Breadcrumb trail for the master list view. */
  breadcrumbs?: Crumb[];
  /** Actions slot for master list view header (e.g., "New" action button). */
  actions?: React.ReactNode;

  /** Currently selected item ID or key. When truthy, signals an item is selected. */
  selectedId?: string | null;
  /** Optional explicit boolean override for selection state. */
  hasSelection?: boolean;

  /** Page title used for mobile drill-down detail view. Defaults to "Details". */
  detailTitle?: React.ReactNode;
  /** Breadcrumbs for the mobile drill-down detail view. */
  detailBreadcrumbs?: Crumb[];
  /** Actions slot for the mobile drill-down detail header. */
  detailActions?: React.ReactNode;

  /** Master list pane content. */
  list: React.ReactNode;
  /** Detail pane content. */
  detail?: React.ReactNode;
  /** Fallback placeholder node shown on desktop when no item is selected. */
  emptyDetail?: React.ReactNode;
  /** Text shown in default empty detail placeholder on desktop. */
  emptyDetailText?: string;

  /** Optional width constraint on the left list column. Defaults to `max-w-[420px]`. */
  listWidthClassName?: string;
  /** Optional data debug ID for the left list column. */
  listDebugId?: string;
  /** Optional data debug ID for the right detail pane. */
  detailDebugId?: string;

  /** PageShell rhythm: 'banded' | 'legacy'. Defaults to 'banded'. */
  rhythm?: 'banded' | 'legacy';
  /** Optional extra content or overlays rendered inside PageShell (e.g. Modals, Toasts). */
  children?: React.ReactNode;
}

export function ResourceContainer({
  title,
  description,
  breadcrumbs,
  actions,
  selectedId,
  hasSelection,
  detailTitle = 'Details',
  detailBreadcrumbs,
  detailActions,
  list,
  detail,
  emptyDetail,
  emptyDetailText = 'Select an item to see it here.',
  listWidthClassName = 'max-w-[420px]',
  listDebugId = 'resource-list-column',
  detailDebugId = 'resource-detail-pane',
  rhythm = 'banded',
  children,
  className,
}: ResourceContainerProps) {
  const viewport = useViewport();
  const twoPane = viewport === 'desktop';
  const isSelected = hasSelection !== undefined ? hasSelection : Boolean(selectedId);

  // Single-pane layout (Mobile / Tablet)
  if (!twoPane) {
    if (isSelected && detail) {
      return (
        <PageShell
          width="full"
          breadcrumbs={detailBreadcrumbs ?? breadcrumbs}
          title={detailTitle}
          actions={detailActions}
          className={['h-full min-h-0 overflow-hidden', className].filter(Boolean).join(' ')}
        >
          <div className="h-full min-h-0 overflow-hidden">
            {detail}
          </div>
          {children}
        </PageShell>
      );
    }

    return (
      <PageShell
        width="full"
        rhythm={rhythm}
        breadcrumbs={breadcrumbs}
        title={title}
        description={description}
        actions={actions}
        className={['h-full min-h-0 overflow-hidden', className].filter(Boolean).join(' ')}
      >
        <div data-debug-id={listDebugId} className="h-full min-h-0 overflow-hidden">
          {list}
        </div>
        {children}
      </PageShell>
    );
  }

  // Two-pane split view (Desktop)
  return (
    <PageShell
      width="full"
      rhythm={rhythm}
      breadcrumbs={breadcrumbs}
      title={title}
      description={description}
      actions={actions}
      className={['h-full min-h-0 overflow-hidden', className].filter(Boolean).join(' ')}
    >
      <div className="flex min-w-0 items-stretch gap-4 flex-1 min-h-0 h-full overflow-hidden">
        {/* Left column: List and filters with independent scroll */}
        <div
          data-debug-id={listDebugId}
          className={[
            'w-full min-w-0 shrink-0 flex flex-col min-h-0 h-full overflow-hidden',
            listWidthClassName,
          ]
            .filter(Boolean)
            .join(' ')}
        >
          {list}
        </div>

        {/* Right column: Detail pane with independent scroll */}
        <div
          data-debug-id={detailDebugId}
          className="min-w-0 flex-1 border-l border-subtle pl-4 flex flex-col min-h-0 h-full overflow-hidden"
        >
          {isSelected && detail ? (
            detail
          ) : (
            emptyDetail ?? (
              <div className="flex h-full items-center justify-center p-6">
                <Text role="body-sm" tone="muted">
                  {emptyDetailText}
                </Text>
              </div>
            )
          )}
        </div>
      </div>
      {children}
    </PageShell>
  );
}

export default ResourceContainer;
