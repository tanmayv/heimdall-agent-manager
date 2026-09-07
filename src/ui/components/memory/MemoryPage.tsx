// MemoryPage — first-class Memory surface (/memory).
//
// Redesign of the memory management surface around the list scope model
// (agent_ids/project_ids/bridge_ids/template_ids, empty = applies to all). Two
// tabs: Active (browse + filter + edit/delete) and Proposals (approve/reject with
// editable scope). Row titles open the dedicated /memory/:id detail page. Styling
// follows the current Heimdall design system (LibraryPage header/filter chrome,
// SearchableSelect popover, Markdown body, Icon buttons).

import { useMemo, useState } from 'react';
import { buildRouteHash } from '../../utils/appLocation';
import Icon from '../Icon';
import Markdown from '../Markdown';
import {
  useListMemoriesQuery,
  useArchiveMemoryMutation,
  useApproveMemoryMutation,
  useRejectMemoryMutation,
  useCreateMemoryMutation,
} from '../../api/endpoints/memory';
import {
  MEMORY_TYPES,
  ScopeChips,
  ScopeEditor,
  emptyTargeting,
  targetingFromRecord,
  useMemoryScopeCatalog,
  type ScopeCatalog,
  type Targeting,
} from './memoryScope';

function timeAgo(unixMs?: number): string {
  if (!unixMs) return '';
  const delta = Date.now() - Number(unixMs);
  if (delta < 0) return '';
  const mins = Math.floor(delta / 60000);
  if (mins < 1) return 'just now';
  if (mins < 60) return `${mins}m ago`;
  const hours = Math.floor(mins / 60);
  if (hours < 24) return `${hours}h ago`;
  const days = Math.floor(hours / 24);
  if (days < 30) return `${days}d ago`;
  return new Date(unixMs).toLocaleDateString();
}

function navigateToMemory(memoryId: string, opts?: { edit?: boolean }) {
  window.location.hash = buildRouteHash(`/memory/${encodeURIComponent(memoryId)}`, opts?.edit ? 'edit=1' : '');
}

type TabKey = 'active' | 'proposals';

