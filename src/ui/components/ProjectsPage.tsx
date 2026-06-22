import { useEffect, useState, useMemo, memo, FormEvent, useCallback } from 'react';
import { useDispatch, useSelector } from 'react-redux';
import { createProjectFromUi, fetchProjectDetail, refreshProjects, selectProject, updateProjectFromUi } from '../store/projectSlice';
import * as daemonApi from '../api/daemonApi';
import type { ProjectAnchor } from '../api/daemonApi';

const blankAnchor: ProjectAnchor = { type: '', value: '', note: '' };

function formatTime(unixMs: number) {
  if (!unixMs) return '—';
  return new Date(unixMs).toLocaleString([], { month: 'short', day: 'numeric', hour: '2-digit', minute: '2-digit' });
}

function cleanAnchors(anchors: ProjectAnchor[]) {
  return anchors
    .map((anchor) => ({ type: anchor.type.trim(), value: anchor.value.trim(), note: anchor.note.trim() }))
    .filter((anchor) => anchor.type || anchor.value || anchor.note);
}

export default function ProjectsPage({ session }: { session: any }) {
  const renderStart = performance.now();
  useEffect(() => {
    const duration = performance.now() - renderStart;
    console.log(`[Render Timer] ProjectsPage took ${duration.toFixed(2)}ms`);
  });
  const dispatch = useDispatch<any>();
  const { projectsById, projectIds, selectedProjectId, loading, detailLoading, mutating, error } = useSelector((state: any) => state.projects);
  const selectedProject = selectedProjectId ? projectsById[selectedProjectId] : null;
  const [page, setPage] = useState<'list' | 'create'>('list');
  const [pickerError, setPickerError] = useState('');
  const [projectAgents, setProjectAgents] = useState<any[]>([]);
  const [allAgents, setAllAgents] = useState<any[]>([]);
  const [agentTemplates, setAgentTemplates] = useState<any[]>([]);
  const [agentProviders, setAgentProviders] = useState<Array<{ name: string }>>([]);
  const [agentBusy, setAgentBusy] = useState(false);
  const [agentError, setAgentError] = useState('');

  useEffect(() => {
    if (session.connected && session.clientToken) dispatch(refreshProjects());
  }, [dispatch, session.connected, session.clientToken]);

  useEffect(() => {
    if (selectedProjectId) dispatch(fetchProjectDetail(selectedProjectId));
  }, [dispatch, selectedProjectId]);



  const refreshProjectAgents = useCallback(async (projectId = selectedProjectId) => {
    if (!projectId) return;
    setAgentError('');
    try {
      const [projectList, allList, templates, providers] = await Promise.all([
        daemonApi.listKnownAgents({ daemonUrl: session.daemonUrl, projectId }),
        daemonApi.listKnownAgents({ daemonUrl: session.daemonUrl }),
        daemonApi.listAgentTemplates({ daemonUrl: session.daemonUrl }).catch(() => []),
        daemonApi.listAgentProviders({ daemonUrl: session.daemonUrl }).catch(() => []),
      ]);
      setProjectAgents(projectList || []);
      setAllAgents(allList || []);
      setAgentTemplates((templates || []).map((template: any) => ({ templateId: template.template_id || template.templateId || template.id, displayName: template.display_name || template.displayName || template.name || template.template_id, roleHint: template.role_hint || template.roleHint || '', defaultProviderProfile: template.default_provider_profile || template.defaultProviderProfile || template.provider_profile || '' })).filter((template: any) => template.templateId));
      const normalizedProviders = (providers || []).map((provider: any) => ({ name: provider.name || String(provider) })).filter((provider: any) => provider.name);
      setAgentProviders(normalizedProviders);
    } catch (err: any) {
      setAgentError(err?.message || 'Failed to load project agents');
    }
  }, [selectedProjectId, session.daemonUrl]);

  useEffect(() => {
    if (selectedProjectId) refreshProjectAgents(selectedProjectId);
  }, [selectedProjectId, session.daemonUrl]);

  function agentRecordId(agent: any) { return agent.agent_record_id || agent.agentRecordId || ''; }
  function agentInstanceId(agent: any) { return agent.agent_instance_id || agent.agentInstanceId || agent.id || ''; }
  function projectDisplayName() { return selectedProject?.name || selectedProject?.projectId || 'Project'; }

  const submitDetail = useCallback((formData: any) => {
    if (!formData.name.trim() || mutating) return;
    dispatch(updateProjectFromUi({
      projectId: formData.projectId,
      name: formData.name.trim(),
      description: formData.description.trim(),
      anchors: cleanAnchors(formData.anchors),
    }));
  }, [dispatch, mutating]);

  const submitCreate = useCallback(async (formData: any) => {
    if (!formData.name.trim() || mutating) return;
    setPage('list');
    try {
      await dispatch(createProjectFromUi({
        name: formData.name.trim(),
        description: formData.description.trim(),
        anchors: cleanAnchors(formData.anchors),
      })).unwrap();
    } catch {
      setPage('create');
    }
  }, [dispatch, mutating]);

  const handleCancelCreate = useCallback(() => {
    setPage('list');
  }, []);

  const handleAddExistingAgent = useCallback(async (agentId: string) => {
    if (!selectedProjectId || agentBusy) return;
    const agent = allAgents.find((item) => (agentRecordId(item) || agentInstanceId(item)) === agentId);
    if (!agent) return;
    setAgentBusy(true);
    setAgentError('');
    try {
      await daemonApi.associateAgentWithProject({
        daemonUrl: session.daemonUrl,
        agentRecordId: agentRecordId(agent),
        agentInstanceId: agentInstanceId(agent),
        projectId: selectedProjectId
      });
      await refreshProjectAgents(selectedProjectId);
    } catch (err: any) {
      setAgentError(err?.message || 'Failed to add agent');
    } finally {
      setAgentBusy(false);
    }
  }, [selectedProjectId, agentBusy, allAgents, session.daemonUrl, refreshProjectAgents]);

  const handleStartProjectAgent = useCallback(async (newAgentFormData: any) => {
    if (!selectedProjectId || !newAgentFormData.provider || agentBusy) return;
    const displayName = newAgentFormData.displayName.trim();
    if (allAgents.some((agent) => (agent.display_name || agent.displayName || agent.alias || agent.id || '').trim().toLowerCase() === displayName.toLowerCase())) {
      setAgentError(`An agent named ${displayName} already exists. Choose a unique display name.`);
      return;
    }
    setAgentBusy(true);
    setAgentError('');
    try {
      const result = await daemonApi.startAgent({ daemonUrl: session.daemonUrl, provider: newAgentFormData.provider, templateId: newAgentFormData.templateId, projectId: selectedProjectId, displayName });
      await refreshProjectAgents(selectedProjectId);
      const refreshed = await daemonApi.listKnownAgents({ daemonUrl: session.daemonUrl, projectId: selectedProjectId });
      setProjectAgents(refreshed || []);
      if (!((refreshed || []).some((agent: any) => (agent.display_name || agent.displayName || agent.alias) === (result.display_name || displayName)))) {
        setAgentError('Agent started, but refreshed project-agent list did not return the requested display name yet. Refresh to reconcile.');
      }
    } catch (err: any) {
      setAgentError(err?.message || 'Failed to start project agent');
    } finally {
      setAgentBusy(false);
    }
  }, [selectedProjectId, agentBusy, allAgents, session.daemonUrl, refreshProjectAgents]);

  const handleRemoveProjectAgent = useCallback(async (agent: any) => {
    const displayName = agent.display_name || agent.displayName || agent.alias || agent.agentInstanceId || agent.id || 'agent';
    if (!window.confirm(`Remove ${displayName} from ${projectDisplayName()}? The agent record remains known; only the project association is removed.`)) return;
    setAgentBusy(true);
    setAgentError('');
    try {
      await daemonApi.disassociateAgentFromProject({ daemonUrl: session.daemonUrl, agentRecordId: agentRecordId(agent), agentInstanceId: agentInstanceId(agent) });
      await refreshProjectAgents(selectedProjectId);
    } catch (err: any) {
      setAgentError(err?.message || 'Failed to remove project agent');
    } finally {
      setAgentBusy(false);
    }
  }, [selectedProjectId, agentBusy, session.daemonUrl, refreshProjectAgents, selectedProject]);

  const availableExistingAgents = useMemo(() => {
    return allAgents.filter((agent) => !projectAgents.some((projectAgent) => (agentRecordId(projectAgent) && agentRecordId(projectAgent) === agentRecordId(agent)) || (agentInstanceId(projectAgent) && agentInstanceId(projectAgent) === agentInstanceId(agent))));
  }, [allAgents, projectAgents]);

  return (
    <main className="flex min-w-0 flex-1 flex-col bg-[var(--fd-canvas)]">
      <header className="framer-panel flex items-center justify-between border-b border-[var(--fd-hairline)] px-6 py-4">
        <div>
          <p className="framer-topline tracking-[0.28em]">Projects</p>
          <h2 className="mt-1 text-2xl font-bold text-white">Project workspace</h2>
        </div>
        <div className="flex gap-2">
          {page === 'create' ? <button type="button" data-debug-id="projects-back-btn" onClick={() => setPage('list')} className="framer-pill-secondary">Back</button> : null}
          <button type="button" data-debug-id="projects-refresh-btn" onClick={() => dispatch(refreshProjects())} disabled={loading} className="framer-pill-secondary disabled:opacity-40">{loading ? 'Refreshing…' : 'Refresh'}</button>
          <button type="button" data-debug-id="projects-new-btn" onClick={() => setPage('create')} className="framer-pill">+ Project</button>
        </div>
      </header>

      <section className="min-h-0 flex-1 overflow-y-auto p-6">
        {error ? <div className="mb-4 rounded-2xl border border-red-500/30 bg-red-500/10 p-3 text-sm text-red-200">{error}</div> : null}
        {pickerError ? <div className="mb-4 rounded-2xl border border-amber-500/30 bg-amber-500/10 p-3 text-sm text-amber-100">{pickerError}</div> : null}

        {page === 'create' ? (
          <ProjectCreateForm
            mutating={mutating}
            onSubmit={submitCreate}
            onCancel={handleCancelCreate}
          />
        ) : (
          <div className="grid min-h-full grid-cols-[minmax(300px,0.9fr)_minmax(420px,1.3fr)] gap-5">
            <div className="space-y-2">
              {projectIds.map((projectId) => {
                const project = projectsById[projectId];
                return (
                  <button key={projectId} type="button" data-debug-id={`project-list-item-${projectId}`} onClick={() => dispatch(selectProject(projectId))} className={`framer-card w-full p-4 text-left transition  ${selectedProjectId === projectId ? 'border-[var(--fd-accent-blue)]' : ''}`}>
                    <p className="font-semibold text-white">{project.name || project.projectId}</p>
                    <p className="mt-1 break-all text-xs text-[#999]">{project.projectId}</p>
                    <p className="mt-2 line-clamp-2 text-sm text-[#bbb]">{project.description || 'No description'}</p>
                    <p className="framer-subtext mt-2 text-xs">{project.anchors?.length || 0} anchors · updated {formatTime(project.updatedUnixMs || project.createdUnixMs)}</p>
                  </button>
                );
              })}
              {!projectIds.length ? <div className="framer-card border-dashed p-5 text-sm text-[#999]">No projects yet. Create one to get started.</div> : null}
            </div>
            <div className="framer-card-xl p-5">
              {selectedProject ? (
                <>
                  <div className="flex items-start justify-between gap-4">
                    <div>
                      <p className="framer-topline">Project detail {detailLoading ? '· loading…' : ''}</p>
                      <h3 className="mt-1 text-2xl font-bold text-white">{selectedProject.name}</h3>
                      <p className="mt-1 break-all text-xs text-[#999]">{selectedProject.projectId}</p>
                    </div>
                    <span className="framer-chip">{selectedProject.anchors?.length || 0} anchors</span>
                  </div>
                  
                  <ProjectEditForm
                    key={selectedProject.projectId}
                    project={selectedProject}
                    mutating={mutating}
                    onSubmit={submitDetail}
                  />

                  <ProjectAgentsManager
                    projectId={selectedProject.projectId}
                    projectName={selectedProject.name}
                    projectAgents={projectAgents}
                    availableExistingAgents={availableExistingAgents}
                    agentTemplates={agentTemplates}
                    agentProviders={agentProviders}
                    agentBusy={agentBusy}
                    agentError={agentError}
                    onRefresh={() => refreshProjectAgents(selectedProjectId)}
                    onRemoveAgent={handleRemoveProjectAgent}
                    onAddExistingAgent={handleAddExistingAgent}
                    onStartNewAgent={handleStartProjectAgent}
                  />
                </>
              ) : <p className="text-sm text-[#999]">Select a project to view details.</p>}
            </div>
          </div>
        )}
      </section>
    </main>
  );
}

