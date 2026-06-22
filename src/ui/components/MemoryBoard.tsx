import { useEffect, useState, useMemo, memo, FormEvent, useCallback } from 'react';
import { useDispatch, useSelector } from 'react-redux';
import { decideMemoryProposal, fetchMemoryDetail, proposeMemoryChange, refreshMemory, selectMemory, setMemoryFilters } from '../store/memorySlice';

const MEMORY_TYPES = ['fact', 'habit', 'episode', 'expertise', 'skill'];
const MEMORY_STATUSES = ['active', 'pending', 'archived', 'rejected'];

function formatTime(unixMs: number) {
  if (!unixMs) return '—';
  return new Date(unixMs).toLocaleString([], { month: 'short', day: 'numeric', hour: '2-digit', minute: '2-digit' });
}

function statusTone(status: string) {
  if (status === 'active') return 'border-emerald-500/25 bg-emerald-500/10 text-emerald-300';
  if (status === 'pending') return 'border-amber-500/25 bg-amber-500/10 text-amber-200';
  if (status === 'rejected') return 'border-red-500/25 bg-red-500/10 text-red-200';
  return 'border-[var(--fd-hairline)] bg-[var(--fd-surface-1)] text-[#aaa]';
}

function StatusPill({ status }: { status: string }) {
  return <span className={`rounded-full border px-2 py-1 text-[11px] font-medium ${statusTone(status)}`}>{status || 'unknown'}</span>;
}

function Field({ label, value }: { label: string; value: string | number }) {
  return (
    <div className="framer-card p-3">
      <p className="framer-topline text-[10px]">{label}</p>
      <p className="mt-1 break-words text-sm text-white">{String(value || '—')}</p>
    </div>
  );
}

const blankForm = { proposalAction: 'new', memoryId: '', expectedVersion: '', subjectAgent: '', type: 'fact', scope: 'global', title: '', body: '', reason: '', evidence: '', sourceTaskId: '' };

