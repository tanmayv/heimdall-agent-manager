import { useEffect, useMemo, useState } from 'react';
import * as daemonApi from '../api/daemonApi';

export type AgentPickerProps = {
  debugId: string;
  daemonUrl: string;
  clientToken?: string;
  agents: any[];
  identities?: any[];
  team?: any;
  projects: any[];
  templates?: any[];
  providers?: any[];
  value?: string;
  roleHint?: string;
  defaultProjectId?: string;
  conversationSummaryById?: Record<string, any>;
  remotePeersEnabled?: boolean;
  onSelected: (agentInstanceId: string, result?: any) => void | Promise<void>;
  onRefreshAgents?: () => void | Promise<void>;
  selectionOnly?: boolean;
};

type PickerRow = {
  kind: 'instance' | 'identity';
  key: string;
  id: string;
  title: string;
  subtitle: string;
  conversationTitle: string;
  provider: string;
  tier: string;
  running: boolean;
  agent?: any;
  identity?: any;
  chips: string[];
  searchText: string;
  sortText: string;
};

function slug(value: string): string {
  return String(value || '').toLowerCase().replace(/[^a-z0-9_-]+/g, '-').replace(/^-+|-+$/g, '') || 'item';
}

function agentInstanceId(agent: any): string {
  return String(agent?.id || agent?.agentInstanceId || agent?.agent_instance_id || '');
}

function agentId(agent: any): string {
  return agentInstanceId(agent);
}

function durableAgentId(agent: any): string {
  const durable = String(agent?.agentId || agent?.agent_id || '');
  if (durable) return durable;
  const id = agentInstanceId(agent);
  const at = id.indexOf('@');
  return at >= 0 ? id.slice(0, at) : id;
}

function agentLabel(agent: any): string {
  return String(agent?.label || agent?.displayName || agent?.display_name || agentInstanceId(agent) || durableAgentId(agent) || 'Agent');
}

function agentTemplate(agent: any): string {
  return String(agent?.templateId || agent?.template_id || agent?.agentRole || agent?.agent_role || agent?.roleHint || agent?.role_hint || durableAgentId(agent));
}

function providerName(provider: any): string {
  return String(provider?.name || provider?.id || provider?.provider_profile || provider || '');
}

function providerLabel(provider: any): string {
  return String(provider?.label || provider?.display_name || providerName(provider) || '');
}

function connectionState(agent: any): string {
  return String(agent?.connectionState || agent?.connection_state || '').toLowerCase();
}

function isRunning(agent: any): boolean {
  const startup = String(agent?.startupStatus || agent?.startup_status || '').toLowerCase();
  const state = String(agent?.state || agent?.status || '').toLowerCase();
  if (startup === 'stopped' || startup === 'stopping' || startup === 'startup_blocked') return false;
  if (agent?.connected || connectionState(agent) === 'connected') return true;
  return ['connected', 'ready', 'active', 'working', 'running', 'idle'].includes(state) && state !== 'offline';
}

function agentKind(agent: any): string {
  return String(agent?.agentKind || agent?.agent_kind || 'local');
}

function agentRemote(agent: any): { peerId: string; originDaemonId: string; remoteAgentInstanceId: string } | null {
  const remote = agent?.remote;
  if (remote) {
    const peerId = String(remote.peerId || remote.peer_id || '');
    const originDaemonId = String(remote.originDaemonId || remote.origin_daemon_id || '');
    const remoteAgentInstanceId = String(remote.remoteAgentInstanceId || remote.remote_agent_instance_id || '');
    if (peerId || originDaemonId || remoteAgentInstanceId) return { peerId, originDaemonId, remoteAgentInstanceId };
  }
  const peerId = String(agent?.remote_peer_id || agent?.remotePeerId || '');
  const originDaemonId = String(agent?.remote_origin_daemon_id || agent?.remoteOriginDaemonId || agent?.origin_daemon_id || agent?.originDaemonId || '');
  const remoteAgentInstanceId = String(agent?.remote_agent_instance_id || agent?.remoteAgentInstanceId || '');
  if (peerId || originDaemonId || remoteAgentInstanceId) return { peerId, originDaemonId, remoteAgentInstanceId };
  return null;
}

function isRemoteProxyAgent(agent: any): boolean {
  return agentKind(agent) === 'remote_proxy' && Boolean(agentRemote(agent)?.peerId) && Boolean(agentRemote(agent)?.remoteAgentInstanceId);
}

function roleMatches(value: any, roleHint: string) {
  if (!roleHint) return true;
  const hint = roleHint.toLowerCase();
  const remote = agentRemote(value);
  const haystack = [
    agentInstanceId(value),
    durableAgentId(value),
    agentLabel(value),
    agentTemplate(value),
    value?.agentRole || value?.agent_role || value?.roleHint || value?.role_hint || '',
    value?.template_id || value?.templateId || '',
    value?.display_name || value?.displayName || '',
    value?.providerProfile || value?.provider_profile || '',
    remote?.originDaemonId || '',
    remote?.remoteAgentInstanceId || '',
  ].join(' ').toLowerCase();
  if (hint === 'coder' || hint === 'assignee') return haystack.includes('coder') || haystack.includes('code') || haystack.includes('implement');
  if (hint === 'reviewer') return haystack.includes('review') || haystack.includes('verify') || haystack.includes('test');
  if (hint === 'coordinator') return haystack.includes('coord') || haystack.includes('lead');
  return haystack.includes(hint);
}