// --- OPTIMIZED SUB-COMPONENTS FOR FORM STATE ISOLATION ---

interface ProjectCreateFormProps {
  mutating: boolean;
  onSubmit: (formData: any) => void;
  onCancel: () => void;
}

function ProjectCreateForm({
  mutating,
  onSubmit,
  onCancel
}: ProjectCreateFormProps) {
  console.log('[Render] ProjectCreateForm');
  const [form, setForm] = useState({ name: '', description: '', anchors: [{ ...blankAnchor }] as ProjectAnchor[] });

  function updateAnchor(index: number, patch: Partial<ProjectAnchor>) {
    setForm((current) => ({
      ...current,
      anchors: current.anchors.map((anchor, anchorIndex) => anchorIndex === index ? { ...anchor, ...patch } : anchor),
    }));
  }

  function removeAnchor(index: number) {
    setForm((current) => ({ ...current, anchors: current.anchors.filter((_, anchorIndex) => anchorIndex !== index) }));
  }

  async function chooseDirectoryAnchor(index: number) {
    if (!window.odinApi?.pickDirectory) return;
    try {
      const result = await window.odinApi.pickDirectory();
      if (result && !result.canceled && result.path) {
        updateAnchor(index, { value: result.path });
      }
    } catch {
      // Ignore
    }
  }

  const handleSubmit = (e: FormEvent) => {
    e.preventDefault();
    if (!form.name.trim()) return;
    onSubmit(form);
  };

  return (
    <form onSubmit={handleSubmit} className="framer-card-xl mx-auto max-w-4xl space-y-4 p-5">
      <div>
        <p className="framer-topline">Create project</p>
        <h3 className="mt-1 text-xl font-bold text-white">New project</h3>
        <p className="mt-2 text-sm text-[#999]">Project id is generated by the daemon. Anchors are intentionally loose type/value/note records.</p>
      </div>
      <input data-debug-id="create-project-name" value={form.name} onChange={(event) => setForm({ ...form, name: event.target.value })} placeholder="Project name" className="framer-input w-full px-3 py-2" required />
      <textarea data-debug-id="create-project-description" value={form.description} onChange={(event) => setForm({ ...form, description: event.target.value })} placeholder="Optional description" className="framer-input min-h-24 w-full px-3 py-2" />
      <div className="space-y-3">
        <div className="flex items-center justify-between">
          <p className="framer-topline">Initial anchors</p>
          <button type="button" data-debug-id="create-project-add-anchor-btn" onClick={() => setForm((current) => ({ ...current, anchors: [...current.anchors, { ...blankAnchor }] }))} className="framer-pill-secondary px-3 py-2 text-xs">+ Anchor</button>
        </div>
        {form.anchors.map((anchor, index) => (
          <div key={index} className="framer-card grid grid-cols-[0.65fr_1fr_1fr_auto_auto] gap-2 p-3">
            <input data-debug-id={`create-anchor-type-${index}`} value={anchor.type} onChange={(event) => updateAnchor(index, { type: event.target.value })} placeholder="type" list="anchor-types" className="framer-input px-3 py-2 text-sm" />
            <input data-debug-id={`create-anchor-value-${index}`} value={anchor.value} onChange={(event) => updateAnchor(index, { value: event.target.value })} placeholder="value" className="framer-input px-3 py-2 text-sm" />
            <input data-debug-id={`create-anchor-note-${index}`} value={anchor.note} onChange={(event) => updateAnchor(index, { note: event.target.value })} placeholder="note" className="framer-input px-3 py-2 text-sm" />
            {anchor.type.trim().toLowerCase() === 'directory' ? <button type="button" data-debug-id={`create-anchor-browse-btn-${index}`} onClick={() => chooseDirectoryAnchor(index)} className="framer-pill-secondary px-3 py-2 text-xs">Browse…</button> : null}
            <button type="button" data-debug-id={`create-anchor-remove-btn-${index}`} onClick={() => removeAnchor(index)} className="framer-pill-secondary px-3 py-2 text-xs">Remove</button>
          </div>
        ))}
        <datalist id="anchor-types"><option value="directory" /><option value="git_repo" /><option value="file" /><option value="url" /><option value="custom" /></datalist>
      </div>
      <div className="flex justify-end gap-2">
        <button type="button" data-debug-id="create-project-cancel-btn" onClick={onCancel} className="framer-pill-secondary">Cancel</button>
        <button data-debug-id="create-project-submit-btn" disabled={!form.name.trim() || mutating} className="framer-pill disabled:opacity-40">
          {mutating ? 'Creating…' : 'Create project'}
        </button>
      </div>
    </form>
  );
}