export default function MemoryPage() {
  const catalog = useMemoryScopeCatalog();
  const [tab, setTab] = useState<TabKey>('active');
  const [search, setSearch] = useState('');
  const [typeFilter, setTypeFilter] = useState('');
  const [facets, setFacets] = useState<Targeting>(emptyTargeting());
  const [createOpen, setCreateOpen] = useState(false);
  const [deleteTarget, setDeleteTarget] = useState<any | null>(null);

  // Active memories: the hub matches when a memory's dimension list is empty
  // (global) OR contains a selected id, so passing the facet lists narrows the
  // server result. Free text is applied client-side over the returned rows.
  const activeQuery = useListMemoriesQuery({ status: 'active', type: typeFilter || undefined, ...facets });
  const activeItems: any[] = activeQuery.data?.items || [];
  const proposalsQuery = useListMemoriesQuery({ status: 'pending' });
  const proposals: any[] = proposalsQuery.data?.items || [];

  const filteredActive = useMemo(() => {
    const q = search.trim().toLowerCase();
    if (!q) return activeItems;
    return activeItems.filter((m) => [m.title, m.body, m.memoryId, m.type].some((v) => String(v || '').toLowerCase().includes(q)));
  }, [activeItems, search]);

  const [archiveMemory] = useArchiveMemoryMutation();

  const facetsActive = facets.agentIds.length || facets.projectIds.length || facets.bridgeIds.length || facets.templateIds.length || typeFilter;

  async function confirmDelete() {
    if (!deleteTarget) return;
    try {
      await archiveMemory({ memoryId: deleteTarget.memoryId || deleteTarget.id }).unwrap();
    } catch {
      // RTK Query tag invalidation keeps the list fresh; surface nothing on failure here.
    } finally {
      setDeleteTarget(null);
    }
  }

  return (
    <div data-debug-id="memory-page" className="w-full text-zinc-100">
      {/* Header */}
      <div data-debug-id="memory-header" className="flex flex-wrap items-start justify-between gap-3">
        <div className="min-w-0">
          <div className="text-[10.5px] font-semibold uppercase tracking-[0.24em] text-zinc-500">Memory</div>
          <div className="mt-1 flex items-center gap-2">
            <h1 className="truncate text-2xl font-semibold tracking-[-0.01em] text-zinc-100">Memory</h1>
            <span data-debug-id="memory-active-count-pill" className="rounded-full border border-white/10 bg-white/[0.04] px-2 py-0.5 text-[11px] text-zinc-400">{activeItems.length}</span>
          </div>
          <p className="mt-1 text-[13px] text-zinc-500">Durable facts, habits &amp; skills for your agents. Empty scope = applies to all.</p>
        </div>
        <div className="flex items-center gap-2">
          <button type="button" data-debug-id="memory-new-btn" onClick={() => setCreateOpen(true)} className="inline-flex items-center gap-1.5 rounded-lg border border-sky-400/30 bg-sky-400/10 px-3 py-1.5 text-[12.5px] font-semibold text-sky-100 hover:bg-sky-400/20">
            <Icon name="plus" size={14} /> Propose memory
          </button>
          <button type="button" data-debug-id="memory-refresh-btn" onClick={() => { activeQuery.refetch(); proposalsQuery.refetch(); }} className="inline-flex items-center gap-1.5 rounded-lg border border-white/10 bg-white/[0.04] px-3 py-1.5 text-[12.5px] text-zinc-300 hover:bg-white/10">
            <Icon name="refresh" size={14} /> Refresh
          </button>
        </div>
      </div>

      {/* Tabs */}
      <div data-debug-id="memory-tabs" className="mt-5 flex items-center gap-6 border-b border-white/[0.08]">
        <TabButton id="active" label="Active" count={activeItems.length} active={tab === 'active'} onClick={() => setTab('active')} />
        <TabButton id="proposals" label="Proposals" count={proposals.length} active={tab === 'proposals'} onClick={() => setTab('proposals')} />
      </div>

      {tab === 'active' ? (
        <div className="mt-4">
          {/* Filter bar */}
          <div data-debug-id="memory-filter-bar" className="space-y-3">
            <div className="flex flex-wrap items-center gap-2">
              <input data-debug-id="memory-filter-search" value={search} onChange={(e) => setSearch(e.target.value)} placeholder="Search title / body / id…" className="min-w-[14rem] flex-1 rounded-lg border border-white/10 bg-black/30 px-3 py-1.5 text-sm text-zinc-100 outline-none placeholder:text-zinc-600 focus:border-sky-400" />
              <label className="text-[11px] uppercase tracking-wide text-zinc-500">Type
                <select data-debug-id="memory-filter-type" value={typeFilter} onChange={(e) => setTypeFilter(e.target.value)} className="ml-1 rounded-lg border border-white/10 bg-black/30 px-2 py-1.5 text-sm text-zinc-100 outline-none">
                  <option value="">all</option>
                  {MEMORY_TYPES.map((t) => <option key={t} value={t}>{t}</option>)}
                </select>
              </label>
              {facetsActive ? (
                <button type="button" data-debug-id="memory-filter-clear" onClick={() => { setFacets(emptyTargeting()); setTypeFilter(''); setSearch(''); }} className="text-[11px] text-zinc-500 hover:text-zinc-200">clear</button>
              ) : null}
            </div>
            <ScopeEditor targeting={facets} catalog={catalog} onChange={setFacets} debugId="memory-filter-scope" />
          </div>

          {/* List */}
          <div data-debug-id="memory-list" className="mt-4 space-y-3">
            {activeQuery.isFetching && activeItems.length === 0 ? (
              <Empty text="Loading memories…" />
            ) : filteredActive.length === 0 ? (
              <Empty text={activeItems.length === 0 ? 'No active memories yet. Propose one to get started.' : 'No memories match your filters.'} />
            ) : filteredActive.map((memory) => (
              <MemoryListItem key={memory.memoryId || memory.id} memory={memory} catalog={catalog} onDelete={() => setDeleteTarget(memory)} />
            ))}
          </div>
        </div>
      ) : (
        <div data-debug-id="memory-proposals" className="mt-4 space-y-3">
          {proposalsQuery.isFetching && proposals.length === 0 ? (
            <Empty text="Loading proposals…" />
          ) : proposals.length === 0 ? (
            <Empty text="No pending proposals." />
          ) : proposals.map((memory) => (
            <ProposalCard key={memory.proposalId || memory.memoryId} memory={memory} catalog={catalog} />
          ))}
        </div>
      )}

      {createOpen ? <CreateMemoryModal catalog={catalog} onClose={() => setCreateOpen(false)} /> : null}
      {deleteTarget ? (
        <ConfirmDeleteModal
          title={deleteTarget.title || deleteTarget.memoryId}
          onCancel={() => setDeleteTarget(null)}
          onConfirm={confirmDelete}
        />
      ) : null}
    </div>
  );
}

