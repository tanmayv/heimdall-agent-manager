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

import BridgeDirectoryPicker from '../BridgeDirectoryPicker';
import { Badge, Button, FormField, Icon, Input, Link, PageShell, Panel, Select, StatusDot, Text, Textarea } from '@ui';
// TODO(FIX): Replace any with strict TypeScript interface matching Odin backend schema
function str(v: any): string { return String(v ?? '').trim(); }
// TODO(FIX): Replace any with strict TypeScript interface matching Odin backend schema
// TODO(FIX): Replace loose fallback chain with canonical typed schema property
function bridgeId(b: any): string { return str(b?.bridge_id || b?.bridgeId || b?.id); }
// TODO(FIX): Replace any with strict TypeScript interface matching Odin backend schema
// TODO(FIX): Replace loose fallback chain with canonical typed schema property
function bridgeLabel(b: any): string { return str(b?.label || b?.machine_hostname || bridgeId(b)); }
function bridgeIsOnline(b: any): boolean {
  const status = str(b?.status || b?.runtime_status || b?.state || 'online').toLowerCase();
  return status === 'online' || status === 'connected';
}

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
  const bridgesQuery = useListBridgesQuery();
  const [createProject, createState] = useCreateProjectMutation();
  const [query, setQuery] = useState('');
  const [showCreate, setShowCreate] = useState(false);
  const [name, setName] = useState('');
  const [defaultPath, setDefaultPath] = useState('');
  const [showLocalPicker, setShowLocalPicker] = useState(false);
  const [selectedBridgeId, setSelectedBridgeId] = useState('');
  const [createError, setCreateError] = useState('');

  const projects: Project[] = useMemo(() => (projectsQuery.data?.projects || projectsQuery.data || []) as Project[], [projectsQuery.data]);
  const bridges: any[] = useMemo(() => (bridgesQuery.data?.bridges || []).filter((b: any) => str(b?.status || b?.state || 'online').toLowerCase() !== 'revoked'), [bridgesQuery.data]);

  useEffect(() => {
    if (!selectedBridgeId && bridges.length > 0) {
      const online = bridges.find(bridgeIsOnline);
      setSelectedBridgeId(bridgeId(online || bridges[0]));
    }
  }, [bridges, selectedBridgeId]);

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
      setName(''); setDefaultPath(''); setShowCreate(false); setShowLocalPicker(false);
    } catch (e: any) {
      setCreateError(str(e?.data?.error?.message || e?.error || e?.message) || 'Create failed');
    }
  }

  const selectedBridge = bridges.find((b) => bridgeId(b) === selectedBridgeId);

  return (
    <PageShell
      width="full"
      title="Projects"
      description="Group work by project — agents, memory and per-device paths."
      actions={
        <Button variant="primary" size="md" data-debug-id="projects-new-btn" onClick={() => setShowCreate((v) => !v)}>
          <Icon name="plus" size={16} /> New project
        </Button>
      }
    >
      <div data-debug-id="projects-surface">

      {showCreate ? (
        <Panel data-debug-id="projects-create-form" tone="raised" padding="md" className="mb-5 space-y-4">
          <div className="grid gap-3 sm:grid-cols-2">
            <FormField label="Name" required>
              <Input
                data-debug-id="projects-create-name-input"
                value={name}
                onChange={setName}
                width="full"
                placeholder="e.g. heimdall agent manager"
              />
            </FormField>
            <FormField label="Default path">
              <div className="flex items-center gap-2">
                <Input
                  data-debug-id="projects-create-path-input"
                  value={defaultPath}
                  onChange={setDefaultPath}
                  width="full"
                  className="flex-1 font-mono"
                  placeholder="~/path/to/repo"
                />
                <Button
                  data-debug-id="projects-create-local-browse-btn"
                  variant="secondary"
                  size="sm"
                  disabled={!selectedBridgeId}
                  onClick={() => setShowLocalPicker((v) => !v)}
                  leading={<Icon name="folder" size={14} />}
                >
                  {showLocalPicker ? 'Hide Browser' : 'Browse…'}
                </Button>
              </div>
            </FormField>
          </div>

          {showLocalPicker && selectedBridgeId ? (
            <div className="space-y-2 rounded-xl border border-sky-500/20 bg-sky-500/[0.04] p-3">
              {bridges.length > 1 ? (
                <div className="flex items-center gap-2 text-xs">
                  <span className="text-zinc-400">Bridge host:</span>
                  <Select
                    data-debug-id="projects-create-local-bridge-select"
                    value={selectedBridgeId}
                    onChange={(val) => setSelectedBridgeId(val)}
                  >
                    {bridges.map((b) => (
                      <option key={bridgeId(b)} value={bridgeId(b)}>
                        {bridgeLabel(b)} ({bridgeIsOnline(b) ? '● Online' : '○ Offline'})
                      </option>
                    ))}
                  </Select>
                </div>
              ) : null}
              <BridgeDirectoryPicker
                debugId="projects-create-local-picker"
                bridgeId={selectedBridgeId}
                bridgeLabel={selectedBridge ? bridgeLabel(selectedBridge) : undefined}
                initialPath={defaultPath}
                onPick={(p) => {
                  setDefaultPath(p);
                  if (!name.trim()) {
                    const base = p.split('/').filter(Boolean).pop();
                    if (base) setName(base);
                  }
                  setShowLocalPicker(false);
                }}
                onClose={() => setShowLocalPicker(false)}
              />
            </div>
          ) : null}

          {createError ? <p data-debug-id="projects-create-error" className="text-xs text-red-300">{createError}</p> : null}
          <div className="flex gap-2">
            <Button variant="primary" size="md" data-debug-id="projects-create-submit-btn" disabled={createState.isLoading} onClick={submitCreate}>{createState.isLoading ? 'Creating…' : 'Create'}</Button>
            <Button variant="secondary" size="md" data-debug-id="projects-create-cancel-btn" onClick={() => { setShowCreate(false); setShowLocalPicker(false); }}>Cancel</Button>
          </div>
        </Panel>
      ) : null}

      <Input
        type="search"
        data-debug-id="projects-search-input"
        value={query}
        onChange={setQuery}
        placeholder={`Search ${projects.length} projects…`}
        width="full"
        className="mb-3"
        leading={<Icon name="search" size={15} />}
      />

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
              {p.default_path ? <span className="block truncate font-mono text-caption text-zinc-500">{p.default_path}</span> : null}
            </span>
            <Icon name="chevron-right" size={16} className="shrink-0 text-zinc-600" />
          </a>
        ))}
      </div>
      </div>
    </PageShell>
  );
}

