import { type FormEvent, useEffect, useMemo, useState } from 'react';
import { cookieJsonFetch } from '../../api/cookieFetch';
import { useListAgentIdentitiesQuery, useReconfigureAgentInstanceMutation, useRestartAgentInstanceMutation } from '../../api/endpoints/agents';
import { normalizeBridgeCapabilities, useListAgentBridgeSupportQuery, useListBridgesQuery } from '../../api/endpoints/bridgeSupport';
import { useCreateLaunchConversationMutation } from '../../api/endpoints/chats';
import { useListSidebarProjectsQuery } from '../../api/endpoints/sidebar';
import { buildRouteHash, getRouteSearch } from '../../utils/appLocation';
import { Button, Combobox, Select, Text, type ComboboxOption } from '@ui';

type AgentOption = {
  agent_id: string;
  name: string;
  default_provider?: string;
  default_tier?: string;
  state?: string;
  template_id?: string;
  role?: string;
  description?: string;
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

// RTK Query queryFn errors reject with `{ status: 'CUSTOM_ERROR', error: '...' }`
// (not an Error), so `err.message` is undefined and `String(err)` becomes the
// useless "[object Object]". Dig the real message out of every shape we produce,
// including the hub's `{ error: { code, message } }` envelope.
function errMsg(err: any, fallback: string): string {
  if (!err) return fallback;
  if (typeof err === 'string') return err;
  const data = err.data ?? err;
  const candidate =
    err.message ||
    data?.error?.message ||
    (typeof data?.error === 'string' ? data.error : '') ||
    data?.message ||
    err.error?.message ||
    (typeof err.error === 'string' ? err.error : '') ||
    err.statusText ||
    (typeof err.status === 'number' ? `Request failed (HTTP ${err.status})` : '');
  return String(candidate || fallback);
}

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
  const templateId = String(agent?.template_id || agent?.templateId || '');
  // Derive a short human role from the template id (e.g. a 'reviewer' template → reviewer).
  const role = String(agent?.role || '').trim() || templateRole(templateId);
  return {
    ...agent,
    agent_id: String(agent?.agent_id || agent?.agentId || agent?.id || ''),
    name: String(agent?.name || agent?.display_name || agent?.displayName || agent?.agent_id || agent?.id || ''),
    default_provider: String(agent?.default_provider || agent?.defaultProvider || ''),
    default_tier: String(agent?.default_tier || agent?.defaultTier || ''),
    state: String(agent?.state || 'active'),
    template_id: templateId,
    role,
    description: String(agent?.instructions || agent?.description || '').trim(),
  };
}

