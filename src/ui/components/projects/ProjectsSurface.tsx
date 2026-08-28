// ProjectsSurface — the primary "Projects" destination.
//
// A project is the organizing unit: it groups conversations, and (per product
// direction) the place to see the agents and memory associated with it and to
// configure per-bridge working paths. This surface has two modes:
//   - list:   all projects (search + create)
//   - detail: one project with Agents / Memory / Bridge paths panels
//
// Everything is backed by existing endpoints:
//   projects  -> useListProjectsQuery / useFetchProjectQuery / bridge-path mutations
//   agents    -> useListAgentsQuery({ projectId })
//   memory    -> useListMemoriesQuery({ project_id })

import { useMemo, useState } from 'react';
import {
  useListProjectsQuery,
  useFetchProjectQuery,
  useCreateProjectMutation,
  useSetProjectBridgePathMutation,
  useDeleteProjectBridgePathMutation,
  useValidateProjectBridgePathMutation,
  type Project,
} from '../../api/endpoints/projects';
import { useListAgentsQuery } from '../../api/endpoints/agents';
import { useListMemoriesQuery } from '../../api/endpoints/memory';
import { useListBridgesQuery } from '../../api/endpoints/bridgeSupport';
import { buildRouteHash, getRouteSearch } from '../../utils/appLocation';
import Icon from '../Icon';
import SearchableSelect from '../SearchableSelect';

function str(v: any): string { return String(v ?? '').trim(); }
function bridgeId(b: any): string { return str(b?.bridge_id || b?.bridgeId || b?.id); }
function bridgeLabel(b: any): string { return str(b?.label || b?.machine_hostname || bridgeId(b)); }

function projectIdFromRoute(): string {
  try {
    const params = new URLSearchParams(getRouteSearch().replace(/^\?/, ''));
    return str(params.get('projectId') || params.get('project'));
  } catch { return ''; }
}

export default function ProjectsSurface() {
  const routeProjectId = projectIdFromRoute();
  return routeProjectId
    ? <ProjectDetail projectId={routeProjectId} />
    : <ProjectList />;
}

