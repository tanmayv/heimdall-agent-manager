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
import BridgeDirectoryPicker from "../BridgeDirectoryPicker";
import { VaultText } from "../vault/VaultText";
import { Badge, Button, Icon, Input, PageShell, SectionHeader, Select, StatusDot, Text } from "@ui";

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
  const [showEditLocalPicker, setShowEditLocalPicker] = useState(false);
  const [selectedBridgeId, setSelectedBridgeId] = useState("");

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
  // TODO(FIX): Replace any with strict TypeScript interface matching Odin backend schema
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

  const selectedBridge = useMemo(() => {
    return bridges.find((b) => String(b?.bridge_id || b?.bridgeId || b?.id || "") === selectedBridgeId) || null;
  }, [bridges, selectedBridgeId]);

  // Update edit form state when selected project changes
  useEffect(() => {
    if (selectedProject) {
      setEditName(selectedProject.name || "");
      setEditDescription(selectedProject.description || "");
      setEditRepoUrl(selectedProject.repo_url || "");
      setEditVcsKind(selectedProject.vcs_kind || "git");
      setEditDefaultPath(selectedProject.default_path || "");
      setEditSaveError("");
      setShowEditLocalPicker(false);
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
      setShowEditLocalPicker(false);
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
    <PageShell
      title="Projects"
      description="Manage projects, default workspace paths, and bridge path overrides."
    >
      <div data-debug-id="settings-projects-panel" className="space-y-6 text-left">
      {/* Project Creation Form */}
      <div data-debug-id="settings-project-create-form" className="rounded-2xl border border-subtle bg-surface p-4 space-y-4">
        <Text as="h3" role="overline" tone="primary">Create New Project</Text>
        <form onSubmit={handleCreateProject} className="space-y-3">
          <div className="grid gap-3 sm:grid-cols-2">
            <div>
              <label className="block text-xs font-medium text-muted mb-1">Project Name *</label>
              <Input
                data-debug-id="settings-project-name-input"
                value={name}
                onChange={setName}
                placeholder="Website Rewrite"
                required
                width="full"
                className="min-h-[44px]"
              />
            </div>
            <div>
              <label className="block text-xs font-medium text-muted mb-1">Default Path *</label>
              <Input
                data-debug-id="settings-project-default-path-input"
                value={defaultPath}
                onChange={setDefaultPath}
                placeholder="/home/user/projects/my-app"
                required
                width="full"
                className="min-h-[44px]"
              />
            </div>
          </div>

          <div>
            <label className="block text-xs font-medium text-muted mb-1">Description</label>
            <Input
              data-debug-id="settings-project-description-input"
              value={description}
              onChange={setDescription}
              placeholder="Frontend migration and backend refactoring project"
              width="full"
              className="min-h-[44px]"
            />
          </div>

          <div className="grid gap-3 sm:grid-cols-2">
            <div>
              <label className="block text-xs font-medium text-muted mb-1">Repository URL</label>
              <Input
                data-debug-id="settings-project-repo-input"
                value={repoUrl}
                onChange={setRepoUrl}
                placeholder="https://github.com/org/repo"
                width="full"
                className="min-h-[44px]"
              />
            </div>
            <div>
              <label className="block text-xs font-medium text-muted mb-1">VCS Kind</label>
              <Select
                data-debug-id="settings-project-vcs-select"
                value={vcsKind}
                onChange={setVcsKind}
                width="full"
                className="min-h-[44px]"
              >
                <option value="none">none</option>
                <option value="git">git</option>
                <option value="jj">jj</option>
              </Select>
            </div>
          </div>

          {createError ? (
            <div data-debug-id="settings-project-create-error" className="rounded-xl border border-danger/30 bg-danger-soft px-3 py-2 text-sm text-danger">
              {createError}
            </div>
          ) : null}

          <Button
            variant="primary"
            data-debug-id="settings-project-create-btn"
            type="submit"
            disabled={!name.trim() || !defaultPath.trim() || creating}
            className="min-h-[44px] w-full sm:w-auto"
          >
            {creating ? "Creating…" : "Create project"}
          </Button>
        </form>
      </div>

      {/* Project Detail View or Project List */}
      {selectedProjectId ? (
        <div className="space-y-6">
          <div className="flex items-center justify-between border-b border-subtle pb-3">
            <button
              type="button"
              onClick={() => { setSelectedProjectId(null); setIsEditing(false); setShowEditLocalPicker(false); }}
              className="text-sm text-accent hover:underline flex items-center gap-1"
            >
              ← Back to all projects
            </button>
            <div className="flex items-center gap-2">
              <Button
                variant="secondary"
                size="sm"
                data-debug-id={`settings-project-edit-btn-${selectedProjectId}`}
                onClick={() => { setIsEditing((prev) => !prev); setShowEditLocalPicker(false); }}
              >
                {isEditing ? "Cancel Edit" : "Edit Project"}
              </Button>
            </div>
          </div>

          {projectDetailQuery.isLoading ? (
            <div className="text-sm text-muted">Loading project details…</div>
          ) : selectedProject ? (
            <div className="space-y-6">
              {/* Project Main Details Form / Viewer */}
              <div className="rounded-2xl border border-subtle bg-surface p-4 space-y-4">
                <SectionHeader
                  level="h3"
                  title={<VaultText value={selectedProject.name} fallback="Untitled project" />}
                  actions={
                    selectedProject.is_default_conversations ? (
                      <Badge tone="info">Default Project</Badge>
                    ) : undefined
                  }
                />

                {isEditing ? (
                  <div className="space-y-4">
                    <div className="grid gap-3 sm:grid-cols-2">
                      <div>
                        <label className="block text-xs font-medium text-muted mb-1">Project Name *</label>
                        <Input
                          value={editName}
                          onChange={setEditName}
                          required
                          width="full"
                        />
                      </div>
                      <div>
                        <label className="block text-xs font-medium text-muted mb-1">Default Path *</label>
                        <div className="flex items-center gap-2">
                          <Input
                            value={editDefaultPath}
                            onChange={setEditDefaultPath}
                            required
                            width="full"
                            className="flex-1 font-mono"
                          />
                          <Button
                            data-debug-id="settings-project-edit-local-browse-btn"
                            variant="secondary"
                            size="sm"
                            disabled={!selectedBridgeId}
                            onClick={() => setShowEditLocalPicker((v) => !v)}
                            leading={<Icon name="folder" size={14} />}
                          >
                            {showEditLocalPicker ? "Hide Browser" : "Browse…"}
                          </Button>
                        </div>
                      </div>
                    </div>

                    {showEditLocalPicker && selectedBridgeId ? (
                      <div className="rounded-xl border border-info/30 bg-info-soft p-3 space-y-2">
                        {bridges.length > 1 ? (
                          <div className="flex items-center gap-2 text-xs mb-2">
                            <span className="text-muted">Bridge host:</span>
                            <Select
                              value={selectedBridgeId}
                              onChange={(val) => setSelectedBridgeId(val)}
                            >
                              {bridges.map((b) => {
                                const bid = String(b?.bridge_id || b?.bridgeId || b?.id || "");
                                const blabel = String(b?.label || b?.machine_hostname || b?.hostname || bid);
                                const bonline = String(b?.status || b?.runtime_status || "").toLowerCase() === "online";
                                return (
                                  <option key={bid} value={bid}>
                                    {blabel} ({bonline ? "● Online" : "○ Offline"})
                                  </option>
                                );
                              })}
                            </Select>
                          </div>
                        ) : null}
                        <BridgeDirectoryPicker
                          debugId="settings-project-edit-local-picker"
                          bridgeId={selectedBridgeId}
                          bridgeLabel={selectedBridge?.label}
                          initialPath={editDefaultPath}
                          onPick={(p) => {
                            setEditDefaultPath(p);
                            if (!editName.trim()) {
                              const base = p.split("/").filter(Boolean).pop();
                              if (base) setEditName(base);
                            }
                            setShowEditLocalPicker(false);
                          }}
                          onClose={() => setShowEditLocalPicker(false)}
                        />
                      </div>
                    ) : null}

                    <div>
                      <label className="block text-xs font-medium text-muted mb-1">Description</label>
                      <Input
                        value={editDescription}
                        onChange={setEditDescription}
                        width="full"
                      />
                    </div>

                    <div className="grid gap-3 sm:grid-cols-2">
                      <div>
                        <label className="block text-xs font-medium text-muted mb-1">Repo URL</label>
                        <Input
                          value={editRepoUrl}
                          onChange={setEditRepoUrl}
                          width="full"
                        />
                      </div>
                      <div>
                        <label className="block text-xs font-medium text-muted mb-1">VCS Kind</label>
                        <Select
                          value={editVcsKind}
                          onChange={setEditVcsKind}
                          width="full"
                        >
                          <option value="none">none</option>
                          <option value="git">git</option>
                          <option value="jj">jj</option>
                        </Select>
                      </div>
                    </div>

                    {editSaveError ? (
                      <div className="text-xs text-danger">{editSaveError}</div>
                    ) : null}

                    <div className="flex justify-end gap-2">
                      <Button
                        variant="secondary"
                        size="sm"
                        onClick={() => { setIsEditing(false); setShowEditLocalPicker(false); }}
                      >
                        Cancel
                      </Button>
                      <Button
                        variant="primary"
                        size="sm"
                        data-debug-id={`settings-project-save-btn-${selectedProjectId}`}
                        onClick={() => void handleSaveProject()}
                        disabled={editSaving || !editName.trim() || !editDefaultPath.trim()}
                      >
                        {editSaving ? "Saving…" : "Save project"}
                      </Button>
                    </div>
                  </div>
                ) : (
                  <div className="space-y-2 text-sm">
                    <div className="grid gap-2 sm:grid-cols-2 text-xs text-muted">
                      <div><strong className="text-muted">Default Path:</strong> <span className="font-mono text-primary">{selectedProject.default_path || "—"}</span></div>
                      <div><strong className="text-muted">VCS / Repo:</strong> {selectedProject.vcs_kind || "git"} · {selectedProject.repo_url || "no repo"}</div>
                    </div>
                    {selectedProject.description ? (
                      <p className="text-xs text-muted mt-1"><VaultText value={selectedProject.description} /></p>
                    ) : null}
                  </div>
                )}
              </div>

              {/* Per-Bridge Paths Editor */}
              <div className="rounded-2xl border border-subtle bg-surface p-4 space-y-4">
                <div>
                  <Text as="h4" role="overline" tone="primary">Per-Bridge Paths Override</Text>
                  <p className="text-xs text-muted mt-0.5">Configure custom filesystem paths for specific bridges when they differ from the default path.</p>
                </div>

                {bridgesQuery.isLoading ? (
                  <div className="text-sm text-muted">Loading bridges…</div>
                ) : bridges.length === 0 ? (
                  <div className="rounded-xl border border-dashed border-subtle p-4 text-center text-xs text-muted">
                    No connected bridges available.
                  </div>
                ) : (
                  <div className="space-y-3">
                    {bridges.map((bridge) => {
                      // TODO(FIX): Replace loose fallback chain with canonical typed schema property
                      const bridgeId = String(bridge?.bridge_id || bridge?.bridgeId || bridge?.id || "");
                      // TODO(FIX): Replace loose fallback chain with canonical typed schema property
                      const bridgeName = String(bridge?.label || bridge?.machine_hostname || bridge?.hostname || bridgeId);
                      // TODO(FIX): Replace loose fallback chain with canonical typed schema property
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
                          className="rounded-xl border border-subtle bg-surface-raised/30 p-3 space-y-2"
                        >
                          <div className="flex flex-wrap items-center justify-between gap-2">
                            <div className="flex items-center gap-2">
                              <StatusDot tone={isOnline ? "success" : "neutral"} label={isOnline ? "Online" : "Offline"} />
                              <span className="text-sm font-medium text-primary">{bridgeName}</span>
                              <span className="text-xs text-muted">({bridgeId})</span>
                            </div>

                            {/* Status Indicator */}
                            <div data-debug-id={`settings-project-bridge-path-status-${bridgeId}`} className="flex items-center gap-2 text-xs">
                              <Badge tone={isOnline ? "success" : "warning"} emphasis="soft">
                                {isOnline ? "online" : "offline"}
                              </Badge>
                              {existingOverride?.is_validated ? (
                                <span className="text-success text-caption font-medium">✓ Validated</span>
                              ) : existingOverride?.validation_error ? (
                                <span className="text-danger text-caption font-medium" title={existingOverride.validation_error}>⚠ Validation failed</span>
                              ) : existingOverride ? (
                                <span className="text-warning text-caption">Not validated</span>
                              ) : (
                                <span className="text-muted text-caption">Using default path</span>
                              )}
                            </div>
                          </div>

                          {/* Path Input */}
                          <div className="flex flex-col sm:flex-row items-stretch sm:items-center gap-2">
                            <Input
                              size="sm"
                              data-debug-id={`settings-project-bridge-path-input-${bridgeId}`}
                              value={currentInputValue}
                              onChange={(val) => setBridgePathInputs((prev) => ({ ...prev, [bridgeId]: val }))}
                              placeholder={`Default: ${selectedProject.default_path}`}
                              className="flex-1 font-mono"
                            />

                            <div className="flex items-center gap-1.5 shrink-0">
                              {existingOverride ? (
                                <>
                                  <Button
                                    variant="primary"
                                    size="sm"
                                    data-debug-id={`settings-project-bridge-path-save-btn-${bridgeId}`}
                                    onClick={() => void handleSaveBridgePath(bridgeId, selectedProject.default_path, existingOverride?.path)}
                                    disabled={Boolean(busyState)}
                                  >
                                    {busyState === "save" ? "Saving…" : "Save"}
                                  </Button>

                                  <Button
                                    variant="secondary"
                                    size="sm"
                                    data-debug-id={`settings-project-bridge-path-validate-btn-${bridgeId}`}
                                    onClick={() => void handleValidateBridgePath(bridgeId)}
                                    disabled={!isOnline || Boolean(busyState)}
                                    title={!isOnline ? "Bridge is offline" : "Validate path on bridge"}
                                  >
                                    {busyState === "validate" ? "Validating…" : "Validate"}
                                  </Button>

                                  <Button
                                    variant="danger"
                                    size="sm"
                                    data-debug-id={`settings-project-bridge-path-remove-btn-${bridgeId}`}
                                    onClick={() => void handleRemoveBridgePath(bridgeId)}
                                    disabled={Boolean(busyState)}
                                  >
                                    {busyState === "remove" ? "Removing…" : "Remove"}
                                  </Button>
                                </>
                              ) : (
                                <Button
                                  variant="primary"
                                  size="sm"
                                  data-debug-id={`settings-project-bridge-path-set-btn-${bridgeId}`}
                                  onClick={() => void handleSetBridgePath(bridgeId, selectedProject.default_path)}
                                  disabled={Boolean(busyState) || !selectedProject.default_path}
                                  title="Set an override seeded with the project's default path"
                                >
                                  {busyState === "set" ? "Setting…" : "Set"}
                                </Button>
                              )}
                            </div>
                          </div>

                          {!isOnline ? (
                            <div className="text-caption text-warning flex items-center gap-1">
                              ⚠ Bridge is offline. Cannot validate path until bridge connects.
                            </div>
                          ) : null}

                          {actionError ? (
                            <div className="text-caption text-danger">{actionError}</div>
                          ) : null}
                        </div>
                      );
                    })}
                  </div>
                )}
              </div>
            </div>
          ) : (
            <div className="text-sm text-muted">Project not found.</div>
          )}
        </div>
      ) : (
        /* Projects List */
        <div className="space-y-3">
          <h3 className="text-sm font-semibold text-muted uppercase tracking-wide">Existing Projects ({projects.length})</h3>

          {projectsQuery.isLoading ? (
            <div className="text-sm text-muted">Loading projects…</div>
          ) : projects.length === 0 ? (
            <div className="rounded-xl border border-dashed border-subtle p-5 text-center text-sm text-muted">
              No projects created yet. Use the form above to add your first project.
            </div>
          ) : (
            <div className="space-y-2">
              {projects.map((project) => {
                // TODO(FIX): Replace any with strict TypeScript interface matching Odin backend schema
                // TODO(FIX): Replace loose fallback chain with canonical typed schema property
                const projectId = String(project.project_id || (project as any).projectId || (project as any).id || "");
                return (
                  <div
                    key={projectId}
                    data-debug-id={`settings-project-row-${projectId}`}
                    className="flex items-center justify-between gap-3 rounded-xl border border-subtle bg-surface-raised/30 p-3.5 hover:border-strong transition"
                  >
                    <div className="min-w-0 flex-1 space-y-1">
                      <div className="flex items-center gap-2">
                        <span className="font-semibold text-primary truncate"><VaultText value={project.name} fallback="Untitled project" /></span>
                        {project.is_default_conversations ? (
                          <Badge tone="info" emphasis="soft">
                            Default
                          </Badge>
                        ) : null}
                      </div>

                      <div className="flex flex-wrap items-center gap-x-4 gap-y-1 text-xs text-muted">
                        <div><strong className="text-muted">Path:</strong> <span className="font-mono text-primary">{project.default_path}</span></div>
                        <div><strong className="text-muted">VCS:</strong> {project.vcs_kind || "git"}</div>
                        {project.repo_url ? (
                          <div className="truncate max-w-xs"><strong className="text-muted">Repo:</strong> {project.repo_url}</div>
                        ) : null}
                      </div>

                      {project.updated_at ? (
                        <div className="text-[10px] text-muted">
                          Updated: {new Date(project.updated_at).toLocaleString()}
                        </div>
                      ) : null}
                    </div>

                    <Button
                      variant="secondary"
                      size="sm"
                      data-debug-id={`settings-project-open-btn-${projectId}`}
                      onClick={() => {
                        setSelectedProjectId(projectId);
                        setIsEditing(false);
                      }}
                      className="shrink-0"
                    >
                      Open &gt;
                    </Button>
                  </div>
                );
              })}
            </div>
          )}
        </div>
      )}
      </div>
    </PageShell>
  );
}
