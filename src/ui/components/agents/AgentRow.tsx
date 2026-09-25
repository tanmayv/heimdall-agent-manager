/**
 * AgentRow — one agent identity in the list, on every viewport.
 * ------------------------------------------------------------------
 * Amendment 6's four-line anatomy, inherited from MemoryRow/ProjectRow:
 *
 *     row 1   Name ..........................................  [ … ]
 *     row 2   instructions line 1
 *     row 3   instructions line 2
 *     row 4   [provider] [tier] [N running] .........  12m ago
 *
 * What differs for an agent:
 *  - Pills are provider · tier · active-instance count · (Archived).
 *    Provider and tier identify the agent's model config at a glance.
 *    Active-instance count shows whether the agent is live right now.
 *  - There is no path chip (agents are not filesystem-bound).
 *  - "Active" pill is suppressed on the Active tab — see ProjectRow.
 *  - No per-row Launch button. Launch needs bridge+provider+tier input
 *    and belongs on the view page header only.
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
import type { AgentRecord } from '../../api/endpoints/agents';
import {
  VERB_LABEL,
  absoluteTime,
  agentSnippet,
  agentState,
  agentTitle,
  relativeTime,
  stateLabel,
  stateTone,
  verbsForState,
  type AgentVerb,
} from './agentModel';

export interface AgentRowProps {
  row: AgentRecord;
  href: string;
  selected: boolean;
  active?: boolean;
  selectable: boolean;
  showCheckbox: boolean;
  onSelectedChange: (next: boolean) => void;
  onVerb: (row: AgentRecord, verb: AgentVerb) => void;
  onOpen: (row: AgentRecord) => void;
  busy?: boolean;
}

export function AgentRow({
  row,
  href,
  selected,
  active = false,
  selectable,
  showCheckbox,
  onSelectedChange,
  onVerb,
  onOpen,
  busy = false,
}: AgentRowProps) {
  const viewport = useViewport();
  const isMobile = viewport === 'mobile';
  const state = agentState(row);
  const menuVerbs = verbsForState(state);
  const agentId = row.agentId;
  const title = agentTitle(row);
  const snippet = agentSnippet(row);

  const menuActions: ResourceMenuAction[] = menuVerbs.map((verb) => ({
    label: VERB_LABEL[verb],
    danger: verb === 'archive',
    debugId: `agent-row-${verb}-menu-${agentId}`,
    onClick: () => onVerb(row, verb),
  }));

  return (
    <ResourceEntryCard
      id={agentId}
      data-agent-row={agentId}
      dataDebugId={`agent-row-${agentId}`}
      bodyDebugId={`agent-row-body-${agentId}`}
      timeDebugId={`agent-row-time-${agentId}`}
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
          {row.defaultProvider ? (
            <Badge data-debug-id={`agent-row-provider-${agentId}`}>{row.defaultProvider}</Badge>
          ) : null}
          {row.defaultTier ? (
            <Badge data-debug-id={`agent-row-tier-${agentId}`}>{row.defaultTier}</Badge>
          ) : null}
          {row.activeInstanceCount > 0 ? (
            <StatusPill tone="success" data-debug-id={`agent-row-instances-${agentId}`}>
              {row.activeInstanceCount} running
            </StatusPill>
          ) : null}
          {state === 'archived' ? (
            <StatusPill tone={stateTone(state)} data-debug-id={`agent-row-state-${agentId}`}>
              {stateLabel(state)}
            </StatusPill>
          ) : null}
        </>
      }
      timestamp={relativeTime(row.updatedAt)}
      timestampTooltip={absoluteTime(row.updatedAt)}
      menuActions={menuActions.length > 0 ? menuActions : undefined}
    />
  );
}

export default AgentRow;
