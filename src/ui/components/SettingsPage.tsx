import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { useDispatch, useSelector } from 'react-redux';
import SessionConfig from './SessionConfig';
// TODO(rtkq-migration owner=task-19f69e242e4): Settings direct-chat debug panel still opens chats via component-level thunk dispatch; replace with RTKQ hooks/initiate during cleanup.
import { addDaemonProfile, fetchSelectedChat, removeDaemonProfile, selectAgent, sendMessageToSelectedAgent } from '../store/chatSlice';
import * as daemonApi from '../api/daemonApi';
import { agentsApi, useListAgentsQuery } from '../api/endpoints/agents';
import { useListMemoryQuery } from '../api/endpoints/memory';
import { useDeleteProjectMutation, useFetchProjectQuery, useListProjectsQuery, useUpdateProjectMutation } from '../api/endpoints/projects';
import { useFetchAgentDefaultsQuery, useFetchPreferencesQuery, useFetchSettingsCatalogQuery, useSaveAgentDefaultMutation, useSavePreferenceMutation } from '../api/endpoints/settings';
import { selectProject } from '../store/projectSlice';
import { VimEditButton } from './VimSidebar';
import ChatHoverCopyButton from './ChatHoverCopyButton';

const DEFAULT_AGENT_USES = ['conversation', 'guide', 'coordinator', 'worker', 'assignee', 'coder', 'tester', 'researcher', 'specialist', 'reviewer'];

function normalizeTemplate(template: any) {
  return {
    id: template.template_id || template.templateId || template.id || '',
    name: template.display_name || template.displayName || template.name || template.template_id || '',
    provider: template.default_provider_profile || template.defaultProviderProfile || '',
    tier: template.suggested_model_tier || template.suggestedModelTier || '',
  };
}

export default function SettingsPage({ session, onReconnect, onBack }: any) {
  const dispatch = useDispatch<any>();
  const { session: reduxSession, chats, sending, daemonProfiles = [] } = useSelector((state: any) => state.chat);
  const effectiveSession = reduxSession || session;
  const memoryQuery = useListMemoryQuery(undefined, { skip: !effectiveSession?.clientToken });
  const { selectedProjectId } = useSelector((state: any) => state.projects);
  const projectsQuery = useListProjectsQuery({ scope: `${effectiveSession?.daemonUrl || ''}:${effectiveSession?.clientInstanceId || ''}:${effectiveSession?.clientToken || ''}` }, { skip: !effectiveSession?.connected || !effectiveSession?.clientToken });
  const selectedProjectListId = selectedProjectId || projectsQuery.data?.projects?.[0]?.projectId || '';
  const selectedProjectQuery = useFetchProjectQuery({ projectId: selectedProjectListId, scope: `${effectiveSession?.daemonUrl || ''}:${effectiveSession?.clientInstanceId || ''}:${effectiveSession?.clientToken || ''}` }, { skip: !effectiveSession?.connected || !effectiveSession?.clientToken || !selectedProjectListId });
  const preferencesQuery = useFetchPreferencesQuery({ scope: `${effectiveSession?.daemonUrl || ''}:${effectiveSession?.clientInstanceId || ''}:${effectiveSession?.clientToken || ''}` }, { skip: !effectiveSession?.connected || !effectiveSession?.clientToken });
  const agentDefaultsQuery = useFetchAgentDefaultsQuery({ scope: `${effectiveSession?.daemonUrl || ''}:${effectiveSession?.clientInstanceId || ''}:${effectiveSession?.clientToken || ''}` }, { skip: !effectiveSession?.connected || !effectiveSession?.clientToken });
  const settingsCatalogQuery = useFetchSettingsCatalogQuery({ scope: `${effectiveSession?.daemonUrl || ''}:${effectiveSession?.clientInstanceId || ''}` }, { skip: !effectiveSession?.connected || !effectiveSession?.daemonUrl });
  const [savePreference] = useSavePreferenceMutation();
  const [saveAgentDefault] = useSaveAgentDefaultMutation();
  const [updateProject, updateProjectState] = useUpdateProjectMutation();
  const [deleteProject, deleteProjectState] = useDeleteProjectMutation();
  const [selected, setSelected] = useState('daemon');
  const [directAgentId, setDirectAgentId] = useState('');
  const [directDraft, setDirectDraft] = useState('');
  const [debugInfo, setDebugInfo] = useState<{ enabled: boolean; port: number; pid: number } | null>(null);

  const agentsQuery = useListAgentsQuery(undefined, {
    skip: !effectiveSession?.daemonUrl,
    pollingInterval: selected === 'agents' || selected === 'direct-chat' || selected === 'daemon' ? 2000 : 0,
  });
  const agents = agentsQuery.data?.agents || [];
  const refetchAgents = useCallback(() => agentsQuery.refetch().catch(() => undefined), [agentsQuery.refetch]);

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

  const templates = useMemo(() => (settingsCatalogQuery.data?.templates || []).map(normalizeTemplate).filter((item: any) => item.id), [settingsCatalogQuery.data?.templates]);
  const providers = useMemo(() => (settingsCatalogQuery.data?.providers || []).map((item: any) => typeof item === 'string' ? { name: item } : item).filter((item: any) => item?.name), [settingsCatalogQuery.data?.providers]);
  const preferences = preferencesQuery.data?.preferences || [];
  const projects = projectsQuery.data?.projects || [];
  const selectedProject = selectedProjectQuery.data?.project || projects.find((project: any) => project.projectId === selectedProjectListId) || null;
  const memoryRecords = memoryQuery.data?.records || [];
  const directMessages = chats[directAgentId] || [];

  const settingsGroups = [
    { title: 'General', items: [{ key: 'defaults', label: 'Default agents' }, { key: 'templates', label: 'Templates' }] },
    { title: 'Connections', items: [{ key: 'daemon', label: 'Daemons' }, { key: 'providers', label: 'Providers' }] },
    { title: 'Workspace', items: [{ key: 'agents', label: 'Agents & templates' }, { key: 'projects', label: 'Projects' }, { key: 'memory', label: 'Memory browser' }, { key: 'direct-chat', label: 'Direct chat' }] },
  ];

  return (
    <main data-debug-id="settings-modal" className="h-full min-h-0 bg-[#08090b] p-5 text-zinc-100">
      <div className="mx-auto grid h-full max-w-6xl overflow-hidden rounded-[22px] border border-white/10 bg-[#0f0f0f] shadow-2xl shadow-black/40 md:grid-cols-[250px_minmax(0,1fr)]">
        <nav data-debug-id="settings-rail" className="min-h-0 overflow-y-auto border-r border-[#262626] bg-[#090909] p-4">
          {settingsGroups.map((group) => (
            <div key={group.title} className="mb-5">
              <div className="mb-2 px-2 text-[10.5px] uppercase tracking-[0.18em] text-zinc-600">{group.title}</div>
              <div className="space-y-1">
                {group.items.map((item) => (
                  <button key={item.key} data-debug-id={`settings-nav-${item.key}`} onClick={() => setSelected(item.key)} className={`w-full rounded-md px-3 py-2 text-left text-[13px] transition ${selected === item.key ? 'bg-[#1c1c1c] text-zinc-100' : 'text-zinc-500 hover:bg-[#141414] hover:text-zinc-100'}`}>{item.label}</button>
                ))}
              </div>
            </div>
          ))}
          <div data-debug-id="settings-single-daemon-note" className="rounded-xl border border-sky-400/20 bg-sky-400/10 p-3 text-[11.5px] leading-5 text-sky-100">v1 is single-active-daemon-first. Switching changes the active daemon; merged multi-daemon views are intentionally not shown.</div>
        </nav>

        <section data-debug-id="settings-body" className="relative min-w-0 overflow-y-auto p-6">
          <button data-debug-id="settings-close-btn" type="button" onClick={onBack} title="Close settings" className="absolute right-5 top-5 rounded-md border border-white/10 bg-[#141414] px-2 py-1 text-sm text-zinc-400 hover:text-zinc-100">✕</button>
          {selected === 'defaults' && <DefaultAgentsPanel defaults={agentDefaultsQuery.data?.defaults || []} identities={agentsQuery.data?.identities || []} agents={agents} loading={agentDefaultsQuery.isFetching} onRefresh={() => agentDefaultsQuery.refetch()} onSave={async (use: string, agentId: string) => { await saveAgentDefault({ use, agentId }).unwrap(); }} />}
          {selected === 'templates' && <TemplatesPanel templates={settingsCatalogQuery.data?.templates || []} session={effectiveSession} providers={providers} onRefetchTemplates={() => settingsCatalogQuery.refetch()} />}
          {selected === 'providers' && <ProvidersPanel providers={providers} preferences={preferences || []} session={effectiveSession} daemonProfiles={daemonProfiles} onSaveDefault={async (key: string, value: string) => { await savePreference({ key, value }).unwrap(); }} />}
          {selected === 'projects' && <ProjectsPanel projects={projects} selectedProjectId={selectedProjectListId} selectedProject={selectedProject} loading={projectsQuery.isFetching || selectedProjectQuery.isFetching} mutating={updateProjectState.isLoading || deleteProjectState.isLoading} error={(updateProjectState.error || deleteProjectState.error) ? 'Project mutation failed' : ''} onSelect={(projectId: string) => { dispatch(selectProject(projectId)); }} onSave={(payload: any) => updateProject(payload).unwrap()} onDelete={async (projectId: string) => { await deleteProject({ projectId }).unwrap(); if (selectedProjectListId === projectId) dispatch(selectProject('')); }} />}
          {selected === 'memory' && <MemoryPanel records={memoryRecords} loading={memoryQuery.isFetching} />}
          {selected === 'agents' && <AgentsPanel agents={agents} templates={templates} providers={providers} onCreateAgent={async (payload: any) => { await daemonApi.createAgent({ daemonUrl: effectiveSession.daemonUrl, displayName: payload.displayName, templateId: payload.templateId, providerProfile: payload.providerProfile, modelTier: payload.modelTier }); await refetchAgents(); }} />}
          {selected === 'direct-chat' && <DirectChatPanel agents={agents} agentId={directAgentId} setAgentId={setDirectAgentId} messages={directMessages} draft={directDraft} setDraft={setDirectDraft} sending={sending} onStart={async (agent: any) => { if (!agent?.id) return; await dispatch(agentsApi.endpoints.startAgent.initiate({ agentInstanceId: agent.id, provider: agent.providerProfile || providers?.[0]?.name || 'pi', templateId: agent.templateId || 'specialist', projectId: agent.projectId || '', displayName: agent.label || agent.id, modelTier: agent.modelTier || 'normal'})).unwrap(); }} onSend={() => { const body = directDraft.trim(); if (!body || !directAgentId) return; dispatch(sendMessageToSelectedAgent({ body, tempId: `settings_${Date.now()}` })); setDirectDraft(''); }} />}
          {selected === 'daemon' && <DaemonPanel session={effectiveSession} daemonProfiles={daemonProfiles} agents={agents} projects={projects} onReconnect={onReconnect} onAddProfile={(payload: any) => dispatch(addDaemonProfile(payload))} onRemoveProfile={(payload: any) => dispatch(removeDaemonProfile(payload))} debugInfo={debugInfo} setDebugInfo={setDebugInfo} />}
        </section>
      </div>
    </main>
  );
}

