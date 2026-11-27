/**
 * BridgeSection — section 2 "Runs on" of the Agent settings panel (see DESIGN.md).
 *
 * A radiogroup with one row per owned, non-revoked bridge: a 36px icon well, the
 * bridge name (mono) with a "Current" badge, a status line (dot + "Connected · <OS>",
 * "Offline", or "No folder for this project" in warning), and the project's folder on
 * that bridge. Offline bridges and bridges without the folder are disabled at 45%.
 * Picking a row edits the DRAFT only (`onSelect`); the rows come from
 * `bridgeRowsView` (agentSettingsDraft.ts).
 */
import React from 'react';
import { Badge, Icon, IconWell, Link, Text } from '@ui';
import { AgentPanelSection } from './AgentSettingsPanel';
import type { BridgeRowsView } from './agentSettingsDraft';
import { radioGroupKeyDown, radioTabStop } from './radioGroup';

export interface BridgeSectionProps {
  view: BridgeRowsView;
  /** The draft's bridge. */
  selected: string;
  onSelect: (bridgeId: string) => void;
  /** The project's bridge paths page; omitted when the agent has no project. */
  manageFoldersHref?: string;
  disabled?: boolean;
  /** Bridges are still loading. */
  loading?: boolean;
  touch?: boolean;
}

const STATUS_DOT: Record<string, string> = {
  connected: 'bg-success',
  offline: 'bg-faint',
  no_folder: 'bg-warning',
};

export function BridgeSection({ view, selected, onSelect, manageFoldersHref, disabled = false, loading = false, touch = false }: BridgeSectionProps) {
  const items = view.rows.map((row) => ({ value: row.bridgeId, disabled: disabled || row.disabled }));
  const tabStop = radioTabStop(items, selected);
  const select = (bridgeId: string) => {
    const item = items.find((i) => i.value === bridgeId);
    if (item && !item.disabled && bridgeId !== selected) onSelect(bridgeId);
  };

  return (
    <AgentPanelSection
      id="bridge"
      label="Runs on"
      trailing={view.total > 0 ? (
        <Text as="span" role="body-sm" tone="muted" data-debug-id="agent-panel-bridge-count">{view.header}</Text>
      ) : null}
    >
      {view.rows.length === 0 ? (
        <Text role="body-sm" tone="muted" className="rounded-[var(--radius-lg)] border border-subtle bg-surface-raised p-4">
          {loading ? 'Loading bridges…' : 'No bridges yet.'}
        </Text>
      ) : (
        <div
          role="radiogroup"
          aria-labelledby="agent-panel-bridge-heading"
          aria-disabled={disabled || undefined}
          onKeyDown={radioGroupKeyDown(items, selected, select)}
          className="overflow-hidden rounded-[var(--radius-lg)] border border-subtle bg-surface-raised"
        >
          {view.rows.map((row, index) => {
            const checked = row.bridgeId === selected;
            const rowDisabled = disabled || row.disabled;
            const statusId = `agent-panel-bridge-${row.bridgeId}-status`;
            return (
              <div
                key={row.bridgeId}
                role="radio"
                aria-checked={checked}
                aria-disabled={rowDisabled || undefined}
                aria-describedby={statusId}
                tabIndex={row.bridgeId === tabStop ? 0 : -1}
                data-radio-value={row.bridgeId}
                data-debug-id={`agent-panel-bridge-option-${row.bridgeId}`}
                data-status={row.status}
                onClick={() => select(row.bridgeId)}
                onKeyDown={(event) => {
                  if (event.key === ' ' || event.key === 'Enter') {
                    event.preventDefault();
                    select(row.bridgeId);
                  }
                }}
                className={[
                  'flex items-center gap-3 px-4 py-3 text-left outline-none focus-visible:shadow-focus',
                  touch ? 'min-h-11' : '',
                  index > 0 ? 'border-t border-subtle' : '',
                  checked ? 'bg-surface-overlay' : '',
                  rowDisabled ? 'cursor-not-allowed opacity-[0.45]' : 'cursor-pointer',
                ].filter(Boolean).join(' ')}
              >
                <IconWell icon="device" className="!h-9 !w-9" />
                <div className="min-w-0 flex-1">
                  <div className="flex min-w-0 items-center gap-2">
                    <Text as="span" role="code" className="truncate text-primary">{row.label}</Text>
                    {row.current ? <Badge data-debug-id="agent-panel-bridge-current">Current</Badge> : null}
                  </div>
                  <Text
                    as="div"
                    role="body-sm"
                    id={statusId}
                    tone={row.status === 'no_folder' ? undefined : 'muted'}
                    className={`flex items-center gap-1.5 ${row.status === 'no_folder' ? 'text-warning' : ''}`}
                  >
                    <span aria-hidden="true" className={`h-1.5 w-1.5 shrink-0 rounded-full ${STATUS_DOT[row.status]}`} />
                    {row.statusText}
                  </Text>
                  {row.folder ? (
                    <Text as="div" role="code-sm" tone="muted" className="flex min-w-0 items-center gap-1.5" title={row.folder}>
                      <Icon name="folder" size={12} className="shrink-0" />
                      <span className="truncate">{row.folder}</span>
                    </Text>
                  ) : null}
                </div>
                {checked ? <Icon name="check" size="sm" className="shrink-0 text-accent" /> : null}
              </div>
            );
          })}
        </div>
      )}
      <Text role="body-sm" tone="muted" data-debug-id="agent-panel-bridge-help">
        A bridge needs this project&apos;s folder to run the agent.
        {manageFoldersHref ? (
          <>
            {' '}
            <Link href={manageFoldersHref} data-debug-id="agent-panel-bridge-manage-folders" className={touch ? 'inline-flex min-h-11 items-center' : ''}>
              Manage project folders
            </Link>
          </>
        ) : null}
      </Text>
    </AgentPanelSection>
  );
}

export default BridgeSection;
