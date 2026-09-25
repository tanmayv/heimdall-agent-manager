/**
 * ResourceSectionCard — reusable section card for detail panes.
 * ------------------------------------------------------------------
 * Purpose: Provides a standardized section card with a subtle uppercase header,
 * optional card header action slot, and content children, matching the look and
 * feel of IssueDetail.tsx.
 */
import React from 'react';
import { Panel } from './Panel';
import type { RootClassNameProps } from '../types';

export interface ResourceSectionCardProps extends RootClassNameProps {
  /** Section heading title (rendered in uppercase subtle typography). */
  title: React.ReactNode;
  /** Optional subtitle or helper text. */
  subtitle?: React.ReactNode;
  /** Alias for subtitle for backwards compatibility. */
  helper?: React.ReactNode;
  /** Optional action slot in the header (e.g. Add, Edit, or Copy button). */
  action?: React.ReactNode;
  /** Section content. */
  children: React.ReactNode;
  /** Data debug ID for testing. */
  dataDebugId?: string;
  /** Alias for dataDebugId for backwards compatibility. */
  debugId?: string;
}

export function ResourceSectionCard({
  title,
  subtitle,
  helper,
  action,
  children,
  dataDebugId,
  debugId,
  className,
}: ResourceSectionCardProps) {
  const resolvedDebugId = dataDebugId || debugId;
  const resolvedSubtitle = subtitle || helper;

  return (
    <Panel
      data-debug-id={resolvedDebugId}
      className={['p-4 rounded-xl border border-subtle bg-surface', className].filter(Boolean).join(' ')}
    >
      <div className="flex items-center justify-between gap-3 mb-3 border-b border-subtle pb-2">
        <div className="min-w-0">
          <h3 className="text-sm font-semibold uppercase tracking-wider text-muted">
            {title}
          </h3>
          {resolvedSubtitle ? (
            <p className="text-xs text-muted mt-0.5">{resolvedSubtitle}</p>
          ) : null}
        </div>
        {action ? <div className="shrink-0">{action}</div> : null}
      </div>
      {children}
    </Panel>
  );
}

export default ResourceSectionCard;
