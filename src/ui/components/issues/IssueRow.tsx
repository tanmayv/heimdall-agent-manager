import React from 'react';
import {
  ActionButton,
  Badge,
  Icon,
  Menu,
  MenuItem,
  StatusPill,
  Text,
} from '@ui';
import type { Issue } from '../../api/endpoints/issues';
import {
  absoluteTime,
  issueSnippet,
  issueStatus,
  issueTitle,
  relativeTime,
  scopeLabel,
  scopeTone,
  statusLabel,
  statusTone,
} from './issueModel';

const BODY_TWO_LINES = 'calc(2 * var(--text-body-sm-size) * var(--text-body-sm-leading))';

export interface IssueRowProps {
  issue: Issue | any;
  href: string;
  active?: boolean;
  onOpen: (issue: any) => void;
  onVoteToggle?: (issue: any) => void;
  onEdit?: (issue: any) => void;
  onDelete?: (issue: any) => void;
  busy?: boolean;
}

export function IssueRow({
  issue,
  href,
  active = false,
  onOpen,
  onVoteToggle,
  onEdit,
  onDelete,
  busy = false,
}: IssueRowProps) {
  const issueId = String(issue?.issue_id || issue?.issueId || issue?.id || '');
  const title = issueTitle(issue);
  const snippet = issueSnippet(issue);
  const status = issueStatus(issue);
  const scopeType = String(issue?.scope_type || issue?.scopeType || 'global');
  const targetId = String(issue?.target_id || issue?.targetId || '');
  const chainId = String(issue?.chain_id || issue?.chainId || '');
  const createdBy = String(issue?.created_by || issue?.createdBy || '');
  const voteCount = Number(issue?.vote_count ?? issue?.voteCount ?? 0);
  const hasVoted = Boolean(issue?.has_voted ?? issue?.hasVoted);
  const updatedAt = String(issue?.updated_at || issue?.updatedAt || issue?.created_at || issue?.createdAt || '');

  function handleRowClick(e: React.MouseEvent) {
    if (e.defaultPrevented || e.button !== 0) return;
    if (e.metaKey || e.ctrlKey || e.shiftKey || e.altKey) return;
    if ((e.target as HTMLElement).closest('[data-row-control]')) return;
    e.preventDefault();
    onOpen(issue);
  }

  return (
    <li
      data-issue-row={issueId}
      data-debug-id={`issue-row-${issueId}`}
      data-active={active || undefined}
      className={[
        'relative flex min-h-[72px] items-start gap-3 border-b border-subtle px-3 py-3 transition-colors duration-fast cursor-pointer',
        active ? 'bg-surface-raised' : 'hover:bg-surface',
      ].join(' ')}
      onClick={handleRowClick}
    >
      <div className="min-w-0 flex-1">
        {/* Row 1: Title and actions menu only */}
        <div className="flex items-start gap-2">
          <a
            href={href}
            onClick={(e) => {
              if (e.metaKey || e.ctrlKey || e.shiftKey || e.altKey || e.button !== 0) return;
              e.preventDefault();
              onOpen(issue);
            }}
            className="min-w-0 flex-1 truncate rounded-[var(--radius-sm)] text-title text-primary focus-visible:shadow-focus focus-visible:outline-none"
          >
            {title}
          </a>

          {/* More options menu */}
          {(onEdit || onDelete) ? (
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
                    data-debug-id={`issue-row-menu-${issueId}`}
                  />
                }
              >
                {onEdit ? (
                  <MenuItem
                    data-debug-id={`issue-row-edit-${issueId}`}
                    onClick={() => onEdit(issue)}
                  >
                    Edit
                  </MenuItem>
                ) : null}
                {onDelete ? (
                  <MenuItem
                    danger
                    data-debug-id={`issue-row-delete-${issueId}`}
                    onClick={() => onDelete(issue)}
                  >
                    Delete
                  </MenuItem>
                ) : null}
              </Menu>
            </span>
          ) : null}
        </div>

        {/* Rows 2-3: Description preview snippet */}
        <p
          className="mt-0.5 overflow-hidden text-body-sm text-muted [display:-webkit-box] [-webkit-box-orient:vertical] [-webkit-line-clamp:2]"
          style={{ minHeight: BODY_TWO_LINES }}
          data-debug-id={`issue-row-body-${issueId}`}
        >
          {snippet && snippet.trim() ? snippet : <span className="italic text-faint select-none">&lt;no description&gt;</span>}
        </p>

        {/* Row 4: Status pill, scope badge, chain link, vote button, author, and relative time */}
        <div className="mt-1.5 flex items-end justify-between gap-3">
          <div className="flex min-w-0 flex-wrap items-center gap-2">
            <StatusPill tone={statusTone(status)}>{statusLabel(status)}</StatusPill>
            <Badge tone={scopeTone(scopeType)}>
              {scopeLabel(scopeType)}{targetId ? `: ${targetId}` : ''}
            </Badge>
            {chainId ? (
              <a
                data-row-control
                href={`#/chains/${encodeURIComponent(chainId)}`}
                onClick={(e) => e.stopPropagation()}
                className="inline-flex items-center gap-1 rounded-pill bg-neutral-soft px-2 py-0.5 text-[length:var(--text-caption-size)] font-semibold text-secondary hover:text-primary border border-subtle transition-colors"
                title={`Task Chain: ${chainId}`}
              >
                <Icon name="tasks" size={11} />
                <span>Chain</span>
              </a>
            ) : null}
            {/* Interactive vote button with tally */}
            <button
              type="button"
              data-row-control
              disabled={busy}
              onClick={(e) => {
                e.stopPropagation();
                onVoteToggle?.(issue);
              }}
              title={hasVoted ? 'Remove your vote' : 'Upvote this issue'}
              aria-label={`Vote for ${title}. Current votes: ${voteCount}`}
              className={[
                'inline-flex shrink-0 items-center gap-1.5 rounded-full px-2.5 py-0.5 text-xs font-semibold border transition-colors',
                hasVoted
                  ? 'bg-accent/15 text-accent border-accent/40 hover:bg-accent/25'
                  : 'bg-surface-raised text-muted border-subtle hover:bg-surface hover:text-primary',
              ].join(' ')}
            >
              <Icon name="arrow-up" size={13} className={hasVoted ? 'text-accent' : 'text-muted'} />
              <span data-debug-id={`issue-vote-count-${issueId}`}>{voteCount}</span>
            </button>
            {createdBy ? (
              <Text as="span" role="caption" tone="muted" className="truncate max-w-[150px]">
                by {createdBy}
              </Text>
            ) : null}
          </div>

          <Text
            as="span"
            role="caption"
            tone="muted"
            className="shrink-0 whitespace-nowrap"
            title={absoluteTime(updatedAt)}
            data-debug-id={`issue-row-time-${issueId}`}
          >
            {relativeTime(updatedAt)}
          </Text>
        </div>
      </div>
    </li>
  );
}

export default IssueRow;
