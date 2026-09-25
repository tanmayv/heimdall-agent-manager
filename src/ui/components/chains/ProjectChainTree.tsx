import { useState, useMemo } from 'react';
import { useDispatch } from 'react-redux';
import {
  useListTaskChainsQuery,
  useListPinnedTaskChainsQuery,
  useTogglePinTaskChainMutation,
} from '../../api/endpoints/tasks';
import type { ChainListItem } from '../../api/endpoints/tasks';
import { showToast } from '../../store/toastSlice';
import { useArchivedProjectIds } from '../projects/projectModel';
import CreateChainModal from './CreateChainModal';
import { StatusDot, Icon, Menu } from '@ui';
import { VaultText } from '../vault/VaultText';
import {
  readSidebarChainFilter,
  writeSidebarChainFilter,
  filterSidebarChains,
  type SidebarChainFilter,
} from '../../utils/clientPersistence';

export { filterSidebarChains };
export type { SidebarChainFilter };

type Props = {
  projects: Array<{ projectId: string; projectName: string }>;
  currentPath: string;
  onNavigate: (path: string) => void;
};

function relativeTime(iso: string): string {
  if (!iso) return '';
  const ms = Date.parse(iso);
  if (Number.isNaN(ms)) return '';
  const diff = Date.now() - ms;
  const secs = Math.floor(diff / 1000);
  if (secs < 60) return `${secs}s ago`;
  const mins = Math.floor(secs / 60);
  if (mins < 60) return `${mins}m ago`;
  const hrs = Math.floor(mins / 60);
  if (hrs < 24) return `${hrs}h ago`;
  const days = Math.floor(hrs / 24);
  if (days < 30) return `${days}d ago`;
  return new Date(ms).toLocaleDateString(undefined, { month: 'short', day: 'numeric' });
}

type StatusTone = 'success' | 'neutral' | 'warning' | 'danger';

function chainStatusTone(status: string): StatusTone {
  switch (status) {
    case 'active': return 'success';
    case 'completed': return 'neutral';
    case 'paused': return 'warning';
    case 'cancelled': return 'danger';
    default: return 'neutral';
  }
}

