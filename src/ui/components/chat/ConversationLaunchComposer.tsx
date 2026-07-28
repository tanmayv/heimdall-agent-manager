import { type FormEvent, useEffect, useMemo, useState } from 'react';
import { cookieJsonFetch } from '../../api/cookieFetch';
import { useListAgentIdentitiesQuery, useReconfigureAgentInstanceMutation, useRestartAgentInstanceMutation } from '../../api/endpoints/agents';
import { normalizeBridgeCapabilities, useListAgentBridgeSupportQuery, useListBridgesQuery } from '../../api/endpoints/bridgeSupport';
import { useCreateLaunchConversationMutation } from '../../api/endpoints/chats';
import { useListSidebarProjectsQuery } from '../../api/endpoints/sidebar';
import { buildRouteHash, getRouteSearch } from '../../utils/appLocation';

type AgentOption = {
  agent_id: string;
  name: string;
  default_provider?: string;
  default_tier?: string;
  state?: string;
};

type ProjectOption = {
  project_id: string;
  name: string;
  is_default_conversations?: boolean;
  isDefaultConversations?: boolean;
};

type BridgeCapability = {
  provider?: string;
  tiers?: string[];
  default_tier?: string;
};

type BridgeOption = {
  bridge_id: string;
  label: string;
  machine_hostname?: string;
  status?: string;
  capabilities?: BridgeCapability[];
};

type LockedLaunch = {
  conversation_id: string;
  agent_instance_id: string;
  chain_id: string;
  agent_id: string;
  project_id: string;
  project_name: string;
  bridge_id: string;
  provider: string;
  tier: string;
};

type LaunchStatus = 'idle' | 'loading' | 'sending' | 'locked' | 'error';

const SYNTHETIC_DEFAULT_PROJECT_ID = 'default-conversations';
const SYNTHETIC_DEFAULT_PROJECT: ProjectOption = {
  project_id: SYNTHETIC_DEFAULT_PROJECT_ID,
  name: 'Conversations',
  is_default_conversations: true,
};

function displayName(value: string | undefined, fallback: string): string {
  const trimmed = String(value || '').trim();
  return trimmed || fallback;
}

function isDefaultProject(project: ProjectOption): boolean {
  return project.is_default_conversations === true || project.isDefaultConversations === true || project.project_id === SYNTHETIC_DEFAULT_PROJECT_ID;
}

function normalizeProject(project: ProjectOption): ProjectOption {
  return {
    ...project,
    project_id: displayName(project.project_id, isDefaultProject(project) ? SYNTHETIC_DEFAULT_PROJECT_ID : project.name),
    name: displayName(project.name, 'Untitled project'),
  };
}

function normalizeAgent(agent: any): AgentOption {
  return {
    ...agent,
    agent_id: String(agent?.agent_id || agent?.agentId || agent?.id || ''),
    name: String(agent?.name || agent?.display_name || agent?.displayName || agent?.agent_id || agent?.id || ''),
    default_provider: String(agent?.default_provider || agent?.defaultProvider || ''),
    default_tier: String(agent?.default_tier || agent?.defaultTier || ''),
    state: String(agent?.state || 'active'),
  };
}

function defaultProject(projects: ProjectOption[]): ProjectOption {
  return projects.find(isDefaultProject) || SYNTHETIC_DEFAULT_PROJECT;
}

function bridgeCapabilityEntries(bridge: BridgeOption | undefined): BridgeCapability[] {
  return normalizeBridgeCapabilities(bridge).map((cap) => ({ provider: cap.provider, tiers: cap.tiers, default_tier: cap.defaultTier }));
}

function capabilityTiers(capability: BridgeCapability): string[] {
  const tiers = Array.isArray(capability.tiers) ? capability.tiers.filter(Boolean) : [];
  // Current `/api/v1/bridges` exposes compact capability rows with provider +
  // default_tier while full tier arrays remain a UI-17 backend follow-up. Treat
  // default_tier as the bounded single-tier capability instead of rejecting an
  // otherwise valid enabled support row.
  if (tiers.length > 0) return tiers;
  return capability.default_tier ? [capability.default_tier] : [];
}