function statusLabel(agent: any): string {
  return isRunning(agent) ? 'LIVE' : (agentInstanceId(agent) === 'user_proxy' ? 'USER' : 'OFFLINE');
}

function searchMatches(item: any, query: string) {
  const q = query.trim().toLowerCase();
  if (!q) return true;
  if (item && typeof item.searchText === 'string') {
    return item.searchText.includes(q);
  }
  const remote = agentRemote(item);
  const haystack = [
    agentId(item),
    agentLabel(item),
    agentTemplate(item),
    item?.agentRole || item?.agent_role || '',
    item?.providerProfile || item?.provider_profile || '',
    item?.projectId || item?.project_id || '',
    statusLabel(item),
    remote?.peerId || '',
    remote?.originDaemonId || '',
    remote?.remoteAgentInstanceId || '',
  ].join(' ').toLowerCase();
  return haystack.includes(q);
}

function remoteAgentId(agent: any): string {
  return String(agent?.agent_instance_id || agent?.agentInstanceId || agent?.remoteAgentInstanceId || '');
}

function remoteAgentLabel(agent: any): string {
  return remoteAgentId(agent) || String(agent?.display_name || agent?.displayName || '');
}

function peerStatus(peer: any): string {
  return String(peer?.status || '').toLowerCase() === 'linked' ? 'linked' : 'unreachable';
}

function conversationTitleFor(agent: any, conversationSummaryById: Record<string, any>) {
  const summary = conversationSummaryById?.[agentInstanceId(agent)] || null;
  return String(summary?.title || '').trim();
}

function teamMemberIds(team: any): Set<string> {
  const members = team?.team?.members || team?.members || [];
  return new Set((members || []).map((member: any) => String(member?.agent_instance_id || member?.agentInstanceId || member?.route_to || '')).filter(Boolean));
}

function identityRole(identity: any): string {
  return String(identity?.agent_role || identity?.agentRole || identity?.role_hint || identity?.roleHint || identity?.template_id || identity?.templateId || identity?.agent_id || identity?.agentId || '');
}

function identityTemplate(identity: any): string {
  return String(identity?.template_id || identity?.templateId || identity?.agent_id || identity?.agentId || '');
}

function identityLabel(identity: any): string {
  return String(identity?.display_name || identity?.displayName || identity?.agent_id || identity?.agentId || 'Agent');
}

function buildInstanceRow(agent: any, conversationSummaryById: Record<string, any>): PickerRow {
  const id = agentInstanceId(agent);
  const conversationTitle = conversationTitleFor(agent, conversationSummaryById);
  const provider = String(agent?.providerProfile || agent?.provider_profile || '');
  const tier = String(agent?.modelTier || agent?.model_tier || 'normal') || 'normal';
  const title = agentLabel(agent);
  const durable = durableAgentId(agent);
  const template = agentTemplate(agent);
  const running = isRunning(agent);
  const chips = [template, provider, agent?.projectId || agent?.project_id ? `home ${agent?.projectId || agent?.project_id}` : '', durable === 'conversation' ? 'conversation' : ''].filter(Boolean);
  return {
    kind: 'instance',
    key: `instance:${id}`,
    id,
    title,
    subtitle: id,
    conversationTitle,
    provider,
    tier,
    running,
    agent,
    chips,
    searchText: [title, id, durable, template, provider, tier, conversationTitle, chips.join(' ')].join(' ').toLowerCase(),
    sortText: `${title} ${id}`.toLowerCase(),
  };
}

function buildIdentityRow(identity: any): PickerRow {
  const id = String(identity?.agent_id || identity?.agentId || '');
  const provider = String(identity?.default_provider_profile || identity?.defaultProviderProfile || '');
  const tier = String(identity?.default_model_tier || identity?.defaultModelTier || 'normal') || 'normal';
  const title = identityLabel(identity);
  const template = identityTemplate(identity);
  const role = identityRole(identity);
  const subtitle = `agent_id: ${id}`;
  const chips = [role, template && template !== id ? template : '', 'new dormant instance'].filter(Boolean);
  return {
    kind: 'identity',
    key: `identity:${id}`,
    id,
    title,
    subtitle,
    conversationTitle: '',
    provider,
    tier,
    running: false,
    identity,
    chips,
    searchText: [title, id, template, role, provider, tier, chips.join(' ')].join(' ').toLowerCase(),
    sortText: `${title} ${id}`.toLowerCase(),
  };
}