// ---------------------------------------------------------------------------
// Detail
// ---------------------------------------------------------------------------
function ProjectDetail({ projectId }: { projectId: string }) {
  const detailQuery = useFetchProjectQuery({ projectId }, { skip: !projectId });
  const agentsQuery = useListAgentsQuery({ projectId });
  const memoryQuery = useListMemoriesQuery({ projectIds: projectId ? [projectId] : [] });
  const bridgesQuery = useListBridgesQuery();

  const project: Project | null = detailQuery.data?.project || null;
  // TODO(FIX): Replace any with strict TypeScript interface matching Odin backend schema
  const agents: any[] = agentsQuery.data?.agents || [];
  // TODO(FIX): Replace any with strict TypeScript interface matching Odin backend schema
  const memories: any[] = memoryQuery.data?.items || [];
  // TODO(FIX): Replace any with strict TypeScript interface matching Odin backend schema
  // TODO(FIX): Replace loose fallback chain with canonical typed schema property
  const bridges: any[] = (bridgesQuery.data?.bridges || []).filter((b: any) => str(b?.status || b?.state || 'online').toLowerCase() !== 'revoked');

  return (
    <PageShell
      width="full"
      eyebrow="Project"
      title={<span data-debug-id="project-detail-title">{project?.name || projectId}</span>}
      actions={
        <Link variant="standalone" tone="muted" data-debug-id="project-detail-back-btn" href={buildRouteHash('/projects', '')} className="inline-flex items-center gap-1.5 text-sm">
          <Icon name="chevron-left" size={16} /> All projects
        </Link>
      }
    >
      <div data-debug-id="project-detail">
      <div className="grid gap-4 lg:grid-cols-2">
        <div className="lg:col-span-2">
          <AboutPanel projectId={projectId} project={project} bridges={bridges} />
        </div>
        <AgentsPanel agents={agents} loading={agentsQuery.isLoading} projectId={projectId} />
        <MemoryPanel memories={memories} loading={memoryQuery.isLoading} projectId={projectId} />
        <div className="lg:col-span-2">
          <BridgePathsPanel projectId={projectId} project={project} bridges={bridges} />
        </div>
      </div>
      </div>
    </PageShell>
  );
}