function bridgeOnline(bridge: BridgeOption | undefined): boolean {
  return String(bridge?.status || '').toLowerCase() === 'online';
}

function defaultCapability(bridge: BridgeOption | undefined, provider = ''): BridgeCapability | undefined {
  const caps = bridgeCapabilityEntries(bridge);
  if (provider) return caps.find((cap) => cap.provider === provider);
  return caps.find((cap) => cap.default_tier) || caps[0];
}

function capabilitySupportsTier(capability: BridgeCapability | undefined, tier: string): boolean {
  if (!capability || !tier) return false;
  return capabilityTiers(capability).includes(tier);
}

function providersForBridges(bridges: BridgeOption[], requestTier: string): string[] {
  const out = new Set<string>();
  bridges.forEach((bridge) => bridgeCapabilityEntries(bridge).forEach((capability) => {
    const provider = capability.provider || '';
    if (provider && (!requestTier || capabilitySupportsTier(capability, requestTier))) out.add(provider);
  }));
  return Array.from(out).sort();
}

function tiersForBridges(bridges: BridgeOption[], requestProvider: string): string[] {
  const out = new Set<string>();
  bridges.forEach((bridge) => bridgeCapabilityEntries(bridge).forEach((capability) => {
    if (requestProvider && capability.provider !== requestProvider) return;
    capabilityTiers(capability).forEach((candidate) => out.add(candidate));
  }));
  return Array.from(out).sort();
}

function bridgeLabel(bridge: BridgeOption): string {
  return bridge.label || bridge.machine_hostname || bridge.bridge_id;
}

function lockedValue(value: string): string {
  return displayName(value, '—');
}

