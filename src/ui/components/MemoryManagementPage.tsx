import { useEffect, useMemo, useState } from 'react';
import { useDispatch, useSelector } from 'react-redux';
import Markdown from './Markdown';
import {
  decideMemoryProposal,
  fetchMemoryDetail,
  proposeMemoryChange,
  refreshMemory,
  resetMemoryFilters,
  selectFilteredMemoryRecords,
  selectMemoryFilters,
  selectMemoryRecords,
  selectPendingMemoryRecords,
  setMemoryFilters,
} from '../store/memorySlice';

type Props = {
  selectedMemoryId: string;
  onSelectMemory: (memoryId: string) => void;
  onBackToHome: () => void;
};

type FormMode = 'new' | 'edit' | 'archive' | 'rollback';

function formatUnix(ms: number) {
  if (!ms) return '—';
  try {
    return new Date(ms).toLocaleString();
  } catch (_err) {
    return String(ms);
  }
}

function csvText(value: any) {
  if (Array.isArray(value)) return value.join(', ');
  return String(value || '');
}

function metadataText(value: string) {
  if (!value) return '—';
  try {
    return JSON.stringify(JSON.parse(value), null, 2);
  } catch (_err) {
    return value;
  }
}

function normalizeProposalState(record: any) {
  if (!record) return '—';
  if (record.proposalId && record.status === 'pending') return 'Pending proposal';
  if (record.proposalId) return `${record.status || 'unknown'} proposal`;
  return record.status || '—';
}

function optionValues(records: any[], key: 'scope' | 'type' | 'status') {
  return Array.from(new Set(records.map((record: any) => String(record?.[key] || '').trim()).filter(Boolean))).sort();
}

function compactList(values: string[]) {
  if (!values?.length) return '—';
  return values.join(', ');
}