function Card({ title, count, children, debugId, action }: { title: string; count?: number; children: React.ReactNode; debugId: string; action?: React.ReactNode }) {
  const headerTitle = (
    <span>
      {title}
      {typeof count === 'number' ? <span className="ml-2 text-caption font-normal text-muted">{count}</span> : null}
    </span>
  );
  return (
    <Panel data-debug-id={debugId} title={headerTitle} actions={action} tone="raised" padding="md">
      {children}
    </Panel>
  );
}

function AboutPanel({ projectId, project, bridges = [] }: { projectId: string; project: Project | null; bridges?: any[] }) {
  const [updateProject, updateState] = useUpdateProjectMutation();
  const [editing, setEditing] = useState(false);
  const [name, setName] = useState('');
  const [description, setDescription] = useState('');
  const [defaultPath, setDefaultPath] = useState('');
  const [showLocalPicker, setShowLocalPicker] = useState(false);
  const [selectedBridgeId, setSelectedBridgeId] = useState('');
  const [err, setErr] = useState('');

  useEffect(() => {
    if (!selectedBridgeId && bridges.length > 0) {
      const online = bridges.find(bridgeIsOnline);
      setSelectedBridgeId(bridgeId(online || bridges[0]));
    }
  }, [bridges, selectedBridgeId]);

  // Seed the edit form from the loaded project whenever it (re)loads.
  useEffect(() => {
    if (!project) return;
    setName(str(project.name));
    setDescription(str(project.description));
    setDefaultPath(str(project.default_path));
    setShowLocalPicker(false);
  }, [project?.project_id, project?.name, project?.description, project?.default_path]);

  async function save() {
    setErr('');
    try {
      await updateProject({ projectId, name: name.trim(), description: description.trim(), default_path: defaultPath.trim() }).unwrap();
      setShowLocalPicker(false);
      setEditing(false);
    } catch (e: any) {
      setErr(str(e?.data?.error?.message || e?.error || e?.message) || 'Save failed');
    }
  }

  const selectedBridge = bridges.find((b) => bridgeId(b) === selectedBridgeId);

  return (
    <Card title="About" debugId="project-detail-about"
      action={!editing ? (
        <Button variant="secondary" size="sm" data-debug-id="project-detail-edit-btn" onClick={() => setEditing(true)}>Edit</Button>
      ) : null}>
      {!editing ? (
        <div className="space-y-2">
          {project?.default_path ? <p data-debug-id="project-detail-path" className="font-mono text-xs text-muted">{project.default_path}</p> : null}
          {str(project?.description) ? (
            <p data-debug-id="project-detail-description" className="max-w-2xl whitespace-pre-wrap text-sm leading-6 text-primary">{project?.description}</p>
          ) : (
            <p data-debug-id="project-detail-description-empty" className="text-sm text-muted">No description yet. <button type="button" onClick={() => setEditing(true)} className="text-accent hover:underline">Add one</button>.</p>
          )}
        </div>
      ) : (
        <div className="space-y-3">
          <FormField label="Name">
            <Input data-debug-id="project-detail-name-input" value={name} onChange={setName} width="full" />
          </FormField>
          <FormField label="Description">
            <Textarea data-debug-id="project-detail-description-input" value={description} onChange={setDescription} rows={4} placeholder="What is this project about?" width="full" />
          </FormField>
          <FormField label="Default path">
            <div className="flex items-center gap-2">
              <Input data-debug-id="project-detail-default-path-input" value={defaultPath} onChange={setDefaultPath} width="full" className="flex-1 font-mono" placeholder="~/path/to/repo" />
              <Button
                data-debug-id="project-detail-edit-local-browse-btn"
                variant="secondary"
                size="sm"
                disabled={!selectedBridgeId}
                onClick={() => setShowLocalPicker((v) => !v)}
                leading={<Icon name="folder" size={14} />}
              >
                {showLocalPicker ? 'Hide Browser' : 'Browse…'}
              </Button>
            </div>
          </FormField>
          {showLocalPicker && selectedBridgeId ? (
            <div className="space-y-2 rounded-xl border border-sky-500/20 bg-sky-500/[0.04] p-3">
              {bridges.length > 1 ? (
                <div className="flex items-center gap-2 text-xs">
                  <span className="text-zinc-400">Bridge host:</span>
                  <Select
                    value={selectedBridgeId}
                    onChange={(val) => setSelectedBridgeId(val)}
                  >
                    {bridges.map((b) => (
                      <option key={bridgeId(b)} value={bridgeId(b)}>
                        {bridgeLabel(b)} ({bridgeIsOnline(b) ? '● Online' : '○ Offline'})
                      </option>
                    ))}
                  </Select>
                </div>
              ) : null}
              <BridgeDirectoryPicker
                debugId="project-detail-edit-local-picker"
                bridgeId={selectedBridgeId}
                bridgeLabel={selectedBridge ? bridgeLabel(selectedBridge) : undefined}
                initialPath={defaultPath}
                onPick={(p) => {
                  setDefaultPath(p);
                  if (!name.trim()) {
                    const base = p.split('/').filter(Boolean).pop();
                    if (base) setName(base);
                  }
                  setShowLocalPicker(false);
                }}
                onClose={() => setShowLocalPicker(false)}
              />
            </div>
          ) : null}
          {err ? <p data-debug-id="project-detail-about-error" className="text-xs text-danger">{err}</p> : null}
          <div className="flex gap-2">
            <Button data-debug-id="project-detail-save-btn" variant="primary" size="md" disabled={updateState.isLoading} onClick={save}>{updateState.isLoading ? 'Saving…' : 'Save'}</Button>
            <Button data-debug-id="project-detail-cancel-btn" variant="secondary" size="md" onClick={() => { setEditing(false); setShowLocalPicker(false); setErr(''); }}>Cancel</Button>
          </div>
        </div>
      )}
    </Card>
  );
}

