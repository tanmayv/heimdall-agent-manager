/**
 * Pagination — list paging controls.
 * ------------------------------------------------------------------
 * Purpose: one paging control (EL-080) covering the two patterns the app uses: a
 * "Load more" button for incremental lists, and prev/next page controls for
 * paged data.
 *
 * NOT for: tabs (use `Tabs`) or in-page navigation.
 *
 * Layer: composite. Spec: `docs/ui-audit/04-component-catalogue.md` › Pagination.
 *
 * API — pick ONE mode:
 *   - Load-more: pass `onLoadMore`; `hasMore` gates it, `loading` shows the busy
 *     state. When `hasMore` is false it renders nothing (or `endLabel`).
 *   - Pages: pass `page`, `pageCount`, `onPageChange` for prev/next + a position
 *     readout.
 *
 * Accessibility (built in): wrapped in `<nav aria-label>`; controls are real
 * `Button`s (keyboard + focus for free); the page readout uses `aria-live` so
 * position changes are announced; disabled ends are non-interactive.
 *
 * Tokens only (via Button/Text). No raw values.
 *
 * Escape hatch: `className` merges onto the root `<nav>`.
 */
import React from 'react';
import { Button } from '../primitives/Button';
import type { LoadableProps, RootClassNameProps } from '../types';

export interface PaginationProps extends LoadableProps, RootClassNameProps {
  /** Load-more mode: called to fetch the next page. */
  onLoadMore?: () => void;
  /** Load-more mode: whether more items remain. Default `true`. */
  hasMore?: boolean;
  /** Load-more label. Default "Load more". */
  loadMoreLabel?: string;
  /** Shown (muted) when load-more has no more items. Omit to render nothing. */
  endLabel?: React.ReactNode;

  /** Pages mode: current page (1-based). */
  page?: number;
  /** Pages mode: total pages. */
  pageCount?: number;
  /** Pages mode: called with the next page. */
  onPageChange?: (page: number) => void;

  /** Accessible name for the nav region. Default "Pagination". */
  label?: string;
}

export const Pagination: React.FC<PaginationProps> = ({
  onLoadMore,
  hasMore = true,
  loading = false,
  loadMoreLabel = 'Load more',
  endLabel,
  page,
  pageCount,
  onPageChange,
  label = 'Pagination',
  className,
}) => {
  const rootClassName = ['flex items-center justify-center gap-3', className].filter(Boolean).join(' ');

  // Load-more mode.
  if (onLoadMore) {
    if (!hasMore) {
      return endLabel ? (
        <nav aria-label={label} className={rootClassName}>
          <span className="text-[length:var(--text-body-sm-size)] text-muted">{endLabel}</span>
        </nav>
      ) : null;
    }
    return (
      <nav aria-label={label} className={rootClassName}>
        <Button variant="secondary" loading={loading} onClick={onLoadMore} data-debug-id="pagination-load-more">
          {loadMoreLabel}
        </Button>
      </nav>
    );
  }

  // Pages mode.
  if (page !== undefined && pageCount !== undefined && onPageChange) {
    return (
      <nav aria-label={label} className={rootClassName}>
        <Button
          variant="secondary"
          size="sm"
          disabled={loading || page <= 1}
          onClick={() => onPageChange(page - 1)}
          leading={<span aria-hidden="true">←</span>}
          data-debug-id="pagination-prev"
        >
          Prev
        </Button>
        <span aria-live="polite" className="text-[length:var(--text-body-sm-size)] text-muted">
          Page {page} of {pageCount}
        </span>
        <Button
          variant="secondary"
          size="sm"
          disabled={loading || page >= pageCount}
          onClick={() => onPageChange(page + 1)}
          trailing={<span aria-hidden="true">→</span>}
          data-debug-id="pagination-next"
        >
          Next
        </Button>
      </nav>
    );
  }

  return null;
};

export default Pagination;
