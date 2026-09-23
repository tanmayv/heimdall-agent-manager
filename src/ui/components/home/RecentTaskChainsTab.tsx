import React, { useMemo, useState } from 'react';
import { Badge, EmptyState, Icon, Input, Spinner, Text } from '@ui';
import { useIsMobile } from '../shell/responsive';
import { useFetchTaskChainGroupsQuery, type ChainListItem } from '../../api/endpoints/tasks';
import { buildRouteHash } from '../../utils/appLocation';

function shellHash(path: string): string {
  return buildRouteHash(path, '');
}

function formatRelativeTime(dateString: string): string {
  if (!dateString) return '';
  const date = new Date(dateString);
  if (Number.isNaN(date.getTime())) return dateString;
  const now = Date.now();
  const diffMs = now - date.getTime();
  const diffSec = Math.floor(diffMs / 1000);
  const diffMin = Math.floor(diffSec / 60);
  const diffHour = Math.floor(diffMin / 60);
  const diffDay = Math.floor(diffHour / 24);

  if (diffSec < 60) return 'just now';
  if (diffMin < 60) return `${diffMin}m ago`;
  if (diffHour < 24) return `${diffHour}h ago`;
  if (diffDay < 7) return `${diffDay}d ago`;
  return date.toLocaleDateString(undefined, { month: 'short', day: 'numeric' });
}

type StatusFilter = 'all' | 'active' | 'completed';

