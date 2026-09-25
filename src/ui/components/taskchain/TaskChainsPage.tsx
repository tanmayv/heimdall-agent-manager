import React, { useEffect, useMemo, useState } from 'react';
import { Badge, PageShell, Select } from '@ui';
import Icon from '../Icon';
import { buildRouteHash } from '../../utils/appLocation';
import ProjectLaunchModal from '../projects/ProjectLaunchModal';
import {
  useFetchTaskChainGroupsQuery,
  useFetchTaskChainProjectPageQuery,
  useLazyFetchTaskChainProjectPageQuery,
  useUpdateTaskChainMutation,
  type ChainListItem,
  type ChainProjectGroup,
} from '../../api/endpoints/tasks';
import { useListProjectsQuery, type Project } from '../../api/endpoints/projects';
import { useArchivedProjectIds } from '../projects/projectModel';
import { useIsMobile } from '../shell/responsive';
import { writeRightSidebarOpen } from '../../utils/clientPersistence';
import { TaskChainOverview } from './TaskChainOverview';
import { VaultText } from '../vault/VaultText';

interface TaskChainsPageProps {
  chainId?: string;
  // Optional deep-link target task (from '/chains/:chainId/tasks/:taskId'); the
  // chain view auto-opens + scrolls to it. Undefined for the plain chain route.
  taskId?: string;
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
      return 'bg-accent/10 text-accent border-accent/20';
    case 'completed':
      return 'bg-success-soft text-success border-success/20';
    case 'archived':
      return 'bg-warning-soft text-warning border-warning/30';
    case 'cancelled':
      return 'bg-neutral-soft text-muted border-subtle';
    default:
      return 'bg-neutral-soft text-muted border-subtle';
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
function ChainRow({
  chain,
  onArchive,
  onRestore,
}: {
  chain: ChainListItem;
  onArchive?: (chainId: string) => void;
  onRestore?: (chainId: string) => void;
}) {
  const coordinator = chain.coordinatorAgentInstanceId;
  const isMobile = useIsMobile();
  const isArchived = chain.status === 'archived';

  const inner = (
    <>
      <span
        data-debug-id={`task-chains-row-status-${chain.chainId}`}
        className={`shrink-0 rounded-md border px-2 py-0.5 text-caption font-semibold capitalize ${statusBadgeClass(chain.status)}`}
      >
        {chain.status || 'unknown'}
      </span>
      <span className="min-w-0 flex-1 truncate text-sm text-primary">
        <VaultText value={chain.title} fallback={chain.chainId} />
      </span>
      <span
        data-debug-id={`task-chains-row-task-count-${chain.chainId}`}
        className="shrink-0 rounded-md border border-subtle bg-surface-raised px-1.5 py-0.5 text-caption text-muted"
        title={`${chain.taskCount} ${chain.taskCount === 1 ? 'task' : 'tasks'}`}
      >
        {chain.taskCount}
      </span>
      {chain.updatedAt ? (
        <span className="shrink-0 text-caption text-faint">{formatUpdatedAt(chain.updatedAt)}</span>
      ) : null}
    </>
  );
  const className =
    'flex items-center gap-3 rounded-xl border border-subtle bg-surface px-3 py-2.5 transition-colors';

  const href = isMobile
    ? shellHash(`/conversations/${encodeURIComponent(coordinator)}`)
    : shellHash(`/conversations/${encodeURIComponent(coordinator)}?panel=tasks`);

  return (
    <div
      data-debug-id={`task-chains-row-${chain.chainId}`}
      className={`${className} justify-between hover:bg-surface-raised`}
    >
      {coordinator ? (
        <a
          href={href}
          title={`Open coordinator conversation (${coordinator})`}
          onClick={() => {
            if (isMobile) {
              writeRightSidebarOpen(false);
              window.dispatchEvent(new CustomEvent('heimdall:close-sidebar'));
            }
          }}
          className="flex min-w-0 flex-1 items-center gap-3 overflow-hidden"
        >
          {inner}
        </a>
      ) : (
        <div className="flex min-w-0 flex-1 items-center gap-3 opacity-70" title="No coordinator instance to open">
          {inner}
        </div>
      )}

      <div className="flex shrink-0 items-center gap-2 pl-2" data-debug-id={`task-chains-row-actions-${chain.chainId}`}>
        {isArchived ? (
          <button
            type="button"
            data-debug-id={`task-chains-restore-btn-${chain.chainId}`}
            onClick={(e) => {
              e.preventDefault();
              e.stopPropagation();
              onRestore?.(chain.chainId);
            }}
            title="Restore chain to active"
            aria-label="Restore chain to active"
            className="rounded-lg border border-subtle bg-surface px-2.5 py-1 text-xs font-semibold text-primary transition-colors hover:border-strong hover:bg-surface-raised"
          >
            Restore
          </button>
        ) : (
          <button
            type="button"
            data-debug-id={`task-chains-archive-btn-${chain.chainId}`}
            onClick={(e) => {
              e.preventDefault();
              e.stopPropagation();
              onArchive?.(chain.chainId);
            }}
            title="Archive chain"
            aria-label="Archive chain"
            className="rounded-lg border border-subtle bg-surface px-2.5 py-1 text-xs text-muted transition-colors hover:border-warning/40 hover:bg-warning-soft hover:text-warning"
          >
            Archive chain
          </button>
        )}
      </div>
    </div>
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
  onlyWithTasks,
  filterStatus,
  collapsed,
  onToggle,
  onLaunchProject,
  onArchiveChain,
  onRestoreChain,
}: {
  projectId: string;
  projectName: string;
  initialChains: ChainListItem[];
  initialHasMore: boolean;
  initialNextCursor: string;
  totalCount: number;
  onlyWithTasks: boolean;
  filterStatus: 'active' | 'completed' | 'archived' | 'all';
  collapsed: boolean;
  onToggle: () => void;
  onLaunchProject?: (project: { projectId: string; name: string }) => void;
  onArchiveChain?: (chainId: string) => void;
  onRestoreChain?: (chainId: string) => void;
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

  const rawChains = useMemo(() => [...initialChains, ...extra], [initialChains, extra]);

  const chains = useMemo(() => {
    return rawChains.filter((c) => {
      if (filterStatus === 'active') return c.status === 'active';
      if (filterStatus === 'completed') return c.status === 'completed';
      if (filterStatus === 'archived') return c.status === 'archived';
      return true;
    });
  }, [rawChains, filterStatus]);

  const onLoadMore = async () => {
    try {
      const res = await loadMorePage({
        projectId,
        limit: PAGE_SIZE,
        cursor,
        hasTasks: onlyWithTasks,
        includeArchived: filterStatus === 'archived' || filterStatus === 'all',
      }).unwrap();
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
  const hasProject = Boolean(projectId && projectId !== '__unassigned__');

  return (
    <div
      data-debug-id={`task-chains-project-group-${projectId || 'unassigned'}`}
      className="overflow-hidden rounded-2xl border border-subtle bg-surface"
    >
      <div className="flex items-center justify-between border-b border-subtle bg-surface-raised px-4 py-3 transition-colors hover:bg-neutral-soft">
        <button
          type="button"
          data-debug-id={`task-chains-project-toggle-${projectId || 'unassigned'}`}
          onClick={onToggle}
          className="flex flex-1 items-center gap-3 text-left"
        >
          <span className="text-muted">
            <Icon name={collapsed ? 'chevron-right' : 'chevron-down'} size={14} />
          </span>
          <div className="flex items-center gap-2">
            <Icon name="folder" size={15} className="text-accent" />
            <span className="text-sm font-semibold text-primary">{displayName}</span>
          </div>
        </button>
        <div className="flex items-center gap-2">
          {hasProject && (
            <button
              type="button"
              data-debug-id={`task-chains-project-launch-btn-${projectId}`}
              onClick={(e) => {
                e.stopPropagation();
                onLaunchProject?.({ projectId, name: projectName || displayName });
              }}
              title={`Launch agent for ${displayName}`}
              aria-label={`Launch agent for ${displayName}`}
              className="flex h-6 w-6 items-center justify-center rounded-lg border border-subtle bg-neutral-soft text-muted transition-colors hover:border-strong hover:bg-surface-raised hover:text-primary"
            >
              <Icon name="plus" size={13} />
            </button>
          )}
          <span
            data-debug-id={`task-chains-project-count-${projectId || 'unassigned'}`}
            className="rounded-md border border-subtle bg-surface px-2 py-0.5 text-xs text-muted"
          >
            {totalCount} {totalCount === 1 ? 'chain' : 'chains'}
          </span>
        </div>
      </div>

      {!collapsed && (
        <div className="space-y-2 p-4">
          {chains.length === 0 ? (
            <p className="py-2 text-xs italic text-faint">No task chains in this project.</p>
          ) : (
            chains.map((chain) => (
              <ChainRow
                key={chain.chainId}
                chain={chain}
                onArchive={onArchiveChain}
                onRestore={onRestoreChain}
              />
            ))
          )}
          {hasMore && (
            <button
              type="button"
              data-debug-id={`task-chains-load-more-${projectId || 'unassigned'}`}
              onClick={() => void onLoadMore()}
              disabled={isFetching}
              className="mt-1 w-full rounded-xl border border-subtle bg-surface-raised px-3 py-2 text-xs font-semibold text-muted transition-colors hover:bg-neutral-soft hover:text-primary disabled:opacity-50"
            >
              {isFetching ? 'Loading…' : 'Load more'}
            </button>
          )}
        </div>
      )}
    </div>
  );
}

export const TaskChainsPage: React.FC<TaskChainsPageProps> = ({ chainId: initialChainId, taskId: focusTaskId, isMobile }) => {
  const [selectedChainId, setSelectedChainId] = useState<string>(initialChainId || '');
  const [filterProjectId, setFilterProjectId] = useState<string>('');
  const [filterStatus, setFilterStatus] = useState<'active' | 'completed' | 'archived' | 'all'>('active');
  // Roughly half of real chains carry no tasks yet and have nothing to show, so
  // the list hides them by default; the toggle brings them back.
  const [onlyWithTasks, setOnlyWithTasks] = useState<boolean>(true);
  const [showArchivedProjects, setShowArchivedProjects] = useState<boolean>(false);
  const [collapsed, setCollapsed] = useState<Record<string, boolean>>({});
  const [launchModalProject, setLaunchModalProject] = useState<{ projectId: string; name: string } | null>(null);

  useEffect(() => {
    setSelectedChainId(initialChainId || '');
  }, [initialChainId]);

  // KEEP the chain-detail branch (deep link / row click into a specific chain).
  const showList = !selectedChainId;

  const shouldIncludeArchived = showArchivedProjects || filterStatus === 'archived' || filterStatus === 'all';

  const groupsQuery = useFetchTaskChainGroupsQuery(
    { hasTasks: onlyWithTasks, includeArchived: shouldIncludeArchived },
    { skip: !showList || Boolean(filterProjectId) },
  );
  const projectPageQuery = useFetchTaskChainProjectPageQuery(
    { projectId: filterProjectId, limit: PAGE_SIZE, hasTasks: onlyWithTasks, includeArchived: shouldIncludeArchived },
    { skip: !showList || !filterProjectId },
  );
  const projectsQuery = useListProjectsQuery();
  const archivedProjectIds = useArchivedProjectIds();

  const [updateTaskChain] = useUpdateTaskChainMutation();

  const handleArchiveChain = async (chainId: string) => {
    try {
      await updateTaskChain({ chainId, status: 'archived' }).unwrap();
    } catch (err: any) {
      console.error('Failed to archive task chain:', err);
    }
  };

  const handleRestoreChain = async (chainId: string) => {
    try {
      await updateTaskChain({ chainId, status: 'active' }).unwrap();
    } catch (err: any) {
      console.error('Failed to restore task chain:', err);
    }
  };

  const projects: Project[] = useMemo(() => {
    const list: Project[] = projectsQuery.data?.projects || [];
    if (showArchivedProjects) return list;
    return list.filter((p) => !archivedProjectIds.has(p.project_id));
  }, [projectsQuery.data, showArchivedProjects, archivedProjectIds]);

  const rawGroups: ChainProjectGroup[] = useMemo(() => {
    const raw = filterProjectId
      ? (projectPageQuery.data ? [projectPageQuery.data] : [])
      : (groupsQuery.data?.groups || []);
    if (!showArchivedProjects) {
      return raw.filter((g) => !g.projectId || !archivedProjectIds.has(g.projectId));
    }
    return raw;
  }, [filterProjectId, projectPageQuery.data, groupsQuery.data, showArchivedProjects, archivedProjectIds]);

  const groups: ChainProjectGroup[] = useMemo(() => {
    return rawGroups
      .map((g) => {
        const matching = g.chains.filter((c) => {
          if (filterStatus === 'active') return c.status === 'active';
          if (filterStatus === 'completed') return c.status === 'completed';
          if (filterStatus === 'archived') return c.status === 'archived';
          return true;
        });
        return {
          ...g,
          chains: matching,
          chainTotal: matching.length,
        };
      })
      .filter((g) => Boolean(filterProjectId) || g.chains.length > 0);
  }, [rawGroups, filterStatus, filterProjectId]);

  const totalChains = useMemo(() => groups.reduce((sum, g) => sum + (g.chainTotal || g.chains.length), 0), [groups]);
  const isLoading = filterProjectId ? projectPageQuery.isLoading : groupsQuery.isLoading;
  const error = filterProjectId ? projectPageQuery.error : groupsQuery.error;

  const toggleCollapse = (projectId: string) => {
    const key = projectId || '__unassigned__';
    setCollapsed((prev) => ({ ...prev, [key]: !prev[key] }));
  };

  if (selectedChainId) {
    return (
      <div className="h-full w-full max-w-full min-w-0 overflow-x-hidden">
        <TaskChainOverview chainId={selectedChainId} focusTaskId={focusTaskId} onClose={() => setSelectedChainId('')} isMobile={isMobile} />
      </div>
    );
  }

  return (
    <PageShell
      title={
        <span className="inline-flex items-center gap-2.5">
          Task Chains
          <Badge data-debug-id="task-chains-total-count" tone="info">
            {totalChains} {totalChains === 1 ? 'chain' : 'chains'}
          </Badge>
        </span>
      }
      description="Multi-agent workflows grouped by project. Open a chain's coordinator conversation to follow its tasks, dependencies, and reviews."
    >
      <div data-debug-id="task-chains-page" className="text-left">
      {/* Project and status filters */}
      <div className="mb-5 flex flex-wrap items-center gap-2">
        <label htmlFor="task-chains-project-filter" className="text-xs text-muted">
          Project
        </label>
        <Select
          id="task-chains-project-filter"
          data-debug-id="task-chains-project-filter"
          size="sm"
          value={filterProjectId}
          onChange={setFilterProjectId}
        >
          <option value="">All projects</option>
          {projects.map((p) => (
            <option key={p.project_id} value={p.project_id}>
              {p.name || p.project_id}
            </option>
          ))}
        </Select>

        <label htmlFor="task-chains-status-filter" className="ml-1 text-xs text-muted">
          Status
        </label>
        <Select
          id="task-chains-status-filter"
          data-debug-id="task-chains-status-filter"
          size="sm"
          value={filterStatus}
          onChange={(val) => setFilterStatus(val as any)}
        >
          <option value="active">Active</option>
          <option value="completed">Completed</option>
          <option value="archived">Archived</option>
          <option value="all">All</option>
        </Select>

        <label
          htmlFor="task-chains-has-tasks-filter"
          className="ml-1 inline-flex min-h-[32px] cursor-pointer items-center gap-2 rounded-xl border border-subtle bg-surface px-3 py-1.5 text-sm text-muted"
        >
          <input
            id="task-chains-has-tasks-filter"
            data-debug-id="task-chains-has-tasks-filter"
            type="checkbox"
            checked={onlyWithTasks}
            onChange={(e) => setOnlyWithTasks(e.target.checked)}
            className="h-4 w-4 accent-accent"
          />
          Only chains with tasks
        </label>

        <label
          htmlFor="task-chains-include-archived-filter"
          className="ml-1 inline-flex min-h-[32px] cursor-pointer items-center gap-2 rounded-xl border border-subtle bg-surface px-3 py-1.5 text-sm text-muted"
        >
          <input
            id="task-chains-include-archived-filter"
            data-debug-id="task-chains-include-archived-filter"
            type="checkbox"
            checked={showArchivedProjects}
            onChange={(e) => setShowArchivedProjects(e.target.checked)}
            className="h-4 w-4 accent-accent"
          />
          Include archived projects
        </label>
      </div>

      {isLoading && (
        <div data-debug-id="task-chains-loading" className="rounded-2xl border border-subtle bg-surface p-6 text-sm text-muted">
          Loading task chains…
        </div>
      )}

      {!isLoading && error && (
        <div data-debug-id="task-chains-error" className="rounded-xl border border-danger/30 bg-danger-soft p-5 text-sm text-danger">
          Failed to load task chains: {String((error as any)?.error || (error as any)?.message || error)}
        </div>
      )}

      {!isLoading && !error && groups.length === 0 && (
        <div
          data-debug-id="task-chains-empty-state"
          className="flex flex-col items-center justify-center rounded-2xl border border-dashed border-subtle bg-surface/50 p-12 text-center"
        >
          <div className="mb-4 grid h-12 w-12 place-items-center rounded-2xl bg-neutral-soft text-muted">
            <Icon name="tasks" size={24} />
          </div>
          <h3 className="text-base font-semibold text-primary">No Task Chains</h3>
          <p className="mt-1 max-w-md text-xs leading-relaxed text-muted">
            {filterProjectId
              ? 'This project has no task chains matching filter.'
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
                onlyWithTasks={onlyWithTasks}
                filterStatus={filterStatus}
                collapsed={Boolean(collapsed[key])}
                onToggle={() => toggleCollapse(group.projectId)}
                onLaunchProject={setLaunchModalProject}
                onArchiveChain={handleArchiveChain}
                onRestoreChain={handleRestoreChain}
              />
            );
          })}
        </div>
      )}

      <ProjectLaunchModal
        isOpen={Boolean(launchModalProject)}
        project={launchModalProject}
        onClose={() => setLaunchModalProject(null)}
        onLaunched={(instanceId) => {
          setLaunchModalProject(null);
          window.location.hash = buildRouteHash('/conversations/' + encodeURIComponent(instanceId), '');
        }}
      />
      </div>
    </PageShell>
  );
};

export default TaskChainsPage;
