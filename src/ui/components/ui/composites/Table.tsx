/**
 * Table — real, accessible tabular data.
 * ------------------------------------------------------------------
 * Purpose: one data table (EL-084) that renders REAL table semantics
 * (`<table>/<thead>/<th scope>/<tbody>/<tr>/<td>`), fixing the "no table
 * semantics anywhere" finding (the app's faux flex/grid tables give SR users no
 * row/column structure). Data-driven via `columns` + `rows`.
 *
 * NOT for: layout grids (use CSS grid/flex) or a list of cards.
 *
 * Layer: composite. Spec: `docs/ui-audit/04-component-catalogue.md` › Table.
 *
 * API: `columns` (each: `key`, `header`, optional `render(row)`, `align`,
 * `sortable`) + `rows`. Sorting is controlled: pass `sort` + `onSortChange`; a
 * sortable header becomes a button that cycles asc→desc and sets `aria-sort`.
 * `getRowKey` gives stable row keys (defaults to index). `label`/`caption` name
 * the table.
 *
 * Accessibility (built in): real table elements; `<th scope="col">` headers;
 * `aria-sort` on the active sort column; an optional `<caption>`; sortable headers
 * are real buttons with a focus ring.
 *
 * Horizontal overflow (ground-truth Amendment 4): the table — never the page —
 * is what scrolls sideways when the columns do not fit. The root wrapper is the
 * `overflow-x: auto` container, and `scrollRegionLabel` turns it into a real
 * `role="region"` with `tabindex="0"`, which is what gives a keyboard user a way to
 * reach the columns past the fold. A column may pin itself with `sticky: 'start' |
 * 'end'`; a pinned cell paints an OPAQUE background (`--ui-table-sticky-bg`,
 * defaulting to the canvas token) because a transparent one smears the rows
 * travelling underneath it.
 *
 * Tokens only: border/type/spacing/color via tokens. No raw values.
 *
 * Escape hatch: `className` merges onto the root `<table>` wrapper.
 */
import React from 'react';
import { Icon } from '../primitives/Icon';
import type { Align, RootClassNameProps } from '../types';

export interface TableColumn<T> {
  /** Stable key; also the default cell accessor (`row[key]`). */
  key: string;
  /** Column header content. */
  header: React.ReactNode;
  /** Custom cell renderer; defaults to `String(row[key])`. */
  render?: (row: T) => React.ReactNode;
  /** Cell text alignment. Default `start`. */
  align?: Align;
  /** Whether this column can be sorted. */
  sortable?: boolean;
  /**
   * Pin the column against an edge while the table scrolls horizontally. Use it for
   * the controls a user reaches for at any scroll offset — the select box and the
   * row actions. A pinned column paints an opaque background.
   */
  sticky?: 'start' | 'end';
  /** Extra classes for this column's `<td>`s (width caps, wrapping, nowrap…). */
  cellClassName?: string;
  /** Extra classes for this column's `<th>`. Defaults to `cellClassName`. */
  headerClassName?: string;
}

export interface TableSort {
  key: string;
  direction: 'asc' | 'desc';
}

export interface TableProps<T> extends RootClassNameProps {
  columns: TableColumn<T>[];
  rows: T[];
  /** Stable row key. Defaults to the row index. */
  getRowKey?: (row: T, index: number) => string;
  /** Controlled sort state. */
  sort?: TableSort;
  /** Fired with the next sort when a sortable header is clicked. */
  onSortChange?: (sort: TableSort) => void;
  /** Accessible table name (rendered as a visually-hidden `<caption>`). */
  caption?: string;
  /**
   * Turns the scroll wrapper into a keyboard-reachable `role="region"` with this
   * accessible name. Set it whenever the table can overflow — without it the
   * columns past the fold are pointer-only.
   */
  scrollRegionLabel?: string;
  /**
   * Minimum table width (any CSS length). Below it the wrapper scrolls instead of
   * squeezing the columns into unreadable slivers — a table that can shrink forever
   * never overflows, and never being able to overflow is not the same as fitting.
   */
  minWidth?: string;
}

