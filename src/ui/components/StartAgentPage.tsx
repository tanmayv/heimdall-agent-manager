import { useEffect, useMemo, useState } from 'react';
import { useDispatch, useSelector } from 'react-redux';
import * as daemonApi from '../api/daemonApi';
import { refreshProjects } from '../store/projectSlice';
import { upsertKnownAgent } from '../store/chatSlice';

const fallbackTemplates = [
  { templateId: 'default', displayName: 'Default agent', roleHint: 'generalist', defaultProviderProfile: '', description: '' },
  { templateId: 'coding', displayName: 'Coding agent', roleHint: 'implementation', defaultProviderProfile: '', description: '' },
  { templateId: 'reviewer', displayName: 'Reviewer agent', roleHint: 'reviewer', defaultProviderProfile: '', description: '' },
];

function defaultDisplayName() {
  return '';
}

function normalizeTemplate(template: any) {
  return {
    templateId: template.template_id || template.templateId || template.id || 'default',
    displayName: template.display_name || template.displayName || template.name || template.template_id || 'Default agent',
    roleHint: template.role_hint || template.roleHint || '',
    defaultProviderProfile: template.default_provider_profile || template.defaultProviderProfile || template.provider_profile || '',
    description: template.description || template.persona || template.instructions || '',
  };
}

