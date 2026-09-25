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
import {
  Badge,
  Checkbox,
  ResourceEntryCard,
  StatusPill,
  TOUCH_TARGET_CLASS,
  useViewport,
  type ResourceMenuAction,
} from '@ui';
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

  const menuActions: ResourceMenuAction[] = menuVerbs.map((verb) => ({
    label: VERB_LABEL[verb],
    danger: verb === 'delete',
    debugId: `action-row-${verb}-menu-${actionId}`,
    onClick: () => onVerb(row, verb),
  }));

  return (
    <ResourceEntryCard
      id={actionId}
      data-action-row={actionId}
      dataDebugId={`action-row-${actionId}`}
      bodyDebugId={`action-row-body-${actionId}`}
      timeDebugId={`action-row-time-${actionId}`}
      title={title}
      href={href}
      active={active}
      onSelect={() => onOpen(row)}
      leading={
        showCheckbox ? (
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
        ) : null
      }
      snippet={snippet && snippet.trim() ? snippet : <span className="italic text-faint select-none">&lt;empty&gt;</span>}
      badges={
        <>
          <Badge
            data-debug-id={`action-row-target-${actionId}`}
            className="max-w-[9rem] truncate"
            title={targetLabel(row, catalog)}
          >
            {targetLabel(row, catalog)}
          </Badge>
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
        </>
      }
      timestamp={nextRun.text}
      timestampTooltip={nextRun.title}
      menuActions={menuActions.length > 0 ? menuActions : undefined}
    />
  );
}

export default ActionRow;
