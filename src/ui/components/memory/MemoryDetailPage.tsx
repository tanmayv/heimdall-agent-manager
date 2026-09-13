// MemoryDetailPage — dedicated /memory/:id detail surface.
//
// Read mode renders the full body as Markdown with a scope card (empty dimension
// shows "All"); Edit mode swaps the body to a source textarea (with VimEditButton
// parity) and the scope card to multi-select Combobox controls. Save issues an
// optimistic-version update; Delete archives after a confirm. Layout follows the
// shell's detail routes (breadcrumb + Back) and the two-column card pattern.

import { useEffect, useMemo, useState } from 'react';
import { buildRouteHash, getRouteSearch } from '../../utils/appLocation';

import Markdown from '../Markdown';
import { Badge, Button, Icon, Input, Modal, PageShell, Select, Textarea } from '@ui';
import {
  useGetMemoryQuery,
  useUpdateMemoryMutation,
  useArchiveMemoryMutation,
  memoryErrorText,
} from '../../api/endpoints/memory';
import {
  MEMORY_TYPES,
  ScopeChips,
  ScopeEditor,
  emptyTargeting,
  targetingFromRecord,
  useMemoryScopeCatalog,
  type Targeting,
} from './memoryScope';

function formatUnix(ms?: number): string {
  if (!ms) return '—';
  try { return new Date(ms).toLocaleString(); } catch { return String(ms); }
}

function startsEditing(): boolean {
  const search = getRouteSearch();
  return /(?:^|[?&])edit=1(?:&|$)/.test(search);
}