function TabButton({ id, label, count, active, onClick }: { id: string; label: string; count: number; active: boolean; onClick: () => void }) {
  return (
    <button
      type="button"
      data-debug-id={`memory-tab-${id}`}
      onClick={onClick}
      className={`-mb-px flex items-center gap-2 border-b-2 px-1 pb-2.5 text-sm font-semibold ${active ? 'border-sky-400 text-zinc-100' : 'border-transparent text-zinc-500 hover:text-zinc-300'}`}
    >
      {label}
      <span className={`rounded-full px-1.5 py-0.5 text-[10.5px] ${active ? 'bg-sky-400/15 text-sky-200' : 'bg-white/[0.06] text-zinc-400'}`}>{count}</span>
    </button>
  );
}

function MemoryListItem({ memory, catalog, onDelete }: { memory: any; catalog: ScopeCatalog; onDelete: () => void }) {
  const id = memory.memoryId || memory.id;
  const targeting = targetingFromRecord(memory);
  return (
    <div data-debug-id={`memory-row-${id}`} className="rounded-2xl border border-white/10 bg-white/[0.02] p-4 transition hover:border-white/20 hover:bg-white/[0.04]">
      <div className="flex items-start justify-between gap-3">
        <div className="min-w-0 flex-1">
          <div className="flex flex-wrap items-center gap-2">
            <button type="button" data-debug-id={`memory-row-open-${id}`} onClick={() => navigateToMemory(id)} className="truncate text-left text-base font-semibold text-zinc-100 hover:text-sky-200">
              {memory.title || id}
            </button>
            <Badge>{memory.type || 'fact'}</Badge>
            <span className="text-[11px] text-zinc-600">v{memory.version || 0}</span>
            <span className="text-[11px] text-zinc-600">·</span>
            <span className="text-[11px] text-zinc-600">{timeAgo(memory.updatedUnixMs || memory.createdUnixMs)}</span>
          </div>
          {memory.body ? <p className="mt-1.5 line-clamp-2 text-[12.5px] leading-5 text-zinc-400">{memory.body}</p> : null}
          <div className="mt-2">
            <ScopeChips targeting={targeting} catalog={catalog} debugId={`memory-row-scope-${id}`} />
          </div>
          <div className="mt-1 font-mono text-[10.5px] text-zinc-600">{id}</div>
        </div>
        <div className="flex shrink-0 items-center gap-1">
          <button type="button" aria-label="Open" title="Open" data-debug-id={`memory-row-detail-${id}`} onClick={() => navigateToMemory(id)} className="rounded-md border border-white/10 px-2 py-1 text-[11.5px] text-zinc-300 hover:bg-white/10">Open</button>
          <button type="button" aria-label="Edit" title="Edit" data-debug-id={`memory-row-edit-${id}`} onClick={() => navigateToMemory(id, { edit: true })} className="rounded-md border border-white/10 px-1.5 py-1 text-zinc-400 hover:bg-white/10"><Icon name="pencil" size={13} /></button>
          <button type="button" aria-label="Delete" title="Delete" data-debug-id={`memory-row-delete-${id}`} onClick={onDelete} className="rounded-md border border-white/10 px-1.5 py-1 text-rose-300 hover:bg-rose-500/10"><Icon name="trash" size={13} /></button>
        </div>
      </div>
    </div>
  );
}

