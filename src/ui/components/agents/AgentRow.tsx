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
import { ActionButton, Badge, Checkbox, Menu, MenuItem, StatusPill, Text, TOUCH_TARGET_CLASS, useViewport } from '@ui';
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

const BODY_TWO_LINES = 'calc(2 * var(--text-body-sm-size) * var(--text-body-sm-leading))';

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

  function handleRowClick(e: React.MouseEvent) {
    if (e.defaultPrevented || e.button !== 0) return;
    if (e.metaKey || e.ctrlKey || e.shiftKey || e.altKey) return;
    if ((e.target as HTMLElement).closest('[data-row-control]')) return;
    e.preventDefault();
    onOpen(row);
  }

  return (
    <li
      data-agent-row={agentId}
      data-debug-id={`agent-row-${agentId}`}
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
        {/* ---- row 1: name and overflow trigger ---- */}
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
                    data-debug-id={`agent-row-menu-${agentId}`}
                  />
                }
              >
                {menuVerbs.map((verb) => (
                  <MenuItem
                    key={verb}
                    danger={verb === 'archive'}
                    data-debug-id={`agent-row-${verb}-menu-${agentId}`}
                    onClick={() => onVerb(row, verb)}
                  >
                    {VERB_LABEL[verb]}
                  </MenuItem>
                ))}
              </Menu>
            </span>
          ) : null}
        </div>

        {/* ---- rows 2-3: instructions, two lines then ellipsis ---- */}
        <p
          className="mt-0.5 overflow-hidden text-body-sm text-muted [display:-webkit-box] [-webkit-box-orient:vertical] [-webkit-line-clamp:2]"
          style={{ minHeight: BODY_TWO_LINES }}
          data-debug-id={`agent-row-body-${agentId}`}
        >
          {snippet && snippet.trim() ? snippet : <span className="italic text-faint select-none">&lt;empty&gt;</span>}
        </p>

        {/* ---- row 4: pills left, relative time hard right ---- */}
        <div className="mt-1.5 flex items-end justify-between gap-3">
          <div className="flex min-w-0 flex-wrap items-center gap-2">
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
          </div>
          <Text
            as="span"
            role="caption"
            tone="muted"
            className="shrink-0 whitespace-nowrap"
            title={absoluteTime(row.updatedAt)}
            data-debug-id={`agent-row-time-${agentId}`}
          >
            {relativeTime(row.updatedAt)}
          </Text>
        </div>
      </div>
    </li>
  );
}

export default AgentRow;
