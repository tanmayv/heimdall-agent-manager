import React from 'react';
import {
  Badge,
  Icon,
  ResourceEntryCard,
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

  {/* Row 1: Title and actions menu */}
  const menuActions = [
    ...(onEdit
      ? [
          {
            label: 'Edit',
            debugId: `issue-row-edit-${issueId}`,
            onClick: () => onEdit(issue),
          },
        ]
      : []),
    ...(onDelete
      ? [
          {
            label: 'Delete',
            danger: true,
            debugId: `issue-row-delete-${issueId}`,
            onClick: () => onDelete(issue),
          },
        ]
      : []),
  ];

  {/* Rows 2-3: Description preview snippet */}

  {/* Row 4: Status pill, scope badge, chain link, vote button, author, and relative time */}
  return (
    <ResourceEntryCard
      id={issueId}
      data-issue-row={issueId}
      dataDebugId={`issue-row-${issueId}`}
      bodyDebugId={`issue-row-body-${issueId}`}
      timeDebugId={`issue-row-time-${issueId}`}
      title={title}
      href={href}
      active={active}
      onSelect={() => onOpen(issue)}
      snippet={snippet && snippet.trim() ? snippet : <span className="italic text-faint select-none">&lt;no description&gt;</span>}
      status={<StatusPill tone={statusTone(status)}>{statusLabel(status)}</StatusPill>}
      badges={
        <>
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
        </>
      }
      metadata={
        <>
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
        </>
      }
      timestamp={relativeTime(updatedAt)}
      timestampTooltip={absoluteTime(updatedAt)}
      menuActions={menuActions.length > 0 ? menuActions : undefined}
    />
  );
}

export default IssueRow;