function ChainRow({
  chain,
  currentPath,
  onNavigate,
  onTogglePin,
}: {
  chain: ChainListItem;
  currentPath: string;
  onNavigate: (path: string) => void;
  onTogglePin?: (chain: ChainListItem, e: React.MouseEvent) => void;
}) {
  const path = chain.coordinatorAgentInstanceId
    ? `/conversations/${encodeURIComponent(chain.coordinatorAgentInstanceId)}`
    : `/chains/${encodeURIComponent(chain.chainId)}`;
  const active = currentPath === path;
  const tone = chainStatusTone(chain.status);
  const timestamp = relativeTime(chain.updatedAt);
  const isCompleted = chain.status === 'completed';
  const isActive = chain.status === 'active';
  const hasTasks = chain.taskCount > 0;
  const hasUserValidation = Boolean(chain.userValidationCount > 0 || chain.hasUserValidation);

  const radius = 5.25;
  const circumference = 2 * Math.PI * radius;
  const ratio = hasTasks ? Math.min(1, Math.max(0, chain.completedTaskCount / chain.taskCount)) : 0;
  const strokeDashoffset = circumference * (1 - ratio);
  const pct = Math.round(ratio * 100);

  return (
    <a
      href={`#${path}`}
      onClick={(e) => { e.preventDefault(); onNavigate(path); }}
      className={`group flex h-8 min-h-8 w-full items-center gap-2 rounded-xl px-2.5 text-[12.5px] transition ${
        active
          ? 'bg-neutral-soft text-primary font-semibold'
          : 'text-muted hover:bg-neutral-soft hover:text-primary'
      }`}
    >
      {isCompleted ? (
        <span
          data-debug-id="chain-completed-icon"
          className="flex h-3.5 w-3.5 shrink-0 items-center justify-center rounded-full bg-neutral-soft text-muted"
          title="Completed"
          aria-label="Completed"
        >
          <Icon name="check" size={10} />
        </span>
      ) : isActive && hasTasks ? (
        <div
          data-debug-id="chain-progress-ring"
          className="relative flex h-3.5 w-3.5 shrink-0 items-center justify-center"
          title={`${pct}% completed (${chain.completedTaskCount}/${chain.taskCount} tasks)`}
          aria-label={`${pct}% completed`}
        >
          <svg
            width="14"
            height="14"
            viewBox="0 0 14 14"
            className="absolute inset-0 -rotate-90 pointer-events-none"
            aria-hidden="true"
          >
            <circle
              cx="7"
              cy="7"
              r={radius}
              fill="none"
              stroke="currentColor"
              className="text-neutral-subtle opacity-25"
              strokeWidth="1.5"
            />
            <circle
              cx="7"
              cy="7"
              r={radius}
              fill="none"
              stroke="currentColor"
              className="text-success transition-all duration-300"
              strokeWidth="1.5"
              strokeDasharray={circumference}
              strokeDashoffset={strokeDashoffset}
              strokeLinecap="round"
            />
          </svg>
          <StatusDot
            tone="success"
            pulse
            label={chain.status}
            size="sm"
          />
        </div>
      ) : (
        <StatusDot
          tone={tone}
          pulse={isActive}
          label={chain.status}
          size="sm"
        />
      )}
      <span className="min-w-0 flex-1 truncate"><VaultText value={chain.title} fallback="Untitled chain" /></span>
      {hasUserValidation ? (
        <span
          data-debug-id="chain-user-validation-badge"
          title="Awaiting user validation"
          aria-label="Awaiting user validation"
          className="inline-flex shrink-0 items-center gap-1 rounded-md bg-warning/15 px-1.5 py-0.5 text-[10px] font-semibold text-warning"
        >
          <Icon name="alert" size={11} className="shrink-0 text-warning" />
          <span className="leading-none">Needs review</span>
        </span>
      ) : null}
      {timestamp ? (
        <span className={`shrink-0 text-[10px] leading-none text-faint ${chain.isPinned ? 'hidden' : 'group-hover:hidden'}`}>
          {timestamp}
        </span>
      ) : null}
      {onTogglePin ? (
        <button
          type="button"
          aria-label={chain.isPinned ? 'Unpin chain' : 'Pin chain'}
          title={chain.isPinned ? 'Unpin chain' : 'Pin chain'}
          onClick={(e) => onTogglePin(chain, e)}
          className={`flex h-4 w-4 shrink-0 items-center justify-center rounded transition ${
            chain.isPinned
              ? 'text-accent hover:text-accent/80'
              : 'hidden text-faint hover:text-primary group-hover:flex'
          }`}
        >
          <Icon name="pin" size={11} />
        </button>
      ) : null}
    </a>
  );
}

function ProjectChainGroup({
  projectId,
  projectName,
  currentPath,
  chainFilter,
  onNavigate,
  onOpenModal,
  onTogglePin,
}: {
  projectId: string;
  projectName: string;
  currentPath: string;
  chainFilter: SidebarChainFilter;
  onNavigate: (path: string) => void;
  onOpenModal: (projectId: string) => void;
  onTogglePin: (chain: ChainListItem, e: React.MouseEvent) => void;
}) {
  const [collapsed, setCollapsed] = useState(false);
  const [cursor, setCursor] = useState('');
  const { data, isFetching } = useListTaskChainsQuery({ projectId, limit: 20, cursor });

  const rawChains = data?.chains ?? [];
  const chains = useMemo(() => {
    return filterSidebarChains(rawChains, chainFilter);
  }, [rawChains, chainFilter]);

  const hasMore = data?.hasMore ?? false;
  const nextCursor = data?.nextCursor ?? '';

  return (
    <div className="mb-2">
      {/* Project header */}
      <div className="flex items-center gap-1 px-2.5 py-1">
        <button
          type="button"
          onClick={() => setCollapsed((v) => !v)}
          className="flex min-w-0 flex-1 items-center gap-1.5 text-left text-[10.5px] font-bold uppercase tracking-[0.14em] text-faint hover:text-primary transition"
        >
          <span className={`shrink-0 transition-transform ${collapsed ? '-rotate-90' : ''}`}>▾</span>
          <span className="min-w-0 truncate"><VaultText value={projectName} fallback="Unnamed project" /></span>
          {isFetching ? <span className="ml-1 text-[9px] font-normal normal-case tracking-normal">…</span> : null}
        </button>
        <button
          type="button"
          aria-label={`New chain for ${projectName}`}
          onClick={() => onOpenModal(projectId)}
          className="shrink-0 rounded-md p-0.5 text-faint hover:bg-neutral-soft hover:text-primary transition"
        >
          <svg width="13" height="13" viewBox="0 0 16 16" fill="none" aria-hidden="true">
            <path d="M8 2v12M2 8h12" stroke="currentColor" strokeWidth="2" strokeLinecap="round" />
          </svg>
        </button>
      </div>

      {/* Chain rows */}
      {!collapsed && (
        <div className="space-y-0.5">
          {chains.map((chain) => (
            <ChainRow
              key={chain.chainId}
              chain={chain}
              currentPath={currentPath}
              onNavigate={onNavigate}
              onTogglePin={onTogglePin}
            />
          ))}
          {!isFetching && chains.length === 0 ? (
            <div className="px-2.5 py-1.5 text-[11.5px] text-faint">
              {chainFilter === 'active' ? 'No active chains.' : 'No chains yet.'}
            </div>
          ) : null}
          {hasMore && nextCursor ? (
            <button
              type="button"
              onClick={() => setCursor(nextCursor)}
              className="w-full px-2.5 py-1.5 text-left text-[11.5px] text-accent hover:underline"
            >
              Load more
            </button>
          ) : null}
        </div>
      )}
    </div>
  );
}

