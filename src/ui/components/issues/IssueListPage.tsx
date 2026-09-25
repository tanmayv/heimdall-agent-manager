import React, { useEffect, useMemo, useState } from 'react';
import {
  Alert,
  Button,
  Icon,
  ResourceContainer,
  ResourceSearchFilter,
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
  const { data, isLoading, error } = useListIssuesQuery({
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

  const [selectionMode, setSelectionMode] = useState(false);
  const [selectedIds, setSelectedIds] = useState<string[]>([]);

  // List column rendered inside ResourceContainer
  const listColumn = (
    <div
      data-debug-id="issues-list-column"
      className="flex flex-col h-full min-w-0 overflow-hidden"
    >
      {/* Search and Filters via ResourceSearchFilter */}
      <ResourceSearchFilter
        searchQuery={searchQuery}
        onSearchChange={setSearchQuery}
        searchPlaceholder="Search issues…"
        searchDebugId="issues-search-input"
        activeTab={statusFilter}
        onTabChange={setStatusFilter}
        selectionMode={selectionMode}
        onToggleSelection={() => {
          setSelectionMode((prev) => !prev);
          if (selectionMode) setSelectedIds([]);
        }}
        tabs={STATUS_FILTERS.map((tab) => ({
          value: tab.value,
          label: tab.label,
          debugId: `issues-filter-status-${tab.value || 'all'}`,
        }))}
        filters={[
          {
            value: scopeFilter,
            onChange: setScopeFilter,
            options: [
              { value: '', label: 'All Scopes' },
              { value: 'global', label: 'Global' },
              { value: 'project', label: 'Project' },
              { value: 'agent_id', label: 'Agent' },
              { value: 'bridge_id', label: 'Bridge' },
            ],
            ariaLabel: 'Filter by scope',
            debugId: 'issues-scope-filter',
          },
        ]}
      />

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
                  selected={selectedIds.includes(id)}
                  showCheckbox={selectionMode}
                  onSelectedChange={(checked) =>
                    setSelectedIds((prev) =>
                      checked ? [...prev, id] : prev.filter((item) => item !== id),
                    )
                  }
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

  return (
    <ResourceContainer
      title="Issues"
      description="Track, vote, and comment on blockers and bugs reported across task chains and environments."
      breadcrumbs={listCrumbs()}
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
      selectedId={selectedId}
      detailTitle="Issue Details"
      listDebugId="issues-list-column"
      detailDebugId="issues-detail-pane"
      emptyDetailText="Select an issue to see it here."
      list={listColumn}
      detail={
        selectedId ? (
          <IssueDetail
            issueId={selectedId}
            onBack={() => {
              setSelectedId('');
              navigateTo(issuesListHref());
            }}
            onEdit={handleEdit}
            onDelete={() => {
              setSelectedId('');
              if (!twoPane) {
                navigateTo(issuesListHref());
              }
            }}
          />
        ) : null
      }
    />
  );
}

export default IssueListPage;
