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
import { Button, Icon, Input, PageShell, Select, StatusPill, Textarea } from '@ui';

type ProviderScope = 'bridge_default' | 'same_provider' | 'per_bridge';
type BridgeScope = 'all' | string;

const tierOrder = ['cheap', 'normal', 'smart'];

function useAgentCreateState() {
  const templatesQuery = useListAgentTemplatesQuery();
  // Poll: bridge status/capabilities change async and the Hub emits no user-WS
  // event for bridge liveness, so a one-shot fetch can leave create/launch
  // controls empty after a Bridge comes online.
  const bridgesQuery = useListBridgesQuery(undefined, { pollingInterval: 120000, refetchOnMountOrArgChange: true });
  const [name, setName] = useState('');
  const [templateId, setTemplateId] = useState('');
  const [instructions, setInstructions] = useState('');
  const [showInstructions, setShowInstructions] = useState(false);
  const [bridgeScope, setBridgeScope] = useState<BridgeScope>('all');
  const [providerScope, setProviderScope] = useState<ProviderScope>('bridge_default');
  const [provider, setProvider] = useState('');
  const [tier, setTier] = useState('normal');
  const [errorMsg, setErrorMsg] = useState('');
  const templates = useMemo(() => (templatesQuery.data?.templates || []).map(normalizeTemplate).filter((t: any) => t.id), [templatesQuery.data?.templates]);
  const bridges = bridgesQuery.data?.bridges || [];
  const capableOnlineBridges = useMemo(() => bridges.filter((bridge: any) => isOnline(bridge) && normalizeBridgeCapabilities(bridge).length > 0), [bridges]);
  const selectedBridges = useMemo(() => bridgeScope === 'all' ? capableOnlineBridges : capableOnlineBridges.filter((bridge: any) => bridgeId(bridge) === bridgeScope), [bridgeScope, capableOnlineBridges]);
  const providerOptions = useMemo(() => unionProviders(selectedBridges), [selectedBridges]);
  const tierOptions = useMemo(() => unionTiers(selectedBridges, providerScope === 'same_provider' ? provider : ''), [selectedBridges, providerScope, provider]);
  const noCapabilities = capableOnlineBridges.length === 0;
  const supportPreviewCount = eligibleSupportRows(selectedBridges, providerScope, provider, tier).length;
  useEffect(() => { if (!templateId && templates[0]?.id) setTemplateId(templates[0].id); }, [templates, templateId]);
  useEffect(() => { if (providerScope === 'same_provider' && !provider && providerOptions[0]) setProvider(providerOptions[0]); }, [providerScope, provider, providerOptions]);
  useEffect(() => { if (tierOptions.length > 0 && !tierOptions.includes(tier)) setTier(tierOptions.includes('normal') ? 'normal' : tierOptions[0]); }, [tierOptions, tier]);
  return { name, setName, templateId, setTemplateId, instructions, setInstructions, showInstructions, setShowInstructions, bridgeScope, setBridgeScope, providerScope, setProviderScope, provider, setProvider, tier, setTier, errorMsg, setErrorMsg, templates, capableOnlineBridges, selectedBridges, providerOptions, tierOptions, noCapabilities, supportPreviewCount };
}

