/**
 * MemoryRow — one memory in the list, on every viewport.
 * ------------------------------------------------------------------
 * The redesign replaces the column table with a row list. The anatomy is the
 * user's own, and it supersedes the spec's "title + one-line snippet + meta line":
 *
 *     row 1   Title ...........................................  [ … ]
 *     row 2   body line 1
 *     row 3   body line 2
 *     row 4   [pill] [pill] [pill] ......................  12m ago
 *
 * Row 1 pairs the title with the overflow trigger. Rows 2-3 give the body TWO
 * lines before it ellipsizes ("ensure body can span two lines and not truncate
 * just on one"). Row 4 puts the pills hard left and the relative time hard right.
 * 72px is a FLOOR here, not a target — four lines take what they take.
 *
 * **Rows carry a single "…" menu and nothing else.** No inline Approve/Reject, no
 * hover-revealed cluster — "hide the hover to show button. Only selection would
 * show approve and reject button or within ...". Approve and Reject live in exactly
 * two places on this page: this menu, and the bulk bar during selection. Inside the
 * menu they are WORDS, so a destructive verb is read rather than guessed from a
 * glyph. The detail header keeps its own Approve / Reject / "…" per the spec.
 *
 * Lives here, not in `@ui`: it knows what a memory is. The generic pieces it stands
 * on (`ScopeChips`, `Badge`, `StatusPill`, `ActionButton`, `Menu`) stay in `@ui`,
 * and `DataList`'s table path is untouched — Agents and Actions still need it.
 *
 * There is NO swipe gesture. It was built and then removed at the user's request —
 * "remove the slide for actions feature it doesn't work well on mobile". Nothing is
 * lost by its going: the "…" menu was always the accessible path behind it, so every
 * verb is still one tap away, discoverable, and reachable from a keyboard. A gesture
 * that only some users can find was never carrying its weight.
 */
import React from 'react';
import { ActionButton, Badge, Checkbox, Menu, MenuItem, ScopeChips, StatusPill, Text, TOUCH_TARGET_CLASS, useViewport } from '@ui';
import type { ScopeCatalog } from '@ui';
import {
  VERB_LABEL,
  absoluteTime,
  memorySnippet,
  memoryStatus,
  memoryTitle,
  relativeTime,
  statusLabel,
  statusTone,
  verbsForStatus,
  type MemoryVerb,
} from './memoryModel';
import { targetingFromRecord } from '@ui';

/**
 * Rows 2-3 are reserved whether or not this memory has a body, so a body-less row
 * does not collapse and leave its pills sitting a line higher than its neighbours'.
 * Derived from the type tokens rather than hard-coded, so it tracks the scale if the
 * body-sm role is ever retuned.
 */
const BODY_TWO_LINES = 'calc(2 * var(--text-body-sm-size) * var(--text-body-sm-leading))';

export interface MemoryRowProps {
  // TODO(FIX): Replace any with strict TypeScript interface matching Odin backend schema
  row: any;
  catalog: ScopeCatalog;
  href: string;
  selected: boolean;
  /** Highlighted because it is the memory open in the detail pane (two-pane only). */
  active?: boolean;
  selectable: boolean;
  showCheckbox: boolean;
  onSelectedChange: (next: boolean) => void;
  onVerb: (row: any, verb: MemoryVerb) => void;
  onOpen: (row: any) => void;
  busy?: boolean;
}