// ---------------------------------------------------------------------------
// List
// ---------------------------------------------------------------------------
function ProjectList() {
  const projectsQuery = useListProjectsQuery();
  const [createProject, createState] = useCreateProjectMutation();
  const [query, setQuery] = useState('');
  const [showCreate, setShowCreate] = useState(false);
  const [name, setName] = useState('');
  const [defaultPath, setDefaultPath] = useState('');
  const [createError, setCreateError] = useState('');

  const projects: Project[] = useMemo(() => (projectsQuery.data?.projects || projectsQuery.data || []) as Project[], [projectsQuery.data]);
  const filtered = useMemo(() => {
    const q = query.trim().toLowerCase();
    if (!q) return projects;
    return projects.filter((p) => [p.name, p.project_id, p.default_path].filter(Boolean).join(' ').toLowerCase().includes(q));
  }, [projects, query]);

  async function submitCreate() {
    setCreateError('');
    if (!name.trim()) { setCreateError('Name is required.'); return; }
    try {
      await createProject({ name: name.trim(), default_path: defaultPath.trim() }).unwrap();
      setName(''); setDefaultPath(''); setShowCreate(false);
    } catch (e: any) {
      setCreateError(str(e?.data?.error?.message || e?.error || e?.message) || 'Create failed');
    }
  }

  return (
    <div data-debug-id="projects-surface" className="w-full">
      <header className="mb-5 flex items-center justify-between gap-3">
        <div>
          <p className="text-[11px] font-bold uppercase tracking-[0.22em] text-sky-300/75">Projects</p>
          <h1 className="mt-1 text-2xl font-semibold tracking-tight text-white">Projects</h1>
          <p className="mt-1 text-sm text-zinc-500">Group work by project — agents, memory and per-device paths.</p>
        </div>
        <button data-debug-id="projects-new-btn" type="button" onClick={() => setShowCreate((v) => !v)} className="inline-flex min-h-10 items-center gap-2 rounded-2xl bg-sky-400 px-4 py-2 text-sm font-black text-black hover:bg-sky-300">
          <Icon name="plus" size={16} /> New project
        </button>
      </header>

      {showCreate ? (
        <div data-debug-id="projects-create-form" className="mb-5 rounded-2xl border border-white/10 bg-white/[0.03] p-4">
          <div className="grid gap-3 sm:grid-cols-2">
            <label className="block text-[11px] font-semibold uppercase tracking-[0.14em] text-zinc-500">Name
              <input data-debug-id="projects-create-name-input" value={name} onChange={(e) => setName(e.target.value)} className="mt-1 w-full rounded-xl border border-white/10 bg-black/30 px-3 py-2.5 text-sm text-white" placeholder="e.g. heimdall agent manager" />
            </label>
            <label className="block text-[11px] font-semibold uppercase tracking-[0.14em] text-zinc-500">Default path
              <input data-debug-id="projects-create-path-input" value={defaultPath} onChange={(e) => setDefaultPath(e.target.value)} className="mt-1 w-full rounded-xl border border-white/10 bg-black/30 px-3 py-2.5 font-mono text-sm text-white" placeholder="~/path/to/repo" />
            </label>
          </div>
          {createError ? <p data-debug-id="projects-create-error" className="mt-2 text-xs text-red-300">{createError}</p> : null}
          <div className="mt-3 flex gap-2">
            <button data-debug-id="projects-create-submit-btn" type="button" disabled={createState.isLoading} onClick={submitCreate} className="rounded-xl bg-sky-400 px-4 py-2 text-sm font-bold text-black hover:bg-sky-300 disabled:opacity-50">{createState.isLoading ? 'Creating…' : 'Create'}</button>
            <button data-debug-id="projects-create-cancel-btn" type="button" onClick={() => setShowCreate(false)} className="rounded-xl border border-white/10 px-4 py-2 text-sm text-zinc-300 hover:bg-white/10">Cancel</button>
          </div>
        </div>
      ) : null}

      <div className="mb-3 flex items-center gap-2 rounded-2xl border border-white/10 bg-black/20 px-3 py-2 text-zinc-500">
        <Icon name="search" size={15} />
        <input data-debug-id="projects-search-input" value={query} onChange={(e) => setQuery(e.target.value)} placeholder={`Search ${projects.length} projects…`} className="w-full bg-transparent text-sm text-white outline-none placeholder:text-zinc-600" />
      </div>

      <div data-debug-id="projects-list" className="divide-y divide-white/[0.06] overflow-hidden rounded-2xl border border-white/10 bg-white/[0.02]">
        {projectsQuery.isLoading ? (
          <div className="p-5 text-sm text-zinc-500">Loading projects…</div>
        ) : filtered.length === 0 ? (
          <div data-debug-id="projects-empty" className="p-6 text-sm text-zinc-500">No projects match.</div>
        ) : filtered.map((p) => (
          <a
            key={p.project_id}
            data-debug-id={`projects-row-${p.project_id}`}
            href={buildRouteHash('/projects', `projectId=${encodeURIComponent(p.project_id)}`)}
            className="flex items-center gap-3 px-4 py-3 hover:bg-white/[0.05]"
          >
            <span className="grid h-9 w-9 shrink-0 place-items-center rounded-xl bg-gradient-to-br from-sky-400/80 to-violet-400/80 text-sm font-black text-black">{(p.name || '?').slice(0, 1).toUpperCase()}</span>
            <span className="min-w-0 flex-1">
              <span className="block truncate text-sm font-semibold text-zinc-100">{p.name || p.project_id}</span>
              {p.default_path ? <span className="block truncate font-mono text-[11px] text-zinc-500">{p.default_path}</span> : null}
            </span>
            <Icon name="chevron-right" size={16} className="shrink-0 text-zinc-600" />
          </a>
        ))}
      </div>
    </div>
  );
}

