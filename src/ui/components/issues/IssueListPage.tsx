import React, { useEffect, useMemo, useState } from 'react';
import {
  Alert,
  Button,
  EmptyState,
  Icon,
  Input,
  PageShell,
  Select,
  Tab,
  Tabs,
  TabsList,
  Text,
  useViewport,
} from '@ui';
import type { Issue } from '../../api/endpoints/issues';
import {
  useDeleteIssueMutation,
  useListIssuesQuery,
  useUnvoteIssueMutation,
  useVoteIssueMutation,
} from '../../api/endpoints/issues';
import { getRoutePathname } from '../../utils/appLocation';
import { IssueDetail } from './IssueDetail';
import { IssueRow } from './IssueRow';
import {
  issueEditHref,
  issueNewHref,
  issuesListHref,
  issueStatus,
  issueTitle,
  issueViewHref,
  listCrumbs,
  navigateTo,
} from './issueModel';

const STATUS_FILTERS = [
  { value: '', label: 'All' },
  { value: 'new', label: 'New' },
  { value: 'fixed', label: 'Fixed' },
  { value: 'obsolete', label: 'Obsolete' },
];

export interface IssueListPageProps {
  selectedIssueId?: string;
}

export function IssueListPage({ selectedIssueId }: IssueListPageProps) {
  const viewport = useViewport();
  const twoPane = viewport === 'desktop';

  const routePath = getRoutePathname();
  const pathIssueId =
    routePath.startsWith('/issues/') &&
    !routePath.endsWith('/new') &&
    !routePath.endsWith('/edit')
      ? decodeURIComponent(routePath.slice('/issues/'.length))
      : '';

  const [selectedId, setSelectedId] = useState<string>(
    selectedIssueId || pathIssueId || '',
  );

  useEffect(() => {
    if (selectedIssueId) {
      setSelectedId(selectedIssueId);
    } else if (pathIssueId) {
      setSelectedId(pathIssueId);
    }
  }, [selectedIssueId, pathIssueId]);

  const [statusFilter, setStatusFilter] = useState('');
  const [scopeFilter, setScopeFilter] = useState('');
  const [searchQuery, setSearchQuery] = useState('');

  // Fetch list of issues with reactive filters
  const { data, isLoading, error, refetch } = useListIssuesQuery({
    status: statusFilter || undefined,
    scope: scopeFilter || undefined,
    q: searchQuery.trim() || undefined,
    limit: 100,
  });

  const issues: Issue[] = useMemo(() => {
    return data?.items || [];
  }, [data]);

  // If in two-pane mode and an issue is selected, but not found in current results, keep selectedId
  // If no issue is selected in twoPane, auto-select the first issue if available
  useEffect(() => {
    if (twoPane && !selectedId && issues.length > 0) {
      setSelectedId(issues[0].issue_id || issues[0].issueId || issues[0].id);
    }
  }, [twoPane, selectedId, issues]);

  const [voteIssue] = useVoteIssueMutation();
  const [unvoteIssue] = useUnvoteIssueMutation();
  const [deleteIssue] = useDeleteIssueMutation();

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

  const handleOpen = (issue: Issue) => {
    const id = issue.issue_id || issue.issueId || issue.id;
    setSelectedId(id);
    if (!twoPane) {
      navigateTo(issueViewHref(id));
    }
  };

  const handleEdit = (issue: Issue) => {
    const id = issue.issue_id || issue.issueId || issue.id;
    navigateTo(issueEditHref(id));
  };

  const handleDelete = async (issue: Issue) => {
    const id = issue.issue_id || issue.issueId || issue.id;
    if (!window.confirm(`Delete issue "${issueTitle(issue)}"?`)) return;
    try {
      await deleteIssue({ issueId: id }).unwrap();
      if (selectedId === id) {
        setSelectedId('');
      }
    } catch (err: any) {
      alert(String(err?.data?.message || err?.message || 'Failed to delete issue'));
    }
  };

  // List column rendered inside split pane or as standalone list
  const listColumn = (
    <div
      data-debug-id="issues-list-column"
      className="flex flex-col h-full min-w-0 overflow-hidden"
    >
      {/* Search Bar */}
      <div className="p-2 border-b border-subtle flex items-center gap-2 shrink-0">
        <Input
          value={searchQuery}
          onChange={setSearchQuery}
          width="full"
          leading={<Icon name="search" size="sm" />}
          placeholder="Search issues…"
          size="sm"
          data-debug-id="issues-search-input"
        />
      </div>

      {/* Filter Row: Status Tabs & Scope Selector */}
      <div className="flex items-center justify-between border-b border-subtle shrink-0">
        <Tabs value={statusFilter} onChange={(val) => setStatusFilter(val)}>
          <TabsList label="Issue status" className="border-b-0">
            {STATUS_FILTERS.map((tab) => (
              <Tab
                key={tab.value}
                value={tab.value}
                data-debug-id={`issues-filter-status-${tab.value || 'all'}`}
              >
                {tab.label}
              </Tab>
            ))}
          </TabsList>
        </Tabs>

        {/* Scope selector */}
        <div className="w-32 shrink-0 py-1 pr-2">
          <Select
            value={scopeFilter}
            onChange={setScopeFilter}
            size="sm"
            aria-label="Filter by scope"
            data-debug-id="issues-scope-filter"
            options={[
              { value: '', label: 'All Scopes' },
              { value: 'global', label: 'Global' },
              { value: 'project', label: 'Project' },
              { value: 'agent_id', label: 'Agent' },
              { value: 'bridge_id', label: 'Bridge' },
            ]}
          />
        </div>
      </div>

      {/* List items */}
      <div className="flex-1 min-h-0 overflow-y-auto">
        {isLoading ? (
          <div className="p-8 text-center text-muted">
            <Icon name="refresh" className="animate-spin inline-block mb-2" size={18} />
            <p className="text-xs">Loading issues...</p>
          </div>
        ) : error ? (
          <div className="p-4">
            <Alert tone="danger" title="Failed to load issues">
              {String((error as any)?.error || error)}
            </Alert>
          </div>
        ) : issues.length === 0 ? (
          <div className="p-8 text-center text-muted">
            <div className="mx-auto w-10 h-10 mb-3 rounded-full bg-neutral-soft grid place-items-center text-muted">
              <Icon name="alert" size={20} />
            </div>
            <p className="text-sm font-medium text-primary">No issues found</p>
            <p className="text-xs text-muted mt-1">
              {searchQuery || statusFilter || scopeFilter
                ? 'Try clearing your search filters.'
                : 'No issues have been reported yet.'}
            </p>
            <Button
              variant="secondary"
              size="sm"
              onClick={() => navigateTo(issueNewHref())}
              className="mt-4"
            >
              Report an issue
            </Button>
          </div>
        ) : (
          <ul className="flex flex-col">
            {issues.map((issue) => {
              const id = issue.issue_id || issue.issueId || issue.id;
              return (
                <IssueRow
                  key={id}
                  issue={issue}
                  href={issueViewHref(id)}
                  active={selectedId === id}
                  onOpen={handleOpen}
                  onVoteToggle={handleVoteToggle}
                  onEdit={handleEdit}
                  onDelete={handleDelete}
                />
              );
            })}
          </ul>
        )}
      </div>

      {/* Footer count */}
      <div className="p-2 border-t border-subtle text-[11px] text-muted text-right px-3 shrink-0">
        {issues.length} {issues.length === 1 ? 'issue' : 'issues'}
      </div>
    </div>
  );

  // Single pane layout (Mobile / Tablet)
  if (!twoPane) {
    if (selectedId) {
      return (
        <PageShell
          width="full"
          breadcrumbs={listCrumbs()}
          title="Issue Details"
          className="h-full min-h-0 overflow-hidden"
        >
          <div className="h-full min-h-0 overflow-hidden">
            <IssueDetail
              issueId={selectedId}
              onBack={() => {
                setSelectedId('');
                navigateTo(issuesListHref());
              }}
              onEdit={handleEdit}
              onDelete={() => {
                setSelectedId('');
                navigateTo(issuesListHref());
              }}
            />
          </div>
        </PageShell>
      );
    }

    return (
      <PageShell
        width="full"
        rhythm="banded"
        breadcrumbs={listCrumbs()}
        title="Issues"
        description="Track, vote, and comment on blockers and bugs reported across task chains and environments."
        className="h-full min-h-0 overflow-hidden"
        actions={
          <Button
            variant="primary"
            data-debug-id="issues-header-new-btn"
            leading={<Icon name="plus" size="sm" />}
            onClick={() => navigateTo(issueNewHref())}
          >
            New issue
          </Button>
        }
      >
        <div className="h-full min-h-0 overflow-hidden">{listColumn}</div>
      </PageShell>
    );
  }

  // Two-pane split view (Desktop / Wide)
  return (
    <PageShell
      width="full"
      rhythm="banded"
      breadcrumbs={listCrumbs()}
      title="Issues"
      description="Track, vote, and comment on blockers and bugs reported across task chains and environments."
      className="h-full min-h-0 overflow-hidden"
      actions={
        <Button
          variant="primary"
          data-debug-id="issues-header-new-btn"
          leading={<Icon name="plus" size="sm" />}
          onClick={() => navigateTo(issueNewHref())}
        >
          New issue
        </Button>
      }
    >
      <div className="flex min-w-0 items-stretch gap-4 flex-1 min-h-0 h-full overflow-hidden">
        {/* Left column: List and filters */}
        <div className="w-full min-w-0 max-w-[420px] shrink-0 flex flex-col min-h-0 h-full overflow-hidden">
          {listColumn}
        </div>

        {/* Right column: Issue detail pane */}
        <div
          data-debug-id="issues-detail-pane"
          className="min-w-0 flex-1 border-l border-subtle pl-4 flex flex-col min-h-0 h-full overflow-hidden"
        >
          {selectedId ? (
            <IssueDetail
              issueId={selectedId}
              onEdit={handleEdit}
              onDelete={() => {
                setSelectedId('');
              }}
            />
          ) : (
            <div className="flex h-full items-center justify-center p-6">
              <Text role="body-sm" tone="muted">Select an issue to see it here.</Text>
            </div>
          )}
        </div>
      </div>
    </PageShell>
  );
}

export default IssueListPage;