export default function MemoryManagementPage({ selectedMemoryId, onSelectMemory, onBackToHome }: Props) {
  const dispatch = useDispatch<any>();
  const session = useSelector((state: any) => state.chat.session);
  const filters = useSelector(selectMemoryFilters);
  const allRecords = useSelector(selectMemoryRecords);
  const filteredRecords = useSelector(selectFilteredMemoryRecords);
  const pendingRecords = useSelector(selectPendingMemoryRecords);
  const memory = useSelector((state: any) => state.memory);
  const [formMode, setFormMode] = useState<FormMode>('new');
  const [submitMessage, setSubmitMessage] = useState('');
  const [submitError, setSubmitError] = useState('');
  const [reviewState, setReviewState] = useState<Record<string, { reason: string; loading?: boolean; error?: string }>>({});
  const [form, setForm] = useState({
    agentInstanceId: '',
    scope: 'team_project',
    templateKey: '',
    projectIds: '',
    roleKeys: '',
    taskChainTypes: '',
    type: 'fact',
    title: '',
    body: '',
    metadataJson: '',
    sourceTaskId: '',
    reason: '',
    evidence: '',
  });

  useEffect(() => {
    if (!session?.clientToken) return;
    dispatch(refreshMemory()).catch(() => undefined);
  }, [dispatch, session?.clientToken]);

  useEffect(() => {
    if (!selectedMemoryId || !session?.clientToken) return;
    dispatch(fetchMemoryDetail(selectedMemoryId)).catch(() => undefined);
  }, [dispatch, selectedMemoryId, session?.clientToken]);

  useEffect(() => {
    if (selectedMemoryId && memory.recordsById?.[selectedMemoryId]) return;
    const next = filteredRecords[0]?.memoryId || allRecords[0]?.memoryId || '';
    if (next && next !== selectedMemoryId) onSelectMemory(next);
  }, [allRecords, filteredRecords, memory.recordsById, onSelectMemory, selectedMemoryId]);

  const selectedRecord = selectedMemoryId ? memory.recordsById?.[selectedMemoryId] || allRecords.find((record: any) => record.memoryId === selectedMemoryId) : null;
  const history = selectedRecord ? (memory.historyById?.[selectedRecord.memoryId] || []) : [];
  const scopeOptions = useMemo(() => optionValues(allRecords, 'scope'), [allRecords]);
  const typeOptions = useMemo(() => optionValues(allRecords, 'type'), [allRecords]);
  const statusOptions = useMemo(() => optionValues(allRecords, 'status'), [allRecords]);

  useEffect(() => {
    if (formMode === 'new') {
      setForm({
        agentInstanceId: '',
        scope: 'team_project',
        templateKey: '',
        projectIds: '',
        roleKeys: '',
        taskChainTypes: '',
        type: 'fact',
        title: '',
        body: '',
        metadataJson: '',
        sourceTaskId: '',
        reason: '',
        evidence: '',
      });
      return;
    }
    if (!selectedRecord) return;
    setForm({
      agentInstanceId: selectedRecord.agentInstanceId || '',
      scope: selectedRecord.scope || 'team_project',
      templateKey: selectedRecord.templateKey || '',
      projectIds: csvText(selectedRecord.projectIds || []),
      roleKeys: csvText(selectedRecord.roleKeys || []),
      taskChainTypes: csvText(selectedRecord.taskChainTypes || []),
      type: selectedRecord.type || 'fact',
      title: selectedRecord.title || '',
      body: selectedRecord.body || '',
      metadataJson: selectedRecord.metadataJson || '',
      sourceTaskId: selectedRecord.sourceTaskId || '',
      reason: '',
      evidence: '',
    });
  }, [formMode, selectedRecord]);

  const handleFilterChange = (patch: Record<string, any>) => {
    dispatch(setMemoryFilters(patch));
  };

  const handleSubmit = async (event: any) => {
    event.preventDefault();
    setSubmitMessage('');
    setSubmitError('');
    try {
      if (formMode === 'new') {
        const result = await dispatch(proposeMemoryChange({
          proposalAction: 'new',
          agentInstanceId: form.agentInstanceId,
          scope: form.scope,
          templateKey: form.templateKey,
          projectIds: form.projectIds,
          roleKeys: form.roleKeys,
          taskChainTypes: form.taskChainTypes,
          type: form.type,
          title: form.title,
          body: form.body,
          metadataJson: form.metadataJson,
          sourceTaskId: form.sourceTaskId,
          reason: form.reason,
          evidence: form.evidence,
        })).unwrap();
        if (result?.memory_id) onSelectMemory(result.memory_id);
        if (result?.memory_id) await dispatch(fetchMemoryDetail(result.memory_id)).catch(() => undefined);
        setSubmitMessage(`Submitted new memory proposal${result?.proposal_id ? ` (${result.proposal_id})` : ''}.`);
      } else {
        if (!selectedRecord?.memoryId) throw new Error('Select a memory record first.');
        if (formMode === 'edit') {
          const result = await dispatch(proposeMemoryChange({
            proposalAction: 'edit',
            memoryId: selectedRecord.memoryId,
            expectedVersion: selectedRecord.version,
            agentInstanceId: form.agentInstanceId,
            scope: form.scope,
            templateKey: form.templateKey,
            projectIds: form.projectIds,
            roleKeys: form.roleKeys,
            taskChainTypes: form.taskChainTypes,
            type: form.type,
            title: form.title,
            body: form.body,
            metadataJson: form.metadataJson,
            sourceTaskId: form.sourceTaskId,
            reason: form.reason,
            evidence: form.evidence,
          })).unwrap();
          await dispatch(fetchMemoryDetail(selectedRecord.memoryId)).catch(() => undefined);
          setSubmitMessage(`Submitted edit proposal for ${selectedRecord.memoryId}${result?.proposal_id ? ` (${result.proposal_id})` : ''}.`);
        } else if (formMode === 'archive') {
          const result = await dispatch(proposeMemoryChange({
            proposalAction: 'archive',
            memoryId: selectedRecord.memoryId,
            expectedVersion: selectedRecord.version,
            reason: form.reason,
            evidence: form.evidence,
          })).unwrap();
          await dispatch(fetchMemoryDetail(selectedRecord.memoryId)).catch(() => undefined);
          setSubmitMessage(`Submitted archive proposal for ${selectedRecord.memoryId}${result?.proposal_id ? ` (${result.proposal_id})` : ''}.`);
        } else if (formMode === 'rollback') {
          const result = await dispatch(proposeMemoryChange({
            proposalAction: 'rollback',
            memoryId: selectedRecord.memoryId,
            expectedVersion: selectedRecord.version,
            reason: form.reason,
            evidence: form.evidence,
          })).unwrap();
          await dispatch(fetchMemoryDetail(selectedRecord.memoryId)).catch(() => undefined);
          setSubmitMessage(`Submitted rollback proposal for ${selectedRecord.memoryId}${result?.proposal_id ? ` (${result.proposal_id})` : ''}.`);
        }
      }
    } catch (err: any) {
      setSubmitError(err?.message || 'Memory request failed.');
    }
  };

  const handleDecision = async (record: any, decision: 'approve' | 'reject') => {
    if (!record?.proposalId) return;
    setReviewState((current) => ({
      ...current,
      [record.proposalId]: {
        reason: current[record.proposalId]?.reason || '',
        loading: true,
        error: '',
      },
    }));
    try {
      await dispatch(decideMemoryProposal({
        proposalId: record.proposalId,
        decision,
        reason: reviewState[record.proposalId]?.reason || '',
      })).unwrap();
      if (record.memoryId) await dispatch(fetchMemoryDetail(record.memoryId)).catch(() => undefined);
      setReviewState((current) => ({
        ...current,
        [record.proposalId]: {
          reason: current[record.proposalId]?.reason || '',
          loading: false,
          error: '',
        },
      }));
    } catch (err: any) {
      setReviewState((current) => ({
        ...current,
        [record.proposalId]: {
          reason: current[record.proposalId]?.reason || '',
          loading: false,
          error: err?.message || 'Decision failed.',
        },
      }));
    }
  };

  return (
    <main data-debug-id="memory-management-surface" className="mx-auto flex h-full max-w-[1600px] flex-col px-6 py-6">
      <div className="flex flex-wrap items-start justify-between gap-3">
        <div>
          <div className="text-xs uppercase tracking-[0.24em] text-zinc-500">Memory Management</div>
          <h1 className="mt-2 text-4xl font-semibold text-zinc-100">First-class memory browser and proposal workflow</h1>
          <p className="mt-2 max-w-4xl text-sm text-zinc-400">Browse memory records, inspect history, create proposals, submit safe edits/archives with expected versions, and review pending proposals without dropping into Settings or direct daemon commands.</p>
        </div>
        <div className="flex flex-wrap gap-2">
          <button data-debug-id="memory-management-home-btn" onClick={onBackToHome} className="rounded-xl bg-white/10 px-4 py-2 text-sm hover:bg-white/15">Back to Home</button>
          <button data-debug-id="memory-refresh-btn" onClick={() => dispatch(refreshMemory())} className="rounded-xl bg-sky-400 px-4 py-2 text-sm font-semibold text-black hover:bg-sky-300">Refresh</button>
        </div>
      </div>

      <div className="mt-5 grid gap-3 md:grid-cols-4">
        <MetricCard debugId="memory-metric-total" label="Loaded records" value={String(allRecords.length)} />
        <MetricCard debugId="memory-metric-filtered" label="Filtered records" value={String(filteredRecords.length)} />
        <MetricCard debugId="memory-metric-pending" label="Pending proposals" value={String(pendingRecords.length)} />
        <MetricCard debugId="memory-metric-selected" label="Selected version" value={selectedRecord ? String(selectedRecord.version || 0) : '—'} />
      </div>

      <div className="mt-5 grid gap-4 xl:grid-cols-[minmax(0,1.55fr)_minmax(360px,0.95fr)]">
        <section className="min-w-0 space-y-4">
          <Card>
            <div className="flex items-center justify-between gap-3">
              <div>
                <div className="text-lg font-semibold text-zinc-100">Filters and search</div>
                <div className="mt-1 text-sm text-zinc-500">Filter by canonical target, lifecycle status, and free text across titles/body/metadata.</div>
              </div>
              <button data-debug-id="memory-filters-reset-btn" onClick={() => dispatch(resetMemoryFilters())} className="rounded-xl bg-white/10 px-3 py-2 text-sm hover:bg-white/15">Reset</button>
            </div>
            <div data-debug-id="memory-filters" className="mt-4 grid gap-3 md:grid-cols-2 xl:grid-cols-3">
              <FilterInput debugId="memory-filter-target-input" label="Target" value={filters.search || ''} onChange={(value) => handleFilterChange({ search: value })} placeholder="target, memory id, proposal id…" />
              <FilterInput debugId="memory-filter-template-key-input" label="Template key" value={filters.templateKey || ''} onChange={(value) => handleFilterChange({ templateKey: value })} placeholder="template key" />
              <FilterInput debugId="memory-filter-project-input" label="Project target" value={filters.projectId || ''} onChange={(value) => handleFilterChange({ projectId: value })} placeholder="heimdall-agent-manager" />
              <FilterInput debugId="memory-filter-role-input" label="Role target" value={filters.roleKey || ''} onChange={(value) => handleFilterChange({ roleKey: value })} placeholder="coder, reviewer" />
              <FilterInput debugId="memory-filter-task-chain-type-input" label="Task-chain type target" value={filters.taskChainType || ''} onChange={(value) => handleFilterChange({ taskChainType: value })} placeholder="feature, bugfix" />
              <FilterInput debugId="memory-filter-search-input" label="Free text" value={filters.search || ''} onChange={(value) => handleFilterChange({ search: value })} placeholder="title, body, evidence, metadata…" />
              <FilterSelect debugId="memory-filter-scope-select" label="Scope" value={filters.scope || ''} onChange={(value) => handleFilterChange({ scope: value })} options={scopeOptions} />
              <FilterSelect debugId="memory-filter-type-select" label="Type" value={filters.type || ''} onChange={(value) => handleFilterChange({ type: value })} options={typeOptions} />
              <FilterSelect debugId="memory-filter-status-select" label="Status" value={filters.status || ''} onChange={(value) => handleFilterChange({ status: value })} options={statusOptions} />
              <FilterSelect debugId="memory-filter-targeting-select" label="Targeting" value={filters.targeting || 'all'} onChange={(value) => handleFilterChange({ targeting: value })} options={['all', 'targeted', 'untargeted']} includeAny={false} />
              <label className="flex items-end gap-3 rounded-2xl border border-white/10 bg-black/20 px-4 py-3 text-sm text-zinc-200">
                <input data-debug-id="memory-filter-pending-active-checkbox" type="checkbox" checked={Boolean(filters.pendingActiveOnly)} onChange={(event) => handleFilterChange({ pendingActiveOnly: event.target.checked })} className="h-4 w-4" />
                <span>Pending + active only</span>
              </label>
            </div>
          </Card>

          <Card>
            <div className="flex items-center justify-between gap-3">
              <div>
                <div className="text-lg font-semibold text-zinc-100">Memory browser</div>
                <div className="mt-1 text-sm text-zinc-500">Title, targeting, status, scope, proposal state, version, and timestamps are visible directly in the list.</div>
              </div>
              <div data-debug-id="memory-browser-count" className="rounded-full bg-white/10 px-3 py-1 text-xs text-zinc-300">{filteredRecords.length} shown</div>
            </div>
            <div className="mt-4 space-y-3">
              {memory.loading && <Empty text="Loading memory records…" />}
              {!memory.loading && filteredRecords.length === 0 && <Empty text="No memory records match the current filters." />}
              {!memory.loading && filteredRecords.map((record: any) => {
                const active = record.memoryId === selectedRecord?.memoryId;
                return (
                  <button
                    key={record.memoryId}
                    data-debug-id={`memory-row-${record.memoryId}`}
                    onClick={() => onSelectMemory(record.memoryId)}
                    className={`w-full rounded-2xl border p-4 text-left transition ${active ? 'border-sky-400/40 bg-sky-400/10' : 'border-white/10 bg-white/[0.03] hover:bg-white/[0.06]'}`}
                  >
                    <div className="flex flex-wrap items-start justify-between gap-3">
                      <div className="min-w-0 flex-1">
                        <div className="flex flex-wrap items-center gap-2">
                          <span className="truncate text-base font-semibold text-zinc-100">{record.title || record.memoryId}</span>
                          <Badge>{record.type || 'type'}</Badge>
                          <Badge>{record.status || 'status'}</Badge>
                          <Badge>{record.scope || 'scope'}</Badge>
                          <Badge>{normalizeProposalState(record)}</Badge>
                        </div>
                        <div className="mt-2 grid gap-1 text-xs text-zinc-400 md:grid-cols-2 xl:grid-cols-3">
                          <div><span className="text-zinc-500">Target:</span> {record.target || '—'}</div>
                          <div><span className="text-zinc-500">template_key:</span> {record.templateKey || '—'}</div>
                          <div><span className="text-zinc-500">Version:</span> {record.version ?? 0}</div>
                          <div><span className="text-zinc-500">project_ids:</span> {compactList(record.projectIds || [])}</div>
                          <div><span className="text-zinc-500">role_keys:</span> {compactList(record.roleKeys || [])}</div>
                          <div><span className="text-zinc-500">task_chain_types:</span> {compactList(record.taskChainTypes || [])}</div>
                        </div>
                      </div>
                      <div className="text-right text-xs text-zinc-500">
                        <div>Updated</div>
                        <div>{formatUnix(record.updatedUnixMs || record.createdUnixMs)}</div>
                        <div className="mt-1 font-mono">{record.memoryId}</div>
                      </div>
                    </div>
                  </button>
                );
              })}
            </div>
          </Card>
        </section>

        <section className="min-w-0 space-y-4">
          <Card>
            <div className="flex items-center justify-between gap-3">
              <div>
                <div className="text-lg font-semibold text-zinc-100">Inspect memory record</div>
                <div className="mt-1 text-sm text-zinc-500">Rendered body, raw metadata JSON, reason/evidence/source task, versioning, and history.</div>
              </div>
              <div data-debug-id="memory-selected-id" className="text-xs font-mono text-zinc-500">{selectedRecord?.memoryId || 'No selection'}</div>
            </div>
            {!selectedRecord ? (
              <div className="mt-4"><Empty text="Select a memory record to inspect it." /></div>
            ) : (
              <div data-debug-id="memory-detail-panel" className="mt-4 space-y-4">
                <div className="grid gap-3 md:grid-cols-2">
                  <DetailStat label="Title" value={selectedRecord.title || '—'} />
                  <DetailStat label="Proposal state" value={normalizeProposalState(selectedRecord)} />
                  <DetailStat label="Type" value={selectedRecord.type || '—'} />
                  <DetailStat label="Status" value={selectedRecord.status || '—'} />
                  <DetailStat label="Agent instance" value={selectedRecord.agentInstanceId || '—'} />
                  <DetailStat label="Scope" value={selectedRecord.scope || '—'} />
                  <DetailStat label="template_key" value={selectedRecord.templateKey || '—'} />
                  <DetailStat label="Version" value={String(selectedRecord.version || 0)} />
                  <DetailStat label="project_ids" value={compactList(selectedRecord.projectIds || [])} />
                  <DetailStat label="role_keys" value={compactList(selectedRecord.roleKeys || [])} />
                  <DetailStat label="task_chain_types" value={compactList(selectedRecord.taskChainTypes || [])} />
                  <DetailStat label="Updated" value={formatUnix(selectedRecord.updatedUnixMs || selectedRecord.createdUnixMs)} />
                  <DetailStat label="Created" value={formatUnix(selectedRecord.createdUnixMs)} />
                  <DetailStat label="source_task_id" value={selectedRecord.sourceTaskId || '—'} />
                </div>

                <div>
                  <div className="mb-2 text-sm font-semibold text-zinc-100">Body</div>
                  <div data-debug-id="memory-detail-body" className="rounded-2xl border border-white/10 bg-black/20 p-4">
                    {selectedRecord.body ? <Markdown source={selectedRecord.body} className="text-sm text-zinc-200" /> : <div className="text-sm text-zinc-500">No body.</div>}
                  </div>
                </div>

                <div className="grid gap-3 md:grid-cols-2">
                  <TextBlock debugId="memory-detail-reason" label="Reason" value={selectedRecord.reason || '—'} />
                  <TextBlock debugId="memory-detail-evidence" label="Evidence" value={selectedRecord.evidence || '—'} />
                </div>

                <TextBlock debugId="memory-detail-metadata" label="metadata_json" value={metadataText(selectedRecord.metadataJson || '')} mono />

                <div>
                  <div className="mb-2 flex items-center justify-between gap-2">
                    <div className="text-sm font-semibold text-zinc-100">History events</div>
                    <button data-debug-id="memory-detail-refresh-btn" onClick={() => dispatch(fetchMemoryDetail(selectedRecord.memoryId))} className="rounded-xl bg-white/10 px-3 py-1.5 text-xs hover:bg-white/15">Refresh detail</button>
                  </div>
                  <div data-debug-id="memory-history-list" className="space-y-2">
                    {memory.detailLoading && <div className="text-sm text-zinc-500">Loading detail…</div>}
                    {!memory.detailLoading && history.length === 0 && <Empty text="No history events loaded for this record." />}
                    {!memory.detailLoading && history.map((event: any) => (
                      <div key={event.eventId || `${event.memoryId}-${event.createdUnixMs}`} className="rounded-2xl border border-white/10 bg-black/20 p-3 text-sm text-zinc-300">
                        <div className="flex flex-wrap items-center justify-between gap-2">
                          <div className="font-mono text-xs text-zinc-500">{event.eventId || 'event'}</div>
                          <div className="text-xs text-zinc-500">{formatUnix(event.createdUnixMs)}</div>
                        </div>
                        <div className="mt-2 text-xs text-zinc-400">Proposal: {event.proposalId || '—'} · Author: {event.author || '—'}</div>
                        <div className="mt-2 grid gap-1 text-xs text-zinc-500">
                          <div>template_key: {event.templateKey || '—'}</div>
                          <div>project_ids: {compactList(event.projectIds || [])}</div>
                          <div>role_keys: {compactList(event.roleKeys || [])}</div>
                          <div>task_chain_types: {compactList(event.taskChainTypes || [])}</div>
                        </div>
                        {(event.reason || event.evidence) && (
                          <div className="mt-2 rounded-xl bg-black/30 p-2 text-xs text-zinc-300">
                            <div><span className="text-zinc-500">Reason:</span> {event.reason || '—'}</div>
                            <div className="mt-1"><span className="text-zinc-500">Evidence:</span> {event.evidence || '—'}</div>
                          </div>
                        )}
                      </div>
                    ))}
                  </div>
                </div>
              </div>
            )}
          </Card>

          <Card>
            <div className="flex flex-wrap items-center justify-between gap-3">
              <div>
                <div className="text-lg font-semibold text-zinc-100">Create / edit / archive lifecycle</div>
                <div className="mt-1 text-sm text-zinc-500">All mutations submit proposals through existing APIs. Edit/archive/rollback use the selected record version as expected_version.</div>
              </div>
              <div className="flex flex-wrap gap-2">
                {(['new', 'edit', 'archive', 'rollback'] as FormMode[]).map((mode) => (
                  <button
                    key={mode}
                    data-debug-id={`memory-form-mode-${mode}-btn`}
                    onClick={() => { setFormMode(mode); setSubmitMessage(''); setSubmitError(''); }}
                    className={`rounded-xl px-3 py-2 text-sm ${formMode === mode ? 'bg-white text-black' : 'bg-white/10 text-zinc-200 hover:bg-white/15'}`}
                  >{mode}</button>
                ))}
              </div>
            </div>
            <form data-debug-id="memory-proposal-form" onSubmit={handleSubmit} className="mt-4 space-y-3">
              {formMode !== 'archive' && formMode !== 'rollback' && (
                <>
                  <div className="grid gap-3 md:grid-cols-2">
                    <FilterInput debugId="memory-form-title-input" label="Title" value={form.title} onChange={(value) => setForm((current) => ({ ...current, title: value }))} placeholder="Memory title" />
                    <label className="block text-sm text-zinc-300">
                      <div className="mb-1 text-xs uppercase tracking-wide text-zinc-500">Type</div>
                      <select data-debug-id="memory-form-type-select" value={form.type} onChange={(event) => setForm((current) => ({ ...current, type: event.target.value }))} className="w-full rounded-xl border border-white/10 bg-black/30 px-3 py-2 text-sm outline-none focus:border-sky-400">
                        {['fact', 'habit', 'episode', 'expertise', 'skill', 'template'].map((type) => <option key={type} value={type}>{type}</option>)}
                      </select>
                    </label>
                  </div>

                  <div className="grid gap-3 md:grid-cols-2">
                    <FilterInput debugId="memory-form-agent-instance-input" label="Agent instance" value={form.agentInstanceId} onChange={(value) => setForm((current) => ({ ...current, agentInstanceId: value }))} placeholder="agent instance id" />
                    <FilterInput debugId="memory-form-scope-input" label="Scope" value={form.scope} onChange={(value) => setForm((current) => ({ ...current, scope: value }))} placeholder="team_project, project, personal…" />
                    <FilterInput debugId="memory-form-template-key-input" label="template_key" value={form.templateKey} onChange={(value) => setForm((current) => ({ ...current, templateKey: value }))} placeholder="template key" />
                    <FilterInput debugId="memory-form-source-task-input" label="source_task_id" value={form.sourceTaskId} onChange={(value) => setForm((current) => ({ ...current, sourceTaskId: value }))} placeholder="task-..." />
                    <FilterInput debugId="memory-form-project-ids-input" label="project_ids (CSV)" value={form.projectIds} onChange={(value) => setForm((current) => ({ ...current, projectIds: value }))} placeholder="proj-a,proj-b" />
                    <FilterInput debugId="memory-form-role-keys-input" label="role_keys (CSV)" value={form.roleKeys} onChange={(value) => setForm((current) => ({ ...current, roleKeys: value }))} placeholder="coder,reviewer" />
                    <FilterInput debugId="memory-form-task-chain-types-input" label="task_chain_types (CSV)" value={form.taskChainTypes} onChange={(value) => setForm((current) => ({ ...current, taskChainTypes: value }))} placeholder="feature,bugfix" />
                  </div>

                  <TextArea debugId="memory-form-body-textarea" label="Body" value={form.body} onChange={(value) => setForm((current) => ({ ...current, body: value }))} rows={8} placeholder="Memory body markdown" />
                  <TextArea debugId="memory-form-metadata-textarea" label="metadata_json" value={form.metadataJson} onChange={(value) => setForm((current) => ({ ...current, metadataJson: value }))} rows={5} placeholder='{"action":"edit"}' />
                </>
              )}

              {formMode !== 'new' && (
                <div data-debug-id="memory-form-expected-version" className="rounded-2xl border border-amber-400/20 bg-amber-400/10 px-4 py-3 text-sm text-amber-100">
                  Selected record: <span className="font-mono">{selectedRecord?.memoryId || 'none'}</span> · expected_version <span className="font-mono">{selectedRecord?.version ?? '—'}</span>
                </div>
              )}

              <div className="grid gap-3 md:grid-cols-2">
                <TextArea debugId="memory-form-reason-textarea" label="Reason" value={form.reason} onChange={(value) => setForm((current) => ({ ...current, reason: value }))} rows={3} placeholder="Why this proposal should be considered" />
                <TextArea debugId="memory-form-evidence-textarea" label="Evidence" value={form.evidence} onChange={(value) => setForm((current) => ({ ...current, evidence: value }))} rows={3} placeholder="Relevant evidence, links, notes" />
              </div>

              {submitError && <div data-debug-id="memory-form-error" className="rounded-2xl border border-red-400/20 bg-red-500/10 px-4 py-3 text-sm text-red-200">{submitError}</div>}
              {submitMessage && <div data-debug-id="memory-form-success" className="rounded-2xl border border-emerald-400/20 bg-emerald-500/10 px-4 py-3 text-sm text-emerald-200">{submitMessage}</div>}
              {memory.error && <div className="rounded-2xl border border-red-400/20 bg-red-500/10 px-4 py-3 text-sm text-red-200">{memory.error}</div>}

              <button data-debug-id="memory-form-submit-btn" type="submit" className="rounded-xl bg-sky-400 px-4 py-2 text-sm font-semibold text-black hover:bg-sky-300">Submit {formMode} proposal</button>
            </form>
          </Card>

          <Card>
            <div className="flex items-center justify-between gap-3">
              <div>
                <div className="text-lg font-semibold text-zinc-100">Pending proposal review</div>
                <div className="mt-1 text-sm text-zinc-500">Approve or reject pending memory proposals with visible context, targeting, evidence, and version info.</div>
              </div>
              <div data-debug-id="memory-pending-count" className="rounded-full bg-white/10 px-3 py-1 text-xs text-zinc-300">{pendingRecords.length} pending</div>
            </div>
            <div data-debug-id="memory-pending-list" className="mt-4 space-y-3">
              {pendingRecords.length === 0 && <Empty text="No pending memory proposals." />}
              {pendingRecords.map((record: any) => {
                const review = reviewState[record.proposalId] || { reason: '', loading: false, error: '' };
                return (
                  <div key={record.proposalId || record.memoryId} data-debug-id={`memory-pending-row-${record.memoryId}`} className="rounded-2xl border border-white/10 bg-black/20 p-4">
                    <div className="flex flex-wrap items-start justify-between gap-3">
                      <div>
                        <div className="flex flex-wrap items-center gap-2">
                          <div className="font-semibold text-zinc-100">{record.title || record.memoryId}</div>
                          <Badge>{record.type || 'type'}</Badge>
                          <Badge>{record.scope || 'scope'}</Badge>
                          <Badge>v{record.version || 0}</Badge>
                        </div>
                        <div className="mt-2 text-xs text-zinc-400">Proposal {record.proposalId || '—'} · Target {record.target || '—'} · template_key {record.templateKey || '—'}</div>
                        <div className="mt-1 text-xs text-zinc-500">Targets: project_ids {compactList(record.projectIds || [])} · role_keys {compactList(record.roleKeys || [])} · task_chain_types {compactList(record.taskChainTypes || [])}</div>
                      </div>
                      <button data-debug-id={`memory-pending-open-${record.memoryId}`} onClick={() => onSelectMemory(record.memoryId)} className="rounded-xl bg-white/10 px-3 py-2 text-sm hover:bg-white/15">Inspect</button>
                    </div>
                    {record.body && (
                      <div className="mt-3 rounded-xl bg-black/30 p-3 text-sm text-zinc-200">
                        <Markdown source={record.body} compact className="text-sm text-zinc-200" />
                      </div>
                    )}
                    <div className="mt-3 grid gap-3 md:grid-cols-2">
                      <TextBlock debugId={`memory-pending-reason-${record.memoryId}`} label="Reason" value={record.reason || '—'} />
                      <TextBlock debugId={`memory-pending-evidence-${record.memoryId}`} label="Evidence" value={record.evidence || '—'} />
                    </div>
                    <TextArea debugId={`memory-pending-review-reason-${record.memoryId}`} label="Decision reason (optional)" value={review.reason} onChange={(value) => setReviewState((current) => ({ ...current, [record.proposalId]: { ...(current[record.proposalId] || {}), reason: value } }))} rows={2} placeholder="Why approve/reject" />
                    {review.error && <div className="mt-3 rounded-2xl border border-red-400/20 bg-red-500/10 px-4 py-3 text-sm text-red-200">{review.error}</div>}
                    <div className="mt-3 flex flex-wrap gap-2">
                      <button data-debug-id={`memory-pending-approve-${record.memoryId}`} disabled={Boolean(review.loading)} onClick={() => handleDecision(record, 'approve')} className="rounded-xl bg-emerald-400 px-3 py-2 text-sm font-semibold text-black hover:bg-emerald-300 disabled:opacity-50">Approve</button>
                      <button data-debug-id={`memory-pending-reject-${record.memoryId}`} disabled={Boolean(review.loading)} onClick={() => handleDecision(record, 'reject')} className="rounded-xl bg-red-400 px-3 py-2 text-sm font-semibold text-black hover:bg-red-300 disabled:opacity-50">Reject</button>
                    </div>
                  </div>
                );
              })}
            </div>
          </Card>
        </section>
      </div>
    </main>
  );
}

