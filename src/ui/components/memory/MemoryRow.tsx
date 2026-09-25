/**
 * MemoryRow — one memory in the list, on every viewport.
 * ------------------------------------------------------------------
 * Refactored to adopt ResourceEntryCard from @ui while preserving:
 * - data-memory-row for cursor navigation & scroll restoration
 * - Selection checkbox for bulk operations
 * - 2-line snippet preview with <empty> fallback
 * - StatusPill, Type Badge, and ScopeChips
 * - Relative time with absolute hover tooltip
 * - Context menu actions for available verbs
 */
import React from 'react';
import {
  Badge,
  Checkbox,
  ResourceEntryCard,
  ScopeChips,
  StatusPill,
  TOUCH_TARGET_CLASS,
  useViewport,
} from '@ui';
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
import { VaultText } from '../vault/VaultText';

export interface MemoryRowProps {
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
  const menuVerbs = verbsForStatus(status);
  const memoryId = String(row.memoryId || row.id || '');
  const title = memoryTitle(row);
  const snippet = memorySnippet(row);

  const menuActions = menuVerbs.map((verb) => ({
    label: VERB_LABEL[verb],
    danger: verb === 'reject' || verb === 'archive',
    debugId: `memory-row-${verb}-menu-${memoryId}`,
    onClick: () => onVerb(row, verb),
  }));

  return (
    <ResourceEntryCard
      id={memoryId}
      data-memory-row={memoryId}
      dataDebugId={`memory-row-${memoryId}`}
      bodyDebugId={`memory-row-body-${memoryId}`}
      timeDebugId={`memory-row-time-${memoryId}`}
      title={<VaultText value={title} as="span" />}
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
      snippet={
        snippet && snippet.trim() ? (
          <VaultText value={snippet} as="span" />
        ) : (
          <span className="italic text-faint select-none">&lt;empty&gt;</span>
        )
      }
      status={<StatusPill tone={statusTone(status)}>{statusLabel(status)}</StatusPill>}
      badges={
        <>
          <Badge>{String(row.type || 'fact')}</Badge>
          <ScopeChips
            targeting={targetingFromRecord(row)}
            catalog={catalog}
            max={2}
            debugId={`memory-row-scope-${memoryId}`}
          />
        </>
      }
      timestamp={relativeTime(row.updatedAt)}
      timestampTooltip={absoluteTime(row.updatedAt)}
      menuActions={menuActions.length > 0 ? menuActions : undefined}
    />
  );
}

export default MemoryRow;