// ---------------------------------------------------------------------------
// Detail
// ---------------------------------------------------------------------------
function ProjectDetail({ projectId }: { projectId: string }) {
  const detailQuery = useFetchProjectQuery({ projectId }, { skip: !projectId });
  const agentsQuery = useListAgentsQuery({ projectId });
  const memoryQuery = useListMemoriesQuery({ project_id: projectId });
  const bridgesQuery = useListBridgesQuery();

  const project: Project | null = detailQuery.data?.project || null;
  const agents: any[] = agentsQuery.data?.agents || [];
  const memories: any[] = memoryQuery.data?.items || [];
  const bridges: any[] = (bridgesQuery.data?.bridges || []).filter((b: any) => str(b?.status || b?.state || 'online').toLowerCase() !== 'revoked');

  return (
    <div data-debug-id="project-detail" className="w-full">
      <a data-debug-id="project-detail-back-btn" href={buildRouteHash('/projects', '')} className="mb-4 inline-flex items-center gap-1.5 text-sm text-zinc-400 hover:text-white">
        <Icon name="chevron-left" size={16} /> All projects
      </a>

      <header className="mb-5">
        <p className="text-[11px] font-bold uppercase tracking-[0.22em] text-sky-300/75">Project</p>
        <h1 data-debug-id="project-detail-title" className="mt-1 text-2xl font-semibold tracking-tight text-white">{project?.name || projectId}</h1>
        {project?.default_path ? <p className="mt-1 font-mono text-xs text-zinc-500">{project.default_path}</p> : null}
        {project?.description ? <p className="mt-2 max-w-2xl text-sm text-zinc-400">{project.description}</p> : null}
      </header>

      <div className="grid gap-4 lg:grid-cols-2">
        <AgentsPanel agents={agents} loading={agentsQuery.isLoading} projectId={projectId} />
        <MemoryPanel memories={memories} loading={memoryQuery.isLoading} projectId={projectId} />
        <div className="lg:col-span-2">
          <BridgePathsPanel projectId={projectId} project={project} bridges={bridges} />
        </div>
      </div>
    </div>
  );
}

function Card({ title, count, children, debugId, action }: { title: string; count?: number; children: React.ReactNode; debugId: string; action?: React.ReactNode }) {
  return (
    <section data-debug-id={debugId} className="rounded-2xl border border-white/10 bg-white/[0.02] p-4">
      <div className="mb-3 flex items-center justify-between">
        <h2 className="text-sm font-semibold text-zinc-200">{title}{typeof count === 'number' ? <span className="ml-2 text-xs font-normal text-zinc-500">{count}</span> : null}</h2>
        {action}
      </div>
      {children}
    </section>
  );
}

