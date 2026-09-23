import React, { useMemo } from 'react';
import { EmptyState, Icon, Spinner } from '@ui';
import { useIsMobile } from '../shell/responsive';
import type { Issue } from '../../api/endpoints/issues';
import {
  useListIssuesQuery,
  useVoteIssueMutation,
  useUnvoteIssueMutation,
} from '../../api/endpoints/issues';
import { IssueRow } from '../issues/IssueRow';
import { issueViewHref } from '../issues/issueModel';
import { navigateTo } from '../../utils/appLocation';

export function RecentIssuesTab() {
  const isMobile = useIsMobile();
  const { data, isLoading, error, refetch } = useListIssuesQuery({
    limit: 100,
  });

  const [voteIssue] = useVoteIssueMutation();
  const [unvoteIssue] = useUnvoteIssueMutation();

  const handleVoteToggle = async (issue: Issue) => {
    const id = issue.issue_id || issue.issueId || issue.id;
    try {
      if (issue.has_voted ?? issue.hasVoted) {
        await unvoteIssue({ issueId: id }).unwrap();
      } else {
        await voteIssue({ issueId: id }).unwrap();
      }
    } catch (err: any) {
      console.error('Vote toggle error', err);
    }
  };

  // Recent: created_at descending
  const issues = useMemo(() => {
    const raw = [...(data?.items || [])];
    raw.sort((a, b) => {
      const tA = new Date(a.created_at || a.createdAt || 0).getTime();
      const tB = new Date(b.created_at || b.createdAt || 0).getTime();
      return tB - tA;
    });
    return raw;
  }, [data]);

  return (
    <div
      data-debug-id="recent-issues-tab"
      className="flex flex-col h-full min-h-0 w-full overflow-hidden"
    >
      <div className="flex-1 min-h-0 overflow-y-auto rounded-2xl border border-subtle bg-surface">
        {isLoading ? (
          <div className="flex flex-col items-center justify-center p-12 text-muted">
            <Spinner size="md" />
            <p className="mt-2 text-xs">Loading issues…</p>
          </div>
        ) : error ? (
          <div className="p-6 text-center text-danger text-xs">
            <p>Failed to load issues</p>
            <button
              type="button"
              onClick={() => refetch()}
              className="mt-3 inline-flex items-center gap-1.5 px-3 py-1.5 rounded-lg border border-subtle bg-surface text-xs font-medium hover:bg-surface-raised min-h-[44px]"
            >
              <Icon name="refresh" size={13} />
              <span>Retry</span>
            </button>
          </div>
        ) : issues.length === 0 ? (
          <div className="p-8 text-center">
            <EmptyState
              icon="alert"
              title="No issues reported"
              description="Reported bugs and blockers will appear here."
              data-debug-id="home-issues-empty-state"
            />
          </div>
        ) : (
          <ul className="divide-y divide-subtle list-none p-0 m-0">
            {issues.map((issue) => {
              const id = issue.issue_id || issue.issueId || issue.id;
              const href = issueViewHref(id);
              return (
                <IssueRow
                  key={id}
                  issue={issue}
                  href={href}
                  onOpen={() => navigateTo(href)}
                  onVoteToggle={() => handleVoteToggle(issue)}
                />
              );
            })}
          </ul>
        )}
      </div>
    </div>
  );
}

export default RecentIssuesTab;
