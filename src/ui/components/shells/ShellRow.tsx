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
 * What differs for a shell session:
 *  - **The body is paths and shell strings, not prose.** `cmd` and `cwd` are long,
 *    unbroken and meaningful at BOTH ends, so each gets its own single truncated line
 *    with the full text in a `title` — rather than the two-line prose clamp the other
 *    resources use. The two lines are still RESERVED when empty, so the pill row never
 *    rides up.
 *  - **The bottom-right time changes field with the row's state** — `last_activity_at`
 *    while live, `finished_at` once terminal. See shellModel's header, point 2.
 *  - **The menu's verbs differ per state**, and the exclusions are hub-verified rather
 *    than guessed (`verbsForSession`). A terminal row offers Restart and nothing else.
 *  - **A row never reorders under the user.** The list is ordered by `started_at`
 *    (shell_session_repo_sqlite.odin:189), which is immutable for a given session, so
 *    a status change repaints the row in place and cannot move it — the one place this
 *    resource has it easier than Memory, whose `updated_at` ordering does move rows.
 */
import React from 'react';
import { ActionButton, Badge, Checkbox, Icon, Menu, MenuItem, StatusPill, Text, TOUCH_TARGET_CLASS, useViewport } from '@ui';
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

/** One line of body type. Two of these are reserved whether or not they are filled. */
const BODY_LINE = 'calc(var(--text-body-sm-size) * var(--text-body-sm-leading))';

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

  function handleRowClick(e: React.MouseEvent) {
    if (e.defaultPrevented || e.button !== 0) return;
    if (e.metaKey || e.ctrlKey || e.shiftKey || e.altKey) return;
    // Tapping the "…" (or the checkbox) must not also open the row.
    if ((e.target as HTMLElement).closest('[data-row-control]')) return;
    e.preventDefault();
    onOpen(row);
  }

  return (
    <li
      data-shell-row={sessionId}
      data-debug-id={`shell-row-${sessionId}`}
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
        {/* ---- row 1: the session's name, and the overflow trigger ---- */}
        <div className="flex items-start gap-2">
          <a
            href={href}
            onClick={(e) => {
              if (e.metaKey || e.ctrlKey || e.shiftKey || e.altKey || e.button !== 0) return;
              e.preventDefault();
              onOpen(row);
            }}
            title={title}
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
                    {/* The glyph rides BESIDE the word, never instead of it: a verb a
                        user has to guess from an icon is the ambiguous-destructive
                        risk Amendment 6 removes rather than mitigates. */}
                    <span className="inline-flex items-center gap-2">
                      <Icon name={VERB_ICON[verb]} size="sm" aria-hidden="true" />
                      {VERB_LABEL[verb]}
                    </span>
                  </MenuItem>
                ))}
              </Menu>
            </span>
          ) : null}
        </div>

        {/* ---- rows 2-3: cmd then cwd, one line each, both reserved ---- */}
        <div className="mt-0.5" data-debug-id={`shell-row-body-${sessionId}`}>
          <p
            className="truncate text-body-sm text-muted"
            style={{ minHeight: BODY_LINE }}
            title={body.cmd || undefined}
          >
            {body.cmd && body.cmd.trim() ? body.cmd : <span className="italic text-faint select-none">&lt;empty&gt;</span>}
          </p>
          <p
            className="truncate text-body-sm text-faint"
            style={{ minHeight: BODY_LINE }}
            title={body.cwd || undefined}
          >
            {body.cwd && body.cwd.trim() ? body.cwd : <span className="italic text-faint select-none">&lt;empty&gt;</span>}
          </p>
        </div>

        {/* ---- row 4: pills left, time hard right (Amendment 7: time LAST) ---- */}
        <div className="mt-1.5 flex items-end justify-between gap-3">
          <div className="flex min-w-0 flex-wrap items-center gap-2">
            <StatusPill tone={statusTone(row.status)} data-debug-id={`shell-row-status-${sessionId}`}>
              {statusLabel(row.status)}
            </StatusPill>
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
          </div>
          <Text
            as="span"
            role="caption"
            tone="muted"
            className="shrink-0 whitespace-nowrap"
            title={time.title || undefined}
            data-debug-id={`shell-row-time-${sessionId}`}
          >
            {time.text}
          </Text>
        </div>
      </div>
    </li>
  );
}

export default ShellRow;