function AgentsPanel({ agents, loading, projectId }: { agents: any[]; loading: boolean; projectId: string }) {
  return (
    <Card title="Agents" count={agents.length} debugId="project-detail-agents"
      action={<a data-debug-id="project-detail-new-agent-btn" href={buildRouteHash('/conversations/new', `project=${encodeURIComponent(projectId)}`)} className="inline-flex items-center gap-1 rounded-lg border border-white/10 px-2 py-1 text-xs text-zinc-300 hover:bg-white/10"><Icon name="plus" size={12} /> New chat</a>}>
      {loading ? (
        <div className="py-4 text-sm text-zinc-500">Loading…</div>
      ) : agents.length === 0 ? (
        <div data-debug-id="project-detail-agents-empty" className="py-3 text-sm text-zinc-500">No agents associated with this project yet.</div>
      ) : (
        <div className="space-y-1">
          {agents.map((a) => {
            const id = str(a?.id || a?.agent_id || a?.agentId);
            const name = str(a?.name || a?.display_name || a?.displayName || id);
            const tier = str(a?.tier || a?.defaultTier || a?.default_tier);
            const instances = Number(a?.activeInstanceCount ?? a?.active_instance_count ?? 0);
            return (
              <a key={id} data-debug-id={`project-detail-agent-${id}`} href={buildRouteHash('/agents', `agentId=${encodeURIComponent(id)}`)} className="flex items-center gap-3 rounded-lg px-2 py-2 hover:bg-white/[0.05]">
                <span className="grid h-7 w-7 shrink-0 place-items-center rounded-lg bg-white/[0.06] text-[11px] font-bold text-zinc-300">{(name || '?').slice(0, 1).toUpperCase()}</span>
                <span className="min-w-0 flex-1 truncate text-sm text-zinc-200">{name}</span>
                {instances > 0 ? <span className="shrink-0 rounded-full bg-emerald-400/15 px-2 py-0.5 text-[10px] font-bold text-emerald-300">{instances} live</span> : null}
                {tier ? <span className="shrink-0 text-[11px] text-zinc-500">{tier}</span> : null}
              </a>
            );
          })}
        </div>
      )}
    </Card>
  );
}

function MemoryPanel({ memories, loading, projectId }: { memories: any[]; loading: boolean; projectId: string }) {
  return (
    <Card title="Memory" count={memories.length} debugId="project-detail-memory"
      action={<a data-debug-id="project-detail-open-memory-btn" href={buildRouteHash('/settings/memory', `project=${encodeURIComponent(projectId)}`)} className="inline-flex items-center gap-1 rounded-lg border border-white/10 px-2 py-1 text-xs text-zinc-300 hover:bg-white/10">Manage</a>}>
      {loading ? (
        <div className="py-4 text-sm text-zinc-500">Loading…</div>
      ) : memories.length === 0 ? (
        <div data-debug-id="project-detail-memory-empty" className="py-3 text-sm text-zinc-500">No memory scoped to this project yet.</div>
      ) : (
        <div className="space-y-1">
          {memories.slice(0, 12).map((m) => {
            const id = str(m?.memoryId || m?.memory_id || m?.id);
            const title = str(m?.title) || str(m?.body).slice(0, 60) || id;
            const type = str(m?.type || m?.memory_type);
            const status = str(m?.status);
            return (
              <div key={id} data-debug-id={`project-detail-memory-${id}`} className="flex items-center gap-3 rounded-lg px-2 py-2 hover:bg-white/[0.04]">
                <span className="min-w-0 flex-1 truncate text-sm text-zinc-200">{title}</span>
                {type ? <span className="shrink-0 rounded-full bg-white/[0.06] px-2 py-0.5 text-[10px] font-semibold text-zinc-400">{type}</span> : null}
                {status && status !== 'active' ? <span className="shrink-0 rounded-full bg-amber-400/15 px-2 py-0.5 text-[10px] font-bold text-amber-300">{status}</span> : null}
              </div>
            );
          })}
        </div>
      )}
    </Card>
  );
}

