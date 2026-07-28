import { useMemo, useState } from 'react';
import {
  useListArtifactsQuery,
  useDeleteArtifactMutation,
  useUpdateArtifactMutation,
} from '../api/endpoints/artifacts';
import { useListAgentsQuery } from '../api/endpoints/agents';
import ArtifactUploadButton, { useArtifactUpload } from './ArtifactUpload';
import { ArtifactImagePreview, isArtifactImage } from './ArtifactAttachmentPreview';
import ArtifactViewer from './ArtifactViewer';

export type LibraryPageProps = {
  session: any;
  projects?: Record<string, any> | any[];
  chains?: any[];
  onBack?: () => void;
};

type ArtifactRow = {
  artifact_id?: string;
  artifactId?: string;
  name?: string;
  kind?: string;
  mime?: string;
  ext?: string;
  size_bytes?: number;
  description?: string;
  project_id?: string;
  projectId?: string;
  creator_id?: string;
  creatorId?: string;
  creator_type?: string;
  creatorType?: string;
  origin_kind?: string;
  originKind?: string;
  origin_ref?: string;
  originRef?: string;
  updated_unix_ms?: number;
  created_unix_ms?: number;
};

function artifactId(a: ArtifactRow): string {
  return String(a?.artifact_id || a?.artifactId || '');
}
function projectId(a: ArtifactRow): string {
  return String(a?.project_id || a?.projectId || '');
}
function creatorId(a: ArtifactRow): string {
  return String(a?.creator_id || a?.creatorId || '');
}
function originRef(a: ArtifactRow): string {
  return String(a?.origin_ref || a?.originRef || '');
}
function kindLabel(a: ArtifactRow): string {
  return String(a?.kind || a?.mime || 'artifact');
}

function formatBytes(value: number) {
  if (!Number.isFinite(value) || value <= 0) return '—';
  const units = ['B', 'KB', 'MB', 'GB'];
  let size = value;
  let unit = 0;
  while (size >= 1024 && unit < units.length - 1) {
    size /= 1024;
    unit += 1;
  }
  return `${size >= 10 || unit === 0 ? size.toFixed(0) : size.toFixed(1)} ${units[unit]}`;
}

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

const KIND_ICON: Record<string, string> = {
  markdown: '📝',
  text: '📝',
  json: '{}',
  diff: '±',
  png: '🖼',
  image: '🖼',
  jpeg: '🖼',
  csv: '▦',
  html: '🌍',
  unsupported: '📎',
};

function kindIcon(kind: string): string {
  return KIND_ICON[String(kind || '').toLowerCase()] || '📎';
}

function isImage(a: ArtifactRow): boolean {
  return isArtifactImage(a);
}

