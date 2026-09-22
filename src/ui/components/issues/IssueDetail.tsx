import React, { useState } from 'react';
import {
  ActionButton,
  Alert,
  Badge,
  Button,
  Icon,
  IconButton,
  Menu,
  MenuItem,
  Panel,
  Select,
  StatusPill,
  Text,
  Textarea,
  useViewport,
} from '@ui';
import type { Issue } from '../../api/endpoints/issues';
import {
  useAddIssueCommentMutation,
  useDeleteIssueCommentMutation,
  useDeleteIssueMutation,
  useGetIssueQuery,
  useListIssueCommentsQuery,
  useUpdateIssueMutation,
  useVoteIssueMutation,
  useUnvoteIssueMutation,
} from '../../api/endpoints/issues';
import MarkdownBody from '../MarkdownBody';
import {
  absoluteTime,
  issueEditHref,
  issueSnippet,
  issueStatus,
  issueTitle,
  navigateTo,
  relativeTime,
  scopeLabel,
  scopeTone,
  statusLabel,
  statusTone,
} from './issueModel';

export interface IssueDetailProps {
  issueId: string;
  onBack?: () => void;
  onEdit?: (issue: Issue) => void;
  onDelete?: (issue: Issue) => void;
}

function SectionCard({
  title,
  action,
  children,
  debugId,
}: {
  title: string;
  action?: React.ReactNode;
  children: React.ReactNode;
  debugId: string;
}) {
  return (
    <Panel data-debug-id={debugId} className="p-4 rounded-xl border border-subtle bg-surface">
      <div className="flex items-center justify-between gap-3 mb-3 border-b border-subtle pb-2">
        <h3 className="text-sm font-semibold uppercase tracking-wider text-muted">{title}</h3>
        {action ? <div>{action}</div> : null}
      </div>
      {children}
    </Panel>
  );
}

