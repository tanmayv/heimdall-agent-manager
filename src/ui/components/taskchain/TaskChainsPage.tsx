import React, { useEffect, useMemo, useState } from 'react';
import Icon from '../Icon';
import { buildRouteHash } from '../../utils/appLocation';
import {
  useFetchTaskChainGroupsQuery,
  useFetchTaskChainProjectPageQuery,
  useLazyFetchTaskChainProjectPageQuery,
  type ChainListItem,
  type ChainProjectGroup,
} from '../../api/endpoints/tasks';
import { useListProjectsQuery, type Project } from '../../api/endpoints/projects';
import { TaskChainOverview } from './TaskChainOverview';

interface TaskChainsPageProps {
  chainId?: string;
  isMobile?: boolean;
}

function shellHash(path: string): string {
  return buildRouteHash(path, '');
}

// Per-project preview page size for the "Load more" pager. The default view
// previews up to 5 chains per project (from the grouped endpoint); each Load more
// then pulls a page of this size via the per-project cursor endpoint.
const PAGE_SIZE = 20;

function statusBadgeClass(status: string): string {
  switch (String(status || '').toLowerCase()) {
    case 'active':
      return 'bg-sky-400/10 text-sky-200 border-sky-400/20';
    case 'completed':
      return 'bg-emerald-400/10 text-emerald-200 border-emerald-400/20';
    case 'cancelled':
      return 'bg-zinc-500/10 text-zinc-400 border-white/10';
    default:
      return 'bg-white/5 text-zinc-300 border-white/10';
  }
}

function formatUpdatedAt(value: string): string {
  if (!value) return '';
  const d = new Date(value);
  if (Number.isNaN(d.getTime())) return value;
  return d.toLocaleString(undefined, { month: 'short', day: 'numeric', hour: '2-digit', minute: '2-digit' });
}

// One chain row: status badge + title + updated_at, linking to the coordinator's
// conversation (instance-id route from TC-ROUTING; the id is already in the row,
// so no extra fetch). Rows without a coordinator render as non-clickable.
function ChainRow({ chain }: { chain: ChainListItem }) {
  const coordinator = chain.coordinatorAgentInstanceId;
  const inner = (
    <>
      <span
        data-debug-id={`task-chains-row-status-${chain.chainId}`}
        className={`shrink-0 rounded-md border px-2 py-0.5 text-[11px] font-semibold capitalize ${statusBadgeClass(chain.status)}`}
      >
        {chain.status || 'unknown'}
      </span>
      <span className="min-w-0 flex-1 truncate text-sm text-zinc-100">{chain.title || chain.chainId}</span>
      {chain.updatedAt ? (
        <span className="shrink-0 text-[11px] text-zinc-500">{formatUpdatedAt(chain.updatedAt)}</span>
      ) : null}
    </>
  );
  const className =
    'flex items-center gap-3 rounded-xl border border-white/10 bg-black/20 px-3 py-2.5 transition-colors';
  if (!coordinator) {
    return (
      <div data-debug-id={`task-chains-row-${chain.chainId}`} className={`${className} opacity-70`} title="No coordinator instance to open">
        {inner}
      </div>
    );
  }
  return (
    <a
      data-debug-id={`task-chains-row-${chain.chainId}`}
      href={shellHash(`/conversations/${encodeURIComponent(coordinator)}`)}
      title={`Open coordinator conversation (${coordinator})`}
      className={`${className} hover:bg-white/[0.06]`}
    >
      {inner}
    </a>
  );
}