function Card({ children }: any) {
  return <div className="rounded-3xl border border-white/10 bg-white/[0.035] p-5 shadow-2xl shadow-black/10">{children}</div>;
}

function Badge({ children }: any) {
  return <span className="rounded-full border border-white/10 bg-white/5 px-2 py-0.5 text-[11px] text-zinc-300">{children}</span>;
}

function Empty({ text }: { text: string }) {
  return <div className="rounded-2xl border border-dashed border-white/10 p-5 text-sm text-zinc-500">{text}</div>;
}

function MetricCard({ debugId, label, value }: { debugId: string; label: string; value: string }) {
  return (
    <div data-debug-id={debugId} className="rounded-2xl border border-white/10 bg-white/[0.03] px-4 py-3">
      <div className="text-xs uppercase tracking-[0.18em] text-zinc-500">{label}</div>
      <div className="mt-2 text-2xl font-semibold text-zinc-100">{value}</div>
    </div>
  );
}

function FilterInput({ debugId, label, value, onChange, placeholder }: any) {
  return (
    <label className="block text-sm text-zinc-300">
      <div className="mb-1 text-xs uppercase tracking-wide text-zinc-500">{label}</div>
      <input data-debug-id={debugId} value={value} onChange={(event) => onChange(event.target.value)} placeholder={placeholder} className="w-full rounded-xl border border-white/10 bg-black/30 px-3 py-2 text-sm outline-none focus:border-sky-400" />
    </label>
  );
}

