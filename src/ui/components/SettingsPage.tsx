import { useEffect, useMemo, useState } from 'react';
import { useDispatch, useSelector } from 'react-redux';
import SessionConfig from './SessionConfig';
import { TEAM_KIND_METADATA, paceLabel, taskCountLabel, wantsVcsLabel } from './teamKinds';
import { fetchPreferences, fetchSelectedChat, refreshAgents, refreshSettingsCatalog, saveUserPreference, selectAgent, sendMessageToSelectedAgent } from '../store/chatSlice';
import * as daemonApi from '../api/daemonApi';
import { refreshMemory } from '../store/memorySlice';
import { clearProjectError, deleteProjectFromUi, fetchProjectDetail, refreshProjects, selectProject, updateProjectFromUi } from '../store/projectSlice';
import { VimEditButton } from './VimSidebar';

const SETTINGS_ITEMS = [
  { key: 'templates', label: 'Agent templates' },
  { key: 'kinds', label: 'Team kinds' },
  { key: 'providers', label: 'Providers & model tiers' },
  { key: 'projects', label: 'Projects' },
  { key: 'memory', label: 'Memory browser' },
  { key: 'agents', label: 'Agents (raw registry)' },
  { key: 'direct-chat', label: 'Direct agent chat (debug)' },
  { key: 'daemon', label: 'Daemon connection' },
];

function normalizeTemplate(template: any) {
  return {
    id: template.template_id || template.templateId || template.id || '',
    name: template.display_name || template.displayName || template.name || template.template_id || '',
    role: template.role_hint || template.roleHint || '',
    provider: template.default_provider_profile || template.defaultProviderProfile || '',
    tier: template.suggested_model_tier || template.suggestedModelTier || '',
  };
}