// TODO(FIX): Replace any with strict TypeScript interface matching Odin backend schema
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
            // TODO(FIX): Replace loose fallback chain with canonical typed schema property
            const id = str(a?.id || a?.agent_id || a?.agentId);
            // TODO(FIX): Replace loose fallback chain with canonical typed schema property
            const name = str(a?.name || a?.display_name || a?.displayName || id);
            // TODO(FIX): Replace loose fallback chain with canonical typed schema property
            const tier = str(a?.tier || a?.defaultTier || a?.default_tier);
            // TODO(FIX): Replace loose fallback chain with canonical typed schema property
            const instances = Number(a?.activeInstanceCount ?? a?.active_instance_count ?? 0);
            return (
              <a key={id} data-debug-id={`project-detail-agent-${id}`} href={buildRouteHash('/agents', `agentId=${encodeURIComponent(id)}`)} className="flex items-center gap-3 rounded-lg px-2 py-2 hover:bg-white/[0.05]">
                <span className="grid h-7 w-7 shrink-0 place-items-center rounded-lg bg-white/[0.06] text-caption font-bold text-zinc-300">{(name || '?').slice(0, 1).toUpperCase()}</span>
                <span className="min-w-0 flex-1 truncate text-sm text-zinc-200">{name}</span>
                {instances > 0 ? <span className="shrink-0 rounded-full bg-emerald-400/15 px-2 py-0.5 text-[10px] font-bold text-emerald-300">{instances} live</span> : null}
                {tier ? <span className="shrink-0 text-caption text-zinc-500">{tier}</span> : null}
              </a>
            );
          })}
        </div>
      )}
    </Card>
  );
}

