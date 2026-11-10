import { cookieJsonFetch } from '../../api/cookieFetch';
import { getKeyringSession } from '../../utils/vaultKeyringSession';
import OwnerLocalPanel from './OwnerLocalPanel';
import { OwnerChainView } from './OwnerChainView';
import { OwnerChainsGroup, filterOwnerChains } from './OwnerChainsGroup';
import { loadOwnerChainSummaries, type OwnerChainSummary } from '../../api/ownerChains';
import { addPendingOwnerChain, useOwnerChains } from '../../api/ownerChainsStore';
import React, { useEffect, useMemo, useState } from 'react';
import { Badge, ResourceContainer, ResourceSearchFilter, useViewport } from '@ui';
import Icon from '../Icon';
import { buildRouteHash } from '../../utils/appLocation';
import { chainConversationRoute } from '../../utils/paneTarget';
import CreateChainModal from './CreateChainModal';
import { ChainTokenUsageSection } from './ChainTokenUsage';
import { useSelector } from 'react-redux';
import { selectIsVaultUnlocked } from '../../store/vaultSlice';

interface TaskChainsPageProps {
  chainId?: string;
  // Optional deep-link target task (from '/chains/:chainId/tasks/:taskId'); the
  // chain view auto-opens + scrolls to it. Undefined for the plain chain route.
  taskId?: string;
  submissionAttempt?: string;
  isMobile?: boolean;
}

function shellHash(path: string): string {
  return buildRouteHash(path, '');
}

// The status filters, as tabs in the list pane's filter row. Bridge-owned
// chains are never archived.
const STATUS_TABS: { value: 'active' | 'completed' | 'all'; label: string }[] = [
  { value: 'active', label: 'Active' },
  { value: 'completed', label: 'Completed' },
  { value: 'all', label: 'All' },
];