export default function ProjectChainTree({ projects, currentPath, onNavigate }: Props) {
  const [modalProjectId, setModalProjectId] = useState<string | null>(null);
  const [chainFilter, setChainFilter] = useState<SidebarChainFilter>(() => readSidebarChainFilter());
  const dispatch = useDispatch();
  const { data: pinnedData } = useListPinnedTaskChainsQuery();
  const [togglePin] = useTogglePinTaskChainMutation();
  const archivedProjectIds = useArchivedProjectIds();

  const handleFilterChange = (nextFilter: SidebarChainFilter) => {
    setChainFilter(nextFilter);
    writeSidebarChainFilter(nextFilter);
  };

  const pinnedChains = useMemo(() => {
    const list = pinnedData?.chains ?? [];
    return filterSidebarChains(list, chainFilter, archivedProjectIds);
  }, [pinnedData, archivedProjectIds, chainFilter]);

  const visibleProjects = useMemo(() => {
    return projects.filter((p) => !archivedProjectIds.has(p.projectId));
  }, [projects, archivedProjectIds]);

  const handleTogglePin = async (chain: ChainListItem, e: React.MouseEvent) => {
    e.preventDefault();
    e.stopPropagation();

    if (!chain.isPinned && pinnedChains.length >= 10) {
      dispatch(
        showToast({
          kind: 'error',
          title: 'Maximum pinned chains reached',
          message: 'You can pin up to 10 task chains. Unpin an existing chain first.',
        })
      );
      return;
    }

    try {
      await togglePin({ chainId: chain.chainId, pinned: !chain.isPinned }).unwrap();
    } catch (err: any) {
      dispatch(
        showToast({
          kind: 'error',
          title: 'Failed to update pin status',
          message: String(err?.data?.error?.message || err?.message || 'Unknown error'),
        })
      );
    }
  };

  return (
    <section data-debug-id="sidebar-project-chain-tree" className="mt-4">
      {/* Header with Chains title, filter badge, and filter menu button */}
      <div className="mb-1.5 flex items-center justify-between px-2.5">
        <div className="flex items-center gap-1.5 text-[10.5px] font-bold uppercase tracking-[0.16em] text-faint">
          <span>Chains</span>
          {chainFilter !== 'all' && (
            <button
              type="button"
              data-debug-id="sidebar-chain-filter-badge"
              onClick={() => handleFilterChange('all')}
              title="Filtering by active chains. Click to show all."
              className="inline-flex items-center gap-1 rounded-full bg-accent/15 px-1.5 py-0.5 text-[9px] font-semibold normal-case tracking-normal text-accent hover:bg-accent/25 transition"
            >
              <span>Active only</span>
              <Icon name="close" size={9} />
            </button>
          )}
        </div>
        <div className="flex items-center gap-1">
          <Menu
            align="end"
            trigger={
              <button
                type="button"
                data-debug-id="sidebar-chain-filter-btn"
                aria-label={`Filter chains: currently ${chainFilter === 'active' ? 'Active only' : 'All'}`}
                title={chainFilter === 'active' ? 'Filter: Active only (click to change)' : 'Filter chains'}
                className={`flex h-5 w-5 shrink-0 items-center justify-center rounded-md transition ${
                  chainFilter !== 'all'
                    ? 'bg-accent/15 text-accent hover:bg-accent/25'
                    : 'text-faint hover:bg-neutral-soft hover:text-primary'
                }`}
              >
                <Icon name="filter" size={12} />
              </button>
            }
          >
            <div className="py-0.5" data-debug-id="sidebar-chain-filter-menu">
              <Menu.Item
                data-debug-id="sidebar-chain-filter-option-all"
                onClick={() => handleFilterChange('all')}
                className={chainFilter === 'all' ? 'font-semibold text-accent' : ''}
              >
                <span className="flex items-center gap-2">
                  <span className="flex h-3.5 w-3.5 items-center justify-center text-accent">
                    {chainFilter === 'all' ? <Icon name="check" size={12} /> : null}
                  </span>
                  <span>All (Active &amp; Completed)</span>
                </span>
              </Menu.Item>
              <Menu.Item
                data-debug-id="sidebar-chain-filter-option-active"
                onClick={() => handleFilterChange('active')}
                className={chainFilter === 'active' ? 'font-semibold text-accent' : ''}
              >
                <span className="flex items-center gap-2">
                  <span className="flex h-3.5 w-3.5 items-center justify-center text-accent">
                    {chainFilter === 'active' ? <Icon name="check" size={12} /> : null}
                  </span>
                  <span>Active only</span>
                </span>
              </Menu.Item>
            </div>
          </Menu>
        </div>
      </div>

      {/* Pinned chains at top of Chains section */}
      {pinnedChains.length > 0 && (
        <div className="mb-3" data-debug-id="pinned-task-chains">
          <div className="mb-1 flex items-center justify-between px-2.5 text-[10.5px] font-bold uppercase tracking-[0.14em] text-faint">
            <span>Pinned</span>
            <span className="text-[10px] font-normal tracking-normal text-faint">
              {pinnedChains.length}/10
            </span>
          </div>
          <div className="space-y-0.5">
            {pinnedChains.map((chain) => (
              <ChainRow
                key={`pinned-${chain.chainId}`}
                chain={chain}
                currentPath={currentPath}
                onNavigate={onNavigate}
                onTogglePin={handleTogglePin}
              />
            ))}
          </div>
        </div>
      )}

      {visibleProjects.length === 0 ? (
        <div className="px-2.5 py-2 text-[11.5px] text-faint">No projects.</div>
      ) : (
        visibleProjects.map((p) => (
          <ProjectChainGroup
            key={p.projectId}
            projectId={p.projectId}
            projectName={p.projectName}
            currentPath={currentPath}
            chainFilter={chainFilter}
            onNavigate={onNavigate}
            onOpenModal={setModalProjectId}
            onTogglePin={handleTogglePin}
          />
        ))
      )}
      {modalProjectId ? (
        <CreateChainModal
          projectId={modalProjectId}
          isOpen={Boolean(modalProjectId)}
          onClose={() => setModalProjectId(null)}
          onCreated={(path) => {
            setModalProjectId(null);
            onNavigate(path);
          }}
        />
      ) : null}
    </section>
  );
}

