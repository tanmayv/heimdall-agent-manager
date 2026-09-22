/**
 * DataList — the responsive list shell: columns on desktop, cards on mobile.
 * ------------------------------------------------------------------
 * Purpose: the one component every resource list renders through (REQ-UI-2 /
 * REQ-UI-13). `Table` renders real, accessible tabular data and nothing else — it
 * has no selection model, no row click target, no per-row action slot and no mobile
 * fallback. `DataList` adds exactly those four things by **wrapping** `Table` and
 * `Checkbox`. It does not replace `Table` and does not touch its API: callers reach
 * for `DataList`, and `Table` stays the right answer for a static data table.
 *
 * NOT for: a static table with no selection or drill-down (use `Table`), or a grid of
 * cards on every viewport (that is a layout, not a list).
 *
 * Layer: composite. Product-agnostic — it holds no knowledge of any resource.
 *
 * Responsive contract: at ≤767px (`useIsMobile`) the table is replaced by a card
 * list. Each column declares how it survives the squeeze via `mobileRole`:
 *   - `'title'` — the card's first line, two-line clamp, and the tap target.
 *   - `'meta'`  — the second line, inline, in `mobilePriority` order.
 *   - `'detail'`— its own line below, elided.
 *   - omitted   — dropped on mobile (the wide Summary column, and anything else that
 *                 cannot pay for its width).
 * Exactly what survives is the caller's decision, declared once per column rather
 * than forked into a second mobile component.
 *
 * Row click target: NOT a clickable `<tr>` (a well-known a11y dead end — no role, no
 * keyboard, no middle-click). The primary column's content is wrapped in a real `<a>`
 * when `getRowHref` is given, else a real `<button>` when `onRowClick` is. On mobile
 * the whole card is that one element, so the tap target is the full card width.
 *
 * Selection (REQ-UI-7 / REQ-UI-19): one model for both viewports — `selectedIds` +
 * `onSelectionChange`. Checkboxes are PERSISTENT on desktop, never hover-revealed. On
 * touch they appear only in `selectMode`, which the caller drives from the page header
 * (see `BulkActionBar.SelectToggle`). `isRowSelectable` lets a read-only row opt out,
 * and select-all then skips it, so a bulk verb can never partly fail on a row that was
 * never actionable.
 *
 * Accessibility (built in): the desktop table keeps `Table`'s real table semantics;
 * the mobile list is a real `<ul>`/`<li>`; the select-all box carries a mixed state via
 * `indeterminate`; every checkbox has an accessible name built from `getRowLabel`.
 *
 * Horizontal overflow (ground-truth Amendment 4): the TABLE scrolls sideways, never
 * the page. `Table` owns the `overflow-x: auto` region; `DataList` names it
 * (`role="region"` + `tabindex="0"` + the list's label) and pins the two columns a
 * user reaches for at any scroll offset — the select box (`sticky: 'start'`) and the
 * row actions (`sticky: 'end'`) — which paint an opaque token background so the rows
 * travel underneath rather than through them. No nested VERTICAL scroller: infinite
 * scroll's sentinel depends on the page scroller.
 *
 * Tokens only. Escape hatch: `className` merges onto the root.
 */
import React from 'react';
import { Checkbox } from '../primitives/Checkbox';
import { Table } from './Table';
import type { TableColumn } from './Table';
import { useIsMobile, TOUCH_TARGET_CLASS } from '../hooks/useViewport';
import type { Align, ChangeHandler, RootClassNameProps } from '../types';

/** How a column survives the ≤767px squeeze. Omitted = dropped on mobile. */
export type DataListMobileRole = 'title' | 'meta' | 'detail';

export interface DataListColumn<T> {
  /** Stable key; also the default cell accessor (`row[key]`). */
  key: string;
  /** Column header content. */
  header: React.ReactNode;
  /** Custom cell renderer; defaults to `String(row[key])`. */
  render?: (row: T) => React.ReactNode;
  /** Cell text alignment on desktop. Default `start`. */
  align?: Align;
  /** Where this column lands in the mobile card. Omitted = not shown on mobile. */
  mobileRole?: DataListMobileRole;
  /** Order within the card line. Lower first. Default: the column's own order. */
  mobilePriority?: number;
  /**
   * Marks the column that carries the row's identity — the link/button target, and
   * the accessible name of the row's checkbox. Defaults to the first column with
   * `mobileRole: 'title'`, else the first column.
   */
  primary?: boolean;
}

