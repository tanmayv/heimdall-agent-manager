/**
 * ProjectRow — one project in the list, on every viewport.
 * ------------------------------------------------------------------
 * Amendment 6's four-line anatomy, inherited from `MemoryRow` unchanged:
 *
 *     row 1   Title ...........................................  [ … ]
 *     row 2   body line 1
 *     row 3   body line 2
 *     row 4   [pill] [pill] [pill] ......................  12m ago
 *
 * What differs for a project, and why:
 *  - **The pills are vcs · path · (Archived).** A project's identity is where it
 *    lives, so `default_path` earns a chip — truncated from the LEFT, because two
 *    checkouts under one home directory are identical for their first 17
 *    characters and a normal end-truncation renders both as the same chip.
 *  - **There is no per-row state pill in the normal case.** Memory has four
 *    statuses worth reading; a project has two, and an "Active" pill on every row
 *    of the Active tab is noise. Only `Archived` prints.
 *  - **No bridge-path validation chip.** It is genuinely display-worthy — and it
 *    arrives only from the DETAIL endpoint (`project_handlers.odin:33-36`). Putting
 *    it in a row would mean one fetch per row for a field the list API does not
 *    send, so it lives on the view page instead.
 *  - **The time is `updated_at`, and nothing says "created".** `created_at` is
 *    never serialised (`project_handlers.odin:77-79`) even though the list's cursor
 *    is keyed on it, and Amendment 6 forbids rendering a field the API does not
 *    send.
 *
 * Everything else — the single `…` trigger, no inline verbs, no hover cluster, no
 * swipe, the two reserved body lines, clicks inside a row control not navigating —
 * is the inherited convention. See `MemoryRow` for why each of those is the way it
 * is; it is not re-argued here.
 */
import React from 'react';
import { ActionButton, Badge, Checkbox, Menu, MenuItem, StatusPill, Text, TOUCH_TARGET_CLASS, useViewport } from '@ui';
import type { ProjectRecord } from '../../api/endpoints/projects';
import {
  VERB_LABEL,
  absoluteTime,
  projectSnippet,
  projectState,
  projectTitle,
  relativeTime,
  shortPath,
  stateLabel,
  stateTone,
  verbsForState,
  vcsLabel,
  type ProjectVerb,
} from './projectModel';

/**
 * Rows 2-3 are reserved whether or not this project has a description, so a
 * description-less row does not collapse and leave its pills sitting a line higher
 * than its neighbours'. Derived from the type tokens, not a magic px.
 */
const BODY_TWO_LINES = 'calc(2 * var(--text-body-sm-size) * var(--text-body-sm-leading))';

export interface ProjectRowProps {
  row: ProjectRecord;
  href: string;
  selected: boolean;
  /** Highlighted because it is the project open in the detail pane (two-pane only). */
  active?: boolean;
  selectable: boolean;
  showCheckbox: boolean;
  onSelectedChange: (next: boolean) => void;
  onVerb: (row: ProjectRecord, verb: ProjectVerb) => void;
  onOpen: (row: ProjectRecord) => void;
  busy?: boolean;
}

export function ProjectRow({
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
}: ProjectRowProps) {
  const viewport = useViewport();
  const isMobile = viewport === 'mobile';
  const state = projectState(row);
  // `verbsForState` already prunes what means nothing in a state — an archived
  // project offers Edit and no Archive, and no Restore, because no endpoint
  // un-archives — so the menu never offers a no-op.
  const menuVerbs = verbsForState(state);
  const projectId = row.projectId;
  const title = projectTitle(row);
  const snippet = projectSnippet(row);
  const vcs = String(row.vcsKind || '').trim();

  /* -------- opening the row --------
   * The whole row is a tap target, but not via a stretched-link overlay: the row
   * handles the click and ignores anything that started inside the checkbox or the
   * menu, so tapping "…" does not also navigate. The title stays a real <a>, so
   * keyboard focus, middle-click and "copy link address" all behave. */
  function handleRowClick(e: React.MouseEvent) {
    if (e.defaultPrevented || e.button !== 0) return;
    if (e.metaKey || e.ctrlKey || e.shiftKey || e.altKey) return;
    if ((e.target as HTMLElement).closest('[data-row-control]')) return;
    e.preventDefault();
    onOpen(row);
  }

  return (
    <li
      data-project-row={projectId}
      data-debug-id={`project-row-${projectId}`}
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
            // `min-w-0` is what makes the title truncate against the trigger rather
            // than pushing it off the row.
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
                    data-debug-id={`project-row-menu-${projectId}`}
                  />
                }
              >
                {menuVerbs.map((verb) => (
                  <MenuItem
                    key={verb}
                    danger={verb === 'archive'}
                    data-debug-id={`project-row-${verb}-menu-${projectId}`}
                    onClick={() => onVerb(row, verb)}
                  >
                    {VERB_LABEL[verb]}
                  </MenuItem>
                ))}
              </Menu>
            </span>
          ) : null}
        </div>

        {/* ---- rows 2-3: the description, two lines then ellipsis ---- */}
        <p
          className="mt-0.5 overflow-hidden text-body-sm text-muted [display:-webkit-box] [-webkit-box-orient:vertical] [-webkit-line-clamp:2]"
          style={{ minHeight: BODY_TWO_LINES }}
          data-debug-id={`project-row-body-${projectId}`}
        >
          {snippet}
        </p>

        {/* ---- row 4: pills left, relative time hard right ---- */}
        <div className="mt-1.5 flex items-end justify-between gap-3">
          <div className="flex min-w-0 flex-wrap items-center gap-2">
            {/* An empty `vcs_kind` gets no chip at all: "No VCS" on most rows is a
                column of nothing, and the absence already says it. */}
            {vcs ? <Badge data-debug-id={`project-row-vcs-${projectId}`}>{vcsLabel(vcs)}</Badge> : null}
            {row.defaultPath ? (
              <Text
                as="span"
                role="caption"
                tone="muted"
                className="min-w-0 truncate font-mono"
                title={row.defaultPath}
                data-debug-id={`project-row-path-${projectId}`}
              >
                {shortPath(row.defaultPath)}
              </Text>
            ) : null}
            {state === 'archived' ? (
              <StatusPill tone={stateTone(state)} data-debug-id={`project-row-state-${projectId}`}>
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
            data-debug-id={`project-row-time-${projectId}`}
          >
            {relativeTime(row.updatedAt)}
          </Text>
        </div>
      </div>
    </li>
  );
}

export default ProjectRow;
