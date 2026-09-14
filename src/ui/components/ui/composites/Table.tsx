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
  className,
}: TableProps<T>) {
  function toggleSort(key: string) {
    const nextDir: 'asc' | 'desc' = sort?.key === key && sort.direction === 'asc' ? 'desc' : 'asc';
    onSortChange?.({ key, direction: nextDir });
  }

  return (
    <div className={['w-full overflow-x-auto', className].filter(Boolean).join(' ')}>
      <table className="w-full border-collapse text-[length:var(--text-body-sm-size)]">
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
                    'px-3 py-2 font-semibold text-muted',
                    ALIGN_CLASS[align],
                  ].join(' ')}
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
                  <td key={col.key} className={['px-3 py-2 text-primary', ALIGN_CLASS[align]].join(' ')}>
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