function Panel({ title, subtitle, children }: any) {
  return <div className="mx-auto max-w-5xl"><div className="mb-5"><h2 className="text-3xl font-semibold">{title}</h2><p className="mt-1 text-sm text-zinc-500">{subtitle}</p></div>{children}</div>;
}

function TemplatesPanel({ templates = [], session, providers = [], onRefetchTemplates }: any) {
  const [open, setOpen] = useState(false);
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState('');
  
  // Form fields
  const [templateId, setTemplateId] = useState('');
  const [displayName, setDisplayName] = useState('');
  const [description, setDescription] = useState('');
  const [persona, setPersona] = useState('');
  const [instructions, setInstructions] = useState('');
  const [defaultProviderProfile, setDefaultProviderProfile] = useState('');
  const [suggestedModelTier, setSuggestedModelTier] = useState('normal');
  const [isEdit, setIsEdit] = useState(false);

  function reset() {
    setTemplateId('');
    setDisplayName('');
    setDescription('');
    setPersona('');
    setInstructions('');
    setDefaultProviderProfile('');
    setSuggestedModelTier('normal');
    setError('');
    setIsEdit(false);
  }

  function openEdit(template: any) {
    setTemplateId(template.template_id || template.templateId || template.id || '');
    setDisplayName(template.display_name || template.displayName || template.name || '');
    setDescription(template.description || '');
    setPersona(template.persona || '');
    setInstructions(template.instructions || '');
    setDefaultProviderProfile(template.default_provider_profile || template.defaultProviderProfile || template.provider || '');
    setSuggestedModelTier(template.suggested_model_tier || template.suggestedModelTier || template.tier || 'normal');
    setError('');
    setIsEdit(true);
    setOpen(true);
  }

  async function submit(e: React.FormEvent) {
    e.preventDefault();
    if (!templateId.trim()) {
      setError('Template ID is required.');
      return;
    }
    setSaving(true);
    setError('');
    try {
      const response = await daemonApi.saveAgentTemplate({
        daemonUrl: session?.daemonUrl || '',
        template: {
          update: isEdit,
          template_id: templateId.trim(),
          display_name: displayName.trim(),
          description: description.trim(),
          persona: persona.trim(),
          instructions: instructions.trim(),
          default_provider_profile: defaultProviderProfile.trim(),
          suggested_model_tier: suggestedModelTier,
        }
      });
      if (response && !response.ok) {
        throw new Error(response.message || 'Failed to save template');
      }
      setOpen(false);
      onRefetchTemplates?.();
    } catch (err: any) {
      setError(err.message || 'An error occurred while saving.');
    } finally {
      setSaving(false);
    }
  }

  async function handleDelete(id: string) {
    if (!window.confirm('Are you sure you want to delete this template?')) return;
    try {
      const response = await daemonApi.archiveAgentTemplate({
        daemonUrl: session?.daemonUrl || '',
        templateId: id
      });
      if (response && !response.ok) {
        alert('Error: ' + response.message);
      } else {
        onRefetchTemplates?.();
      }
    } catch (err: any) {
      alert('Error deleting template: ' + (err.message || err));
    }
  }

  return (
    <div className="mx-auto max-w-5xl">
      <div className="mb-6 flex items-start justify-between">
        <div>
          <h2 className="text-3xl font-semibold">Agent templates</h2>
          <p className="mt-1 text-sm text-zinc-500">Create and manage reusable agent roles, personas, and instructions.</p>
        </div>
        <button
          data-debug-id="templates-create-btn"
          onClick={() => { reset(); setOpen(true); }}
          className="rounded-xl bg-sky-500 px-4 py-2 text-sm font-semibold text-black hover:bg-sky-400"
        >
          + Create Template
        </button>
      </div>

      <div className="grid gap-4">
        {templates.length === 0 ? (
          <div className="rounded-xl border border-white/10 bg-black/30 p-8 text-center text-sm text-zinc-500">
            No templates found. Create one to get started.
          </div>
        ) : (
          templates.map((template: any) => {
            const id = template.template_id || template.templateId || template.id;
            return (
              <div key={id} className="group flex items-start justify-between gap-4 rounded-2xl border border-white/10 bg-[#141414] p-5 hover:border-white/20">
                <div>
                  <div className="flex items-center gap-2">
                    <h3 className="font-semibold text-zinc-100">{template.display_name || template.displayName || template.name || id}</h3>
                    <span className="rounded-full bg-white/10 px-2 py-0.5 text-[10px] font-mono text-zinc-400">{id}</span>
                  </div>
                  <p className="mt-1 text-sm text-zinc-400">{template.description || 'No description provided.'}</p>
                  <div className="mt-3 flex items-center gap-4 text-xs text-zinc-500">
                    {template.default_provider_profile && (
                      <div className="flex items-center gap-1">
                        <span className="uppercase tracking-wider">Provider:</span>
                        <span className="font-medium text-zinc-300">{template.default_provider_profile || template.provider}</span>
                      </div>
                    )}
                    {template.suggested_model_tier && (
                      <div className="flex items-center gap-1">
                        <span className="uppercase tracking-wider">Tier:</span>
                        <span className="font-medium text-zinc-300">{template.suggested_model_tier || template.tier}</span>
                      </div>
                    )}
                  </div>
                </div>
                <div className="flex shrink-0 items-center gap-2 opacity-0 transition-opacity group-hover:opacity-100">
                  <button
                    data-debug-id={`template-edit-btn-${id}`}
                    onClick={() => openEdit(template)}
                    className="rounded-lg bg-white/5 px-3 py-1.5 text-xs font-medium hover:bg-white/15"
                  >
                    Edit
                  </button>
                  <button
                    data-debug-id={`template-delete-btn-${id}`}
                    onClick={() => handleDelete(id)}
                    className="rounded-lg bg-red-500/10 px-3 py-1.5 text-xs font-medium text-red-400 hover:bg-red-500/20 hover:text-red-300"
                  >
                    Delete
                  </button>
                </div>
              </div>
            );
          })
        )}
      </div>

      {open && (
        <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/70 px-4">
          <form onSubmit={submit} className="flex max-h-[90vh] w-full max-w-2xl flex-col rounded-3xl border border-white/10 bg-[#0d0f14] shadow-2xl">
            <div className="flex shrink-0 items-start justify-between gap-3 p-5 pb-0">
              <div>
                <h3 className="text-xl font-semibold">{isEdit ? 'Edit Template' : 'Create Template'}</h3>
                <p className="mt-1 text-sm text-zinc-500">Define the persona, instructions, and default model tier.</p>
              </div>
              <button
                type="button"
                data-debug-id="template-modal-close-btn"
                onClick={() => setOpen(false)}
                className="rounded-xl bg-white/10 px-3 py-2 text-sm hover:bg-white/15"
              >
                Close
              </button>
            </div>
            
            <div className="flex-1 overflow-y-auto p-5 space-y-4">
              <div className="grid gap-4 sm:grid-cols-2">
                <label className="block text-sm text-zinc-300">
                  Template ID
                  <input
                    value={templateId}
                    data-debug-id="template-id-input"
                    onChange={(e) => setTemplateId(e.target.value)}
                    disabled={isEdit}
                    placeholder="e.g. frontend-expert"
                    className="mt-1 w-full rounded-xl border border-white/10 bg-black/30 px-3 py-2 text-sm outline-none focus:border-sky-400 disabled:opacity-50"
                  />
                </label>
                <label className="block text-sm text-zinc-300">
                  Display Name
                  <input
                    value={displayName}
                    data-debug-id="template-name-input"
                    onChange={(e) => setDisplayName(e.target.value)}
                    placeholder="e.g. Frontend Expert"
                    className="mt-1 w-full rounded-xl border border-white/10 bg-black/30 px-3 py-2 text-sm outline-none focus:border-sky-400"
                  />
                </label>
              </div>
              
              <label className="block text-sm text-zinc-300">
                Description
                <input
                  value={description}
                  data-debug-id="template-desc-input"
                  onChange={(e) => setDescription(e.target.value)}
                  placeholder="Brief summary of what this template does"
                  className="mt-1 w-full rounded-xl border border-white/10 bg-black/30 px-3 py-2 text-sm outline-none focus:border-sky-400"
                />
              </label>

              <label className="block text-sm text-zinc-300">
                Persona
                <textarea
                  value={persona}
                  data-debug-id="template-persona-input"
                  onChange={(e) => setPersona(e.target.value)}
                  placeholder="e.g. You are a senior frontend developer..."
                  rows={3}
                  className="mt-1 w-full rounded-xl border border-white/10 bg-black/30 px-3 py-2 text-sm outline-none focus:border-sky-400"
                />
              </label>

              <label className="block text-sm text-zinc-300">
                Instructions
                <textarea
                  value={instructions}
                  data-debug-id="template-instructions-input"
                  onChange={(e) => setInstructions(e.target.value)}
                  placeholder="System instructions and rules..."
                  rows={4}
                  className="mt-1 w-full rounded-xl border border-white/10 bg-black/30 px-3 py-2 text-sm font-mono text-zinc-300 outline-none focus:border-sky-400"
                />
              </label>
              
              <div className="grid gap-4 sm:grid-cols-2">
                <label className="block text-sm text-zinc-300">
                  Default Provider
                  <select
                    value={defaultProviderProfile}
                    data-debug-id="template-provider-select"
                    onChange={(e) => setDefaultProviderProfile(e.target.value)}
                    className="mt-1 w-full rounded-xl border border-white/10 bg-black/30 px-3 py-2 text-sm outline-none focus:border-sky-400"
                  >
                    <option value="">(None)</option>
                    {providers?.map((provider: any) => (
                      <option key={provider.name} value={provider.name}>{provider.name}</option>
                    ))}
                  </select>
                </label>
                <label className="block text-sm text-zinc-300">
                  Suggested Model Tier
                  <select
                    value={suggestedModelTier}
                    data-debug-id="template-tier-select"
                    onChange={(e) => setSuggestedModelTier(e.target.value)}
                    className="mt-1 w-full rounded-xl border border-white/10 bg-black/30 px-3 py-2 text-sm outline-none focus:border-sky-400"
                  >
                    <option value="cheap">cheap</option>
                    <option value="normal">normal</option>
                    <option value="smart">smart</option>
                  </select>
                </label>
              </div>

              {error && (
                <div className="rounded-xl border border-red-400/30 bg-red-400/10 px-3 py-2 text-sm text-red-100">
                  {error}
                </div>
              )}
            </div>
            <div className="flex shrink-0 justify-end gap-2 p-5 pt-0">
              <button
                type="button"
                data-debug-id="template-modal-cancel-btn"
                onClick={() => setOpen(false)}
                className="rounded-xl bg-white/10 px-4 py-2 text-sm hover:bg-white/15"
              >
                Cancel
              </button>
              <button
                type="submit"
                data-debug-id="template-modal-submit-btn"
                disabled={saving || !templateId.trim()}
                className="rounded-xl bg-sky-500 px-4 py-2 text-sm font-semibold text-black hover:bg-sky-400 disabled:cursor-not-allowed disabled:bg-white/10 disabled:text-zinc-500"
              >
                {saving ? 'Saving...' : (isEdit ? 'Save Changes' : 'Create Template')}
              </button>
            </div>
          </form>
        </div>
      )}
    </div>
  );
}