// UI-10: Library — a filterable gallery/list of ALL the user's artifacts across
// every conversation/chain/project (global counterpart to the conversation
// inspector's Artifacts tab). Filters: kind, agent, project, chain, search.
// Grid (thumbnails/previews) vs list (dense). Row/card click -> fullscreen
// ArtifactViewer. Upload supported (user-created artifacts).
export default function LibraryPage({ session, projects, chains = [], onBack }: LibraryPageProps) {
  const [viewMode, setViewMode] = useState<'grid' | 'list'>('grid');
  const [search, setSearch] = useState('');
  const [kindFilter, setKindFilter] = useState('');
  const [agentFilter, setAgentFilter] = useState('');
  const [projectFilter, setProjectFilter] = useState('');
  const [chainFilter, setChainFilter] = useState('');
  const [activeArtifactId, setActiveArtifactId] = useState('');
  const [renamingId, setRenamingId] = useState('');
  const [renameName, setRenameName] = useState('');
  const [deleteConfirmId, setDeleteConfirmId] = useState('');

  const artifactsQuery = useListArtifactsQuery({ limit: 200, includeDeleted: false }, { skip: !session?.clientToken });
  const agentsQuery = useListAgentsQuery(undefined, { skip: !session?.clientToken });
  const [updateArtifact] = useUpdateArtifactMutation();
  const [deleteArtifact] = useDeleteArtifactMutation();
  const upload = useArtifactUpload({ projectId: '', originKind: 'library_upload', originRef: '' });

  const artifacts = useMemo(() => (artifactsQuery.data?.artifacts || []) as ArtifactRow[], [artifactsQuery.data]);
  const agents = agentsQuery?.data?.agents || agentsQuery?.data || [];
  const agentsArray = Array.isArray(agents) ? agents : [];
  const projectsList = Array.isArray(projects) ? projects : Object.values(projects || {});
  const chainsArray = Array.isArray(chains) ? chains : [];

  const kindOptions = useMemo(() => {
    const set = new Set<string>();
    artifacts.forEach((a) => { const k = kindLabel(a); if (k) set.add(k); });
    return Array.from(set).sort();
  }, [artifacts]);

  const filtered = useMemo(() => {
    const q = search.trim().toLowerCase();
    return artifacts.filter((a) => {
      if (kindFilter && kindLabel(a) !== kindFilter) return false;
      if (projectFilter && projectId(a) !== projectFilter) return false;
      if (agentFilter && creatorId(a) !== agentFilter) return false;
      if (chainFilter && originRef(a) !== chainFilter) return false;
      if (q) {
        const hay = `${a?.name || ''} ${a?.description || ''} ${artifactId(a)} ${originRef(a)}`.toLowerCase();
        if (!hay.includes(q)) return false;
      }
      return true;
    });
  }, [artifacts, search, kindFilter, projectFilter, agentFilter, chainFilter]);

  async function handleRename(id: string) {
    const name = renameName.trim();
    if (!name) return;
    try {
      await updateArtifact({ artifactId: id, name, changeReason: 'rename from library' }).unwrap();
      setRenamingId('');
    } catch {
      // ignore — RTK Query tag invalidation keeps the list fresh
    }
  }

  async function handleDelete(id: string) {
    try {
      await deleteArtifact({ artifactId: id }).unwrap();
      setDeleteConfirmId('');
      if (activeArtifactId === id) setActiveArtifactId('');
    } catch {
      // ignore
    }
  }

  const daemonUrl = session?.daemonUrl || '';
  const clientToken = session?.clientToken || '';

  return (
    <div data-debug-id="library-page" className="flex h-full flex-col bg-[#0a0a0a] text-zinc-100">
      {/* Header */}
      <div data-debug-id="library-header" className="border-b border-white/[0.06] px-6 py-4">
        <div className="flex items-center justify-between gap-3">
          <div className="min-w-0">
            <div className="flex items-center gap-2">
              {onBack ? <button type="button" data-debug-id="library-back-btn" onClick={onBack} className="text-zinc-500 hover:text-zinc-200">←</button> : null}
              <h1 data-debug-id="library-title" className="truncate text-lg font-semibold tracking-[-0.01em]">Library</h1>
              <span className="rounded-full border border-white/10 bg-white/[0.04] px-2 py-0.5 text-[11px] text-zinc-400">{filtered.length}{filtered.length !== artifacts.length ? ` / ${artifacts.length}` : ''}</span>
            </div>
            <p data-debug-id="library-subtitle" className="mt-0.5 text-[11.5px] text-zinc-500">All artifacts across conversations, chains, and projects.</p>
          </div>
          <div className="flex items-center gap-2">
            {/* grid | list toggle */}
            <div data-debug-id="library-view-toggle" className="flex rounded-lg border border-white/10 bg-black/30 p-0.5">
              {(['grid', 'list'] as const).map((mode) => (
                <button key={mode} type="button" data-debug-id={`library-view-${mode}`} onClick={() => setViewMode(mode)} className={`rounded-md px-2.5 py-1 text-[11px] ${viewMode === mode ? 'bg-white/[0.08] text-zinc-100' : 'text-zinc-500 hover:text-zinc-200'}`}>{mode}</button>
              ))}
            </div>
            {session?.clientToken ? (
              <ArtifactUploadButton
                onUploaded={() => artifactsQuery.refetch()}
                context={{ originKind: 'library_upload', originRef: '' }}
                debugIdPrefix="library-upload"
                label="＋ Upload"
                buttonClassName="rounded-lg border border-sky-400/30 bg-sky-400/10 px-3 py-1.5 text-[12px] text-sky-100 hover:bg-sky-400/20"
              />
            ) : null}
          </div>
        </div>

        {/* Filters */}
        <div data-debug-id="library-filters" className="mt-3 flex flex-wrap items-center gap-2">
          <input data-debug-id="library-filter-search" value={search} onChange={(e) => setSearch(e.target.value)} placeholder="Search name / description…" className="min-w-[12rem] flex-1 rounded-lg border border-white/10 bg-black/30 px-3 py-1.5 text-sm text-zinc-100 outline-none placeholder:text-zinc-600 focus:border-sky-400" />
          <label className="text-[11px] uppercase tracking-wide text-zinc-500">Kind
            <select data-debug-id="library-filter-kind" value={kindFilter} onChange={(e) => setKindFilter(e.target.value)} className="ml-1 rounded-lg border border-white/10 bg-black/30 px-2 py-1.5 text-sm text-zinc-100 outline-none">
              <option value="">all</option>
              {kindOptions.map((k) => <option key={k} value={k}>{k}</option>)}
            </select>
          </label>
          <label className="text-[11px] uppercase tracking-wide text-zinc-500">Agent
            <select data-debug-id="library-filter-agent" value={agentFilter} onChange={(e) => setAgentFilter(e.target.value)} className="ml-1 rounded-lg border border-white/10 bg-black/30 px-2 py-1.5 text-sm text-zinc-100 outline-none">
              <option value="">all</option>
              {agentsArray.map((ag: any) => <option key={ag.id || ag.agent_id} value={ag.id || ag.agent_id}>{ag.display_name || ag.displayName || ag.id || ag.agent_id}</option>)}
            </select>
          </label>
          <label className="text-[11px] uppercase tracking-wide text-zinc-500">Project
            <select data-debug-id="library-filter-project" value={projectFilter} onChange={(e) => setProjectFilter(e.target.value)} className="ml-1 rounded-lg border border-white/10 bg-black/30 px-2 py-1.5 text-sm text-zinc-100 outline-none">
              <option value="">all</option>
              {projectsList.map((p: any) => <option key={p.project_id || p.id} value={p.project_id || p.id}>{p.name || p.project_id || p.id}</option>)}
            </select>
          </label>
          <label className="text-[11px] uppercase tracking-wide text-zinc-500">Chain
            <select data-debug-id="library-filter-chain" value={chainFilter} onChange={(e) => setChainFilter(e.target.value)} className="ml-1 rounded-lg border border-white/10 bg-black/30 px-2 py-1.5 text-sm text-zinc-100 outline-none">
              <option value="">all</option>
              {chainsArray.map((c: any) => <option key={c.chainId || c.chain_id} value={c.chainId || c.chain_id}>{c.title || c.chainId || c.chain_id}</option>)}
            </select>
          </label>
          {(search || kindFilter || agentFilter || projectFilter || chainFilter) ? (
            <button type="button" data-debug-id="library-filter-clear" onClick={() => { setSearch(''); setKindFilter(''); setAgentFilter(''); setProjectFilter(''); setChainFilter(''); }} className="text-[11px] text-zinc-500 hover:text-zinc-200">clear</button>
          ) : null}
        </div>
      </div>

      {/* Body */}
      <div data-debug-id="library-body" className="flex-1 overflow-y-auto p-6">
        {artifactsQuery.isFetching && artifacts.length === 0 ? (
          <div data-debug-id="library-loading" className="py-16 text-center text-sm text-zinc-500">Loading artifacts…</div>
        ) : filtered.length === 0 ? (
          <div data-debug-id="library-empty" className="rounded-2xl border border-dashed border-white/10 bg-[#111111]/70 py-16 text-center text-sm text-zinc-500">
            <div className="text-zinc-300">{artifacts.length === 0 ? 'No artifacts yet.' : 'No artifacts match your filters.'}</div>
            <p className="mt-1 leading-5">{artifacts.length === 0 ? 'Upload an artifact or generate one in a conversation.' : 'Try clearing filters.'}</p>
          </div>
        ) : viewMode === 'grid' ? (
          <div data-debug-id="library-grid" className="grid grid-cols-1 gap-3 sm:grid-cols-2 lg:grid-cols-3 xl:grid-cols-4">
            {filtered.map((a) => {
              const id = artifactId(a);
              return (
                <div key={id} data-debug-id={`library-card-${id}`} className="group relative overflow-hidden rounded-2xl border border-white/10 bg-white/[0.02] p-3 transition hover:border-white/20 hover:bg-white/[0.04]">
                  <button type="button" data-debug-id={`library-card-open-${id}`} onClick={() => setActiveArtifactId(id)} className="block w-full text-left">
                    <div className="mb-2 flex h-24 items-center justify-center overflow-hidden rounded-xl bg-black/30">
                      {isImage(a) ? (
                        <ArtifactThumbnail artifactId={id} session={session} alt={a?.name || id} />
                      ) : (
                        <span className="text-3xl opacity-40">{kindIcon(kindLabel(a))}</span>
                      )}
                    </div>
                    <div className="truncate text-sm font-medium text-zinc-100">{a?.name || id}</div>
                    <div className="mt-0.5 flex items-center gap-2 text-[11px] text-zinc-500">
                      <span className="rounded-full border border-white/10 bg-black/20 px-1.5 py-0.5 uppercase tracking-wide">{kindLabel(a)}</span>
                      <span>{formatBytes(Number(a?.size_bytes) || 0)}</span>
                      <span className="ml-auto">{timeAgo(Number(a?.updated_unix_ms || a?.created_unix_ms))}</span>
                    </div>
                    {a?.description ? <div className="mt-1 line-clamp-2 text-[11.5px] leading-4 text-zinc-500">{a.description}</div> : null}
                  </button>
                  {/* per-card rename / delete menu */}
                  <div className="mt-2 flex justify-end gap-1 opacity-0 transition group-hover:opacity-100">
                    <button type="button" data-debug-id={`library-card-rename-${id}`} onClick={() => { setRenamingId(id); setRenameName(a?.name || ''); }} className="rounded-md border border-white/10 px-1.5 py-0.5 text-[10.5px] text-zinc-400 hover:bg-white/10">✎</button>
                    <button type="button" data-debug-id={`library-card-delete-${id}`} onClick={() => setDeleteConfirmId(id)} className="rounded-md border border-white/10 px-1.5 py-0.5 text-[10.5px] text-rose-300 hover:bg-rose-500/10">🗑</button>
                  </div>
                  {renamingId === id ? (
                    <div data-debug-id={`library-card-rename-panel-${id}`} className="absolute inset-0 z-10 flex flex-col justify-center gap-2 rounded-2xl bg-[#0b0d12]/95 p-3">
                      <input data-debug-id={`library-rename-input-${id}`} value={renameName} onChange={(e) => setRenameName(e.target.value)} className="w-full rounded-lg border border-white/10 bg-black/40 px-2 py-1 text-sm text-zinc-100 outline-none focus:border-sky-400" />
                      <div className="flex justify-end gap-1">
                        <button type="button" data-debug-id={`library-rename-save-${id}`} onClick={() => void handleRename(id)} className="rounded-md bg-sky-400 px-2 py-0.5 text-[11px] font-semibold text-black hover:bg-sky-300">Save</button>
                        <button type="button" data-debug-id={`library-rename-cancel-${id}`} onClick={() => setRenamingId('')} className="rounded-md bg-white/10 px-2 py-0.5 text-[11px] text-zinc-200 hover:bg-white/15">Cancel</button>
                      </div>
                    </div>
                  ) : null}
                  {deleteConfirmId === id ? (
                    <div data-debug-id={`library-card-delete-panel-${id}`} className="absolute inset-0 z-10 flex flex-col justify-center gap-2 rounded-2xl bg-[#0b0d12]/95 p-3 text-center">
                      <div className="text-xs text-rose-100">Delete this artifact? References become unavailable placeholders.</div>
                      <div className="flex justify-center gap-1">
                        <button type="button" data-debug-id={`library-delete-confirm-${id}`} onClick={() => void handleDelete(id)} className="rounded-md bg-rose-400 px-2 py-0.5 text-[11px] font-semibold text-black hover:bg-rose-300">Delete</button>
                        <button type="button" data-debug-id={`library-delete-cancel-${id}`} onClick={() => setDeleteConfirmId('')} className="rounded-md bg-white/10 px-2 py-0.5 text-[11px] text-zinc-200 hover:bg-white/15">Cancel</button>
                      </div>
                    </div>
                  ) : null}
                </div>
              );
            })}
          </div>
        ) : (
          <div data-debug-id="library-list" className="overflow-hidden rounded-2xl border border-white/10">
            <div className="grid grid-cols-[1fr_5rem_5rem_6rem_7rem_3rem] gap-2 border-b border-white/10 bg-white/[0.03] px-3 py-2 text-[10.5px] uppercase tracking-wide text-zinc-500">
              <span>Name</span><span>Kind</span><span>Size</span><span>Project</span><span>Updated</span><span></span>
            </div>
            {filtered.map((a) => {
              const id = artifactId(a);
              const project = projectsList.find((p: any) => (p.project_id || p.id) === projectId(a));
              return (
                <div key={id} data-debug-id={`library-row-${id}`} className="grid grid-cols-[1fr_5rem_5rem_6rem_7rem_3rem] items-center gap-2 border-b border-white/[0.04] px-3 py-2 text-sm hover:bg-white/[0.02]">
                  <button type="button" data-debug-id={`library-row-open-${id}`} onClick={() => setActiveArtifactId(id)} className="flex min-w-0 items-center gap-2 text-left">
                    {isImage(a) ? (
                      <span className="h-8 w-8 shrink-0 overflow-hidden rounded-lg border border-white/10 bg-black/30">
                        <ArtifactThumbnail artifactId={id} session={session} alt={a?.name || id} />
                      </span>
                    ) : (
                      <span className="text-base opacity-50">{kindIcon(kindLabel(a))}</span>
                    )}
                    <span className="min-w-0 flex-1 truncate text-zinc-100">{a?.name || id}</span>
                  </button>
                  <span className="truncate text-[11.5px] text-zinc-500">{kindLabel(a)}</span>
                  <span className="truncate text-[11.5px] text-zinc-500">{formatBytes(Number(a?.size_bytes) || 0)}</span>
                  <span className="truncate text-[11.5px] text-zinc-500">{project?.name || projectId(a) || '—'}</span>
                  <span className="truncate text-[11.5px] text-zinc-500">{timeAgo(Number(a?.updated_unix_ms || a?.created_unix_ms))}</span>
                  <span className="flex justify-end gap-1">
                    <button type="button" data-debug-id={`library-row-rename-${id}`} onClick={() => { setRenamingId(id); setRenameName(a?.name || ''); }} className="rounded-md px-1 text-[11px] text-zinc-500 hover:text-zinc-200">✎</button>
                    <button type="button" data-debug-id={`library-row-delete-${id}`} onClick={() => setDeleteConfirmId(id)} className="rounded-md px-1 text-[11px] text-rose-300 hover:text-rose-100">🗑</button>
                  </span>
                </div>
              );
            })}
          </div>
        )}
      </div>

      {/* Fullscreen viewer */}
      {activeArtifactId && daemonUrl && clientToken ? (
        <ArtifactViewer artifactId={activeArtifactId} daemonUrl={daemonUrl} clientToken={clientToken} onClose={() => setActiveArtifactId('')} />
      ) : null}
    </div>
  );
}

function ArtifactThumbnail({ artifactId, session, alt }: { artifactId: string; session: any; alt: string }) {
  return <ArtifactImagePreview artifactId={artifactId} session={session} alt={alt} debugId={`library-thumbnail-${artifactId}`} className="h-full w-full object-cover" />;
}
