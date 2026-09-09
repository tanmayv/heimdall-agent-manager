// MemoryDetailPage — dedicated /memory/:id detail surface.
//
// Read mode renders the full body as Markdown with a scope card (empty dimension
// shows "All"); Edit mode swaps the body to a source textarea (with VimEditButton
// parity) and the scope card to SearchableMultiSelect controls. Save issues an
// optimistic-version update; Delete archives after a confirm. Layout follows the
// shell's detail routes (breadcrumb + Back) and the two-column card pattern.

import { useEffect, useMemo, useState } from 'react';
import { buildRouteHash, getRouteSearch } from '../../utils/appLocation';
import Icon from '../Icon';
import Markdown from '../Markdown';
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
    <div data-debug-id="memory-detail-page" className="w-full text-zinc-100">
      {/* Breadcrumb + back */}
      <div className="flex items-center justify-between gap-3">
        <nav data-debug-id="memory-detail-breadcrumb" className="flex items-center gap-2 text-sm text-zinc-400">
          <a data-debug-id="memory-detail-breadcrumb-home" href={buildRouteHash('/memory', '')} className="font-semibold text-zinc-300 hover:text-white">Memory</a>
          <span className="text-zinc-700">/</span>
          <span className="truncate font-semibold text-white">{record?.title || memoryId}</span>
        </nav>
        <button type="button" data-debug-id="memory-detail-back-btn" onClick={goBack} className="inline-flex items-center gap-1.5 rounded-lg border border-white/10 bg-white/[0.04] px-3 py-1.5 text-[12.5px] text-zinc-300 hover:bg-white/10">
          <Icon name="chevron-left" size={14} /> Back
        </button>
      </div>

      {memoryQuery.isFetching && !record ? (
        <div className="mt-8 text-center text-sm text-zinc-500">Loading memory…</div>
      ) : !record ? (
        <div className="mt-8 rounded-2xl border border-dashed border-white/10 bg-white/[0.02] py-12 text-center text-sm text-zinc-500">Memory not found.</div>
      ) : (
        <>
          {/* Header + action bar */}
          <div data-debug-id="memory-detail-header" className="mt-4 flex flex-wrap items-start justify-between gap-3">
            <div className="min-w-0">
              <div className="flex flex-wrap items-center gap-2">
                <Badge>{record.type || 'fact'}</Badge>
                <span className="rounded-full border border-white/10 bg-white/5 px-2 py-0.5 text-[11px] text-zinc-300">{record.status || 'active'}</span>
                <span className="text-[11px] text-zinc-600">v{record.version || 0}</span>
              </div>
              <h1 className="mt-1.5 text-2xl font-semibold tracking-[-0.01em] text-zinc-100">{record.title || record.memoryId}</h1>
              {!editing && record.description ? (
                <p className="mt-1 text-sm text-zinc-400">{record.description}</p>
              ) : null}
            </div>
            <div className="flex items-center gap-2">
              {editing ? (
                <>
                  <button type="button" data-debug-id="memory-detail-cancel-btn" onClick={() => { setEditing(false); setError(''); }} className="rounded-lg border border-white/10 bg-white/[0.04] px-3 py-1.5 text-[12.5px] text-zinc-300 hover:bg-white/10">Cancel</button>
                  <button type="button" data-debug-id="memory-detail-save-btn" disabled={saving} onClick={save} className="rounded-lg bg-sky-400 px-3.5 py-1.5 text-[12.5px] font-semibold text-black hover:bg-sky-300 disabled:opacity-50">{saving ? 'Saving…' : 'Save'}</button>
                </>
              ) : (
                <>
                  <button type="button" data-debug-id="memory-detail-edit-btn" onClick={() => setEditing(true)} className="inline-flex items-center gap-1.5 rounded-lg border border-white/10 bg-white/[0.04] px-3 py-1.5 text-[12.5px] text-zinc-300 hover:bg-white/10"><Icon name="pencil" size={13} /> Edit</button>
                  <button type="button" data-debug-id="memory-detail-delete-btn" onClick={() => setConfirmDelete(true)} className="inline-flex items-center gap-1.5 rounded-lg border border-rose-400/30 bg-rose-500/10 px-3 py-1.5 text-[12.5px] text-rose-200 hover:bg-rose-500/20"><Icon name="trash" size={13} /> Delete</button>
                </>
              )}
            </div>
          </div>

          {error ? <div className="mt-3 rounded-lg border border-red-400/25 bg-red-500/10 px-3 py-2 text-sm text-red-200">{error}</div> : null}

          <div className="mt-4 grid gap-4 lg:grid-cols-[minmax(0,1.6fr)_minmax(300px,1fr)]">
            {/* Main: body */}
            <div className="min-w-0 rounded-2xl border border-white/10 bg-white/[0.03] p-5">
              {editing ? (
                <div className="mb-4">
                  <div className="mb-1 text-sm font-semibold text-zinc-100">Description</div>
                  <input
                    data-debug-id="memory-detail-description-input"
                    value={description}
                    onChange={(e) => setDescription(e.target.value)}
                    placeholder="Short summary of this memory"
                    className="w-full rounded-lg border border-white/10 bg-black/30 px-3 py-2 text-sm text-zinc-100 outline-none focus:border-sky-400"
                  />
                </div>
              ) : null}
              <div className="mb-2 flex items-center justify-between">
                <div className="text-sm font-semibold text-zinc-100">Body</div>
                {editing ? <span className="text-[11px] text-zinc-500">Markdown</span> : null}
              </div>
              {editing ? (
                <textarea data-debug-id="memory-detail-body-textarea" value={body} onChange={(e) => setBody(e.target.value)} rows={16} placeholder="Memory body (Markdown)" className="w-full resize-y rounded-xl border border-white/10 bg-black/30 px-3 py-2 text-sm text-zinc-100 outline-none focus:border-sky-400" />
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
                        <select data-debug-id="memory-detail-type" value={type} onChange={(e) => setType(e.target.value)} className="rounded-lg border border-white/10 bg-black/40 px-2 py-1 text-sm text-zinc-100 outline-none focus:border-sky-400">
                          {MEMORY_TYPES.map((t) => <option key={t} value={t}>{t}</option>)}
                        </select>
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
        </>
      )}

      {confirmDelete && record ? (
        <div data-debug-id="memory-detail-delete-overlay" className="fixed inset-0 z-[60] flex items-start justify-center overflow-y-auto bg-black/60 p-4 sm:p-8" onClick={() => setConfirmDelete(false)}>
          <div data-debug-id="memory-detail-delete-modal" className="w-full max-w-md rounded-2xl border border-white/10 bg-[#0d0f14] p-5 shadow-2xl shadow-black/70" onClick={(e) => e.stopPropagation()}>
            <h2 className="text-lg font-semibold text-zinc-100">Delete memory</h2>
            <p className="mt-2 text-sm text-zinc-300">Delete <span className="font-semibold text-zinc-100">{record.title || record.memoryId}</span>? Agents will stop receiving it.</p>
            <div className="mt-4 flex justify-end gap-2">
              <button type="button" data-debug-id="memory-detail-delete-cancel" onClick={() => setConfirmDelete(false)} className="rounded-lg border border-white/10 bg-white/[0.04] px-3 py-1.5 text-sm text-zinc-300 hover:bg-white/10">Cancel</button>
              <button type="button" data-debug-id="memory-detail-delete-confirm" onClick={remove} className="rounded-lg bg-rose-400 px-4 py-1.5 text-sm font-bold text-black hover:bg-rose-300">Delete</button>
            </div>
          </div>
        </div>
      ) : null}
    </div>
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

function Badge({ children }: { children: React.ReactNode }) {
  return <span className="rounded-full border border-white/10 bg-white/5 px-2 py-0.5 text-[11px] text-zinc-300">{children}</span>;
}