const ALIGN_CLASS: Record<Align, string> = {
  start: 'text-left',
  center: 'text-center',
  end: 'text-right',
};

export function Table<T>({
  columns,
  rows,
  getRowKey,
  sort,
  onSortChange,
  caption,
  scrollRegionLabel,
  minWidth,
  className,
}: TableProps<T>) {
  function toggleSort(key: string) {
    const nextDir: 'asc' | 'desc' = sort?.key === key && sort.direction === 'asc' ? 'desc' : 'asc';
    onSortChange?.({ key, direction: nextDir });
  }

  // Sticky cells need an opaque paint of their own — the rows scroll under them.
  const stickyClass = (sticky: TableColumn<T>['sticky']) =>
    sticky === 'start'
      ? 'sticky left-0 z-[1] bg-[var(--ui-table-sticky-bg,var(--color-canvas))]'
      : sticky === 'end'
        ? 'sticky right-0 z-[1] bg-[var(--ui-table-sticky-bg,var(--color-canvas))]'
        : '';

  return (
    <div
      role={scrollRegionLabel ? 'region' : undefined}
      aria-label={scrollRegionLabel}
      tabIndex={scrollRegionLabel ? 0 : undefined}
      className={[
        'w-full max-w-full overflow-x-auto rounded-[var(--radius-sm)] focus-visible:shadow-focus focus-visible:outline-none',
        className,
      ]
        .filter(Boolean)
        .join(' ')}
    >
      <table
        style={minWidth ? { minWidth } : undefined}
        className="w-full border-collapse text-[length:var(--text-body-sm-size)]"
      >
        {caption ? <caption className="sr-only">{caption}</caption> : null}
        <thead>
          <tr className="border-b border-subtle">
            {columns.map((col) => {
              const align = col.align ?? 'start';
              const isSorted = sort?.key === col.key;
              const ariaSort = isSorted ? (sort!.direction === 'asc' ? 'ascending' : 'descending') : undefined;
              return (
                <th
                  key={col.key}
                  scope="col"
                  aria-sort={ariaSort}
                  className={[
                    'whitespace-nowrap px-3 py-2 text-label font-semibold uppercase tracking-wide text-faint',
                    ALIGN_CLASS[align],
                    stickyClass(col.sticky),
                    col.headerClassName ?? col.cellClassName ?? '',
                  ]
                    .filter(Boolean)
                    .join(' ')}
                >
                  {col.sortable ? (
                    <button
                      type="button"
                      onClick={() => toggleSort(col.key)}
                      className="inline-flex items-center gap-1 rounded-[var(--radius-sm)] text-muted hover:text-primary focus-visible:shadow-focus focus-visible:outline-none"
                    >
                      {col.header}
                      <Icon
                        name="chevron-down"
                        size="sm"
                        className={[
                          'transition-transform duration-fast',
                          isSorted ? 'text-primary' : 'opacity-40',
                          isSorted && sort!.direction === 'asc' ? 'rotate-180' : '',
                        ].join(' ')}
                      />
                    </button>
                  ) : (
                    col.header
                  )}
                </th>
              );
            })}
          </tr>
        </thead>
        <tbody>
          {rows.map((row, i) => (
            <tr key={getRowKey ? getRowKey(row, i) : String(i)} className="border-b border-subtle last:border-0">
              {columns.map((col) => {
                const align = col.align ?? 'start';
                const content = col.render
                  ? col.render(row)
                  : String((row as Record<string, unknown>)[col.key] ?? '');
                return (
                  <td
                    key={col.key}
                    className={[
                      'px-3 py-2 align-middle text-primary',
                      ALIGN_CLASS[align],
                      stickyClass(col.sticky),
                      col.cellClassName ?? '',
                    ]
                      .filter(Boolean)
                      .join(' ')}
                  >
                    {content}
                  </td>
                );
              })}
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}

export default Table;