export function RecentTaskChainsTab() {
  const isMobile = useIsMobile();
  const { data, isLoading, error, refetch } = useFetchTaskChainGroupsQuery();

  const [statusFilter, setStatusFilter] = useState<StatusFilter>('all');
  const [searchQuery, setSearchQuery] = useState('');

  // Extract all chains from all project groups
  const allChains = useMemo(() => {
    const groups = data?.groups || [];
    const list: ChainListItem[] = [];
    for (const g of groups) {
      for (const c of g.chains) {
        list.push({
          ...c,
          projectName: c.projectName || g.projectName || 'Unassigned',
          projectId: c.projectId || g.projectId || '',
        });
      }
    }
    return list;
  }, [data]);

  // Filter for chains with status === 'active' or status === 'completed'
  const filteredChains = useMemo(() => {
    return allChains
      .filter((chain) => {
        const s = (chain.status || '').toLowerCase();
        // REQ-HOME-CHAINS-3: Only active (in progress) or completed chains
        if (s !== 'active' && s !== 'completed') {
          return false;
        }

        // Status tab filter
        if (statusFilter === 'active' && s !== 'active') return false;
        if (statusFilter === 'completed' && s !== 'completed') return false;

        // Search query filter
        if (searchQuery.trim()) {
          const q = searchQuery.toLowerCase().trim();
          const matchesTitle = (chain.title || '').toLowerCase().includes(q);
          const matchesId = (chain.chainId || '').toLowerCase().includes(q);
          const matchesProject = (chain.projectName || '').toLowerCase().includes(q);
          if (!matchesTitle && !matchesId && !matchesProject) {
            return false;
          }
        }

        return true;
      })
      .sort((a, b) => {
        const timeA = new Date(a.updatedAt).getTime() || 0;
        const timeB = new Date(b.updatedAt).getTime() || 0;
        return timeB - timeA;
      });
  }, [allChains, statusFilter, searchQuery]);

  return (
    <div
      data-debug-id="recent-task-chains-tab"
      className="flex flex-col h-full min-h-0 w-full overflow-hidden space-y-4"
    >
      {/* Top Filter and Search Bar */}
      <div className="flex flex-col sm:flex-row items-stretch sm:items-center justify-between gap-3 shrink-0">
        {/* Status filter chips */}
        <div
          data-debug-id="home-chains-status-filters"
          className="flex items-center gap-1.5 overflow-x-auto py-0.5"
        >
          <button
            type="button"
            data-debug-id="home-chains-filter-all"
            onClick={() => setStatusFilter('all')}
            className={`min-h-[36px] sm:min-h-[32px] px-3 py-1 text-xs font-semibold rounded-full border transition-colors ${
              statusFilter === 'all'
                ? 'bg-accent text-accent-fg border-accent'
                : 'bg-surface text-muted border-subtle hover:text-primary hover:border-strong'
            }`}
          >
            All
          </button>
          <button
            type="button"
            data-debug-id="home-chains-filter-active"
            onClick={() => setStatusFilter('active')}
            className={`min-h-[36px] sm:min-h-[32px] px-3 py-1 text-xs font-semibold rounded-full border transition-colors ${
              statusFilter === 'active'
                ? 'bg-accent text-accent-fg border-accent'
                : 'bg-surface text-muted border-subtle hover:text-primary hover:border-strong'
            }`}
          >
            In Progress
          </button>
          <button
            type="button"
            data-debug-id="home-chains-filter-completed"
            onClick={() => setStatusFilter('completed')}
            className={`min-h-[36px] sm:min-h-[32px] px-3 py-1 text-xs font-semibold rounded-full border transition-colors ${
              statusFilter === 'completed'
                ? 'bg-accent text-accent-fg border-accent'
                : 'bg-surface text-muted border-subtle hover:text-primary hover:border-strong'
            }`}
          >
            Completed
          </button>
        </div>

        {/* Search input */}
        <div className="w-full sm:w-72 shrink-0">
          <Input
            value={searchQuery}
            onChange={setSearchQuery}
            width="full"
            leading={<Icon name="search" size="sm" />}
            placeholder="Search chains by title, ID, or project…"
            size="sm"
            data-debug-id="home-chains-search-input"
          />
        </div>
      </div>

      {/* Chain Cards Feed */}
      <div className="flex-1 min-h-0 overflow-y-auto space-y-3 pr-1">
        {isLoading ? (
          <div className="flex flex-col items-center justify-center p-12 text-muted">
            <Spinner size="md" />
            <p className="mt-2 text-xs">Loading task chains…</p>
          </div>
        ) : error ? (
          <div className="rounded-2xl border border-danger/30 bg-danger-soft p-6 text-center text-danger text-sm">
            <p>Failed to load task chains: {String((error as any)?.error || error)}</p>
            <button
              type="button"
              onClick={() => refetch()}
              className="mt-3 inline-flex items-center gap-1.5 px-3 py-1.5 rounded-lg border border-danger/40 bg-surface text-xs font-medium hover:bg-surface-raised"
            >
              <Icon name="refresh" size={13} />
              <span>Retry</span>
            </button>
          </div>
        ) : filteredChains.length === 0 ? (
          <EmptyState
            icon="tasks"
            title={
              searchQuery.trim()
                ? 'No matching task chains found'
                : statusFilter === 'active'
                ? 'No in-progress task chains'
                : statusFilter === 'completed'
                ? 'No completed task chains'
                : 'No recent task chains'
            }
            description={
              searchQuery.trim()
                ? `No active or completed chains match query "${searchQuery}". Try clearing search or filters.`
                : 'Task chains that are in progress or recently completed across projects will appear here.'
            }
            data-debug-id="recent-task-chains-empty-state"
          />
        ) : (
          <div className="grid gap-3">
            {filteredChains.map((chain) => {
              const isActive = (chain.status || '').toLowerCase() === 'active';
              const coordinator = chain.coordinatorAgentInstanceId;
              const conversationHref = coordinator
                ? isMobile
                  ? shellHash(`/conversations/${encodeURIComponent(coordinator)}`)
                  : shellHash(`/conversations/${encodeURIComponent(coordinator)}?panel=tasks`)
                : '';

              return (
                <div
                  key={chain.chainId}
                  data-debug-id={`home-chain-card-${chain.chainId}`}
                  className="rounded-2xl border border-subtle bg-surface p-4 hover:border-strong transition-all space-y-3"
                >
                  {/* Card Header: Status, Title, Task count */}
                  <div className="flex flex-wrap items-start justify-between gap-3">
                    <div className="space-y-1 flex-1 min-w-[240px]">
                      <div className="flex flex-wrap items-center gap-2">
                        <span
                          data-debug-id={`home-chain-status-${chain.chainId}`}
                          className={`inline-flex items-center gap-1 rounded-md border px-2 py-0.5 text-caption font-semibold capitalize ${
                            isActive
                              ? 'bg-accent/10 text-accent border-accent/20'
                              : 'bg-success-soft text-success border-success/20'
                          }`}
                        >
                          <span className={`h-1.5 w-1.5 rounded-full ${isActive ? 'bg-accent animate-pulse' : 'bg-success'}`} />
                          <span>{isActive ? 'In Progress' : 'Completed'}</span>
                        </span>

                        <span
                          data-debug-id={`home-chain-project-${chain.chainId}`}
                          className="inline-flex items-center gap-1 rounded-md border border-subtle bg-surface-raised px-2 py-0.5 text-caption text-muted"
                        >
                          <Icon name="folder" size={11} className="text-accent" />
                          <span>{chain.projectName}</span>
                        </span>

                        <span
                          data-debug-id={`home-chain-tasks-${chain.chainId}`}
                          className="inline-flex items-center gap-1 rounded-md border border-subtle bg-surface-raised px-1.5 py-0.5 text-caption text-muted"
                          title={`${chain.taskCount} tasks`}
                        >
                          <Icon name="tasks" size={11} />
                          <span>{chain.taskCount} {chain.taskCount === 1 ? 'task' : 'tasks'}</span>
                        </span>

                        {chain.updatedAt ? (
                          <span className="text-caption text-muted flex items-center gap-1">
                            <Icon name="clock" size={11} />
                            <span>{formatRelativeTime(chain.updatedAt)}</span>
                          </span>
                        ) : null}
                      </div>

                      <h3
                        data-debug-id={`home-chain-title-${chain.chainId}`}
                        className="text-base font-semibold text-primary"
                      >
                        {chain.title || chain.chainId}
                      </h3>
                      <p className="text-caption font-mono text-muted">{chain.chainId}</p>
                    </div>

                    {/* Action link to Coordinator */}
                    {coordinator ? (
                      <a
                        data-debug-id={`home-chain-link-${chain.chainId}`}
                        href={conversationHref}
                        className="min-h-[44px] sm:min-h-[36px] inline-flex items-center gap-1.5 rounded-xl border border-subtle bg-surface-raised px-3 py-1.5 text-xs font-semibold text-primary hover:bg-neutral-soft hover:text-accent transition-colors shrink-0"
                        title={`Open coordinator conversation (${coordinator})`}
                      >
                        <Icon name="chat" size={13} className="text-accent" />
                        <span>Coordinator</span>
                        <Icon name="chevron-right" size={12} className="text-muted" />
                      </a>
                    ) : (
                      <span className="text-caption text-muted italic">No coordinator assigned</span>
                    )}
                  </div>
                </div>
              );
            })}
          </div>
        )}
      </div>

      {/* Footer count indicator */}
      {!isLoading && !error && filteredChains.length > 0 && (
        <div className="pt-2 border-t border-subtle flex items-center justify-between text-caption text-muted shrink-0">
          <span>Showing {filteredChains.length} {filteredChains.length === 1 ? 'chain' : 'chains'}</span>
          <span>{statusFilter === 'all' ? 'Active & Completed' : statusFilter === 'active' ? 'In Progress' : 'Completed'}</span>
        </div>
      )}
    </div>
  );
}

export default RecentTaskChainsTab;