// A collapsible per-project card that previews chains and pages the rest in via
// the per-project cursor endpoint. `initial*` seed the first page (from either the
// grouped endpoint or the filtered project fetch); further pages accumulate in
// local state. Remounts (keyed by projectId) reset state on filter change.
function ChainGroupCard({
  projectId,
  projectName,
  initialChains,
  initialHasMore,
  initialNextCursor,
  totalCount,
  collapsed,
  onToggle,
}: {
  projectId: string;
  projectName: string;
  initialChains: ChainListItem[];
  initialHasMore: boolean;
  initialNextCursor: string;
  totalCount: number;
  collapsed: boolean;
  onToggle: () => void;
}) {
  const [extra, setExtra] = useState<ChainListItem[]>([]);
  const [cursor, setCursor] = useState<string>(initialNextCursor);
  const [hasMore, setHasMore] = useState<boolean>(initialHasMore);
  const [loadMorePage, { isFetching }] = useLazyFetchTaskChainProjectPageQuery();

  // Reset accumulated pages when the seed changes (e.g. a background refetch of
  // the grouped list, or the filtered project's first page reloading).
  useEffect(() => {
    setExtra([]);
    setCursor(initialNextCursor);
    setHasMore(initialHasMore);
  }, [projectId, initialNextCursor, initialHasMore]);

  const chains = useMemo(() => [...initialChains, ...extra], [initialChains, extra]);

  const onLoadMore = async () => {
    try {
      const res = await loadMorePage({ projectId, limit: PAGE_SIZE, cursor }).unwrap();
      setExtra((prev) => [...prev, ...(res.chains || [])]);
      setCursor(res.nextCursor || '');
      setHasMore(Boolean(res.hasMore));
    } catch {
      // Leave the button in place so the user can retry; RTK surfaces the error
      // state on the trigger if needed.
      setHasMore(true);
    }
  };

  const displayName = projectName || (projectId ? projectId : 'Unassigned');

  return (
    <div
      data-debug-id={`task-chains-project-group-${projectId || 'unassigned'}`}
      className="overflow-hidden rounded-2xl border border-white/10 bg-white/[0.02]"
    >
      <button
        type="button"
        data-debug-id={`task-chains-project-toggle-${projectId || 'unassigned'}`}
        onClick={onToggle}
        className="flex w-full items-center justify-between border-b border-white/10 bg-white/[0.03] px-4 py-3 text-left transition-colors hover:bg-white/[0.05]"
      >
        <div className="flex items-center gap-3">
          <span className="text-zinc-400">
            <Icon name={collapsed ? 'chevron-right' : 'chevron-down'} size={14} />
          </span>
          <div className="flex items-center gap-2">
            <Icon name="folder" size={15} className="text-sky-400" />
            <span className="text-sm font-semibold text-white">{displayName}</span>
          </div>
        </div>
        <span
          data-debug-id={`task-chains-project-count-${projectId || 'unassigned'}`}
          className="rounded-md border border-white/10 bg-black/40 px-2 py-0.5 text-xs text-zinc-400"
        >
          {totalCount} {totalCount === 1 ? 'chain' : 'chains'}
        </span>
      </button>

      {!collapsed && (
        <div className="space-y-2 p-4">
          {chains.length === 0 ? (
            <p className="py-2 text-xs italic text-zinc-500">No task chains in this project.</p>
          ) : (
            chains.map((chain) => <ChainRow key={chain.chainId} chain={chain} />)
          )}
          {hasMore && (
            <button
              type="button"
              data-debug-id={`task-chains-load-more-${projectId || 'unassigned'}`}
              onClick={() => void onLoadMore()}
              disabled={isFetching}
              className="mt-1 w-full rounded-xl border border-white/10 bg-white/[0.03] px-3 py-2 text-xs font-semibold text-zinc-300 transition-colors hover:bg-white/[0.06] disabled:opacity-50"
            >
              {isFetching ? 'Loading…' : 'Load more'}
            </button>
          )}
        </div>
      )}
    </div>
  );
}