export function AgentsPanel() {
  const agentsQuery = useListAgentIdentitiesQuery();
  const [archiveAgent] = useArchiveAgentIdentityMutation();
  const [launchAgent, { isLoading: isLaunching }] = useLaunchAgentInstanceMutation();
  const agents = (agentsQuery.data?.agents || []).filter((a: any) => a.state !== 'archived');
  const [errorMsg, setErrorMsg] = useState('');
  const [launchingAgentId, setLaunchingAgentId] = useState('');

  async function handleArchive(agentId: string) {
    if (!agentId) return;
    setErrorMsg('');
    try { await archiveAgent({ agentId }).unwrap(); } catch (err: any) { setErrorMsg(String(err?.message || 'Failed to archive agent')); }
  }

  async function handleLaunch(agent: any) {
    const agentId = agentIdOf(agent);
    if (!agentId) return;
    setLaunchingAgentId(agentId);
    setErrorMsg('');
    try { await launchAgent({ agentId }).unwrap(); await agentsQuery.refetch(); } catch (err: any) { setErrorMsg(String(err?.message || 'Failed to launch agent instance')); } finally { setLaunchingAgentId(''); }
  }

  return (
    <PageShell
      title="Agents"
      description="Create durable agent identities from templates, choose where they run, and optionally pin a provider while keeping Bridge defaults as the normal path."
      actions={
        <Button variant="primary" data-debug-id="agents-add-agent-btn" onClick={() => { window.location.hash = shellHash('/agents/new'); }} leading={<Icon name="plus" size={16} />}>Add agent</Button>
      }
    >
      <div className="space-y-6 text-left">
      {errorMsg ? <div className="rounded-xl border border-danger/30 bg-danger-soft px-3 py-2 text-sm text-danger">{errorMsg}</div> : null}
      {agentsQuery.isLoading ? <div className="animate-pulse space-y-4"><div className="h-24 rounded-xl bg-surface-raised/40" /><div className="h-24 rounded-xl bg-surface-raised/40" /></div> : agents.length === 0 ? <div className="rounded-xl border border-dashed border-subtle p-8 text-center"><p className="text-muted">No agents found.</p></div> : (
        <div className="space-y-3">{agents.map((agent: any) => {
          const id = agentIdOf(agent); const supported = Number(agent.supported_bridge_count ?? agent.supportedBridgeCount ?? 0); const active = Number(agent.active_instance_count ?? agent.activeInstanceCount ?? 0);
          return <div key={id} data-debug-id={`agents-agent-row-${id}`} className="rounded-2xl border border-subtle bg-surface-raised/40 p-4 transition-colors hover:bg-surface-raised"><div className="flex flex-wrap items-start justify-between gap-3"><div className="min-w-0"><div className="flex flex-wrap items-center gap-2"><h3 className="font-semibold text-primary">{agent.name || agent.slug || id}</h3><StatusPill tone={agent.state === 'archived' ? 'neutral' : 'success'} className="uppercase">{agent.state || 'active'}</StatusPill></div><p className="mt-1 text-xs text-muted">{id} · template {agent.template_id || agent.templateId || '—'} · provider {agent.default_provider || 'Bridge default'} · tier {agent.default_tier || 'Bridge default'}</p><p className="mt-1 text-xs text-muted">supported Bridges <span className="text-primary">{supported}</span> · running instances <span className="text-primary">{active}</span></p>{agent.instructions ? <p className="mt-2 line-clamp-2 text-sm text-muted">{agent.instructions}</p> : null}</div><div className="flex shrink-0 flex-wrap gap-2"><a data-debug-id={`agents-agent-open-btn-${id}`} href={shellHash(`/agents/${encodeURIComponent(id)}`)} className="rounded-lg border border-subtle px-2.5 py-1 text-xs text-muted hover:bg-neutral-soft">Open</a><a data-debug-id={`agents-agent-launch-btn-${id}`} href={shellHash(`/agents/${encodeURIComponent(id)}`)} className={`rounded-lg border border-info/30 px-2.5 py-1 text-xs text-info hover:bg-info-soft ${agent.state === 'archived' ? 'pointer-events-none opacity-50' : ''}`}>Launch…</a><button data-debug-id={`agents-agent-archive-btn-${id}`} type="button" onClick={() => void handleArchive(id)} disabled={agent.state === 'archived'} className="rounded-lg border border-danger/30 px-2.5 py-1 text-xs text-danger hover:bg-danger-soft disabled:opacity-40">Archive</button></div></div></div>;
        })}</div>
      )}
      </div>
    </PageShell>
  );
}