// Best-effort short role label from a template id for the agent picker subtitle.
function templateRole(templateId: string): string {
  const t = String(templateId || '').toLowerCase();
  if (!t) return '';
  const stripped = t.replace(/^tmpl_(system_)?/, '').replace(/_/g, ' ').trim();
  return stripped ? stripped.charAt(0).toUpperCase() + stripped.slice(1) : '';
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
  const bridgesQuery = useListBridgesQuery(undefined, { pollingInterval: 120000, refetchOnMountOrArgChange: true });
  const [createLaunchConversation] = useCreateLaunchConversationMutation();
  const [restartAgentInstance] = useRestartAgentInstanceMutation();
  const [reconfigureAgentInstance] = useReconfigureAgentInstanceMutation();
  const [status, setStatus] = useState<LaunchStatus>('idle');
  const [agentId, setAgentId] = useState('');
  const [projectId, setProjectId] = useState(SYNTHETIC_DEFAULT_PROJECT_ID);
  const [bridgeId, setBridgeId] = useState('');
  const [provider, setProvider] = useState('');
  const [tier, setTier] = useState('');
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

  // Searchable-select option lists (scale to 10–50 with search + descriptions).
  const agentSelectOptions = useMemo<ComboboxOption[]>(() => runnableAgents.map((agent: AgentOption) => ({
    value: agent.agent_id,
    title: agent.name || agent.agent_id,
    tag: agent.role || undefined,
    subtitle: agent.description || (agent.default_provider || agent.default_tier ? `defaults to ${[agent.default_provider, agent.default_tier].filter(Boolean).join(' · ')}` : undefined),
    id: agent.agent_id,
  })), [runnableAgents]);
  const projectSelectOptions = useMemo<ComboboxOption[]>(() => projects.map((project: ProjectOption) => ({
    value: project.project_id,
    title: project.name + (isDefaultProject(project) ? '' : ''),
    tag: isDefaultProject(project) ? 'default' : undefined,
    id: isDefaultProject(project) ? undefined : project.project_id,
  })), [projects]);
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
    if (anyError) { setError(errMsg(anyError, 'Failed to load launch data')); setStatus('error'); }
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

  // No first message here: only agent + a supported bridge/provider/tier are
  // required. The backend (POST /api/v1/chats) creates + binds the instance and
  // conversation without an initial message; the user types their first message
  // inside the thread after it opens.
  const canSend = status !== 'sending' && Boolean(agentId) && Boolean(selectedBridge) && launchPairSupported;
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
        body: '', // no initial message: backend creates + binds without a first send/title
        artifactIds: [],
      }).unwrap();
      const created = launched.conversation || {};
      const boundInstance = launched.instance || {};
      // Conversation routing is instance-id-only, so navigate by the created
      // instance id (the thread page resolves the conversation from it).
      const agentInstanceId = String(boundInstance.agent_instance_id || boundInstance.agentInstanceId || created.agent_instance_id || created.agentInstanceId || '');
      // Starting creates + binds the AgentInstance/ChatConversation/TaskChain.
      // There's no reason to show an intermediate "session bound" screen — go
      // straight into the conversation thread.
      if (agentInstanceId) {
        window.location.hash = buildRouteHash(`/conversations/${encodeURIComponent(agentInstanceId)}`, '');
        return;
      }
      // Fallback: if the id is missing for any reason, land on the inbox rather
      // than getting stuck on the composer.
      window.location.hash = buildRouteHash('/conversations', '');
    } catch (err: any) {
      setError(errMsg(err, 'Start failed'));
      setStatus('idle');
    }
  }


  return (
    <div className="mx-auto w-full max-w-2xl p-3 sm:p-6">
      <form data-debug-id="new-convo-composer-shell" onSubmit={submitFirstSend} className="w-full rounded-2xl border border-white/10 bg-white/[0.04] p-4 text-left shadow-xl sm:p-6">
        <h2 className="text-xl font-semibold text-white sm:text-2xl">Start a conversation</h2>
        <p className="mt-1 text-sm text-zinc-400">Pick an agent and where to run it, then start.</p>

        <div data-debug-id="launch-required-agent-control" className="mt-5 grid gap-4 sm:grid-cols-2">
          <div className="block">
            <Text role="overline" tone="muted">Agent</Text>
            <Combobox
              debugId="new-convo-agent-select"
              options={agentSelectOptions}
              value={agentId}
              onChange={setAgentId}
              placeholder="Choose an agent…"
              searchPlaceholder="Search agents…"
              emptyLabel="No agents match your search."
              loading={agentsQuery.isLoading}
              width="full"
              className="mt-2"
            />
          </div>
          <div data-debug-id="launch-project-default-control" className="block">
            <Text role="overline" tone="muted">Project</Text>
            <Combobox
              debugId="new-convo-project-select"
              options={projectSelectOptions}
              value={projectId}
              onChange={setProjectId}
              placeholder="Choose a project…"
              searchPlaceholder="Search projects…"
              emptyLabel="No projects match your search."
              loading={projectsQuery.isLoading}
              width="full"
              className="mt-2"
            />
          </div>
        </div>

        <fieldset data-debug-id="launch-advanced-bridge-provider-tier-controls" className="mt-5 rounded-2xl border border-white/10 bg-black/20 p-4">
          <legend className="px-2 text-xs font-bold uppercase tracking-[0.16em] text-zinc-500">Run location</legend>
          <div className="grid gap-4 sm:grid-cols-3">
            <label className="block">
              <span className="text-xs font-semibold text-zinc-400">Bridge</span>
              <Select data-debug-id="new-convo-bridge-select" value={bridgeId} onChange={(value) => { setBridgeId(value); setProvider(''); setTier(''); }} disabled={!agentId} width="full" className="mt-2">
                <option value="">Choose Bridge…</option>
                {bridgeOptions.map((row) => <option key={row.bridge_id} value={row.bridge_id}>{bridgeLabel(row)}</option>) }
              </Select>
            </label>
            <label className="block">
              <span className="text-xs font-semibold text-zinc-400">Provider</span>
              <Select data-debug-id="new-convo-provider-select" value={provider} onChange={(value) => { setProvider(value); setTier(''); }} disabled={!agentId || !selectedBridge} width="full" className="mt-2">
                {providerOptions.map((option) => <option key={option} value={option}>{option}</option>)}
              </Select>
            </label>
            <label className="block">
              <span className="text-xs font-semibold text-zinc-400">Tier</span>
              <Select data-debug-id="new-convo-tier-select" value={tier} onChange={setTier} disabled={!agentId || !selectedBridge} width="full" className="mt-2">
                {tierOptions.map((option) => <option key={option} value={option}>{option}</option>)}
              </Select>
            </label>
          </div>
          {effectiveBridgePathInfo && effectiveBridgePathInfo.effectivePath ? (
            <div data-debug-id="new-convo-project-path-hint" className="mt-3 rounded-xl bg-zinc-800/60 px-3 py-2 text-xs text-zinc-300">
              Runs in <code className="font-semibold text-zinc-100">{effectiveBridgePathInfo.effectivePath}</code>{' '}
              {effectiveBridgePathInfo.isValidated ? (
                <span className="font-semibold text-emerald-400">✓</span>
              ) : (
                <span className="font-semibold text-amber-400">⚠ not validated</span>
              )}
            </div>
          ) : null}
          {selectedBridge ? <p data-debug-id="launch-capability-note" className={`mt-3 rounded-xl px-3 py-2 text-xs ${launchPairSupported ? 'bg-emerald-400/10 text-emerald-100' : 'bg-amber-400/10 text-amber-100'}`}>Launches on <span className="font-semibold">{bridgeLabel(selectedBridge)}</span> · {launchProvider || '—'} / {launchTier || '—'}</p> : <p data-debug-id="launch-capability-note" className="mt-3 rounded-xl bg-amber-400/10 px-3 py-2 text-xs text-amber-100">Choose a Bridge to run on.</p>}
        </fieldset>

        {!hasRunnableAgent && (
          <p data-debug-id="new-convo-no-runnable-agent-warning" className="mt-3 rounded-xl border border-red-400/20 bg-red-400/10 px-3 py-2 text-xs text-red-100">No runnable agents. Create an agent first.</p>
        )}
        {agentId && !hasCapableBridgeSupport && (
          <p data-debug-id="new-convo-no-bridge-warning" className="mt-3 rounded-xl border border-red-400/20 bg-red-400/10 px-3 py-2 text-xs text-red-100">Choose an online Bridge for this agent.</p>
        )}
        {error && <p data-debug-id="new-convo-error" className="mt-3 rounded-xl border border-red-400/20 bg-red-400/10 px-3 py-2 text-sm text-red-100">{error}</p>}

        <div className="mt-5 flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between">
          <p data-debug-id="launch-send-guard" className="text-xs text-zinc-500">{!agentId ? 'Choose an agent to start.' : !selectedBridge ? 'Choose a Bridge to run on.' : launchPairSupported ? 'Ready to start.' : 'Choose a supported provider/tier.'}</p>
          <Button data-debug-id="new-convo-send-btn" type="submit" variant="primary" size="lg" disabled={!canSend} className="w-full sm:w-auto">{status === 'sending' ? 'Starting…' : 'Start conversation'}</Button>
        </div>
      </form>
    </div>
  );
}
