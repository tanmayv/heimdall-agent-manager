/**
 * AgentListPage — `/agents`.
 * ------------------------------------------------------------------
 * Inherits from ProjectListPage. Key differences:
 *
 *  1. **No FilterBar.** `GET /api/v1/agents` takes limit+cursor only — no state,
 *     no type facet. Tab is the only client-side filter, and there is nothing
 *     else to offer in a drawer, so the filter icon is not rendered.
 *
 *  2. **No tabs for agents (REQ-UI-3).** Wait — the coordinator's scope change
 *     retained tabs: Active | Archived is client-side, same as Projects. The
 *     original REQ-UI-3 ruling was about "no provider/tier tabs", not state tabs.
 *     Active and Archived tabs are present.
 *
 *  3. **Bulk verbs on Active only.** Archived agents get no bulk action (no
 *     restore endpoint), same ruling as Projects.
 *
 *  4. **WS live updates via focus-refetch.** The WS patches the RTK `listAgents`
 *     cache for other consumers; the infinite list stays consistent via on-focus
 *     refresh, the same pattern Projects uses.
 */
import React from 'react';
import {
  ActionButton,
  Alert,
  BulkActionBar,
  Button,
  EmptyState,
  Icon,
  Input,
  Modal,
  ModalBody,
  ModalFooter,
  PageShell,
  Tab,
  Tabs,
  TabsList,
  TabsPanel,
  Text,
  Toast,
  TOUCH_TARGET_CLASS,
  useInfiniteList,
  useViewport,
} from '@ui';
import AgentRow from './AgentRow';
import {
  AgentDetailActions,
  AgentDetailBody,
  AgentDetailMeta,
  AgentDetailPaneSkeleton,
  useAgentDetail,
  usePaneIsWide,
} from './AgentDetail';
import { getRouteSearch } from '../../utils/appLocation';
import {
  fetchAgentPage,
  searchAgentPage,
  agentErrorText,
  useArchiveAgentIdentityMutation,
  type AgentHit,
  type AgentRecord,
} from '../../api/endpoints/agents';
import {
  AGENT_TABS,
  EMPTY_LIST_URL_STATE,
  FILTER_PAGE_CAP,
  archiveConfirmBody,
  listCrumbs,
  matchesTab,
  navigateTo,
  agentEditHref,
  agentListHref,
  agentNewHref,
  agentState,
  agentTitle,
  agentViewHref,
  parseAgentListUrl,
  rememberRow,
  replaceListSearch,
  takeRememberedRow,
  type AgentListUrlState,
  type AgentTab,
  type AgentVerb,
} from './agentModel';

const PAGE_SIZE = 50;
const SEARCH_DEBOUNCE_MS = 250;

type ToastEntry = {
  id: string;
  tone: 'success' | 'danger' | 'info';
  title: string;
  message?: string;
};

