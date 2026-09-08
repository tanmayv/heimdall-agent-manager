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
import {
  useListBridgeFigWorkspacesQuery,
  useCreateBridgeFigWorkspaceMutation,
  type FigWorkspace,
} from '../../api/endpoints/bridgeFig';
import { buildRouteHash, getRouteSearch } from '../../utils/appLocation';
import Icon from '../Icon';
import BridgeDirectoryPicker from '../BridgeDirectoryPicker';
import FigDirectoryPicker from '../FigDirectoryPicker';

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
  const [projectType, setProjectType] = useState<'local' | 'fig'>('local');
  const [name, setName] = useState('');
  const [defaultPath, setDefaultPath] = useState('');
  const [createError, setCreateError] = useState('');

  // CitC / Fig state for Create
  const [selectedBridgeId, setSelectedBridgeId] = useState('');
  const [workspaceName, setWorkspaceName] = useState('');
  const [relativePath, setRelativePath] = useState('');
  const [showLocationModal, setShowLocationModal] = useState(false);
  const [pickerTab, setPickerTab] = useState<'local' | 'fig'>('local');
  const [showFigPicker, setShowFigPicker] = useState(false);
  const [showLocalPicker, setShowLocalPicker] = useState(false);
  const [showNewWorkspaceModal, setShowNewWorkspaceModal] = useState(false);
  const [newWorkspaceName, setNewWorkspaceName] = useState('');
  const [newWorkspaceError, setNewWorkspaceError] = useState('');
  const [creatingWorkspace, setCreatingWorkspace] = useState(false);

  const bridgesQuery = useListBridgesQuery();
  const bridges: any[] = (bridgesQuery.data?.bridges || []).filter(
    (b: any) => str(b?.status || b?.state || 'online').toLowerCase() !== 'revoked'
  );

  useEffect(() => {
    if (!selectedBridgeId && bridges.length > 0) {
      const online = bridges.find(bridgeIsOnline);
      setSelectedBridgeId(bridgeId(online || bridges[0]));
    }
  }, [bridges, selectedBridgeId]);

  const figWorkspacesQuery = useListBridgeFigWorkspacesQuery(
    { bridgeId: selectedBridgeId },
    { skip: !selectedBridgeId || projectType !== 'fig' }
  );
  const figWorkspaces: FigWorkspace[] = figWorkspacesQuery.data?.workspaces || [];
  const [createBridgeFigWorkspace] = useCreateBridgeFigWorkspaceMutation();

  const selectedBridge = useMemo(
    () => bridges.find((b) => bridgeId(b) === selectedBridgeId) || null,
    [bridges, selectedBridgeId]
  );
  const isSelectedBridgeOffline = selectedBridge ? !bridgeIsOnline(selectedBridge) : false;
  const figWorkspacesError = useMemo(() => {
    if (figWorkspacesQuery.isError) {
      const err: any = figWorkspacesQuery.error;
      return err?.data?.error?.message || err?.error || err?.message || 'Bridge is offline or unreachable (409 Conflict)';
    }
    if (isSelectedBridgeOffline) {
      return `Bridge ${bridgeLabel(selectedBridge)} (${selectedBridgeId}) is currently offline. CitC discovery requires an active ham-bridge daemon.`;
    }
    return '';
  }, [figWorkspacesQuery.isError, figWorkspacesQuery.error, isSelectedBridgeOffline, selectedBridge, selectedBridgeId]);

  const projects: Project[] = useMemo(() => (projectsQuery.data?.projects || projectsQuery.data || []) as Project[], [projectsQuery.data]);
  const filtered = useMemo(() => {
    const q = query.trim().toLowerCase();
    if (!q) return projects;
    return projects.filter((p) => [p.name, p.project_id, p.default_path, p.workspace_name, p.relative_path].filter(Boolean).join(' ').toLowerCase().includes(q));
  }, [projects, query]);

  async function handleCreateWorkspace() {
    const ws = newWorkspaceName.trim();
    if (!ws || !selectedBridgeId) return;
    setNewWorkspaceError('');
    setCreatingWorkspace(true);
    try {
      const res = await createBridgeFigWorkspace({ bridgeId: selectedBridgeId, name: ws }).unwrap();
      if (!res.ok) {
        setNewWorkspaceError(res.message || res.error_code || 'Failed to create CitC workspace');
        return;
      }
      setWorkspaceName(ws);
      if (!name.trim()) setName(ws);
      setNewWorkspaceName('');
      setShowNewWorkspaceModal(false);
    } catch (err: any) {
      setNewWorkspaceError(err?.data?.error?.message || err?.error || err?.message || 'Workspace creation failed');
    } finally {
      setCreatingWorkspace(false);
    }
  }

  async function submitCreate() {
    setCreateError('');
    if (!name.trim()) { setCreateError('Name is required.'); return; }
    if (projectType === 'local' && !defaultPath.trim()) { setCreateError('Default path is required.'); return; }
    if (projectType === 'fig' && !workspaceName.trim()) { setCreateError('CitC workspace name is required.'); return; }
    try {
      await createProject({
        name: name.trim(),
        default_path: projectType === 'fig' ? (defaultPath.trim() || undefined) : defaultPath.trim(),
        project_type: projectType,
        workspace_name: projectType === 'fig' ? workspaceName.trim() : undefined,
        relative_path: projectType === 'fig' ? relativePath.trim() || undefined : undefined,
        vcs_kind: projectType === 'fig' ? 'piper' : undefined,
      }).unwrap();
      setName('');
      setDefaultPath('');
      setWorkspaceName('');
      setRelativePath('');
      setShowLocationModal(false);
      setShowFigPicker(false);
      setShowLocalPicker(false);
      setProjectType('local');
      setShowCreate(false);
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
            <label className="block text-[11px] font-semibold uppercase tracking-[0.14em] text-zinc-500">Name *
              <input
                data-debug-id="projects-create-name-input"
                value={name}
                onChange={(e) => setName(e.target.value)}
                className="mt-1 w-full rounded-xl border border-white/10 bg-black/30 px-3 py-2.5 text-sm text-white outline-none focus:border-sky-400"
                placeholder="e.g. website-rewrite or cloudtop-agent"
              />
            </label>

            <div>
              <label className="block text-[11px] font-semibold uppercase tracking-[0.14em] text-zinc-500 mb-1">
                Project Location / Path *
              </label>
              <div className="rounded-xl border border-white/10 bg-[#121214] p-2.5 flex items-center justify-between gap-3 min-h-[46px]">
                <div className="min-w-0 flex-1">
                  {(projectType === 'local' && defaultPath) || (projectType === 'fig' && workspaceName) ? (
                    <div>
                      <div className="flex items-center gap-2">
                        <Icon
                          name="folder"
                          size={14}
                          className={projectType === 'fig' ? 'text-amber-400 shrink-0' : 'text-sky-400 shrink-0'}
                        />
                        <span className="font-mono text-xs font-semibold text-zinc-200 truncate">
                          {projectType === 'fig' ? workspaceName : defaultPath}
                        </span>
                        <span className="rounded bg-white/[0.08] px-1.5 py-0.5 text-[10px] font-semibold text-zinc-300 border border-white/10">
                          {projectType === 'fig' ? 'CitC' : 'Local'}
                        </span>
                      </div>
                      {projectType === 'fig' ? (
                        <div className="mt-0.5 text-[11px] font-mono text-zinc-400 truncate">
                          /google/src/cloud/…/{workspaceName}/google3{relativePath ? `/${relativePath}` : ''}
                        </div>
                      ) : null}
                    </div>
                  ) : (
                    <div>
                      <div className="text-xs font-semibold text-zinc-300">No Location Selected</div>
                      <div className="text-[11px] text-zinc-500">Pick a local directory or CitC workspace</div>
                    </div>
                  )}
                </div>
                <button
                  data-debug-id="projects-create-browse-btn"
                  id="projects-create-fig-browse-btn"
                  type="button"
                  disabled={!selectedBridgeId}
                  onClick={() => {
                    setPickerTab(projectType === 'fig' ? 'fig' : 'local');
                    setShowLocationModal(true);
                  }}
                  className="shrink-0 rounded-lg border border-white/10 bg-white/[0.05] hover:bg-white/[0.1] px-3.5 py-1.5 text-xs font-semibold text-zinc-200 transition disabled:opacity-40"
                >
                  {(projectType === 'local' && defaultPath) || (projectType === 'fig' && workspaceName)
                    ? 'Change Location…'
                    : 'Browse…'}
                </button>
              </div>
            </div>
          </div>

          {/* Preserved form fields for compatibility */}
          <input
            type="hidden"
            data-debug-id="projects-create-path-input"
            value={defaultPath}
          />
          <input
            type="hidden"
            data-debug-id="projects-create-fig-relative-path-input"
            value={relativePath}
          />
          <select
            data-debug-id="projects-create-fig-workspace-select"
            value={workspaceName}
            disabled={Boolean(figWorkspacesError && figWorkspaces.length === 0)}
            onChange={(e) => {
              const ws = e.target.value;
              setWorkspaceName(ws);
              if (!name.trim() && ws) setName(ws);
            }}
            className="hidden"
            aria-hidden="true"
          >
            <option value="">
              {figWorkspacesQuery.isLoading
                ? 'Loading CitC workspaces…'
                : figWorkspacesError
                ? '-- CitC Bridge Offline --'
                : '-- Select CitC Workspace --'}
            </option>
            {workspaceName ? <option value={workspaceName}>{workspaceName}</option> : null}
            {figWorkspaces.map((ws) => (
              <option key={ws.name} value={ws.name}>
                {ws.name} {ws.has_google3 ? '✓ (google3)' : ''}
              </option>
            ))}
          </select>

          {createError ? <p data-debug-id="projects-create-error" className="mt-2 text-xs text-red-300">{createError}</p> : null}
          <div className="mt-3 flex gap-2">
            <button
              data-debug-id="projects-create-submit-btn"
              type="button"
              disabled={createState.isLoading || !name.trim() || (projectType === 'local' ? !defaultPath.trim() : !workspaceName.trim())}
              onClick={submitCreate}
              className="rounded-xl bg-sky-400 hover:bg-sky-300 px-4 py-2 text-sm font-bold text-black disabled:opacity-50 transition"
            >
              {createState.isLoading ? 'Creating…' : 'Create'}
            </button>
            <button
              data-debug-id="projects-create-cancel-btn"
              type="button"
              onClick={() => {
                setShowCreate(false);
                setShowLocationModal(false);
              }}
              className="rounded-xl border border-white/10 px-4 py-2 text-sm text-zinc-300 hover:bg-white/10"
            >
              Cancel
            </button>
          </div>
        </div>
      ) : null}

      {/* Unified Location Modal Popup: Local / Fig Tabs */}
      {showLocationModal ? (
        <div data-debug-id="projects-create-location-modal" className="fixed inset-0 z-50 flex items-center justify-center bg-black/70 p-4">
          <div className="w-full max-w-2xl rounded-2xl border border-white/10 bg-[#121214] p-5 shadow-2xl space-y-4">
            <div className="flex items-center justify-between gap-3">
              <div>
                <h3 className="text-base font-semibold text-white flex items-center gap-2">
                  <Icon name="folder" size={16} className="text-sky-400" />
                  <span>Choose Project Location</span>
                </h3>
                <p className="text-xs text-zinc-400 mt-0.5">
                  Select a local directory or CitC workspace on your bridge host
                </p>
              </div>
              <button
                type="button"
                onClick={() => setShowLocationModal(false)}
                aria-label="Close"
                className="rounded-lg p-1.5 text-zinc-400 hover:bg-white/10 hover:text-white transition"
              >
                <Icon name="close" size={16} />
              </button>
            </div>

            {/* Tab switch */}
            <div data-debug-id="projects-create-type-toggle" className="inline-flex rounded-xl bg-black/40 p-1 border border-white/10">
              <button
                data-debug-id="projects-create-type-local-btn"
                type="button"
                onClick={() => setPickerTab('local')}
                className={`rounded-lg px-4 py-1.5 text-xs font-semibold transition flex items-center gap-1.5 ${
                  pickerTab === 'local'
                    ? 'bg-sky-500/20 text-sky-300 border border-sky-500/40'
                    : 'text-zinc-400 hover:text-white border border-transparent'
                }`}
              >
                <Icon name="folder" size={13} className="text-sky-400" />
                <span>Local Directory</span>
              </button>
              <button
                data-debug-id="projects-create-type-fig-btn"
                type="button"
                onClick={() => setPickerTab('fig')}
                className={`rounded-lg px-4 py-1.5 text-xs font-semibold transition flex items-center gap-1.5 ${
                  pickerTab === 'fig'
                    ? 'bg-sky-500/20 text-sky-300 border border-sky-500/40'
                    : 'text-zinc-400 hover:text-white border border-transparent'
                }`}
              >
                <Icon name="folder" size={13} className="text-amber-400" />
                <span>Fig (CitC)</span>
              </button>
            </div>

            {/* Optional Bridge Select when multiple bridges exist */}
            {bridges.length > 1 ? (
              <div className="flex items-center justify-between gap-2 p-2 rounded-lg bg-black/30 border border-white/5">
                <span className="text-xs text-zinc-400">Bridge Host:</span>
                <select
                  data-debug-id="projects-create-fig-bridge-select"
                  value={selectedBridgeId}
                  onChange={(e) => setSelectedBridgeId(e.target.value)}
                  className="rounded-lg border border-white/10 bg-black/40 px-2 py-1 text-xs text-zinc-200 outline-none"
                >
                  {bridges.map((b) => (
                    <option key={bridgeId(b)} value={bridgeId(b)}>
                      {bridgeLabel(b)} ({bridgeIsOnline(b) ? '● Online' : '○ Offline'})
                    </option>
                  ))}
                </select>
              </div>
            ) : null}

            {/* Offline warning if CitC tab is active and error */}
            {pickerTab === 'fig' && figWorkspacesError ? (
              <div
                data-debug-id="projects-create-fig-offline-warning"
                className="flex items-start gap-2.5 rounded-xl border border-amber-500/40 bg-amber-500/10 p-3 text-xs text-amber-200"
              >
                <Icon name="alert" size={16} className="shrink-0 text-amber-400 mt-0.5" />
                <div className="flex-1 space-y-1">
                  <div className="font-semibold text-amber-300">
                    CitC Bridge Offline (409 Conflict)
                  </div>
                  <div>{figWorkspacesError}</div>
                </div>
                <button
                  data-debug-id="projects-create-fig-retry-btn"
                  type="button"
                  onClick={() => figWorkspacesQuery.refetch()}
                  className="shrink-0 px-2.5 py-1 text-[11px] rounded-lg border border-white/10 bg-white/[0.05] hover:bg-white/[0.1] font-medium text-zinc-200 transition"
                >
                  Retry
                </button>
              </div>
            ) : null}

            {/* Tab content */}
            {pickerTab === 'local' && selectedBridgeId ? (
              <BridgeDirectoryPicker
                debugId="projects-create-local-picker"
                bridgeId={selectedBridgeId}
                bridgeLabel={selectedBridge ? bridgeLabel(selectedBridge) : undefined}
                initialPath={defaultPath}
                onPick={(p) => {
                  setProjectType('local');
                  setDefaultPath(p);
                  if (!name.trim()) {
                    const base = p.split('/').filter(Boolean).pop();
                    if (base) setName(base);
                  }
                  setShowLocationModal(false);
                }}
                onClose={() => setShowLocationModal(false)}
              />
            ) : null}

            {pickerTab === 'fig' && selectedBridgeId ? (
              <div data-debug-id="projects-create-fig-picker" className="space-y-2">
                <div className="flex items-center justify-between px-1">
                  <span className="text-xs text-zinc-400">CitC Workspaces</span>
                  <button
                    data-debug-id="projects-create-fig-new-workspace-btn"
                    type="button"
                    onClick={() => { setShowNewWorkspaceModal(true); setNewWorkspaceError(''); }}
                    className="text-xs text-sky-400 hover:text-sky-300 flex items-center gap-1 font-semibold transition"
                  >
                    <Icon name="plus" size={12} /> + New CitC Workspace
                  </button>
                </div>
                <FigDirectoryPicker
                  debugId="projects-create-fig-picker-inner"
                  bridgeId={selectedBridgeId}
                  workspace={workspaceName}
                  initialPath={relativePath}
                  onPick={(p, ws) => {
                    setProjectType('fig');
                    if (ws) {
                      setWorkspaceName(ws);
                      if (!name.trim()) setName(ws);
                    }
                    setRelativePath(p);
                    setShowLocationModal(false);
                  }}
                  onSelectWorkspace={(ws) => {
                    setWorkspaceName(ws);
                    if (!name.trim()) setName(ws);
                  }}
                  onClose={() => setShowLocationModal(false)}
                />
              </div>
            ) : null}
          </div>
        </div>
      ) : null}

      {/* New CitC Workspace Modal */}
      {showNewWorkspaceModal ? (
        <div data-debug-id="projects-create-fig-modal" className="fixed inset-0 z-50 flex items-center justify-center bg-black/70 p-4">
          <div className="w-full max-w-md rounded-2xl border border-white/10 bg-[#121214] p-5 shadow-2xl space-y-4">
            <h3 className="text-base font-semibold text-white flex items-center gap-2">
              <Icon name="folder" size={16} className="text-amber-400" />
              <span>Create New CitC Workspace</span>
            </h3>
            <p className="text-xs text-zinc-400">
              Runs <code className="font-mono text-zinc-300">g4 citc -q --head &lt;name&gt;</code> on the bridge host to create a fresh CitC client.
            </p>
            <div>
              <label className="block text-xs font-medium text-zinc-300 mb-1">Workspace Name *</label>
              <input
                data-debug-id="projects-create-fig-modal-name-input"
                value={newWorkspaceName}
                onChange={(e) => setNewWorkspaceName(e.target.value)}
                placeholder="e.g. feat-mobile-sync"
                className="w-full rounded-xl border border-white/10 bg-black/40 px-3 py-2 text-sm text-white outline-none focus:border-sky-500 font-mono"
              />
            </div>
            {newWorkspaceError ? (
              <p className="text-xs text-red-400">{newWorkspaceError}</p>
            ) : null}
            <div className="flex justify-end gap-2 pt-2">
              <button
                data-debug-id="projects-create-fig-modal-cancel-btn"
                type="button"
                onClick={() => { setShowNewWorkspaceModal(false); setNewWorkspaceError(''); }}
                className="rounded-xl bg-zinc-800 hover:bg-zinc-700 px-4 py-2 text-xs font-medium text-zinc-300 transition"
              >
                Cancel
              </button>
              <button
                data-debug-id="projects-create-fig-modal-submit-btn"
                type="button"
                disabled={!newWorkspaceName.trim() || creatingWorkspace}
                onClick={handleCreateWorkspace}
                className="rounded-xl bg-sky-600 hover:bg-sky-500 px-4 py-2 text-xs font-bold text-white transition disabled:opacity-50"
              >
                {creatingWorkspace ? 'Creating…' : 'Create Workspace'}
              </button>
            </div>
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
        ) : filtered.map((p) => {
          const isFig = p.project_type === 'fig';
          return (
            <a
              key={p.project_id}
              data-debug-id={`projects-row-${p.project_id}`}
              href={buildRouteHash('/projects', `projectId=${encodeURIComponent(p.project_id)}`)}
              className="flex items-center gap-3 px-4 py-3 hover:bg-white/[0.05]"
            >
              <span className={`grid h-9 w-9 shrink-0 place-items-center rounded-xl text-sm font-black text-black ${
                isFig ? 'bg-gradient-to-br from-amber-400 to-orange-500' : 'bg-gradient-to-br from-sky-400/80 to-violet-400/80'
              }`}>
                {(p.name || '?').slice(0, 1).toUpperCase()}
              </span>
              <span className="min-w-0 flex-1">
                <span className="flex items-center gap-2">
                  <span className="truncate text-sm font-semibold text-zinc-100">{p.name || p.project_id}</span>
                  {isFig ? (
                    <span className="rounded-full border border-amber-400/30 bg-amber-400/10 px-2 py-0.5 text-[9px] font-bold text-amber-300">
                      Fig (CitC)
                    </span>
                  ) : null}
                </span>
                {isFig && p.workspace_name ? (
                  <span className="block truncate font-mono text-[11px] text-amber-300/80">
                    {p.workspace_name}{p.relative_path ? ` · google3/${p.relative_path}` : ' · google3'}
                  </span>
                ) : p.default_path ? (
                  <span className="block truncate font-mono text-[11px] text-zinc-500">{p.default_path}</span>
                ) : null}
              </span>
              <Icon name="chevron-right" size={16} className="shrink-0 text-zinc-600" />
            </a>
          );
        })}
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
  const memoryQuery = useListMemoriesQuery({ projectIds: projectId ? [projectId] : [] });
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
          <AboutPanel projectId={projectId} project={project} bridges={bridges} />
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