function DefaultAgentsPanel({ defaults, identities = [], agents = [], loading, onRefresh, onSave }: any) {
  const defaultsByUse = useMemo(() => {
    const map: Record<string, string> = {};
    (defaults || []).forEach((row: any) => { if (row?.use) map[String(row.use)] = String(row.agent_id || row.agentId || ''); });
    return map;
  }, [defaults]);
  const options = useMemo(() => {
    const ids = new Set<string>();
    (identities || []).forEach((identity: any) => { const id = String(identity?.agent_id || identity?.agentId || ''); if (id && id !== 'user_proxy') ids.add(id); });
    (agents || []).forEach((agent: any) => {
      const durable = String(agent?.agentId || agent?.agent_id || '').trim();
      if (durable && durable !== 'user_proxy') ids.add(durable);
      const id = String(agent?.id || agent?.agentInstanceId || agent?.agent_instance_id || '');
      if (id && !id.includes('@') && id !== 'user_proxy') ids.add(id);
    });
    DEFAULT_AGENT_USES.forEach((use) => { if (defaultsByUse[use]) ids.add(defaultsByUse[use]); });
    return Array.from(ids).sort();
  }, [agents, defaultsByUse, identities]);
  const [draft, setDraft] = useState<Record<string, string>>({});
  const [savingUse, setSavingUse] = useState('');
  const [message, setMessage] = useState('');
  useEffect(() => {
    const next: Record<string, string> = {};
    DEFAULT_AGENT_USES.forEach((use) => { next[use] = defaultsByUse[use] || ''; });
    setDraft(next);
  }, [defaultsByUse]);
  const saveAll = async () => {
    setMessage('');
    for (const use of DEFAULT_AGENT_USES) {
      const agentId = String(draft[use] || '').trim();
      if (!agentId || agentId === defaultsByUse[use]) continue;
      setSavingUse(use);
      await onSave(use, agentId);
    }
    setSavingUse('');
    setMessage('Default-agent map saved.');
  };
  return (
    <Panel title="Default agents" subtitle="Role/default-use → durable default agent id. Coordinators and skills use these suggestions when assigning task participants; task participants remain the authority for actual roles.">
      <section data-debug-id="settings-default-agents-panel" className="rounded-2xl border border-white/10 bg-white/[0.035] p-4">
        <div className="mb-4 flex items-center justify-between gap-3">
          <div className="text-xs uppercase tracking-[0.18em] text-zinc-500">Default-agent map</div>
          <button data-debug-id="settings-default-agents-refresh-btn" type="button" onClick={onRefresh} className="rounded-xl bg-white/10 px-3 py-2 text-xs text-zinc-100 hover:bg-white/15">{loading ? 'Refreshing…' : 'Refresh'}</button>
        </div>
        <div className="space-y-2">
          {DEFAULT_AGENT_USES.map((use) => {
            const value = draft[use] || '';
            const status = ['conversation', 'guide', 'coordinator', 'worker', 'reviewer'].includes(use) ? 'seeded' : 'alias';
            return (
              <div key={use} data-debug-id={`settings-default-agent-use-${use}-row`} className="grid gap-2 rounded-2xl border border-white/10 bg-black/20 p-3 md:grid-cols-[150px_minmax(0,1fr)_80px] md:items-center">
                <div className="font-mono text-sm text-zinc-200">{use}</div>
                <label className="sr-only" htmlFor={`default-agent-${use}`}>Default agent for {use}</label>
                <select id={`default-agent-${use}`} data-debug-id={`settings-default-agent-use-${use}-picker-btn`} value={value} onChange={(event) => setDraft((current) => ({ ...current, [use]: event.target.value }))} className="w-full rounded-xl border border-white/10 bg-black/30 px-3 py-2 text-sm text-zinc-100 outline-none focus:border-sky-400">
                  {!value && <option value="">Choose durable agent id</option>}
                  {value && !options.includes(value) && <option value={value}>{value}</option>}
                  {options.map((id) => <option key={id} value={id}>{id}</option>)}
                </select>
                <div data-debug-id={`settings-default-agent-use-${use}-value`} className="text-xs text-zinc-500">{status}</div>
              </div>
            );
          })}
        </div>
        {message && <div data-debug-id="settings-default-agents-save-message" className="mt-3 rounded-xl border border-emerald-400/20 bg-emerald-400/10 px-3 py-2 text-sm text-emerald-100">{message}</div>}
        <div className="mt-4 flex justify-end">
          <button data-debug-id="settings-default-agents-save-btn" type="button" disabled={Boolean(savingUse)} onClick={() => { void saveAll(); }} className="rounded-xl bg-sky-400 px-4 py-2 text-sm font-semibold text-black hover:bg-sky-300 disabled:cursor-not-allowed disabled:opacity-50">{savingUse ? `Saving ${savingUse}…` : 'Save changes'}</button>
        </div>
      </section>
    </Panel>
  );
}