export default function AgentListPage({ selectedId = '' }: { selectedId?: string } = {}) {
  const viewport = useViewport();
  const isMobile = viewport === 'mobile';
  const twoPane = viewport === 'desktop';
  const searchRef = React.useRef<HTMLInputElement | null>(null);

  /* ---------------- URL state ---------------- */
  const [urlState, setUrlState] = React.useState<AgentListUrlState>(() =>
    parseAgentListUrl(getRouteSearch()),
  );
  const tab: AgentTab = urlState.tab || 'active';
  const searching = Boolean(urlState.q);

  const applyUrlState = React.useCallback((next: AgentListUrlState) => {
    setUrlState(next);
    replaceListSearch(next);
  }, []);

  /* ---------------- Search ---------------- */
  const [queryInput, setQueryInput] = React.useState(urlState.q);
  React.useEffect(() => {
    if (queryInput === urlState.q) return undefined;
    const timer = window.setTimeout(() => {
      applyUrlState({ ...urlState, q: queryInput });
    }, SEARCH_DEBOUNCE_MS);
    return () => window.clearTimeout(timer);
  }, [queryInput, urlState, applyUrlState]);
  const querySettling = queryInput.trim() !== urlState.q.trim();

  /* ---------------- The two data paths ----------------
   * `resetKey: 'agents'` is CONSTANT: the tab is client-side, so switching
   * must not throw away rows that are already loaded and correct. */
  const list = useInfiniteList<AgentRecord>({
    fetchPage: ({ cursor, signal }) => fetchAgentPage({ limit: PAGE_SIZE, cursor, signal }),
    getItemId: (row) => row.agentId,
    // Agents key on `created_at` server-side, but that field is never serialised
    // (`agent_handlers.odin:338-351`) — use `updated_at`, the one timestamp on the
    // wire, purely to detect "this row changed" for the N-new pill. The keyset
    // cursor comes from the page envelope, so paging is unaffected.
    getCursorValue: (row) => row.updatedAt,
    resetKey: 'agents',
    enabled: !searching,
  });

  const search = useInfiniteList<AgentHit>({
    fetchPage: ({ cursor, signal }) => searchAgentPage({ q: urlState.q, limit: PAGE_SIZE, cursor, signal }),
    getItemId: (hit) => hit.id,
    resetKey: urlState.q,
    enabled: searching,
  });

  const active = searching ? search : list;

  /* ---------------- Client-side tab filter ----------------
   * No VCS filter — agents have no per-agent filter beyond state. */
  const visibleRows = React.useMemo(
    () => list.items.filter((row) => matchesTab(row, tab)),
    [list.items, tab],
  );

  const [autoPages, setAutoPages] = React.useState(0);
  React.useEffect(() => {
    setAutoPages(0);
  }, [tab]);
  React.useEffect(() => {
    if (searching) return;
    if (visibleRows.length > 0) return;
    if (!list.hasMore || list.isPaging || list.isLoadingInitial || list.pagingError) return;
    if (autoPages >= FILTER_PAGE_CAP) return;
    setAutoPages((prev) => prev + 1);
    list.loadMore();
  }, [autoPages, list, searching, visibleRows.length]);

  const moreToSearch = !searching && visibleRows.length === 0 && list.hasMore;

  /* ---------------- Live updates (focus-refetch) ---------------- */
  React.useEffect(() => {
    if (searching) return undefined;
    const onFocus = () => list.refresh();
    window.addEventListener('focus', onFocus);
    return () => window.removeEventListener('focus', onFocus);
  }, [list, searching]);

  /* ---------------- Scroll restoration ---------------- */
  const restoredRef = React.useRef(false);
  React.useEffect(() => {
    if (restoredRef.current) return;
    restoredRef.current = true;
    const rowId = takeRememberedRow();
    if (!rowId || searching) return;
    void list.restoreToId(rowId).then((outcome) => {
      if (outcome !== 'found') return;
      window.requestAnimationFrame(() => {
        const node = document.querySelector(`[data-agent-row="${CSS.escape(rowId)}"]`);
        node?.scrollIntoView({ block: 'center' });
      });
    });
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  React.useEffect(() => {
    if (!list.restoreNotice) return undefined;
    const dismiss = () => list.dismissRestoreNotice();
    window.addEventListener('scroll', dismiss, { capture: true, once: true });
    return () => window.removeEventListener('scroll', dismiss, { capture: true });
  }, [list]);

  /* ---------------- Selection ---------------- */
  const [selectedIds, setSelectedIds] = React.useState<string[]>([]);
  React.useEffect(() => {
    setSelectedIds([]);
  }, [tab, urlState.q]);

  /* ---------------- Toasts ---------------- */
  const [toasts, setToasts] = React.useState<ToastEntry[]>([]);
  const pushToast = React.useCallback((entry: Omit<ToastEntry, 'id'>) => {
    const id = `agent-toast-${Date.now()}-${Math.random().toString(36).slice(2, 6)}`;
    setToasts((prev) => [...prev.slice(-2), { ...entry, id }]);
  }, []);
  const dismissToast = React.useCallback((id: string) => {
    setToasts((prev) => prev.filter((entry) => entry.id !== id));
  }, []);

  /* ---------------- Archive ---------------- */
  const [confirm, setConfirm] = React.useState<{ ids: string[] } | null>(null);
  const [bulkBusy, setBulkBusy] = React.useState(false);
  const [busyRow, setBusyRow] = React.useState('');

  const [archiveAgent] = useArchiveAgentIdentityMutation();

  const runArchive = React.useCallback(
    async (agentId: string) => {
      const saved = await archiveAgent({ agentId }).unwrap();
      const record = saved && typeof saved === 'object' ? saved : null;
      if (record) {
        list.patchItem(agentId, (prev) => ({ ...prev, state: 'archived', updatedAt: String((record as any).updated_at || prev.updatedAt) }));
      }
    },
    [archiveAgent, list],
  );

  const runBulkArchive = React.useCallback(
    async (ids: string[]) => {
      setBulkBusy(true);
      const failed: string[] = [];
      let done = 0;
      for (const id of ids) {
        try {
          await runArchive(id);
          done += 1;
        } catch {
          failed.push(id);
        }
      }
      setBulkBusy(false);
      setSelectedIds(failed);
      pushToast({
        tone: failed.length ? 'danger' : 'success',
        title: failed.length ? `${done} archived, ${failed.length} failed` : `${done} archived`,
        message: failed.length ? 'The rows that failed are still selected.' : undefined,
      });
    },
    [pushToast, runArchive],
  );

  /* ---------------- Keyboard ---------------- */
  const [cursorId, setCursorId] = React.useState('');
  const cursorRef = React.useRef('');
  cursorRef.current = cursorId || selectedId;

  React.useEffect(() => {
    function onKeyDown(event: KeyboardEvent) {
      if (event.metaKey || event.ctrlKey || event.altKey) return;
      const target = event.target as HTMLElement | null;
      const tag = target?.tagName?.toLowerCase();
      const typing = tag === 'input' || tag === 'textarea' || tag === 'select' || target?.isContentEditable;
      if (event.key === '/' && !typing) {
        event.preventDefault();
        searchRef.current?.focus();
        return;
      }
      if (typing || confirm) return;

      const items = visibleRows;
      const index = items.findIndex((row) => row.agentId === cursorRef.current);

      if (event.key === 'j' || event.key === 'k') {
        if (items.length === 0) return;
        event.preventDefault();
        const nextIndex = event.key === 'j'
          ? Math.min(items.length - 1, index < 0 ? 0 : index + 1)
          : Math.max(0, index < 0 ? 0 : index - 1);
        const next = items[nextIndex];
        const nextId = next ? next.agentId : '';
        setCursorId(nextId);
        if (twoPane && nextId) navigateTo(agentViewHref(nextId, urlState));
        const node = nextId ? document.querySelector(`[data-agent-row="${CSS.escape(nextId)}"]`) : null;
        node?.scrollIntoView({ block: 'nearest' });
        return;
      }

      if (event.key === 'e') {
        const row = index >= 0 ? items[index] : null;
        if (!row) return;
        event.preventDefault();
        rememberRow(row.agentId);
        navigateTo(agentEditHref(row.agentId));
      }
    }
    window.addEventListener('keydown', onKeyDown);
    return () => window.removeEventListener('keydown', onKeyDown);
  }, [confirm, twoPane, urlState, visibleRows]);

  /* ---------------- Empty states ---------------- */
  function emptyState(): React.ReactNode {
    if (searching) {
      return (
        <EmptyState
          data-debug-id="agent-empty-query"
          icon="search"
          title={`No agents match "${urlState.q}"`}
          description="Search covers agent names, slugs and IDs — not instructions."
          action={<Button variant="secondary" onClick={() => { setQueryInput(''); applyUrlState({ ...urlState, q: '' }); }}>Clear search</Button>}
        />
      );
    }
    if (tab === 'archived') {
      return (
        <EmptyState
          data-debug-id="agent-empty-archived"
          icon="folder"
          title="Nothing archived"
          description="Archiving takes an agent out of the Active list without stopping its instances or deleting its memories."
        />
      );
    }
    return (
      <EmptyState
        data-debug-id="agent-empty-first-run"
        icon="bot"
        title="No agents yet"
        description="An agent is a persona with instructions and a model. Create one and it can run on any bridge in your workspace."
        action={<Button variant="primary" onClick={() => navigateTo(agentNewHref())}>New agent</Button>}
      />
    );
  }

  /* ---------------- List foot ---------------- */
  const footer = (
    <div>
      {active.isPaging ? (
        <div data-debug-id="agent-paging-skeleton" aria-hidden="true" className="flex flex-col gap-2 py-3">
          {[0, 1, 2].map((i) => (
            <div key={i} className="h-5 w-full animate-pulse rounded-[var(--radius-sm)] bg-neutral-soft" />
          ))}
        </div>
      ) : null}
      {active.pagingError ? (
        <div data-debug-id="agent-paging-error" className="py-3">
          <Alert tone="danger" title="Couldn't load more agents">
            <div className="flex items-center gap-3">
              <span>{agentErrorText(active.pagingError)}</span>
              <Button size="sm" variant="secondary" onClick={() => active.loadMore()}>Retry</Button>
            </div>
          </Alert>
        </div>
      ) : null}
      {active.hasMore && !active.pagingError ? (
        <div ref={active.sentinelRef} data-debug-id="agent-scroll-sentinel" className="h-px w-full" />
      ) : null}
    </div>
  );

  /* ---------------- Rows ---------------- */
  const openAgent = React.useCallback(
    (agentId: string) => {
      if (!agentId) return;
      rememberRow(agentId);
      navigateTo(agentViewHref(agentId, urlState));
    },
    [urlState],
  );

  const selectable = !searching && tab === 'active';

  const listBody = (
    <>
      {active.status === 'error' ? (
        <Alert tone="danger" title="Couldn't load agents">
          <div className="flex flex-col items-start gap-3">
            <span>{agentErrorText(active.error)}</span>
            <Button size="sm" variant="secondary" onClick={() => active.reload()}>Retry</Button>
          </div>
        </Alert>
      ) : active.isLoadingInitial ? (
        <div role="status" aria-live="polite" aria-busy="true" data-debug-id="agent-list-skeleton">
          <span className="sr-only">Loading agents…</span>
          <ul aria-hidden="true" className="flex flex-col">
            {[0, 1, 2, 3, 4, 5].map((i) => (
              <li key={i} className="flex min-h-[72px] flex-col justify-center gap-2 border-b border-subtle px-3 py-3">
                <div className="h-4 w-2/3 animate-pulse rounded-[var(--radius-sm)] bg-neutral-soft" />
                <div className="h-3 w-5/6 animate-pulse rounded-[var(--radius-sm)] bg-neutral-soft" />
                <div className="h-3 w-1/3 animate-pulse rounded-[var(--radius-sm)] bg-neutral-soft" />
              </li>
            ))}
          </ul>
        </div>
      ) : searching ? (
        search.items.length === 0 ? (
          emptyState()
        ) : (
          <ul
            aria-label="Agent search results"
            data-debug-id="agent-search-rows"
            className={['flex flex-col', querySettling ? 'opacity-60' : ''].filter(Boolean).join(' ')}
          >
            {search.items.map((hit) => (
              <AgentRow
                key={hit.id}
                row={{
                  agentId: hit.id,
                  name: hit.label,
                  slug: hit.slug,
                  templateId: '',
                  defaultProvider: '',
                  defaultTier: '',
                  instructions: hit.preview,
                  state: 'active',
                  supportedBridgeCount: 0,
                  activeInstanceCount: 0,
                  updatedAt: '',
                }}
                href={agentViewHref(hit.id, urlState)}
                selectable={false}
                showCheckbox={false}
                selected={false}
                active={hit.id === selectedId}
                onSelectedChange={() => undefined}
                onVerb={(row, verb) => {
                  if (verb === 'edit') navigateTo(agentEditHref(row.agentId));
                }}
                onOpen={() => openAgent(hit.id)}
              />
            ))}
          </ul>
        )
      ) : visibleRows.length === 0 ? (
        moreToSearch ? (
          <div className="flex flex-col items-start gap-3 py-6" data-debug-id="agent-more-to-search">
            <Text role="body" tone="muted" className="ui-measure">
              Nothing under {AGENT_TABS.find((entry) => entry.value === tab)?.label} in the agents loaded so far.
              This list loads in pages, and older agents may still be further down.
            </Text>
            <Button
              size="sm"
              variant="secondary"
              loading={list.isPaging}
              data-debug-id="agent-load-more"
              onClick={() => list.loadMore()}
            >
              Keep loading
            </Button>
          </div>
        ) : (
          emptyState()
        )
      ) : (
        <ul aria-label="Agents" data-debug-id="agent-rows" className="flex flex-col">
          {visibleRows.map((row) => (
            <AgentRow
              key={row.agentId}
              row={row}
              href={agentViewHref(row.agentId, urlState)}
              selectable={selectable}
              showCheckbox={selectable}
              selected={selectedIds.includes(row.agentId)}
              active={row.agentId === selectedId}
              busy={busyRow === row.agentId}
              onSelectedChange={(next) =>
                setSelectedIds((prev) => (next ? [...prev, row.agentId] : prev.filter((id) => id !== row.agentId)))
              }
              onVerb={(target, verb: AgentVerb) => {
                if (verb === 'edit') {
                  rememberRow(target.agentId);
                  navigateTo(agentEditHref(target.agentId));
                  return;
                }
                setConfirm({ ids: [target.agentId] });
              }}
              onOpen={() => openAgent(row.agentId)}
            />
          ))}
        </ul>
      )}
      {footer}
    </>
  );

  const listSection = (
    <div className={`flex w-full min-w-0 flex-col gap-4 ${twoPane ? 'flex-1 min-h-0 overflow-hidden' : ''}`}>
      {!searching && list.pendingCount > 0 ? (
        <div className="shrink-0">
          <Button size="sm" variant="secondary" data-debug-id="agent-pending-pill" onClick={() => list.applyPending()}>
            {list.pendingCount} new or updated — refresh
          </Button>
        </div>
      ) : null}

      {list.restoreNotice ? (
        <div className="shrink-0">
          <Text role="body-sm" tone="muted" data-debug-id="agent-restore-notice">
            Couldn&apos;t find where you were — showing the top of the list.
          </Text>
        </div>
      ) : null}

      <div className={twoPane ? 'flex-1 min-h-0 overflow-y-auto' : undefined}>
        {listBody}
      </div>

      {selectable ? (
        <div className="shrink-0">
          <BulkActionBar
            selectedCount={selectedIds.length}
            loadedCount={visibleRows.length}
            onCancel={() => setSelectedIds([])}
          >
            <ActionButton
              icon="folder"
              label="Archive"
              variant="danger"
              loading={bulkBusy}
              disabled={selectedIds.length === 0}
              data-debug-id="agent-bulk-archive"
              onClick={() => selectedIds.length && setConfirm({ ids: selectedIds })}
            />
          </BulkActionBar>
        </div>
      ) : null}
    </div>
  );

  /* ---------------- Toolbar ---------------- */
  const toolbar = (
    <div className="flex items-center gap-2" data-debug-id="agent-toolbar">
      <Input
        type="search"
        value={queryInput}
        onChange={setQueryInput}
        width="full"
        size={isMobile ? 'md' : 'sm'}
        leading={<Icon name="search" size="sm" />}
        placeholder="Search names and slugs…"
        aria-label="Search agent names and slugs"
        data-debug-id="agent-search-input"
        ref={searchRef}
        className={['min-w-0 flex-1', isMobile ? TOUCH_TARGET_CLASS : ''].filter(Boolean).join(' ')}
      />
      {urlState.q ? (
        <ActionButton
          icon="close"
          label="Clear"
          aria-label="Clear search"
          data-debug-id="agent-search-clear"
          onClick={() => { setQueryInput(''); applyUrlState({ ...urlState, q: '' }); }}
        />
      ) : null}
    </div>
  );

  const tabsBlock = (
    <Tabs
      value={searching ? '' : tab}
      onChange={(next) => applyUrlState({ ...urlState, tab: next as AgentTab })}
      className={twoPane ? 'flex flex-1 min-h-0 flex-col overflow-hidden' : undefined}
    >
      <TabsList label="Agent state" className="shrink-0">
        {AGENT_TABS.map((entry) => (
          <Tab key={entry.value} value={entry.value} disabled={searching} data-debug-id={`agent-tab-${entry.value}`}>
            {entry.label}
          </Tab>
        ))}
      </TabsList>
      {searching ? null : (
        <TabsPanel value={tab} className={twoPane ? 'flex flex-1 min-h-0 flex-col overflow-hidden' : undefined}>
          {listSection}
        </TabsPanel>
      )}
    </Tabs>
  );

  const listColumn = (
    <div data-debug-id="agent-list-page" className={`flex w-full min-w-0 flex-col gap-3 ${twoPane ? 'flex-1 min-h-0 h-full overflow-hidden' : ''}`}>
      <div className="shrink-0">{toolbar}</div>
      <div className={`flex min-w-0 flex-col gap-4 ${twoPane ? 'flex-1 min-h-0 overflow-hidden' : ''}`}>
        {tabsBlock}
        {searching ? listSection : null}
      </div>
    </div>
  );

  const confirmNames = React.useMemo(
    () =>
      (confirm?.ids || []).map((id) => {
        const row = list.items.find((item) => item.agentId === id);
        return row ? agentTitle(row) : id;
      }),
    [confirm, list.items],
  );

  const overlays = (
    <>
      {confirm ? (
        <Modal
          open
          onOpenChange={(next) => { if (!next) setConfirm(null); }}
          title={confirm.ids.length === 1 ? `Archive "${confirmNames[0]}"?` : `Archive ${confirm.ids.length} agents?`}
          size="sm"
          data-debug-id="agent-archive-modal"
        >
          <ModalBody>
            <Text role="body">{archiveConfirmBody(confirmNames)}</Text>
          </ModalBody>
          <ModalFooter>
            <Button variant="secondary" data-debug-id="agent-archive-cancel" onClick={() => setConfirm(null)}>Cancel</Button>
            <Button
              variant="danger"
              loading={bulkBusy}
              data-debug-id="agent-archive-confirm"
              onClick={() => {
                const pending = confirm;
                setConfirm(null);
                if (!pending) return;
                if (pending.ids.length === 1) {
                  const only = pending.ids[0];
                  setBusyRow(only);
                  void runArchive(only)
                    .then(() => pushToast({ tone: 'success', title: 'Agent archived' }))
                    .catch((err) => pushToast({ tone: 'danger', title: "Couldn't archive this agent", message: agentErrorText(err) }))
                    .finally(() => setBusyRow(''));
                  return;
                }
                void runBulkArchive(pending.ids);
              }}
            >
              Archive
            </Button>
          </ModalFooter>
        </Modal>
      ) : null}

      {toasts.length ? (
        <div className="pointer-events-none fixed inset-x-0 bottom-0 z-toast flex flex-col items-center gap-2 p-4 sm:items-end">
          {toasts.map((entry) => (
            <div key={entry.id} className="pointer-events-auto">
              <Toast tone={entry.tone} title={entry.title} duration={4000} onDismiss={() => dismissToast(entry.id)}>
                {entry.message ? <span>{entry.message}</span> : null}
              </Toast>
            </div>
          ))}
        </div>
      ) : null}
    </>
  );

  const headerDescription = 'An agent is a persona — instructions, a model, and an identity — that can run across your bridges.';

  /* ---------------- Two-pane ---------------- */
  if (twoPane) {
    return (
      <PageShell
        width="full"
        rhythm="banded"
        title="Agents"
        breadcrumbs={listCrumbs()}
        description={headerDescription}
        className="h-full min-h-0 overflow-hidden"
        actions={
          <Button
            variant="primary"
            data-debug-id="agent-new-btn"
            leading={<Icon name="plus" size="sm" />}
            onClick={() => navigateTo(agentNewHref())}
          >
            New agent
          </Button>
        }
      >
        <div className="flex min-w-0 items-stretch gap-4 flex-1 min-h-0 h-full overflow-hidden">
          <div className="w-full min-w-0 max-w-[420px] shrink-0 flex flex-col min-h-0 h-full overflow-hidden">{listColumn}</div>
          <div className="min-w-0 flex-1 border-l border-subtle pl-4 flex flex-col min-h-0 h-full overflow-hidden" data-debug-id="agent-detail-pane">
            {selectedId ? (
              <AgentDetailPane agentId={selectedId} onAfterArchive={() => undefined} />
            ) : (
              <div className="flex h-full items-center justify-center p-6">
                <Text role="body-sm" tone="muted">Select an agent to see it here.</Text>
              </div>
            )}
          </div>
        </div>
        {overlays}
      </PageShell>
    );
  }

  return (
    <PageShell
      width={viewport === 'tablet' ? 'content' : 'full'}
      rhythm="banded"
      title="Agents"
      breadcrumbs={listCrumbs()}
      description={headerDescription}
      actions={
        <ActionButton
          icon="plus"
          label="New agent"
          variant="primary"
          showIconOnDesktop
          data-debug-id="agent-new-btn"
          onClick={() => navigateTo(agentNewHref())}
        />
      }
    >
      {listColumn}
      {overlays}
    </PageShell>
  );
}

/**
 * The right-hand pane of the two-pane layout.
 */
function AgentDetailPane({ agentId, onAfterArchive }: { agentId: string; onAfterArchive: () => void }) {
  const { query, record, busy, actionError, runVerb } = useAgentDetail(agentId, () => onAfterArchive());
  const paneRef = React.useRef<HTMLDivElement | null>(null);
  const wide = usePaneIsWide(paneRef);

  if (query.isLoading) return <AgentDetailPaneSkeleton />;
  if (query.error || !record) {
    return (
      <EmptyState
        data-debug-id="agent-pane-missing"
        icon="search"
        title="That agent doesn't exist"
        description={query.error ? agentErrorText(query.error) : undefined}
        action={<Button variant="secondary" onClick={() => navigateTo(agentListHref())}>Back to Agents</Button>}
      />
    );
  }

  const title = agentTitle(record);

  return (
    <div ref={paneRef} className="min-w-0 flex flex-col min-h-0 h-full overflow-hidden">
      <div className="mb-3 flex shrink-0 items-start justify-between gap-3">
        <div className="min-w-0">
          <a
            href={agentViewHref(record.agentId)}
            data-debug-id="agent-pane-title"
            className="block truncate rounded-[var(--radius-sm)] text-page-title text-primary focus-visible:shadow-focus focus-visible:outline-none"
          >
            {title}
          </a>
          <AgentDetailMeta record={record} />
        </div>
        <div className="flex shrink-0 items-center gap-2">
          <AgentDetailActions record={record} busy={busy} onVerb={(verb) => void runVerb(verb)} />
        </div>
      </div>
      <div className="flex-1 min-h-0 overflow-y-auto">
        <AgentDetailBody record={record} actionError={actionError} wide={wide} />
      </div>
    </div>
  );
}

/** Re-exported for the shell's route table. */
export { EMPTY_LIST_URL_STATE };
export { agentState };

