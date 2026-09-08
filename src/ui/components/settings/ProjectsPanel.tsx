import { useEffect, useMemo, useState } from "react";
import {
  useListProjectsQuery,
  useFetchProjectQuery,
  useCreateProjectMutation,
  useUpdateProjectMutation,
  useSetProjectBridgePathMutation,
  useDeleteProjectBridgePathMutation,
  useValidateProjectBridgePathMutation,
  type Project,
  type ProjectBridgePath,
} from "../../api/endpoints/projects";
import { useListBridgesQuery } from "../../api/endpoints/bridgeSupport";
import {
  useListBridgeFigWorkspacesQuery,
  useCreateBridgeFigWorkspaceMutation,
  type FigWorkspace,
} from "../../api/endpoints/bridgeFig";
import BridgeDirectoryPicker from "../BridgeDirectoryPicker";
import FigDirectoryPicker from "../FigDirectoryPicker";
import Icon from "../Icon";

export default function ProjectsPanel() {
  const projectsQuery = useListProjectsQuery();
  const [createProject] = useCreateProjectMutation();
  const [updateProject] = useUpdateProjectMutation();
  const [setProjectBridgePath] = useSetProjectBridgePathMutation();
  const [deleteProjectBridgePath] = useDeleteProjectBridgePathMutation();
  const [validateProjectBridgePath] = useValidateProjectBridgePathMutation();

  const bridgesQuery = useListBridgesQuery();

  // Create form state
  const [projectType, setProjectType] = useState<"local" | "fig">("local");
  const [name, setName] = useState("");
  const [description, setDescription] = useState("");
  const [repoUrl, setRepoUrl] = useState("");
  const [vcsKind, setVcsKind] = useState("git");
  const [defaultPath, setDefaultPath] = useState("");
  const [createError, setCreateError] = useState("");
  const [creating, setCreating] = useState(false);

  // CitC / Fig / Local directory state for Create
  const [selectedBridgeId, setSelectedBridgeId] = useState("");
  const [workspaceName, setWorkspaceName] = useState("");
  const [relativePath, setRelativePath] = useState("");
  const [showFigPicker, setShowFigPicker] = useState(false);
  const [showLocalPicker, setShowLocalPicker] = useState(false);
  const [showLocationModal, setShowLocationModal] = useState(false);
  const [pickerTab, setPickerTab] = useState<"local" | "fig">("local");
  const [showNewWorkspaceModal, setShowNewWorkspaceModal] = useState(false);
  const [newWorkspaceName, setNewWorkspaceName] = useState("");
  const [newWorkspaceError, setNewWorkspaceError] = useState("");
  const [creatingWorkspace, setCreatingWorkspace] = useState(false);

  const [createBridgeFigWorkspace] = useCreateBridgeFigWorkspaceMutation();

  // Selected project detail view state
  const [selectedProjectId, setSelectedProjectId] = useState<string | null>(null);
  const projectDetailQuery = useFetchProjectQuery(
    { projectId: selectedProjectId || "" },
    { skip: !selectedProjectId }
  );

  // Detail view edit form state
  const [editName, setEditName] = useState("");
  const [editDescription, setEditDescription] = useState("");
  const [editRepoUrl, setEditRepoUrl] = useState("");
  const [editVcsKind, setEditVcsKind] = useState("git");
  const [editDefaultPath, setEditDefaultPath] = useState("");
  const [editProjectType, setEditProjectType] = useState("local");
  const [editWorkspaceName, setEditWorkspaceName] = useState("");
  const [editRelativePath, setEditRelativePath] = useState("");
  const [showEditLocalPicker, setShowEditLocalPicker] = useState(false);
  const [isEditing, setIsEditing] = useState(false);
  const [editSaveError, setEditSaveError] = useState("");
  const [editSaving, setEditSaving] = useState(false);

  // Per-bridge custom path inputs state: bridgeId -> path string
  const [bridgePathInputs, setBridgePathInputs] = useState<Record<string, string>>({});
  const [bridgeActionError, setBridgeActionError] = useState<Record<string, string>>({});
  const [bridgeActionBusy, setBridgeActionBusy] = useState<Record<string, string>>({});

  const projects: Project[] = projectsQuery.data?.projects || [];
  const selectedProject: Project | null = projectDetailQuery.data?.project || null;
  const bridgePaths: ProjectBridgePath[] = projectDetailQuery.data?.bridge_paths || selectedProject?.bridge_paths || [];
  const bridges: any[] = bridgesQuery.data?.bridges || [];

  // Default selectedBridgeId to first online bridge (or first bridge)
  useEffect(() => {
    if (!selectedBridgeId && bridges.length > 0) {
      const online = bridges.find((b) => {
        const s = String(b?.status || b?.runtime_status || "").toLowerCase();
        return s === "online" || s === "connected";
      });
      setSelectedBridgeId(String(online?.bridge_id || online?.bridgeId || online?.id || bridges[0]?.bridge_id || bridges[0]?.bridgeId || bridges[0]?.id || ""));
    }
  }, [bridges, selectedBridgeId]);

  const figWorkspacesQuery = useListBridgeFigWorkspacesQuery(
    { bridgeId: selectedBridgeId },
    { skip: !selectedBridgeId || (projectType !== "fig" && (!showLocationModal || pickerTab !== "fig")) }
  );
  const figWorkspaces: FigWorkspace[] = figWorkspacesQuery.data?.workspaces || [];

  const isBridgeOnline = (b: any) => {
    const s = String(b?.status || b?.runtime_status || "").toLowerCase();
    return s === "online" || s === "connected";
  };
  const selectedBridge = useMemo(
    () => bridges.find((b) => String(b?.bridge_id || b?.bridgeId || b?.id || "") === selectedBridgeId) || null,
    [bridges, selectedBridgeId]
  );
  const isSelectedBridgeOffline = selectedBridge ? !isBridgeOnline(selectedBridge) : false;
  const figWorkspacesError = useMemo(() => {
    if (figWorkspacesQuery.isError) {
      const err: any = figWorkspacesQuery.error;
      return err?.data?.error?.message || err?.error || err?.message || "Bridge is offline or unreachable (409 Conflict)";
    }
    if (isSelectedBridgeOffline) {
      return `Bridge ${selectedBridge?.label || selectedBridgeId} is currently offline. CitC discovery requires an active ham-bridge daemon.`;
    }
    return "";
  }, [figWorkspacesQuery.isError, figWorkspacesQuery.error, isSelectedBridgeOffline, selectedBridge, selectedBridgeId]);

  // Update edit form state when selected project changes
  useEffect(() => {
    if (selectedProject) {
      setEditName(selectedProject.name || "");
      setEditDescription(selectedProject.description || "");
      setEditRepoUrl(selectedProject.repo_url || "");
      setEditVcsKind(selectedProject.vcs_kind || (selectedProject.project_type === "fig" ? "piper" : "git"));
      setEditDefaultPath(selectedProject.default_path || "");
      setEditProjectType(selectedProject.project_type || "local");
      setEditWorkspaceName(selectedProject.workspace_name || "");
      setEditRelativePath(selectedProject.relative_path || "");
      setShowEditLocalPicker(false);
      setEditSaveError("");
      setBridgePathInputs({});
      setBridgeActionError({});
      setBridgeActionBusy({});
    }
  }, [selectedProject]);

  async function handleCreateWorkspace() {
    const ws = newWorkspaceName.trim();
    if (!ws || !selectedBridgeId) return;
    setNewWorkspaceError("");
    setCreatingWorkspace(true);
    try {
      const res = await createBridgeFigWorkspace({ bridgeId: selectedBridgeId, name: ws }).unwrap();
      if (!res.ok) {
        setNewWorkspaceError(res.message || res.error_code || "Failed to create CitC workspace");
        return;
      }
      setWorkspaceName(ws);
      if (!name.trim()) setName(ws);
      setNewWorkspaceName("");
      setShowNewWorkspaceModal(false);
    } catch (err: any) {
      setNewWorkspaceError(err?.data?.error?.message || err?.error || err?.message || "Workspace creation failed");
    } finally {
      setCreatingWorkspace(false);
    }
  }

  async function handleCreateProject(e?: React.FormEvent) {
    if (e) e.preventDefault();
    if (!name.trim()) return;
    if (projectType === "local" && !defaultPath.trim()) return;
    if (projectType === "fig" && !workspaceName.trim()) {
      setCreateError("CitC workspace name is required");
      return;
    }
    setCreateError("");
    setCreating(true);
    try {
      await createProject({
        name: name.trim(),
        description: description.trim() || undefined,
        repo_url: repoUrl.trim() || undefined,
        vcs_kind: projectType === "fig" ? "piper" : vcsKind,
        default_path: projectType === "fig" ? (defaultPath.trim() || undefined) : defaultPath.trim(),
        project_type: projectType,
        workspace_name: projectType === "fig" ? workspaceName.trim() : undefined,
        relative_path: projectType === "fig" ? relativePath.trim() || undefined : undefined,
      }).unwrap();
      setName("");
      setDescription("");
      setRepoUrl("");
      setVcsKind("git");
      setDefaultPath("");
      setWorkspaceName("");
      setRelativePath("");
      setShowLocationModal(false);
      setShowFigPicker(false);
      setShowLocalPicker(false);
      setProjectType("local");
    } catch (err: any) {
      const msg = err?.data?.error?.message || err?.error || err?.message || String(err || "Unable to create project");
      setCreateError(msg);
    } finally {
      setCreating(false);
    }
  }

  async function handleSaveProject() {
    if (!selectedProjectId || !editName.trim()) return;
    if (editProjectType === "local" && !editDefaultPath.trim()) return;
    if (editProjectType === "fig" && !editWorkspaceName.trim()) {
      setEditSaveError("CitC workspace name is required");
      return;
    }
    setEditSaveError("");
    setEditSaving(true);
    try {
      await updateProject({
        projectId: selectedProjectId,
        name: editName.trim(),
        description: editDescription.trim() || undefined,
        repo_url: editRepoUrl.trim() || undefined,
        vcs_kind: editProjectType === "fig" ? "piper" : editVcsKind,
        default_path: editDefaultPath.trim() || undefined,
        project_type: editProjectType,
        workspace_name: editProjectType === "fig" ? editWorkspaceName.trim() : undefined,
        relative_path: editProjectType === "fig" ? editRelativePath.trim() || undefined : undefined,
      }).unwrap();
      setShowEditLocalPicker(false);
      setIsEditing(false);
    } catch (err: any) {
      const msg = err?.data?.error?.message || err?.error || err?.message || String(err || "Unable to update project");
      setEditSaveError(msg);
    } finally {
      setEditSaving(false);
    }
  }

  async function handleSaveBridgePath(bridgeId: string, currentDefaultPath: string, existingOverridePath?: string) {
    if (!selectedProjectId) return;
    const currentPath = existingOverridePath || currentDefaultPath;
    const pathValue = (bridgePathInputs[bridgeId] !== undefined ? bridgePathInputs[bridgeId] : currentPath).trim();
    if (!pathValue) return;
    setBridgeActionError((prev) => ({ ...prev, [bridgeId]: "" }));
    setBridgeActionBusy((prev) => ({ ...prev, [bridgeId]: "save" }));
    try {
      await setProjectBridgePath({
        projectId: selectedProjectId,
        bridgeId,
        path: pathValue,
      }).unwrap();
    } catch (err: any) {
      const msg = err?.error || err?.message || String(err || "Save failed");
      setBridgeActionError((prev) => ({ ...prev, [bridgeId]: msg }));
    } finally {
      setBridgeActionBusy((prev) => ({ ...prev, [bridgeId]: "" }));
    }
  }

  async function handleSetBridgePath(bridgeId: string, defaultPathValue: string) {
    if (!selectedProjectId) return;
    const pathValue = (defaultPathValue || "").trim();
    if (!pathValue) return;
    setBridgeActionError((prev) => ({ ...prev, [bridgeId]: "" }));
    setBridgeActionBusy((prev) => ({ ...prev, [bridgeId]: "set" }));
    try {
      await setProjectBridgePath({
        projectId: selectedProjectId,
        bridgeId,
        path: pathValue,
      }).unwrap();
    } catch (err: any) {
      const msg = err?.error || err?.message || String(err || "Set failed");
      setBridgeActionError((prev) => ({ ...prev, [bridgeId]: msg }));
    } finally {
      setBridgeActionBusy((prev) => ({ ...prev, [bridgeId]: "" }));
    }
  }

  async function handleValidateBridgePath(bridgeId: string) {
    if (!selectedProjectId) return;
    setBridgeActionError((prev) => ({ ...prev, [bridgeId]: "" }));
    setBridgeActionBusy((prev) => ({ ...prev, [bridgeId]: "validate" }));
    try {
      await validateProjectBridgePath({
        projectId: selectedProjectId,
        bridgeId,
      }).unwrap();
    } catch (err: any) {
      const msg = err?.error || err?.message || String(err || "Validation failed");
      setBridgeActionError((prev) => ({ ...prev, [bridgeId]: msg }));
    } finally {
      setBridgeActionBusy((prev) => ({ ...prev, [bridgeId]: "" }));
    }
  }

  async function handleRemoveBridgePath(bridgeId: string) {
    if (!selectedProjectId) return;
    setBridgeActionError((prev) => ({ ...prev, [bridgeId]: "" }));
    setBridgeActionBusy((prev) => ({ ...prev, [bridgeId]: "remove" }));
    try {
      await deleteProjectBridgePath({
        projectId: selectedProjectId,
        bridgeId,
      }).unwrap();
      setBridgePathInputs((prev) => {
        const next = { ...prev };
        delete next[bridgeId];
        return next;
      });
    } catch (err: any) {
      const msg = err?.error || err?.message || String(err || "Remove failed");
      setBridgeActionError((prev) => ({ ...prev, [bridgeId]: msg }));
    } finally {
      setBridgeActionBusy((prev) => ({ ...prev, [bridgeId]: "" }));
    }
  }

  return (
    <div data-debug-id="settings-projects-panel" className="w-full max-w-4xl space-y-6 text-left">
      <div>
        <h2 className="text-xl font-semibold text-white">Projects</h2>
        <p className="mt-1 text-sm text-zinc-400">Manage projects, default workspace paths, and bridge path overrides.</p>
      </div>

      {/* Project Creation Form */}
      <div data-debug-id="settings-project-create-form" className="rounded-2xl border border-white/10 bg-white/[0.04] p-4 space-y-4">
        <div className="flex flex-wrap items-center justify-between gap-2">
          <h3 className="text-sm font-semibold text-zinc-200 uppercase tracking-wide">Create New Project</h3>
        </div>

        <form onSubmit={handleCreateProject} className="space-y-3">
          <div className="grid gap-3 sm:grid-cols-2">
            <div>
              <label className="block text-xs font-medium text-zinc-400 mb-1">Project Name *</label>
              <input
                data-debug-id="settings-project-name-input"
                value={name}
                onChange={(e) => setName(e.target.value)}
                placeholder={projectType === "fig" ? "e.g. Fig Workspace Project" : "Website Rewrite"}
                required
                className="w-full min-h-[44px] rounded-xl border border-white/10 bg-black/30 px-3 py-2 text-sm text-zinc-100 outline-none focus:border-sky-400"
              />
            </div>

            <div>
              <label className="block text-xs font-medium text-zinc-400 mb-1">
                Project Location / Path *
              </label>
              <div className="rounded-xl border border-white/10 bg-[#121214] p-2.5 flex items-center justify-between gap-3 min-h-[44px]">
                <div className="min-w-0 flex-1">
                  {(projectType === "local" && defaultPath) || (projectType === "fig" && workspaceName) ? (
                    <div>
                      <div className="flex items-center gap-2">
                        <Icon
                          name="folder"
                          size={14}
                          className={projectType === "fig" ? "text-amber-400 shrink-0" : "text-sky-400 shrink-0"}
                        />
                        <span className="font-mono text-xs font-semibold text-zinc-200 truncate">
                          {projectType === "fig" ? workspaceName : defaultPath}
                        </span>
                        <span className="rounded bg-white/[0.08] px-1.5 py-0.5 text-[10px] font-semibold text-zinc-300 border border-white/10">
                          {projectType === "fig" ? "CitC" : "Local"}
                        </span>
                      </div>
                      {projectType === "fig" ? (
                        <div className="mt-0.5 text-[11px] font-mono text-zinc-400 truncate">
                          /google/src/cloud/…/{workspaceName}/google3{relativePath ? `/${relativePath}` : ""}
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
                  data-debug-id="settings-project-browse-btn"
                  id="settings-project-fig-browse-btn"
                  type="button"
                  disabled={!selectedBridgeId}
                  onClick={() => {
                    setPickerTab(projectType === "fig" ? "fig" : "local");
                    setShowLocationModal(true);
                  }}
                  className="shrink-0 rounded-lg border border-white/10 bg-white/[0.05] hover:bg-white/[0.1] px-3.5 py-1.5 text-xs font-semibold text-zinc-200 transition disabled:opacity-40"
                >
                  {(projectType === "local" && defaultPath) || (projectType === "fig" && workspaceName)
                    ? "Change Location…"
                    : "Browse…"}
                </button>
              </div>
            </div>
          </div>

          {/* Preserved form fields for compatibility */}
          <input
            type="hidden"
            data-debug-id="settings-project-default-path-input"
            value={defaultPath}
          />
          <input
            type="hidden"
            data-debug-id="settings-project-fig-relative-path-input"
            value={relativePath}
          />
          <select
            data-debug-id="settings-project-fig-workspace-select"
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
                ? "Loading CitC workspaces…"
                : figWorkspacesError
                ? "-- CitC Bridge Offline --"
                : "-- Select CitC Workspace --"}
            </option>
            {workspaceName ? <option value={workspaceName}>{workspaceName}</option> : null}
            {figWorkspaces.map((ws) => (
              <option key={ws.name} value={ws.name}>
                {ws.name} {ws.has_google3 ? "✓ (google3)" : ""}
              </option>
            ))}
          </select>

          <div>
            <label className="block text-xs font-medium text-zinc-400 mb-1">Description</label>
            <input
              data-debug-id="settings-project-description-input"
              value={description}
              onChange={(e) => setDescription(e.target.value)}
              placeholder="Frontend migration and backend refactoring project"
              className="w-full min-h-[44px] rounded-xl border border-white/10 bg-black/30 px-3 py-2 text-sm text-zinc-100 outline-none focus:border-sky-400"
            />
          </div>

          <div className="grid gap-3 sm:grid-cols-2">
            <div>
              <label className="block text-xs font-medium text-zinc-400 mb-1">Repository URL</label>
              <input
                data-debug-id="settings-project-repo-input"
                value={repoUrl}
                onChange={(e) => setRepoUrl(e.target.value)}
                placeholder={projectType === "fig" ? "//depot/google3" : "https://github.com/org/repo"}
                className="w-full min-h-[44px] rounded-xl border border-white/10 bg-black/30 px-3 py-2 text-sm text-zinc-100 outline-none focus:border-sky-400"
              />
            </div>
            <div>
              <label className="block text-xs font-medium text-zinc-400 mb-1">VCS Kind</label>
              <select
                data-debug-id="settings-project-vcs-select"
                value={vcsKind}
                onChange={(e) => setVcsKind(e.target.value)}
                className="w-full min-h-[44px] rounded-xl border border-white/10 bg-black/30 px-3 py-2 text-sm text-zinc-100 outline-none focus:border-sky-400"
              >
                <option value="none">none</option>
                <option value="git">git</option>
                <option value="jj">jj</option>
                <option value="piper">piper</option>
              </select>
            </div>
          </div>

          {createError ? (
            <div data-debug-id="settings-project-create-error" className="rounded-xl border border-red-400/30 bg-red-500/10 px-3 py-2 text-sm text-red-100">
              {createError}
            </div>
          ) : null}

          <button
            data-debug-id="settings-project-create-btn"
            type="submit"
            disabled={!name.trim() || (projectType === "local" ? !defaultPath.trim() : !workspaceName.trim()) || creating}
            className="min-h-[44px] w-full rounded-xl bg-sky-400 hover:bg-sky-300 px-4 py-2 text-sm font-semibold text-black disabled:opacity-50 sm:w-auto transition"
          >
            {creating ? "Creating…" : "Create project"}
          </button>
        </form>
      </div>

      {/* Unified Location Modal Popup: Local / Fig Tabs */}
      {showLocationModal ? (
        <div data-debug-id="settings-project-location-modal" className="fixed inset-0 z-50 flex items-center justify-center bg-black/70 p-4">
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
            <div data-debug-id="settings-project-type-toggle" className="inline-flex rounded-xl bg-black/40 p-1 border border-white/10">
              <button
                data-debug-id="settings-project-type-local-btn"
                type="button"
                onClick={() => setPickerTab("local")}
                className={`rounded-lg px-4 py-1.5 text-xs font-semibold transition flex items-center gap-1.5 ${
                  pickerTab === "local"
                    ? "bg-sky-500/20 text-sky-300 border border-sky-500/40"
                    : "text-zinc-400 hover:text-white border border-transparent"
                }`}
              >
                <Icon name="folder" size={13} className="text-sky-400" />
                <span>Local Directory</span>
              </button>
              <button
                data-debug-id="settings-project-type-fig-btn"
                type="button"
                onClick={() => setPickerTab("fig")}
                className={`rounded-lg px-4 py-1.5 text-xs font-semibold transition flex items-center gap-1.5 ${
                  pickerTab === "fig"
                    ? "bg-sky-500/20 text-sky-300 border border-sky-500/40"
                    : "text-zinc-400 hover:text-white border border-transparent"
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
                  data-debug-id="settings-project-fig-bridge-select"
                  value={selectedBridgeId}
                  onChange={(e) => setSelectedBridgeId(e.target.value)}
                  className="rounded-lg border border-white/10 bg-black/40 px-2 py-1 text-xs text-zinc-200 outline-none"
                >
                  {bridges.map((b) => {
                    const id = String(b?.bridge_id || b?.bridgeId || b?.id || "");
                    const label = String(b?.label || b?.machine_hostname || b?.hostname || id);
                    const online = isBridgeOnline(b);
                    return (
                      <option key={id} value={id}>
                        {label} ({online ? "● Online" : "○ Offline"})
                      </option>
                    );
                  })}
                </select>
              </div>
            ) : null}

            {/* Offline warning if CitC tab is active and error */}
            {pickerTab === "fig" && figWorkspacesError ? (
              <div
                data-debug-id="settings-project-fig-offline-warning"
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
                  data-debug-id="settings-project-fig-retry-btn"
                  type="button"
                  onClick={() => figWorkspacesQuery.refetch()}
                  className="shrink-0 px-2.5 py-1 text-[11px] rounded-lg border border-white/10 bg-white/[0.05] hover:bg-white/[0.1] font-medium text-zinc-200 transition"
                >
                  Retry
                </button>
              </div>
            ) : null}

            {/* Tab content */}
            {pickerTab === "local" && selectedBridgeId ? (
              <BridgeDirectoryPicker
                debugId="settings-project-local-picker"
                bridgeId={selectedBridgeId}
                bridgeLabel={selectedBridge?.label}
                initialPath={defaultPath}
                onPick={(p) => {
                  setProjectType("local");
                  setVcsKind("git");
                  setDefaultPath(p);
                  if (!name.trim()) {
                    const base = p.split("/").filter(Boolean).pop();
                    if (base) setName(base);
                  }
                  setShowLocationModal(false);
                }}
                onClose={() => setShowLocationModal(false)}
              />
            ) : null}

            {pickerTab === "fig" && selectedBridgeId ? (
              <div data-debug-id="settings-project-fig-picker" className="space-y-2">
                <div className="flex items-center justify-between px-1">
                  <span className="text-xs text-zinc-400">CitC Workspaces</span>
                  <button
                    data-debug-id="settings-project-fig-new-workspace-btn"
                    type="button"
                    onClick={() => { setShowNewWorkspaceModal(true); setNewWorkspaceError(""); }}
                    className="text-xs text-sky-400 hover:text-sky-300 flex items-center gap-1 font-semibold transition"
                  >
                    <Icon name="plus" size={12} /> + New CitC Workspace
                  </button>
                </div>
                <FigDirectoryPicker
                  debugId="settings-project-fig-picker-inner"
                  bridgeId={selectedBridgeId}
                  workspace={workspaceName}
                  initialPath={relativePath}
                  onPick={(p, ws) => {
                    setProjectType("fig");
                    setVcsKind("piper");
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
        <div data-debug-id="settings-project-fig-modal" className="fixed inset-0 z-50 flex items-center justify-center bg-black/70 p-4">
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
                data-debug-id="settings-project-fig-modal-name-input"
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
                data-debug-id="settings-project-fig-modal-cancel-btn"
                type="button"
                onClick={() => { setShowNewWorkspaceModal(false); setNewWorkspaceError(""); }}
                className="rounded-xl bg-zinc-800 hover:bg-zinc-700 px-4 py-2 text-xs font-medium text-zinc-300 transition"
              >
                Cancel
              </button>
              <button
                data-debug-id="settings-project-fig-modal-submit-btn"
                type="button"
                disabled={!newWorkspaceName.trim() || creatingWorkspace}
                onClick={handleCreateWorkspace}
                className="rounded-xl bg-sky-600 hover:bg-sky-500 px-4 py-2 text-xs font-bold text-white transition disabled:opacity-50"
              >
                {creatingWorkspace ? "Creating…" : "Create Workspace"}
              </button>
            </div>
          </div>
        </div>
      ) : null}

      {/* Project Detail View or Project List */}
      {selectedProjectId ? (
        <div className="space-y-6">
          <div className="flex items-center justify-between border-b border-white/10 pb-3">
            <button
              type="button"
              onClick={() => { setSelectedProjectId(null); setIsEditing(false); }}
              className="text-sm text-sky-400 hover:underline flex items-center gap-1"
            >
              ← Back to all projects
            </button>
            <div className="flex items-center gap-2">
              <button
                data-debug-id={`settings-project-edit-btn-${selectedProjectId}`}
                type="button"
                onClick={() => {
                  setIsEditing((prev) => !prev);
                  setShowEditLocalPicker(false);
                }}
                className="rounded-xl border border-white/10 px-3 py-1.5 text-xs text-zinc-300 hover:bg-white/10"
              >
                {isEditing ? "Cancel Edit" : "Edit Project"}
              </button>
            </div>
          </div>

          {projectDetailQuery.isLoading ? (
            <div className="text-sm text-zinc-500">Loading project details…</div>
          ) : selectedProject ? (
            <div className="space-y-6">
              {/* Project Main Details Form / Viewer */}
              <div className="rounded-2xl border border-white/10 bg-black/20 p-4 space-y-4">
                <h3 className="text-base font-semibold text-white flex items-center justify-between">
                  <span>{selectedProject.name}</span>
                  {selectedProject.is_default_conversations ? (
                    <span className="rounded-full border border-sky-400/30 bg-sky-400/10 px-2 py-0.5 text-[10px] text-sky-300">
                      Default Project
                    </span>
                  ) : null}
                </h3>

                {isEditing ? (
                  <div className="space-y-3">
                    <div className="grid gap-3 sm:grid-cols-2">
                      <div>
                        <label className="block text-xs font-medium text-zinc-400 mb-1">Project Name</label>
                        <input
                          value={editName}
                          onChange={(e) => setEditName(e.target.value)}
                          className="w-full rounded-xl border border-white/10 bg-black/30 px-3 py-2 text-sm text-zinc-100 outline-none focus:border-sky-400"
                        />
                      </div>
                      <div>
                        <label className="block text-xs font-medium text-zinc-400 mb-1">Default Path</label>
                        <div className="flex items-center gap-2">
                          <input
                            data-debug-id={`settings-project-edit-default-path-input-${selectedProjectId}`}
                            value={editDefaultPath}
                            onChange={(e) => setEditDefaultPath(e.target.value)}
                            className="flex-1 rounded-xl border border-white/10 bg-black/30 px-3 py-2 text-sm text-zinc-100 outline-none focus:border-sky-400 font-mono"
                          />
                          {editProjectType === "local" ? (
                            <button
                              data-debug-id="settings-project-edit-local-browse-btn"
                              type="button"
                              disabled={!selectedBridgeId}
                              onClick={() => setShowEditLocalPicker((v) => !v)}
                              className="shrink-0 rounded-xl border border-sky-500/30 bg-sky-500/10 px-3 py-2 text-xs font-semibold text-sky-300 hover:bg-sky-500/20 disabled:opacity-40 flex items-center gap-1.5"
                            >
                              <Icon name="folder" size={14} />
                              <span>{showEditLocalPicker ? "Hide Browser" : "Browse…"}</span>
                            </button>
                          ) : null}
                        </div>
                      </div>
                    </div>

                    {editProjectType === "local" && showEditLocalPicker && selectedBridgeId ? (
                      <div className="rounded-xl border border-sky-500/20 bg-sky-500/[0.04] p-3">
                        <BridgeDirectoryPicker
                          debugId="settings-project-edit-local-picker"
                          bridgeId={selectedBridgeId}
                          bridgeLabel={selectedBridge?.label}
                          initialPath={editDefaultPath}
                          onPick={(p) => {
                            setEditDefaultPath(p);
                            setShowEditLocalPicker(false);
                          }}
                          onClose={() => setShowEditLocalPicker(false)}
                        />
                      </div>
                    ) : null}

                    {editProjectType === "fig" ? (
                      <div className="grid gap-3 sm:grid-cols-2 rounded-xl border border-white/10 bg-white/[0.02] p-3">
                        <div>
                          <label className="block text-xs font-medium text-zinc-400 mb-1">CitC Workspace</label>
                          <input
                            value={editWorkspaceName}
                            onChange={(e) => setEditWorkspaceName(e.target.value)}
                            className="w-full rounded-xl border border-white/10 bg-black/40 px-3 py-2 text-sm text-zinc-100 outline-none focus:border-sky-400 font-mono"
                          />
                        </div>
                        <div>
                          <label className="block text-xs font-medium text-zinc-400 mb-1">Relative google3 Path</label>
                          <input
                            value={editRelativePath}
                            onChange={(e) => setEditRelativePath(e.target.value)}
                            placeholder="e.g. cloud/security"
                            className="w-full rounded-xl border border-white/10 bg-black/40 px-3 py-2 text-sm text-zinc-100 outline-none focus:border-sky-400 font-mono"
                          />
                        </div>
                      </div>
                    ) : null}

                    <div>
                      <label className="block text-xs font-medium text-zinc-400 mb-1">Description</label>
                      <input
                        value={editDescription}
                        onChange={(e) => setEditDescription(e.target.value)}
                        className="w-full rounded-xl border border-white/10 bg-black/30 px-3 py-2 text-sm text-zinc-100 outline-none focus:border-sky-400"
                      />
                    </div>

                    <div className="grid gap-3 sm:grid-cols-2">
                      <div>
                        <label className="block text-xs font-medium text-zinc-400 mb-1">Repo URL</label>
                        <input
                          value={editRepoUrl}
                          onChange={(e) => setEditRepoUrl(e.target.value)}
                          className="w-full rounded-xl border border-white/10 bg-black/30 px-3 py-2 text-sm text-zinc-100 outline-none focus:border-sky-400"
                        />
                      </div>
                      <div>
                        <label className="block text-xs font-medium text-zinc-400 mb-1">VCS Kind</label>
                        <select
                          value={editVcsKind}
                          onChange={(e) => setEditVcsKind(e.target.value)}
                          className="w-full rounded-xl border border-white/10 bg-black/30 px-3 py-2 text-sm text-zinc-100 outline-none focus:border-sky-400"
                        >
                          <option value="none">none</option>
                          <option value="git">git</option>
                          <option value="jj">jj</option>
                          <option value="piper">piper</option>
                        </select>
                      </div>
                    </div>

                    {editSaveError ? (
                      <div className="text-xs text-red-300">{editSaveError}</div>
                    ) : null}

                    <div className="flex justify-end gap-2">
                      <button
                        type="button"
                        onClick={() => { setIsEditing(false); setShowEditLocalPicker(false); }}
                        className="rounded-xl border border-white/10 px-3 py-1.5 text-xs text-zinc-400 hover:bg-white/10"
                      >
                        Cancel
                      </button>
                      <button
                        data-debug-id={`settings-project-save-btn-${selectedProjectId}`}
                        type="button"
                        onClick={() => void handleSaveProject()}
                        disabled={editSaving || !editName.trim() || (editProjectType === "local" && !editDefaultPath.trim()) || (editProjectType === "fig" && !editWorkspaceName.trim())}
                        className="rounded-xl bg-sky-400 hover:bg-sky-300 px-4 py-1.5 text-xs font-semibold text-black disabled:opacity-50 transition"
                      >
                        {editSaving ? "Saving…" : "Save project"}
                      </button>
                    </div>
                  </div>
                ) : (
                  <div className="space-y-2 text-sm">
                    <div className="grid gap-2 sm:grid-cols-2 text-xs text-zinc-400">
                      <div>
                        <strong className="text-zinc-300">Type:</strong>{" "}
                        <span className={selectedProject.project_type === "fig" ? "text-amber-400 font-semibold" : "text-zinc-300"}>
                          {selectedProject.project_type === "fig" ? "Fig (CitC)" : "Local"}
                        </span>
                      </div>
                      <div><strong className="text-zinc-300">Default Path:</strong> <span className="font-mono text-zinc-200">{selectedProject.default_path || "—"}</span></div>
                      {selectedProject.project_type === "fig" ? (
                        <>
                          <div><strong className="text-zinc-300">CitC Workspace:</strong> <span className="font-mono text-amber-300">{selectedProject.workspace_name || "—"}</span></div>
                          <div><strong className="text-zinc-300">Relative google3 Path:</strong> <span className="font-mono text-amber-300">{selectedProject.relative_path || "root"}</span></div>
                        </>
                      ) : null}
                      <div><strong className="text-zinc-300">VCS / Repo:</strong> {selectedProject.vcs_kind || (selectedProject.project_type === "fig" ? "piper" : "git")} · {selectedProject.repo_url || "no repo"}</div>
                    </div>
                    {selectedProject.description ? (
                      <p className="text-xs text-zinc-300 mt-1">{selectedProject.description}</p>
                    ) : null}
                  </div>
                )}
              </div>

              {/* Per-Bridge Paths Editor */}
              <div className="rounded-2xl border border-white/10 bg-white/[0.03] p-4 space-y-4">
                <div>
                  <h4 className="text-sm font-semibold text-zinc-200 uppercase tracking-wide">Per-Bridge Paths Override</h4>
                  <p className="text-xs text-zinc-500 mt-0.5">Configure custom filesystem paths for specific bridges when they differ from the default path.</p>
                </div>

                {bridgesQuery.isLoading ? (
                  <div className="text-sm text-zinc-500">Loading bridges…</div>
                ) : bridges.length === 0 ? (
                  <div className="rounded-xl border border-dashed border-white/10 p-4 text-center text-xs text-zinc-500">
                    No connected bridges available.
                  </div>
                ) : (
                  <div className="space-y-3">
                    {bridges.map((bridge) => {
                      const bridgeId = String(bridge?.bridge_id || bridge?.bridgeId || bridge?.id || "");
                      const bridgeName = String(bridge?.label || bridge?.machine_hostname || bridge?.hostname || bridgeId);
                      const bridgeStatus = String(bridge?.status || bridge?.runtime_status || "").toLowerCase();
                      const isOnline = bridgeStatus === "online" || bridgeStatus === "connected";

                      const existingOverride = bridgePaths.find((bp) => bp.bridge_id === bridgeId);
                      const currentInputValue = bridgePathInputs[bridgeId] !== undefined
                        ? bridgePathInputs[bridgeId]
                        : (existingOverride?.path || "");

                      const actionError = bridgeActionError[bridgeId] || "";
                      const busyState = bridgeActionBusy[bridgeId] || "";

                      return (
                        <div
                          key={bridgeId}
                          data-debug-id={`settings-project-bridge-path-row-${bridgeId}`}
                          className="rounded-xl border border-white/10 bg-black/20 p-3 space-y-2"
                        >
                          <div className="flex flex-wrap items-center justify-between gap-2">
                            <div className="flex items-center gap-2">
                              <span className={`h-2 w-2 rounded-full ${isOnline ? "bg-emerald-400" : "bg-zinc-600"}`} />
                              <span className="text-sm font-medium text-zinc-200">{bridgeName}</span>
                              <span className="text-xs text-zinc-500">({bridgeId})</span>
                            </div>

                            {/* Status Indicator */}
                            <div data-debug-id={`settings-project-bridge-path-status-${bridgeId}`} className="flex items-center gap-2 text-xs">
                              <span className={`px-2 py-0.5 rounded-full border text-[10px] ${isOnline ? "border-emerald-400/30 bg-emerald-400/10 text-emerald-200" : "border-amber-400/20 bg-amber-400/5 text-amber-300"}`}>
                                {isOnline ? "online" : "offline"}
                              </span>
                              {existingOverride?.is_validated ? (
                                <span className="text-emerald-400 text-[11px] font-medium">✓ Validated</span>
                              ) : existingOverride?.validation_error ? (
                                <span className="text-red-400 text-[11px] font-medium" title={existingOverride.validation_error}>⚠ Validation failed</span>
                              ) : existingOverride ? (
                                <span className="text-amber-300 text-[11px]">Not validated</span>
                              ) : (
                                <span className="text-zinc-500 text-[11px]">Using default path</span>
                              )}
                            </div>
                          </div>

                          {/* Path Input */}
                          <div className="flex flex-col sm:flex-row items-stretch sm:items-center gap-2">
                            <input
                              data-debug-id={`settings-project-bridge-path-input-${bridgeId}`}
                              value={currentInputValue}
                              onChange={(e) => {
                                const val = e.target.value;
                                setBridgePathInputs((prev) => ({ ...prev, [bridgeId]: val }));
                              }}
                              placeholder={`Default: ${selectedProject.default_path}`}
                              className="flex-1 rounded-xl border border-white/10 bg-black/40 px-3 py-1.5 text-xs text-zinc-100 outline-none focus:border-sky-400 font-mono"
                            />

                            <div className="flex items-center gap-1.5 shrink-0">
                              {existingOverride ? (
                                <>
                                  <button
                                    data-debug-id={`settings-project-bridge-path-save-btn-${bridgeId}`}
                                    type="button"
                                    onClick={() => void handleSaveBridgePath(bridgeId, selectedProject.default_path, existingOverride?.path)}
                                    disabled={Boolean(busyState)}
                                    className="rounded-lg bg-sky-400/10 border border-sky-400/30 px-2.5 py-1 text-xs text-sky-200 hover:bg-sky-400/20 disabled:opacity-50 font-medium"
                                  >
                                    {busyState === "save" ? "Saving…" : "Save"}
                                  </button>

                                  <button
                                    data-debug-id={`settings-project-bridge-path-validate-btn-${bridgeId}`}
                                    type="button"
                                    onClick={() => void handleValidateBridgePath(bridgeId)}
                                    disabled={!isOnline || Boolean(busyState)}
                                    title={!isOnline ? "Bridge is offline" : "Validate path on bridge"}
                                    className="rounded-lg bg-white/10 border border-white/10 px-2.5 py-1 text-xs text-zinc-200 hover:bg-white/15 disabled:opacity-40 disabled:cursor-not-allowed font-medium"
                                  >
                                    {busyState === "validate" ? "Validating…" : "Validate"}
                                  </button>

                                  <button
                                    data-debug-id={`settings-project-bridge-path-remove-btn-${bridgeId}`}
                                    type="button"
                                    onClick={() => void handleRemoveBridgePath(bridgeId)}
                                    disabled={Boolean(busyState)}
                                    className="rounded-lg border border-red-400/20 bg-red-400/5 px-2.5 py-1 text-xs text-red-300 hover:bg-red-400/10 disabled:opacity-50 font-medium"
                                  >
                                    {busyState === "remove" ? "Removing…" : "Remove"}
                                  </button>
                                </>
                              ) : (
                                <button
                                  data-debug-id={`settings-project-bridge-path-set-btn-${bridgeId}`}
                                  type="button"
                                  onClick={() => void handleSetBridgePath(bridgeId, selectedProject.default_path)}
                                  disabled={Boolean(busyState) || !selectedProject.default_path}
                                  title="Set an override seeded with the project's default path"
                                  className="rounded-lg bg-sky-400/10 border border-sky-400/30 px-2.5 py-1 text-xs text-sky-200 hover:bg-sky-400/20 disabled:opacity-50 font-medium"
                                >
                                  {busyState === "set" ? "Setting…" : "Set"}
                                </button>
                              )}
                            </div>
                          </div>

                          {!isOnline ? (
                            <div className="text-[11px] text-amber-300/80 flex items-center gap-1">
                              ⚠ Bridge is offline. Cannot validate path until bridge connects.
                            </div>
                          ) : null}

                          {actionError ? (
                            <div className="text-[11px] text-red-300">{actionError}</div>
                          ) : null}
                        </div>
                      );
                    })}
                  </div>
                )}
              </div>
            </div>
          ) : (
            <div className="text-sm text-zinc-500">Project not found.</div>
          )}
        </div>
      ) : (
        /* Projects List */
        <div className="space-y-3">
          <h3 className="text-sm font-semibold text-zinc-400 uppercase tracking-wide">Existing Projects ({projects.length})</h3>

          {projectsQuery.isLoading ? (
            <div className="text-sm text-zinc-500">Loading projects…</div>
          ) : projects.length === 0 ? (
            <div className="rounded-xl border border-dashed border-white/10 p-5 text-center text-sm text-zinc-500">
              No projects created yet. Use the form above to add your first project.
            </div>
          ) : (
            <div className="space-y-2">
              {projects.map((project) => {
                const projectId = String(project.project_id || (project as any).projectId || (project as any).id || "");
                return (
                  <div
                    key={projectId}
                    data-debug-id={`settings-project-row-${projectId}`}
                    className="flex items-center justify-between gap-3 rounded-xl border border-white/10 bg-black/20 p-3.5 hover:border-white/20 transition"
                  >
                    <div className="min-w-0 flex-1 space-y-1">
                      <div className="flex items-center gap-2">
                        <span className="font-semibold text-zinc-100 truncate">{project.name}</span>
                        {project.project_type === "fig" ? (
                          <span className="rounded-full border border-amber-400/30 bg-amber-400/10 px-2 py-0.5 text-[10px] font-medium text-amber-300 flex items-center gap-1">
                            <Icon name="folder" size={10} className="text-amber-400" />
                            CitC
                          </span>
                        ) : (
                          <span className="rounded-full border border-zinc-700 bg-zinc-800 px-2 py-0.5 text-[10px] font-medium text-zinc-400">
                            Local
                          </span>
                        )}
                        {project.is_default_conversations ? (
                          <span className="rounded-full border border-sky-400/30 bg-sky-400/10 px-2 py-0.5 text-[10px] font-medium text-sky-300">
                            Default
                          </span>
                        ) : null}
                      </div>

                      <div className="flex flex-wrap items-center gap-x-4 gap-y-1 text-xs text-zinc-400">
                        {project.project_type === "fig" && project.workspace_name ? (
                          <div>
                            <strong className="text-zinc-500">CitC:</strong>{" "}
                            <span className="font-mono text-amber-300">
                              {project.workspace_name}{project.relative_path ? ` · google3/${project.relative_path}` : ""}
                            </span>
                          </div>
                        ) : (
                          <div><strong className="text-zinc-500">Path:</strong> <span className="font-mono text-zinc-300">{project.default_path}</span></div>
                        )}
                        <div><strong className="text-zinc-500">VCS:</strong> {project.vcs_kind || (project.project_type === "fig" ? "piper" : "git")}</div>
                        {project.repo_url ? (
                          <div className="truncate max-w-xs"><strong className="text-zinc-500">Repo:</strong> {project.repo_url}</div>
                        ) : null}
                      </div>

                      {project.updated_at ? (
                        <div className="text-[10px] text-zinc-500">
                          Updated: {new Date(project.updated_at).toLocaleString()}
                        </div>
                      ) : null}
                    </div>

                    <button
                      data-debug-id={`settings-project-open-btn-${projectId}`}
                      type="button"
                      onClick={() => {
                        setSelectedProjectId(projectId);
                        setIsEditing(false);
                      }}
                      className="shrink-0 rounded-xl border border-white/10 bg-white/5 px-3 py-1.5 text-xs font-semibold text-sky-400 hover:bg-sky-400 hover:text-black transition"
                    >
                      Open &gt;
                    </button>
                  </div>
                );
              })}
            </div>
          )}
        </div>
      )}
    </div>
  );
}