export default function MemoryBoard({ session, agents = [] }: { session: any; agents?: any[] }) {
  const renderStart = performance.now();
  useEffect(() => {
    const duration = performance.now() - renderStart;
    console.log(`[Render Timer] MemoryBoard took ${duration.toFixed(2)}ms`);
  });
  const dispatch = useDispatch<any>();
  const { recordsById, recordIds, selectedMemoryId, historyById, filters, loading, detailLoading, error } = useSelector((state: any) => state.memory);
  const selected = selectedMemoryId ? recordsById[selectedMemoryId] : null;
  const history = selectedMemoryId ? historyById[selectedMemoryId] ?? [] : [];
  const [page, setPage] = useState<'list' | 'detail' | 'propose'>('list');
  const [proposalFormValues, setProposalFormValues] = useState<any>(null);
  const [decisionReason, setDecisionReason] = useState('');
  const [mutationError, setMutationError] = useState('');
  const [mutating, setMutating] = useState(false);
  const canMutate = Boolean(session.clientToken) && session.connected && !mutating;

  useEffect(() => {
    if (session.connected && session.clientToken) dispatch(refreshMemory());
  }, [dispatch, session.connected, session.clientToken, filters.subjectAgent, filters.type, filters.status]);

  useEffect(() => {
    if (selectedMemoryId) dispatch(fetchMemoryDetail(selectedMemoryId));
  }, [dispatch, selectedMemoryId]);

  // Form update helper is deleted because form state is now local to MemoryProposalForm component

  const openDetail = useCallback((memoryId: string) => {
    dispatch(selectMemory(memoryId));
    setPage('detail');
  }, [dispatch]);

  const openProposal = useCallback((action: string, record: any = selected) => {
    setMutationError('');
    setProposalFormValues({
      proposalAction: action,
      memoryId: action === 'new' ? '' : record?.memoryId || '',
      expectedVersion: action === 'new' ? '' : String(record?.version || ''),
      subjectAgent: record?.subjectAgent || '',
      type: record?.type || 'fact',
      scope: record?.scope || 'global',
      title: action === 'archive' || action === 'rollback' ? record?.title || '' : record?.title || '',
      body: action === 'archive' || action === 'rollback' ? '' : record?.body || '',
      sourceTaskId: record?.sourceTaskId || '',
      reason: '',
      evidence: '',
    });
    setPage('propose');
  }, [selected]);

  const runMutation = useCallback(async (callback: () => Promise<any>) => {
    setMutationError('');
    setMutating(true);
    try {
      await callback();
    } catch (error: any) {
      setMutationError(error?.message || 'Memory mutation failed');
    } finally {
      setMutating(false);
    }
  }, []);

  const handlePropose = useCallback((formData: any) => {
    runMutation(async () => {
      const payload: any = {
        proposalAction: formData.proposalAction,
        memory_id: formData.memoryId.trim(),
        expected_version: Number(formData.expectedVersion || selected?.version || 0),
        subject_agent: formData.subjectAgent.trim(),
        scope: formData.scope.trim() || 'global',
        type: formData.type,
        title: formData.title.trim(),
        body: formData.body,
        reason: formData.reason.trim(),
        evidence: formData.evidence.trim(),
        source_task_id: formData.sourceTaskId.trim(),
      };
      if (formData.proposalAction === 'new') {
        delete payload.memory_id;
        delete payload.expected_version;
      }
      await dispatch(proposeMemoryChange(payload)).unwrap();
      setPage('list');
    });
  }, [dispatch, runMutation, selected?.version]);

  const handleCancelProposal = useCallback(() => {
    setPage('list');
  }, []);

  const decide = useCallback((decision: 'approve' | 'reject') => {
    if (!selected?.proposalId || !canMutate) return;
    runMutation(async () => {
      await dispatch(decideMemoryProposal({ proposalId: selected.proposalId, decision, reason: decisionReason.trim() })).unwrap();
      setDecisionReason('');
      await dispatch(fetchMemoryDetail(selected.memoryId));
    });
  }, [dispatch, runMutation, selected?.proposalId, canMutate, decisionReason, selected?.memoryId]);

  const counts = useMemo(() => 
    MEMORY_STATUSES.map((status) => ({ status, count: recordIds.filter((id) => recordsById[id]?.status === status).length })),
    [recordIds, recordsById]
  );

  return (
    <main className="flex min-w-0 flex-1 flex-col bg-[var(--fd-canvas)]">
      <header className="framer-panel flex items-center justify-between border-b border-[var(--fd-hairline)] px-6 py-4">
        <div>
          <p className="framer-topline tracking-[0.28em]">Memory</p>
          <h2 className="mt-1 text-2xl font-bold text-white">Durable memory</h2>
        </div>
        <div className="flex gap-2">
          {page !== 'list' ? <button type="button" data-debug-id="memory-back-btn" onClick={() => setPage('list')} className="framer-pill-secondary">Back</button> : null}
          <button type="button" data-debug-id="memory-refresh-btn" onClick={() => dispatch(refreshMemory())} className="framer-pill-secondary" disabled={loading}>Refresh</button>
          <button type="button" data-debug-id="memory-new-proposal-btn" onClick={() => openProposal('new', null)} className="framer-pill" disabled={!session.clientToken}>+ Proposal</button>
        </div>
      </header>

      <section className="min-h-0 flex-1 overflow-hidden p-6">
        {error ? <div className="mb-4 rounded-2xl border border-red-500/30 bg-red-500/10 p-3 text-sm text-red-200">{error}</div> : null}
        {mutationError ? <div className="mb-4 rounded-2xl border border-red-500/30 bg-red-500/10 p-3 text-sm text-red-200">{mutationError}</div> : null}

        {page === 'list' ? (
          <div className="grid h-full grid-cols-[minmax(300px,0.95fr)_minmax(420px,1.25fr)] gap-5 overflow-hidden">
            <div className="flex flex-col h-full min-h-0 space-y-4">
              <div className="framer-card-xl p-4 shrink-0">
                <div className="grid grid-cols-4 gap-2">
                  {counts.map((item) => <div key={item.status} className="framer-card p-3"><p className="framer-topline text-[10px]">{item.status}</p><p className="mt-1 text-xl font-bold">{item.count}</p></div>)}
                </div>
                <div className="mt-4 grid gap-2">
                  <input data-debug-id="memory-filter-agent" value={filters.subjectAgent} onChange={(event) => dispatch(setMemoryFilters({ subjectAgent: event.target.value }))} placeholder="Filter subject agent" className="framer-input px-3 py-2 text-sm" />
                  <div className="grid grid-cols-2 gap-2">
                    <select data-debug-id="memory-filter-type" value={filters.type} onChange={(event) => dispatch(setMemoryFilters({ type: event.target.value }))} className="framer-input px-3 py-2 text-sm"><option value="">All types</option>{MEMORY_TYPES.map((type) => <option key={type} value={type}>{type}</option>)}</select>
                    <select data-debug-id="memory-filter-status" value={filters.status} onChange={(event) => dispatch(setMemoryFilters({ status: event.target.value }))} className="framer-input px-3 py-2 text-sm"><option value="">All statuses</option>{MEMORY_STATUSES.map((status) => <option key={status} value={status}>{status}</option>)}</select>
                  </div>
                </div>
              </div>
              <div className="flex-1 overflow-y-auto space-y-2 pr-1 min-h-0">
                {recordIds.map((id) => {
                  const record = recordsById[id];
                  return (
                    <button key={id} type="button" data-debug-id={`memory-record-${id}`} onClick={() => openDetail(id)} className={`framer-card w-full p-4 text-left transition hover:-translate-y-0.5 ${selectedMemoryId === id ? 'border-[var(--fd-accent-blue)]' : ''}`}>
                      <div className="flex items-start justify-between gap-3"><div><p className="font-semibold text-white">{record.title || record.memoryId}</p><p className="mt-1 text-xs text-[#999]">{record.subjectAgent || 'global'} · {record.type} · v{record.version}</p></div><StatusPill status={record.status} /></div>
                      <p className="mt-2 line-clamp-2 text-sm text-[#bdbdbd]">{record.body || record.reason || 'No body'}</p>
                    </button>
                  );
                })}
                {!recordIds.length ? <div className="framer-card border-dashed p-5 text-sm text-[#999]">No memory records match the filters.</div> : null}
              </div>
            </div>
            <div className="h-full min-h-0 overflow-hidden">
              <MemoryDetail selected={selected} history={history} detailLoading={detailLoading} decisionReason={decisionReason} setDecisionReason={setDecisionReason} openProposal={openProposal} decide={decide} canMutate={canMutate} />
            </div>
          </div>
        ) : page === 'detail' ? (
          <MemoryDetail selected={selected} history={history} detailLoading={detailLoading} decisionReason={decisionReason} setDecisionReason={setDecisionReason} openProposal={openProposal} decide={decide} canMutate={canMutate} />
        ) : (
          <MemoryProposalForm
            initialForm={proposalFormValues}
            agents={agents}
            canMutate={canMutate}
            mutating={mutating}
            onSubmit={handlePropose}
            onCancel={handleCancelProposal}
          />
        )}
      </section>
    </main>
  );
}