/**
 * Extracts first letter of first two words, uppercase.
 * If 1 word, first 2 letters uppercase. If single char, 1 letter. If empty/whitespace, "TC".
 */
export function chainAvatarInitials(title: string): string {
  const trimmed = (title || '').trim();
  if (!trimmed) return 'TC';
  const words = trimmed.split(/\s+/).filter(Boolean);
  if (words.length >= 2) {
    return (words[0][0] + words[1][0]).toUpperCase();
  }
  return trimmed.slice(0, 2).toUpperCase();
}

/**
 * Returns true if currentPath matches chain coordinator conversation
 * (/conversations/<id>, /c/<id>) or chain overview (/chains/<chainId>).
 */
export function isChainActive(chain: ChainListItem, currentPath: string): boolean {
  const coordId = chain.coordinatorAgentInstanceId;
  if (coordId) {
    const encCoord = encodeURIComponent(coordId);
    if (
      currentPath === `/conversations/${coordId}` ||
      currentPath === `/conversations/${encCoord}` ||
      currentPath === `/c/${coordId}` ||
      currentPath === `/c/${encCoord}` ||
      currentPath.startsWith(`/conversations/${coordId}/`) ||
      currentPath.startsWith(`/conversations/${encCoord}/`) ||
      currentPath.startsWith(`/c/${coordId}/`) ||
      currentPath.startsWith(`/c/${encCoord}/`)
    ) {
      return true;
    }
  }
  if (chain.chainId) {
    const encChain = encodeURIComponent(chain.chainId);
    if (
      currentPath === `/chains/${chain.chainId}` ||
      currentPath === `/chains/${encChain}` ||
      currentPath.startsWith(`/chains/${chain.chainId}/`) ||
      currentPath.startsWith(`/chains/${encChain}/`)
    ) {
      return true;
    }
  }
  return false;
}