export default function SettingsPage({ session, onReconnect, onBack }: any) {
  const dispatch = useDispatch<any>();
  const { agents, preferences, session: reduxSession, settingsTemplates, settingsProviders, chats, sending } = useSelector((state: any) => state.chat);
  const { recordsById, recordIds, loading: memoryLoading } = useSelector((state: any) => state.memory);
  const { projectsById, projectIds, selectedProjectId, detailLoading: projectDetailLoading, mutating: projectMutating, error: projectError } = useSelector((state: any) => state.projects);
  const [selected, setSelected] = useState('templates');
  const [directAgentId, setDirectAgentId] = useState('');
  const [directDraft, setDirectDraft] = useState('');
  const [debugInfo, setDebugInfo] = useState<{ enabled: boolean; port: number; pid: number } | null>(null);

  const effectiveSession = reduxSession || session;

  useEffect(() => {
    if (!effectiveSession?.daemonUrl) return;
    dispatch(refreshSettingsCatalog()).catch(() => undefined);
    dispatch(fetchPreferences()).catch(() => undefined);
    dispatch(refreshProjects()).catch(() => undefined);
    dispatch(refreshMemory()).catch(() => undefined);
  }, [dispatch, effectiveSession?.daemonUrl, effectiveSession?.clientToken]);

  useEffect(() => {
    if ((window as any).odinApi?.getDebugInfo) (window as any).odinApi.getDebugInfo().then(setDebugInfo);
  }, []);

  useEffect(() => {
    if (!directAgentId && agents[0]?.id) setDirectAgentId(agents[0].id);
  }, [agents, directAgentId]);

  useEffect(() => {
    if (!directAgentId) return;
    dispatch(selectAgent(directAgentId));
    dispatch(fetchSelectedChat({ agentId: directAgentId })).catch(() => undefined);
  }, [dispatch, directAgentId]);

  const templates = useMemo(() => (settingsTemplates || []).map(normalizeTemplate).filter((item: any) => item.id), [settingsTemplates]);
  const providers = useMemo(() => (settingsProviders || []).map((item: any) => typeof item === 'string' ? { name: item } : item).filter((item: any) => item?.name), [settingsProviders]);
  const projects = useMemo(() => (projectIds || []).map((id: string) => projectsById[id]).filter(Boolean), [projectIds, projectsById]);
  const selectedProject = selectedProjectId ? projectsById[selectedProjectId] : null;
  const memoryRecords = useMemo(() => (recordIds || []).map((id: string) => recordsById[id]).filter(Boolean), [recordIds, recordsById]);
  const directMessages = chats[directAgentId] || [];

  return (
    <main className="h-full min-h-0 bg-[#08090b] text-zinc-100">
      <header className="flex items-center justify-between border-b border-white/10 bg-[#0d0f14] px-6 py-4">
        <div>
          <div className="text-xs uppercase tracking-[0.24em] text-zinc-500">Settings</div>
          <h1 className="mt-1 text-2xl font-semibold">System, debug, and daemon views</h1>
          <p className="mt-1 text-sm text-zinc-500">Moved legacy top-level tabs into this Settings surface. Data is hydrated by shared Redux/HTTP loads.</p>
        </div>
        <button data-debug-id="settings-back-btn" type="button" onClick={onBack} className="rounded-xl bg-white/10 px-4 py-2 text-sm hover:bg-white/15">Back</button>
      </header>

      <div className="grid h-[calc(100%-73px)] grid-cols-[240px_minmax(0,1fr)]">
        <nav className="border-r border-white/10 bg-[#0d0f14] p-3">
          <div className="space-y-1">
            {SETTINGS_ITEMS.map((item) => (
              <button key={item.key} data-debug-id={`settings-nav-${item.key}`} onClick={() => setSelected(item.key)} className={`w-full rounded-xl px-3 py-2 text-left text-sm ${selected === item.key ? 'bg-white text-black' : 'bg-white/5 text-zinc-300 hover:bg-white/10'}`}>{item.label}</button>
            ))}
          </div>
          <div className="mt-4 rounded-xl bg-white/[0.04] p-3 text-[11px] text-zinc-500">
            Freshness: Home-level periodic and WebSocket refreshes keep agents/tasks/chains current; Settings mounts dispatch HTTP-backed Redux loads for templates, preferences, and memory.
          </div>
        </nav>

        <section className="min-w-0 overflow-y-auto p-6">
          {selected === 'templates' && <TemplatesPanel templates={templates} />}
          {selected === 'kinds' && <TeamKindsPanel />}
          {selected === 'providers' && <ProvidersPanel providers={providers} preferences={preferences || []} onSaveDefault={async (key: string, value: string) => { await dispatch(saveUserPreference({ key, value })); dispatch(fetchPreferences()); }} />}
          {selected === 'projects' && <ProjectsPanel projects={projects} selectedProjectId={selectedProjectId} selectedProject={selectedProject} loading={projectDetailLoading} mutating={projectMutating} error={projectError} onSelect={(projectId: string) => { dispatch(selectProject(projectId)); dispatch(fetchProjectDetail(projectId)); }} onSave={(payload: any) => dispatch(updateProjectFromUi(payload))} onDelete={async (projectId: string) => { await dispatch(deleteProjectFromUi({ projectId })); dispatch(clearProjectError()); }} />}
          {selected === 'memory' && <MemoryPanel records={memoryRecords} loading={memoryLoading} />}
          {selected === 'agents' && <AgentsPanel agents={agents} templates={templates} providers={providers} onCreateAgent={async (payload: any) => { await daemonApi.createAgent({ daemonUrl: effectiveSession.daemonUrl, displayName: payload.displayName, templateId: payload.templateId, providerProfile: payload.providerProfile, modelTier: payload.modelTier }); await dispatch(refreshAgents()); }} />}
          {selected === 'direct-chat' && <DirectChatPanel agents={agents} agentId={directAgentId} setAgentId={setDirectAgentId} messages={directMessages} draft={directDraft} setDraft={setDirectDraft} sending={sending} onSend={() => { const body = directDraft.trim(); if (!body || !directAgentId) return; dispatch(sendMessageToSelectedAgent({ body, tempId: `settings_${Date.now()}` })); setDirectDraft(''); }} />}
          {selected === 'daemon' && <DaemonPanel session={effectiveSession} onReconnect={onReconnect} debugInfo={debugInfo} setDebugInfo={setDebugInfo} />}
        </section>
      </div>
    </main>
  );
}

function Panel({ title, subtitle, children }: any) {
  return <div className="mx-auto max-w-5xl"><div className="mb-5"><h2 className="text-3xl font-semibold">{title}</h2><p className="mt-1 text-sm text-zinc-500">{subtitle}</p></div>{children}</div>;
}