export function IssueDetail({ issueId, onBack, onEdit, onDelete }: IssueDetailProps) {
  const viewport = useViewport();
  const isMobile = viewport === 'mobile';

  const { data: issue, isLoading, error } = useGetIssueQuery({ issueId }, { skip: !issueId });
  const embeddedComments = issue?.comments || [];
  const { data: fetchedComments, isLoading: commentsQueryLoading } = useListIssueCommentsQuery({ issueId }, { skip: !issueId });
  const comments = fetchedComments !== undefined ? fetchedComments : embeddedComments;
  const commentsLoading = commentsQueryLoading && embeddedComments.length === 0;

  const [updateIssue, { isLoading: isUpdatingStatus }] = useUpdateIssueMutation();
  const [deleteIssue, { isLoading: isDeleting }] = useDeleteIssueMutation();
  const [voteIssue, { isLoading: isVoting }] = useVoteIssueMutation();
  const [unvoteIssue, { isLoading: isUnvoting }] = useUnvoteIssueMutation();
  const [addComment, { isLoading: isAddingComment }] = useAddIssueCommentMutation();
  const [deleteComment] = useDeleteIssueCommentMutation();

  const [commentText, setCommentText] = useState('');
  const [commentError, setCommentError] = useState('');
  const [actionError, setActionError] = useState('');

  if (isLoading) {
    return (
      <div className="flex h-full items-center justify-center p-8 text-muted">
        <Icon name="refresh" className="animate-spin mr-2" size={18} />
        <span>Loading issue details...</span>
      </div>
    );
  }

  if (error || !issue) {
    return (
      <div className="p-6">
        <Alert tone="danger" title="Issue not found">
          {error ? String((error as any)?.error || error) : `Issue ${issueId} could not be loaded.`}
        </Alert>
        {onBack ? (
          <Button variant="secondary" className="mt-4" onClick={onBack}>
            Back to list
          </Button>
        ) : null}
      </div>
    );
  }

  const status = issueStatus(issue);
  const title = issueTitle(issue);
  const scopeType = String(issue.scope_type || issue.scopeType || 'global');
  const targetId = String(issue.target_id || issue.targetId || '');
  const chainId = String(issue.chain_id || issue.chainId || '');
  const createdBy = String(issue.created_by || issue.createdBy || '');
  const voteCount = Number(issue.vote_count ?? issue.voteCount ?? 0);
  const hasVoted = Boolean(issue.has_voted ?? issue.hasVoted);
  const createdAt = String(issue.created_at || issue.createdAt || '');
  const updatedAt = String(issue.updated_at || issue.updatedAt || '');
  const closedAt = String(issue.closed_at || issue.closedAt || '');

  const handleStatusChange = async (newStatus: string) => {
    setActionError('');
    try {
      await updateIssue({ issueId, status: newStatus }).unwrap();
    } catch (err: any) {
      setActionError(String(err?.data?.message || err?.message || 'Failed to update status'));
    }
  };

  const handleVoteToggle = async () => {
    setActionError('');
    try {
      if (hasVoted) {
        await unvoteIssue({ issueId }).unwrap();
      } else {
        await voteIssue({ issueId }).unwrap();
      }
    } catch (err: any) {
      setActionError(String(err?.data?.message || err?.message || 'Failed to update vote'));
    }
  };

  const handleDelete = async () => {
    if (!window.confirm(`Are you sure you want to delete issue "${title}"?`)) return;
    setActionError('');
    try {
      await deleteIssue({ issueId }).unwrap();
      if (onDelete) {
        onDelete(issue);
      } else {
        navigateTo('#/issues');
      }
    } catch (err: any) {
      setActionError(String(err?.data?.message || err?.message || 'Failed to delete issue'));
    }
  };

  const handleEdit = () => {
    if (onEdit) {
      onEdit(issue);
    } else {
      navigateTo(issueEditHref(issueId));
    }
  };

  const handleAddComment = async (e?: React.FormEvent) => {
    if (e) e.preventDefault();
    const text = commentText.trim();
    if (!text) return;
    setCommentError('');
    try {
      await addComment({ issueId, body: text }).unwrap();
      setCommentText('');
    } catch (err: any) {
      setCommentError(String(err?.data?.message || err?.message || 'Failed to post comment'));
    }
  };

  const handleDeleteComment = async (commentId: string) => {
    if (!window.confirm('Delete this comment?')) return;
    try {
      await deleteComment({ issueId, commentId }).unwrap();
    } catch (err: any) {
      alert(String(err?.data?.message || err?.message || 'Failed to delete comment'));
    }
  };

  return (
    <div className="flex flex-col h-full overflow-y-auto p-4 sm:p-6 space-y-6" data-debug-id={`issue-detail-${issueId}`}>
      {/* Mobile back trigger */}
      {isMobile && onBack ? (
        <div>
          <Button variant="ghost" size="sm" onClick={onBack} className="gap-1.5 -ml-2">
            <Icon name="chevron-left" size={16} />
            <span>All issues</span>
          </Button>
        </div>
      ) : null}

      {actionError ? (
        <Alert tone="danger" title="Action Error">
          {actionError}
        </Alert>
      ) : null}

      {/* Header section: Title, badges, and primary action controls */}
      <div className="flex flex-col gap-4 border-b border-subtle pb-4 sm:flex-row sm:items-start sm:justify-between">
        <div className="min-w-0 flex-1">
          <div className="flex flex-wrap items-center gap-2 mb-2">
            <StatusPill tone={statusTone(status)}>{statusLabel(status)}</StatusPill>
            <Badge tone={scopeTone(scopeType)}>
              {scopeLabel(scopeType)}{targetId ? `: ${targetId}` : ''}
            </Badge>
            <Text as="span" role="caption" tone="muted" title={absoluteTime(createdAt)}>
              Reported {relativeTime(createdAt)} {createdBy ? `by ${createdBy}` : ''}
            </Text>
          </div>
          <h1 className="text-xl sm:text-2xl font-bold tracking-tight text-primary break-words">
            {title}
          </h1>
          <p className="text-xs text-muted mt-1 font-mono">{issueId}</p>
        </div>

        {/* Action cluster: Vote toggle, status dropdown, edit, more actions */}
        <div className="flex flex-wrap items-center gap-2 shrink-0">
          {/* Vote Toggle Button */}
          <Button
            variant={hasVoted ? 'primary' : 'secondary'}
            size="sm"
            onClick={handleVoteToggle}
            disabled={isVoting || isUnvoting}
            title={hasVoted ? 'Click to unvote' : 'Click to upvote'}
            data-debug-id="issue-detail-vote-button"
            className="gap-2"
          >
            <Icon name="arrow-up" size={14} className={hasVoted ? 'text-white' : 'text-accent'} />
            <span>{hasVoted ? 'Upvoted' : 'Upvote'}</span>
            <span className="rounded-full bg-neutral-soft px-1.5 py-0.2 text-xs font-mono font-bold">
              {voteCount}
            </span>
          </Button>

          {/* Status Select dropdown */}
          <div className="w-32">
            <Select
              value={status}
              disabled={isUpdatingStatus}
              onChange={handleStatusChange}
              size="sm"
              aria-label="Change issue status"
              options={[
                { value: 'new', label: 'New' },
                { value: 'fixed', label: 'Fixed' },
                { value: 'obsolete', label: 'Obsolete' },
              ]}
            />
          </div>

          <Button variant="secondary" size="sm" onClick={handleEdit} data-debug-id="issue-detail-edit-button">
            <Icon name="pencil" size={14} className="mr-1.5" />
            <span>Edit</span>
          </Button>

          <Menu
            label="More options"
            align="end"
            trigger={
              <ActionButton
                icon="more-horizontal"
                label="More"
                iconOnly
                aria-label="More options"
                data-debug-id="issue-detail-more-menu"
              />
            }
          >
            <MenuItem
              danger
              data-debug-id="issue-detail-delete-item"
              onClick={handleDelete}
              disabled={isDeleting}
            >
              Delete Issue
            </MenuItem>
          </Menu>
        </div>
      </div>

      {/* Task chain context link card (if chain_id is set) */}
      {chainId ? (
        <Panel data-debug-id="issue-chain-context" className="p-4 rounded-xl border border-accent/20 bg-accent/5">
          <div className="flex items-start gap-3">
            <div className="p-2 rounded-lg bg-accent/10 text-accent shrink-0">
              <Icon name="tasks" size={20} />
            </div>
            <div className="min-w-0 flex-1">
              <div className="flex items-center gap-2">
                <h4 className="text-sm font-semibold text-primary">Found in Task Chain</h4>
                <Badge tone="info">Context</Badge>
              </div>
              <p className="text-xs text-muted mt-1">
                This issue was discovered while running chain{' '}
                <a
                  href={`#/chains/${encodeURIComponent(chainId)}`}
                  className="font-mono text-accent hover:underline font-semibold"
                >
                  {chainId}
                </a>
                .
              </p>
              <div className="mt-2">
                <a
                  href={`#/chains/${encodeURIComponent(chainId)}`}
                  className="inline-flex items-center gap-1 text-xs text-accent font-medium hover:underline"
                >
                  <span>Open Task Chain</span>
                  <Icon name="arrow-right" size={12} />
                </a>
              </div>
            </div>
          </div>
        </Panel>
      ) : null}

      {/* Description Section */}
      <SectionCard title="Description" debugId="issue-description-card">
        {issue.description ? (
          <div className="prose prose-invert max-w-none text-sm text-primary">
            <MarkdownBody source={issue.description} />
          </div>
        ) : (
          <p className="italic text-muted text-sm">No description provided.</p>
        )}
      </SectionCard>

      {/* Metadata / Scope Details */}
      <SectionCard title="Details & Scope" debugId="issue-metadata-card">
        <div className="grid grid-cols-1 sm:grid-cols-2 gap-4 text-xs">
          <div>
            <span className="text-muted block mb-0.5">Scope</span>
            <span className="font-medium text-primary capitalize">{scopeLabel(scopeType)}</span>
          </div>
          {targetId ? (
            <div>
              <span className="text-muted block mb-0.5">Target Identifier</span>
              <span className="font-mono text-primary">{targetId}</span>
            </div>
          ) : null}
          <div>
            <span className="text-muted block mb-0.5">Created By</span>
            <span className="font-medium text-primary">{createdBy || 'User'}</span>
          </div>
          <div>
            <span className="text-muted block mb-0.5">Last Updated</span>
            <span className="text-primary">{absoluteTime(updatedAt)}</span>
          </div>
          {closedAt ? (
            <div>
              <span className="text-muted block mb-0.5">Closed At</span>
              <span className="text-primary">{absoluteTime(closedAt)}</span>
            </div>
          ) : null}
        </div>
      </SectionCard>

      {/* Threaded Comments Section */}
      <SectionCard
        title={`Discussion (${comments.length})`}
        debugId="issue-comments-section"
      >
        <div className="space-y-4">
          {commentsLoading ? (
            <p className="text-xs text-muted">Loading comments...</p>
          ) : comments.length === 0 ? (
            <p className="text-xs text-muted italic">No comments yet. Be the first to chime in.</p>
          ) : (
            <div className="space-y-3 divide-y divide-subtle">
              {comments.map((comment) => (
                <div key={comment.comment_id || comment.id} className="pt-3 first:pt-0">
                  <div className="flex items-center justify-between gap-2 mb-1.5">
                    <div className="flex items-center gap-2 text-xs">
                      <span className="font-semibold text-primary">
                        {comment.author_name || comment.author_id || 'Participant'}
                      </span>
                      <span className="text-muted">·</span>
                      <span className="text-muted" title={absoluteTime(comment.created_at || comment.createdAt)}>
                        {relativeTime(comment.created_at || comment.createdAt)}
                      </span>
                    </div>
                    <button
                      type="button"
                      title="Delete comment"
                      onClick={() => handleDeleteComment(comment.comment_id || comment.id)}
                      className="text-muted hover:text-danger p-1 rounded transition-colors"
                    >
                      <Icon name="trash" size={13} />
                    </button>
                  </div>
                  <div className="prose prose-invert text-xs max-w-none text-secondary">
                    <MarkdownBody source={comment.body} />
                  </div>
                </div>
              ))}
            </div>
          )}

          {/* Comment Composer */}
          <form onSubmit={handleAddComment} className="mt-4 pt-3 border-t border-subtle">
            {commentError ? (
              <Alert tone="danger" title="Error" className="mb-2">
                {commentError}
              </Alert>
            ) : null}
            <div className="space-y-2">
              <Textarea
                value={commentText}
                onChange={setCommentText}
                placeholder="Leave a comment (supports markdown)..."
                rows={3}
                onKeyDown={(e) => {
                  if ((e.ctrlKey || e.metaKey) && e.key === 'Enter') {
                    e.preventDefault();
                    handleAddComment();
                  }
                }}
              />
              <div className="flex items-center justify-between">
                <span className="text-[11px] text-muted">Press Ctrl+Enter to submit</span>
                <Button
                  type="submit"
                  variant="primary"
                  size="sm"
                  disabled={!commentText.trim() || isAddingComment}
                  loading={isAddingComment}
                >
                  <Icon name="chat" size={14} className="mr-1.5" />
                  <span>Comment</span>
                </Button>
              </div>
            </div>
          </form>
        </div>
      </SectionCard>
    </div>
  );
}

export default IssueDetail;