export default function AgentPicker({
  debugId,
  daemonUrl,
  clientToken = '',
  agents,
  identities = [],
  team,
  projects,
  templates = [],
  providers = [],
  value = '',
  roleHint = '',
  defaultProjectId = '',
  conversationSummaryById = {},
  remotePeersEnabled = false,
  onSelected,
  onRefreshAgents,
  selectionOnly = false,
}: AgentPickerProps) {
  const [query, setQuery] = useState('');
  const [tab, setTab] = useState<'suggested' | 'instances'>('suggested');
  const [busyKey, setBusyKey] = useState('');
  const [error, setError] = useState('');
  const [prefsByKey, setPrefsByKey] = useState<Record<string, { provider: string; tier: string }>>({});
  const fallbackTemplate = String(templates[0]?.template_id || templates[0]?.templateId || roleHint || 'agent');
  const providerOptions = useMemo(() => {
    const vals = providers.map(providerName).filter(Boolean);
    return vals.length ? vals : ['pi'];
  }, [providers]);
  const providerByName = useMemo(() => {
    const map = new Map<string, any>();
    providers.forEach((provider) => map.set(providerName(provider), provider));
    return map;
  }, [providers]);
  const tierOptions = ['cheap', 'normal', 'smart'];
  const instanceRows = useMemo(() => {
    return (agents || [])
      .filter((agent) => agentInstanceId(agent) && roleMatches(agent, roleHint))
      .map((agent) => buildInstanceRow(agent, conversationSummaryById))
      .sort((left, right) => left.sortText.localeCompare(right.sortText));
  }, [agents, conversationSummaryById, roleHint]);
  const identityRows = useMemo(() => {
    if (!selectionOnly) return [] as PickerRow[];
    return (identities || [])
      .filter((identity) => {
        const id = String(identity?.agent_id || identity?.agentId || '');
        if (!id || id === 'user_proxy') return false;
        return roleMatches(identity, roleHint);
      })
      .map(buildIdentityRow)
      .sort((left, right) => left.sortText.localeCompare(right.sortText));
  }, [identities, roleHint, selectionOnly]);
  const teamIds = useMemo(() => teamMemberIds(team), [team]);

  useEffect(() => {
    const next: Record<string, { provider: string; tier: string }> = {};
    [...instanceRows, ...identityRows].forEach((row) => {
      next[row.key] = prefsByKey[row.key] || { provider: row.provider || providerOptions[0] || 'pi', tier: row.tier || 'normal' };
    });
    setPrefsByKey((prev) => ({ ...next, ...prev }));
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [instanceRows.length, identityRows.length, providerOptions.join(',')]);

  const suggestedRows = useMemo(() => {
    const matchingInstances = instanceRows.filter((row) => searchMatches(row, query));
    const matchingIdentities = identityRows.filter((row) => searchMatches(row, query));
    if (!selectionOnly) {
      return {
        teamRows: [] as PickerRow[],
        liveOtherRows: matchingInstances,
        identityRows: [] as PickerRow[],
        offlineOtherRows: [] as PickerRow[],
      };
    }
    if (teamIds.size > 0) {
      const teamRows = matchingInstances.filter((row) => teamIds.has(row.id));
      const nonTeamRows = matchingInstances.filter((row) => !teamIds.has(row.id));
      const liveOtherRows = nonTeamRows.filter((row) => row.running);
      const offlineOtherRows = nonTeamRows.filter((row) => !row.running);
      return { teamRows, liveOtherRows, identityRows: matchingIdentities, offlineOtherRows };
    }
    return {
      teamRows: [] as PickerRow[],
      liveOtherRows: matchingInstances,
      identityRows: matchingIdentities,
      offlineOtherRows: [] as PickerRow[],
    };
  }, [identityRows, instanceRows, query, selectionOnly, teamIds]);

  const allInstanceRows = useMemo(() => instanceRows.filter((row) => searchMatches(row, query)), [instanceRows, query]);
  const selectedId = value || '';
  const selectedLabel = useMemo(() => {
    const row = [...instanceRows, ...identityRows].find((item) => item.id === selectedId || item.subtitle === selectedId);
    if (row) return row.id;
    const selectedAgent = (agents || []).find((agent) => agentId(agent) === selectedId);
    const remote = selectedAgent ? agentRemote(selectedAgent) : null;
    if (selectedAgent && isRemoteProxyAgent(selectedAgent) && remote) return `${remote.remoteAgentInstanceId} · ${remote.originDaemonId || remote.peerId}`;
    return selectedId;
  }, [identityRows, instanceRows, selectedId, agents]);

  const [runId, setRunId] = useState('');
  const [runTemplate, setRunTemplate] = useState(fallbackTemplate);
  const [runProvider, setRunProvider] = useState(providerOptions[0] || 'pi');
  const [runProject, setRunProject] = useState(defaultProjectId || '');
  const [runTier, setRunTier] = useState('normal');
  const [createId, setCreateId] = useState('');
  const [createName, setCreateName] = useState('');
  const [createTemplate, setCreateTemplate] = useState(fallbackTemplate);
  const [createProvider, setCreateProvider] = useState(providerOptions[0] || 'pi');
  const [createProject, setCreateProject] = useState(defaultProjectId || '');
  const [createTier, setCreateTier] = useState('normal');
  const [remotePeers, setRemotePeers] = useState<any[]>([]);
  const [remoteLoading, setRemoteLoading] = useState(false);
  const [remoteError, setRemoteError] = useState('');

  useEffect(() => {
    setRunTemplate(fallbackTemplate);
    setCreateTemplate(fallbackTemplate);
  }, [fallbackTemplate]);

  useEffect(() => {
    setRunProvider(providerOptions[0] || 'pi');
    setCreateProvider(providerOptions[0] || 'pi');
  }, [providerOptions]);

  useEffect(() => {
    let cancelled = false;
    async function loadRemotePeers() {
      if (!remotePeersEnabled || !daemonUrl || !clientToken) {
        if (!cancelled) {
          setRemotePeers([]);
          setRemoteError('');
          setRemoteLoading(false);
        }
        return;
      }
      setRemoteLoading(true);
      setRemoteError('');
      try {
        const peers = await daemonApi.listFederationPeers({ daemonUrl, clientToken });
        const loaded = await Promise.all((peers || []).map(async (peer: any) => {
          const effectiveStatus = peerStatus(peer);
          if (effectiveStatus !== 'linked') return { ...peer, remoteAgents: [], loadError: '' };
          try {
            const data = await daemonApi.listPeerAdvertisedAgents({ daemonUrl, clientToken, peerId: peer.peer_id });
            return { ...peer, daemonName: data.daemonId || peer.daemon_id || peer.peer_id, remoteAgents: data.agents || [], loadError: '' };
          } catch (err: any) {
            return { ...peer, daemonName: peer.daemon_id || peer.peer_id, status: 'unreachable', remoteAgents: [], loadError: err?.message || 'Unable to load peer agents' };
          }
        }));
        if (!cancelled) setRemotePeers(loaded);
      } catch (err: any) {
        if (!cancelled) {
          setRemotePeers([]);
          setRemoteError(err?.message || 'Unable to load peer daemons');
        }
      } finally {
        if (!cancelled) setRemoteLoading(false);
      }
    }
    loadRemotePeers().catch(() => undefined);
    return () => { cancelled = true; };
  }, [remotePeersEnabled, daemonUrl, clientToken]);

  async function refresh() {
    if (onRefreshAgents) await onRefreshAgents();
  }

  async function useRow(row: PickerRow) {
    if (!selectionOnly) {
      await onSelected(row.id);
      return;
    }
    setBusyKey(row.key);
    setError('');
    try {
      const pref = prefsByKey[row.key] || { provider: row.provider || providerOptions[0] || 'pi', tier: row.tier || 'normal' };
      if (row.kind === 'identity') {
        const identity = row.identity || {};
        const result = await daemonApi.createAgent({
          daemonUrl,
          agentId: row.id,
          displayName: identityLabel(identity),
          providerProfile: pref.provider,
          templateId: identityTemplate(identity) || fallbackTemplate,
          projectId: defaultProjectId || String(identity?.default_project_id || identity?.defaultProjectId || ''),
          modelTier: pref.tier,
          agentRole: identityRole(identity) || roleHint || identityTemplate(identity) || row.id,
          start: false,
        });
        const createdId = String(result?.agent_instance_id || result?.agentInstanceId || result?.agent?.agent_instance_id || result?.agent?.agentInstanceId || '');
        await onSelected(createdId, result);
        return;
      }
      const instanceId = row.id;
      let result: any = undefined;
      if (!row.running) {
        const currentProvider = row.provider || providerOptions[0] || 'pi';
        const currentTier = row.tier || 'normal';
        if (pref.provider !== currentProvider || pref.tier !== currentTier) {
          result = await daemonApi.updateAgent({
            daemonUrl,
            agentInstanceId: instanceId,
            providerProfile: pref.provider,
            modelTier: pref.tier,
          });
        }
      }
      await onSelected(instanceId, result);
    } catch (err: any) {
      setError(err?.message || 'Unable to use selected agent');
    } finally {
      setBusyKey('');
    }
  }

  async function runAgent(agentInstanceIdValue: string, templateId: string, provider: string, projectId: string, modelTier: string) {
    const trimmed = agentInstanceIdValue.trim();
    if (!trimmed) return;
    setBusyKey(`run:${trimmed}`);
    setError('');
    try {
      const result = await daemonApi.startAgent({ daemonUrl, agentInstanceId: trimmed, provider, templateId, projectId, modelTier, agentRole: templateId });
      await refresh();
      await onSelected(trimmed, result);
    } catch (err: any) {
      setError(err?.message || 'Unable to run agent');
    } finally {
      setBusyKey('');
    }
  }

  async function createAndRun(agentIdValue: string, displayName: string, templateId: string, provider: string, projectId: string, modelTier: string) {
    const trimmed = agentIdValue.trim();
    if (!trimmed) return;
    setBusyKey(`create-run:${trimmed}`);
    setError('');
    try {
      await daemonApi.createAgent({ daemonUrl, agentInstanceId: trimmed, displayName: displayName.trim() || trimmed, providerProfile: provider, templateId, projectId, modelTier, agentRole: templateId });
      const result = await daemonApi.startAgent({ daemonUrl, agentInstanceId: trimmed, provider, templateId, projectId, displayName: displayName.trim() || trimmed, modelTier, agentRole: templateId });
      await refresh();
      await onSelected(trimmed, result);
    } catch (err: any) {
      setError(err?.message || 'Unable to create agent');
    } finally {
      setBusyKey('');
    }
  }

  async function selectRemoteAgent(peer: any, remoteAgent: any) {
    if (!clientToken || peerStatus(peer) !== 'linked' || busyKey) return;
    const remoteId = remoteAgentId(remoteAgent).trim();
    if (!remoteId) return;
    const peerId = String(peer?.peer_id || '').trim();
    if (!peerId) return;
    setBusyKey(`remote-${peerId}-${remoteId}`);
    setError('');
    try {
      const result = await daemonApi.bindRemoteProxy({
        daemonUrl,
        clientToken,
        peerId,
        originDaemonId: String(remoteAgent?.origin_daemon_id || remoteAgent?.originDaemonId || ''),
        remoteAgentInstanceId: remoteId,
        displayName: String(remoteAgent?.display_name || remoteAgent?.displayName || ''),
        templateId: String(remoteAgent?.template_id || remoteAgent?.templateId || ''),
        providerProfile: String(remoteAgent?.provider_profile || remoteAgent?.providerProfile || ''),
        modelTier: String(remoteAgent?.model_tier || remoteAgent?.modelTier || 'normal'),
        agentRole: String(remoteAgent?.agent_role || remoteAgent?.agentRole || ''),
      });
      const localProxyId = String(result?.agent?.agent_instance_id || result?.agent?.agentInstanceId || '');
      if (!localProxyId) throw new Error('Daemon did not return a local proxy id');
      await refresh();
      await onSelected(localProxyId, result);
    } catch (err: any) {
      setError(err?.message || 'Unable to select remote agent');
    } finally {
      setBusyKey('');
    }
  }

  const remoteProxyAgents = useMemo(() => (agents || []).filter((agent) => isRemoteProxyAgent(agent)), [agents]);
  const remoteProxyByKey = useMemo(() => {
    const map = new Map<string, any>();
    for (const agent of remoteProxyAgents) {
      const remote = agentRemote(agent);
      if (!remote?.peerId || !remote?.remoteAgentInstanceId) continue;
      map.set(`${remote.peerId}::${remote.originDaemonId || remote.peerId}::${remote.remoteAgentInstanceId}`, agent);
    }
    return map;
  }, [remoteProxyAgents]);

  const remoteSections = useMemo(() => {
    if (!remotePeersEnabled) return [];
    return (remotePeers || []).map((peer: any) => {
      const peerId = String(peer?.peer_id || '');
      const liveRows = (peer.remoteAgents || []).map((item: any) => ({ ...item, __rowKind: 'live' }));
      const proxyRows = remoteProxyAgents
        .filter((agent) => agentRemote(agent)?.peerId === peerId)
        .map((agent) => ({
          agent_instance_id: agentRemote(agent)?.remoteAgentInstanceId || '',
          origin_daemon_id: agentRemote(agent)?.originDaemonId || '',
          display_name: agentLabel(agent),
          template_id: agentTemplate(agent),
          agent_role: agent?.agentRole || agent?.agent_role || '',
          provider_profile: agent?.providerProfile || agent?.provider_profile || '',
          model_tier: agent?.modelTier || agent?.model_tier || 'normal',
          identity_state: agent?.state || 'provisioned',
          __rowKind: 'proxy',
        }))
        .filter((item: any) => !liveRows.some((live: any) => remoteAgentId(live) === remoteAgentId(item)));
      const rows = [...liveRows, ...proxyRows].filter((item: any) => remoteAgentId(item) && roleMatches(item, roleHint) && searchMatches(item, query));
      return { peer, rows };
    });
  }, [remotePeersEnabled, remotePeers, remoteProxyAgents, roleHint, query]);

  function renderRow(row: PickerRow) {
    const pref = prefsByKey[row.key] || { provider: row.provider || providerOptions[0] || 'pi', tier: row.tier || 'normal' };
    const selected = selectedId === row.id;
    const rowSlug = slug(row.key);
    const status = row.kind === 'identity' ? 'AGENT ID' : statusLabel(row.agent);
    const statusTone = row.kind === 'identity'
      ? 'bg-violet-400/15 text-violet-100'
      : status === 'LIVE'
        ? 'bg-emerald-400/15 text-emerald-100'
        : status === 'USER'
          ? 'bg-white/10 text-zinc-100'
          : 'bg-zinc-500/15 text-zinc-300';
    return (
      <button
        key={row.key}
        type="button"
        data-debug-id={`${debugId}-row-${rowSlug}`}
        disabled={Boolean(busyKey)}
        onClick={() => { void useRow(row); }}
        className={`w-full rounded-2xl border px-3 py-2.5 text-left transition ${selected ? 'border-sky-400/50 bg-sky-400/10' : row.kind === 'identity' ? 'border-dashed border-violet-400/20 bg-violet-400/[0.05] hover:bg-violet-400/[0.08]' : 'border-white/10 bg-black/20 hover:border-white/20 hover:bg-white/[0.05]'} ${busyKey === row.key ? 'opacity-70' : ''}`}
      >
        <div className="flex items-start justify-between gap-3">
          <div className="min-w-0 flex-1">
            <div className="truncate text-sm font-semibold text-zinc-100">{row.title}</div>
            <div className="mt-1 truncate font-mono text-[11px] text-zinc-500">{row.subtitle}</div>
            {row.conversationTitle ? <div className="mt-1 truncate text-[11px] text-sky-200">Conversation: <span className="text-zinc-300">{row.conversationTitle}</span></div> : null}
            <div className="mt-2 flex flex-wrap gap-1.5">
              {row.chips.map((chip) => <span key={chip} className="max-w-full truncate rounded-full bg-white/[0.05] px-2 py-0.5 text-[10px] text-zinc-400">{chip}</span>)}
            </div>
            {!row.running ? (
              <div className="mt-2.5 flex flex-wrap items-center gap-2">
                <span className="text-[10px] font-semibold uppercase tracking-wide text-zinc-500">Start with</span>
                <select
                  data-debug-id={`${debugId}-start-with-provider-${rowSlug}`}
                  value={pref.provider}
                  disabled={Boolean(busyKey)}
                  onClick={(event) => event.stopPropagation()}
                  onChange={(event) => setPrefsByKey((current) => ({ ...current, [row.key]: { ...pref, provider: event.target.value } }))}
                  className="h-7 max-w-[140px] rounded-lg border border-white/10 bg-black/30 px-2 text-[11px] text-zinc-100 outline-none focus:border-sky-400"
                >
                  {providerOptions.map((provider) => <option key={provider} value={provider}>{providerLabel(providerByName.get(provider) || provider)}</option>)}
                </select>
                <select
                  data-debug-id={`${debugId}-start-with-tier-${rowSlug}`}
                  value={pref.tier}
                  disabled={Boolean(busyKey)}
                  onClick={(event) => event.stopPropagation()}
                  onChange={(event) => setPrefsByKey((current) => ({ ...current, [row.key]: { ...pref, tier: event.target.value } }))}
                  className="h-7 max-w-[110px] rounded-lg border border-white/10 bg-black/30 px-2 text-[11px] text-zinc-100 outline-none focus:border-sky-400"
                >
                  {tierOptions.map((tier) => <option key={tier} value={tier}>{tier}</option>)}
                </select>
              </div>
            ) : null}
          </div>
          <span className={`shrink-0 rounded-full px-2 py-1 text-[10px] font-semibold ${statusTone}`}>{status}</span>
        </div>
      </button>
    );
  }

  const projectOptions = projects || [];
  const templateOptions = templates.length ? templates : [{ template_id: fallbackTemplate, display_name: fallbackTemplate }];

  return (
    <div data-debug-id={debugId} className="rounded-2xl border border-white/10 bg-black/20 p-3 text-sm">
      <div className="flex items-start justify-between gap-3">
        <div>
          <div className="font-medium text-zinc-100">Agent picker</div>
          {roleHint ? <div className="text-xs text-zinc-500">Filter: {roleHint}</div> : null}
        </div>
        {selectedLabel ? <div className="max-w-[240px] truncate rounded-full bg-white/5 px-2 py-1 text-xs text-zinc-400">Selected <b className="text-zinc-200">{selectedLabel}</b></div> : null}
      </div>

      <div data-debug-id={`${debugId}-tabs`} className="mt-3 grid grid-cols-2 gap-1 rounded-xl border border-white/10 bg-white/[0.03] p-1">
        <button type="button" data-debug-id={`${debugId}-tab-suggested`} onClick={() => setTab('suggested')} className={`rounded-lg px-3 py-2 text-left text-xs font-semibold ${tab === 'suggested' ? 'bg-sky-400/10 text-sky-100 shadow-[inset_0_0_0_1px_rgba(56,189,248,0.35)]' : 'text-zinc-500 hover:text-zinc-200'}`}>Suggested</button>
        <button type="button" data-debug-id={`${debugId}-tab-all-instances`} onClick={() => setTab('instances')} className={`rounded-lg px-3 py-2 text-left text-xs font-semibold ${tab === 'instances' ? 'bg-sky-400/10 text-sky-100 shadow-[inset_0_0_0_1px_rgba(56,189,248,0.35)]' : 'text-zinc-500 hover:text-zinc-200'}`}>All instances</button>
      </div>

      <input
        data-debug-id={`${debugId}-search-input`}
        value={query}
        onChange={(event) => setQuery(event.target.value)}
        placeholder="Search agents, identities, conversations…"
        className="mt-3 w-full rounded-xl border border-white/10 bg-black/30 px-3 py-2 text-sm outline-none focus:border-sky-400"
      />

      <div data-debug-id={`${debugId}-results`} className="mt-3 max-h-[420px] space-y-2 overflow-y-auto pr-1">
        {tab === 'suggested' ? (
          teamIds.size > 0 ? (
            <>
              {suggestedRows.teamRows.length > 0 ? <div className="px-1 text-[10px] font-semibold uppercase tracking-[0.18em] text-zinc-500">Team instances</div> : null}
              {suggestedRows.teamRows.map(renderRow)}
              {suggestedRows.liveOtherRows.length > 0 ? <div className="px-1 pt-1 text-[10px] font-semibold uppercase tracking-[0.18em] text-zinc-500">Live instances</div> : null}
              {suggestedRows.liveOtherRows.map(renderRow)}
              {suggestedRows.identityRows.length > 0 ? <div className="px-1 pt-1 text-[10px] font-semibold uppercase tracking-[0.18em] text-zinc-500">Durable agent IDs</div> : null}
              {suggestedRows.identityRows.map(renderRow)}
              {suggestedRows.offlineOtherRows.length > 0 ? <div className="px-1 pt-1 text-[10px] font-semibold uppercase tracking-[0.18em] text-zinc-500">Offline instances</div> : null}
              {suggestedRows.offlineOtherRows.map(renderRow)}
              {suggestedRows.teamRows.length === 0 && suggestedRows.liveOtherRows.length === 0 && suggestedRows.identityRows.length === 0 && suggestedRows.offlineOtherRows.length === 0 ? <div data-debug-id={`${debugId}-no-matching-agents`} className="rounded-xl border border-dashed border-white/10 p-4 text-sm text-zinc-500">No matching agents.</div> : null}
            </>
          ) : (
            <>
              {suggestedRows.identityRows.length > 0 ? <div className="px-1 text-[10px] font-semibold uppercase tracking-[0.18em] text-zinc-500">Durable agent IDs</div> : null}
              {suggestedRows.identityRows.map(renderRow)}
              {suggestedRows.liveOtherRows.length > 0 ? <div className="px-1 pt-1 text-[10px] font-semibold uppercase tracking-[0.18em] text-zinc-500">All instances</div> : null}
              {suggestedRows.liveOtherRows.map(renderRow)}
              {suggestedRows.identityRows.length === 0 && suggestedRows.liveOtherRows.length === 0 ? <div data-debug-id={`${debugId}-no-matching-agents`} className="rounded-xl border border-dashed border-white/10 p-4 text-sm text-zinc-500">No matching agents.</div> : null}
            </>
          )
        ) : (
          <>
            {allInstanceRows.map(renderRow)}
            {allInstanceRows.length === 0 ? <div data-debug-id={`${debugId}-no-matching-agents`} className="rounded-xl border border-dashed border-white/10 p-4 text-sm text-zinc-500">No matching agents.</div> : null}
          </>
        )}
      </div>

      {remotePeersEnabled && (
        <div className="mt-4 space-y-3">
          {remoteLoading && <div data-debug-id={`${debugId}-remote-loading`} className="rounded-xl border border-dashed border-white/10 p-3 text-xs text-zinc-500">Loading remote agents…</div>}
          {remoteError && <div data-debug-id={`${debugId}-remote-error`} className="rounded-xl border border-red-400/30 bg-red-500/10 px-3 py-2 text-xs text-red-100">{remoteError}</div>}
          {remoteSections.map(({ peer, rows }: any) => {
            const peerId = String(peer?.peer_id || 'peer');
            const offline = peerStatus(peer) !== 'linked';
            return (
              <div key={peerId} data-debug-id={`${debugId}-remote-section-${peerId}`}>
                <div className="mb-2 text-[10px] font-semibold uppercase tracking-[0.18em] text-zinc-500">Remote - {peerId}</div>
                <div className="grid gap-2 md:grid-cols-2">
                  {rows.length === 0 ? (
                    <div data-debug-id={`${debugId}-remote-empty-${peerId}`} className={`rounded-2xl border border-dashed p-4 text-sm ${offline ? 'border-red-400/20 bg-red-400/5 text-red-100/80 opacity-70' : 'border-white/10 text-zinc-500'}`}>
                      {offline ? 'Peer offline. Remote agents are unavailable right now.' : 'No matching remote agents.'}
                    </div>
                  ) : rows.map((remoteAgent: any) => {
                    const remoteId = remoteAgentId(remoteAgent);
                    const originDaemonId = String(remoteAgent?.origin_daemon_id || remoteAgent?.originDaemonId || peer?.daemon_id || peerId);
                    const key = `${peerId}::${originDaemonId}::${remoteId}`;
                    const localProxy = remoteProxyByKey.get(key);
                    const selected = Boolean(localProxy && agentId(localProxy) === selectedId);
                    return (
                      <div
                        key={key}
                        role="button"
                        tabIndex={offline ? -1 : 0}
                        data-debug-id={`${debugId}-remote-card-${peerId}-${slug(remoteId)}`}
                        aria-disabled={offline || Boolean(busyKey)}
                        onClick={() => { if (offline || busyKey) return; void selectRemoteAgent(peer, remoteAgent); }}
                        onKeyDown={(event) => {
                          if (event.key !== 'Enter' && event.key !== ' ') return;
                          event.preventDefault();
                          if (offline || busyKey) return;
                          void selectRemoteAgent(peer, remoteAgent);
                        }}
                        className={`min-w-0 rounded-2xl border border-dashed p-3 text-left transition ${offline ? 'cursor-not-allowed opacity-55 border-red-400/20 bg-red-400/[0.03]' : 'cursor-pointer border-teal-400/25 bg-teal-400/[0.05] hover:border-teal-300/40 hover:bg-teal-400/[0.08]'} ${selected ? 'border-solid border-teal-300/60 bg-teal-400/[0.12]' : ''}`}
                        title={`${remoteId} · ${originDaemonId} via ${peerId}`}
                      >
                        <div className="flex min-w-0 items-start justify-between gap-3">
                          <div className="min-w-0">
                            <div className="truncate text-sm font-semibold text-zinc-100">{remoteAgentLabel(remoteAgent)}</div>
                            <div className="mt-1 truncate font-mono text-[11px] text-zinc-500">{remoteId} · {originDaemonId} via {peerId}</div>
                          </div>
                          <span className={`shrink-0 rounded-full px-2 py-0.5 text-[10px] font-semibold ${offline ? 'bg-red-400/15 text-red-100' : 'bg-teal-400/15 text-teal-100'}`}>{offline ? 'OFFLINE' : 'REMOTE · LIVE'}</span>
                        </div>
                        <div className="mt-3 flex min-w-0 flex-wrap gap-1.5 text-[10px] text-zinc-400">
                          <span className="max-w-full truncate rounded-full bg-teal-400/10 px-2 py-0.5 text-teal-100">remote</span>
                          {(remoteAgent.agent_role || remoteAgent.agentRole) && <span className="max-w-full truncate rounded-full bg-white/[0.05] px-2 py-0.5">{remoteAgent.agent_role || remoteAgent.agentRole}</span>}
                          {offline && <span className="max-w-full truncate rounded-full bg-white/[0.05] px-2 py-0.5">peer offline</span>}
                        </div>
                      </div>
                    );
                  })}
                </div>
              </div>
            );
          })}
        </div>
      )}

      {!selectionOnly ? (
        <>
          <details className="mt-3 rounded-xl bg-white/[0.035] p-3">
            <summary data-debug-id={`${debugId}-run-by-id-summary`} className="cursor-pointer text-xs font-semibold uppercase tracking-wide text-zinc-400">Run agent by ID</summary>
            <div className="mt-3 grid gap-2 md:grid-cols-2">
              <input data-debug-id={`${debugId}-run-id-input`} value={runId} onChange={(event) => setRunId(event.target.value)} placeholder="agent-instance-id" className="rounded-xl border border-white/10 bg-black/30 px-3 py-2 text-sm outline-none focus:border-sky-400" />
              <select data-debug-id={`${debugId}-run-template-select`} value={runTemplate} onChange={(event) => setRunTemplate(event.target.value)} className="rounded-xl border border-white/10 bg-black/30 px-3 py-2 text-sm outline-none focus:border-sky-400">{templateOptions.map((t: any) => <option key={t.template_id || t.templateId} value={t.template_id || t.templateId}>{t.display_name || t.displayName || t.template_id || t.templateId}</option>)}</select>
              <select data-debug-id={`${debugId}-run-provider-select`} value={runProvider} onChange={(event) => setRunProvider(event.target.value)} className="rounded-xl border border-white/10 bg-black/30 px-3 py-2 text-sm outline-none focus:border-sky-400">{providerOptions.map((provider) => <option key={provider} value={provider}>{providerLabel(providerByName.get(provider) || provider)}</option>)}</select>
              <select data-debug-id={`${debugId}-run-project-select`} value={runProject} onChange={(event) => setRunProject(event.target.value)} className="rounded-xl border border-white/10 bg-black/30 px-3 py-2 text-sm outline-none focus:border-sky-400"><option value="">No project</option>{projectOptions.map((project: any) => <option key={project.projectId || project.project_id} value={project.projectId || project.project_id}>{project.name || project.projectId || project.project_id}</option>)}</select>
              <select data-debug-id={`${debugId}-run-tier-select`} value={runTier} onChange={(event) => setRunTier(event.target.value)} className="rounded-xl border border-white/10 bg-black/30 px-3 py-2 text-sm outline-none focus:border-sky-400">{tierOptions.map((tier) => <option key={tier} value={tier}>{tier}</option>)}</select>
              <button data-debug-id={`${debugId}-run-submit-btn`} disabled={!runId.trim() || Boolean(busyKey)} onClick={() => { void runAgent(runId, runTemplate, runProvider, runProject, runTier); }} className="inline-flex h-10 w-10 items-center justify-center rounded-xl bg-sky-400 text-xs font-semibold text-black hover:bg-sky-300 disabled:opacity-50">▶</button>
            </div>
          </details>

          <details className="mt-3 rounded-xl bg-white/[0.035] p-3">
            <summary data-debug-id={`${debugId}-create-summary`} className="cursor-pointer text-xs font-semibold uppercase tracking-wide text-zinc-400">Create new agent ID and run</summary>
            <div className="mt-3 grid gap-2 md:grid-cols-2">
              <input data-debug-id={`${debugId}-create-id-input`} value={createId} onChange={(event) => setCreateId(event.target.value)} placeholder="new-agent-id" className="rounded-xl border border-white/10 bg-black/30 px-3 py-2 text-sm outline-none focus:border-sky-400" />
              <input data-debug-id={`${debugId}-create-name-input`} value={createName} onChange={(event) => setCreateName(event.target.value)} placeholder="Display name (optional)" className="rounded-xl border border-white/10 bg-black/30 px-3 py-2 text-sm outline-none focus:border-sky-400" />
              <select data-debug-id={`${debugId}-create-template-select`} value={createTemplate} onChange={(event) => setCreateTemplate(event.target.value)} className="rounded-xl border border-white/10 bg-black/30 px-3 py-2 text-sm outline-none focus:border-sky-400">{templateOptions.map((t: any) => <option key={t.template_id || t.templateId} value={t.template_id || t.templateId}>{t.display_name || t.displayName || t.template_id || t.templateId}</option>)}</select>
              <select data-debug-id={`${debugId}-create-provider-select`} value={createProvider} onChange={(event) => setCreateProvider(event.target.value)} className="rounded-xl border border-white/10 bg-black/30 px-3 py-2 text-sm outline-none focus:border-sky-400">{providerOptions.map((provider) => <option key={provider} value={provider}>{providerLabel(providerByName.get(provider) || provider)}</option>)}</select>
              <select data-debug-id={`${debugId}-create-project-select`} value={createProject} onChange={(event) => setCreateProject(event.target.value)} className="rounded-xl border border-white/10 bg-black/30 px-3 py-2 text-sm outline-none focus:border-sky-400"><option value="">No project</option>{projectOptions.map((project: any) => <option key={project.projectId || project.project_id} value={project.projectId || project.project_id}>{project.name || project.projectId || project.project_id}</option>)}</select>
              <select data-debug-id={`${debugId}-create-tier-select`} value={createTier} onChange={(event) => setCreateTier(event.target.value)} className="rounded-xl border border-white/10 bg-black/30 px-3 py-2 text-sm outline-none focus:border-sky-400">{tierOptions.map((tier) => <option key={tier} value={tier}>{tier}</option>)}</select>
              <button data-debug-id={`${debugId}-create-submit-btn`} disabled={!createId.trim() || Boolean(busyKey)} onClick={() => { void createAndRun(createId, createName, createTemplate, createProvider, createProject, createTier); }} className="inline-flex h-10 w-10 items-center justify-center rounded-xl bg-emerald-400 text-xs font-semibold text-black hover:bg-emerald-300 disabled:opacity-50">＋</button>
            </div>
          </details>
        </>
      ) : null}

      {busyKey ? <div data-debug-id={`${debugId}-busy`} className="mt-2 text-xs text-sky-300">Working…</div> : null}
      {error ? <div data-debug-id={`${debugId}-error`} className="mt-2 rounded-lg border border-red-400/30 bg-red-500/10 px-3 py-2 text-xs text-red-100">{error}</div> : null}
    </div>
  );
}