function TemplatesPanel({ templates }: any) {
  return <Panel title="Agent templates" subtitle="Template registry moved from the legacy Agents tab. Read-only list for this UI pass."><div className="grid gap-3">{templates.length === 0 ? <Empty text="No templates loaded." /> : templates.map((template: any) => <Card key={template.id}><div className="font-semibold">{template.name || template.id}</div><div className="mt-1 text-sm text-zinc-500">{template.id} · role {template.role || '—'} · provider {template.provider || '—'} · tier {template.tier || '—'}</div></Card>)}</div></Panel>;
}

function TeamKindsPanel() {
  return <Panel title="Team kinds" subtitle="Closed-set daemon team kinds. Read-only."><div className="grid gap-3 md:grid-cols-2">{TEAM_KIND_METADATA.map((kind) => <Card key={kind.key}><div className="flex items-center justify-between"><div className="font-semibold">{kind.label}</div><span className="rounded-full bg-white/10 px-2 py-0.5 text-xs text-zinc-400">{kind.key}</span></div><div className="mt-2 text-sm text-zinc-500">{kind.description}</div><div className="mt-3 flex flex-wrap gap-1 text-xs">{[`${paceLabel(kind.pace)} pace`, taskCountLabel(kind.expectedTaskCount), `${kind.collaboratingAgentCount} agents`, `VCS: ${wantsVcsLabel(kind.wantsVcsMode)}`].map((badge) => <span key={badge} className="rounded-full bg-white/10 px-2 py-0.5 text-zinc-300">{badge}</span>)}</div><div className="mt-3 flex flex-wrap gap-1">{kind.scaffolds.map((scaffold) => <span key={scaffold.key} className="rounded-full bg-sky-400/10 px-2 py-0.5 text-xs text-sky-200">{scaffold.label} · {paceLabel(scaffold.pace)} · {scaffold.expectedTaskCount} tasks</span>)}</div></Card>)}</div></Panel>;
}

function preferenceValue(preferences: any[], key: string, fallback = '') {
  const pref = (preferences || []).find((item: any) => item.key === key);
  return String(pref?.value ?? pref?.default_value ?? pref?.defaultValue ?? fallback);
}

function ProvidersPanel({ providers, preferences, onSaveDefault }: any) {
  const [provider, setProvider] = useState('');
  const [tier, setTier] = useState('normal');
  useEffect(() => {
    setProvider(preferenceValue(preferences, 'default_agent_provider_profile', providers[0]?.name || 'pi'));
    setTier(preferenceValue(preferences, 'default_agent_model_tier', 'normal'));
  }, [preferences, providers]);
  const save = async (event: any) => {
    event.preventDefault();
    await onSaveDefault('default_agent_provider_profile', provider.trim() || 'pi');
    await onSaveDefault('default_agent_model_tier', tier || 'normal');
  };
  const visiblePreferences = (preferences || []).slice(0, 12);
  return <Panel title="Providers & model tiers" subtitle="Provider profiles, model tiers, and generated-team-agent defaults."><div className="grid gap-4 lg:grid-cols-2"><Card><h3 className="font-semibold">Generated team agent defaults</h3><p className="mt-1 text-sm text-zinc-500">Used for generated names such as coordinator@project-chain when a team role does not explicitly override provider/tier.</p><form onSubmit={save} className="mt-4 space-y-3"><label className="block text-sm text-zinc-300">Default provider<select data-debug-id="settings-default-agent-provider-select" value={provider} onChange={(event) => setProvider(event.target.value)} className="mt-1 w-full rounded-xl border border-white/10 bg-black/30 px-3 py-2 text-sm outline-none focus:border-sky-400">{providers.length === 0 && <option value={provider || 'pi'}>{provider || 'pi'}</option>}{providers.map((item: any) => <option key={item.name} value={item.name}>{item.name}</option>)}</select></label><label className="block text-sm text-zinc-300">Default model tier<select data-debug-id="settings-default-agent-tier-select" value={tier} onChange={(event) => setTier(event.target.value)} className="mt-1 w-full rounded-xl border border-white/10 bg-black/30 px-3 py-2 text-sm outline-none focus:border-sky-400"><option value="normal">normal</option><option value="smart">smart</option></select></label><button data-debug-id="settings-default-agent-save-btn" type="submit" className="rounded-xl bg-sky-400 px-4 py-2 text-sm font-semibold text-black hover:bg-sky-300">Save defaults</button></form></Card><Card><h3 className="font-semibold">Providers</h3><div className="mt-3 space-y-2">{providers.length === 0 ? <div className="text-sm text-zinc-500">No providers loaded.</div> : providers.map((item: any) => <div key={item.name} className="rounded-lg bg-black/20 px-3 py-2 text-sm">{item.name}</div>)}</div></Card><Card><h3 className="font-semibold">Preference snapshot</h3><div className="mt-3 space-y-2">{visiblePreferences.length === 0 ? <div className="text-sm text-zinc-500">No preferences loaded.</div> : visiblePreferences.map((pref: any) => <div key={pref.key} className="rounded-lg bg-black/20 px-3 py-2 text-sm"><div className="text-zinc-300">{pref.key}</div><div className="truncate text-xs text-zinc-500">{String(pref.value || '')}</div></div>)}</div></Card></div></Panel>;
}