export interface DataListProps<T> extends RootClassNameProps {
  columns: DataListColumn<T>[];
  rows: T[];
  /** Stable row identity. Required — selection and keys both depend on it. */
  getRowKey: (row: T) => string;
  /** Accessible name for the list (the table caption / the `<ul>`'s label). Required. */
  label: string;

  /** Turn on the selection column. */
  selectable?: boolean;
  /** Controlled selection. Ids, in no particular order. */
  selectedIds?: string[];
  /** Fired with the next selection. */
  onSelectionChange?: ChangeHandler<string[]>;
  /** Rows that cannot be selected (read-only rows). Default: everything is selectable. */
  isRowSelectable?: (row: T) => boolean;
  /**
   * Touch select mode. On mobile, checkboxes render ONLY when this is true. Ignored on
   * desktop, where checkboxes are always present.
   */
  selectMode?: boolean;

  /** Navigation target for the row. Preferred over `onRowClick` — it is a real link. */
  getRowHref?: (row: T) => string;
  /** Activation handler when the row is not a link. */
  onRowClick?: (row: T) => void;
  /** Per-row action slot (the persistent edit button + the `⋯` menu). */
  rowActions?: (row: T) => React.ReactNode;
  /** Accessible name for a row, for the checkbox. Defaults to the primary cell's text. */
  getRowLabel?: (row: T) => string;

  /** Initial load: render skeleton rows at the real row height instead of the rows. */
  loading?: boolean;
  /** How many skeleton rows. Default 8. */
  skeletonRows?: number;
  /** Rendered instead of the list when there are no rows and it is not loading. */
  empty?: React.ReactNode;
  /** Rendered under the list — the paging skeleton, the sentinel, a retry strip. */
  footer?: React.ReactNode;
  /**
   * Minimum desktop table width before the table's own region starts scrolling
   * sideways. Default `48rem`. Raise it for a list carrying more columns.
   */
  minTableWidth?: string;
}

/** Plain-text extraction, for a checkbox's accessible name when none is supplied. */
function nodeText(node: React.ReactNode): string {
  if (node === null || node === undefined || typeof node === 'boolean') return '';
  if (typeof node === 'string' || typeof node === 'number') return String(node);
  if (Array.isArray(node)) return node.map(nodeText).join('');
  if (React.isValidElement(node)) return nodeText((node.props as { children?: React.ReactNode }).children);
  return '';
}

/**
 * The select-all box. `indeterminate` is a DOM property with no React attribute, so
 * it is set through the ref that `Checkbox` forwards to its `<input>`.
 */
function SelectAllCheckbox({
  checked,
  indeterminate,
  onChange,
  disabled,
}: {
  checked: boolean;
  indeterminate: boolean;
  onChange: ChangeHandler<boolean>;
  disabled?: boolean;
}) {
  const ref = React.useRef<HTMLInputElement | null>(null);
  React.useEffect(() => {
    if (ref.current) ref.current.indeterminate = indeterminate;
  }, [indeterminate]);
  return (
    <Checkbox
      ref={ref}
      checked={checked}
      onChange={onChange}
      disabled={disabled}
      aria-label={indeterminate || checked ? 'Clear selection' : 'Select all loaded rows'}
    />
  );
}