function ProposalCard({ memory, catalog }: { memory: any; catalog: ScopeCatalog }) {
  const id = memory.memoryId || memory.id;
  const [targeting, setTargeting] = useState<Targeting>(() => targetingFromRecord(memory));
  const [reason, setReason] = useState('');
  const [busy, setBusy] = useState<'' | 'approve' | 'reject'>('');
  const [error, setError] = useState('');
  const [approveMemory] = useApproveMemoryMutation();
  const [rejectMemory] = useRejectMemoryMutation();

  async function decide(decision: 'approve' | 'reject') {
    setBusy(decision);
    setError('');
    try {
      if (decision === 'reject') {
        await rejectMemory({ memoryId: id, reason: reason || undefined }).unwrap();
      } else {
        await approveMemory({ memoryId: id, title: memory.title, body: memory.body, evidence: memory.evidence || undefined, type: memory.type, reason: reason || undefined, ...targeting }).unwrap();
      }
    } catch (err: any) {
      setError(String(err?.data?.error || err?.message || err || 'Decision failed.'));
    } finally {
      setBusy('');
    }
  }

  return (
    <div data-debug-id={`memory-proposal-${id}`} className="rounded-2xl border border-amber-400/25 bg-amber-950/10 p-4">
      <div className="flex flex-wrap items-center justify-between gap-2">
        <div className="flex flex-wrap items-center gap-2">
          <span className="rounded-full bg-amber-400/20 px-2 py-0.5 text-[11px] font-bold uppercase text-amber-200">Pending</span>
          <span className="font-semibold text-zinc-100">{memory.title || id}</span>
          <Badge>{memory.type || 'fact'}</Badge>
        </div>
        <span className="font-mono text-[11px] text-zinc-500">{memory.proposalId || id}</span>
      </div>

      {memory.body ? (
        <div className="mt-3 rounded-xl border border-white/10 bg-black/30 p-3">
          <Markdown source={memory.body} compact className="text-sm text-zinc-200" />
        </div>
      ) : null}
      {(memory.reason || memory.evidence) ? (
        <div className="mt-2 grid gap-2 text-xs text-zinc-400 sm:grid-cols-2">
          <div><span className="text-zinc-500">Reason:</span> {memory.reason || '—'}</div>
          <div><span className="text-zinc-500">Evidence:</span> {memory.evidence || '—'}</div>
        </div>
      ) : null}

      <div className="mt-3">
        <div className="mb-1.5 text-[11px] uppercase tracking-wide text-zinc-500">Scope (editable before deciding)</div>
        <ScopeEditor targeting={targeting} catalog={catalog} onChange={setTargeting} debugId={`memory-proposal-scope-${id}`} />
      </div>

      <input data-debug-id={`memory-proposal-reason-${id}`} value={reason} onChange={(e) => setReason(e.target.value)} placeholder="Decision reason (optional)" className="mt-3 w-full rounded-lg border border-white/10 bg-black/30 px-3 py-2 text-sm text-zinc-100 outline-none placeholder:text-zinc-600 focus:border-sky-400" />
      {error ? <div className="mt-2 rounded-lg border border-red-400/25 bg-red-500/10 px-3 py-2 text-xs text-red-200">{error}</div> : null}
      <div className="mt-3 flex flex-wrap justify-end gap-2">
        <button type="button" data-debug-id={`memory-proposal-reject-${id}`} disabled={Boolean(busy)} onClick={() => decide('reject')} className="rounded-lg border border-red-400/30 bg-red-500/10 px-3 py-1.5 text-sm font-semibold text-red-200 hover:bg-red-500/20 disabled:opacity-50">{busy === 'reject' ? 'Rejecting…' : 'Reject'}</button>
        <button type="button" data-debug-id={`memory-proposal-approve-${id}`} disabled={Boolean(busy)} onClick={() => decide('approve')} className="rounded-lg bg-emerald-400 px-3.5 py-1.5 text-sm font-bold text-black hover:bg-emerald-300 disabled:opacity-50">{busy === 'approve' ? 'Approving…' : 'Approve'}</button>
      </div>
    </div>
  );
}

function CreateMemoryModal({ catalog, onClose }: { catalog: ScopeCatalog; onClose: () => void }) {
  const [title, setTitle] = useState('');
  const [body, setBody] = useState('');
  const [evidence, setEvidence] = useState('');
  const [type, setType] = useState('fact');
  const [targeting, setTargeting] = useState<Targeting>(emptyTargeting());
  const [error, setError] = useState('');
  const [createMemory, { isLoading }] = useCreateMemoryMutation();

  async function submit() {
    setError('');
    if (!title.trim() || !body.trim()) {
      setError('Title and body are required.');
      return;
    }
    try {
      await createMemory({ title: title.trim(), body: body.trim(), evidence: evidence.trim() || undefined, type, status: 'active', ...targeting }).unwrap();
      onClose();
    } catch (err: any) {
      setError(String(err?.data?.error || err?.message || err || 'Failed to create memory.'));
    }
  }

  return (
    <ModalShell debugId="memory-create-modal" title="Propose memory" onClose={onClose}>
      {error ? <div data-debug-id="memory-create-error" className="rounded-lg border border-red-400/25 bg-red-500/10 px-3 py-2 text-xs text-red-200">{error}</div> : null}
      <div className="grid gap-3 sm:grid-cols-2">
        <Field label="Title">
          <input data-debug-id="memory-create-title" value={title} onChange={(e) => setTitle(e.target.value)} placeholder="Memory title" className="w-full rounded-lg border border-white/10 bg-black/40 px-3 py-2 text-sm text-zinc-100 outline-none focus:border-sky-400" />
        </Field>
        <Field label="Type">
          <select data-debug-id="memory-create-type" value={type} onChange={(e) => setType(e.target.value)} className="w-full rounded-lg border border-white/10 bg-black/40 px-3 py-2 text-sm text-zinc-100 outline-none focus:border-sky-400">
            {MEMORY_TYPES.map((t) => <option key={t} value={t}>{t}</option>)}
          </select>
        </Field>
      </div>
      <Field label="Body">
        <textarea data-debug-id="memory-create-body" value={body} onChange={(e) => setBody(e.target.value)} rows={6} placeholder="Memory body (Markdown)" className="w-full resize-y rounded-lg border border-white/10 bg-black/40 px-3 py-2 text-sm text-zinc-100 outline-none focus:border-sky-400" />
      </Field>
      <Field label="Evidence (optional)">
        <input data-debug-id="memory-create-evidence" value={evidence} onChange={(e) => setEvidence(e.target.value)} placeholder="Links, notes, source" className="w-full rounded-lg border border-white/10 bg-black/40 px-3 py-2 text-sm text-zinc-100 outline-none focus:border-sky-400" />
      </Field>
      <Field label="Scope (empty = applies to all)">
        <ScopeEditor targeting={targeting} catalog={catalog} onChange={setTargeting} debugId="memory-create-scope" />
      </Field>
      <div className="mt-1 flex justify-end gap-2">
        <button type="button" data-debug-id="memory-create-cancel" onClick={onClose} className="rounded-lg border border-white/10 bg-white/[0.04] px-3 py-1.5 text-sm text-zinc-300 hover:bg-white/10">Cancel</button>
        <button type="button" data-debug-id="memory-create-submit" disabled={isLoading} onClick={submit} className="rounded-lg bg-sky-400 px-4 py-1.5 text-sm font-semibold text-black hover:bg-sky-300 disabled:opacity-50">{isLoading ? 'Creating…' : 'Create'}</button>
      </div>
    </ModalShell>
  );
}

