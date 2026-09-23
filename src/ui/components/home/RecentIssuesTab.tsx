import React, { useEffect, useMemo, useState } from 'react';
import { Button, EmptyState, Icon, Input, Spinner, Text } from '@ui';
import { useIsMobile } from '../shell/responsive';
import type { Issue } from '../../api/endpoints/issues';
import {
  useListIssuesQuery,
  useVoteIssueMutation,
  useUnvoteIssueMutation,
} from '../../api/endpoints/issues';
import { IssueDetail } from '../issues/IssueDetail';
import { IssueRow } from '../issues/IssueRow';
import { issueViewHref } from '../issues/issueModel';

type ViewMode = 'recent' | 'top10';

const STATUS_FILTERS = [
  { value: '', label: 'All' },
  { value: 'new', label: 'New' },
  { value: 'fixed', label: 'Fixed' },
  { value: 'obsolete', label: 'Obsolete' },
];

export function RecentIssuesTab() {
  const isMobile = useIsMobile();
  const twoPane = !isMobile;

  const [viewMode, setViewMode] = useState<ViewMode>('recent');
  const [statusFilter, setStatusFilter] = useState('');
  const [searchQuery, setSearchQuery] = useState('');
  const [selectedId, setSelectedId] = useState<string>('');

  const { data, isLoading, error, refetch } = useListIssuesQuery({
    status: statusFilter || undefined,
    q: searchQuery.trim() || undefined,
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

  // Process and sort issues based on view mode (recent vs top 10)
  const processedIssues = useMemo(() => {
    const raw = [...(data?.items || [])];
    if (viewMode === 'top10') {
      raw.sort((a, b) => {
        const vA = Number(a.vote_count ?? a.voteCount ?? 0);
        const vB = Number(b.vote_count ?? b.voteCount ?? 0);
        if (vB !== vA) return vB - vA;
        const tA = new Date(a.created_at || a.createdAt || 0).getTime();
        const tB = new Date(b.created_at || b.createdAt || 0).getTime();
        return tB - tA;
      });
      return raw.slice(0, 10);
    } else {
      // Recent: created_at descending
      raw.sort((a, b) => {
        const tA = new Date(a.created_at || a.createdAt || 0).getTime();
        const tB = new Date(b.created_at || b.createdAt || 0).getTime();
        return tB - tA;
      });
      return raw;
    }
  }, [data, viewMode]);

  // On desktop twoPane mode, auto-select first issue if none selected
  useEffect(() => {
    if (twoPane && !selectedId && processedIssues.length > 0) {
      setSelectedId(processedIssues[0].issue_id || processedIssues[0].issueId || processedIssues[0].id);
    }
  }, [twoPane, selectedId, processedIssues]);

  const listColumn = (
    <div
      data-debug-id="home-issues-list-pane"
      className="flex flex-col h-full min-w-0 overflow-hidden"
    >
      {/* Search Bar */}
      <div className="p-2 border-b border-subtle shrink-0">
        <Input
          value={searchQuery}
          onChange={setSearchQuery}
          width="full"
          leading={<Icon name="search" size="sm" />}
          placeholder="Search issues…"
          size="sm"
          data-debug-id="home-issues-search-input"
        />
      </div>

      {/* Sub-view toggle: Recent Issues vs Top 10 Issues */}
      <div className="px-2 py-2 border-b border-subtle flex items-center justify-between gap-2 shrink-0">
        <div
          data-debug-id="home-issues-view-mode-toggle"
          className="inline-flex rounded-lg border border-subtle bg-surface p-0.5"
        >
          <button
            type="button"
            data-debug-id="home-issues-view-mode-recent"
            onClick={() => setViewMode('recent')}
            className={`px-3 py-1 text-xs font-semibold rounded-md transition-colors ${
              viewMode === 'recent'
                ? 'bg-accent text-accent-fg shadow-sm'
                : 'text-muted hover:text-primary'
            }`}
          >
            Recent Issues
          </button>
          <button
            type="button"
            data-debug-id="home-issues-view-mode-top10"
            onClick={() => setViewMode('top10')}
            className={`px-3 py-1 text-xs font-semibold rounded-md transition-colors ${
              viewMode === 'top10'
                ? 'bg-accent text-accent-fg shadow-sm'
                : 'text-muted hover:text-primary'
            }`}
          >
            Top 10 Issues
          </button>
        </div>

        <span className="text-caption text-muted font-medium">
          {processedIssues.length} {processedIssues.length === 1 ? 'issue' : 'issues'}
        </span>
      </div>

      {/* Status Filter Chips */}
      <div
        data-debug-id="home-issues-status-chips"
        className="px-2 py-1.5 border-b border-subtle flex items-center gap-1.5 overflow-x-auto shrink-0"
      >
        {STATUS_FILTERS.map((f) => (
          <button
            key={f.value}
            type="button"
            data-debug-id={`home-issues-filter-${f.value || 'all'}`}
            onClick={() => setStatusFilter(f.value)}
            className={`px-2.5 py-0.5 text-xs font-semibold rounded-full border transition-colors shrink-0 ${
              statusFilter === f.value
                ? 'bg-accent text-accent-fg border-accent'
                : 'bg-surface text-muted border-subtle hover:text-primary hover:border-strong'
            }`}
          >
            {f.label}
          </button>
        ))}
      </div>

      {/* Issues list items */}
      <div className="flex-1 min-h-0 overflow-y-auto">
        {isLoading ? (
          <div className="p-8 text-center text-muted">
            <Spinner size="md" />
            <p className="mt-2 text-xs">Loading issues…</p>
          </div>
        ) : error ? (
          <div className="p-4 text-center text-danger text-xs">
            <p>Failed to load issues</p>
            <button
              type="button"
              onClick={() => refetch()}
              className="mt-2 text-xs text-accent hover:underline"
            >
              Retry
            </button>
          </div>
        ) : processedIssues.length === 0 ? (
          <div className="p-8 text-center">
            <EmptyState
              icon="alert"
              title={searchQuery.trim() ? 'No matching issues' : 'No issues reported'}
              description={
                searchQuery.trim()
                  ? `No issues match query "${searchQuery}".`
                  : 'Reported bugs and blockers will appear here.'
              }
              data-debug-id="home-issues-empty-state"
            />
          </div>
        ) : (
          <ul className="divide-y divide-subtle list-none p-0 m-0">
            {processedIssues.map((issue) => {
              const id = issue.issue_id || issue.issueId || issue.id;
              const isSelected = selectedId === id;
              return (
                <IssueRow
                  key={id}
                  issue={issue}
                  active={twoPane && isSelected}
                  href={issueViewHref(id)}
                  onOpen={() => setSelectedId(id)}
                  onVoteToggle={() => handleVoteToggle(issue)}
                />
              );
            })}
          </ul>
        )}
      </div>
    </div>
  );

  // Mobile Single-Pane Drilldown View
  if (isMobile) {
    if (selectedId) {
      return (
        <div
          data-debug-id="recent-issues-tab"
          className="flex flex-col h-full min-h-0 w-full overflow-hidden"
        >
          <div className="p-2 border-b border-subtle shrink-0">
            <Button
              variant="ghost"
              size="sm"
              data-debug-id="home-issues-back-btn"
              onClick={() => setSelectedId('')}
              className="gap-1.5 min-h-[44px]"
            >
              <Icon name="chevron-left" size={16} />
              <span>Back to issues</span>
            </Button>
          </div>
          <div className="flex-1 min-h-0 overflow-y-auto p-3">
            <IssueDetail
              issueId={selectedId}
              onBack={() => setSelectedId('')}
              onDelete={() => setSelectedId('')}
            />
          </div>
        </div>
      );
    }

    return (
      <div
        data-debug-id="recent-issues-tab"
        className="flex flex-col h-full min-h-0 w-full overflow-hidden rounded-2xl border border-subtle bg-surface"
      >
        {listColumn}
      </div>
    );
  }

  // Desktop Two-Pane Layout
  return (
    <div
      data-debug-id="recent-issues-tab"
      className="flex min-w-0 items-stretch gap-4 flex-1 min-h-0 h-full overflow-hidden"
    >
      {/* Left Column: List and filters */}
      <div className="w-full min-w-0 max-w-[420px] shrink-0 flex flex-col min-h-0 h-full overflow-hidden rounded-2xl border border-subtle bg-surface">
        {listColumn}
      </div>

      {/* Right Column: Issue detail pane */}
      <div
        data-debug-id="home-issues-detail-pane"
        className="min-w-0 flex-1 rounded-2xl border border-subtle bg-surface p-4 flex flex-col min-h-0 h-full overflow-y-auto"
      >
        {selectedId ? (
          <IssueDetail
            issueId={selectedId}
            onDelete={() => setSelectedId('')}
          />
        ) : (
          <div className="flex h-full items-center justify-center p-6 text-muted">
            <Text role="body-sm" tone="muted">Select an issue to view its details.</Text>
          </div>
        )}
      </div>
    </div>
  );
}

export default RecentIssuesTab;
