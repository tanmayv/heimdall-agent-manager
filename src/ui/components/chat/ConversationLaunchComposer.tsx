import { type FormEvent, useEffect, useMemo, useState } from 'react';
import { buildRouteHash } from '../../utils/appLocation';

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

type AgentBridgeSupport = {
  agent_id: string;
  bridge_id: string;
  enabled: boolean;
  provider?: string;
  tier?: string;
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

function apiUrl(path: string): string {
  return path.startsWith('/api/v1') ? path : `/api/v1${path.startsWith('/') ? path : `/${path}`}`;
}

async function apiList<T>(path: string): Promise<T[]> {
  const response = await fetch(apiUrl(path), { credentials: 'include' });
  if (!response.ok) throw new Error(`${path} failed (${response.status})`);
  const body = await response.json();
  return Array.isArray(body?.data) ? body.data : [];
}

async function apiJson<T>(path: string, init: RequestInit): Promise<T> {
  const response = await fetch(apiUrl(path), {
    ...init,
    credentials: 'include',
    headers: { 'content-type': 'application/json' },
  });
  const body = response.status === 204 ? {} : await response.json().catch(() => ({}));
  if (!response.ok) throw new Error(body?.error?.message || body?.message || `${path} failed (${response.status})`);
  return body?.data || body;
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

function defaultProject(projects: ProjectOption[]): ProjectOption {
  return projects.find(isDefaultProject) || SYNTHETIC_DEFAULT_PROJECT;
}

function bridgeCapabilityEntries(bridge: BridgeOption | undefined): BridgeCapability[] {
  return Array.isArray(bridge?.capabilities) ? bridge.capabilities : [];
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

function supportProviderAllowed(support: AgentBridgeSupport, capability: BridgeCapability): boolean {
  return !support.provider || support.provider === capability.provider;
}

function supportTierIntersection(support: AgentBridgeSupport, capability: BridgeCapability): string[] {
  const tiers = capabilityTiers(capability);
  if (!support.tier) return tiers;
  return tiers.includes(support.tier) ? [support.tier] : [];
}

function supportHasCapabilityIntersection(support: AgentBridgeSupport, bridgesById: Map<string, BridgeOption>): boolean {
  return bridgeCapabilityEntries(bridgesById.get(support.bridge_id)).some((capability) => supportProviderAllowed(support, capability) && supportTierIntersection(support, capability).length > 0);
}

function providersForSupportIntersection(rows: AgentBridgeSupport[], bridgesById: Map<string, BridgeOption>): string[] {
  const out = new Set<string>();
  rows.forEach((support) => {
    bridgeCapabilityEntries(bridgesById.get(support.bridge_id)).forEach((capability) => {
      if (capability.provider && supportProviderAllowed(support, capability) && supportTierIntersection(support, capability).length > 0) out.add(capability.provider);
    });
  });
  return Array.from(out).sort();
}

function tiersForSupportIntersection(rows: AgentBridgeSupport[], bridgesById: Map<string, BridgeOption>, selectedProvider: string): string[] {
  const out = new Set<string>();
  rows.forEach((support) => {
    bridgeCapabilityEntries(bridgesById.get(support.bridge_id)).forEach((capability) => {
      if (selectedProvider && capability.provider !== selectedProvider) return;
      if (!supportProviderAllowed(support, capability)) return;
      supportTierIntersection(support, capability).forEach((candidate) => out.add(candidate));
    });
  });
  return Array.from(out).sort();
}

function supportLabel(support: AgentBridgeSupport, bridgesById: Map<string, BridgeOption>): string {
  const bridge = bridgesById.get(support.bridge_id);
  const label = bridge?.label || bridge?.machine_hostname || support.bridge_id;
  const provider = support.provider ? ` · ${support.provider}` : '';
  const tier = support.tier ? `/${support.tier}` : '';
  return `${label}${provider}${tier}`;
}

function lockedValue(value: string): string {
  return displayName(value, '—');
}

export default function ConversationLaunchComposer() {
  const [status, setStatus] = useState<LaunchStatus>('loading');
  const [agents, setAgents] = useState<AgentOption[]>([]);
  const [projects, setProjects] = useState<ProjectOption[]>([SYNTHETIC_DEFAULT_PROJECT]);
  const [bridges, setBridges] = useState<BridgeOption[]>([]);
  const [support, setSupport] = useState<AgentBridgeSupport[]>([]);
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

  useEffect(() => {
    let cancelled = false;
    setStatus('loading');
    Promise.all([apiList<AgentOption>('/agents'), apiList<ProjectOption>('/projects'), apiList<BridgeOption>('/bridges')])
      .then(([agentRows, projectRows, bridgeRows]) => {
        if (cancelled) return;
        const normalizedProjects = projectRows.map(normalizeProject);
        const withFallback = normalizedProjects.some(isDefaultProject) ? normalizedProjects : [SYNTHETIC_DEFAULT_PROJECT, ...normalizedProjects];
        const selectedDefault = defaultProject(withFallback);
        setAgents(agentRows);
        setProjects(withFallback);
        setBridges(bridgeRows);
        setProjectId(selectedDefault.project_id || SYNTHETIC_DEFAULT_PROJECT_ID);
        setStatus('idle');
      })
      .catch((err) => {
        if (cancelled) return;
        setError(String(err?.message || err));
        setStatus('error');
      });
    return () => { cancelled = true; };
  }, []);

  useEffect(() => {
    let cancelled = false;
    setSupport([]);
    setBridgeId('');
    if (!agentId) return;
    apiList<AgentBridgeSupport>(`/agents/${encodeURIComponent(agentId)}/bridge-support`)
      .then((rows) => {
        if (!cancelled) setSupport(rows.filter((row) => row.enabled !== false));
      })
      .catch(() => { if (!cancelled) setSupport([]); });
    return () => { cancelled = true; };
  }, [agentId]);

  const selectedAgent = useMemo(() => agents.find((agent) => agent.agent_id === agentId), [agents, agentId]);
  const selectedProject = useMemo(() => projects.find((project) => project.project_id === projectId) || defaultProject(projects), [projects, projectId]);
  const bridgesById = useMemo(() => new Map(bridges.map((bridge) => [bridge.bridge_id, bridge])), [bridges]);
  const capableSupport = useMemo(() => support.filter((row) => supportHasCapabilityIntersection(row, bridgesById)), [support, bridgesById]);
  const constrainedSupport = useMemo(() => capableSupport.filter((row) => !bridgeId || row.bridge_id === bridgeId), [capableSupport, bridgeId]);
  const providerOptions = useMemo(() => providersForSupportIntersection(constrainedSupport, bridgesById), [constrainedSupport, bridgesById]);
  const tierOptions = useMemo(() => tiersForSupportIntersection(constrainedSupport, bridgesById, provider), [constrainedSupport, bridgesById, provider]);
  const pendingTierOptions = useMemo(() => tiersForSupportIntersection(constrainedSupport, bridgesById, pendingProvider), [constrainedSupport, bridgesById, pendingProvider]);

  useEffect(() => {
    setProvider((current) => providerOptions.includes(current) ? current : (providerOptions[0] || selectedAgent?.default_provider || ''));
  }, [providerOptions.join('|'), selectedAgent?.default_provider]);

  useEffect(() => {
    setTier((current) => tierOptions.includes(current) ? current : (tierOptions[0] || selectedAgent?.default_tier || ''));
  }, [tierOptions.join('|'), selectedAgent?.default_tier]);

  useEffect(() => {
    setPendingProvider((current) => current === '' || providerOptions.includes(current) ? current : (providerOptions[0] || ''));
  }, [providerOptions.join('|')]);

  useEffect(() => {
    setPendingTier((current) => current === '' || pendingTierOptions.includes(current) ? current : (pendingTierOptions[0] || ''));
  }, [pendingTierOptions.join('|')]);

  const hasCapableBridgeSupport = !agentId || capableSupport.length > 0;
  const canSend = status !== 'sending' && Boolean(agentId) && hasCapableBridgeSupport && body.trim().length > 0;
  const usingSyntheticDefault = selectedProject.project_id === SYNTHETIC_DEFAULT_PROJECT_ID;
  const hasPendingProviderTierChange = locked ? pendingProvider !== locked.provider || pendingTier !== locked.tier : false;
  const pendingProviderValid = pendingProvider === '' || providerOptions.includes(pendingProvider);
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
    setStatus('sending');
    setError('');
    try {
      const payload: Record<string, unknown> = {
        agent_id: agentId,
        initial_message: { body: body.trim() },
        artifact_ids: [],
      };
      // Backend currently validates real project ids. Keep the UI default visible,
      // but omit the synthetic fallback id until the backend exposes the default
      // Conversations project marker/id documented in UI-17.
      if (!usingSyntheticDefault) payload.project_id = selectedProject.project_id;
      if (bridgeId) payload.bridge_id = bridgeId;
      if (provider) payload.provider = provider;
      if (tier) payload.tier = tier;
      const created = await apiJson<any>('/chats', { method: 'POST', body: JSON.stringify(payload) });
      let boundInstance: any = {};
      if (created.agent_instance_id) {
        try {
          boundInstance = await apiJson<any>(`/agent-instances/${encodeURIComponent(String(created.agent_instance_id))}`, { method: 'GET' });
        } catch (_err) {
          boundInstance = {};
        }
      }
      const nextLocked: LockedLaunch = {
        conversation_id: String(created.conversation_id || boundInstance.conversation_id || ''),
        agent_instance_id: String(created.agent_instance_id || boundInstance.agent_instance_id || ''),
        chain_id: String(created.chain_id || boundInstance.chain_id || ''),
        agent_id: String(created.agent_id || boundInstance.agent_id || agentId),
        project_id: String(created.project_id || boundInstance.project_id || selectedProject.project_id || ''),
        project_name: selectedProject.name || 'Conversations',
        bridge_id: String(boundInstance.bridge_id || bridgeId || 'Auto'),
        provider: String(boundInstance.provider || provider || selectedAgent?.default_provider || ''),
        tier: String(boundInstance.tier || tier || selectedAgent?.default_tier || ''),
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
      await apiJson(`/agent-instances/${encodeURIComponent(locked.agent_instance_id)}/restart`, { method: 'POST', body: '{}' });
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
      await apiJson(`/agent-instances/${encodeURIComponent(locked.agent_instance_id)}`, { method: 'PATCH', body: JSON.stringify({ provider: pendingProvider, tier: pendingTier }) });
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
                {providerOptions.map((option) => <option key={option} value={option}>{option}</option>)}
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
          <p data-debug-id="launch-post-start-change-note" className="mt-3 text-xs text-emerald-100/70">Agent, project, and Bridge stay locked. Provider/tier changes only happen when you press Reconfigure, and Restart is a separate explicit relaunch action. Changing provider resets tier to a supported option when the old tier is outside the pinned Bridge/support intersection.</p>
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
    <form data-debug-id="conversation-launch-composer" onSubmit={submitFirstSend} className="w-full max-w-4xl rounded-[2rem] border border-white/10 bg-white/[0.04] p-6 text-left shadow-2xl">
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
          <select value={agentId} onChange={(event) => setAgentId(event.target.value)} className="mt-2 w-full rounded-2xl border border-white/10 bg-black/30 px-3 py-3 text-sm text-white">
            <option value="">Choose an agent before sending…</option>
            {agents.map((agent) => <option key={agent.agent_id} value={agent.agent_id}>{agent.name || agent.agent_id}</option>)}
          </select>
        </label>
        <label data-debug-id="launch-project-default-control" className="block">
          <span className="text-xs font-bold uppercase tracking-[0.16em] text-zinc-500">Project</span>
          <select value={projectId} onChange={(event) => setProjectId(event.target.value)} className="mt-2 w-full rounded-2xl border border-white/10 bg-black/30 px-3 py-3 text-sm text-white">
            {projects.map((project) => <option key={project.project_id} value={project.project_id}>{project.name}{isDefaultProject(project) ? ' · default' : ''}</option>)}
          </select>
        </label>
      </div>

      <fieldset data-debug-id="launch-advanced-bridge-provider-tier-controls" className="mt-5 rounded-3xl border border-white/10 bg-black/20 p-4">
        <legend className="px-2 text-xs font-bold uppercase tracking-[0.16em] text-zinc-500">Advanced controls constrained by Bridge support</legend>
        <div className="grid gap-4 md:grid-cols-3">
          <label className="block">
            <span className="text-xs font-semibold text-zinc-400">Bridge / machine</span>
            <select value={bridgeId} onChange={(event) => setBridgeId(event.target.value)} disabled={!agentId} className="mt-2 w-full rounded-2xl border border-white/10 bg-black/30 px-3 py-3 text-sm text-white disabled:opacity-50">
              <option value="">Auto</option>
              {capableSupport.map((row) => <option key={row.bridge_id} value={row.bridge_id}>{supportLabel(row, bridgesById)}</option>)}
            </select>
          </label>
          <label className="block">
            <span className="text-xs font-semibold text-zinc-400">Provider</span>
            <select value={provider} onChange={(event) => setProvider(event.target.value)} disabled={!agentId} className="mt-2 w-full rounded-2xl border border-white/10 bg-black/30 px-3 py-3 text-sm text-white disabled:opacity-50">
              <option value="">Default</option>
              {providerOptions.map((option) => <option key={option} value={option}>{option}</option>)}
            </select>
          </label>
          <label className="block">
            <span className="text-xs font-semibold text-zinc-400">Tier</span>
            <select value={tier} onChange={(event) => setTier(event.target.value)} disabled={!agentId} className="mt-2 w-full rounded-2xl border border-white/10 bg-black/30 px-3 py-3 text-sm text-white disabled:opacity-50">
              <option value="">Default</option>
              {tierOptions.map((option) => <option key={option} value={option}>{option}</option>)}
            </select>
          </label>
        </div>
        <p data-debug-id="launch-capability-note" className="mt-3 text-xs text-zinc-500">Bridge options come from <code>/api/v1/agents/:agent_id/bridge-support</code> intersected with <code>/api/v1/bridges</code> capability providers/tiers; compact capability rows use <code>default_tier</code> as the bounded tier until full tier arrays land. Disabled support and unsupported provider/tier pairs are hidden, and Auto lets the Hub select a capable online Bridge.</p>
      </fieldset>

      <label className="mt-5 block">
        <span className="text-xs font-bold uppercase tracking-[0.16em] text-zinc-500">Message</span>
        <textarea data-debug-id="launch-first-message-input" value={body} onChange={(event) => setBody(event.target.value)} rows={5} placeholder="Ask the selected agent to start working…" className="mt-2 w-full resize-y rounded-3xl border border-white/10 bg-black/30 px-4 py-3 text-sm leading-6 text-white outline-none placeholder:text-zinc-600 focus:border-sky-400/60" />
      </label>

      {usingSyntheticDefault && (
        <p data-debug-id="launch-synthetic-default-project-gap" className="mt-3 rounded-2xl border border-amber-400/20 bg-amber-400/10 px-3 py-2 text-xs text-amber-100">Using the UI fallback Conversations project. First-send omits the synthetic project id until the backend exposes the default project marker/id documented in UI-17.</p>
      )}
      {agentId && !hasCapableBridgeSupport && (
        <p data-debug-id="launch-no-capable-bridge-support" className="mt-3 rounded-2xl border border-red-400/20 bg-red-400/10 px-3 py-2 text-xs text-red-100">This agent has no enabled Bridge support, so it cannot launch until an enabled support row exists.</p>
      )}
      {error && <p data-debug-id="launch-error" className="mt-3 rounded-2xl border border-red-400/20 bg-red-400/10 px-3 py-2 text-sm text-red-100">{error}</p>}

      <div className="mt-5 flex items-center justify-between gap-4">
        <p data-debug-id="launch-send-guard" className="text-xs text-zinc-500">{!agentId ? 'Agent selection is required before send.' : hasCapableBridgeSupport ? 'Ready when the first message is written.' : 'Enable Bridge support before launch.'}</p>
        <button data-debug-id="launch-first-send-button" type="submit" disabled={!canSend} className="rounded-2xl bg-sky-400 px-5 py-3 text-sm font-black text-black hover:bg-sky-300 disabled:cursor-not-allowed disabled:bg-zinc-700 disabled:text-zinc-400">{status === 'sending' ? 'Starting…' : 'Send and start'}</button>
      </div>
    </form>
  );
}