function preferenceValue(preferences: any[], key: string, fallback = '') {
  const pref = (preferences || []).find((item: any) => item.key === key);
  return String(pref?.value ?? pref?.default_value ?? pref?.defaultValue ?? fallback);
}


function providerTierSummary(item: any): string {
  const models = item?.models || item?.model_tiers || item?.modelTiers || {};
  const cheap = models.cheap || item?.cheap || 'configured by daemon';
  const normal = models.normal || item?.normal || 'configured by daemon';
  const smart = models.smart || item?.smart || 'configured by daemon';
  return `cheap → ${cheap} · normal → ${normal} · smart → ${smart}`;
}

function ProvidersPanel({ providers, preferences, session, daemonProfiles = [], onSaveDefault }: any) {
  const [provider, setProvider] = useState('');
  const [tier, setTier] = useState('normal');
  const [selectedDaemon, setSelectedDaemon] = useState(session?.daemonUrl || '');
  const [defaultsDirty, setDefaultsDirty] = useState(false);
  const hydratedDefaultsRef = useRef('');
  const defaultProvider = preferenceValue(preferences, 'default_agent_provider_profile', providers[0]?.name || 'pi');
  const defaultTier = preferenceValue(preferences, 'default_agent_model_tier', 'normal');
  useEffect(() => {
    hydratedDefaultsRef.current = '';
    setDefaultsDirty(false);
    setSelectedDaemon(session?.daemonUrl || '');
  }, [session?.daemonUrl]);
  useEffect(() => {
    if (defaultsDirty) return;
    const signature = `${session?.daemonUrl || ''}:${defaultProvider}:${defaultTier}:${providers.length}`;
    if (hydratedDefaultsRef.current === signature) return;
    hydratedDefaultsRef.current = signature;
    setProvider(defaultProvider);
    setTier(defaultTier);
  }, [defaultProvider, defaultTier, defaultsDirty, providers.length, session?.daemonUrl]);
  const save = async (event: any) => {
    event.preventDefault();
    await onSaveDefault('default_agent_provider_profile', provider.trim() || 'pi');
    await onSaveDefault('default_agent_model_tier', tier || 'normal');
  };
  const activeLabel = daemonProfiles.find((profile: any) => profile.url === selectedDaemon)?.label || selectedDaemon || 'Active daemon';
  return (
    <Panel title="Providers" subtitle="Provider profiles and model-tier mappings are read from the selected daemon. Defaults saved here apply to the single active daemon in v1.">
      <div data-debug-id="settings-providers-single-daemon-banner" className="mb-4 rounded-2xl border border-sky-400/20 bg-sky-400/10 p-4 text-sm text-sky-100">Single active daemon mode: provider profiles below belong to <span className="font-mono">{activeLabel}</span>. Merged multi-daemon provider views are deferred.</div>
      <div className="rounded-2xl border border-white/10 bg-white/[0.035] p-4">
        <div className="flex flex-wrap items-center justify-between gap-3">
          <div><div className="font-semibold">Daemon</div><div className="mt-1 text-sm text-zinc-500">Providers below belong to the selected daemon.</div></div>
          <div className="flex items-center gap-2">
            <span className="h-2 w-2 rounded-full bg-sky-400" />
            <select data-debug-id="settings-providers-daemon-select" value={selectedDaemon} onChange={(event) => setSelectedDaemon(event.target.value)} className="rounded-xl border border-white/10 bg-black/30 px-3 py-2 text-sm outline-none focus:border-sky-400">
              {(daemonProfiles.length ? daemonProfiles : [{ label: activeLabel, url: selectedDaemon }]).map((profile: any) => <option key={profile.url || profile.label} value={profile.url || ''}>{profile.label || profile.url || 'Active daemon'}</option>)}
            </select>
          </div>
        </div>
      </div>

      <div className="mt-6 flex items-center justify-between gap-3">
        <div className="text-xs uppercase tracking-[0.18em] text-zinc-500">Provider profiles · {activeLabel}</div>
        <span data-debug-id="settings-providers-list" className="rounded-full bg-white/10 px-2.5 py-1 text-xs text-zinc-400">{providers.length}</span>
      </div>
      <div className="mt-3 space-y-2">
        {providers.length === 0 ? <Empty text="No providers loaded from this daemon." /> : providers.map((item: any) => {
          const isDefault = item.name === provider;
          return (
            <div key={item.name} data-debug-id={`settings-provider-card-${item.name}`} className="flex items-center gap-3 rounded-2xl border border-white/10 bg-white/[0.035] p-4">
              <div className="min-w-0 flex-1"><div className="font-semibold text-zinc-100">{item.name}</div><div className="mt-1 text-sm text-zinc-500">{providerTierSummary(item)}</div></div>
              {isDefault && <span className="rounded-full bg-emerald-400/10 px-2.5 py-1 text-xs text-emerald-100">default</span>}
              <button data-debug-id={`settings-provider-default-btn-${item.name}`} type="button" onClick={() => { setDefaultsDirty(true); setProvider(item.name); }} className="rounded-xl bg-white/10 px-3 py-2 text-xs text-zinc-100 hover:bg-white/15">Set default</button>
            </div>
          );
        })}
      </div>

      <form onSubmit={save} className="mt-6 rounded-2xl border border-white/10 bg-white/[0.035] p-4">
        <div className="mb-3 text-xs uppercase tracking-[0.18em] text-zinc-500">Default agent ({activeLabel})</div>
        <div className="grid gap-3 md:grid-cols-2">
          <label className="block text-sm text-zinc-300">Default provider<select data-debug-id="settings-default-agent-provider-select" value={provider} onChange={(event) => { setDefaultsDirty(true); setProvider(event.target.value); }} className="mt-1 w-full rounded-xl border border-white/10 bg-black/30 px-3 py-2 text-sm outline-none focus:border-sky-400">{providers.length === 0 && <option value={provider || 'pi'}>{provider || 'pi'}</option>}{providers.map((item: any) => <option key={item.name} value={item.name}>{item.name}</option>)}</select></label>
          <label className="block text-sm text-zinc-300">Default tier<select data-debug-id="settings-default-agent-tier-select" value={tier} onChange={(event) => { setDefaultsDirty(true); setTier(event.target.value); }} className="mt-1 w-full rounded-xl border border-white/10 bg-black/30 px-3 py-2 text-sm outline-none focus:border-sky-400"><option value="normal">normal</option><option value="cheap">cheap</option><option value="smart">smart</option></select></label>
        </div>
        <div className="mt-4 flex justify-end"><button data-debug-id="settings-default-agent-save-btn" type="submit" className="rounded-xl bg-sky-400 px-4 py-2 text-sm font-semibold text-black hover:bg-sky-300">Save</button></div>
      </form>
    </Panel>
  );
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

function settingsAgentHasLiveSession(agent: any): boolean {
  const connection = String(agent?.connectionState || agent?.connection_state || '').toLowerCase();
  const status = String(agent?.status || '').toLowerCase();
  const state = String(agent?.state || '').toLowerCase();
  const startup = String(agent?.startupStatus || agent?.startup_status || '').toLowerCase();
  if (Boolean(agent?.connected) || connection === 'connected') return true;
  if (['offline', 'stopped', 'disconnected', 'archived', 'missing'].includes(status) || ['offline', 'stopped', 'disconnected'].includes(state) || startup === 'stopped') return false;
  return Boolean(agent?.currentTaskId || agent?.current_task_id || ['active', 'working', 'ready', 'connected', 'idle'].includes(status) || ['active', 'working', 'ready', 'connected', 'idle'].includes(state) || startup === 'ready');
}

function SettingsChatRuntimeBanner({ agent, sending, onStart }: any) {
  if (!agent?.id) return null;
  const activity = String(agent.activityStatus || agent.activity_status || '').toLowerCase();
  const status = String(agent.status || '').toLowerCase();
  const state = String(agent.state || '').toLowerCase();
  const live = settingsAgentHasLiveSession(agent);
  const working = live && activity !== 'idle' && (activity === 'active' || agent.currentTaskId || agent.current_task_id || status === 'active' || status === 'working' || state === 'working');
  const stopped = !live || status === 'offline' || status === 'stopped';
  if (!working && !stopped) return null;
  return (
    <div data-debug-id="settings-direct-chat-status-banner" className="mt-3 flex items-center gap-2 rounded-[14px] border border-white/10 bg-[#101010] px-3 py-2 text-[12px] text-zinc-300">
      <span className={`h-2 w-2 shrink-0 rounded-full ${working ? 'animate-pulse bg-zinc-300' : 'bg-zinc-600'}`} />
      <div className="min-w-0 flex-1 truncate font-medium text-zinc-200">{agent.label || agent.id} is {working ? 'working' : 'stopped'}</div>
      {stopped ? <button data-debug-id="settings-direct-chat-status-start-btn" type="button" onClick={() => onStart?.(agent)} disabled={sending} className="rounded-full border border-white/15 bg-zinc-200 px-2.5 py-1 text-[11px] font-semibold text-zinc-950 hover:bg-white disabled:cursor-not-allowed disabled:opacity-50">Start</button> : null}
    </div>
  );
}

function DirectChatPanel({ agents, agentId, setAgentId, messages, draft, setDraft, sending, onSend, onStart }: any) {
  const selectedAgent = agents.find((agent: any) => agent.id === agentId);
  return (
    <Panel title="Direct agent chat (debug)" subtitle="Debug affordance only. Main-path chat remains chain coordinator-only.">
      <div className="rounded-3xl border border-white/10 bg-[#090909] p-5">
        <label className="text-sm text-zinc-300">
          Agent
          <select data-debug-id="settings-direct-chat-agent-select" value={agentId} onChange={(event) => setAgentId(event.target.value)} className="mt-2 w-full rounded-xl border border-white/10 bg-black/30 px-3 py-2 text-sm outline-none">
            <option value="">Select agent</option>
            {agents.map((agent: any) => <option key={agent.id} value={agent.id}>{agent.label || agent.id}</option>)}
          </select>
        </label>
        <div data-debug-id="settings-direct-chat-feed" className="mt-4 max-h-[420px] min-h-56 space-y-[18px] overflow-y-auto rounded-[18px] bg-[#090909] p-4">
          {messages.length === 0 ? <div className="rounded-2xl border border-dashed border-white/10 p-6 text-sm text-zinc-500">No direct debug messages loaded.</div> : messages.map((message: any, index: number) => {
            const isUser = message.direction === 'user_to_agent' || message.author === 'user';
            const messageId = message.id || message.messageId || index;
            return (
              <div key={messageId} data-debug-id={`settings-direct-chat-message-${messageId}`} className={`msg group flex ${isUser ? 'justify-end' : 'justify-start'}`}>
                <div className={`flex ${isUser ? 'max-w-[74%] items-end' : 'max-w-full items-start'} flex-col text-sm`}>
                  <div className={`${isUser ? 'rounded-[15px] border border-[#262626] bg-[#1c1c1c] px-[14px] py-[10px] text-zinc-100' : 'max-w-full text-zinc-200'}`}>{message.body}</div>
                  <div data-debug-id={`settings-direct-chat-message-actions-${messageId}`} className={`mt-1 flex items-center gap-[10px] text-[13px] text-zinc-500 ${isUser ? 'self-end' : 'self-start'}`}>
                    <ChatHoverCopyButton debugId={`settings-direct-chat-message-copy-btn-${messageId}`} text={message.body || ''} />
                  </div>
                </div>
              </div>
            );
          })}
        </div>
        <SettingsChatRuntimeBanner agent={selectedAgent} sending={sending} onStart={onStart} />
        <div data-debug-id="settings-direct-chat-composer-shell" className="mt-3 rounded-[15px] border border-white/10 bg-[#141414] p-0 focus-within:border-white/35">
          <textarea data-debug-id="settings-direct-chat-input" value={draft} onChange={(event) => setDraft(event.target.value)} onKeyDown={(event) => { if (event.key === 'Enter' && !event.shiftKey) { event.preventDefault(); onSend(); } }} placeholder="Debug direct message to selected agent…" rows={3} className="min-h-[74px] w-full resize-none bg-transparent px-3 pt-3 text-[15px] leading-relaxed text-zinc-100 outline-none placeholder:text-zinc-600" />
          <div className="flex items-center justify-end gap-2 px-2 pb-2"><span className="hidden text-[11px] text-zinc-600 sm:inline">Enter to send · Shift+Enter for newline</span><button data-debug-id="settings-direct-chat-send-btn" type="button" onClick={onSend} disabled={sending || !agentId || !draft.trim()} className="inline-flex h-8 items-center justify-center rounded-full border border-white/10 px-3 text-sm text-zinc-500 hover:bg-[#1c1c1c] hover:text-zinc-100 disabled:cursor-not-allowed disabled:opacity-50">{sending ? 'Sending…' : '→'}</button></div>
        </div>
      </div>
    </Panel>
  );
}


function daemonDisplay(url: string): string {
  try { return new URL(url).host || url; } catch { return url || 'daemon'; }
}

function DaemonPanel({ session, daemonProfiles = [], agents = [], projects = [], onReconnect, onAddProfile, onRemoveProfile, debugInfo, setDebugInfo }: any) {
  const activeUrl = session?.daemonUrl || '';
  const clientToken = session?.clientToken || '';
  const profiles = daemonProfiles.length ? daemonProfiles : [{ label: 'Local daemon', url: activeUrl }];
  const [daemonUrl, setDaemonUrl] = useState(activeUrl || '');
  const [label, setLabel] = useState('Local daemon');
  const [userId, setUserId] = useState(session?.userId || 'operator@local');
  const [peerUrl, setPeerUrl] = useState('');
  const [peerLabel, setPeerLabel] = useState('');
  const [peerToken, setPeerToken] = useState('');
  const [peers, setPeers] = useState<any[]>([]);
  const [peerAgentCounts, setPeerAgentCounts] = useState<Record<string, number>>({});
  const [peerBusy, setPeerBusy] = useState('');
  const [peerError, setPeerError] = useState('');

  useEffect(() => { setDaemonUrl(activeUrl || ''); setUserId(session?.userId || 'operator@local'); }, [activeUrl, session?.userId]);

  async function refreshPeers() {
    if (!activeUrl || !clientToken) {
      setPeers([]);
      setPeerAgentCounts({});
      return;
    }
    setPeerError('');
    const nextPeers = await daemonApi.listFederationPeers({ daemonUrl: activeUrl, clientToken });
    setPeers(nextPeers || []);
    const counts: Record<string, number> = {};
    await Promise.all((nextPeers || []).map(async (peer: any) => {
      if (String(peer?.status || '') !== 'linked') return;
      try {
        const data = await daemonApi.listPeerAdvertisedAgents({ daemonUrl: activeUrl, clientToken, peerId: peer.peer_id });
        counts[String(peer.peer_id || '')] = Array.isArray(data?.agents) ? data.agents.length : 0;
      } catch {
        // Peer rows still render from the peer list even if the live directory call fails.
      }
    }));
    setPeerAgentCounts(counts);
  }

  useEffect(() => {
    refreshPeers().catch((err: any) => setPeerError(err?.message || 'Unable to load peer daemons'));
  }, [activeUrl, clientToken]);

  const connect = () => {
    const nextUrl = daemonUrl.trim();
    if (!nextUrl) return;
    onAddProfile?.({ daemonUrl: nextUrl, url: nextUrl, label: label.trim() || daemonDisplay(nextUrl) });
    onReconnect?.({ daemonUrl: nextUrl, userId: userId.trim() || 'operator@local' });
  };

  const connectPeer = async () => {
    const nextUrl = peerUrl.trim();
    const nextPeerId = peerLabel.trim() || daemonDisplay(nextUrl);
    const nextPeerToken = peerToken.trim();
    if (!nextUrl || !nextPeerId || !nextPeerToken || !clientToken) return;
    setPeerBusy('connect');
    setPeerError('');
    try {
      await daemonApi.linkFederationPeer({ daemonUrl: activeUrl, clientToken, peerId: nextPeerId, peerUrl: nextUrl, peerToken: nextPeerToken });
      setPeerUrl('');
      setPeerLabel('');
      setPeerToken('');
      await refreshPeers();
    } catch (err: any) {
      setPeerError(err?.message || 'Unable to connect peer daemon');
    } finally {
      setPeerBusy('');
    }
  };

  const reconnectPeer = async (peerId: string) => {
    if (!clientToken) return;
    setPeerBusy(`reconnect-${peerId}`);
    setPeerError('');
    try {
      await daemonApi.reconnectFederationPeer({ daemonUrl: activeUrl, clientToken, peerId });
      await refreshPeers();
    } catch (err: any) {
      setPeerError(err?.message || 'Unable to reconnect peer daemon');
    } finally {
      setPeerBusy('');
    }
  };

  const removePeer = async (peerId: string) => {
    if (!clientToken) return;
    setPeerBusy(`remove-${peerId}`);
    setPeerError('');
    try {
      await daemonApi.removeFederationPeer({ daemonUrl: activeUrl, clientToken, peerId });
      await refreshPeers();
    } catch (err: any) {
      setPeerError(err?.message || 'Unable to remove peer daemon');
    } finally {
      setPeerBusy('');
    }
  };

  return (
    <Panel title="Daemons" subtitle="Connect and manage the daemon this UI controls, plus peer daemons that lend agents. v1 uses one active daemon; peers are used for remote reviewers only.">
      <div data-debug-id="settings-daemon-single-active-banner" className="mb-4 rounded-2xl border border-amber-400/20 bg-amber-400/10 p-4 text-sm text-amber-100">Single active daemon mode: switch/reconnect changes the active daemon. Merged multi-daemon views are intentionally deferred for v1.</div>
      <div className="mb-3 text-xs uppercase tracking-[0.18em] text-zinc-500">Connected</div>
      <div data-debug-id="settings-daemon-list" className="space-y-2">
        {profiles.map((profile: any, index: number) => {
          const url = profile.url || activeUrl || '';
          const active = url === activeUrl;
          const slug = (profile.label || daemonDisplay(url) || `daemon-${index}`).toLowerCase().replace(/[^a-z0-9_-]+/g, '-');
          return (
            <div key={`${url}-${index}`} data-debug-id={`settings-daemon-row-${slug}`} className={`flex items-center gap-3 rounded-2xl border p-4 ${active ? 'border-sky-400/30 bg-sky-400/10' : 'border-white/10 bg-white/[0.035]'}`}>
              <span className={`h-2.5 w-2.5 rounded-full ${active && session?.connected ? 'bg-sky-400' : 'bg-zinc-500'}`} />
              <div className="min-w-0 flex-1"><div className="font-semibold text-zinc-100">{profile.label || daemonDisplay(url)}</div><div className="mt-1 truncate font-mono text-xs text-zinc-500">{url}</div><div className="mt-1 text-xs text-zinc-500">{active && session?.connected ? 'connected' : active ? 'configured' : 'stored'} · daemon_id {session?.daemonId || session?.daemon_id || daemonDisplay(url)} · version {session?.version || 'unknown'} · {projects.length} projects · {agents.length} agents</div></div>
              <button data-debug-id={`settings-daemon-reconnect-btn-${slug}`} type="button" onClick={() => { onAddProfile?.({ daemonUrl: url, url, label: profile.label || daemonDisplay(url) }); onReconnect?.({ daemonUrl: url, userId }); }} className="rounded-xl bg-white/10 px-3 py-2 text-xs text-zinc-100 hover:bg-white/15">Reconnect</button>
              <button data-debug-id={`settings-daemon-remove-btn-${slug}`} type="button" onClick={() => onRemoveProfile?.({ daemonUrl: url, url })} disabled={active} title={active ? 'Cannot remove the active daemon from this v1 pane.' : 'Remove stored daemon'} className="rounded-xl bg-red-400/10 px-3 py-2 text-xs text-red-200 hover:bg-red-400/15 disabled:cursor-not-allowed disabled:opacity-40">Remove</button>
            </div>
          );
        })}
      </div>

      <div className="mt-6 text-xs uppercase tracking-[0.18em] text-zinc-500">Peer daemons</div>
      <div className="mt-3 rounded-2xl border border-teal-400/20 bg-teal-400/10 p-4 text-sm text-teal-100">Peers are linked in the background and not switched to. Connecting a peer copies no projects or agents into this UI; remote agents are fetched live when the picker opens.</div>
      {peerError && <div className="mt-3 rounded-xl border border-red-400/30 bg-red-500/10 px-3 py-2 text-sm text-red-100">{peerError}</div>}
      <div data-debug-id="settings-peer-daemon-list" className="mt-3 space-y-2">
        {peers.length === 0 ? <Empty text="No peer daemons linked yet." /> : peers.map((peer: any) => {
          const peerId = String(peer?.peer_id || 'peer');
          const slug = peerId.toLowerCase().replace(/[^a-z0-9_-]+/g, '-');
          const linked = String(peer?.status || '') === 'linked';
          const count = peerAgentCounts[peerId];
          return (
            <div key={peerId} data-debug-id={`settings-peer-daemon-row-${slug}`} className="flex items-center gap-3 rounded-2xl border border-white/10 bg-white/[0.035] p-4">
              <span className={`h-2.5 w-2.5 rounded-full ${linked ? 'bg-emerald-400' : 'bg-zinc-500'}`} />
              <div className="min-w-0 flex-1"><div className="font-semibold text-zinc-100">{peerId}</div><div className="mt-1 truncate font-mono text-xs text-zinc-500">{peer.peer_url || '—'}</div><div className="mt-1 text-xs text-zinc-500">{linked ? 'linked' : 'unreachable'} · daemon_id {peer.daemon_id || 'unknown'} · version {peer.version || 'unknown'}{linked && count !== undefined ? ` · lends ${count} agents` : ''}</div></div>
              <button data-debug-id={`settings-peer-daemon-reconnect-btn-${slug}`} type="button" onClick={() => reconnectPeer(peerId)} disabled={Boolean(peerBusy)} className="rounded-xl bg-white/10 px-3 py-2 text-xs text-zinc-100 hover:bg-white/15 disabled:cursor-not-allowed disabled:opacity-50">Reconnect</button>
              <button data-debug-id={`settings-peer-daemon-remove-btn-${slug}`} type="button" onClick={() => removePeer(peerId)} disabled={Boolean(peerBusy)} className="rounded-xl bg-red-400/10 px-3 py-2 text-xs text-red-200 hover:bg-red-400/15 disabled:cursor-not-allowed disabled:opacity-50">Remove</button>
            </div>
          );
        })}
      </div>

      <div className="mt-6 text-xs uppercase tracking-[0.18em] text-zinc-500">Add daemon</div>
      <div className="mt-3 rounded-2xl border border-white/10 bg-white/[0.035] p-4">
        <div className="grid gap-3 md:grid-cols-3">
          <label className="block text-sm text-zinc-300">Daemon URL<input data-debug-id="settings-daemon-url-input" value={daemonUrl} onChange={(event) => setDaemonUrl(event.target.value)} placeholder="https://host:7777" className="mt-1 w-full rounded-xl border border-white/10 bg-black/30 px-3 py-2 text-sm outline-none focus:border-sky-400" /></label>
          <label className="block text-sm text-zinc-300">Label<input data-debug-id="settings-daemon-label-input" value={label} onChange={(event) => setLabel(event.target.value)} placeholder="prod" className="mt-1 w-full rounded-xl border border-white/10 bg-black/30 px-3 py-2 text-sm outline-none focus:border-sky-400" /></label>
          <label className="block text-sm text-zinc-300">User id<input data-debug-id="settings-daemon-user-input" value={userId} onChange={(event) => setUserId(event.target.value)} placeholder="operator@local" className="mt-1 w-full rounded-xl border border-white/10 bg-black/30 px-3 py-2 text-sm outline-none focus:border-sky-400" /></label>
        </div>
        <div className="mt-4 flex items-center justify-between gap-3"><div className="flex items-center gap-2 text-xs text-zinc-500"><span>Color</span><span className="h-4 w-4 rounded-full bg-sky-400" /><span className="h-4 w-4 rounded-full bg-emerald-400" /><span className="h-4 w-4 rounded-full bg-amber-400" /><span className="h-4 w-4 rounded-full bg-violet-400" /></div><button data-debug-id="settings-daemon-add-btn" type="button" onClick={connect} disabled={!daemonUrl.trim()} className="rounded-xl bg-sky-400 px-4 py-2 text-sm font-semibold text-black hover:bg-sky-300 disabled:cursor-not-allowed disabled:opacity-50">Connect</button></div>
      </div>

      <div className="mt-6 text-xs uppercase tracking-[0.18em] text-zinc-500">Add peer daemon</div>
      <div className="mt-3 rounded-2xl border border-white/10 bg-white/[0.035] p-4">
        <div className="grid gap-3 md:grid-cols-3">
          <label className="block text-sm text-zinc-300">Peer URL<input data-debug-id="settings-peer-daemon-url-input" value={peerUrl} onChange={(event) => setPeerUrl(event.target.value)} placeholder="https://peer:7777" className="mt-1 w-full rounded-xl border border-white/10 bg-black/30 px-3 py-2 text-sm outline-none focus:border-teal-400" /></label>
          <label className="block text-sm text-zinc-300">Label<input data-debug-id="settings-peer-daemon-label-input" value={peerLabel} onChange={(event) => setPeerLabel(event.target.value)} placeholder="studio-mini" className="mt-1 w-full rounded-xl border border-white/10 bg-black/30 px-3 py-2 text-sm outline-none focus:border-teal-400" /></label>
          <label className="block text-sm text-zinc-300">Access token<input data-debug-id="settings-peer-daemon-token-input" type="password" value={peerToken} onChange={(event) => setPeerToken(event.target.value)} placeholder="Paste peer token" className="mt-1 w-full rounded-xl border border-white/10 bg-black/30 px-3 py-2 text-sm outline-none focus:border-teal-400" /></label>
        </div>
        <div className="mt-4 flex items-center justify-between gap-3"><div className="text-xs text-zinc-500">Saved peer tokens stay on the daemon and are never shown again in the UI.</div><button data-debug-id="settings-peer-daemon-connect-btn" type="button" onClick={() => { void connectPeer(); }} disabled={!peerUrl.trim() || !peerToken.trim() || Boolean(peerBusy)} className="rounded-xl bg-teal-400 px-4 py-2 text-sm font-semibold text-black hover:bg-teal-300 disabled:cursor-not-allowed disabled:opacity-50">Connect peer</button></div>
      </div>

      <div className="mt-6 grid gap-4 lg:grid-cols-2">
        <Card><SessionConfig session={session} onReconnect={onReconnect} /></Card>
        <Card><h3 className="font-semibold">Electron debug server</h3><label className="mt-4 flex items-center gap-3 text-sm text-zinc-300"><input data-debug-id="settings-debug-server-checkbox" type="checkbox" checked={Boolean(debugInfo?.enabled)} onChange={async () => { if (!debugInfo || !(window as any).odinApi?.toggleDebugServer) return; setDebugInfo(await (window as any).odinApi.toggleDebugServer(!debugInfo.enabled)); }} />Enabled</label>{debugInfo?.enabled && <div className="mt-3 rounded-xl bg-black/20 p-3 font-mono text-xs text-zinc-400">http://127.0.0.1:{debugInfo.port}<br />pid {debugInfo.pid}</div>}</Card>
      </div>
    </Panel>
  );
}


function Card({ children }: any) { return <div className="rounded-2xl border border-white/10 bg-white/[0.035] p-4">{children}</div>; }
function Empty({ text }: { text: string }) { return <div className="rounded-2xl border border-dashed border-white/10 p-5 text-sm text-zinc-500">{text}</div>; }