function ConfirmDeleteModal({ title, onCancel, onConfirm }: { title: string; onCancel: () => void; onConfirm: () => void }) {
  return (
    <ModalShell debugId="memory-delete-modal" title="Delete memory" onClose={onCancel} maxWidth="max-w-md">
      <p className="text-sm text-zinc-300">Delete <span className="font-semibold text-zinc-100">{title}</span>? Agents will stop receiving it.</p>
      <div className="mt-4 flex justify-end gap-2">
        <button type="button" data-debug-id="memory-delete-cancel" onClick={onCancel} className="rounded-lg border border-white/10 bg-white/[0.04] px-3 py-1.5 text-sm text-zinc-300 hover:bg-white/10">Cancel</button>
        <button type="button" data-debug-id="memory-delete-confirm" onClick={onConfirm} className="rounded-lg bg-rose-400 px-4 py-1.5 text-sm font-bold text-black hover:bg-rose-300">Delete</button>
      </div>
    </ModalShell>
  );
}

function ModalShell({ debugId, title, onClose, maxWidth = 'max-w-2xl', children }: { debugId: string; title: string; onClose: () => void; maxWidth?: string; children: React.ReactNode }) {
  return (
    <div data-debug-id={`${debugId}-overlay`} className="fixed inset-0 z-[60] flex items-start justify-center overflow-y-auto bg-black/60 p-4 sm:p-8" onClick={onClose}>
      <div data-debug-id={debugId} className={`w-full ${maxWidth} rounded-2xl border border-white/10 bg-[#0d0f14] p-5 shadow-2xl shadow-black/70`} onClick={(e) => e.stopPropagation()}>
        <div className="mb-4 flex items-center justify-between">
          <h2 className="text-lg font-semibold text-zinc-100">{title}</h2>
          <button type="button" aria-label="Close" data-debug-id={`${debugId}-close`} onClick={onClose} className="rounded-md p-1 text-zinc-500 hover:bg-white/10 hover:text-zinc-200"><Icon name="close" size={16} /></button>
        </div>
        <div className="space-y-3">{children}</div>
      </div>
    </div>
  );
}

function Field({ label, children }: { label: string; children: React.ReactNode }) {
  return (
    <label className="block">
      <div className="mb-1 text-[11px] uppercase tracking-wide text-zinc-500">{label}</div>
      {children}
    </label>
  );
}

function Badge({ children }: { children: React.ReactNode }) {
  return <span className="rounded-full border border-white/10 bg-white/5 px-2 py-0.5 text-[11px] text-zinc-300">{children}</span>;
}

function Empty({ text }: { text: string }) {
  return <div data-debug-id="memory-empty" className="rounded-2xl border border-dashed border-white/10 bg-white/[0.02] py-12 text-center text-sm text-zinc-500">{text}</div>;
}
