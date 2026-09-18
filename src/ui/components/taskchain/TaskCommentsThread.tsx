import React from 'react';
import Markdown from '../Markdown';
import { ArtifactAttachmentPreview } from '../ArtifactAttachmentPreview';
import { useFetchChainTaskCommentsQuery } from '../../api/endpoints/tasks';
import { useIsMobile } from '../shell/responsive';
import { writeRightSidebarOpen } from '../../utils/clientPersistence';

// artifactIdsFromText mirrors the helper in TaskChainOverview; kept local so this
// component is self-contained.
function artifactIdsFromText(text: string): string[] {
  const ids = new Set<string>();
  const re = /\b(art_[A-Za-z0-9]+)\b/g;
  let m: RegExpExecArray | null;
  while ((m = re.exec(text || '')) !== null) ids.add(m[1]);
  return Array.from(ids);
}

interface CommentSummary {
  count: number;
  lastCommentAt: string;
  lastCommentAuthorAgentInstanceId: string;
  lastCommentPreview: string;
}

// shellHash mirrors the local helper used across the taskchain views (e.g.
// TaskChainOverview) for hash-router links.
function shellHash(path: string): string { return `#${path.startsWith('/') ? path : `/${path}`}`; }

/**
 * CommentAuthor (MEM-7) renders a comment's author identity. An agent-authored
 * comment shows the resolved display name as a clickable link to that agent's
 * conversation (the same affordance the agent "Open" button uses). A user-authored
 * comment (no author instance) shows the human commenter's user id instead.
 */
const CommentAuthor: React.FC<{ instanceId: string; displayName: string; userId: string; debugId: string }> = ({
  instanceId,
  displayName,
  userId,
  debugId,
}) => {
  const isMobile = useIsMobile();
  if (instanceId) {
    const label = displayName || instanceId;
    const href = isMobile
      ? shellHash(`/conversations/${encodeURIComponent(instanceId)}`)
      : shellHash(`/conversations/${encodeURIComponent(instanceId)}?panel=tasks`);
    return (
      <a
        data-debug-id={debugId}
        href={href}
        title={`Open ${label} (${instanceId})`}
        onClick={() => {
          if (isMobile) {
            writeRightSidebarOpen(false);
            window.dispatchEvent(new CustomEvent('heimdall:close-sidebar'));
          }
        }}
        className="text-accent hover:underline"
      >
        @{label}
      </a>
    );
  }
  return (
    <span data-debug-id={debugId} className="text-primary">
      {userId || 'user'}
    </span>
  );
};

/**
 * TaskCommentsThread renders a task's comment thread. The chain/task list ships
 * only a `comment_summary` (count + last comment) to keep payloads small, so the
 * bodies are lazy-loaded here via GET .../comments?last=N — only when the task is
 * expanded (`enabled`). Until then (or while loading) it shows the summary line.
 */
export const TaskCommentsThread: React.FC<{
  chainId: string;
  taskId: string;
  summary?: CommentSummary | null;
  enabled: boolean;
  last?: number;
}> = ({ chainId, taskId, summary, enabled, last = 50 }) => {
  const { data, isFetching } = useFetchChainTaskCommentsQuery(
    { chainId, taskId, last },
    { skip: !enabled || !chainId || !taskId, refetchOnMountOrArgChange: true },
  );
  const comments: any[] = data?.comments || [];
  const count = summary?.count ?? comments.length;

  return (
    <div data-debug-id={`taskchain-task-comments-${taskId}`} className="space-y-2">
      <span className="font-semibold text-muted">
        Comments{count ? ` (${count})` : ''}:
      </span>

      {/* Summary line while the thread is loading or before any bodies arrive. */}
      {count > 0 && comments.length === 0 ? (
        <div data-debug-id={`taskchain-task-comment-summary-${taskId}`} className="rounded border border-subtle bg-surface-raised/60 p-2 text-caption text-muted">
          {isFetching ? 'Loading comments…' : (
            <>
              <span className="font-semibold text-primary">{summary?.lastCommentAuthorAgentInstanceId || 'user'}</span>
              {summary?.lastCommentPreview ? <>: {summary.lastCommentPreview}</> : null}
              {summary?.lastCommentAt ? <span className="ml-1 text-faint">· {summary.lastCommentAt}</span> : null}
            </>
          )}
        </div>
      ) : null}

      {count === 0 ? (
        <div data-debug-id={`taskchain-task-comment-empty-${taskId}`} className="text-caption text-faint">No comments yet.</div>
      ) : null}

      {comments.map((comment: any, idx: number) => (
        <div
          key={comment.commentId || comment.comment_id || idx}
          data-debug-id={`taskchain-task-comment-${taskId}-${idx}`}
          className="rounded border border-subtle bg-surface-raised p-2 text-caption"
        >
          <div className="font-semibold text-muted">
            <CommentAuthor
              instanceId={comment.authorAgentInstanceId || comment.author_agent_instance_id || ''}
              displayName={comment.authorDisplayName || comment.author_display_name || ''}
              userId={comment.authorUserId || comment.author_user_id || ''}
              debugId={`taskchain-task-comment-author-${taskId}-${idx}`}
            />:
          </div>
          <div className="mt-1 text-primary">
            <Markdown source={comment.body || ''} compact copyAll={false} data-debug-id={`taskchain-task-comment-body-${taskId}-${idx}`} />
            {artifactIdsFromText(comment.body || '').length > 0 ? (
              <div data-debug-id={`taskchain-task-comment-artifacts-${taskId}-${idx}`} className="mt-2 flex flex-wrap gap-2">
                {artifactIdsFromText(comment.body || '').map((artifactId) => (
                  <ArtifactAttachmentPreview
                    key={artifactId}
                    artifactId={artifactId}
                    session={{ daemonUrl: '', clientToken: '' }}
                    debugId={`taskchain-task-comment-artifact-${taskId}-${idx}-${artifactId}`}
                  />
                ))}
              </div>
            ) : null}
          </div>
        </div>
      ))}
    </div>
  );
};

export default TaskCommentsThread;