function FilterSelect({ debugId, label, value, onChange, options, includeAny = true }: any) {
  return (
    <label className="block text-sm text-zinc-300">
      <div className="mb-1 text-xs uppercase tracking-wide text-zinc-500">{label}</div>
      <select data-debug-id={debugId} value={value} onChange={(event) => onChange(event.target.value)} className="w-full rounded-xl border border-white/10 bg-black/30 px-3 py-2 text-sm outline-none focus:border-sky-400">
        {includeAny && <option value="">Any</option>}
        {(options || []).map((option: string) => <option key={option} value={option}>{option}</option>)}
      </select>
    </label>
  );
}

function TextArea({ debugId, label, value, onChange, rows, placeholder }: any) {
  return (
    <label className="block text-sm text-zinc-300">
      <div className="mb-1 text-xs uppercase tracking-wide text-zinc-500">{label}</div>
      <textarea data-debug-id={debugId} value={value} onChange={(event) => onChange(event.target.value)} rows={rows} placeholder={placeholder} className="w-full resize-y rounded-xl border border-white/10 bg-black/30 px-3 py-2 text-sm outline-none focus:border-sky-400" />
    </label>
  );
}

function DetailStat({ label, value }: { label: string; value: string }) {
  return (
    <div className="rounded-2xl border border-white/10 bg-black/20 p-3">
      <div className="text-[11px] uppercase tracking-[0.18em] text-zinc-500">{label}</div>
      <div className="mt-1 break-words text-sm text-zinc-200">{value}</div>
    </div>
  );
}

function TextBlock({ debugId, label, value, mono = false }: { debugId: string; label: string; value: string; mono?: boolean }) {
  return (
    <div>
      <div className="mb-1 text-xs uppercase tracking-wide text-zinc-500">{label}</div>
      <pre data-debug-id={debugId} className={`overflow-x-auto whitespace-pre-wrap rounded-2xl border border-white/10 bg-black/20 p-3 text-sm text-zinc-200 ${mono ? 'font-mono' : 'font-sans'}`}>{value}</pre>
    </div>
  );
}
