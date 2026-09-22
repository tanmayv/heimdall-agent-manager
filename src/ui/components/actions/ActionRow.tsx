/**
 * ActionRow — one scheduled/on-demand prompt in the list, on every viewport.
 * ------------------------------------------------------------------
 * Amendment 6's four-line anatomy, inherited from MemoryRow/AgentRow:
 *
 *     row 1   first line of the prompt .......................  [ … ]
 *     row 2   the rest of the prompt, line 1
 *     row 3   the rest of the prompt, line 2
 *     row 4   [target] [schedule] [state] ............  in 12m
 *
 * What differs for an action:
 *  - **There is no name field.** The title is the prompt's first line and the body
 *    is the remainder, so a one-line prompt legitimately has an empty body. The two
 *    lines stay reserved regardless, or the pills ride up on short rows.
 *  - **The bottom-right time is the NEXT RUN, not `updated_at`** — a future time.
 *    The hub sorts this list `ORDER BY target_run_at ASC`, so a past edit timestamp
 *    here would be a number unrelated to the order being read down the page. The
 *    absolute form, in the action's own timezone, is in the `title`.
 *    Deliberate divergence; see actionModel's header.
 *  - Pills are target · schedule · state · blackout count. The target needs a
 *    catalog lookup (the wire carries only ids) and degrades to the id.
 */
import React from 'react';
import { ActionButton, Badge, Checkbox, Menu, MenuItem, StatusPill, Text, TOUCH_TARGET_CLASS, useViewport } from '@ui';
import type { Action } from '../../api/endpoints/actions';
import { targetLabel, type ActionCatalog } from './actionCatalog';
import {
  VERB_LABEL,
  actionSnippet,
  actionState,
  actionTitle,
  blackoutCount,
  nextRunLabel,
  scheduleLabel,
  stateLabel,
  stateTone,
  verbsForState,
  type ActionVerb,
} from './actionModel';

const BODY_TWO_LINES = 'calc(2 * var(--text-body-sm-size) * var(--text-body-sm-leading))';

export interface ActionRowProps {
  row: Action;
  catalog: ActionCatalog;
  href: string;
  selected: boolean;
  active?: boolean;
  selectable: boolean;
  showCheckbox: boolean;
  onSelectedChange: (next: boolean) => void;
  onVerb: (row: Action, verb: ActionVerb) => void;
  onOpen: (row: Action) => void;
  busy?: boolean;
}

export function ActionRow({
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
}: ActionRowProps) {
  const viewport = useViewport();
  const isMobile = viewport === 'mobile';
  const state = actionState(row);
  const menuVerbs = verbsForState(state);
  const actionId = row.id;
  const title = actionTitle(row);
  const snippet = actionSnippet(row);
  const nextRun = nextRunLabel(row);
  const blackouts = blackoutCount(row);

  function handleRowClick(e: React.MouseEvent) {
    if (e.defaultPrevented || e.button !== 0) return;
    if (e.metaKey || e.ctrlKey || e.shiftKey || e.altKey) return;
    if ((e.target as HTMLElement).closest('[data-row-control]')) return;
    e.preventDefault();
    onOpen(row);
  }

  return (
    <li
      data-action-row={actionId}
      data-debug-id={`action-row-${actionId}`}
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
        {/* ---- row 1: the prompt's first line, and the overflow trigger ---- */}
        <div className="flex items-start gap-2">
          <a
            href={href}
            onClick={(e) => {
              if (e.metaKey || e.ctrlKey || e.shiftKey || e.altKey || e.button !== 0) return;
              e.preventDefault();
              onOpen(row);
            }}
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
                    iconOnly
                    aria-label={`Actions for ${title}`}
                    loading={busy}
                    data-debug-id={`action-row-menu-${actionId}`}
                  />
                }
              >
                {menuVerbs.map((verb) => (
                  <MenuItem
                    key={verb}
                    danger={verb === 'delete'}
                    data-debug-id={`action-row-${verb}-menu-${actionId}`}
                    onClick={() => onVerb(row, verb)}
                  >
                    {VERB_LABEL[verb]}
                  </MenuItem>
                ))}
              </Menu>
            </span>
          ) : null}
        </div>

        {/* ---- rows 2-3: the rest of the prompt, two lines then ellipsis ---- */}
        <p
          className="mt-0.5 overflow-hidden text-body-sm text-muted [display:-webkit-box] [-webkit-box-orient:vertical] [-webkit-line-clamp:2]"
          style={{ minHeight: BODY_TWO_LINES }}
          data-debug-id={`action-row-body-${actionId}`}
        >
          {snippet && snippet.trim() ? snippet : <span className="italic text-faint select-none">&lt;empty&gt;</span>}
        </p>

        {/* ---- row 4: pills left, next run hard right ---- */}
        <div className="mt-1.5 flex items-end justify-between gap-3">
          <div className="flex min-w-0 flex-wrap items-center gap-2">
            <Badge
              data-debug-id={`action-row-target-${actionId}`}
              className="max-w-[9rem] truncate"
              title={targetLabel(row, catalog)}
            >
              {targetLabel(row, catalog)}
            </Badge>
            {/* An irregular cron can describe itself at length. The caps keep the two
                always-present pills on ONE line inside the 420px two-pane column —
                without them a wide schedule pushed the state pill onto a second row
                and the four-line anatomy became five. Full text stays in `title`. */}
            <Badge
              data-debug-id={`action-row-schedule-${actionId}`}
              className="max-w-[12rem] truncate"
              title={scheduleLabel(row)}
            >
              {scheduleLabel(row)}
            </Badge>
            {state !== 'active' ? (
              <StatusPill tone={stateTone(state)} data-debug-id={`action-row-state-${actionId}`}>
                {stateLabel(state)}
              </StatusPill>
            ) : null}
            {blackouts > 0 ? (
              <StatusPill tone="warning" data-debug-id={`action-row-blackouts-${actionId}`}>
                {blackouts} blackout {blackouts === 1 ? 'date' : 'dates'}
              </StatusPill>
            ) : null}
          </div>
          <Text
            as="span"
            role="caption"
            tone="muted"
            className="shrink-0 whitespace-nowrap"
            title={nextRun.title}
            data-debug-id={`action-row-time-${actionId}`}
          >
            {nextRun.text}
          </Text>
        </div>
      </div>
    </li>
  );
}

export default ActionRow;