// TODO(FIX): Replace any with strict TypeScript interface matching Odin backend schema
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
            // TODO(FIX): Replace loose fallback chain with canonical typed schema property
            const id = str(m?.memoryId || m?.memory_id || m?.id);
            // TODO(FIX): Replace loose fallback chain with canonical typed schema property
            const title = str(m?.title) || str(m?.body).slice(0, 60) || id;
            // TODO(FIX): Replace loose fallback chain with canonical typed schema property
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

// TODO(FIX): Replace any with strict TypeScript interface matching Odin backend schema
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
  const [showDefaultPicker, setShowDefaultPicker] = useState(false);
  const [defaultPickerBridgeId, setDefaultPickerBridgeId] = useState('');

  useEffect(() => {
    if (!defaultPickerBridgeId && bridges.length > 0) {
      const online = bridges.find(bridgeIsOnline);
      setDefaultPickerBridgeId(bridgeId(online || bridges[0]));
    }
  }, [bridges, defaultPickerBridgeId]);

  useEffect(() => { setDefaultDraft(defaultPath); }, [defaultPath]);
  async function saveDefault() {
    setDefaultErr('');
    try {
      await updateProject({ projectId, default_path: defaultDraft.trim() }).unwrap();
    } catch (e: any) { setDefaultErr(str(e?.data?.error?.message || e?.error || e?.message) || 'Save failed'); }
  }

  // Per-bridge existence probe (stat) — one call per online bridge.
  const [statFor] = useLazyStatBridgePathQuery();
  const [statByBridge, setStatByBridge] = useState<Record<string, { loading: boolean; exists?: boolean; hasGit?: boolean; error?: string }>>({});
  async function probe(bid: string) {
    const path = effectivePath(bid);
    if (!path) { setStatByBridge((s) => ({ ...s, [bid]: { loading: false, error: 'no path' } })); return; }
    setStatByBridge((s) => ({ ...s, [bid]: { loading: true } }));
    try {
      const res = await statFor({ bridgeId: bid, path }).unwrap();
      setStatByBridge((s) => ({ ...s, [bid]: { loading: false, exists: Boolean(res.exists && res.is_dir), hasGit: Boolean(res.has_git), error: res.ok ? '' : str(res.error?.message) } }));
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
        <label className="block text-caption font-semibold uppercase tracking-[0.14em] text-zinc-500">Default path (all devices)</label>
        <p className="mt-1 text-xs text-zinc-500">Used on every device unless overridden below. e.g. <span className="font-mono text-zinc-400">~/projects/my-app</span></p>
        <div className="mt-2 flex gap-2">
          <Input data-debug-id="project-detail-default-path-input" value={defaultDraft} onChange={setDefaultDraft} placeholder="~/path/to/project" className="min-w-0 flex-1 font-mono" />
          <Button
            data-debug-id="project-detail-default-path-browse-btn"
            variant="secondary"
            size="md"
            disabled={!defaultPickerBridgeId}
            onClick={() => setShowDefaultPicker((v) => !v)}
            leading={<Icon name="folder" size={14} />}
            className="shrink-0"
          >
            {showDefaultPicker ? 'Hide Browser' : 'Browse…'}
          </Button>
          <Button variant="primary" size="md" data-debug-id="project-detail-default-path-save-btn" disabled={updateState.isLoading || defaultDraft.trim() === defaultPath} onClick={saveDefault} className="shrink-0">Save</Button>
        </div>
        {defaultErr ? <p data-debug-id="project-detail-default-path-error" className="mt-1 text-xs text-red-300">{defaultErr}</p> : null}
        {showDefaultPicker && defaultPickerBridgeId ? (
          <div className="mt-2 rounded-xl border border-sky-500/20 bg-sky-500/[0.04] p-3 space-y-2">
            {bridges.length > 1 ? (
              <div className="flex items-center gap-2 text-xs mb-2">
                <span className="text-zinc-400">Bridge host:</span>
                <Select
                  value={defaultPickerBridgeId}
                  onChange={(val) => setDefaultPickerBridgeId(val)}
                >
                  {bridges.map((b) => (
                    <option key={bridgeId(b)} value={bridgeId(b)}>
                      {bridgeLabel(b)} ({bridgeIsOnline(b) ? '● Online' : '○ Offline'})
                    </option>
                  ))}
                </Select>
              </div>
            ) : null}
            <BridgeDirectoryPicker
              debugId="project-detail-default-path-bridge-picker"
              bridgeId={defaultPickerBridgeId}
              bridgeLabel={bridgeLabel(bridges.find((b) => bridgeId(b) === defaultPickerBridgeId))}
              initialPath={defaultDraft}
              onPick={(p) => {
                setDefaultDraft(p);
                setShowDefaultPicker(false);
              }}
              onClose={() => setShowDefaultPicker(false)}
            />
          </div>
        ) : null}
      </div>

      {/* Per-device presence + overrides. */}
      <label className="block text-caption font-semibold uppercase tracking-[0.14em] text-zinc-500">Devices</label>
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
                <div className="flex flex-wrap items-center gap-x-3 gap-y-1.5 px-3 py-2">
                  {/* status dot */}
                  <StatusDot
                    tone={st.loading ? 'pending' : st.exists ? 'success' : st.error ? 'warning' : 'neutral'}
                    pulse={st.loading}
                    label={st.loading ? 'Probing…' : st.exists ? 'Directory exists' : st.error ? 'Directory error' : 'Not found'}
                  />
                  <span className="shrink-0 rounded-md bg-white/[0.06] px-2 py-0.5 text-caption font-semibold text-zinc-300">{bridgeLabel(b)}</span>
                  <span className={`shrink-0 rounded px-1.5 py-0.5 text-[9px] font-bold ${overridden ? 'bg-sky-400/15 text-sky-300' : 'bg-white/[0.06] text-zinc-500'}`}>{overridden ? 'override' : 'default'}</span>
                  <span className="min-w-0 flex-1 basis-full truncate font-mono text-[12px] text-zinc-400 sm:basis-0" title={path}>{path || <span className="text-zinc-600">no path set</span>}</span>
                  {/* presence label */}
                  <span data-debug-id={`project-detail-bridge-path-status-${bid}`} className={`shrink-0 text-caption font-semibold ${st.loading ? 'text-zinc-500' : st.error ? 'text-amber-400' : st.exists ? 'text-emerald-400' : 'text-red-400'}`}>
                    {st.loading ? 'checking…' : st.error ? st.error : st.exists ? (st.hasGit ? 'present · git' : 'present') : 'not present'}
                  </span>
                  {/* actions */}
                  {!st.loading && !st.exists && !st.error && path ? (
                    <CreateOnBridgeButton bridgeId={bid} path={path} onDone={() => void probe(bid)} />
                  ) : null}
                  <button data-debug-id={`project-detail-bridge-path-recheck-${bid}`} type="button" onClick={() => void probe(bid)} title="Re-check" aria-label="Re-check" className="shrink-0 rounded-md p-1 text-zinc-500 hover:bg-white/10 hover:text-zinc-200"><Icon name="refresh" size={13} /></button>
                  <Button variant="secondary" size="sm" data-debug-id={`project-detail-bridge-path-override-${bid}`} onClick={() => setPickerBridge(isOpen ? '' : bid)} className="shrink-0">{isOpen ? 'Close' : 'Override'}</Button>
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
      className="shrink-0 rounded-md border border-emerald-400/30 px-2 py-1 text-caption font-semibold text-emerald-200 hover:bg-emerald-400/10 disabled:opacity-50"
    >
      {state.isLoading ? 'Creating…' : 'Create'}
    </button>
  );
}