export const TaskChainsPage: React.FC<TaskChainsPageProps> = ({ chainId: initialChainId, isMobile }) => {
  const [selectedChainId, setSelectedChainId] = useState<string>(initialChainId || '');
  const [filterProjectId, setFilterProjectId] = useState<string>('');
  const [collapsed, setCollapsed] = useState<Record<string, boolean>>({});

  useEffect(() => {
    setSelectedChainId(initialChainId || '');
  }, [initialChainId]);

  // KEEP the chain-detail branch (deep link / row click into a specific chain).
  const showList = !selectedChainId;

  const groupsQuery = useFetchTaskChainGroupsQuery(undefined, { skip: !showList || Boolean(filterProjectId) });
  const projectPageQuery = useFetchTaskChainProjectPageQuery(
    { projectId: filterProjectId, limit: PAGE_SIZE },
    { skip: !showList || !filterProjectId },
  );
  const projectsQuery = useListProjectsQuery();

  const projects: Project[] = projectsQuery.data?.projects || [];
  const groups: ChainProjectGroup[] = useMemo(() => {
    if (filterProjectId) {
      return projectPageQuery.data ? [projectPageQuery.data] : [];
    }
    return groupsQuery.data?.groups || [];
  }, [filterProjectId, projectPageQuery.data, groupsQuery.data]);

  const totalChains = useMemo(() => groups.reduce((sum, g) => sum + (g.chainTotal || g.chains.length), 0), [groups]);
  const isLoading = filterProjectId ? projectPageQuery.isLoading : groupsQuery.isLoading;
  const error = filterProjectId ? projectPageQuery.error : groupsQuery.error;

  const toggleCollapse = (projectId: string) => {
    const key = projectId || '__unassigned__';
    setCollapsed((prev) => ({ ...prev, [key]: !prev[key] }));
  };

  if (selectedChainId) {
    return (
      <div className="h-full w-full">
        <TaskChainOverview chainId={selectedChainId} onClose={() => setSelectedChainId('')} isMobile={isMobile} />
      </div>
    );
  }

  return (
    <div data-debug-id="task-chains-page" className="w-full max-w-4xl text-left">
      {/* Header: title + count pill + description (mirrors the Actions page) */}
      <div className="mb-5">
        <div className="flex items-center gap-3">
          <h1 className="text-2xl font-bold text-white">Task Chains</h1>
          <span data-debug-id="task-chains-total-count" className="rounded-md border border-white/10 bg-black/40 px-2 py-0.5 text-xs text-zinc-400">
            {totalChains} {totalChains === 1 ? 'chain' : 'chains'}
          </span>
        </div>
        <p className="mt-1.5 text-sm text-zinc-400">
          Multi-agent workflows grouped by project. Open a chain's coordinator conversation to follow its tasks, dependencies, and reviews.
        </p>
      </div>

      {/* Project filter */}
      <div className="mb-5 flex items-center gap-2">
        <label htmlFor="task-chains-project-filter" className="text-xs text-zinc-500">
          Project
        </label>
        <select
          id="task-chains-project-filter"
          data-debug-id="task-chains-project-filter"
          value={filterProjectId}
          onChange={(e) => setFilterProjectId(e.target.value)}
          className="rounded-xl border border-white/10 bg-black/30 px-3 py-1.5 text-sm text-zinc-200 outline-none focus:border-sky-400"
        >
          <option value="">All projects</option>
          {projects.map((p) => (
            <option key={p.project_id} value={p.project_id}>
              {p.name || p.project_id}
            </option>
          ))}
        </select>
      </div>

      {isLoading && (
        <div data-debug-id="task-chains-loading" className="rounded-2xl border border-white/10 bg-white/[0.02] p-6 text-sm text-zinc-400">
          Loading task chains…
        </div>
      )}

      {!isLoading && error && (
        <div data-debug-id="task-chains-error" className="rounded-xl border border-red-500/40 bg-red-950/20 p-5 text-sm text-red-300">
          Failed to load task chains: {String((error as any)?.error || (error as any)?.message || error)}
        </div>
      )}

      {!isLoading && !error && groups.length === 0 && (
        <div
          data-debug-id="task-chains-empty-state"
          className="flex flex-col items-center justify-center rounded-2xl border border-dashed border-white/10 bg-white/[0.01] p-12 text-center"
        >
          <div className="mb-4 grid h-12 w-12 place-items-center rounded-2xl bg-white/5 text-zinc-400">
            <Icon name="tasks" size={24} />
          </div>
          <h3 className="text-base font-semibold text-white">No Task Chains</h3>
          <p className="mt-1 max-w-md text-xs leading-relaxed text-zinc-400">
            {filterProjectId
              ? 'This project has no task chains yet.'
              : 'Task chains appear here once a coordinator starts a multi-agent workflow.'}
          </p>
        </div>
      )}

      {!isLoading && !error && groups.length > 0 && (
        <div data-debug-id="task-chains-project-groups" className="space-y-6">
          {groups.map((group) => {
            const key = group.projectId || '__unassigned__';
            return (
              <ChainGroupCard
                key={key}
                projectId={group.projectId}
                projectName={group.projectName}
                initialChains={group.chains}
                initialHasMore={group.hasMore}
                initialNextCursor={group.nextCursor}
                totalCount={group.chainTotal || group.chains.length}
                collapsed={Boolean(collapsed[key])}
                onToggle={() => toggleCollapse(group.projectId)}
              />
            );
          })}
        </div>
      )}
    </div>
  );
};

export default TaskChainsPage;