export function CollapsedPinnedChains({
  currentPath,
  onNavigate,
}: {
  currentPath: string;
  onNavigate: (path: string) => void;
}) {
  const { data: pinnedData } = useListPinnedTaskChainsQuery();
  const archivedProjectIds = useArchivedProjectIds();
  const pinnedChains = useMemo(() => {
    const list = pinnedData?.chains ?? [];
    return list.filter((c) => {
      if (c.status === 'archived' || (c as any).archived) return false;
      if (c.projectId && archivedProjectIds.has(c.projectId)) return false;
      return true;
    });
  }, [pinnedData, archivedProjectIds]);

  if (pinnedChains.length === 0) {
    return null;
  }

  return (
    <div
      data-debug-id="collapsed-pinned-chains"
      className="flex flex-col items-center gap-2 pt-3 mt-3 border-t border-subtle"
    >
      {pinnedChains.map((chain) => {
        const path = chain.coordinatorAgentInstanceId
          ? `/conversations/${encodeURIComponent(chain.coordinatorAgentInstanceId)}`
          : `/chains/${encodeURIComponent(chain.chainId)}`;
        const active = isChainActive(chain, currentPath);
        const title = chain.title || 'Untitled chain';
        const tone = chainStatusTone(chain.status);
        const initials = chainAvatarInitials(chain.title);

        return (
          <a
            key={`collapsed-pinned-${chain.chainId}`}
            href={`#${path}`}
            data-debug-id={`collapsed-chain-avatar-${chain.chainId}`}
            data-active={active ? 'true' : 'false'}
            title={title}
            aria-label={title}
            onClick={(e) => {
              e.preventDefault();
              onNavigate(path);
            }}
            className={`relative flex h-9 w-9 items-center justify-center rounded-xl text-xs font-bold transition select-none ${
              active
                ? 'border-2 border-accent text-accent bg-neutral-soft ring-1 ring-accent/30 font-bold'
                : 'border border-subtle text-muted hover:text-primary hover:bg-neutral-soft hover:border-default'
            }`}
          >
            <span>{initials}</span>
            {chain.status === 'completed' ? (
              <span className="absolute -bottom-0.5 -right-0.5 flex h-2.5 w-2.5 items-center justify-center rounded-full bg-neutral-soft text-muted pointer-events-none">
                <Icon name="check" size={8} />
              </span>
            ) : (
              <span className="absolute -bottom-0.5 -right-0.5 pointer-events-none">
                <StatusDot
                  tone={tone}
                  pulse={chain.status === 'active'}
                  label={chain.status}
                  size="sm"
                />
              </span>
            )}
            {(chain.userValidationCount > 0 || chain.hasUserValidation) && (
              <span
                data-debug-id={`collapsed-chain-validation-${chain.chainId}`}
                className="absolute -top-1 -right-1 flex h-3.5 w-3.5 items-center justify-center rounded-full bg-warning text-[8px] text-surface font-bold pointer-events-none"
                title="Awaiting user validation"
              >
                !
              </span>
            )}
          </a>
        );
      })}
    </div>
  );
}