function AboutPanel({ projectId, project, bridges = [] }: { projectId: string; project: Project | null; bridges?: any[] }) {
  const [updateProject, updateState] = useUpdateProjectMutation();
  const [editing, setEditing] = useState(false);
  const [name, setName] = useState('');
  const [description, setDescription] = useState('');
  const [defaultPath, setDefaultPath] = useState('');
  const [workspaceName, setWorkspaceName] = useState('');
  const [relativePath, setRelativePath] = useState('');
  const [projectType, setProjectType] = useState('local');
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
    setWorkspaceName(str(project.workspace_name));
    setRelativePath(str(project.relative_path));
    setProjectType(str(project.project_type || 'local'));
    setShowLocalPicker(false);
  }, [project?.project_id, project?.name, project?.description, project?.default_path, project?.workspace_name, project?.relative_path, project?.project_type]);

  async function save() {
    setErr('');
    try {
      await updateProject({
        projectId,
        name: name.trim(),
        description: description.trim(),
        default_path: defaultPath.trim(),
        project_type: projectType,
        workspace_name: projectType === 'fig' ? workspaceName.trim() || undefined : undefined,
        relative_path: projectType === 'fig' ? relativePath.trim() || undefined : undefined,
      }).unwrap();
      setShowLocalPicker(false);
      setEditing(false);
    } catch (e: any) {
      setErr(str(e?.data?.error?.message || e?.error || e?.message) || 'Save failed');
    }
  }

  const isFig = project?.project_type === 'fig';

  return (
    <Card title="About" debugId="project-detail-about"
      action={!editing ? (
        <button data-debug-id="project-detail-edit-btn" type="button" onClick={() => setEditing(true)} className="inline-flex items-center gap-1 rounded-lg border border-white/10 px-2 py-1 text-xs text-zinc-300 hover:bg-white/10">Edit</button>
      ) : null}>
      {!editing ? (
        <div className="space-y-2">
          <div className="flex items-center gap-2">
            <span className={`rounded-full px-2 py-0.5 text-[10px] font-bold border ${
              isFig ? 'border-amber-400/30 bg-amber-400/10 text-amber-300' : 'border-zinc-700 bg-zinc-800 text-zinc-400'
            }`}>
              {isFig ? 'Fig (CitC)' : 'Local Directory'}
            </span>
            {isFig && project?.workspace_name ? (
              <span className="font-mono text-xs text-amber-300 font-semibold">
                ws: {project.workspace_name}
              </span>
            ) : null}
          </div>
          {isFig && project?.relative_path ? (
            <p className="font-mono text-xs text-zinc-400">
              google3 relative path: <span className="text-amber-300">{project.relative_path}</span>
            </p>
          ) : null}
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
          {isFig ? (
            <div className="grid gap-3 sm:grid-cols-2 rounded-xl border border-amber-500/20 bg-amber-500/[0.04] p-3">
              <label className="block text-[11px] font-semibold uppercase tracking-[0.14em] text-amber-300">CitC Workspace
                <input value={workspaceName} onChange={(e) => setWorkspaceName(e.target.value)} className="mt-1 w-full rounded-xl border border-white/10 bg-black/40 px-3 py-2 font-mono text-xs text-white" />
              </label>
              <label className="block text-[11px] font-semibold uppercase tracking-[0.14em] text-amber-300">Relative google3 Path
                <input value={relativePath} onChange={(e) => setRelativePath(e.target.value)} placeholder="e.g. cloud/security" className="mt-1 w-full rounded-xl border border-white/10 bg-black/40 px-3 py-2 font-mono text-xs text-white" />
              </label>
            </div>
          ) : null}
          <label className="block text-[11px] font-semibold uppercase tracking-[0.14em] text-zinc-500">Description
            <textarea data-debug-id="project-detail-description-input" value={description} onChange={(e) => setDescription(e.target.value)} rows={4} placeholder="What is this project about?" className="mt-1 w-full resize-y rounded-xl border border-white/10 bg-black/30 px-3 py-2.5 text-sm leading-6 text-white placeholder:text-zinc-600" />
          </label>
          <div>
            <label className="block text-[11px] font-semibold uppercase tracking-[0.14em] text-zinc-500 mb-1">Default path</label>
            <div className="flex items-center gap-2">
              <input data-debug-id="project-detail-default-path-input" value={defaultPath} onChange={(e) => setDefaultPath(e.target.value)} className="flex-1 rounded-xl border border-white/10 bg-black/30 px-3 py-2.5 font-mono text-sm text-white" placeholder="~/path/to/repo" />
              {!isFig ? (
                <button
                  data-debug-id="project-detail-edit-local-browse-btn"
                  type="button"
                  disabled={!selectedBridgeId}
                  onClick={() => setShowLocalPicker((v) => !v)}
                  className="min-h-[42px] shrink-0 rounded-xl border border-sky-500/30 bg-sky-500/10 px-3 py-2 text-xs font-semibold text-sky-300 hover:bg-sky-500/20 disabled:opacity-40 flex items-center gap-1.5"
                >
                  <Icon name="folder" size={14} />
                  <span>{showLocalPicker ? 'Hide Browser' : 'Browse…'}</span>
                </button>
              ) : null}
            </div>
          </div>
          {!isFig && showLocalPicker && selectedBridgeId ? (
            <div className="mt-2">
              <BridgeDirectoryPicker
                debugId="project-detail-edit-local-picker"
                bridgeId={selectedBridgeId}
                initialPath={defaultPath}
                onPick={(p) => {
                  setDefaultPath(p);
                  setShowLocalPicker(false);
                }}
                onClose={() => setShowLocalPicker(false)}
              />
            </div>
          ) : null}
          {err ? <p data-debug-id="project-detail-about-error" className="text-xs text-red-300">{err}</p> : null}
          <div className="flex gap-2">
            <button data-debug-id="project-detail-save-btn" type="button" disabled={updateState.isLoading} onClick={save} className={`rounded-xl px-4 py-2 text-sm font-bold text-black disabled:opacity-50 ${isFig ? 'bg-amber-400 hover:bg-amber-300' : 'bg-sky-400 hover:bg-sky-300'}`}>{updateState.isLoading ? 'Saving…' : 'Save'}</button>
            <button data-debug-id="project-detail-cancel-btn" type="button" onClick={() => { setEditing(false); setShowLocalPicker(false); setErr(''); }} className="rounded-xl border border-white/10 px-4 py-2 text-sm text-zinc-300 hover:bg-white/10">Cancel</button>
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
                <div className="flex flex-wrap items-center gap-x-3 gap-y-1.5 px-3 py-2">
                  {/* status dot */}
                  <span
                    aria-hidden="true"
                    className={`h-2 w-2 shrink-0 rounded-full ${st.loading ? 'bg-zinc-500 animate-pulse' : st.error ? 'bg-amber-400' : st.exists ? 'bg-emerald-400' : 'bg-red-400'}`}
                  />
                  <span className="shrink-0 rounded-md bg-white/[0.06] px-2 py-0.5 text-[11px] font-semibold text-zinc-300">{bridgeLabel(b)}</span>
                  <span className={`shrink-0 rounded px-1.5 py-0.5 text-[9px] font-bold ${overridden ? 'bg-sky-400/15 text-sky-300' : 'bg-white/[0.06] text-zinc-500'}`}>{overridden ? 'override' : 'default'}</span>
                  <span className="min-w-0 flex-1 basis-full truncate font-mono text-[12px] text-zinc-400 sm:basis-0" title={path}>{path || <span className="text-zinc-600">no path set</span>}</span>
                  {/* presence label */}
                  <span data-debug-id={`project-detail-bridge-path-status-${bid}`} className={`shrink-0 text-[11px] font-semibold ${st.loading ? 'text-zinc-500' : st.error ? 'text-amber-400' : st.exists ? 'text-emerald-400' : 'text-red-400'}`}>
                    {st.loading ? 'checking…' : st.error ? st.error : st.exists ? (st.hasGit ? 'present · git' : 'present') : 'not present'}
                  </span>
                  {/* actions */}
                  {!st.loading && !st.exists && !st.error && path ? (
                    <CreateOnBridgeButton bridgeId={bid} path={path} onDone={() => void probe(bid)} />
                  ) : null}
                  <button data-debug-id={`project-detail-bridge-path-recheck-${bid}`} type="button" onClick={() => void probe(bid)} title="Re-check" aria-label="Re-check" className="shrink-0 rounded-md p-1 text-zinc-500 hover:bg-white/10 hover:text-zinc-200"><Icon name="refresh" size={13} /></button>
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