export default function ConversationLaunchComposer() {
  const agentsQuery = useListAgentIdentitiesQuery();
  const projectsQuery = useListSidebarProjectsQuery({ limit: 100 });
  // Poll bridges: liveness/capabilities update async with no user-WS event, so a
  // one-shot fetch can leave the launch controls empty after a Bridge connects.
  const bridgesQuery = useListBridgesQuery(undefined, { pollingInterval: 5000, refetchOnMountOrArgChange: true });
  const [createLaunchConversation] = useCreateLaunchConversationMutation();
  const [restartAgentInstance] = useRestartAgentInstanceMutation();
  const [reconfigureAgentInstance] = useReconfigureAgentInstanceMutation();
  const [status, setStatus] = useState<LaunchStatus>('idle');
  const [agentId, setAgentId] = useState('');
  const [projectId, setProjectId] = useState(SYNTHETIC_DEFAULT_PROJECT_ID);
  const [bridgeId, setBridgeId] = useState('');
  const [provider, setProvider] = useState('');
  const [tier, setTier] = useState('');
  const [body, setBody] = useState('');
  const [error, setError] = useState('');
  const [locked, setLocked] = useState<LockedLaunch | null>(null);
  const [pendingProvider, setPendingProvider] = useState('');
  const [pendingTier, setPendingTier] = useState('');
  const [restartStatus, setRestartStatus] = useState('');
  const [projectDetail, setProjectDetail] = useState<any>(null);
  const supportQuery = useListAgentBridgeSupportQuery({ agentId }, { skip: !agentId, refetchOnMountOrArgChange: true });
  const preselectedAgentId = useMemo(() => {
    const params = new URLSearchParams(getRouteSearch().replace(/^\?/, ''));
    return String(params.get('agent_id') || params.get('agentId') || '').trim();
  }, []);

  const agents = useMemo(() => (agentsQuery.data?.agents || []).map(normalizeAgent).filter((agent: AgentOption) => agent.agent_id), [agentsQuery.data?.agents]);
  const runnableAgents = useMemo(() => agents.filter((agent: any) => agent.state !== 'archived'), [agents]);
  const projects = useMemo(() => {
    const normalizedProjects = (projectsQuery.data || []).map((project: any) => normalizeProject({ project_id: project.projectId || project.project_id, name: project.name, is_default_conversations: project.isDefaultConversations || project.is_default_conversations }));
    return normalizedProjects.some(isDefaultProject) ? normalizedProjects : [SYNTHETIC_DEFAULT_PROJECT, ...normalizedProjects];
  }, [projectsQuery.data]);
  const bridges = useMemo<BridgeOption[]>(() => bridgesQuery.data?.bridges || [], [bridgesQuery.data?.bridges]);
  const support = useMemo(() => (supportQuery.data?.entries || []).map((row: any) => ({ bridgeId: row.bridgeId || row.bridge_id, provider: row.providerProfile || row.provider || '', tier: row.modelTier || row.tier || '' })), [supportQuery.data?.entries]);

  useEffect(() => {
    const selectedDefault = defaultProject(projects);
    setProjectId(selectedDefault.project_id || SYNTHETIC_DEFAULT_PROJECT_ID);
  }, [projects]);

  useEffect(() => {
    if (!preselectedAgentId || agentId) return;
    if (agents.some((agent) => agent.agent_id === preselectedAgentId)) setAgentId(preselectedAgentId);
  }, [agentId, agents, preselectedAgentId]);

  useEffect(() => { setBridgeId(''); setProvider(''); setTier(''); }, [agentId]);

  useEffect(() => {
    const anyError = agentsQuery.error || projectsQuery.error || bridgesQuery.error;
    if (anyError) { setError(String((anyError as any)?.error || 'Failed to load launch data')); setStatus('error'); }
  }, [agentsQuery.error, projectsQuery.error, bridgesQuery.error]);

  const selectedAgent = useMemo(() => agents.find((agent) => agent.agent_id === agentId), [agents, agentId]);
  const selectedProject = useMemo(() => projects.find((project) => project.project_id === projectId) || defaultProject(projects), [projects, projectId]);

  useEffect(() => {
    if (!projectId || projectId === SYNTHETIC_DEFAULT_PROJECT_ID || selectedProject?.is_default_conversations || selectedProject?.isDefaultConversations) {
      setProjectDetail(null);
      return;
    }
    let cancelled = false;
    cookieJsonFetch(`/projects/${projectId}`)
      .then((data) => {
        if (!cancelled) setProjectDetail(data?.data || data || null);
      })
      .catch(() => {
        if (!cancelled) setProjectDetail(null);
      });
    return () => { cancelled = true; };
  }, [projectId, selectedProject]);
  const bridgesById = useMemo<Map<string, BridgeOption>>(() => new Map(bridges.map((bridge) => [bridge.bridge_id, bridge])), [bridges]);
  const bridgeOptions = useMemo(() => bridges.filter((bridge) => bridgeOnline(bridge) && bridgeCapabilityEntries(bridge).length > 0), [bridges]);
  const selectedBridge = bridgeId ? bridgesById.get(bridgeId) : undefined;
  const selectedSupport = useMemo(() => support.find((row: any) => row.bridgeId === bridgeId) || null, [support, bridgeId]);
  const selectedDefaultCapability = useMemo(() => defaultCapability(selectedBridge, selectedSupport?.provider || ''), [selectedBridge, selectedSupport]);
  const resolvedDefaultProvider = selectedSupport?.provider || selectedDefaultCapability?.provider || '';
  const selectedProviderCapability = useMemo(() => defaultCapability(selectedBridge, provider || resolvedDefaultProvider), [selectedBridge, provider, resolvedDefaultProvider]);
  const resolvedDefaultTier = selectedSupport?.tier || selectedAgent?.default_tier || selectedProviderCapability?.default_tier || capabilityTiers(selectedProviderCapability || {})[0] || '';
  const providerOptions = useMemo(() => selectedBridge ? providersForBridges([selectedBridge], '') : [], [selectedBridge]);
  const tierOptions = useMemo(() => selectedBridge ? tiersForBridges([selectedBridge], provider || resolvedDefaultProvider) : [], [selectedBridge, provider, resolvedDefaultProvider]);
  const launchProvider = provider || resolvedDefaultProvider;
  const launchTier = tier || resolvedDefaultTier;
  const launchPairSupported = Boolean(selectedBridge && launchProvider && launchTier && capabilitySupportsTier(defaultCapability(selectedBridge, launchProvider), launchTier));
  const lockedBridge = locked ? bridgesById.get(locked.bridge_id) : undefined;
  const lockedBridges = lockedBridge ? [lockedBridge] : [];
  const pendingProviderOptions = useMemo(() => providersForBridges(lockedBridges, pendingTier), [lockedBridges, pendingTier]);
  const pendingTierOptions = useMemo(() => tiersForBridges(lockedBridges, pendingProvider), [lockedBridges, pendingProvider]);

  // Preselect a CONCRETE provider/tier (never leave it on the "" default) so the
  // user always sees the exact provider/tier the instance will start with.
  useEffect(() => {
    setProvider((current) => (current && providerOptions.includes(current)) ? current : (resolvedDefaultProvider || providerOptions[0] || ''));
  }, [providerOptions.join('|'), resolvedDefaultProvider]);

  useEffect(() => {
    setTier((current) => (current && tierOptions.includes(current)) ? current : (tierOptions.includes(resolvedDefaultTier) ? resolvedDefaultTier : (tierOptions[0] || '')));
  }, [tierOptions.join('|'), resolvedDefaultTier]);

  useEffect(() => {
    setPendingProvider((current) => current === '' || pendingProviderOptions.includes(current) ? current : (pendingProviderOptions[0] || ''));
  }, [pendingProviderOptions.join('|')]);

  useEffect(() => {
    setPendingTier((current) => current === '' || pendingTierOptions.includes(current) ? current : (pendingTierOptions[0] || ''));
  }, [pendingTierOptions.join('|')]);

  const hasRunnableAgent = runnableAgents.length > 0;
  // While bridge/support data is still loading, don't declare the agent
  // unrunnable or flash the resolve warning — the options simply aren't ready.
  const capabilityDataLoading = Boolean(agentId) && (bridgesQuery.isLoading || bridgesQuery.isFetching || supportQuery.isLoading || supportQuery.isFetching) && bridges.length === 0;
  const hasCapableBridgeSupport = !agentId || capabilityDataLoading || Boolean(selectedBridge);
  const effectiveBridgePathInfo = useMemo(() => {
    if (!projectDetail || !selectedBridge) return null;
    const bridgePaths: any[] = Array.isArray(projectDetail.bridge_paths) ? projectDetail.bridge_paths : Array.isArray(projectDetail.bridgePaths) ? projectDetail.bridgePaths : [];
    const match = bridgePaths.find((bp: any) => String(bp.bridge_id || bp.bridgeId) === selectedBridge.bridge_id);
    const effectivePath = match?.path || projectDetail.default_path || projectDetail.defaultPath || '';
    const isValidated = Boolean(match?.is_validated || match?.isValidated);
    return { effectivePath, isValidated };
  }, [projectDetail, selectedBridge]);

  const canSend = status !== 'sending' && Boolean(agentId) && Boolean(selectedBridge) && launchPairSupported && body.trim().length > 0;
  const usingSyntheticDefault = selectedProject.project_id === SYNTHETIC_DEFAULT_PROJECT_ID;
  const hasPendingProviderTierChange = locked ? pendingProvider !== locked.provider || pendingTier !== locked.tier : false;
  const pendingProviderValid = pendingProvider === '' || pendingProviderOptions.includes(pendingProvider);
  const pendingTierValid = pendingTier === '' || pendingTierOptions.includes(pendingTier);
  const pendingProviderTierValid = pendingProviderValid && pendingTierValid;
  const canReconfigureProviderTier = hasPendingProviderTierChange && pendingProviderTierValid;

  async function submitFirstSend(event: FormEvent) {
    event.preventDefault();
    if (!agentId) {
      setError('Choose an agent before sending.');
      return;
    }
    if (!body.trim()) return;
    if (!selectedBridge) {
      setError('Choose the Bridge to run this agent on.');
      return;
    }
    if (!launchPairSupported) {
      setError('Choose a provider/tier supported by the selected Bridge.');
      return;
    }
    setStatus('sending');
    setError('');
    try {
      const launched = await createLaunchConversation({
        agentId,
        projectId: usingSyntheticDefault ? undefined : selectedProject.project_id,
        bridgeId,
        provider: launchProvider,
        tier: launchTier,
        body: body.trim(),
        artifactIds: [],
      }).unwrap();
      const created = launched.conversation || {};
      const boundInstance = launched.instance || {};
      const nextLocked: LockedLaunch = {
        conversation_id: String(created.conversation_id || boundInstance.conversation_id || ''),
        agent_instance_id: String(created.agent_instance_id || boundInstance.agent_instance_id || ''),
        chain_id: String(created.chain_id || boundInstance.chain_id || ''),
        agent_id: String(created.agent_id || boundInstance.agent_id || agentId),
        project_id: String(created.project_id || boundInstance.project_id || selectedProject.project_id || ''),
        project_name: selectedProject.name || 'Conversations',
        bridge_id: String(boundInstance.bridge_id || bridgeId),
        provider: String(boundInstance.provider || launchProvider || ''),
        tier: String(boundInstance.tier || launchTier || ''),
      };
      setLocked(nextLocked);
      setBridgeId(nextLocked.bridge_id === 'Auto' ? '' : nextLocked.bridge_id);
      setPendingProvider(nextLocked.provider);
      setPendingTier(nextLocked.tier);
      setStatus('locked');
    } catch (err: any) {
      setError(String(err?.message || err || 'First send failed'));
      setStatus('idle');
    }
  }

  async function restartInstance() {
    if (!locked?.agent_instance_id) return;
    setRestartStatus('Restarting…');
    try {
      await restartAgentInstance({ agentId: locked.agent_id, instanceId: locked.agent_instance_id }).unwrap();
      setRestartStatus('Restart requested');
    } catch (err: any) {
      setRestartStatus(String(err?.message || err));
    }
  }

  async function reconfigureInstance() {
    if (!locked?.agent_instance_id) return;
    setRestartStatus('Reconfiguring provider/tier…');
    if (!hasPendingProviderTierChange) {
      setRestartStatus('Choose a new provider or tier before reconfiguring.');
      return;
    }
    if (!pendingProviderTierValid) {
      setRestartStatus('Choose a provider/tier pair supported by the pinned Bridge before reconfiguring.');
      return;
    }
    try {
      await reconfigureAgentInstance({ agentId: locked.agent_id, instanceId: locked.agent_instance_id, provider: pendingProvider, tier: pendingTier }).unwrap();
      setLocked({ ...locked, provider: pendingProvider, tier: pendingTier });
      setRestartStatus('Provider/tier reconfigure requested explicitly; restart if the running process must relaunch.');
    } catch (err: any) {
      setRestartStatus(String(err?.message || err));
    }
  }

  if (status === 'locked' && locked) {
    return (
      <section data-debug-id="conversation-launch-locked-state" className="w-full max-w-4xl rounded-[2rem] border border-emerald-400/20 bg-emerald-400/10 p-6 text-left shadow-2xl">
        <p className="text-xs font-semibold uppercase tracking-[0.22em] text-emerald-200">Conversation started</p>
        <h2 className="mt-2 text-2xl font-semibold text-white">First send created and bound the session</h2>
        <p className="mt-2 text-sm text-emerald-50/80">The launch controls are now locked to the created AgentInstance, ChatConversation, and private TaskChain.</p>
        <div data-debug-id="launch-locked-chips" className="mt-5 flex flex-wrap gap-2 text-xs font-semibold">
          <span className="rounded-full bg-black/25 px-3 py-1.5 text-emerald-50">agent: {lockedValue(locked.agent_id)}</span>
          <span className="rounded-full bg-black/25 px-3 py-1.5 text-emerald-50">project: {lockedValue(locked.project_name)}</span>
          <span className="rounded-full bg-black/25 px-3 py-1.5 text-emerald-50">bridge: {lockedValue(locked.bridge_id)}</span>
          <span className="rounded-full bg-black/25 px-3 py-1.5 text-emerald-50">provider: {lockedValue(locked.provider)}</span>
          <span className="rounded-full bg-black/25 px-3 py-1.5 text-emerald-50">tier: {lockedValue(locked.tier)}</span>
          <span className="rounded-full bg-black/25 px-3 py-1.5 text-emerald-50">chain: {lockedValue(locked.chain_id)}</span>
          <span className="rounded-full bg-black/25 px-3 py-1.5 text-emerald-50">instance: {lockedValue(locked.agent_instance_id)}</span>
        </div>
        <fieldset data-debug-id="launch-post-start-provider-tier-controls" className="mt-5 rounded-3xl border border-emerald-200/15 bg-black/20 p-4">
          <legend className="px-2 text-xs font-bold uppercase tracking-[0.16em] text-emerald-100/70">Explicit post-start provider/tier change</legend>
          <div className="grid gap-4 md:grid-cols-2">
            <label className="block">
              <span className="text-xs font-semibold text-emerald-100/70">New provider</span>
              <select data-debug-id="launch-post-start-provider-select" value={pendingProvider} onChange={(event) => setPendingProvider(event.target.value)} className="mt-2 w-full rounded-2xl border border-white/10 bg-black/30 px-3 py-3 text-sm text-white">
                <option value="">Default</option>
                {pendingProviderOptions.map((option) => <option key={option} value={option}>{option}</option>)}
              </select>
            </label>
            <label className="block">
              <span className="text-xs font-semibold text-emerald-100/70">New tier</span>
              <select data-debug-id="launch-post-start-tier-select" value={pendingTier} onChange={(event) => setPendingTier(event.target.value)} className="mt-2 w-full rounded-2xl border border-white/10 bg-black/30 px-3 py-3 text-sm text-white">
                <option value="">Default</option>
                {pendingTierOptions.map((option) => <option key={option} value={option}>{option}</option>)}
              </select>
            </label>
          </div>
          <p data-debug-id="launch-post-start-change-note" className="mt-3 text-xs text-emerald-100/70">Agent, project, and Bridge stay locked. Provider/tier changes only happen when you press Reconfigure, and Restart is a separate explicit relaunch action. Choices come from the locked Bridge capability matrix.</p>
        </fieldset>
        <div className="mt-5 flex flex-wrap gap-3">
          <a data-debug-id="launch-open-bound-conversation" href={buildRouteHash(`/conversations/${locked.conversation_id}`, '')} className="rounded-2xl bg-emerald-300 px-4 py-2 text-sm font-bold text-black hover:bg-emerald-200">Open conversation</a>
          <button data-debug-id="launch-reconfigure-provider-tier" type="button" disabled={!canReconfigureProviderTier} onClick={reconfigureInstance} className="rounded-2xl border border-white/10 bg-white/10 px-4 py-2 text-sm font-bold text-white hover:bg-white/15 disabled:cursor-not-allowed disabled:opacity-50">Reconfigure provider/tier</button>
          <button data-debug-id="launch-restart-instance" type="button" onClick={restartInstance} className="rounded-2xl border border-white/10 bg-white/10 px-4 py-2 text-sm font-bold text-white hover:bg-white/15">Restart instance</button>
        </div>
        {restartStatus && <p data-debug-id="launch-restart-status" className="mt-3 text-xs text-emerald-100/80">{restartStatus}</p>}
      </section>
    );
  }

  return (
    <form data-debug-id="new-convo-composer-shell" onSubmit={submitFirstSend} className="w-full max-w-4xl rounded-[2rem] border border-white/10 bg-white/[0.04] p-6 text-left shadow-2xl">
      <div className="flex items-start justify-between gap-4">
        <div>
          <p className="text-xs font-semibold uppercase tracking-[0.22em] text-sky-300/80">Composer launch</p>
          <h2 className="mt-2 text-2xl font-semibold text-white">Start with a message</h2>
          <p className="mt-2 text-sm leading-6 text-zinc-400">Choose an agent in the composer, keep the default Conversations project unless needed, then first-send creates the bound AgentInstance, ChatConversation, and TaskChain through <code>POST /api/v1/chats</code>.</p>
        </div>
        <span data-debug-id="launch-default-project-chip" className="shrink-0 rounded-full bg-sky-400/10 px-3 py-1.5 text-xs font-bold text-sky-200">Default project: {selectedProject.name || 'Conversations'}</span>
      </div>

      <div data-debug-id="launch-required-agent-control" className="mt-5 grid gap-4 md:grid-cols-2">
        <label className="block">
          <span className="text-xs font-bold uppercase tracking-[0.16em] text-zinc-500">Agent required</span>
          <select data-debug-id="new-convo-agent-select" value={agentId} onChange={(event) => setAgentId(event.target.value)} className="mt-2 w-full rounded-2xl border border-white/10 bg-black/30 px-3 py-3 text-sm text-white">
            <option value="">Choose an agent before sending…</option>
            {runnableAgents.map((agent) => <option key={agent.agent_id} value={agent.agent_id}>{agent.name || agent.agent_id}</option>)}
          </select>
        </label>
        <label data-debug-id="launch-project-default-control" className="block">
          <span className="text-xs font-bold uppercase tracking-[0.16em] text-zinc-500">Project</span>
          <select data-debug-id="new-convo-project-select" value={projectId} onChange={(event) => setProjectId(event.target.value)} className="mt-2 w-full rounded-2xl border border-white/10 bg-black/30 px-3 py-3 text-sm text-white">
            {projects.map((project) => <option key={project.project_id} value={project.project_id}>{project.name}{isDefaultProject(project) ? ' · default' : ''}</option>)}
          </select>
        </label>
      </div>

      <fieldset data-debug-id="launch-advanced-bridge-provider-tier-controls" className="mt-5 rounded-3xl border border-white/10 bg-black/20 p-4">
        <legend className="px-2 text-xs font-bold uppercase tracking-[0.16em] text-zinc-500">Run location</legend>
        <div className="grid gap-4 md:grid-cols-3">
          <label className="block">
            <span className="text-xs font-semibold text-zinc-400">Bridge / machine</span>
            <select data-debug-id="new-convo-bridge-select" value={bridgeId} onChange={(event) => { setBridgeId(event.target.value); setProvider(''); setTier(''); }} disabled={!agentId} className="mt-2 w-full rounded-2xl border border-white/10 bg-black/30 px-3 py-3 text-sm text-white disabled:opacity-50">
              <option value="">Choose Bridge…</option>
              {bridgeOptions.map((row) => <option key={row.bridge_id} value={row.bridge_id}>{bridgeLabel(row)}</option>) }
            </select>
          </label>
          <label className="block">
            <span className="text-xs font-semibold text-zinc-400">Provider for this launch</span>
            <select data-debug-id="new-convo-provider-select" value={provider} onChange={(event) => { setProvider(event.target.value); setTier(''); }} disabled={!agentId || !selectedBridge} className="mt-2 w-full rounded-2xl border border-white/10 bg-black/30 px-3 py-3 text-sm text-white disabled:opacity-50">
              {providerOptions.map((option) => <option key={option} value={option}>{option}</option>)}
            </select>
          </label>
          <label className="block">
            <span className="text-xs font-semibold text-zinc-400">Tier for this launch</span>
            <select data-debug-id="new-convo-tier-select" value={tier} onChange={(event) => setTier(event.target.value)} disabled={!agentId || !selectedBridge} className="mt-2 w-full rounded-2xl border border-white/10 bg-black/30 px-3 py-3 text-sm text-white disabled:opacity-50">
              {tierOptions.map((option) => <option key={option} value={option}>{option}</option>)}
            </select>
          </label>
        </div>
        {effectiveBridgePathInfo && effectiveBridgePathInfo.effectivePath ? (
          <div data-debug-id="new-convo-project-path-hint" className="mt-3 rounded-2xl bg-zinc-800/60 px-3 py-2 text-xs text-zinc-300">
            Runs in: <code className="font-semibold text-zinc-100">{effectiveBridgePathInfo.effectivePath}</code>{' '}
            {effectiveBridgePathInfo.isValidated ? (
              <span className="font-semibold text-emerald-400">(✓ validated)</span>
            ) : (
              <span className="font-semibold text-amber-400">(⚠ path not validated on this bridge)</span>
            )}
          </div>
        ) : null}
        {selectedBridge ? <p data-debug-id="launch-capability-note" className={`mt-3 rounded-2xl px-3 py-2 text-xs ${launchPairSupported ? 'bg-emerald-400/10 text-emerald-100' : 'bg-amber-400/10 text-amber-100'}`}>Will launch on <span className="font-semibold">{bridgeLabel(selectedBridge)}</span> with <span className="font-semibold">{launchProvider || '—'} / {launchTier || '—'}</span>. These values start from the bridge/agent defaults; change provider or tier here to override only this instance.</p> : <p data-debug-id="launch-capability-note" className="mt-3 rounded-2xl bg-amber-400/10 px-3 py-2 text-xs text-amber-100">Choose the Bridge to run this agent on.</p>}
      </fieldset>

      <label className="mt-5 block">
        <span className="text-xs font-bold uppercase tracking-[0.16em] text-zinc-500">Message</span>
        <textarea data-debug-id="new-convo-input" value={body} onChange={(event) => setBody(event.target.value)} rows={5} placeholder="Ask the selected agent to start working…" className="mt-2 w-full resize-y rounded-3xl border border-white/10 bg-black/30 px-4 py-3 text-sm leading-6 text-white outline-none placeholder:text-zinc-600 focus:border-sky-400/60" />
      </label>

      {usingSyntheticDefault && (
        <p data-debug-id="launch-synthetic-default-project-gap" className="mt-3 rounded-2xl border border-amber-400/20 bg-amber-400/10 px-3 py-2 text-xs text-amber-100">Using the UI fallback Conversations project. First-send omits the synthetic project id until the backend exposes the default project marker/id documented in UI-17.</p>
      )}
      {!hasRunnableAgent && (
        <p data-debug-id="new-convo-no-runnable-agent-warning" className="mt-3 rounded-2xl border border-red-400/20 bg-red-400/10 px-3 py-2 text-xs text-red-100">No runnable agents are available. Create an agent before starting a conversation.</p>
      )}
      {agentId && !hasCapableBridgeSupport && (
        <p data-debug-id="new-convo-no-bridge-warning" className="mt-3 rounded-2xl border border-red-400/20 bg-red-400/10 px-3 py-2 text-xs text-red-100">Choose an online Bridge to run this agent on.</p>
      )}
      {error && <p data-debug-id="new-convo-error" className="mt-3 rounded-2xl border border-red-400/20 bg-red-400/10 px-3 py-2 text-sm text-red-100">{error}</p>}

      <div className="mt-5 flex items-center justify-between gap-4">
        <p data-debug-id="launch-send-guard" className="text-xs text-zinc-500">{!agentId ? 'Agent selection is required before send.' : !selectedBridge ? 'Choose the Bridge to run on.' : launchPairSupported ? 'Ready when the first message is written.' : 'Choose a provider/tier supported by the selected Bridge.'}</p>
        <button data-debug-id="new-convo-send-btn" type="submit" disabled={!canSend} className="rounded-2xl bg-sky-400 px-5 py-3 text-sm font-black text-black hover:bg-sky-300 disabled:cursor-not-allowed disabled:bg-zinc-700 disabled:text-zinc-400">{status === 'sending' ? 'Starting…' : 'Send and start'}</button>
      </div>
    </form>
  );
}
