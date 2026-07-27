import { useEffect, useMemo, useState } from 'react';
import {
  useFetchAgentIdentityQuery,
  useLaunchAgentInstanceMutation,
  useListAgentInstancesQuery,
  useRestartAgentInstanceMutation,
  useStopAgentInstanceMutation,
  useUpdateAgentIdentityMutation,
} from '../../api/endpoints/agents';
import {
  normalizeBridgeCapabilities,
  useListAgentBridgeSupportQuery,
  useListBridgesQuery,
  usePatchAgentBridgeSupportMutation,
  type BridgeCapability,
} from '../../api/endpoints/bridgeSupport';
import { useListSidebarProjectsQuery } from '../../api/endpoints/sidebar';

type ProviderScope = 'bridge_default' | 'same_provider';
type BridgeRowDraft = { enabled: boolean; providerScope: ProviderScope; provider: string; tier: string };

const tierOrder = ['cheap', 'normal', 'smart'];

export function AgentDetailPanel({ agentId }: { agentId: string }) {
  const agentQuery = useFetchAgentIdentityQuery({ agentId }, { skip: !agentId });
  const supportQuery = useListAgentBridgeSupportQuery({ agentId }, { skip: !agentId });
  const instancesQuery = useListAgentInstancesQuery({ agentId }, { skip: !agentId });
  const bridgesQuery = useListBridgesQuery();
  const projectsQuery = useListSidebarProjectsQuery({ limit: 100 });
  const [updateAgent, { isLoading: updatingAgent }] = useUpdateAgentIdentityMutation();
  const [patchSupport, { isLoading: patchingSupport }] = usePatchAgentBridgeSupportMutation();
  const [launchInstance, { isLoading: launching }] = useLaunchAgentInstanceMutation();
  const [stopInstance] = useStopAgentInstanceMutation();
  const [restartInstance] = useRestartAgentInstanceMutation();

  const agent = agentQuery.data?.agent || null;
  const bridges = bridgesQuery.data?.bridges || [];
  const supports = supportQuery.data?.entries || [];
  const supportByBridge = useMemo(() => new Map(supports.map((s: any) => [s.bridgeId, s])), [supports]);
  const instances = instancesQuery.data?.instances || [];
  const projects = projectsQuery.data || [];
  const providerOptions = useMemo(() => unionProviders(bridges), [bridges]);
  const defaultTierOptions = useMemo(() => unionTiers(bridges, ''), [bridges]);

  const [defaultScope, setDefaultScope] = useState<ProviderScope>('bridge_default');
  const [defaultProvider, setDefaultProvider] = useState('');
  const [defaultTier, setDefaultTier] = useState('normal');
  const [rowDrafts, setRowDrafts] = useState<Record<string, BridgeRowDraft>>({});
  const [launchOpen, setLaunchOpen] = useState(false);
  const [launchBridge, setLaunchBridge] = useState('');
  const [launchProvider, setLaunchProvider] = useState('');
  const [launchTier, setLaunchTier] = useState('');
  const [launchProject, setLaunchProject] = useState('');
  const [message, setMessage] = useState('');
  const [error, setError] = useState('');

  useEffect(() => {
    if (!agent) return;
    const nextProvider = String(agent.default_provider || agent.defaultProvider || '');
    setDefaultScope(nextProvider ? 'same_provider' : 'bridge_default');
    setDefaultProvider(nextProvider);
    setDefaultTier(String(agent.default_tier || agent.defaultTier || 'normal'));
  }, [agent?.agent_id, agent?.default_provider, agent?.default_tier]);

  useEffect(() => {
    const next: Record<string, BridgeRowDraft> = {};
    for (const bridge of bridges) {
      const id = bridgeId(bridge);
      const support: any = supportByBridge.get(id);
      const provider = String(support?.providerProfile || '');
      next[id] = {
        enabled: Boolean(support?.enabled ?? false),
        providerScope: provider ? 'same_provider' : 'bridge_default',
        provider,
        tier: String(support?.modelTier || ''),
      };
    }
    setRowDrafts(next);
  }, [bridges, supportByBridge]);

  const selectedLaunchBridge = bridges.find((b: any) => bridgeId(b) === launchBridge) || bridges.find((b: any) => isOnline(b));
  const launchProviderOptions = selectedLaunchBridge ? normalizeBridgeCapabilities(selectedLaunchBridge).map((cap) => cap.provider) : providerOptions;
  const launchTierOptions = selectedLaunchBridge ? unionTiers([selectedLaunchBridge], launchProvider) : defaultTierOptions;

  async function saveDefaults() {
    if (!agentId) return;
    setError(''); setMessage('');
    try {
      await updateAgent({
        agentId,
        defaultProvider: defaultScope === 'same_provider' ? defaultProvider : '',
        defaultTier,
      }).unwrap();
      setMessage('Saved default provider/tier.');
      await agentQuery.refetch();
      await supportQuery.refetch();
    } catch (err: any) {
      setError(String(err?.message || 'Failed to save defaults'));
    }
  }

  async function saveBridge(bridge: any) {
    const id = bridgeId(bridge);
    const draft = rowDrafts[id];
    if (!draft) return;
    setError(''); setMessage('');
    try {
      await patchSupport({
        agentId,
        bridgeId: id,
        enabled: draft.enabled,
        providerProfile: draft.providerScope === 'same_provider' ? draft.provider : '',
        modelTier: draft.tier,
      }).unwrap();
      setMessage(`Saved ${bridge.label || bridge.machine_hostname || id}.`);
      await supportQuery.refetch();
      await agentQuery.refetch();
    } catch (err: any) {
      setError(String(err?.message || 'Failed to save bridge support'));
    }
  }

  async function launch() {
    setError(''); setMessage('');
    try {
      await launchInstance({ agentId, bridgeId: launchBridge, provider: launchProvider, tier: launchTier, projectId: launchProject }).unwrap();
      setLaunchOpen(false);
      setMessage('Launch requested.');
      await instancesQuery.refetch();
      await agentQuery.refetch();
    } catch (err: any) {
      setError(String(err?.message || 'Failed to launch instance'));
    }
  }

  async function stop(instance: any) {
    const instanceId = instanceIdOf(instance);
    try {
      await stopInstance({ agentId, instanceId }).unwrap();
      await instancesQuery.refetch();
    } catch (err: any) { setError(String(err?.message || 'Failed to stop instance')); }
  }

  async function restart(instance: any) {
    const instanceId = instanceIdOf(instance);
    try {
      await restartInstance({ agentId, instanceId }).unwrap();
      await instancesQuery.refetch();
    } catch (err: any) { setError(String(err?.message || 'Failed to restart instance')); }
  }

  if (!agentId) return <div className="text-sm text-zinc-500">Missing agent id.</div>;
  if (agentQuery.isLoading) return <div className="w-full rounded-2xl bg-white/5 p-6 text-sm text-zinc-500">Loading agent…</div>;
  if (!agent) return <div className="w-full rounded-2xl border border-red-400/20 bg-red-500/10 p-6 text-sm text-red-100">Agent not found.</div>;

  return (
    <div data-debug-id="agent-detail-page" className="w-full max-w-5xl space-y-5 text-left">
      <div className="flex flex-wrap items-start justify-between gap-3">
        <div>
          <a data-debug-id="agent-detail-back-btn" href={shellHash('/agents')} className="text-xs text-zinc-500 hover:text-zinc-200">← Back to agents</a>
          <h2 data-debug-id="agent-detail-title" className="mt-2 text-2xl font-semibold text-white">{agent.name || agent.agent_id || agentId}</h2>
          <p className="mt-1 text-sm text-zinc-500">{agent.agent_id || agentId} · template {agent.template_id || '—'} · state {agent.state || 'active'}</p>
        </div>
        <button data-debug-id="agent-detail-launch-instance-header-btn" type="button" onClick={() => setLaunchOpen(!launchOpen)} className="rounded-xl bg-sky-400 px-4 py-2 text-sm font-semibold text-black hover:bg-sky-300">Launch instance</button>
      </div>

      {message ? <div className="rounded-xl border border-emerald-400/30 bg-emerald-400/10 px-3 py-2 text-sm text-emerald-100">{message}</div> : null}
      {error ? <div data-debug-id="agent-detail-action-error" className="rounded-xl border border-red-400/30 bg-red-500/10 px-3 py-2 text-sm text-red-100">{error}</div> : null}

      <section className="rounded-2xl border border-white/10 bg-white/[0.04] p-4">
        <h3 className="font-semibold text-white">Default provider/tier</h3>
        <p className="mt-1 text-xs text-zinc-500">Use Bridge default unless you want this agent to prefer the same provider everywhere.</p>
        <div className="mt-4 grid gap-3 sm:grid-cols-3">
          <label className="block text-sm text-zinc-300">Provider mode<select data-debug-id="agent-detail-default-provider-scope" value={defaultScope} onChange={(e) => setDefaultScope(e.target.value as ProviderScope)} className="mt-1 w-full rounded-xl border border-white/10 bg-black/30 px-3 py-2 text-sm outline-none focus:border-sky-400"><option value="bridge_default">Use Bridge default</option><option value="same_provider">Same provider on all Bridges</option></select></label>
          <label className="block text-sm text-zinc-300">Provider<select data-debug-id="agent-detail-default-provider-select" value={defaultProvider} onChange={(e) => setDefaultProvider(e.target.value)} disabled={defaultScope !== 'same_provider'} className="mt-1 w-full rounded-xl border border-white/10 bg-black/30 px-3 py-2 text-sm outline-none focus:border-sky-400 disabled:opacity-50"><option value="">Choose provider</option>{providerOptions.map((provider) => <option key={provider} value={provider}>{provider}</option>)}</select></label>
          <label className="block text-sm text-zinc-300">Tier<select data-debug-id="agent-detail-default-tier-select" value={defaultTier} onChange={(e) => setDefaultTier(e.target.value)} className="mt-1 w-full rounded-xl border border-white/10 bg-black/30 px-3 py-2 text-sm outline-none focus:border-sky-400">{(defaultTierOptions.length ? defaultTierOptions : tierOrder).map((tier) => <option key={tier} value={tier}>{tier}</option>)}</select></label>
        </div>
        <div className="mt-4 flex justify-end"><button data-debug-id="agent-detail-default-save-btn" type="button" onClick={() => void saveDefaults()} disabled={updatingAgent || (defaultScope === 'same_provider' && !defaultProvider)} className="rounded-xl bg-white/10 px-4 py-2 text-sm font-semibold text-zinc-100 hover:bg-white/15 disabled:opacity-50">Save defaults</button></div>
      </section>

      <section className="rounded-2xl border border-white/10 bg-white/[0.04] p-4">
        <h3 className="font-semibold text-white">Bridge support</h3>
        <div className="mt-3 space-y-3">
          {bridges.map((bridge: any) => {
            const id = bridgeId(bridge);
            const draft = rowDrafts[id] || { enabled: false, providerScope: 'bridge_default' as ProviderScope, provider: '', tier: '' };
            const caps = normalizeBridgeCapabilities(bridge);
            const rowTierOptions = unionTiers([bridge], draft.providerScope === 'same_provider' ? draft.provider : '');
            const effective = effectiveProviderTier(agent, bridge, draft);
            return (
              <div key={id} data-debug-id={`agent-detail-bridge-row-${id}`} className="rounded-xl border border-white/10 bg-black/20 p-3">
                <div className="flex flex-wrap items-center justify-between gap-3">
                  <div><div className="font-medium text-zinc-100">{bridge.label || bridge.machine_hostname || id}</div><div className="mt-1 text-xs text-zinc-500">{id} · {bridge.status || 'offline'} · {caps.map((cap) => cap.provider).join(', ') || 'no capabilities'}</div></div>
                  <label className="flex items-center gap-2 text-sm text-zinc-300"><input data-debug-id={`agent-detail-bridge-toggle-${id}`} type="checkbox" checked={draft.enabled} onChange={(e) => setRowDrafts({ ...rowDrafts, [id]: { ...draft, enabled: e.target.checked } })} /> Enabled</label>
                </div>
                <div className="mt-3 grid gap-3 sm:grid-cols-4">
                  <label className="block text-sm text-zinc-300">Provider mode<select data-debug-id={`agent-detail-bridge-provider-scope-${id}`} value={draft.providerScope} onChange={(e) => setRowDrafts({ ...rowDrafts, [id]: { ...draft, providerScope: e.target.value as ProviderScope, provider: e.target.value === 'same_provider' ? draft.provider : '' } })} className="mt-1 w-full rounded-xl border border-white/10 bg-black/30 px-3 py-2 text-sm outline-none focus:border-sky-400"><option value="bridge_default">Bridge default</option><option value="same_provider">Override</option></select></label>
                  <label className="block text-sm text-zinc-300">Provider<select data-debug-id={`agent-detail-bridge-provider-select-${id}`} value={draft.provider} onChange={(e) => setRowDrafts({ ...rowDrafts, [id]: { ...draft, provider: e.target.value } })} disabled={draft.providerScope !== 'same_provider'} className="mt-1 w-full rounded-xl border border-white/10 bg-black/30 px-3 py-2 text-sm outline-none focus:border-sky-400 disabled:opacity-50"><option value="">Default</option>{caps.map((cap) => <option key={cap.provider} value={cap.provider}>{cap.provider}</option>)}</select></label>
                  <label className="block text-sm text-zinc-300">Tier<select data-debug-id={`agent-detail-bridge-tier-select-${id}`} value={draft.tier} onChange={(e) => setRowDrafts({ ...rowDrafts, [id]: { ...draft, tier: e.target.value } })} className="mt-1 w-full rounded-xl border border-white/10 bg-black/30 px-3 py-2 text-sm outline-none focus:border-sky-400"><option value="">Default tier</option>{(rowTierOptions.length ? rowTierOptions : tierOrder).map((tier) => <option key={tier} value={tier}>{tier}</option>)}</select></label>
                  <div data-debug-id={`agent-detail-bridge-effective-${id}`} className="rounded-xl bg-white/[0.04] px-3 py-2 text-xs text-zinc-500">effective<br /><span className="text-zinc-200">{effective.provider || '—'} / {effective.tier || '—'}</span></div>
                </div>
                <div className="mt-3 flex justify-end"><button data-debug-id={`agent-detail-bridge-save-btn-${id}`} type="button" onClick={() => void saveBridge(bridge)} disabled={patchingSupport || (draft.enabled && draft.providerScope === 'same_provider' && !draft.provider)} className="rounded-lg border border-white/10 px-3 py-1.5 text-xs text-zinc-200 hover:bg-white/10 disabled:opacity-50">Save Bridge</button></div>
              </div>
            );
          })}
          {!bridges.length ? <div className="rounded-xl border border-dashed border-white/10 p-5 text-sm text-zinc-500">No Bridges are enrolled.</div> : null}
        </div>
      </section>

      <section className="rounded-2xl border border-white/10 bg-white/[0.04] p-4">
        <div className="flex items-center justify-between gap-3"><h3 className="font-semibold text-white">Instances</h3><button data-debug-id="agent-detail-launch-instance-btn" type="button" onClick={() => setLaunchOpen(!launchOpen)} className="rounded-xl border border-sky-400/30 px-3 py-1.5 text-sm text-sky-100 hover:bg-sky-400/10">Launch instance</button></div>
        {launchOpen ? (
          <div className="mt-3 grid gap-3 rounded-xl border border-white/10 bg-black/20 p-3 sm:grid-cols-4">
            <label className="block text-sm text-zinc-300">Bridge<select data-debug-id="agent-detail-launch-bridge-select" value={launchBridge} onChange={(e) => { setLaunchBridge(e.target.value); setLaunchProvider(''); setLaunchTier(''); }} className="mt-1 w-full rounded-xl border border-white/10 bg-black/30 px-3 py-2 text-sm outline-none focus:border-sky-400"><option value="">Auto</option>{bridges.filter(isOnline).map((bridge: any) => <option key={bridgeId(bridge)} value={bridgeId(bridge)}>{bridge.label || bridge.machine_hostname || bridgeId(bridge)}</option>)}</select></label>
            <label className="block text-sm text-zinc-300">Provider<select data-debug-id="agent-detail-launch-provider-select" value={launchProvider} onChange={(e) => setLaunchProvider(e.target.value)} className="mt-1 w-full rounded-xl border border-white/10 bg-black/30 px-3 py-2 text-sm outline-none focus:border-sky-400"><option value="">Resolved default</option>{launchProviderOptions.map((provider) => <option key={provider} value={provider}>{provider}</option>)}</select></label>
            <label className="block text-sm text-zinc-300">Tier<select data-debug-id="agent-detail-launch-tier-select" value={launchTier} onChange={(e) => setLaunchTier(e.target.value)} className="mt-1 w-full rounded-xl border border-white/10 bg-black/30 px-3 py-2 text-sm outline-none focus:border-sky-400"><option value="">Resolved default</option>{(launchTierOptions.length ? launchTierOptions : tierOrder).map((tier) => <option key={tier} value={tier}>{tier}</option>)}</select></label>
            <label className="block text-sm text-zinc-300">Project<select data-debug-id="agent-detail-launch-project-select" value={launchProject} onChange={(e) => setLaunchProject(e.target.value)} className="mt-1 w-full rounded-xl border border-white/10 bg-black/30 px-3 py-2 text-sm outline-none focus:border-sky-400"><option value="">Conversations default</option>{projects.map((project: any) => <option key={project.projectId} value={project.projectId}>{project.name}</option>)}</select></label>
            <div className="sm:col-span-4 flex justify-end"><button data-debug-id="agent-detail-launch-submit-btn" type="button" onClick={() => void launch()} disabled={launching} className="rounded-xl bg-sky-400 px-4 py-2 text-sm font-semibold text-black hover:bg-sky-300 disabled:opacity-50">{launching ? 'Launching…' : 'Launch'}</button></div>
          </div>
        ) : null}
        <div className="mt-3 space-y-2">
          {instances.map((instance: any) => {
            const id = instanceIdOf(instance);
            const conversationId = String(instance.conversation_id || instance.conversationId || '');
            return <div key={id} data-debug-id={`agent-detail-instance-row-${id}`} className="flex flex-wrap items-center justify-between gap-3 rounded-xl border border-white/10 bg-black/20 p-3"><div className="min-w-0"><div className="font-mono text-xs text-zinc-100">{id}</div><div className="mt-1 text-xs text-zinc-500">bridge {instance.bridge_id || '—'} · {instance.provider || '—'} / {instance.tier || '—'} · chain {instance.chain_id || '—'}</div></div><div className="flex items-center gap-2"><span data-debug-id={`agent-detail-instance-status-${id}`} className="rounded-full bg-white/10 px-2 py-0.5 text-xs text-zinc-300">{instance.runtime_status || 'unknown'}</span>{conversationId ? <a data-debug-id={`agent-detail-instance-open-btn-${id}`} href={shellHash(`/conversations/${conversationId}`)} className="rounded-lg border border-white/10 px-2.5 py-1 text-xs text-zinc-300 hover:bg-white/10">Open</a> : null}<button data-debug-id={`agent-detail-instance-stop-btn-${id}`} type="button" onClick={() => void stop(instance)} className="rounded-lg border border-amber-400/20 px-2.5 py-1 text-xs text-amber-100 hover:bg-amber-400/10">Stop</button><button data-debug-id={`agent-detail-instance-restart-btn-${id}`} type="button" onClick={() => void restart(instance)} className="rounded-lg border border-sky-400/20 px-2.5 py-1 text-xs text-sky-100 hover:bg-sky-400/10">Restart</button></div></div>;
          })}
          {!instances.length ? <div className="rounded-xl border border-dashed border-white/10 p-5 text-sm text-zinc-500">No instances yet. Launch one to create a private chain and conversation.</div> : null}
        </div>
      </section>
    </div>
  );
}