export function DataList<T>({
  columns,
  rows,
  getRowKey,
  label,
  selectable = false,
  selectedIds,
  onSelectionChange,
  isRowSelectable,
  selectMode = false,
  getRowHref,
  onRowClick,
  rowActions,
  getRowLabel,
  loading = false,
  skeletonRows = 8,
  empty,
  footer,
  minTableWidth = '48rem',
  className,
}: DataListProps<T>) {
  const isMobile = useIsMobile();
  const selected = React.useMemo(() => new Set(selectedIds ?? []), [selectedIds]);

  // Checkboxes are persistent on desktop and select-mode-gated on touch (REQ-UI-19:
  // no hover-revealed affordance anywhere).
  const showCheckboxes = selectable && (!isMobile || selectMode);

  const canSelect = React.useCallback(
    (row: T) => (isRowSelectable ? isRowSelectable(row) : true),
    [isRowSelectable],
  );

  const selectableRows = React.useMemo(() => rows.filter(canSelect), [rows, canSelect]);
  const selectableIds = React.useMemo(
    () => selectableRows.map(getRowKey),
    [selectableRows, getRowKey],
  );
  const selectedSelectableCount = selectableIds.filter((id) => selected.has(id)).length;
  const allSelected = selectableIds.length > 0 && selectedSelectableCount === selectableIds.length;
  const someSelected = selectedSelectableCount > 0 && !allSelected;

  const primaryKey =
    columns.find((col) => col.primary)?.key ??
    columns.find((col) => col.mobileRole === 'title')?.key ??
    columns[0]?.key;

  function renderCell(col: DataListColumn<T>, row: T): React.ReactNode {
    return col.render ? col.render(row) : String((row as Record<string, unknown>)[col.key] ?? '');
  }

  function rowLabel(row: T): string {
    if (getRowLabel) return getRowLabel(row);
    const primary = columns.find((col) => col.key === primaryKey);
    return primary ? nodeText(renderCell(primary, row)) || getRowKey(row) : getRowKey(row);
  }

  function toggleRow(row: T, next: boolean) {
    if (!onSelectionChange) return;
    const id = getRowKey(row);
    const out = new Set(selected);
    if (next) out.add(id);
    else out.delete(id);
    onSelectionChange(Array.from(out));
  }

  /**
   * Select-all covers the rows currently LOADED, never "all matching" — there is no
   * total in any list API, so "all" would be a promise the API cannot keep.
   */
  function toggleAll(next: boolean) {
    if (!onSelectionChange) return;
    const out = new Set(selected);
    for (const id of selectableIds) {
      if (next) out.add(id);
      else out.delete(id);
    }
    onSelectionChange(Array.from(out));
  }

  /** Wraps the primary cell (desktop) or the whole card (mobile) in the tap target. */
  function activatable(row: T, content: React.ReactNode, extraClassName = ''): React.ReactNode {
    const base = ['text-left rounded-[var(--radius-sm)] focus-visible:shadow-focus focus-visible:outline-none', extraClassName]
      .filter(Boolean)
      .join(' ');
    if (getRowHref) {
      return (
        <a href={getRowHref(row)} className={`${base} text-primary hover:text-accent`}>
          {content}
        </a>
      );
    }
    if (onRowClick) {
      return (
        <button type="button" onClick={() => onRowClick(row)} className={`${base} text-primary hover:text-accent`}>
          {content}
        </button>
      );
    }
    return content;
  }

  const rootClassName = ['w-full', className].filter(Boolean).join(' ');

  /* ---------------------------------------------------------------- *
   * Loading — skeletons at the real row height, never a spinner, never
   * a layout shift.
   * ---------------------------------------------------------------- */
  if (loading) {
    return (
      <div className={rootClassName} role="status" aria-live="polite" aria-busy="true">
        <span className="sr-only">Loading {label}…</span>
        <div className="flex flex-col divide-y divide-subtle" aria-hidden="true">
          {Array.from({ length: skeletonRows }).map((_, i) => (
            // Built from the SAME box model as a real row/card — the row's own padding
            // and one bar per line of text — so the skeleton lands at the real row
            // height without hard-coding one, and paging in the rows shifts nothing.
            <div key={i} className={isMobile ? 'flex flex-col gap-1 py-3' : 'flex items-center py-2'}>
              <div className="h-5 w-3/4 animate-pulse rounded-[var(--radius-sm)] bg-neutral-soft" />
              {isMobile ? (
                <>
                  <div className="h-4 w-1/2 animate-pulse rounded-[var(--radius-sm)] bg-neutral-soft" />
                  <div className="h-4 w-2/3 animate-pulse rounded-[var(--radius-sm)] bg-neutral-soft" />
                </>
              ) : null}
            </div>
          ))}
        </div>
      </div>
    );
  }

  if (rows.length === 0) {
    return (
      <div className={rootClassName}>
        {empty}
        {footer}
      </div>
    );
  }

  /* ---------------------------------------------------------------- *
   * Mobile — a card list. Two lines of text plus an optional detail line.
   * ---------------------------------------------------------------- */
  if (isMobile) {
    const byRole = (role: DataListMobileRole) =>
      columns
        .map((col, index) => ({ col, index }))
        .filter((entry) => entry.col.mobileRole === role)
        .sort((a, b) => (a.col.mobilePriority ?? a.index) - (b.col.mobilePriority ?? b.index))
        .map((entry) => entry.col);

    const titleCols = byRole('title');
    const metaCols = byRole('meta');
    const detailCols = byRole('detail');

    return (
      <div className={rootClassName}>
        <ul aria-label={label} className="flex flex-col divide-y divide-subtle">
          {rows.map((row) => {
            const id = getRowKey(row);
            const selectableRow = canSelect(row);
            return (
              <li key={id} className="flex items-start gap-3 py-3">
                {showCheckboxes ? (
                  <span className={`flex shrink-0 items-center justify-center ${TOUCH_TARGET_CLASS}`}>
                    <Checkbox
                      checked={selected.has(id)}
                      onChange={(next) => toggleRow(row, next)}
                      disabled={!selectableRow}
                      aria-label={`Select ${rowLabel(row)}`}
                    />
                  </span>
                ) : null}

                <div className="min-w-0 flex-1">
                  {activatable(
                    row,
                    <>
                      {titleCols.map((col) => (
                        <div
                          key={col.key}
                          className="text-title [display:-webkit-box] [-webkit-box-orient:vertical] [-webkit-line-clamp:2] overflow-hidden"
                        >
                          {renderCell(col, row)}
                        </div>
                      ))}
                      {metaCols.length ? (
                        <div className="mt-1 flex flex-wrap items-center gap-2 text-label text-muted">
                          {metaCols.map((col) => (
                            <span key={col.key} className="inline-flex min-w-0 items-center">
                              {renderCell(col, row)}
                            </span>
                          ))}
                        </div>
                      ) : null}
                      {detailCols.map((col) => (
                        <div key={col.key} className="mt-1 truncate text-label text-muted">
                          {renderCell(col, row)}
                        </div>
                      ))}
                    </>,
                    'block w-full',
                  )}
                </div>

                {rowActions ? <div className="flex shrink-0 items-center">{rowActions(row)}</div> : null}
              </li>
            );
          })}
        </ul>
        {footer}
      </div>
    );
  }

  /* ---------------------------------------------------------------- *
   * Desktop — `Table`, with the select column prepended and the action
   * column appended. `Table` itself is unmodified.
   * ---------------------------------------------------------------- */
  const tableColumns: TableColumn<T>[] = [];

  if (showCheckboxes) {
    tableColumns.push({
      key: '__select',
      sticky: 'start',
      cellClassName: 'w-px',
      header: (
        <SelectAllCheckbox
          checked={allSelected}
          indeterminate={someSelected}
          onChange={toggleAll}
          disabled={selectableIds.length === 0}
        />
      ),
      render: (row) => {
        const id = getRowKey(row);
        return (
          <Checkbox
            checked={selected.has(id)}
            onChange={(next) => toggleRow(row, next)}
            disabled={!canSelect(row)}
            aria-label={`Select ${rowLabel(row)}`}
          />
        );
      },
    });
  }

  for (const col of columns) {
    const isPrimary = col.key === primaryKey;
    tableColumns.push({
      key: col.key,
      header: col.header,
      align: col.align,
      // One hierarchy per row: the title is the scanning target, so it is the only
      // thing at full contrast and weight; every other column recedes in colour as
      // well as in weight, rather than competing with it.
      // The primary column is the one that YIELDS: `w-full max-w-0` makes the title
      // cell absorb the slack and truncate, so the narrow columns (type, status,
      // updated) keep their content width and the table only starts scrolling when
      // even a truncated title cannot buy enough room.
      cellClassName: isPrimary ? 'w-1/2 max-w-0 text-primary' : 'whitespace-nowrap text-muted',
      headerClassName: isPrimary ? 'w-1/2 max-w-0' : undefined,
      render: (row) => {
        const content = renderCell(col, row);
        if (!isPrimary) return content;
        return activatable(row, <span className="text-title">{content}</span>, 'inline-block max-w-full truncate');
      },
    });
  }

  if (rowActions) {
    tableColumns.push({
      key: '__actions',
      sticky: 'end',
      cellClassName: 'w-px whitespace-nowrap',
      header: <span className="sr-only">Actions</span>,
      align: 'end',
      render: (row) => <div className="flex items-center justify-end gap-1">{rowActions(row)}</div>,
    });
  }

  return (
    <div className={rootClassName}>
      <Table<T>
        columns={tableColumns}
        rows={rows}
        getRowKey={(row) => getRowKey(row)}
        caption={label}
        scrollRegionLabel={`${label} (scrolls horizontally)`}
        minWidth={minTableWidth}
      />
      {footer}
    </div>
  );
}

export default DataList;