function MemoryDetail({ selected, history, detailLoading, decisionReason, setDecisionReason, openProposal, decide, canMutate }) {
  if (!selected) return <div className="framer-card-xl p-5 text-sm text-[#999]">Select a memory record to view details and history.</div>;
  const metadata = (() => { try { return JSON.stringify(JSON.parse(selected.metadataJson || '{}'), null, 2); } catch { return selected.metadataJson || ''; } })();
  return (
    <div className="framer-card-xl h-full overflow-y-auto p-5">
      <div className="flex items-start justify-between gap-4"><div><p className="framer-topline">{selected.memoryId}</p><h3 className="mt-1 text-2xl font-bold text-white">{selected.title || 'Untitled memory'}</h3><p className="mt-2 text-sm text-[#999]">{selected.subjectAgent || 'global'} · {selected.type} · {selected.scope}</p></div><StatusPill status={selected.status} /></div>
      <div className="mt-5 grid grid-cols-2 gap-3"><Field label="Version" value={selected.version} /><Field label="Proposal" value={selected.proposalId} /><Field label="Source task" value={selected.sourceTaskId} /><Field label="Updated" value={formatTime(selected.updatedUnixMs || selected.createdUnixMs)} /></div>
      <div className="mt-5 grid gap-4 lg:grid-cols-2"><section className="framer-card p-4"><p className="framer-topline">Body</p><pre className="mt-3 whitespace-pre-wrap break-words text-sm leading-6 text-[#ddd]">{selected.body || '—'}</pre></section><section className="framer-card p-4"><p className="framer-topline">Review metadata</p><p className="mt-3 text-sm text-[#aaa]">Reason</p><pre className="mt-1 whitespace-pre-wrap break-words text-sm text-[#ddd]">{selected.reason || '—'}</pre><p className="mt-3 text-sm text-[#aaa]">Evidence</p><pre className="mt-1 whitespace-pre-wrap break-words text-sm text-[#ddd]">{selected.evidence || '—'}</pre>{metadata ? <><p className="mt-3 text-sm text-[#aaa]">Metadata</p><pre className="mt-1 whitespace-pre-wrap break-words text-xs text-[#bbb]">{metadata}</pre></> : null}</section></div>
      <div className="mt-5 flex flex-wrap gap-2"><button type="button" data-debug-id="memory-propose-edit-btn" onClick={() => openProposal('edit', selected)} className="framer-pill-secondary">Propose edit</button><button type="button" data-debug-id="memory-propose-archive-btn" onClick={() => openProposal('archive', selected)} className="framer-pill-secondary">Propose archive</button><button type="button" data-debug-id="memory-propose-rollback-btn" onClick={() => openProposal('rollback', selected)} className="framer-pill-secondary">Propose rollback</button></div>
      {selected.status === 'pending' && selected.proposalId ? <div className="mt-5 rounded-2xl border border-amber-500/20 bg-amber-500/10 p-4"><p className="font-semibold text-amber-100">Pending proposal decision</p><textarea data-debug-id="memory-decision-reason" value={decisionReason} onChange={(event) => setDecisionReason(event.target.value)} placeholder="optional decision reason" className="framer-input mt-3 min-h-16 w-full px-3 py-2" /><div className="mt-3 flex justify-end gap-2"><button type="button" data-debug-id="memory-reject-btn" onClick={() => decide('reject')} disabled={!canMutate} className="framer-pill-secondary">Reject</button><button type="button" data-debug-id="memory-approve-btn" onClick={() => decide('approve')} disabled={!canMutate} className="framer-pill">Approve</button></div></div> : null}
      <section className="mt-5"><p className="framer-topline">Version / history {detailLoading ? '· loading…' : ''}</p><div className="mt-3 space-y-2">{history.map((event) => <div key={event.eventId || `${event.proposalId}-${event.createdUnixMs}`} className="framer-card p-3"><div className="flex justify-between gap-3 text-sm"><span className="font-medium text-white">{event.proposalId || event.eventId}</span><span className="text-[#999]">{formatTime(event.createdUnixMs)}</span></div><p className="mt-1 text-xs text-[#999]">by {event.author || 'unknown'}</p>{event.reason ? <p className="mt-2 text-sm text-[#ddd]">Reason: {event.reason}</p> : null}{event.evidence ? <p className="mt-1 text-sm text-[#bbb]">Evidence: {event.evidence}</p> : null}</div>)}{!history.length ? <div className="framer-card border-dashed p-4 text-sm text-[#999]">No history loaded.</div> : null}</div></section>
    </div>
  );
}