export default function MemoryDetailPage({ memoryId }: { memoryId: string }) {
  const catalog = useMemoryScopeCatalog();
  const memoryQuery = useGetMemoryQuery({ memoryId }, { skip: !memoryId });
  const record = memoryQuery.data;

  const [editing, setEditing] = useState(startsEditing());
  const [description, setDescription] = useState('');
  const [body, setBody] = useState('');
  const [type, setType] = useState('fact');
  const [targeting, setTargeting] = useState<Targeting>(emptyTargeting());
  const [error, setError] = useState('');
  const [saving, setSaving] = useState(false);
  const [confirmDelete, setConfirmDelete] = useState(false);

  const [updateMemory] = useUpdateMemoryMutation();
  const [archiveMemory] = useArchiveMemoryMutation();

  const recordTargeting = useMemo(() => (record ? targetingFromRecord(record) : emptyTargeting()), [record]);

  // Seed the edit form from the record whenever the identity or edit mode changes.
  // Depending on the whole record would clobber in-progress edits on cache refresh.
  useEffect(() => {
    if (!record) return;
    setDescription(record.description || '');
    setBody(record.body || '');
    setType(record.type || 'fact');
    setTargeting(targetingFromRecord(record));
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [record?.memoryId, editing]);

  function goBack() {
    window.location.hash = buildRouteHash('/memory', '');
  }

  async function save() {
    if (!record) return;
    setSaving(true);
    setError('');
    try {
      await updateMemory({ memoryId: record.memoryId || memoryId, description: description.trim() || undefined, body, type, expectedVersion: record.version, ...targeting }).unwrap();
      setEditing(false);
    } catch (err: any) {
      setError(memoryErrorText(err, 'Failed to save changes.'));
    } finally {
      setSaving(false);
    }
  }

  async function remove() {
    if (!record) return;
    try {
      await archiveMemory({ memoryId: record.memoryId || memoryId }).unwrap();
      goBack();
    } catch (err: any) {
      setError(memoryErrorText(err, 'Failed to delete memory.'));
      setConfirmDelete(false);
    }
  }

  return (
    <PageShell
      width="full"
      eyebrow="Memory"
      title={record?.title || memoryId}
      description={!editing && record?.description ? record.description : undefined}
      loading={memoryQuery.isFetching && !record}
      error={!memoryQuery.isFetching && !record ? 'Memory not found.' : undefined}
      actions={
        <div className="flex items-center gap-2">
          {record ? (
            editing ? (
              <>
                <Button variant="secondary" size="sm" data-debug-id="memory-detail-cancel-btn" onClick={() => { setEditing(false); setError(''); }}>Cancel</Button>
                <Button variant="primary" size="sm" data-debug-id="memory-detail-save-btn" disabled={saving} onClick={save}>{saving ? 'Saving…' : 'Save'}</Button>
              </>
            ) : (
              <>
                <Button variant="secondary" size="sm" data-debug-id="memory-detail-edit-btn" onClick={() => setEditing(true)}><Icon name="pencil" size={13} /> Edit</Button>
                <Button variant="danger" size="sm" data-debug-id="memory-detail-delete-btn" onClick={() => setConfirmDelete(true)}><Icon name="trash" size={13} /> Delete</Button>
              </>
            )
          ) : null}
          <Button variant="secondary" size="sm" data-debug-id="memory-detail-back-btn" onClick={goBack}><Icon name="chevron-left" size={14} /> Back</Button>
        </div>
      }
    >
      {record ? (
        <div data-debug-id="memory-detail-page" className="text-zinc-100">
          {/* Meta chips */}
          <div data-debug-id="memory-detail-header" className="flex flex-wrap items-center gap-2">
            <Badge>{record.type || 'fact'}</Badge>
            <span className="rounded-full border border-white/10 bg-white/5 px-2 py-0.5 text-[11px] text-zinc-300">{record.status || 'active'}</span>
            <span className="text-[11px] text-zinc-600">v{record.version || 0}</span>
          </div>

          {error ? <div className="mt-3 rounded-lg border border-red-400/25 bg-red-500/10 px-3 py-2 text-sm text-red-200">{error}</div> : null}

          <div className="mt-4 grid gap-4 lg:grid-cols-[minmax(0,1.6fr)_minmax(300px,1fr)]">
            {/* Main: body */}
            <div className="min-w-0 rounded-2xl border border-white/10 bg-white/[0.03] p-5">
              {editing ? (
                <div className="mb-4">
                  <div className="mb-1 text-sm font-semibold text-zinc-100">Description</div>
                  <Input
                    data-debug-id="memory-detail-description-input"
                    value={description}
                    onChange={setDescription}
                    placeholder="Short summary of this memory"
                    width="full"
                  />
                </div>
              ) : null}
              <div className="mb-2 flex items-center justify-between">
                <div className="text-sm font-semibold text-zinc-100">Body</div>
                {editing ? <span className="text-[11px] text-zinc-500">Markdown</span> : null}
              </div>
              {editing ? (
                <Textarea data-debug-id="memory-detail-body-textarea" value={body} onChange={setBody} rows={16} placeholder="Memory body (Markdown)" width="full" />
              ) : (
                <div data-debug-id="memory-detail-body" className="rounded-xl border border-white/10 bg-black/20 p-4">
                  {record.body ? <Markdown source={record.body} className="text-sm text-zinc-200" /> : <div className="text-sm text-zinc-500">No body.</div>}
                </div>
              )}
            </div>

            {/* Sidebar: details + scope */}
            <div className="space-y-4">
              <div className="rounded-2xl border border-white/10 bg-white/[0.03] p-4">
                <div className="mb-2 text-sm font-semibold text-zinc-100">Details</div>
                <dl className="space-y-2 text-[12.5px]">
                  <DetailRow label="ID" value={<span className="font-mono text-zinc-300">{record.memoryId}</span>} />
                  {editing ? (
                    <div className="flex items-center justify-between gap-3">
                      <dt className="text-zinc-500">Type</dt>
                      <dd>
                        <Select data-debug-id="memory-detail-type" value={type} onChange={setType}>
                          {MEMORY_TYPES.map((t) => <option key={t} value={t}>{t}</option>)}
                        </Select>
                      </dd>
                    </div>
                  ) : (
                    <DetailRow label="Type" value={record.type || 'fact'} />
                  )}
                  <DetailRow label="Status" value={record.status || 'active'} />
                  <DetailRow label="Version" value={String(record.version || 0)} />
                  <DetailRow label="Updated" value={formatUnix(record.updatedUnixMs || record.createdUnixMs)} />
                </dl>
              </div>

              <div className="rounded-2xl border border-white/10 bg-white/[0.03] p-4">
                <div className="mb-2 text-sm font-semibold text-zinc-100">Scope <span className="font-normal text-zinc-500">(empty = all)</span></div>
                {editing ? (
                  <ScopeEditor targeting={targeting} catalog={catalog} onChange={setTargeting} debugId="memory-detail-scope" />
                ) : (
                  <ScopeChips targeting={recordTargeting} catalog={catalog} debugId="memory-detail-scope-chips" />
                )}
              </div>
            </div>
          </div>

          {confirmDelete && record ? (
            <Modal open onOpenChange={(next) => { if (!next) setConfirmDelete(false); }} title="Delete memory" size="sm" data-debug-id="memory-detail-delete-modal">
              <Modal.Body>
                <p className="text-sm text-zinc-300">Delete <span className="font-semibold text-zinc-100">{record.title || record.memoryId}</span>? Agents will stop receiving it.</p>
                <div className="mt-4 flex justify-end gap-2">
                  <Button variant="secondary" size="sm" data-debug-id="memory-detail-delete-cancel" onClick={() => setConfirmDelete(false)}>Cancel</Button>
                  <Button variant="danger" size="sm" data-debug-id="memory-detail-delete-confirm" onClick={remove}>Delete</Button>
                </div>
              </Modal.Body>
            </Modal>
          ) : null}
        </div>
      ) : null}
    </PageShell>
  );
}

function DetailRow({ label, value }: { label: string; value: React.ReactNode }) {
  return (
    <div className="flex items-center justify-between gap-3">
      <dt className="text-zinc-500">{label}</dt>
      <dd className="min-w-0 truncate text-right text-zinc-200">{value}</dd>
    </div>
  );
}
