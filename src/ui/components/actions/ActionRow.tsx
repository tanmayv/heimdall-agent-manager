import React from 'react';
import {
  Badge,
  Toggle,
  Checkbox,
  ResourceEntryCard,
  StatusPill,
  TOUCH_TARGET_CLASS,
  useViewport,
  type ResourceMenuAction,
} from '@ui';
import { useSetActionEnabledMutation, type Action } from '../../api/endpoints/actions';
import { triggerSummary } from './scheduleUtils';
import { targetLabel, type ActionCatalog } from './actionCatalog';
import {
  VERB_LABEL,
  actionSnippet,
  actionState,
  actionTitle,
  nextRunLabel,
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
  const [setEnabled, enabledState] = useSetActionEnabledMutation();

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
              data-debug-id={`action-row-select-${actionId}`}
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
          {row.triggers.map((t, i) => <Badge key={t.id || i} data-debug-id={`action-row-trigger-${t.id || i}`}>{triggerSummary(t)}</Badge>)}
          <span data-row-control onClick={e => e.stopPropagation()}>
            <Toggle checked={row.enabled} disabled={enabledState.isLoading} aria-label={'Enable ' + title} data-debug-id={`action-row-enabled-${actionId}`} onChange={enabled => void setEnabled({ id: actionId, enabled }).unwrap().catch(() => {})} />
          </span>
          {enabledState.error ? <span role="alert">Couldn't change enabled state.</span> : null}

        </>
      }
      timestamp={nextRun.text}
      timestampTooltip={nextRun.title}
      menuActions={menuActions.length > 0 ? menuActions : undefined}
    />
  );
}

export default ActionRow;