function projectAnchorValue(project: any, type: string, fallback = '') {
  const anchor = (project?.anchors || []).find((item: any) => item.type === type);
  return anchor?.value || fallback;
}

function buildVcsAnchors(vcsEnabled: boolean, directory: string, vcsKind: string, baseRef: string, worktreeRoot: string) {
  if (!vcsEnabled) return [{ type: 'vcs_kind', value: 'none', note: 'Project VCS disabled from UI' }];
  const anchors = [
    { type: 'directory', value: directory.trim(), note: 'Local project directory used to detect and provision VCS workspaces' },
    { type: 'vcs_kind', value: vcsKind, note: 'VCS backend: auto, git, jj, or none' },
  ].filter((anchor) => anchor.value);
  if (baseRef.trim()) anchors.push({ type: 'base_ref', value: baseRef.trim(), note: 'Default base ref for new workspaces' });
  if (worktreeRoot.trim()) anchors.push({ type: 'worktree_root', value: worktreeRoot.trim(), note: 'Parent directory for provisioned worktrees' });
  return anchors;
}

function ProjectsPanel({ projects, selectedProjectId, selectedProject, loading, mutating, error, onSelect, onSave, onDelete }: any) {
  const [name, setName] = useState('');
  const [description, setDescription] = useState('');
  const [vcsEnabled, setVcsEnabled] = useState(false);
  const [directory, setDirectory] = useState('');
  const [vcsKind, setVcsKind] = useState('auto');
  const [baseRef, setBaseRef] = useState('');
  const [worktreeRoot, setWorktreeRoot] = useState('');
  const [deleteConfirming, setDeleteConfirming] = useState(false);

  useEffect(() => {
    setName(selectedProject?.name || '');
    setDescription(selectedProject?.description || '');
    const nextDirectory = projectAnchorValue(selectedProject, 'directory');
    const nextVcsKind = projectAnchorValue(selectedProject, 'vcs_kind', 'auto');
    setVcsEnabled(Boolean(nextDirectory) && nextVcsKind !== 'none');
    setDirectory(nextDirectory);
    setVcsKind(nextVcsKind === 'none' ? 'auto' : nextVcsKind);
    setBaseRef(projectAnchorValue(selectedProject, 'base_ref'));
    setWorktreeRoot(projectAnchorValue(selectedProject, 'worktree_root'));
    setDeleteConfirming(false);
    // Repopulate the form only when the selected project identity changes.
    // Depending on name/description/anchors would re-run on every refresh (those
    // are rebuilt with fresh references) and wipe in-progress edits. See hotfix.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [selectedProject?.projectId]);

  return (
    <Panel title="Projects" subtitle="View project details and update/delete them from the UI.">
      <div className="grid gap-4 lg:grid-cols-[280px_minmax(0,1fr)]">
        <Card>
          <h3 className="font-semibold">Project list</h3>
          <div className="mt-3 space-y-2">
            {projects.length === 0 ? <div className="text-sm text-zinc-500">No projects loaded.</div> : projects.map((project: any) => (
              <button key={project.projectId} data-debug-id={`settings-project-${project.projectId}`} type="button" onClick={() => onSelect(project.projectId)} className={`w-full rounded-xl px-3 py-2 text-left text-sm ${selectedProjectId === project.projectId ? 'bg-white text-black' : 'bg-black/20 text-zinc-300 hover:bg-white/10'}`}>
                <div className="font-medium">{project.name || project.projectId}</div>
                <div className="mt-1 text-xs opacity-70">{project.projectId}</div>
              </button>
            ))}
          </div>
        </Card>
        <Card>
          <h3 className="font-semibold">Project details</h3>
          {!selectedProject ? <div className="mt-3 text-sm text-zinc-500">Select a project to view or edit it.</div> : (
            <form className="mt-3 space-y-4" onSubmit={(event) => { event.preventDefault(); if (!selectedProject?.projectId) return; onSave({ projectId: selectedProject.projectId, name: name.trim(), description: description.trim(), anchors: buildVcsAnchors(vcsEnabled, directory, vcsKind, baseRef, worktreeRoot) }); }}>
              <div className="text-xs text-zinc-500">Project ID: <span className="font-mono">{selectedProject.projectId}</span></div>
              <label className="block text-sm text-zinc-300">Name
                <input data-debug-id="settings-project-name-input" value={name} onChange={(event) => setName(event.target.value)} className="mt-1 w-full rounded-xl border border-white/10 bg-black/30 px-3 py-2 text-sm outline-none focus:border-sky-400" />
              </label>
              <label className="block text-sm text-zinc-300">
                <div className="flex items-center justify-between mb-1">
                  <span>Description</span>
                  <VimEditButton
                    debugId="settings-project-description-vim-edit-btn"
                    title="Edit Project Description"
                    value={description}
                    onApply={(newVal) => setDescription(newVal)}
                    lang="markdown"
                  />
                </div>
                <textarea data-debug-id="settings-project-description-textarea" value={description} onChange={(event) => setDescription(event.target.value)} rows={5} className="mt-1 w-full resize-none rounded-xl border border-white/10 bg-black/30 px-3 py-2 text-sm outline-none focus:border-sky-400" />
              </label>
              <div className="rounded-2xl border border-white/10 bg-black/20 p-4">
                <label className="flex items-center gap-3 text-sm text-zinc-300">
                  <input data-debug-id="settings-project-vcs-enabled-checkbox" type="checkbox" checked={vcsEnabled} onChange={(event) => setVcsEnabled(event.target.checked)} className="h-4 w-4" />
                  Enable VCS workspaces for chains in this project
                </label>
                <div className="mt-3 grid gap-3 md:grid-cols-2">
                  <label className="text-sm text-zinc-300">Project directory / directory
                    <input data-debug-id="settings-project-directory-input" value={directory} onChange={(event) => setDirectory(event.target.value)} disabled={!vcsEnabled} placeholder="/path/to/project" className="mt-1 w-full rounded-xl border border-white/10 bg-black/30 px-3 py-2 text-sm outline-none focus:border-sky-400 disabled:opacity-50" />
                  </label>
                  <label className="text-sm text-zinc-300">VCS kind / vcs_kind
                    <select data-debug-id="settings-project-vcs-kind-select" value={vcsKind} onChange={(event) => setVcsKind(event.target.value)} disabled={!vcsEnabled} className="mt-1 w-full rounded-xl border border-white/10 bg-black/30 px-3 py-2 text-sm outline-none focus:border-sky-400 disabled:opacity-50"><option value="auto">auto</option><option value="git">git</option><option value="jj">jj</option><option value="fig">fig</option></select>
                  </label>
                  <label className="text-sm text-zinc-300">Base ref / base_ref {vcsKind === 'fig' && '(CL / p4base)'}
                    <input data-debug-id="settings-project-base-ref-input" value={baseRef} onChange={(event) => setBaseRef(event.target.value)} disabled={!vcsEnabled} placeholder={vcsKind === 'fig' ? 'CL or p4base' : 'main'} className="mt-1 w-full rounded-xl border border-white/10 bg-black/30 px-3 py-2 text-sm outline-none focus:border-sky-400 disabled:opacity-50" />
                  </label>
                  <label className="text-sm text-zinc-300">Worktree root / worktree_root
                    <input data-debug-id="settings-project-worktree-root-input" value={worktreeRoot} onChange={(event) => setWorktreeRoot(event.target.value)} disabled={!vcsEnabled} placeholder="/tmp/heimdall-worktrees/my-project" className="mt-1 w-full rounded-xl border border-white/10 bg-black/30 px-3 py-2 text-sm outline-none focus:border-sky-400 disabled:opacity-50" />
                  </label>
                </div>
                {vcsEnabled && !directory.trim() && <div className="mt-3 text-xs text-amber-200">Project directory is required to enable VCS support.</div>}
                <div className="mt-3 text-xs text-zinc-500">Anchors: {(selectedProject.anchors || []).length}. Created {selectedProject.createdUnixMs || 0}. Updated {selectedProject.updatedUnixMs || 0}.</div>
              </div>
              {error && <div className="rounded-xl border border-red-500/20 bg-red-500/10 p-3 text-sm text-red-200">{error}</div>}
              <div className="flex flex-wrap justify-between gap-2">
                {!deleteConfirming ? <button data-debug-id="settings-project-delete-btn" type="button" disabled={mutating || selectedProject.projectId === 'heimdall-system'} onClick={() => setDeleteConfirming(true)} className="rounded-xl bg-red-500/15 px-4 py-2 text-sm text-red-200 hover:bg-red-500/25 disabled:cursor-not-allowed disabled:opacity-50">Delete project</button> : <button data-debug-id="settings-project-confirm-delete-btn" type="button" disabled={mutating || selectedProject.projectId === 'heimdall-system'} onClick={() => onDelete(selectedProject.projectId)} className="rounded-xl bg-red-500 px-4 py-2 text-sm font-semibold text-white hover:bg-red-400 disabled:cursor-not-allowed disabled:opacity-50">Confirm delete</button>}
                <button data-debug-id="settings-project-save-btn" type="submit" disabled={mutating || !name.trim() || loading || (vcsEnabled && !directory.trim())} className="rounded-xl bg-sky-400 px-4 py-2 text-sm font-semibold text-black hover:bg-sky-300 disabled:cursor-not-allowed disabled:opacity-50">{mutating ? 'Saving…' : 'Save changes'}</button>
              </div>
            </form>
          )}
        </Card>
      </div>
    </Panel>
  );
}

function MemoryPanel({ records, loading }: any) {
  return <Panel title="Memory browser" subtitle="Redux-backed memory records; refreshed on Settings mount and memory events.">{loading ? <Empty text="Loading memory…" /> : <div className="grid gap-3">{records.length === 0 ? <Empty text="No memory records loaded." /> : records.slice(0, 50).map((record: any) => <Card key={record.memoryId || record.id}><div className="font-semibold">{record.title || record.memoryId || record.id}</div><div className="mt-1 text-sm text-zinc-500">{record.type || 'type'} · {record.status || 'status'}</div><div className="mt-1 text-xs text-zinc-500">Target: {record.target || 'global'}</div><div className="mt-2 line-clamp-3 text-sm text-zinc-300">{record.body || record.content || ''}</div></Card>)}</div>}</Panel>;
}

function AgentsPanel({ agents, templates, providers, onCreateAgent }: any) {
  const [open, setOpen] = useState(false);
  const [displayName, setDisplayName] = useState('');
  const [templateId, setTemplateId] = useState('');
  const [providerProfile, setProviderProfile] = useState('');
  const [modelTier, setModelTier] = useState('normal');
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState('');

  useEffect(() => {
    if (!templateId && templates?.[0]?.id) setTemplateId(templates[0].id);
    if (!providerProfile && providers?.[0]?.name) setProviderProfile(providers[0].name);
  }, [templates, providers, templateId, providerProfile]);

  const reset = () => {
    setDisplayName('');
    setTemplateId(templates?.[0]?.id || '');
    setProviderProfile(providers?.[0]?.name || '');
    setModelTier('normal');
    setError('');
  };
  const close = () => { if (saving) return; setOpen(false); reset(); };
  const submit = async (event: any) => {
    event.preventDefault();
    const name = displayName.trim();
    if (!name) { setError('Agent name is required.'); return; }
    if (!templateId) { setError('Choose a predefined role/template.'); return; }
    setSaving(true);
    setError('');
    try {
      await onCreateAgent({ displayName: name, templateId, providerProfile, modelTier });
      setOpen(false);
      reset();
    } catch (err: any) {
      setError(err?.message || 'Failed to create agent');
    } finally {
      setSaving(false);
    }
  };

  return <Panel title="Agents" subtitle="Create reusable durable agents by name + predefined role. Runtime sessions are started separately."><div className="mb-4 flex items-center justify-between gap-3"><div className="text-sm text-zinc-500">{agents.length} known agent{agents.length === 1 ? '' : 's'} loaded.</div><button data-debug-id="settings-create-agent-btn" type="button" onClick={() => { reset(); setOpen(true); }} className="rounded-xl bg-sky-400 px-4 py-2 text-sm font-semibold text-black hover:bg-sky-300">+ Create agent</button></div><div className="grid gap-3">{agents.length === 0 ? <Empty text="No agents loaded." /> : agents.map((agent: any) => <Card key={agent.id}><div className="flex items-center justify-between gap-3"><div className="font-semibold">{agent.label || agent.id}</div><span className="rounded-full bg-white/10 px-2 py-0.5 text-xs text-zinc-400">{agent.state || agent.status || 'unknown'}</span></div><div className="mt-1 text-xs text-zinc-500">{agent.id} · agent {agent.agentId || agent.agent_id || agent.id} · project {agent.projectId || '—'} · current task {agent.currentTaskId || 'idle'} · activity {agent.activityStatus || 'unknown'}</div></Card>)}</div>{open && <div data-debug-id="settings-create-agent-modal" className="fixed inset-0 z-50 flex items-center justify-center bg-black/70 px-4"><form onSubmit={submit} className="w-full max-w-lg rounded-3xl border border-white/10 bg-[#0d0f14] p-5 shadow-2xl"><div className="flex items-start justify-between gap-3"><div><h3 className="text-xl font-semibold">Create reusable agent</h3><p className="mt-1 text-sm text-zinc-500">Choose a durable name and predefined role. No project is required.</p></div><button data-debug-id="settings-create-agent-cancel-btn" type="button" onClick={close} className="rounded-xl bg-white/10 px-3 py-2 text-sm hover:bg-white/15">Close</button></div><div className="mt-5 space-y-4"><label className="block text-sm text-zinc-300">Agent name<input data-debug-id="settings-create-agent-name-input" value={displayName} onChange={(event) => setDisplayName(event.target.value)} placeholder="Alice Coder" className="mt-1 w-full rounded-xl border border-white/10 bg-black/30 px-3 py-2 text-sm outline-none focus:border-sky-400" /></label><label className="block text-sm text-zinc-300">Predefined role<select data-debug-id="settings-create-agent-template-select" value={templateId} onChange={(event) => setTemplateId(event.target.value)} className="mt-1 w-full rounded-xl border border-white/10 bg-black/30 px-3 py-2 text-sm outline-none focus:border-sky-400"><option value="">Choose role/template</option>{templates.map((template: any) => <option key={template.id} value={template.id}>{template.name || template.id}</option>)}</select></label><div className="grid gap-3 sm:grid-cols-2"><label className="block text-sm text-zinc-300">Provider<select data-debug-id="settings-create-agent-provider-select" value={providerProfile} onChange={(event) => setProviderProfile(event.target.value)} className="mt-1 w-full rounded-xl border border-white/10 bg-black/30 px-3 py-2 text-sm outline-none focus:border-sky-400"><option value="">Default</option>{providers.map((provider: any) => <option key={provider.name} value={provider.name}>{provider.name}</option>)}</select></label><label className="block text-sm text-zinc-300">Model tier<select data-debug-id="settings-create-agent-tier-select" value={modelTier} onChange={(event) => setModelTier(event.target.value)} className="mt-1 w-full rounded-xl border border-white/10 bg-black/30 px-3 py-2 text-sm outline-none focus:border-sky-400"><option value="normal">normal</option><option value="smart">smart</option><option value="cheap">cheap</option></select></label></div>{error && <div data-debug-id="settings-create-agent-error" className="rounded-xl border border-red-400/30 bg-red-400/10 px-3 py-2 text-sm text-red-100">{error}</div>}</div><div className="mt-5 flex justify-end gap-2"><button data-debug-id="settings-create-agent-cancel-secondary-btn" type="button" onClick={close} className="rounded-xl bg-white/10 px-4 py-2 text-sm hover:bg-white/15">Cancel</button><button data-debug-id="settings-create-agent-submit-btn" type="submit" disabled={saving || !displayName.trim() || !templateId} className="rounded-xl bg-sky-400 px-4 py-2 text-sm font-semibold text-black hover:bg-sky-300 disabled:cursor-not-allowed disabled:bg-white/10 disabled:text-zinc-500">{saving ? 'Creating…' : 'Create agent'}</button></div></form></div>}</Panel>;
}

function DirectChatPanel({ agents, agentId, setAgentId, messages, draft, setDraft, sending, onSend }: any) {
  return (
    <Panel title="Direct agent chat (debug)" subtitle="Debug affordance only. Main-path chat remains chain coordinator-only.">
      <Card>
        <label className="text-sm text-zinc-300">
          Agent
          <select data-debug-id="settings-direct-chat-agent-select" value={agentId} onChange={(event) => setAgentId(event.target.value)} className="mt-2 w-full rounded-xl border border-white/10 bg-black/30 px-3 py-2 text-sm outline-none">
            <option value="">Select agent</option>
            {agents.map((agent: any) => <option key={agent.id} value={agent.id}>{agent.label || agent.id}</option>)}
          </select>
        </label>
        <div data-debug-id="settings-direct-chat-feed" className="mt-4 max-h-80 min-h-48 overflow-y-auto rounded-xl bg-black/20 p-3">
          {messages.length === 0 ? <div className="text-sm text-zinc-500">No direct debug messages loaded.</div> : messages.map((message: any, index: number) => (
            <div key={message.id || message.messageId || index} className={`mb-2 rounded-xl px-3 py-2 text-sm ${message.direction === 'user_to_agent' || message.author === 'user' ? 'ml-8 bg-sky-500/15 text-sky-100' : 'mr-8 bg-white/5 text-zinc-200'}`}>{message.body}</div>
          ))}
        </div>
        <div className="mt-3 flex gap-2">
          <input data-debug-id="settings-direct-chat-input" value={draft} onChange={(event) => setDraft(event.target.value)} onKeyDown={(event) => { if (event.key === 'Enter') onSend(); }} placeholder="Debug direct message to selected agent…" className="min-w-0 flex-1 rounded-xl border border-white/10 bg-black/30 px-3 py-2 text-sm outline-none focus:border-sky-400" />
          <button data-debug-id="settings-direct-chat-send-btn" type="button" onClick={onSend} disabled={sending || !agentId || !draft.trim()} className="rounded-xl bg-sky-400 px-4 py-2 text-sm font-semibold text-black hover:bg-sky-300 disabled:cursor-not-allowed disabled:opacity-50">{sending ? 'Sending…' : 'Send'}</button>
        </div>
      </Card>
    </Panel>
  );
}

function DaemonPanel({ session, onReconnect, debugInfo, setDebugInfo }: any) {
  return <Panel title="Daemon connection" subtitle="Connection profile and Electron debug server."><div className="grid gap-4 lg:grid-cols-2"><Card><SessionConfig session={session} onReconnect={onReconnect} /></Card><Card><h3 className="font-semibold">Electron debug server</h3><label className="mt-4 flex items-center gap-3 text-sm text-zinc-300"><input type="checkbox" checked={Boolean(debugInfo?.enabled)} onChange={async () => { if (!debugInfo || !(window as any).odinApi?.toggleDebugServer) return; setDebugInfo(await (window as any).odinApi.toggleDebugServer(!debugInfo.enabled)); }} />Enabled</label>{debugInfo?.enabled && <div className="mt-3 rounded-xl bg-black/20 p-3 font-mono text-xs text-zinc-400">http://127.0.0.1:{debugInfo.port}<br />pid {debugInfo.pid}</div>}</Card></div></Panel>;
}

function Card({ children }: any) { return <div className="rounded-2xl border border-white/10 bg-white/[0.035] p-4">{children}</div>; }
function Empty({ text }: { text: string }) { return <div className="rounded-2xl border border-dashed border-white/10 p-5 text-sm text-zinc-500">{text}</div>; }
