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
import { Badge, Button, FormField, Icon, Input, Modal, PageShell, Panel, SectionHeader, Select, StatusDot, Tabs, Text } from "@ui";

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
    <PageShell
      title="Projects"
      description="Manage projects, default workspace paths, and bridge path overrides."
    >
      <div data-debug-id="settings-projects-panel" className="space-y-6 text-left">
      {/* Project Creation Form */}
      <Panel data-debug-id="settings-project-create-form" tone="raised" padding="md" className="space-y-4">
        <Text as="h3" role="overline" tone="primary">Create New Project</Text>
        <form onSubmit={handleCreateProject} className="space-y-3">
          <div className="grid gap-3 sm:grid-cols-2">
            <FormField label="Project Name" required>
              <Input
                data-debug-id="settings-project-name-input"
                value={name}
                onChange={setName}
                placeholder={projectType === "fig" ? "e.g. Fig Workspace Project" : "Website Rewrite"}
                required
                width="full"
                className="min-h-[44px]"
              />
            </FormField>

            <FormField label="Project Location / Path" required>
              <div className="rounded-[var(--radius-md)] border border-subtle bg-surface p-2.5 flex items-center justify-between gap-3 min-h-[44px]">
                <div className="min-w-0 flex-1">
                  {(projectType === "local" && defaultPath) || (projectType === "fig" && workspaceName) ? (
                    <div>
                      <div className="flex items-center gap-2">
                        <Icon
                          name="folder"
                          size={14}
                          className={projectType === "fig" ? "text-amber-400 shrink-0" : "text-sky-400 shrink-0"}
                        />
                        <span className="font-mono text-xs font-semibold text-primary truncate">
                          {projectType === "fig" ? workspaceName : defaultPath}
                        </span>
                        <Badge tone={projectType === "fig" ? "warning" : "neutral"} emphasis="soft">
                          {projectType === "fig" ? "CitC" : "Local"}
                        </Badge>
                      </div>
                      {projectType === "fig" ? (
                        <div className="mt-0.5 text-caption font-mono text-muted truncate">
                          /google/src/cloud/…/{workspaceName}/google3{relativePath ? `/${relativePath}` : ""}
                        </div>
                      ) : null}
                    </div>
                  ) : (
                    <div>
                      <div className="text-xs font-semibold text-primary">No Location Selected</div>
                      <div className="text-caption text-muted">Pick a local directory or CitC workspace</div>
                    </div>
                  )}
                </div>
                <Button
                  data-debug-id="settings-project-browse-btn settings-project-local-browse-btn settings-project-fig-browse-btn"
                  id="settings-project-fig-browse-btn"
                  variant="secondary"
                  size="sm"
                  disabled={!selectedBridgeId}
                  onClick={() => {
                    setPickerTab(projectType === "fig" ? "fig" : "local");
                    setShowLocationModal(true);
                  }}
                  className="shrink-0"
                >
                  {(projectType === "local" && defaultPath) || (projectType === "fig" && workspaceName)
                    ? "Change Location…"
                    : "Browse…"}
                </Button>
              </div>
            </FormField>
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
          <Select
            data-debug-id="settings-project-fig-workspace-select"
            value={workspaceName}
            disabled={Boolean(figWorkspacesError && figWorkspaces.length === 0)}
            onChange={(ws) => {
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
          </Select>

          <FormField label="Description">
            <Input
              data-debug-id="settings-project-description-input"
              value={description}
              onChange={setDescription}
              placeholder="Frontend migration and backend refactoring project"
              width="full"
              className="min-h-[44px]"
            />
          </FormField>

          <div className="grid gap-3 sm:grid-cols-2">
            <FormField label="Repository URL">
              <Input
                data-debug-id="settings-project-repo-input"
                value={repoUrl}
                onChange={setRepoUrl}
                placeholder={projectType === "fig" ? "//depot/google3" : "https://github.com/org/repo"}
                width="full"
                className="min-h-[44px]"
              />
            </FormField>
            <FormField label="VCS Kind">
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
                <option value="piper">piper</option>
              </Select>
            </FormField>
          </div>

          {createError ? (
            <div data-debug-id="settings-project-create-error" className="rounded-[var(--radius-md)] border border-danger/30 bg-danger/10 px-3 py-2 text-sm text-danger">
              {createError}
            </div>
          ) : null}

          <Button
            variant="primary"
            data-debug-id="settings-project-create-btn"
            type="submit"
            disabled={!name.trim() || (projectType === "local" ? !defaultPath.trim() : !workspaceName.trim()) || creating}
            loading={creating}
            className="min-h-[44px] w-full sm:w-auto"
          >
            Create project
          </Button>
        </form>
      </Panel>

      {/* Unified Location Modal Popup: Local / Fig Tabs */}
      <Modal
        open={showLocationModal}
        onOpenChange={setShowLocationModal}
        title={
          <span className="flex items-center gap-2">
            <Icon name="folder" size={16} className="text-sky-400" />
            <span>Choose Project Location</span>
          </span>
        }
        size="lg"
        data-debug-id="settings-project-location-modal"
      >
        <Modal.Body className="space-y-4">
          <p className="text-xs text-muted">
            Select a local directory or CitC workspace on your bridge host
          </p>

          {/* Tab switch */}
          <div data-debug-id="settings-project-type-toggle">
            <Tabs variant="segmented" value={pickerTab} onChange={(v) => setPickerTab(v as 'local' | 'fig')}>
              <Tabs.List>
                <Tabs.Tab value="local" data-debug-id="settings-project-type-local-btn" className="flex items-center gap-1.5">
                  <Icon name="folder" size={13} className="text-sky-400" />
                  <span>Local Directory</span>
                </Tabs.Tab>
                <Tabs.Tab value="fig" data-debug-id="settings-project-type-fig-btn" className="flex items-center gap-1.5">
                  <Icon name="folder" size={13} className="text-amber-400" />
                  <span>Fig (CitC)</span>
                </Tabs.Tab>
              </Tabs.List>
            </Tabs>
          </div>

          {/* Optional Bridge Select when multiple bridges exist */}
          {bridges.length > 1 ? (
            <div className="flex items-center justify-between gap-2 p-2 rounded-[var(--radius-md)] bg-surface border border-subtle">
              <span className="text-xs text-muted">Bridge Host:</span>
              <Select
                data-debug-id="settings-project-fig-bridge-select settings-project-local-bridge-select"
                value={selectedBridgeId}
                onChange={setSelectedBridgeId}
                size="sm"
                className="w-48"
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
              </Select>
            </div>
          ) : null}

          {/* Offline warning if CitC tab is active and error */}
          {pickerTab === "fig" && figWorkspacesError ? (
            <div
              data-debug-id="settings-project-fig-offline-warning"
              className="flex items-start gap-2.5 rounded-[var(--radius-md)] border border-amber-500/40 bg-amber-500/10 p-3 text-xs text-amber-200"
            >
              <Icon name="alert" size={16} className="shrink-0 text-amber-400 mt-0.5" />
              <div className="flex-1 space-y-1">
                <div className="font-semibold text-amber-300">
                  CitC Bridge Offline (409 Conflict)
                </div>
                <div>{figWorkspacesError}</div>
              </div>
              <Button
                data-debug-id="settings-project-fig-retry-btn"
                variant="secondary"
                size="sm"
                onClick={() => figWorkspacesQuery.refetch()}
              >
                Retry
              </Button>
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
                <span className="text-xs text-muted">CitC Workspaces</span>
                <Button
                  data-debug-id="settings-project-fig-new-workspace-btn"
                  variant="secondary"
                  size="sm"
                  onClick={() => { setShowNewWorkspaceModal(true); setNewWorkspaceError(""); }}
                  leading={<Icon name="plus" size={12} />}
                >
                  New CitC Workspace
                </Button>
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
        </Modal.Body>
      </Modal>

      {/* New CitC Workspace Modal */}
      <Modal
        open={showNewWorkspaceModal}
        onOpenChange={setShowNewWorkspaceModal}
        title={
          <span className="flex items-center gap-2">
            <Icon name="folder" size={16} className="text-amber-400" />
            <span>Create New CitC Workspace</span>
          </span>
        }
        size="sm"
        data-debug-id="settings-project-fig-modal"
      >
        <Modal.Body className="space-y-3">
          <p className="text-xs text-muted">
            Runs <code className="font-mono text-zinc-300">g4 citc -q --head &lt;name&gt;</code> on the bridge host to create a fresh CitC client.
          </p>
          <FormField label="Workspace Name" required error={newWorkspaceError || undefined}>
            <Input
              data-debug-id="settings-project-fig-modal-name-input"
              value={newWorkspaceName}
              onChange={setNewWorkspaceName}
              placeholder="e.g. feat-mobile-sync"
              width="full"
              className="font-mono"
            />
          </FormField>
        </Modal.Body>
        <Modal.Footer>
          <Button
            data-debug-id="settings-project-fig-modal-cancel-btn"
            variant="secondary"
            size="sm"
            onClick={() => { setShowNewWorkspaceModal(false); setNewWorkspaceError(""); }}
          >
            Cancel
          </Button>
          <Button
            data-debug-id="settings-project-fig-modal-submit-btn"
            variant="primary"
            size="sm"
            disabled={!newWorkspaceName.trim() || creatingWorkspace}
            loading={creatingWorkspace}
            onClick={handleCreateWorkspace}
          >
            Create Workspace
          </Button>
        </Modal.Footer>
      </Modal>

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
              <Button
                variant="secondary"
                size="sm"
                data-debug-id={`settings-project-edit-btn-${selectedProjectId}`}
                onClick={() => {
                  setIsEditing((prev) => !prev);
                  setShowEditLocalPicker(false);
                }}
              >
                {isEditing ? "Cancel Edit" : "Edit Project"}
              </Button>
            </div>
          </div>

          {projectDetailQuery.isLoading ? (
            <div className="text-sm text-zinc-500">Loading project details…</div>
          ) : selectedProject ? (
            <div className="space-y-6">
              {/* Project Main Details Form / Viewer */}
              <div className="rounded-2xl border border-white/10 bg-black/20 p-4 space-y-4">
                <SectionHeader
                  level="h3"
                  title={selectedProject.name}
                  actions={
                    selectedProject.is_default_conversations ? (
                      <Badge tone="info">Default Project</Badge>
                    ) : undefined
                  }
                />

                {isEditing ? (
                  <div className="space-y-3">
                    <div className="grid gap-3 sm:grid-cols-2">
                      <FormField label="Project Name" required>
                        <Input
                          value={editName}
                          onChange={setEditName}
                          width="full"
                        />
                      </FormField>
                      <FormField label="Default Path" required>
                        <div className="flex items-center gap-2">
                          <Input
                            data-debug-id={`settings-project-edit-default-path-input-${selectedProjectId}`}
                            value={editDefaultPath}
                            onChange={setEditDefaultPath}
                            width="full"
                            className="flex-1 font-mono"
                          />
                          {editProjectType === "local" ? (
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
                          ) : null}
                        </div>
                      </FormField>
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
                        <FormField label="CitC Workspace" required>
                          <Input
                            value={editWorkspaceName}
                            onChange={setEditWorkspaceName}
                            width="full"
                            className="font-mono"
                          />
                        </FormField>
                        <FormField label="Relative google3 Path">
                          <Input
                            value={editRelativePath}
                            onChange={setEditRelativePath}
                            placeholder="e.g. cloud/security"
                            width="full"
                            className="font-mono"
                          />
                        </FormField>
                      </div>
                    ) : null}

                    <FormField label="Description">
                      <Input
                        value={editDescription}
                        onChange={setEditDescription}
                        width="full"
                      />
                    </FormField>

                    <div className="grid gap-3 sm:grid-cols-2">
                      <FormField label="Repo URL">
                        <Input
                          value={editRepoUrl}
                          onChange={setEditRepoUrl}
                          width="full"
                        />
                      </FormField>
                      <FormField label="VCS Kind">
                        <Select
                          value={editVcsKind}
                          onChange={setEditVcsKind}
                          width="full"
                        >
                          <option value="none">none</option>
                          <option value="git">git</option>
                          <option value="jj">jj</option>
                          <option value="piper">piper</option>
                        </Select>
                      </FormField>
                    </div>

                    {editSaveError ? (
                      <div className="text-xs text-red-300">{editSaveError}</div>
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
                        disabled={editSaving || !editName.trim() || (editProjectType === "local" && !editDefaultPath.trim()) || (editProjectType === "fig" && !editWorkspaceName.trim())}
                      >
                        {editSaving ? "Saving…" : "Save project"}
                      </Button>
                    </div>
                  </div>
                ) : (
                  <div className="space-y-2 text-sm">
                    <div className="grid gap-2 sm:grid-cols-2 text-xs text-zinc-400">
                      <div className="flex items-center gap-2">
                        <strong className="text-zinc-300">Type:</strong>
                        <Badge
                          tone={selectedProject.project_type === "fig" ? "warning" : "neutral"}
                          emphasis="soft"
                        >
                          {selectedProject.project_type === "fig" ? (
                            <span className="flex items-center gap-1">
                              <Icon name="folder" size={10} className="text-amber-400" />
                              Fig (CitC)
                            </span>
                          ) : (
                            "Local"
                          )}
                        </Badge>
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
              <Panel tone="raised" padding="md" className="space-y-4">
                <div>
                  <Text as="h4" role="overline" tone="primary">Per-Bridge Paths Override</Text>
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
                          className="rounded-xl border border-white/10 bg-black/20 p-3 space-y-2"
                        >
                          <div className="flex flex-wrap items-center justify-between gap-2">
                            <div className="flex items-center gap-2">
                              <StatusDot tone={isOnline ? "success" : "neutral"} label={isOnline ? "Online" : "Offline"} />
                              <span className="text-sm font-medium text-zinc-200">{bridgeName}</span>
                              <span className="text-xs text-zinc-500">({bridgeId})</span>
                            </div>

                            {/* Status Indicator */}
                            <div data-debug-id={`settings-project-bridge-path-status-${bridgeId}`} className="flex items-center gap-2 text-xs">
                              <Badge
                                tone={isOnline ? "success" : "warning"}
                                emphasis="soft"
                              >
                                {isOnline ? "online" : "offline"}
                              </Badge>
                              {existingOverride?.is_validated ? (
                                <Badge tone="success" emphasis="soft">✓ Validated</Badge>
                              ) : existingOverride?.validation_error ? (
                                <Badge tone="danger" emphasis="soft" title={existingOverride.validation_error}>⚠ Validation failed</Badge>
                              ) : existingOverride ? (
                                <Badge tone="warning" emphasis="soft">Not validated</Badge>
                              ) : (
                                <span className="text-zinc-500 text-caption">Using default path</span>
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
                            <div className="text-caption text-amber-300/80 flex items-center gap-1">
                              ⚠ Bridge is offline. Cannot validate path until bridge connects.
                            </div>
                          ) : null}

                          {actionError ? (
                            <div className="text-caption text-red-300">{actionError}</div>
                          ) : null}
                        </div>
                      );
                    })}
                  </div>
                )}
              </Panel>
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
                // TODO(FIX): Replace any with strict TypeScript interface matching Odin backend schema
                // TODO(FIX): Replace loose fallback chain with canonical typed schema property
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
                          <Badge tone="warning" emphasis="soft" className="flex items-center gap-1">
                            <Icon name="folder" size={10} className="text-amber-400" />
                            CitC
                          </Badge>
                        ) : (
                          <Badge tone="neutral" emphasis="soft">
                            Local
                          </Badge>
                        )}
                        {project.is_default_conversations ? (
                          <Badge tone="info" emphasis="soft">
                            Default
                          </Badge>
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