interface ProjectEditFormProps {
  project: any;
  mutating: boolean;
  onSubmit: (formData: any) => void;
}

function ProjectEditForm({
  project,
  mutating,
  onSubmit
}: ProjectEditFormProps) {
  console.log('[Render] ProjectEditForm', project.projectId);
  const [form, setForm] = useState({
    projectId: project.projectId,
    name: project.name || '',
    description: project.description || '',
    anchors: (project.anchors?.length ? project.anchors : [{ ...blankAnchor }]).map((anchor: any) => ({ type: anchor.type || '', value: anchor.value || '', note: anchor.note || '' })) as ProjectAnchor[],
  });

  function updateAnchor(index: number, patch: Partial<ProjectAnchor>) {
    setForm((current) => ({
      ...current,
      anchors: current.anchors.map((anchor, anchorIndex) => anchorIndex === index ? { ...anchor, ...patch } : anchor),
    }));
  }

  function removeAnchor(index: number) {
    setForm((current) => ({ ...current, anchors: current.anchors.filter((_, anchorIndex) => anchorIndex !== index) }));
  }

  async function chooseDirectoryAnchor(index: number) {
    if (!window.odinApi?.pickDirectory) return;
    try {
      const result = await window.odinApi.pickDirectory();
      if (result && !result.canceled && result.path) {
        updateAnchor(index, { value: result.path });
      }
    } catch {
      // Ignore
    }
  }

  const handleSubmit = (e: FormEvent) => {
    e.preventDefault();
    if (!form.name.trim()) return;
    onSubmit(form);
  };

  return (
    <form onSubmit={handleSubmit} className="mt-5 space-y-4">
      <input data-debug-id="detail-project-name" value={form.name} onChange={(event) => setForm({ ...form, name: event.target.value })} placeholder="Project name" className="framer-input w-full px-3 py-2 text-sm" required />
      <textarea data-debug-id="detail-project-description" value={form.description} onChange={(event) => setForm({ ...form, description: event.target.value })} placeholder="Project description" className="framer-input min-h-24 w-full px-3 py-2 text-sm" />
      <div className="space-y-3">
        <div className="flex items-center justify-between">
          <p className="framer-topline">Anchors</p>
          <button type="button" data-debug-id="detail-project-add-anchor-btn" onClick={() => setForm((current) => ({ ...current, anchors: [...current.anchors, { ...blankAnchor }] }))} className="framer-pill-secondary px-3 py-2 text-xs">+ Anchor</button>
        </div>
        {form.anchors.map((anchor, index) => (
          <div key={index} className="framer-card grid grid-cols-[0.65fr_1fr_1fr_auto_auto] gap-2 p-3">
            <input data-debug-id={`detail-anchor-type-${index}`} value={anchor.type} onChange={(event) => updateAnchor(index, { type: event.target.value })} placeholder="type" list="anchor-types" className="framer-input px-3 py-2 text-sm" />
            <input data-debug-id={`detail-anchor-value-${index}`} value={anchor.value} onChange={(event) => updateAnchor(index, { value: event.target.value })} placeholder="value" className="framer-input px-3 py-2 text-sm" />
            <input data-debug-id={`detail-anchor-note-${index}`} value={anchor.note} onChange={(event) => updateAnchor(index, { note: event.target.value })} placeholder="note" className="framer-input px-3 py-2 text-sm" />
            {anchor.type.trim().toLowerCase() === 'directory' ? <button type="button" data-debug-id={`detail-anchor-browse-btn-${index}`} onClick={() => chooseDirectoryAnchor(index)} className="framer-pill-secondary px-3 py-2 text-xs">Browse…</button> : null}
            <button type="button" data-debug-id={`detail-anchor-remove-btn-${index}`} onClick={() => removeAnchor(index)} className="framer-pill-secondary px-3 py-2 text-xs">Remove</button>
          </div>
        ))}
      </div>
      <div className="flex justify-end">
        <button data-debug-id="detail-project-save-btn" disabled={!form.name.trim() || mutating} className="framer-pill disabled:opacity-40">
          {mutating ? 'Saving…' : 'Save project'}
        </button>
      </div>
    </form>
  );
}

