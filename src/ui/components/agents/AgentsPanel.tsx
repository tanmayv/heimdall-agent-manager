import React, { useEffect, useMemo, useState } from 'react';
import {
  useArchiveAgentIdentityMutation,
  useCreateAgentMutation,
  useEnableBridgeSupportMutation,
  useLaunchAgentInstanceMutation,
  useListAgentIdentitiesQuery,
  useListAgentTemplatesQuery,
} from '../../api/endpoints/agents';
import { normalizeBridgeCapabilities, useListBridgesQuery, type BridgeCapability } from '../../api/endpoints/bridgeSupport';

type ProviderScope = 'bridge_default' | 'same_provider' | 'per_bridge';
type BridgeScope = 'all' | string;

const tierOrder = ['cheap', 'normal', 'smart'];

export function AgentsPanel() {
  const agentsQuery = useListAgentIdentitiesQuery();
  const templatesQuery = useListAgentTemplatesQuery();
  const bridgesQuery = useListBridgesQuery();
  const [createAgent, { isLoading: isCreating }] = useCreateAgentMutation();
  const [enableBridgeSupport, { isLoading: isEnabling }] = useEnableBridgeSupportMutation();
  const [archiveAgent] = useArchiveAgentIdentityMutation();
  const [launchAgent, { isLoading: isLaunching }] = useLaunchAgentInstanceMutation();
  const [showForm, setShowForm] = useState(false);
  const [name, setName] = useState('');
  const [templateId, setTemplateId] = useState('');
  const [instructions, setInstructions] = useState('');
  const [showInstructions, setShowInstructions] = useState(false);
  const [bridgeScope, setBridgeScope] = useState<BridgeScope>('all');
  const [providerScope, setProviderScope] = useState<ProviderScope>('bridge_default');
  const [provider, setProvider] = useState('');
  const [tier, setTier] = useState('normal');
  const [errorMsg, setErrorMsg] = useState('');
  const [launchingAgentId, setLaunchingAgentId] = useState('');

  const agents = agentsQuery.data?.agents || [];
  const templates = useMemo(() => (templatesQuery.data?.templates || []).map(normalizeTemplate).filter((t: any) => t.id), [templatesQuery.data?.templates]);
  const bridges = bridgesQuery.data?.bridges || [];
  const capableOnlineBridges = useMemo(() => bridges.filter((bridge: any) => isOnline(bridge) && normalizeBridgeCapabilities(bridge).length > 0), [bridges]);
  const selectedBridges = useMemo(() => {
    if (bridgeScope === 'all') return capableOnlineBridges;
    return capableOnlineBridges.filter((bridge: any) => bridgeId(bridge) === bridgeScope);
  }, [bridgeScope, capableOnlineBridges]);
  const providerOptions = useMemo(() => unionProviders(selectedBridges), [selectedBridges]);
  const tierOptions = useMemo(() => unionTiers(selectedBridges, providerScope === 'same_provider' ? provider : ''), [selectedBridges, providerScope, provider]);
  const noCapabilities = capableOnlineBridges.length === 0;
  const supportPreviewCount = eligibleSupportRows(selectedBridges, providerScope, provider, tier).length;

  useEffect(() => {
    if (!templateId && templates[0]?.id) setTemplateId(templates[0].id);
  }, [templates, templateId]);

  useEffect(() => {
    if (providerScope === 'same_provider' && !provider && providerOptions[0]) setProvider(providerOptions[0]);
  }, [providerScope, provider, providerOptions]);

  useEffect(() => {
    if (tierOptions.length > 0 && !tierOptions.includes(tier)) setTier(tierOptions.includes('normal') ? 'normal' : tierOptions[0]);
  }, [tierOptions, tier]);

  function resetForm() {
    setName('');
    setTemplateId(templates[0]?.id || '');
    setInstructions('');
    setShowInstructions(false);
    setBridgeScope('all');
    setProviderScope('bridge_default');
    setProvider('');
    setTier('normal');
    setErrorMsg('');
  }

  async function handleSubmit(e: React.FormEvent) {
    e.preventDefault();
    setErrorMsg('');
    if (!name.trim()) { setErrorMsg('Agent name is required.'); return; }
    if (!templateId) { setErrorMsg('Choose a template/persona.'); return; }
    if (noCapabilities) { setErrorMsg('No online Bridge reports provider capabilities yet. Configure a Bridge provider first.'); return; }
    if (providerScope === 'same_provider' && !provider) { setErrorMsg('Choose a provider or use the Bridge default.'); return; }

    const supportRows = eligibleSupportRows(selectedBridges, providerScope, provider, tier);
    if (supportRows.length === 0) { setErrorMsg('No selected Bridge supports the chosen provider/tier.'); return; }

    try {
      const created = await createAgent({
        name: name.trim(),
        slug: slugify(name.trim()),
        templateId,
        defaultProvider: providerScope === 'same_provider' ? provider : undefined,
        defaultTier: tier,
        instructions,
      }).unwrap();
      const agentId = String(created?.agent_id || created?.agentId || '');
      if (!agentId) throw new Error('Agent was created but no agent_id was returned.');
      await enableBridgeSupport({ agentId, bridges: supportRows }).unwrap();
      setShowForm(false);
      resetForm();
      await agentsQuery.refetch();
    } catch (err: any) {
      setErrorMsg(String(err?.message || err || 'Failed to create agent'));
    }
  }

  async function handleArchive(agentId: string) {
    if (!agentId) return;
    setErrorMsg('');
    try {
      await archiveAgent({ agentId }).unwrap();
    } catch (err: any) {
      setErrorMsg(String(err?.message || 'Failed to archive agent'));
    }
  }

  async function handleLaunch(agent: any) {
    const agentId = agentIdOf(agent);
    if (!agentId) return;
    setLaunchingAgentId(agentId);
    setErrorMsg('');
    try {
      await launchAgent({ agentId }).unwrap();
      await agentsQuery.refetch();
    } catch (err: any) {
      setErrorMsg(String(err?.message || 'Failed to launch agent instance'));
    } finally {
      setLaunchingAgentId('');
    }
  }

  return (
    <div className="w-full max-w-5xl space-y-6 text-left">
      <div className="flex flex-wrap items-center justify-between gap-3">
        <div>
          <h2 className="text-xl font-semibold text-white">Agents</h2>
          <p className="mt-1 max-w-2xl text-sm text-zinc-400">Create durable agent identities from templates, choose where they run, and optionally pin a provider while keeping Bridge defaults as the normal path.</p>
        </div>
        <button data-debug-id="agents-add-agent-btn" onClick={() => { resetForm(); setShowForm(true); }} className="rounded-xl bg-sky-400 px-4 py-2 text-sm font-semibold text-black hover:bg-sky-300">＋ Add agent</button>
      </div>

      {errorMsg ? <div className="rounded-xl border border-red-400/30 bg-red-500/10 px-3 py-2 text-sm text-red-100">{errorMsg}</div> : null}

      {showForm ? (
        <div className="fixed inset-0 z-50 flex items-center justify-center overflow-y-auto bg-black/70 p-4">
          <form onSubmit={handleSubmit} className="w-full max-w-3xl rounded-3xl border border-white/10 bg-[#0d0f14] p-5 shadow-2xl">
            <div className="flex items-start justify-between gap-3">
              <div><h3 className="text-xl font-semibold text-white">Create agent</h3><p className="mt-1 text-sm text-zinc-500">Pick a name, persona, Bridge scope, and preferred tier. Provider can stay on Bridge default.</p></div>
              <button data-debug-id="agents-create-close-btn" type="button" onClick={() => setShowForm(false)} className="rounded-xl bg-white/10 px-3 py-2 text-sm hover:bg-white/15">Close</button>
            </div>

            {noCapabilities ? (
              <div data-debug-id="agents-no-capabilities-warning" className="mt-4 rounded-xl border border-amber-400/30 bg-amber-400/10 px-3 py-2 text-sm text-amber-100">
                No online Bridge reports provider capabilities. Open <a className="underline" href={shellHash('/settings/bridges')}>Bridges</a> or <a className="underline" href={shellHash('/settings/providers')}>Providers</a> to connect/configure one before creating agents.
              </div>
            ) : null}

            <div className="mt-5 grid gap-4 sm:grid-cols-2">
              <label className="block text-sm text-zinc-300">Name (agent id)<input data-debug-id="agents-create-name-input" value={name} onChange={(e) => setName(e.target.value)} placeholder="Code Reviewer" className="mt-1 w-full rounded-xl border border-white/10 bg-black/30 px-3 py-2 text-sm outline-none focus:border-sky-400" /></label>
              <label className="block text-sm text-zinc-300">Template / persona<select data-debug-id="agents-create-template-select" value={templateId} onChange={(e) => setTemplateId(e.target.value)} className="mt-1 w-full rounded-xl border border-white/10 bg-black/30 px-3 py-2 text-sm outline-none focus:border-sky-400"><option value="">Choose template</option>{templates.map((template: any) => <option key={template.id} value={template.id}>{template.name || template.id}</option>)}</select></label>

              <div className="sm:col-span-2 rounded-2xl border border-white/10 bg-white/[0.03] p-3">
                <button data-debug-id="agents-create-instructions-toggle-btn" type="button" onClick={() => setShowInstructions(!showInstructions)} className="text-sm font-medium text-zinc-200 hover:text-white">{showInstructions ? 'Hide' : 'Customize'} instructions</button>
                {showInstructions ? <textarea data-debug-id="agents-create-instructions-input" value={instructions} onChange={(e) => setInstructions(e.target.value)} placeholder="Optional additions layered on the selected template." className="mt-2 h-24 w-full rounded-xl border border-white/10 bg-black/30 px-3 py-2 text-sm outline-none focus:border-sky-400" /> : null}
              </div>

              <label className="block text-sm text-zinc-300">Where it runs<select data-debug-id="agents-create-bridge-scope" value={bridgeScope} onChange={(e) => setBridgeScope(e.target.value)} className="mt-1 w-full rounded-xl border border-white/10 bg-black/30 px-3 py-2 text-sm outline-none focus:border-sky-400"><option value="all">All online Bridges with capabilities</option>{capableOnlineBridges.map((bridge: any) => <option key={bridgeId(bridge)} value={bridgeId(bridge)}>{bridge.label || bridge.machine_hostname || bridgeId(bridge)}</option>)}</select></label>
              <label className="block text-sm text-zinc-300">Provider<select data-debug-id="agents-create-provider-scope" value={providerScope} onChange={(e) => setProviderScope(e.target.value as ProviderScope)} className="mt-1 w-full rounded-xl border border-white/10 bg-black/30 px-3 py-2 text-sm outline-none focus:border-sky-400"><option value="bridge_default">Use Bridge default</option><option value="same_provider">Same provider on selected Bridges</option><option value="per_bridge">Per-Bridge (configure after create)</option></select></label>

              {providerScope === 'same_provider' ? <label className="block text-sm text-zinc-300">Provider profile<select data-debug-id="agents-create-provider-select" value={provider} onChange={(e) => setProvider(e.target.value)} className="mt-1 w-full rounded-xl border border-white/10 bg-black/30 px-3 py-2 text-sm outline-none focus:border-sky-400"><option value="">Choose provider</option>{providerOptions.map((item) => <option key={item} value={item}>{item}</option>)}</select></label> : <div className="rounded-xl border border-white/10 bg-white/[0.03] p-3 text-sm text-zinc-500">{providerScope === 'per_bridge' ? 'Per-Bridge provider overrides can be set on the agent detail page after create.' : 'No provider is stored; each Bridge resolves its configured default.'}</div>}
              <label className="block text-sm text-zinc-300">Preferred tier<select data-debug-id="agents-create-tier-select" value={tier} onChange={(e) => setTier(e.target.value)} className="mt-1 w-full rounded-xl border border-white/10 bg-black/30 px-3 py-2 text-sm outline-none focus:border-sky-400">{(tierOptions.length ? tierOptions : tierOrder).map((item) => <option key={item} value={item}>{item}</option>)}</select></label>
            </div>

            <div className="mt-4 rounded-xl border border-white/10 bg-black/20 px-3 py-2 text-xs text-zinc-500">Will enable <span className="text-zinc-200">{supportPreviewCount}</span> Bridge{supportPreviewCount === 1 ? '' : 's'} that support the selected provider/tier.</div>

            <div className="mt-5 flex justify-end gap-2">
              <button data-debug-id="agents-create-cancel-btn" type="button" onClick={() => setShowForm(false)} className="rounded-xl bg-white/10 px-4 py-2 text-sm hover:bg-white/15">Cancel</button>
              <button data-debug-id="agents-create-submit-btn" type="submit" disabled={isCreating || isEnabling || !name.trim() || !templateId || noCapabilities || supportPreviewCount === 0} className="rounded-xl bg-sky-400 px-4 py-2 text-sm font-semibold text-black hover:bg-sky-300 disabled:opacity-50">{isCreating || isEnabling ? 'Creating…' : 'Create agent'}</button>
            </div>
          </form>
        </div>
      ) : null}

      {agentsQuery.isLoading ? (
        <div className="animate-pulse space-y-4"><div className="h-24 rounded-xl bg-white/5" /><div className="h-24 rounded-xl bg-white/5" /></div>
      ) : agents.length === 0 ? (
        <div className="rounded-xl border border-dashed border-white/20 p-8 text-center"><p className="text-zinc-400">No agents found.</p></div>
      ) : (
        <div className="space-y-3">
          {agents.map((agent: any) => {
            const id = agentIdOf(agent);
            const supported = Number(agent.supported_bridge_count ?? agent.supportedBridgeCount ?? 0);
            const active = Number(agent.active_instance_count ?? agent.activeInstanceCount ?? 0);
            return (
              <div key={id} data-debug-id={`agents-agent-row-${id}`} className="rounded-2xl border border-white/10 bg-white/[0.04] p-4 transition-colors hover:bg-white/[0.07]">
                <div className="flex flex-wrap items-start justify-between gap-3">
                  <div className="min-w-0">
                    <div className="flex flex-wrap items-center gap-2"><h3 className="font-semibold text-white">{agent.name || agent.slug || id}</h3><span className={`rounded-full px-2 py-0.5 text-[10px] uppercase tracking-wide ${agent.state === 'archived' ? 'bg-zinc-500/10 text-zinc-500' : 'bg-emerald-400/10 text-emerald-300'}`}>{agent.state || 'active'}</span></div>
                    <p className="mt-1 text-xs text-zinc-500">{id} · template {agent.template_id || agent.templateId || '—'} · provider {agent.default_provider || 'Bridge default'} · tier {agent.default_tier || 'Bridge default'}</p>
                    <p className="mt-1 text-xs text-zinc-500">supported Bridges <span className="text-zinc-300">{supported}</span> · running instances <span className="text-zinc-300">{active}</span></p>
                    {agent.instructions ? <p className="mt-2 line-clamp-2 text-sm text-zinc-300">{agent.instructions}</p> : null}
                  </div>
                  <div className="flex shrink-0 flex-wrap gap-2">
                    <a data-debug-id={`agents-agent-open-btn-${id}`} href={shellHash(`/agents/${encodeURIComponent(id)}`)} className="rounded-lg border border-white/10 px-2.5 py-1 text-xs text-zinc-300 hover:bg-white/10">Open</a>
                    <button data-debug-id={`agents-agent-launch-btn-${id}`} type="button" onClick={() => void handleLaunch(agent)} disabled={isLaunching || launchingAgentId === id || supported === 0 || agent.state === 'archived'} className="rounded-lg border border-sky-400/30 px-2.5 py-1 text-xs text-sky-100 hover:bg-sky-400/10 disabled:opacity-50">{launchingAgentId === id ? 'Launching…' : 'Launch'}</button>
                    <button data-debug-id={`agents-agent-archive-btn-${id}`} type="button" onClick={() => void handleArchive(id)} disabled={agent.state === 'archived'} className="rounded-lg border border-rose-400/20 px-2.5 py-1 text-xs text-rose-200 hover:bg-rose-400/10 disabled:opacity-40">Archive</button>
                  </div>
                </div>
              </div>
            );
          })}
        </div>
      )}
    </div>
  );
}

