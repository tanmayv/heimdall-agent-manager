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

import { useEffect, useMemo, useState } from 'react';
import {
  useListProjectsQuery,
  useFetchProjectQuery,
  useCreateProjectMutation,
  useUpdateProjectMutation,
  useSetProjectBridgePathMutation,
  useDeleteProjectBridgePathMutation,
  type Project,
} from '../../api/endpoints/projects';
import { useListAgentsQuery } from '../../api/endpoints/agents';
import { useListMemoriesQuery } from '../../api/endpoints/memory';
import { useListBridgesQuery } from '../../api/endpoints/bridgeSupport';
import { useLazyStatBridgePathQuery, useMkdirBridgePathMutation } from '../../api/endpoints/bridgeFs';
import { buildRouteHash, getRouteSearch } from '../../utils/appLocation';
import Icon from '../Icon';
import BridgeDirectoryPicker from '../BridgeDirectoryPicker';

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
  // The AppShell route is just `/projects` for both list and detail (detail only
  // adds a `?projectId=` query). The shell won't re-render on a query-only change,
  // so track the selected project id here and react to hashchange ourselves.
  const [routeProjectId, setRouteProjectId] = useState(projectIdFromRoute);
  useEffect(() => {
    const update = () => setRouteProjectId(projectIdFromRoute());
    window.addEventListener('hashchange', update);
    window.addEventListener('popstate', update);
    update();
    return () => {
      window.removeEventListener('hashchange', update);
      window.removeEventListener('popstate', update);
    };
  }, []);
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
      </header>

      <div className="grid gap-4 lg:grid-cols-2">
        <div className="lg:col-span-2">
          <AboutPanel projectId={projectId} project={project} />
        </div>
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