// --- OPTIMIZED SUB-COMPONENTS FOR FORM STATE ISOLATION ---

interface MemoryProposalFormProps {
  initialForm: any;
  agents: any[];
  canMutate: boolean;
  mutating: boolean;
  onSubmit: (formData: any) => void;
  onCancel: () => void;
}

function MemoryProposalForm({
  initialForm,
  agents,
  canMutate,
  mutating,
  onSubmit,
  onCancel
}: MemoryProposalFormProps) {
  console.log('[Render] MemoryProposalForm');
  const [form, setForm] = useState(initialForm || blankForm);

  function updateForm(patch: any) {
    setForm((current) => ({ ...current, ...patch }));
  }

  const handleSubmit = (e: FormEvent) => {
    e.preventDefault();
    if (!canMutate || !form.reason.trim() || !form.evidence.trim()) return;
    onSubmit(form);
  };

  const isSubmitDisabled = !canMutate || !form.reason.trim() || !form.evidence.trim() || mutating;

  return (
    <form onSubmit={handleSubmit} className="framer-card-xl mx-auto max-w-4xl space-y-4 p-5">
      <div>
        <p className="framer-topline">Proposal</p>
        <h3 className="mt-1 text-xl font-bold capitalize">{form.proposalAction} memory</h3>
        <p className="mt-1 text-sm text-[#999]">
          Reason and evidence are required for review/history and are not part of the runtime memory body.
        </p>
      </div>
      <div className="grid grid-cols-2 gap-3">
        <select data-debug-id="proposal-action-select" value={form.proposalAction} onChange={(event) => updateForm({ proposalAction: event.target.value })} className="framer-input px-3 py-2">
          <option value="new">new</option>
          <option value="edit">edit</option>
          <option value="archive">archive</option>
          <option value="rollback">rollback</option>
        </select>
        <input data-debug-id="proposal-memory-id" value={form.memoryId} onChange={(event) => updateForm({ memoryId: event.target.value })} placeholder="memory_id for edit/archive/rollback" className="framer-input px-3 py-2" disabled={form.proposalAction === 'new'} />
        <input data-debug-id="proposal-expected-version" value={form.expectedVersion} onChange={(event) => updateForm({ expectedVersion: event.target.value })} placeholder="expected version" className="framer-input px-3 py-2" disabled={form.proposalAction === 'new'} />
        <select data-debug-id="proposal-subject-agent-select" value={form.subjectAgent} onChange={(event) => updateForm({ subjectAgent: event.target.value })} className="framer-input px-3 py-2" disabled={form.proposalAction !== 'new'}>
          <option value="">— select agent —</option>
          {agents.map((a: any) => <option key={a.id} value={a.id}>{a.label || a.id}</option>)}
        </select>
        <select data-debug-id="proposal-type-select" value={form.type} onChange={(event) => updateForm({ type: event.target.value })} className="framer-input px-3 py-2" disabled={form.proposalAction === 'archive'}>
          {MEMORY_TYPES.map((type) => <option key={type} value={type}>{type}</option>)}
        </select>
        <input data-debug-id="proposal-scope" value={form.scope} onChange={(event) => updateForm({ scope: event.target.value })} placeholder="scope" className="framer-input px-3 py-2" />
        <input data-debug-id="proposal-title" value={form.title} onChange={(event) => updateForm({ title: event.target.value })} placeholder="title" className="framer-input px-3 py-2" disabled={form.proposalAction === 'archive' || form.proposalAction === 'rollback'} />
        <input data-debug-id="proposal-source-task-id" value={form.sourceTaskId} onChange={(event) => updateForm({ sourceTaskId: event.target.value })} placeholder="source task id" className="framer-input px-3 py-2" />
      </div>
      <textarea data-debug-id="proposal-body" value={form.body} onChange={(event) => updateForm({ body: event.target.value })} placeholder="memory body" className="framer-input min-h-36 w-full px-3 py-2" disabled={form.proposalAction === 'archive' || form.proposalAction === 'rollback'} />
      <textarea data-debug-id="proposal-reason" value={form.reason} onChange={(event) => updateForm({ reason: event.target.value })} placeholder="required reason" className="framer-input min-h-20 w-full px-3 py-2" required />
      <textarea data-debug-id="proposal-evidence" value={form.evidence} onChange={(event) => updateForm({ evidence: event.target.value })} placeholder="required evidence" className="framer-input min-h-20 w-full px-3 py-2" required />
      <div className="flex justify-end gap-2">
        <button type="button" data-debug-id="proposal-cancel-btn" onClick={onCancel} className="framer-pill-secondary">Cancel</button>
        <button type="submit" data-debug-id="proposal-submit-btn" className="framer-pill" disabled={isSubmitDisabled}>
          {mutating ? 'Submitting…' : 'Submit proposal'}
        </button>
      </div>
    </form>
  );
}