export function NewAgentPage() {
  const agentsQuery = useListAgentIdentitiesQuery();
  const [createAgent, { isLoading: isCreating }] = useCreateAgentMutation();
  const [enableBridgeSupport, { isLoading: isEnabling }] = useEnableBridgeSupportMutation();
  const state = useAgentCreateState();
  async function handleSubmit(e: React.FormEvent) {
    e.preventDefault();
    state.setErrorMsg('');
    if (!state.name.trim()) { state.setErrorMsg('Agent name is required.'); return; }
    if (!state.templateId) { state.setErrorMsg('Choose a template/persona.'); return; }
    if (state.noCapabilities) { state.setErrorMsg('No online Bridge reports provider capabilities yet. Configure a Bridge provider first.'); return; }
    if (state.providerScope === 'same_provider' && !state.provider) { state.setErrorMsg('Choose a provider or use the Bridge default.'); return; }
    const supportRows = eligibleSupportRows(state.selectedBridges, state.providerScope, state.provider, state.tier);
    if (supportRows.length === 0) { state.setErrorMsg('No selected Bridge supports the chosen provider.'); return; }
    try {
      const created = await createAgent({ name: state.name.trim(), slug: slugify(state.name.trim()), templateId: state.templateId, defaultProvider: state.providerScope === 'same_provider' ? state.provider : undefined, defaultTier: state.tier, instructions: state.instructions }).unwrap();
      const agentId = String(created?.agent_id || created?.agentId || '');
      if (!agentId) throw new Error('Agent was created but no agent_id was returned.');
      await enableBridgeSupport({ agentId, bridges: supportRows }).unwrap();
      await agentsQuery.refetch();
      window.location.hash = shellHash(`/agents/${encodeURIComponent(agentId)}`);
    } catch (err: any) { state.setErrorMsg(String(err?.message || err || 'Failed to create agent')); }
  }
  return (
    <PageShell
      title="Create agent"
      description="Pick a name, persona, Bridge scope, and preferred tier. Provider can stay on Bridge default."
      actions={
        <a data-debug-id="agents-create-header-cancel-btn" href={shellHash('/agents')} className="inline-flex min-h-[44px] items-center justify-center rounded-xl bg-neutral-soft px-4 py-2 text-sm hover:bg-surface-raised">Cancel</a>
      }
    >
      <div className="space-y-6 text-left">
      {state.noCapabilities ? <div data-debug-id="agents-no-capabilities-warning" className="rounded-xl border border-warning/30 bg-warning-soft px-3 py-2 text-sm text-warning">No online Bridge reports provider capabilities. Open <a data-debug-id="agents-no-capabilities-bridges-link" className="underline" href={shellHash('/settings/bridges')}>Bridges</a> or <a data-debug-id="agents-no-capabilities-providers-link" className="underline" href={shellHash('/settings/providers')}>Providers</a> to connect/configure one before creating agents.</div> : null}
      {state.errorMsg ? <div className="rounded-xl border border-danger/30 bg-danger-soft px-3 py-2 text-sm text-danger">{state.errorMsg}</div> : null}
      <form onSubmit={handleSubmit} className="rounded-2xl border border-subtle bg-surface-raised/40 p-4 sm:p-5">
        <div className="grid gap-4 sm:grid-cols-2">
          <label className="block text-sm text-muted">Name (agent id)<Input data-debug-id="agents-create-name-input" value={state.name} onChange={state.setName} placeholder="Code Reviewer" width="full" className="mt-1 min-h-[44px]" /></label>
          <label className="block text-sm text-muted">Template / persona<Select data-debug-id="agents-create-template-select" value={state.templateId} onChange={state.setTemplateId} width="full" className="mt-1 min-h-[44px]"><option value="">Choose template</option>{state.templates.map((template: any) => <option key={template.id} value={template.id}>{template.name || template.id}</option>)}</Select></label>
          <div className="rounded-2xl border border-subtle bg-surface-raised/30 p-3 sm:col-span-2"><Button variant="ghost" data-debug-id="agents-create-instructions-toggle-btn" onClick={() => state.setShowInstructions(!state.showInstructions)} className="min-h-[44px]">{state.showInstructions ? 'Hide' : 'Customize'} instructions</Button>{state.showInstructions ? <Textarea data-debug-id="agents-create-instructions-input" value={state.instructions} onChange={state.setInstructions} placeholder="Optional additions layered on the selected template." width="full" className="mt-2 h-28" /> : null}</div>
          <label className="block text-sm text-muted">Where it runs<Select data-debug-id="agents-create-bridge-scope" value={state.bridgeScope} onChange={state.setBridgeScope} width="full" className="mt-1 min-h-[44px]"><option value="all">All online Bridges with capabilities</option>{state.capableOnlineBridges.map((bridge: any) => <option key={bridgeId(bridge)} value={bridgeId(bridge)}>{bridge.label || bridge.machine_hostname || bridgeId(bridge)}</option>)}</Select></label>
          <label className="block text-sm text-muted">Provider<Select data-debug-id="agents-create-provider-scope" value={state.providerScope} onChange={(value) => state.setProviderScope(value as ProviderScope)} width="full" className="mt-1 min-h-[44px]"><option value="bridge_default">Use Bridge default</option><option value="same_provider">Same provider on selected Bridges</option><option value="per_bridge">Per-Bridge (configure after create)</option></Select></label>
          {state.providerScope === 'same_provider' ? <label className="block text-sm text-muted">Provider profile<Select data-debug-id="agents-create-provider-select" value={state.provider} onChange={state.setProvider} width="full" className="mt-1 min-h-[44px]"><option value="">Choose provider</option>{state.providerOptions.map((item) => <option key={item} value={item}>{item}</option>)}</Select></label> : <div className="rounded-xl border border-subtle bg-surface-raised/30 p-3 text-sm text-muted">{state.providerScope === 'per_bridge' ? 'Per-Bridge provider overrides can be set on the agent detail page after create.' : 'No provider is stored; each Bridge resolves its configured default.'}</div>}
          <label className="block text-sm text-muted">Preferred tier<Select data-debug-id="agents-create-tier-select" value={state.tier} onChange={state.setTier} width="full" className="mt-1 min-h-[44px]">{(state.tierOptions.length ? state.tierOptions : tierOrder).map((item) => <option key={item} value={item}>{item}</option>)}</Select></label>
        </div>
        <div className="mt-4 rounded-xl border border-subtle bg-surface-raised/30 px-3 py-2 text-xs text-muted">Will enable <span className="text-primary">{state.supportPreviewCount}</span> Bridge{state.supportPreviewCount === 1 ? '' : 's'} that support the selected provider. Tier remains a preferred default; each Bridge can run any configured tier for its providers.</div>
        <div className="z-10 mt-5 flex flex-col-reverse gap-2 rounded-2xl border border-subtle bg-surface/95 p-3 pb-[max(0.75rem,env(safe-area-inset-bottom))] backdrop-blur md:sticky md:bottom-0 sm:flex-row sm:justify-end">
          <a data-debug-id="agents-create-footer-cancel-btn" href={shellHash('/agents')} className="inline-flex min-h-[44px] items-center justify-center rounded-xl bg-neutral-soft px-4 py-2 text-sm hover:bg-surface-raised">Cancel</a>
          <Button variant="primary" data-debug-id="agents-create-submit-btn" type="submit" disabled={isCreating || isEnabling || !state.name.trim() || !state.templateId || state.noCapabilities || state.supportPreviewCount === 0} className="min-h-[44px]">{isCreating || isEnabling ? 'Creating…' : 'Create agent'}</Button>
        </div>
      </form>
      </div>
    </PageShell>
  );
}