interface ProjectAgentsManagerProps {
  projectId: string;
  projectName: string;
  projectAgents: any[];
  availableExistingAgents: any[];
  agentTemplates: any[];
  agentProviders: any[];
  agentBusy: boolean;
  agentError: string;
  onRefresh: () => void;
  onRemoveAgent: (agent: any) => void;
  onAddExistingAgent: (agentId: string) => void;
  onStartNewAgent: (formData: any) => void;
}

function ProjectAgentsManager({
  projectId,
  projectName,
  projectAgents,
  availableExistingAgents,
  agentTemplates,
  agentProviders,
  agentBusy,
  agentError,
  onRefresh,
  onRemoveAgent,
  onAddExistingAgent,
  onStartNewAgent
}: ProjectAgentsManagerProps) {
  console.log('[Render] ProjectAgentsManager', projectId);
  const [existingAgentId, setExistingAgentId] = useState('');
  const [newAgentForm, setNewAgentForm] = useState({ templateId: 'reviewer', provider: agentProviders[0]?.name || '', displayName: '' });

  useEffect(() => {
    if (!newAgentForm.provider && agentProviders.length > 0) {
      setNewAgentForm((current) => ({ ...current, provider: agentProviders[0].name }));
    }
  }, [agentProviders]);

  function agentRecordId(agent: any) { return agent.agent_record_id || agent.agentRecordId || ''; }
  function agentInstanceId(agent: any) { return agent.agent_instance_id || agent.agentInstanceId || agent.id || ''; }
  function agentDisplayName(agent: any) { return agent.display_name || agent.displayName || agent.alias || agentInstanceId(agent) || 'Unnamed agent'; }
  function agentTemplateId(agent: any) { return agent.template_id || agent.templateId || ''; }
  function agentProvider(agent: any) { return agent.provider_profile || agent.providerProfile || agent.agent_class || ''; }
  
  const suggestedAgentDisplayName = `${newAgentForm.templateId || 'agent'}@${projectName || projectId}`;

  const handleAddExistingSubmit = (e: FormEvent) => {
    e.preventDefault();
    if (!existingAgentId || agentBusy) return;
    onAddExistingAgent(existingAgentId);
    setExistingAgentId('');
  };

  const handleStartNewSubmit = (e: FormEvent) => {
    e.preventDefault();
    if (!newAgentForm.provider || agentBusy) return;
    onStartNewAgent({
      ...newAgentForm,
      displayName: newAgentForm.displayName.trim() || suggestedAgentDisplayName
    });
    setNewAgentForm((current) => ({ ...current, displayName: '' }));
  };

  return (
    <section className="mt-6 space-y-4 border-t border-[var(--fd-hairline)] pt-5">
      <div className="flex items-center justify-between gap-3">
        <div>
          <p className="framer-topline">Project agents</p>
          <p className="mt-1 text-sm text-[#999]">Agents associated with this project_id. Durable ids are daemon-generated and hidden from entry.</p>
        </div>
        <button type="button" data-debug-id="project-agents-refresh-btn" onClick={onRefresh} className="framer-pill-secondary px-3 py-2 text-xs">Refresh</button>
      </div>
      {agentError ? <div className="rounded-2xl border border-amber-500/30 bg-amber-500/10 p-3 text-sm text-amber-100">{agentError}</div> : null}
      <div className="space-y-2">
        {projectAgents.length ? projectAgents.map((agent) => (
          <div key={agentRecordId(agent) || agentInstanceId(agent)} className="framer-card flex items-start justify-between gap-3 p-3">
            <div className="min-w-0">
              <p className="truncate text-sm font-semibold text-white">{agentDisplayName(agent)}</p>
              <p className="mt-1 text-xs text-[#999]">Template {agentTemplateId(agent) || '—'} · Provider {agentProvider(agent) || '—'}</p>
            </div>
            <button type="button" data-debug-id="project-agent-remove-btn" onClick={() => onRemoveAgent(agent)} disabled={agentBusy} className="framer-pill-secondary px-3 py-2 text-xs disabled:opacity-40">Remove</button>
          </div>
        )) : <div className="framer-card border-dashed p-4 text-sm text-[#999]">No agents are associated with this project yet.</div>}
      </div>

      <div className="grid gap-3 lg:grid-cols-2">
        <form onSubmit={handleAddExistingSubmit} className="framer-card space-y-3 p-4">
          <div>
            <p className="framer-topline">Add existing</p>
            <p className="mt-1 text-xs text-[#999]">Associates a known agent with this project.</p>
          </div>
          <select data-debug-id="add-existing-agent-select" value={existingAgentId} onChange={(event) => setExistingAgentId(event.target.value)} className="framer-input w-full px-3 py-2 text-sm">
            <option value="">Select known agent</option>
            {availableExistingAgents.map((agent) => <option key={agentRecordId(agent) || agentInstanceId(agent)} value={agentRecordId(agent) || agentInstanceId(agent)}>{agentDisplayName(agent)}</option>)}
          </select>
          <button data-debug-id="add-existing-agent-submit-btn" disabled={!existingAgentId || agentBusy} className="framer-pill disabled:opacity-40">Add to project</button>
        </form>

        <form onSubmit={handleStartNewSubmit} className="framer-card space-y-3 p-4">
          <div>
            <p className="framer-topline">Add new</p>
            <p className="mt-1 text-xs text-[#999]">Selected project is locked; display name is sent separately from project_id.</p>
          </div>
          <select data-debug-id="new-agent-template-select" value={newAgentForm.templateId} onChange={(event) => setNewAgentForm({ ...newAgentForm, templateId: event.target.value })} className="framer-input w-full px-3 py-2 text-sm">
            {agentTemplates.length ? agentTemplates.map((template) => <option key={template.templateId} value={template.templateId}>{template.displayName || template.templateId}</option>) : <option value="reviewer">reviewer</option>}
          </select>
          <select data-debug-id="new-agent-provider-select" value={newAgentForm.provider} onChange={(event) => setNewAgentForm({ ...newAgentForm, provider: event.target.value })} className="framer-input w-full px-3 py-2 text-sm">
            {agentProviders.length ? agentProviders.map((provider) => <option key={provider.name} value={provider.name}>{provider.name}</option>) : <option value="">No providers</option>}
          </select>
          <input data-debug-id="new-agent-display-name" value={newAgentForm.displayName} onChange={(event) => setNewAgentForm({ ...newAgentForm, displayName: event.target.value })} placeholder={suggestedAgentDisplayName} className="framer-input w-full px-3 py-2 text-sm" />
          <p className="text-xs text-[#999]">Default display_name: <span className="text-white">{suggestedAgentDisplayName}</span>. Project association uses <span className="text-white">{projectId}</span>.</p>
          <button data-debug-id="start-project-agent-btn" disabled={!newAgentForm.provider || agentBusy} className="framer-pill disabled:opacity-40">Start project agent</button>
        </form>
      </div>
    </section>
  );
}