function normalizeTemplate(template: any) {
  return {
    id: String(template?.template_id || template?.templateId || template?.id || ''),
    name: String(template?.name || template?.display_name || template?.displayName || template?.template_id || template?.id || ''),
  };
}

function bridgeId(bridge: any): string { return String(bridge?.bridge_id || bridge?.bridgeId || bridge?.id || ''); }
function agentIdOf(agent: any): string { return String(agent?.agent_id || agent?.agentId || agent?.id || ''); }
function isOnline(bridge: any): boolean { return String(bridge?.status || '').toLowerCase() === 'online'; }
function slugify(value: string): string { return value.trim().toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-+|-+$/g, '') || value.trim(); }
function shellHash(path: string): string { return `#${path.startsWith('/') ? path : `/${path}`}`; }

function unionProviders(bridges: any[]): string[] {
  return Array.from(new Set(bridges.flatMap((bridge) => normalizeBridgeCapabilities(bridge).map((cap) => cap.provider)))).sort();
}

function unionTiers(bridges: any[], provider: string): string[] {
  const tiers = new Set<string>();
  for (const bridge of bridges) {
    const caps = normalizeBridgeCapabilities(bridge);
    const matched = provider ? caps.filter((cap) => cap.provider === provider) : defaultCaps(caps);
    for (const cap of matched) {
      for (const tier of cap.tiers || []) tiers.add(tier);
      if (cap.defaultTier) tiers.add(cap.defaultTier);
    }
  }
  return tierOrder.filter((tier) => tiers.has(tier)).concat(Array.from(tiers).filter((tier) => !tierOrder.includes(tier)).sort());
}

function eligibleSupportRows(bridges: any[], providerScope: ProviderScope, provider: string, tier: string) {
  return bridges.filter((bridge) => bridgeCanSupport(bridge, providerScope === 'same_provider' ? provider : '', tier)).map((bridge) => ({ bridgeId: bridgeId(bridge), enabled: true }));
}

function bridgeCanSupport(bridge: any, provider: string, tier: string): boolean {
  const caps: BridgeCapability[] = normalizeBridgeCapabilities(bridge);
  if (!caps.length) return false;
  if (provider) {
    const cap = caps.find((item) => item.provider === provider);
    if (!cap) return false;
    return !tier || !cap.tiers?.length || cap.tiers.includes(tier) || cap.defaultTier === tier;
  }
  if (!tier) return true;
  return defaultCaps(caps).some((cap) => !cap.tiers?.length || cap.tiers.includes(tier) || cap.defaultTier === tier);
}

function defaultCaps(caps: BridgeCapability[]): BridgeCapability[] {
  if (!caps.length) return [];
  const withDefaultTier = caps.find((cap) => cap.defaultTier);
  return [withDefaultTier || caps[0]];
}
