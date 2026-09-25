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
import {
  Badge,
  Checkbox,
  ResourceEntryCard,
  StatusPill,
  Text,
  TOUCH_TARGET_CLASS,
  useViewport,
  type ResourceMenuAction,
} from '@ui';
import { VaultText } from '../vault/VaultText';
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
  const menuVerbs = verbsForState(state);
  const projectId = row.projectId;
  const project = row;
  const isFig = project.project_type === 'fig';
  const title = projectTitle(row);
  const snippet = projectSnippet(row);
  const vcs = String(row.vcsKind || '').trim();

  const menuActions: ResourceMenuAction[] = menuVerbs.map((verb) => ({
    label: VERB_LABEL[verb],
    danger: verb === 'archive',
    debugId: `project-row-${verb}-menu-${projectId}`,
    onClick: () => onVerb(row, verb),
  }));

  return (
    <ResourceEntryCard
      id={projectId}
      data-project-row={projectId}
      dataDebugId={`project-row-${projectId}`}
      bodyDebugId={`project-row-body-${projectId}`}
      timeDebugId={`project-row-time-${projectId}`}
      title={
        <span className="flex min-w-0 items-center gap-2">
          <span className="min-w-0 truncate"><VaultText value={row.name || title} fallback={projectId} as="span" /></span>
          {isFig ? (
            <Badge tone="warning" data-debug-id={`project-row-fig-badge-${projectId}`}>
              Fig (CitC)
            </Badge>
          ) : null}
        </span>
      }
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
      badges={
        <>
          {vcs ? <Badge data-debug-id={`project-row-vcs-${projectId}`}>{vcsLabel(vcs)}</Badge> : null}
          {isFig && row.workspace_name ? (
            <Text
              as="span"
              role="caption"
              tone="warning"
              className="min-w-0 truncate font-mono text-warning"
              title={`${row.workspace_name}${row.relative_path ? ` · google3/${row.relative_path}` : ' · google3'}`}
              data-debug-id={`project-row-workspace-${projectId}`}
            >
              {row.workspace_name}{row.relative_path ? ` · google3/${row.relative_path}` : ' · google3'}
            </Text>
          ) : row.defaultPath ? (
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
        </>
      }
      timestamp={relativeTime(row.updatedAt)}
      timestampTooltip={absoluteTime(row.updatedAt)}
      menuActions={menuActions.length > 0 ? menuActions : undefined}
    />
  );
}

export default ProjectRow;