export const TaskChainsPage: React.FC<TaskChainsPageProps> = ({ chainId: initialChainId, taskId: focusTaskId, submissionAttempt, isMobile }) => {
  // Read the viewport the same way ResourceContainer does, so the page and the
  // container can never disagree about where the 2-pane boundary is.
  const viewport = useViewport();
  const twoPane = viewport === 'desktop';
  const isMobileViewport = isMobile ?? viewport === 'mobile';

  const [showOwnerLocal, setShowOwnerLocal] = useState(false);
  // A deep-linked owner chain resolved before the shared registry snapshot loads.
  const [ownerProbe, setOwnerProbe] = useState<OwnerChainSummary | null>(null);
  const ownerChains = useOwnerChains();
  const [selectedChainId, setSelectedChainId] = useState<string>(initialChainId || '');
  const [filterStatus, setFilterStatus] = useState<'active' | 'completed' | 'all'>('active');
  const [showCreateChainModal, setShowCreateChainModal] = useState(false);
  const [searchQuery, setSearchQuery] = useState<string>('');
  // Roughly half of real chains carry no tasks yet and have nothing to show, so
  // the list hides them by default; the toggle brings them back.
  const [onlyWithTasks, setOnlyWithTasks] = useState<boolean>(true);
  const [collapsed, setCollapsed] = useState(false);

  useEffect(() => {
    setSelectedChainId(initialChainId || '');
  }, [initialChainId]);

  const isUnlocked = useSelector(selectIsVaultUnlocked);
  useEffect(() => {
    setOwnerProbe(null);
    const session = getKeyringSession();
    if (!initialChainId || !isUnlocked || !session) return;
    if (ownerChains.chains.some((c) => c.chainId === initialChainId)) return;
    const controller = new AbortController();
    void loadOwnerChainSummaries(
      session,
      (path) => cookieJsonFetch(path + '&chain_id=' + encodeURIComponent(initialChainId), { signal: controller.signal }),
      () => !controller.signal.aborted && getKeyringSession() === session,
    ).then((rows) => {
      const row = rows.find((r) => r.chainId === initialChainId);
      if (row && !controller.signal.aborted) setOwnerProbe(row);
    }).catch(() => {});
    return () => controller.abort();
  }, [initialChainId, isUnlocked]); // eslint-disable-line react-hooks/exhaustive-deps

  const owners = ownerChains.chains;
  const ownerById = useMemo(() => {
    const map = new Map(owners.map((o) => [o.chainId, o]));
    if (ownerProbe && !map.has(ownerProbe.chainId)) map.set(ownerProbe.chainId, ownerProbe);
    return map;
  }, [owners, ownerProbe]);

  const visibleOwners = useMemo(
    () => filterOwnerChains(owners, { query: searchQuery, status: filterStatus, projectId: '', onlyWithTasks, kind: 'all' }),
    [owners, searchQuery, filterStatus, onlyWithTasks],
  );
  const totalChains = visibleOwners.length;
  const isLoading = ownerChains.status === 'loading' && owners.length === 0;
  const error = ownerChains.status === 'error' ? ownerChains.error : '';

  // Desktop shows both panes, so an empty detail pane is wasted space: preselect
  // the first visible chain (mirrors IssueListPage). State only — no route push,
  // so '/chains' stays '/chains' until the user actually picks a row.
  const firstChainId = visibleOwners[0]?.chainId || '';
  useEffect(() => {
    if (twoPane && !selectedChainId && firstChainId) {
      setSelectedChainId(firstChainId);
    }
  }, [twoPane, selectedChainId, firstChainId]);

  // Selecting a row syncs the hash route so deep links and the browser back button
  // keep working. AppShell renders TaskChainsPage from the same position for both
  // '/chains' and '/chains/*', so this updates the page in place rather than
  // remounting it — the filters and collapse state survive.
  const handleSelectChain = (chainId: string) => {
    setSelectedChainId(chainId);
    window.location.hash = shellHash(`/chains/${encodeURIComponent(chainId)}`);
  };

  const handleCloseDetail = () => {
    setSelectedChainId('');
    window.location.hash = shellHash('/chains');
  };

  const listColumn = (
    <div data-debug-id="task-chains-page" className="flex h-full min-w-0 flex-col overflow-hidden text-left">
      <ResourceSearchFilter
        searchQuery={searchQuery}
        onSearchChange={setSearchQuery}
        searchPlaceholder="Search chains…"
        searchDebugId="task-chains-search-input"
        activeTab={filterStatus}
        onTabChange={(tab) => setFilterStatus(tab as 'active' | 'completed' | 'all')}
        tabsLabel="Filter chains by status"
        tabs={STATUS_TABS.map((tab) => ({
          value: tab.value,
          label: tab.label,
          debugId: `task-chains-filter-status-${tab.value}`,
        }))}
        showFooterCounter
        itemsCount={totalChains}
        itemsLabel="chain"
        counterDebugId="task-chains-footer-count"
      >
        <label
          htmlFor="task-chains-has-tasks-filter"
          className={`inline-flex cursor-pointer items-center gap-2 rounded-xl border border-subtle bg-surface px-3 py-1.5 text-sm text-muted ${isMobileViewport ? 'min-h-11' : 'min-h-[32px]'}`}
        >
          <input
            id="task-chains-has-tasks-filter"
            data-debug-id="task-chains-has-tasks-filter"
            type="checkbox"
            checked={onlyWithTasks}
            onChange={(e) => setOnlyWithTasks(e.target.checked)}
            className="h-4 w-4 accent-accent"
          />
          Only chains with tickets
        </label>
      </ResourceSearchFilter>

      <div className="min-h-0 flex-1 overflow-y-auto p-4">
        {ownerChains.status === 'locked' && (
          <div data-debug-id="task-chains-locked" className="rounded-2xl border border-subtle bg-surface p-6 text-sm text-muted">
            Unlock the vault on this device to see your Bridge-owned task chains.
          </div>
        )}

        {isLoading && (
          <div data-debug-id="task-chains-loading" className="rounded-2xl border border-subtle bg-surface p-6 text-sm text-muted">
            Loading task chains…
          </div>
        )}

        {!isLoading && error && (
          <div data-debug-id="task-chains-error" className="rounded-xl border border-danger/30 bg-danger-soft p-5 text-sm text-danger">
            Failed to load task chains: {error}
          </div>
        )}

        {visibleOwners.length > 0 && (
          <OwnerChainsGroup
            chains={visibleOwners}
            activeChainId={selectedChainId}
            onSelect={handleSelectChain}
            loading={ownerChains.status === 'loading'}
            error={error || undefined}
            collapsed={collapsed}
            onToggle={() => setCollapsed((prev) => !prev)}
          />
        )}

        {ownerChains.status === 'ready' && !error && visibleOwners.length === 0 && (
          <div
            data-debug-id="task-chains-empty-state"
            className="flex flex-col items-center justify-center rounded-2xl border border-dashed border-subtle bg-surface/50 p-12 text-center"
          >
            <div className="mb-4 grid h-12 w-12 place-items-center rounded-2xl bg-neutral-soft text-muted">
              <Icon name="tasks" size={24} />
            </div>
            <h3 className="text-base font-semibold text-primary">No Task Chains</h3>
            <p className="mt-1 max-w-md text-xs leading-relaxed text-muted">
              {searchQuery.trim()
                ? 'No task chains match your search.'
                : 'Task chains live on your Bridges. Create one, or import legacy Hub chains from Settings → Bridges.'}
            </p>
          </div>
        )}
      </div>
    </div>
  );

  if (showOwnerLocal) return <OwnerLocalPanel onClose={() => setShowOwnerLocal(false)} />;
  const selectedOwner = selectedChainId ? ownerById.get(selectedChainId) : undefined;

  return (
    <ResourceContainer
      title={
        <div className="flex items-center justify-between w-full pr-2">
          <span className="inline-flex items-center gap-2.5">
            Task Chains
            <Badge data-debug-id="task-chains-total-count" tone="info">
              {totalChains} {totalChains === 1 ? 'chain' : 'chains'}
            </Badge>
          </span>
          <div className="flex items-center gap-2">
            <button
              type="button"
              data-debug-id="task-chains-owner-local"
              onClick={() => setShowOwnerLocal(true)}
              title="Raw owner-local operations (advanced/debug)"
              className="inline-flex items-center rounded-lg border border-subtle bg-surface px-3 py-1 text-xs text-muted hover:text-primary"
            >
              Owner-local (debug)
            </button>
            <button
              type="button"
              data-debug-id="task-chains-new-chain-btn"
              onClick={() => setShowCreateChainModal(true)}
              className="inline-flex items-center gap-1.5 rounded-lg bg-accent px-3 py-1 text-xs font-semibold text-accent-fg hover:opacity-90 transition-opacity"
            >
              <span>+</span>
              <span>New Chain</span>
            </button>
          </div>
        </div>
      }
      description="Task chains on your Bridges. Select a chain to follow its tickets and reviews."
      breadcrumbs={[{ label: 'Task Chains' }]}
      selectedId={selectedChainId}
      detailTitle="Task Chain"
      listDebugId="task-chains-list-column"
      detailDebugId="task-chains-detail-pane"
      emptyDetailText="Select a task chain to see it here."
      list={listColumn}
      detail={
        selectedOwner ? (
          <OwnerChainView
            key={JSON.stringify([selectedOwner.chainId, focusTaskId, submissionAttempt])}
            chain={selectedOwner}
            focusTaskId={focusTaskId}
            submissionAttempt={submissionAttempt}
            onClose={handleCloseDetail}
            extra={<ChainTokenUsageSection chainId={selectedOwner.chainId} embedded />}
          />
        ) : selectedChainId ? (
          <div data-debug-id="task-chains-unknown-chain" className="p-6 text-sm text-muted">
            {ownerChains.status === 'locked'
              ? 'Unlock the vault to open this task chain.'
              : 'This task chain is not on any of your Bridges. A legacy Hub chain must be imported first (Settings → Bridges → Import all legacy chains).'}
          </div>
        ) : null
      }
    >
      <CreateChainModal
        isOpen={showCreateChainModal}
        onClose={() => setShowCreateChainModal(false)}
        onCreated={(newChainId, owner) => {
          setShowCreateChainModal(false);
          if (owner) addPendingOwnerChain(owner);
          // A chain with a coordinator opens its conversation at the canonical
          // chain URL (the sidebar's); without one, the chain page.
          if (owner?.coordinatorAgentInstanceId) window.location.hash = shellHash(chainConversationRoute(newChainId));
          else handleSelectChain(newChainId);
        }}
      />
    </ResourceContainer>
  );
};

export default TaskChainsPage;