function bridgeId(bridge: any): string { return String(bridge?.bridge_id || bridge?.bridgeId || bridge?.id || ''); }
function instanceIdOf(instance: any): string { return String(instance?.agent_instance_id || instance?.agentInstanceId || instance?.id || ''); }
function isOnline(bridge: any): boolean { return String(bridge?.status || '').toLowerCase() === 'online'; }
function shellHash(path: string): string { return `#${path.startsWith('/') ? path : `/${path}`}`; }

function unionProviders(bridges: any[]): string[] {
  return Array.from(new Set(bridges.flatMap((bridge) => normalizeBridgeCapabilities(bridge).map((cap) => cap.provider)))).sort();
}

function unionTiers(bridges: any[], provider: string): string[] {
  const tiers = new Set<string>();
  for (const bridge of bridges) {
    for (const cap of normalizeBridgeCapabilities(bridge)) {
      if (provider && cap.provider !== provider) continue;
      for (const tier of cap.tiers || []) tiers.add(tier);
      if (cap.defaultTier) tiers.add(cap.defaultTier);
    }
  }
  return tierOrder.filter((tier) => tiers.has(tier)).concat(Array.from(tiers).filter((tier) => !tierOrder.includes(tier)).sort());
}

function defaultCapability(bridge: any, provider?: string): BridgeCapability | undefined {
  const caps = normalizeBridgeCapabilities(bridge);
  if (provider) return caps.find((cap) => cap.provider === provider) || caps[0];
  return caps.find((cap) => cap.defaultTier) || caps[0];
}

function effectiveProviderTier(agent: any, bridge: any, draft: BridgeRowDraft): { provider: string; tier: string } {
  const provider = draft.provider || String(agent?.default_provider || agent?.defaultProvider || '') || defaultCapability(bridge)?.provider || '';
  const cap = defaultCapability(bridge, provider);
  const tier = draft.tier || String(agent?.default_tier || agent?.defaultTier || '') || cap?.defaultTier || cap?.tiers?.[0] || '';
  return { provider, tier };
}
