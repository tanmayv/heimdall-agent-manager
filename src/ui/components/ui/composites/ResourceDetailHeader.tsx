/**
 * ResourceDetailHeader — standardized header for detail views in master/detail layouts.
 * ------------------------------------------------------------------
 * Purpose: Provides a standardized detail header based on IssueDetail.tsx, including:
 * - Mobile back trigger
 * - Alert banners
 * - Title and mono-spaced ID
 * - Status pills, metadata badges, and timestamps
 * - Action buttons cluster
 */
import React from 'react';
import { Button } from '../primitives/Button';
import { Icon } from '../primitives/Icon';
import { Text } from '../primitives/Text';
import { useViewport } from '../hooks/useViewport';
import type { RootClassNameProps } from '../types';

export interface ResourceDetailHeaderProps extends RootClassNameProps {
  /** Primary title of the resource. */
  title: React.ReactNode;
  /** Unique ID or identifier displayed in mono font beneath the title. */
  id?: string;

  /** Status pill or indicator. */
  status?: React.ReactNode;
  /** Metadata badges (e.g. scope, category, type). */
  badges?: React.ReactNode;

  /** Timestamp or relative time node (e.g. "Reported 2h ago by tanmay"). */
  timestamp?: React.ReactNode;
  /** Tooltip for absolute time on hover. */
  timestampTooltip?: string;

  /** Action buttons cluster (e.g. status dropdown, edit, delete, custom buttons). */
  actions?: React.ReactNode;

  /** Alert banner node displayed at the top of the header (e.g. errors or notices). */
  alert?: React.ReactNode;

  /** Mobile back button callback. */
  onBack?: () => void;
  /** Label for the back button. Defaults to "Back". */
  backLabel?: string;
  /** When true, renders back button on desktop viewports as well. */
  alwaysShowBack?: boolean;

  /** Optional data debug ID for testing. */
  dataDebugId?: string;
}

export function ResourceDetailHeader({
  title,
  id,
  status,
  badges,
  timestamp,
  timestampTooltip,
  actions,
  alert,
  onBack,
  backLabel = 'Back',
  alwaysShowBack = false,
  dataDebugId,
  className,
}: ResourceDetailHeaderProps) {
  const viewport = useViewport();
  const isMobile = viewport === 'mobile';
  const showBack = onBack && (isMobile || alwaysShowBack);

  return (
    <div
      data-debug-id={dataDebugId}
      className={['flex flex-col gap-3 border-b border-subtle pb-4', className].filter(Boolean).join(' ')}
    >
      {/* Mobile back trigger */}
      {showBack ? (
        <div>
          <Button
            variant="ghost"
            size="sm"
            onClick={onBack}
            className="gap-1.5 -ml-2"
            data-debug-id="resource-detail-back-btn"
          >
            <Icon name="chevron-left" size={16} />
            <span>{backLabel}</span>
          </Button>
        </div>
      ) : null}

      {/* Alert banner */}
      {alert ? (
        <div className="w-full">
          {alert}
        </div>
      ) : null}

      {/* Metadata chips / pills above title */}
      {(status || badges || timestamp) ? (
        <div className="flex flex-wrap items-center gap-2">
          {status}
          {badges}
          {timestamp ? (
            <Text
              as="span"
              role="caption"
              tone="muted"
              title={timestampTooltip}
            >
              {timestamp}
            </Text>
          ) : null}
        </div>
      ) : null}

      {/* Title & mono ID - full width, space efficient */}
      <div className="min-w-0 w-full">
        <h1 className="text-lg sm:text-xl font-semibold tracking-tight text-primary break-words">
          {title}
        </h1>

        {id ? (
          <p className="text-xs text-muted mt-1 font-mono select-all">{id}</p>
        ) : null}
      </div>

      {/* Action buttons cluster at the end of the header */}
      {actions ? (
        <div className="flex flex-wrap items-center gap-2 pt-1 w-full" data-debug-id="resource-detail-actions">
          {actions}
        </div>
      ) : null}
    </div>
  );
}

export default ResourceDetailHeader;
