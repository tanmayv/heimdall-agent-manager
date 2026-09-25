/**
 * ShellRow — one shell session in the list, on every viewport.
 * ------------------------------------------------------------------
 * Amendment 6's four-line anatomy, inherited from MemoryRow/ActionRow:
 *
 *     row 1   label (or cmd) ..................................  [ … ]
 *     row 2   cmd
 *     row 3   cwd
 *     row 4   [status] [kind] [:port] [exit N] ..........  active 12s ago
 *
 * Adopted ResourceEntryCard from the unified composite suite.
 */
import React from 'react';
import {
  ActionButton,
  Badge,
  Checkbox,
  Icon,
  Menu,
  MenuItem,
  ResourceEntryCard,
  StatusPill,
  TOUCH_TARGET_CLASS,
  useViewport,
} from '@ui';
import type { ShellSession } from '../../api/endpoints/shells';
import {
  VERB_ICON,
  VERB_LABEL,
  exitLabel,
  exitTone,
  isDestructive,
  kindLabel,
  shellBodyLines,
  shellTimeLabel,
  shellTitle,
  statusLabel,
  statusTone,
  verbsForSession,
  type ShellVerb,
} from './shellModel';

export interface ShellRowProps {
  row: ShellSession;
  href: string;
  selected: boolean;
  active?: boolean;
  selectable: boolean;
  showCheckbox: boolean;
  onSelectedChange: (next: boolean) => void;
  onVerb: (row: ShellSession, verb: ShellVerb) => void;
  onOpen: (row: ShellSession) => void;
  busy?: boolean;
}

export function ShellRow({
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
}: ShellRowProps) {
  const viewport = useViewport();
  const isMobile = viewport === 'mobile';
  const sessionId = row.session_id;
  const title = shellTitle(row);
  const body = shellBodyLines(row);
  const time = shellTimeLabel(row);
  const exit = exitLabel(row);
  const menuVerbs = verbsForSession(row);

  const actionsMenu = menuVerbs.length ? (
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
          data-debug-id={`shell-row-menu-${sessionId}`}
        />
      }
    >
      {menuVerbs.map((verb) => (
        <MenuItem
          key={verb}
          danger={isDestructive(verb)}
          data-debug-id={`shell-row-${verb}-menu-${sessionId}`}
          onClick={() => onVerb(row, verb)}
        >
          <span className="inline-flex items-center gap-2">
            <Icon name={VERB_ICON[verb]} size="sm" aria-hidden="true" />
            {VERB_LABEL[verb]}
          </span>
        </MenuItem>
      ))}
    </Menu>
  ) : undefined;

  return (
    <ResourceEntryCard
      id={sessionId}
      data-shell-row={sessionId}
      dataDebugId={`shell-row-${sessionId}`}
      bodyDebugId={`shell-row-body-${sessionId}`}
      timeDebugId={`shell-row-time-${sessionId}`}
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
      snippet={
        <>
          <span
            className="block truncate text-body-sm text-muted font-mono"
            title={body.cmd || undefined}
          >
            {body.cmd && body.cmd.trim() ? body.cmd : <span className="italic text-faint select-none">&lt;empty&gt;</span>}
          </span>
          <span
            className="block truncate text-body-sm text-faint font-mono"
            title={body.cwd || undefined}
          >
            {body.cwd && body.cwd.trim() ? body.cwd : <span className="italic text-faint select-none">&lt;empty&gt;</span>}
          </span>
        </>
      }
      status={
        <StatusPill tone={statusTone(row.status)} data-debug-id={`shell-row-status-${sessionId}`}>
          {statusLabel(row.status)}
        </StatusPill>
      }
      badges={
        <>
          <Badge data-debug-id={`shell-row-kind-${sessionId}`}>{kindLabel(row.kind)}</Badge>
          {row.server_port > 0 ? (
            <Badge
              data-debug-id={`shell-row-port-${sessionId}`}
              title={`This session declares port ${row.server_port}`}
            >
              :{row.server_port}
            </Badge>
          ) : null}
          {exit ? (
            <StatusPill tone={exitTone(row)} data-debug-id={`shell-row-exit-${sessionId}`}>
              {exit}
            </StatusPill>
          ) : null}
        </>
      }
      timestamp={time.text}
      timestampTooltip={time.title || undefined}
      actionsMenu={actionsMenu}
    />
  );
}

export default ShellRow;