function normalizeTemplate(template: any) { return { id: String(template?.template_id || template?.templateId || template?.id || ''), name: String(template?.name || template?.display_name || template?.displayName || template?.template_id || template?.id || '') }; }
function bridgeId(bridge: any): string { return String(bridge?.bridge_id || bridge?.bridgeId || bridge?.id || ''); }
function agentIdOf(agent: any): string { return String(agent?.agent_id || agent?.agentId || agent?.id || ''); }
function isOnline(bridge: any): boolean { return String(bridge?.status || '').toLowerCase() === 'online'; }
function slugify(value: string): string { return value.trim().toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-+|-+$/g, '') || value.trim(); }
function shellHash(path: string): string { return `#${path.startsWith('/') ? path : `/${path}`}`; }
function unionProviders(bridges: any[]): string[] { return Array.from(new Set(bridges.flatMap((bridge) => normalizeBridgeCapabilities(bridge).map((cap) => cap.provider)))).sort(); }
function unionTiers(bridges: any[], provider: string): string[] { const tiers = new Set<string>(); for (const bridge of bridges) { const caps = normalizeBridgeCapabilities(bridge); const matched = provider ? caps.filter((cap) => cap.provider === provider) : defaultCaps(caps); for (const cap of matched) { for (const tier of cap.tiers || []) tiers.add(tier); if (cap.defaultTier) tiers.add(cap.defaultTier); } } return tierOrder.filter((tier) => tiers.has(tier)).concat(Array.from(tiers).filter((tier) => !tierOrder.includes(tier)).sort()); }
function eligibleSupportRows(bridges: any[], providerScope: ProviderScope, provider: string, _tier: string) { return bridges.filter((bridge) => bridgeCanSupportProvider(bridge, providerScope === 'same_provider' ? provider : '')).map((bridge) => ({ bridgeId: bridgeId(bridge), enabled: true })); }
function bridgeCanSupportProvider(bridge: any, provider: string): boolean { const caps = normalizeBridgeCapabilities(bridge); if (!caps.length) return false; if (!provider) return true; return caps.some((item) => item.provider === provider); }
function defaultCaps(caps: BridgeCapability[]): BridgeCapability[] { if (!caps.length) return []; const withDefaultTier = caps.find((cap) => cap.defaultTier); return [withDefaultTier || caps[0]]; }
