import { useEffect, useState } from "react";
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

export default function ProjectsPanel() {
  const projectsQuery = useListProjectsQuery();
  const [createProject] = useCreateProjectMutation();
  const [updateProject] = useUpdateProjectMutation();
  const [setProjectBridgePath] = useSetProjectBridgePathMutation();
  const [deleteProjectBridgePath] = useDeleteProjectBridgePathMutation();
  const [validateProjectBridgePath] = useValidateProjectBridgePathMutation();

  const bridgesQuery = useListBridgesQuery();

  // Create form state
  const [name, setName] = useState("");
  const [description, setDescription] = useState("");
  const [repoUrl, setRepoUrl] = useState("");
  const [vcsKind, setVcsKind] = useState("git");
  const [defaultPath, setDefaultPath] = useState("");
  const [createError, setCreateError] = useState("");
  const [creating, setCreating] = useState(false);

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

  // Update edit form state when selected project changes
  useEffect(() => {
    if (selectedProject) {
      setEditName(selectedProject.name || "");
      setEditDescription(selectedProject.description || "");
      setEditRepoUrl(selectedProject.repo_url || "");
      setEditVcsKind(selectedProject.vcs_kind || "git");
      setEditDefaultPath(selectedProject.default_path || "");
      setEditSaveError("");
      setBridgePathInputs({});
      setBridgeActionError({});
      setBridgeActionBusy({});
    }
  }, [selectedProject]);

  async function handleCreateProject(e?: React.FormEvent) {
    if (e) e.preventDefault();
    if (!name.trim() || !defaultPath.trim()) return;
    setCreateError("");
    setCreating(true);
    try {
      await createProject({
        name: name.trim(),
        description: description.trim() || undefined,
        repo_url: repoUrl.trim() || undefined,
        vcs_kind: vcsKind,
        default_path: defaultPath.trim(),
      }).unwrap();
      setName("");
      setDescription("");
      setRepoUrl("");
      setVcsKind("git");
      setDefaultPath("");
    } catch (err: any) {
      const msg = err?.error || err?.message || String(err || "Unable to create project");
      setCreateError(msg);
    } finally {
      setCreating(false);
    }
  }

  async function handleSaveProject() {
    if (!selectedProjectId || !editName.trim() || !editDefaultPath.trim()) return;
    setEditSaveError("");
    setEditSaving(true);
    try {
      await updateProject({
        projectId: selectedProjectId,
        name: editName.trim(),
        description: editDescription.trim() || undefined,
        repo_url: editRepoUrl.trim() || undefined,
        vcs_kind: editVcsKind,
        default_path: editDefaultPath.trim(),
      }).unwrap();
      setIsEditing(false);
    } catch (err: any) {
      const msg = err?.error || err?.message || String(err || "Unable to update project");
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
        <h3 className="text-sm font-semibold text-zinc-200 uppercase tracking-wide">Create New Project</h3>
        <form onSubmit={handleCreateProject} className="space-y-3">
          <div className="grid gap-3 sm:grid-cols-2">
            <div>
              <label className="block text-xs font-medium text-zinc-400 mb-1">Project Name *</label>
              <input
                data-debug-id="settings-project-name-input"
                value={name}
                onChange={(e) => setName(e.target.value)}
                placeholder="Website Rewrite"
                required
                className="w-full min-h-[44px] rounded-xl border border-white/10 bg-black/30 px-3 py-2 text-sm text-zinc-100 outline-none focus:border-sky-400"
              />
            </div>
            <div>
              <label className="block text-xs font-medium text-zinc-400 mb-1">Default Path *</label>
              <input
                data-debug-id="settings-project-default-path-input"
                value={defaultPath}
                onChange={(e) => setDefaultPath(e.target.value)}
                placeholder="/home/user/projects/my-app"
                required
                className="w-full min-h-[44px] rounded-xl border border-white/10 bg-black/30 px-3 py-2 text-sm text-zinc-100 outline-none focus:border-sky-400"
              />
            </div>
          </div>

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
                placeholder="https://github.com/org/repo"
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
            disabled={!name.trim() || !defaultPath.trim() || creating}
            className="min-h-[44px] w-full rounded-xl bg-sky-400 px-4 py-2 text-sm font-semibold text-black disabled:opacity-50 sm:w-auto hover:bg-sky-300"
          >
            {creating ? "Creating…" : "Create project"}
          </button>
        </form>
      </div>

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
                onClick={() => setIsEditing((prev) => !prev)}
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
                        <input
                          value={editDefaultPath}
                          onChange={(e) => setEditDefaultPath(e.target.value)}
                          className="w-full rounded-xl border border-white/10 bg-black/30 px-3 py-2 text-sm text-zinc-100 outline-none focus:border-sky-400"
                        />
                      </div>
                    </div>

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
                        </select>
                      </div>
                    </div>

                    {editSaveError ? (
                      <div className="text-xs text-red-300">{editSaveError}</div>
                    ) : null}

                    <div className="flex justify-end gap-2">
                      <button
                        type="button"
                        onClick={() => setIsEditing(false)}
                        className="rounded-xl border border-white/10 px-3 py-1.5 text-xs text-zinc-400 hover:bg-white/10"
                      >
                        Cancel
                      </button>
                      <button
                        data-debug-id={`settings-project-save-btn-${selectedProjectId}`}
                        type="button"
                        onClick={() => void handleSaveProject()}
                        disabled={editSaving || !editName.trim() || !editDefaultPath.trim()}
                        className="rounded-xl bg-sky-400 px-4 py-1.5 text-xs font-semibold text-black hover:bg-sky-300 disabled:opacity-50"
                      >
                        {editSaving ? "Saving…" : "Save project"}
                      </button>
                    </div>
                  </div>
                ) : (
                  <div className="space-y-2 text-sm">
                    <div className="grid gap-2 sm:grid-cols-2 text-xs text-zinc-400">
                      <div><strong className="text-zinc-300">Default Path:</strong> <span className="font-mono text-zinc-200">{selectedProject.default_path || "—"}</span></div>
                      <div><strong className="text-zinc-300">VCS / Repo:</strong> {selectedProject.vcs_kind || "git"} · {selectedProject.repo_url || "no repo"}</div>
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

                              {existingOverride ? (
                                <button
                                  data-debug-id={`settings-project-bridge-path-remove-btn-${bridgeId}`}
                                  type="button"
                                  onClick={() => void handleRemoveBridgePath(bridgeId)}
                                  disabled={Boolean(busyState)}
                                  className="rounded-lg border border-red-400/20 bg-red-400/5 px-2.5 py-1 text-xs text-red-300 hover:bg-red-400/10 disabled:opacity-50 font-medium"
                                >
                                  {busyState === "remove" ? "Removing…" : "Remove"}
                                </button>
                              ) : null}
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
                        {project.is_default_conversations ? (
                          <span className="rounded-full border border-sky-400/30 bg-sky-400/10 px-2 py-0.5 text-[10px] font-medium text-sky-300">
                            Default
                          </span>
                        ) : null}
                      </div>

                      <div className="flex flex-wrap items-center gap-x-4 gap-y-1 text-xs text-zinc-400">
                        <div><strong className="text-zinc-500">Path:</strong> <span className="font-mono text-zinc-300">{project.default_path}</span></div>
                        <div><strong className="text-zinc-500">VCS:</strong> {project.vcs_kind || "git"}</div>
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