export function MemoryRow({
  row,
  catalog,
  href,
  selected,
  active = false,
  selectable,
  showCheckbox,
  onSelectedChange,
  onVerb,
  onOpen,
  busy = false,
}: MemoryRowProps) {
  const viewport = useViewport();
  const isMobile = viewport === 'mobile';
  const status = memoryStatus(row);
  // Every verb this status offers goes in the menu — nothing is promoted into the
  // row. `verbsForStatus` already prunes the verbs that mean nothing in a state
  // (no Archive on an archived memory, no Reject on one), so the menu never offers
  // a no-op.
  const menuVerbs = verbsForStatus(status);
  const memoryId = String(row.memoryId || row.id || '');
  const title = memoryTitle(row);
  const snippet = memorySnippet(row);

  /* -------- opening the row --------
   * The whole row is a tap target, but NOT via a stretched-link pseudo-element: an
   * overlay spanning the row would sit on top of the scope chips' "+N" affordance and
   * swallow it. Instead the row handles the click and ignores anything that started
   * inside the checkbox or the menu — tapping "…" must not also navigate, which is
   * the classic bug in this layout. The title stays a real <a>, so keyboard focus,
   * middle-click and "copy link address" all still behave like a link. */
  function handleRowClick(e: React.MouseEvent) {
    if (e.defaultPrevented || e.button !== 0) return;
    if (e.metaKey || e.ctrlKey || e.shiftKey || e.altKey) return;
    if ((e.target as HTMLElement).closest('[data-row-control]')) return;
    e.preventDefault();
    onOpen(row);
  }

  return (
    <li
      data-memory-row={memoryId}
      data-debug-id={`memory-row-${memoryId}`}
      data-active={active || undefined}
      className={[
        'relative flex min-h-[72px] items-start gap-3 border-b border-subtle px-3 py-3 transition-colors duration-fast',
        active ? 'bg-surface-raised' : 'hover:bg-surface',
      ].join(' ')}
      onClick={handleRowClick}
    >
      {showCheckbox ? (
        <span
          data-row-control
          className={`flex shrink-0 items-center ${isMobile ? TOUCH_TARGET_CLASS : ''}`}
        >
          <Checkbox
            checked={selected}
            disabled={!selectable}
            onChange={onSelectedChange}
            aria-label={`Select ${title}`}
          />
        </span>
      ) : null}

      <div className="min-w-0 flex-1">
        {/* ---- row 1: title and the overflow trigger share the line ---- */}
        <div className="flex items-start gap-2">
          <a
            href={href}
            onClick={(e) => {
              if (e.metaKey || e.ctrlKey || e.shiftKey || e.altKey || e.button !== 0) return;
              e.preventDefault();
              onOpen(row);
            }}
            // `min-w-0` is what makes the title truncate against the trigger instead
            // of pushing it off the row: without it the flex item refuses to shrink
            // below its content width.
            className="min-w-0 flex-1 truncate rounded-[var(--radius-sm)] text-title text-primary focus-visible:shadow-focus focus-visible:outline-none"
          >
            {title}
          </a>

          {menuVerbs.length ? (
            <span data-row-control className="shrink-0">
              <Menu
                label={`Actions for ${title}`}
                align="end"
                trigger={
                  <ActionButton
                    icon="more-horizontal"
                    label="More"
                    // The trigger is an icon on every viewport, and it keeps its
                    // accessible name — collapsing a control to a glyph never drops
                    // one. Inside the menu the verbs stay words.
                    iconOnly
                    aria-label={`Actions for ${title}`}
                    loading={busy}
                    data-debug-id={`memory-row-menu-${memoryId}`}
                  />
                }
              >
                {menuVerbs.map((verb) => (
                  <MenuItem
                    key={verb}
                    danger={verb === 'reject' || verb === 'archive'}
                    data-debug-id={`memory-row-${verb}-menu-${memoryId}`}
                    onClick={() => onVerb(row, verb)}
                  >
                    {VERB_LABEL[verb]}
                  </MenuItem>
                ))}
              </Menu>
            </span>
          ) : null}
        </div>

        {/* ---- rows 2-3: the body, two lines then ellipsis ---- */}
        <p
          className="mt-0.5 overflow-hidden text-body-sm text-muted [display:-webkit-box] [-webkit-box-orient:vertical] [-webkit-line-clamp:2]"
          style={{ minHeight: BODY_TWO_LINES }}
          data-debug-id={`memory-row-body-${memoryId}`}
        >
          {snippet}
        </p>

        {/* ---- row 4: pills left, relative time hard right ---- */}
        <div className="mt-1.5 flex items-end justify-between gap-3">
          <div className="flex min-w-0 flex-wrap items-center gap-2">
            <Badge>{String(row.type || 'fact')}</Badge>
            <StatusPill tone={statusTone(status)}>{statusLabel(status)}</StatusPill>
            <ScopeChips
              targeting={targetingFromRecord(row)}
              catalog={catalog}
              max={2}
              debugId={`memory-row-scope-${memoryId}`}
            />
          </div>
          <Text
            as="span"
            role="caption"
            tone="muted"
            className="shrink-0 whitespace-nowrap"
            title={absoluteTime(row.updatedAt)}
            data-debug-id={`memory-row-time-${memoryId}`}
          >
            {relativeTime(row.updatedAt)}
          </Text>
        </div>
      </div>

    </li>
  );
}

export default MemoryRow;