function BridgePathsPanel({ projectId, project, bridges }: { projectId: string; project: Project | null; bridges: any[] }) {
  const [setBridgePath, setState] = useSetProjectBridgePathMutation();
  const [deleteBridgePath] = useDeleteProjectBridgePathMutation();
  const [validateBridgePath] = useValidateProjectBridgePathMutation();
  const existing = project?.bridge_paths || [];
  const pathByBridge = useMemo(() => {
    const map = new Map<string, any>();
    for (const bp of existing) map.set(str(bp.bridge_id), bp);
    return map;
  }, [existing]);

  const [selBridge, setSelBridge] = useState('');
  const [pathDraft, setPathDraft] = useState('');
  const [err, setErr] = useState('');

  async function save() {
    setErr('');
    if (!selBridge || !pathDraft.trim()) { setErr('Choose a device and enter a path.'); return; }
    try {
      await setBridgePath({ projectId, bridgeId: selBridge, path: pathDraft.trim() } as any).unwrap();
      setPathDraft('');
    } catch (e: any) { setErr(str(e?.data?.error?.message || e?.error || e?.message) || 'Save failed'); }
  }

  const bridgeOptions = bridges.map((b) => ({ value: bridgeId(b), title: bridgeLabel(b), subtitle: pathByBridge.has(bridgeId(b)) ? 'has a path set' : undefined }));

  return (
    <Card title="Bridge paths" count={existing.length} debugId="project-detail-bridge-paths">
      <p className="mb-3 text-xs text-zinc-500">Where this project lives on each device (bridge). Agents launched on a device use its path.</p>

      {existing.length > 0 ? (
        <div className="mb-4 space-y-1.5">
          {existing.map((bp) => {
            const bid = str(bp.bridge_id);
            const b = bridges.find((x) => bridgeId(x) === bid);
            return (
              <div key={bid} data-debug-id={`project-detail-bridge-path-row-${bid}`} className="flex items-center gap-3 rounded-lg border border-white/[0.06] bg-black/20 px-3 py-2">
                <span className="shrink-0 rounded-md bg-white/[0.06] px-2 py-0.5 text-[11px] font-semibold text-zinc-300">{b ? bridgeLabel(b) : bid}</span>
                <span className="min-w-0 flex-1 truncate font-mono text-[12px] text-zinc-300">{bp.path}</span>
                {bp.is_validated ? <span className="shrink-0 text-[11px] font-semibold text-emerald-400">validated</span> : <span className="shrink-0 text-[11px] text-amber-400">unvalidated</span>}
                <button data-debug-id={`project-detail-bridge-path-validate-${bid}`} type="button" onClick={() => validateBridgePath({ projectId, bridgeId: bid } as any)} className="shrink-0 rounded-md border border-white/10 px-2 py-1 text-[11px] text-zinc-300 hover:bg-white/10">Validate</button>
                <button data-debug-id={`project-detail-bridge-path-remove-${bid}`} type="button" onClick={() => deleteBridgePath({ projectId, bridgeId: bid } as any)} aria-label="Remove path" className="shrink-0 rounded-md p-1 text-zinc-500 hover:bg-white/10 hover:text-red-300"><Icon name="close" size={14} /></button>
              </div>
            );
          })}
        </div>
      ) : (
        <div data-debug-id="project-detail-bridge-paths-empty" className="mb-4 text-sm text-zinc-500">No per-device paths yet. Add one below.</div>
      )}

      <div className="grid gap-2 sm:grid-cols-[minmax(0,220px)_1fr_auto] sm:items-end">
        <div>
          <label className="block text-[11px] font-semibold uppercase tracking-[0.14em] text-zinc-500">Device</label>
          <SearchableSelect debugId="project-detail-bridge-path-device" options={bridgeOptions} value={selBridge} onChange={setSelBridge} buttonPlaceholder="Choose device…" placeholder="Search devices…" />
        </div>
        <label className="block text-[11px] font-semibold uppercase tracking-[0.14em] text-zinc-500">Path
          <input data-debug-id="project-detail-bridge-path-input" value={pathDraft} onChange={(e) => setPathDraft(e.target.value)} placeholder="~/path/on/this/device" className="mt-1 w-full rounded-xl border border-white/10 bg-black/30 px-3 py-2.5 font-mono text-sm text-white" />
        </label>
        <button data-debug-id="project-detail-bridge-path-save-btn" type="button" disabled={setState.isLoading} onClick={save} className="h-[42px] rounded-xl bg-sky-400 px-4 text-sm font-bold text-black hover:bg-sky-300 disabled:opacity-50">Save</button>
      </div>
      {err ? <p data-debug-id="project-detail-bridge-path-error" className="mt-2 text-xs text-red-300">{err}</p> : null}
    </Card>
  );
}