export default function StartAgentPage({ session, onBack, onStarted }: { session: any; onBack: () => void; onStarted: () => void }) {
  const dispatch = useDispatch<any>();
  const { projectIds, projectsById } = useSelector((state: any) => state.projects);
  const knownAgents = useSelector((state: any) => state.chat.agents);
  const [displayName, setDisplayName] = useState(defaultDisplayName);
  const [providers, setProviders] = useState<Array<{ name: string }>>([]);
  const [provider, setProvider] = useState('');
  const [templates, setTemplates] = useState(fallbackTemplates);
  const [templateId, setTemplateId] = useState('default');
  const [projectId, setProjectId] = useState('');
  const [modelTier, setModelTier] = useState<'cheap' | 'normal' | 'smart'>('normal');
  const [loadingProviders, setLoadingProviders] = useState(false);
  const [loadingTemplates, setLoadingTemplates] = useState(false);
  const [starting, setStarting] = useState(false);
  const [error, setError] = useState('');
  const [result, setResult] = useState<any>(null);

  const selectedTemplate = useMemo(() => templates.find((template) => template.templateId === templateId) || templates[0], [templates, templateId]);
  const selectedProject = projectId ? projectsById[projectId] : null;
  const suggestedDisplayName = `${selectedTemplate?.templateId || 'agent'}@${selectedProject?.name || projectId || 'no-project'}`;
  const effectiveDisplayName = displayName.trim() || suggestedDisplayName;

  useEffect(() => {
    dispatch(refreshProjects());
  }, [dispatch]);

  useEffect(() => {
    let cancelled = false;
    setLoadingProviders(true);
    daemonApi.listAgentProviders({ daemonUrl: session.daemonUrl })
      .then((items) => {
        if (cancelled) return;
        const normalized = (items ?? []).map((item: any) => ({ name: item.name || String(item) })).filter((item) => item.name);
        setProviders(normalized);
        setProvider((current) => current || selectedTemplate?.defaultProviderProfile || normalized[0]?.name || '');
      })
      .catch((err) => {
        if (!cancelled) setError(err?.message || 'Failed to load agent providers');
      })
      .finally(() => {
        if (!cancelled) setLoadingProviders(false);
      });
    return () => {
      cancelled = true;
    };
  }, [session.daemonUrl]);

  useEffect(() => {
    let cancelled = false;
    setLoadingTemplates(true);
    daemonApi.listAgentTemplates({ daemonUrl: session.daemonUrl })
      .then((items) => {
        if (cancelled) return;
        const normalized = (items ?? []).map(normalizeTemplate).filter((item) => item.templateId);
        const nextTemplates = normalized.length ? normalized : fallbackTemplates;
        setTemplates(nextTemplates);
        setTemplateId((current) => nextTemplates.some((template) => template.templateId === current) ? current : nextTemplates[0].templateId);
      })
      .catch(() => {
        if (!cancelled) setTemplates(fallbackTemplates);
      })
      .finally(() => {
        if (!cancelled) setLoadingTemplates(false);
      });
    return () => {
      cancelled = true;
    };
  }, [session.daemonUrl]);

  useEffect(() => {
    if (!provider && selectedTemplate?.defaultProviderProfile) setProvider(selectedTemplate.defaultProviderProfile);
  }, [provider, selectedTemplate?.defaultProviderProfile]);

  async function handleSubmit(event) {
    event.preventDefault();
    if (starting) return;
    if (knownAgents.some((agent: any) => (agent.label || '').trim().toLowerCase() === effectiveDisplayName.trim().toLowerCase())) {
      setError(`An agent named ${effectiveDisplayName} already exists. Choose a unique display name.`);
      return;
    }
    setError('');
    setResult(null);
    setStarting(true);
    try {
      const response = await daemonApi.startAgent({
        daemonUrl: session.daemonUrl,
        provider,
        templateId,
        projectId,
        displayName: effectiveDisplayName,
        modelTier,
      });
      const knownAgent = {
        agent_instance_id: response.agent_instance_id || '',
        display_name: response.display_name || effectiveDisplayName,
        connected: false,
        last_seen_unix_ms: Date.now(),
        template_id: templateId,
        project_id: projectId,
        provider_profile: provider,
        role_hint: selectedTemplate?.roleHint || '',
      };
      dispatch(upsertKnownAgent(knownAgent));
      setResult(response);
      window.setTimeout(onStarted, 600);
    } catch (err: any) {
      setError(err?.message || 'Failed to start agent');
    } finally {
      setStarting(false);
    }
  }

  return (
    <main className="flex min-w-0 flex-1 flex-col bg-[var(--fd-canvas)]">
      <header className="framer-panel flex items-center justify-between border-b border-[var(--fd-hairline)] px-6 py-4">
        <div>
          <p className="framer-topline tracking-[0.28em]">Agents</p>
          <h2 className="mt-1 text-2xl font-bold text-white">Start new agent</h2>
        </div>
        <button type="button" onClick={onBack} className="framer-pill-secondary">Back</button>
      </header>

      <section className="flex flex-1 items-start justify-center overflow-y-auto p-6">
        <form onSubmit={handleSubmit} className="framer-card-xl w-full max-w-2xl space-y-5 p-5">
          <div>
            <p className="framer-topline">New runtime</p>
            <h3 className="mt-1 text-xl font-bold text-white">Create an agent instance</h3>
            <p className="mt-2 text-sm leading-6 text-[#999]">
              Select a project, persona template, provider profile, and optional display name. Heimdall/daemon owns the durable AgentInstance id; the display name is only a label.
            </p>
          </div>

          {error ? <div className="rounded-2xl border border-red-500/30 bg-red-500/10 p-3 text-sm text-red-200">{error}</div> : null}
          {result ? <div className="rounded-2xl border border-emerald-500/30 bg-emerald-500/10 p-3 text-sm text-emerald-200">Started {result.display_name || effectiveDisplayName}. Wrapper log: {result.wrapper_log || '—'}</div> : null}

          <label className="block">
            <span className="framer-topline">Project</span>
            <select value={projectId} onChange={(event) => setProjectId(event.target.value)} className="framer-input mt-2 w-full px-3 py-2 text-sm">
              <option value="">No project / legacy default</option>
              {projectIds.map((id: string) => <option key={id} value={id}>{projectsById[id]?.name || id}</option>)}
            </select>
            <p className="mt-2 text-xs text-[#999]">One primary project is sent for the instance when selected.</p>
          </label>

          <label className="block">
            <span className="framer-topline">Agent template / persona</span>
            <select value={templateId} onChange={(event) => setTemplateId(event.target.value)} className="framer-input mt-2 w-full px-3 py-2 text-sm" disabled={loadingTemplates || !templates.length}>
              {templates.map((template) => <option key={template.templateId} value={template.templateId}>{template.displayName}</option>)}
            </select>
            <div className="mt-2 rounded-2xl border border-[var(--fd-hairline)] bg-[var(--fd-surface-2)] p-3 text-xs leading-5 text-[#aaa]">
              <p><span className="text-white">Role hint:</span> {selectedTemplate?.roleHint || '—'}</p>
              {selectedTemplate?.description ? <p className="mt-1 line-clamp-3">{selectedTemplate.description}</p> : null}
            </div>
          </label>

          <label className="block">
            <span className="framer-topline">Provider / profile</span>
            <select value={provider} onChange={(event) => setProvider(event.target.value)} className="framer-input mt-2 w-full px-3 py-2 text-sm" disabled={loadingProviders || !providers.length}>
              {providers.length ? providers.map((item) => <option key={item.name} value={item.name}>{item.name}</option>) : <option value="">No configured providers</option>}
            </select>
            <p className="mt-2 text-xs text-[#999]">Runtime provider remains separate from the selected template/persona.</p>
          </label>

          <div className="block">
            <span className="framer-topline">Model tier</span>
            <div className="mt-2 flex gap-3">
              {(['cheap', 'normal', 'smart'] as const).map((tier) => (
                <label key={tier} className={`flex flex-1 cursor-pointer items-center justify-center gap-2 rounded-xl border px-3 py-2.5 text-sm transition ${modelTier === tier ? 'border-[var(--fd-accent-blue)]/60 bg-[var(--fd-accent-blue)]/10 text-white' : 'border-[var(--fd-hairline)] text-[#888] hover:border-[var(--fd-hairline)] hover:text-[#ccc]'}`}>
                  <input type="radio" name="modelTier" value={tier} checked={modelTier === tier} onChange={() => setModelTier(tier)} className="sr-only" />
                  <span className="font-semibold capitalize">{tier}</span>
                </label>
              ))}
            </div>
            <p className="mt-2 text-xs text-[#999]">Maps to the provider's cheap / normal / smart model defined in config.</p>
          </div>

          <label className="block">
            <span className="framer-topline">Optional display name</span>
            <input value={displayName} onChange={(event) => setDisplayName(event.target.value)} placeholder={suggestedDisplayName} className="framer-input mt-2 w-full px-3 py-2 text-sm" />
            <p className="mt-2 text-xs text-[#999]">
              Suggested label: <span className="text-white">{suggestedDisplayName}</span>. This is not a durable id; the daemon will provide the AgentInstance id.
            </p>
          </label>

          <div className="flex justify-end gap-2">
            <button type="button" onClick={onBack} className="framer-pill-secondary">Cancel</button>
            <button type="submit" className="framer-pill" disabled={!providers.length || starting}>
              {starting ? 'Starting…' : 'Start agent'}
            </button>
          </div>
        </form>
      </section>
    </main>
  );
}