function AboutPanel({ projectId, project }: { projectId: string; project: Project | null }) {
  const [updateProject, updateState] = useUpdateProjectMutation();
  const [editing, setEditing] = useState(false);
  const [name, setName] = useState('');
  const [description, setDescription] = useState('');
  const [defaultPath, setDefaultPath] = useState('');
  const [err, setErr] = useState('');

  // Seed the edit form from the loaded project whenever it (re)loads.
  useEffect(() => {
    if (!project) return;
    setName(str(project.name));
    setDescription(str(project.description));
    setDefaultPath(str(project.default_path));
  }, [project?.project_id, project?.name, project?.description, project?.default_path]);

  async function save() {
    setErr('');
    try {
      await updateProject({ projectId, name: name.trim(), description: description.trim(), default_path: defaultPath.trim() }).unwrap();
      setEditing(false);
    } catch (e: any) {
      setErr(str(e?.data?.error?.message || e?.error || e?.message) || 'Save failed');
    }
  }

  return (
    <Card title="About" debugId="project-detail-about"
      action={!editing ? (
        <button data-debug-id="project-detail-edit-btn" type="button" onClick={() => setEditing(true)} className="inline-flex items-center gap-1 rounded-lg border border-white/10 px-2 py-1 text-xs text-zinc-300 hover:bg-white/10">Edit</button>
      ) : null}>
      {!editing ? (
        <div className="space-y-2">
          {project?.default_path ? <p data-debug-id="project-detail-path" className="font-mono text-xs text-zinc-500">{project.default_path}</p> : null}
          {str(project?.description) ? (
            <p data-debug-id="project-detail-description" className="max-w-2xl whitespace-pre-wrap text-sm leading-6 text-zinc-300">{project?.description}</p>
          ) : (
            <p data-debug-id="project-detail-description-empty" className="text-sm text-zinc-500">No description yet. <button type="button" onClick={() => setEditing(true)} className="text-sky-300 hover:underline">Add one</button>.</p>
          )}
        </div>
      ) : (
        <div className="space-y-3">
          <label className="block text-[11px] font-semibold uppercase tracking-[0.14em] text-zinc-500">Name
            <input data-debug-id="project-detail-name-input" value={name} onChange={(e) => setName(e.target.value)} className="mt-1 w-full rounded-xl border border-white/10 bg-black/30 px-3 py-2.5 text-sm text-white" />
          </label>
          <label className="block text-[11px] font-semibold uppercase tracking-[0.14em] text-zinc-500">Description
            <textarea data-debug-id="project-detail-description-input" value={description} onChange={(e) => setDescription(e.target.value)} rows={4} placeholder="What is this project about?" className="mt-1 w-full resize-y rounded-xl border border-white/10 bg-black/30 px-3 py-2.5 text-sm leading-6 text-white placeholder:text-zinc-600" />
          </label>
          <label className="block text-[11px] font-semibold uppercase tracking-[0.14em] text-zinc-500">Default path
            <input data-debug-id="project-detail-default-path-input" value={defaultPath} onChange={(e) => setDefaultPath(e.target.value)} className="mt-1 w-full rounded-xl border border-white/10 bg-black/30 px-3 py-2.5 font-mono text-sm text-white" placeholder="~/path/to/repo" />
          </label>
          {err ? <p data-debug-id="project-detail-about-error" className="text-xs text-red-300">{err}</p> : null}
          <div className="flex gap-2">
            <button data-debug-id="project-detail-save-btn" type="button" disabled={updateState.isLoading} onClick={save} className="rounded-xl bg-sky-400 px-4 py-2 text-sm font-bold text-black hover:bg-sky-300 disabled:opacity-50">{updateState.isLoading ? 'Saving…' : 'Save'}</button>
            <button data-debug-id="project-detail-cancel-btn" type="button" onClick={() => { setEditing(false); setErr(''); }} className="rounded-xl border border-white/10 px-4 py-2 text-sm text-zinc-300 hover:bg-white/10">Cancel</button>
          </div>
        </div>
      )}
    </Card>
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

function bridgeIsOnline(b: any): boolean { return str(b?.status || b?.state || 'online').toLowerCase() === 'online'; }

function BridgePathsPanel({ projectId, project, bridges }: { projectId: string; project: Project | null; bridges: any[] }) {
  const [updateProject, updateState] = useUpdateProjectMutation();
  const [setBridgePath] = useSetProjectBridgePathMutation();
  const [deleteBridgePath] = useDeleteProjectBridgePathMutation();

  const defaultPath = str(project?.default_path);
  const overrides = useMemo(() => {
    const map = new Map<string, string>();
    for (const bp of (project?.bridge_paths || [])) map.set(str(bp.bridge_id), str(bp.path));
    return map;
  }, [project?.bridge_paths]);

  // Effective path for a bridge = its override, else the project default.
  const effectivePath = (bid: string) => overrides.get(bid) || defaultPath;

  const onlineBridges = useMemo(() => bridges.filter(bridgeIsOnline), [bridges]);

  // Default-path editor.
  const [defaultDraft, setDefaultDraft] = useState(defaultPath);
  const [defaultErr, setDefaultErr] = useState('');
  useEffect(() => { setDefaultDraft(defaultPath); }, [defaultPath]);
  async function saveDefault() {
    setDefaultErr('');
    try {
      await updateProject({ projectId, default_path: defaultDraft.trim() }).unwrap();
    } catch (e: any) { setDefaultErr(str(e?.data?.error?.message || e?.error || e?.message) || 'Save failed'); }
  }

  // Per-bridge existence probe (stat) — one call per online bridge.
  const [statFor] = useLazyStatBridgePathQuery();
  const [statByBridge, setStatByBridge] = useState<Record<string, { loading: boolean; exists?: boolean; error?: string }>>({});
  async function probe(bid: string) {
    const path = effectivePath(bid);
    if (!path) { setStatByBridge((s) => ({ ...s, [bid]: { loading: false, error: 'no path' } })); return; }
    setStatByBridge((s) => ({ ...s, [bid]: { loading: true } }));
    try {
      const res = await statFor({ bridgeId: bid, path }).unwrap();
      setStatByBridge((s) => ({ ...s, [bid]: { loading: false, exists: Boolean(res.exists && res.is_dir), error: res.ok ? '' : str(res.error?.message) } }));
    } catch (e: any) {
      setStatByBridge((s) => ({ ...s, [bid]: { loading: false, error: str(e?.error || e?.message) || 'bridge unavailable' } }));
    }
  }
  // Probe all online bridges whenever the set of bridges or the paths change.
  useEffect(() => {
    for (const b of onlineBridges) void probe(bridgeId(b));
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [onlineBridges.map(bridgeId).join(','), defaultPath, Array.from(overrides.entries()).map(([k, v]) => `${k}:${v}`).join(',')]);

  // Which bridge's override picker is open.
  const [pickerBridge, setPickerBridge] = useState('');

  async function applyOverride(bid: string, path: string) {
    try {
      await setBridgePath({ projectId, bridgeId: bid, path }).unwrap();
      setPickerBridge('');
    } catch { /* surfaced via re-probe */ }
  }
  async function resetToDefault(bid: string) {
    try { await deleteBridgePath({ projectId, bridgeId: bid }).unwrap(); } catch { /* ignore */ }
  }

  return (
    <Card title="Working directory" debugId="project-detail-bridge-paths">
      {/* Default path — not tied to any bridge. */}
      <div className="mb-4">
        <label className="block text-[11px] font-semibold uppercase tracking-[0.14em] text-zinc-500">Default path (all devices)</label>
        <p className="mt-1 text-xs text-zinc-500">Used on every device unless overridden below. e.g. <span className="font-mono text-zinc-400">~/projects/my-app</span></p>
        <div className="mt-2 flex gap-2">
          <input data-debug-id="project-detail-default-path-input" value={defaultDraft} onChange={(e) => setDefaultDraft(e.target.value)} placeholder="~/path/to/project" className="min-w-0 flex-1 rounded-xl border border-white/10 bg-black/30 px-3 py-2.5 font-mono text-sm text-white" />
          <button data-debug-id="project-detail-default-path-save-btn" type="button" disabled={updateState.isLoading || defaultDraft.trim() === defaultPath} onClick={saveDefault} className="shrink-0 rounded-xl bg-sky-400 px-4 text-sm font-bold text-black hover:bg-sky-300 disabled:opacity-40">Save</button>
        </div>
        {defaultErr ? <p data-debug-id="project-detail-default-path-error" className="mt-1 text-xs text-red-300">{defaultErr}</p> : null}
      </div>

      {/* Per-device presence + overrides. */}
      <label className="block text-[11px] font-semibold uppercase tracking-[0.14em] text-zinc-500">Devices</label>
      <p className="mt-1 mb-2 text-xs text-zinc-500">Whether the effective path is present on each online device.</p>
      {onlineBridges.length === 0 ? (
        <div data-debug-id="project-detail-bridge-paths-empty" className="text-sm text-zinc-500">No online devices to check.</div>
      ) : (
        <div className="space-y-1.5">
          {onlineBridges.map((b) => {
            const bid = bridgeId(b);
            const path = effectivePath(bid);
            const overridden = overrides.has(bid);
            const st = statByBridge[bid] || { loading: true };
            const isOpen = pickerBridge === bid;
            return (
              <div key={bid} data-debug-id={`project-detail-bridge-path-row-${bid}`} className="rounded-lg border border-white/[0.06] bg-black/20">
                <div className="flex items-center gap-3 px-3 py-2">
                  <span className="shrink-0 rounded-md bg-white/[0.06] px-2 py-0.5 text-[11px] font-semibold text-zinc-300">{bridgeLabel(b)}</span>
                  <span className="min-w-0 flex-1 truncate font-mono text-[12px] text-zinc-300" title={path}>{path || <span className="not-italic text-zinc-600">no path</span>}</span>
                  {overridden ? <span className="shrink-0 rounded bg-sky-400/15 px-1.5 py-0.5 text-[9px] font-bold text-sky-300">override</span> : null}
                  {/* presence indicator */}
                  {st.loading ? (
                    <span data-debug-id={`project-detail-bridge-path-status-${bid}`} className="shrink-0 text-[11px] text-zinc-500">checking…</span>
                  ) : st.error ? (
                    <span data-debug-id={`project-detail-bridge-path-status-${bid}`} className="shrink-0 text-[11px] text-amber-400">{st.error}</span>
                  ) : st.exists ? (
                    <span data-debug-id={`project-detail-bridge-path-status-${bid}`} className="shrink-0 text-[11px] font-semibold text-emerald-400">present</span>
                  ) : (
                    <span data-debug-id={`project-detail-bridge-path-status-${bid}`} className="shrink-0 text-[11px] font-semibold text-red-400">not present</span>
                  )}
                  {/* actions */}
                  {!st.loading && !st.exists && !st.error && path ? (
                    <CreateOnBridgeButton bridgeId={bid} path={path} onDone={() => void probe(bid)} />
                  ) : null}
                  <button data-debug-id={`project-detail-bridge-path-override-${bid}`} type="button" onClick={() => setPickerBridge(isOpen ? '' : bid)} className="shrink-0 rounded-md border border-white/10 px-2 py-1 text-[11px] text-zinc-300 hover:bg-white/10">{isOpen ? 'Close' : 'Override'}</button>
                  {overridden ? <button data-debug-id={`project-detail-bridge-path-reset-${bid}`} type="button" onClick={() => resetToDefault(bid)} className="shrink-0 rounded-md p-1 text-zinc-500 hover:bg-white/10 hover:text-red-300" title="Reset to default"><Icon name="close" size={14} /></button> : null}
                </div>
                {isOpen ? (
                  <div className="border-t border-white/[0.06] p-2">
                    <BridgeDirectoryPicker
                      debugId={`project-detail-bridge-picker-${bid}`}
                      bridgeId={bid}
                      bridgeLabel={bridgeLabel(b)}
                      initialPath={path}
                      onPick={(p) => void applyOverride(bid, p)}
                      onClose={() => setPickerBridge('')}
                    />
                  </div>
                ) : null}
              </div>
            );
          })}
        </div>
      )}
    </Card>
  );
}

// CreateOnBridgeButton mkdir's the effective path on a bridge, then triggers a re-probe.
function CreateOnBridgeButton({ bridgeId, path, onDone }: { bridgeId: string; path: string; onDone: () => void }) {
  const [mkdir, state] = useMkdirBridgePathMutation();
  return (
    <button
      data-debug-id={`project-detail-bridge-path-create-${bridgeId}`}
      type="button"
      disabled={state.isLoading}
      onClick={async () => { try { await mkdir({ bridgeId, path }).unwrap(); } catch { /* ignore */ } onDone(); }}
      className="shrink-0 rounded-md border border-emerald-400/30 px-2 py-1 text-[11px] font-semibold text-emerald-200 hover:bg-emerald-400/10 disabled:opacity-50"
    >
      {state.isLoading ? 'Creating…' : 'Create'}
    </button>
  );
}
