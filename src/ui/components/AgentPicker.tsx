import { useEffect, useMemo, useState } from 'react';
import * as daemonApi from '../api/daemonApi';

type AgentPickerProps = {
  debugId: string;
  daemonUrl: string;
  clientToken?: string;
  agents: any[];
  projects: any[];
  templates?: any[];
  providers?: any[];
  value?: string;
  roleHint?: string;
  defaultProjectId?: string;
  remotePeersEnabled?: boolean;
  onSelected: (agentInstanceId: string, result?: any) => void | Promise<void>;
  onRefreshAgents?: () => void | Promise<void>;
  selectionOnly?: boolean;
};

function slug(value: string): string {
  return String(value || '').toLowerCase().replace(/[^a-z0-9_-]+/g, '-');
}

function agentId(agent: any): string {
  return agent?.id || agent?.agentInstanceId || agent?.agent_instance_id || '';
}

function agentLabel(agent: any): string {
  return agent?.label || agent?.displayName || agent?.display_name || agentId(agent);
}

function agentTemplate(agent: any): string {
  return agent?.templateId || agent?.template_id || agent?.agentRole || agent?.agent_role || agent?.roleHint || agent?.role_hint || '';
}

function agentKind(agent: any): string {
  return String(agent?.agentKind || agent?.agent_kind || 'local');
}

function agentRemote(agent: any): { peerId: string; remoteAgentInstanceId: string } | null {
  const remote = agent?.remote;
  if (remote) {
    const peerId = String(remote.peerId || remote.peer_id || '');
    const remoteAgentInstanceId = String(remote.remoteAgentInstanceId || remote.remote_agent_instance_id || '');
    if (peerId || remoteAgentInstanceId) return { peerId, remoteAgentInstanceId };
  }
  const peerId = String(agent?.remote_peer_id || agent?.remotePeerId || '');
  const remoteAgentInstanceId = String(agent?.remote_agent_instance_id || agent?.remoteAgentInstanceId || '');
  if (peerId || remoteAgentInstanceId) return { peerId, remoteAgentInstanceId };
  return null;
}

function isRemoteProxyAgent(agent: any): boolean {
  return agentKind(agent) === 'remote_proxy' && Boolean(agentRemote(agent)?.peerId) && Boolean(agentRemote(agent)?.remoteAgentInstanceId);
}

function roleMatches(agent: any, roleHint: string) {
  if (!roleHint) return true;
  const hint = roleHint.toLowerCase();
  const remote = agentRemote(agent);
  const haystack = [agentId(agent), agentLabel(agent), agentTemplate(agent), agent?.agentRole || agent?.agent_role || '', agent?.providerProfile || agent?.provider_profile || '', remote?.remoteAgentInstanceId || ''].join(' ').toLowerCase();
  if (hint === 'coder') return haystack.includes('coder') || haystack.includes('code') || haystack.includes('implement');
  if (hint === 'reviewer') return haystack.includes('review') || haystack.includes('verify') || haystack.includes('test');
  if (hint === 'coordinator') return haystack.includes('coord') || haystack.includes('lead') || haystack.includes('principal');
  return haystack.includes(hint);
}

function templateDefault(templates: any[], roleHint: string) {
  if (!roleHint) return templates[0]?.template_id || templates[0]?.templateId || 'coder';
  const hint = roleHint.toLowerCase();
  const found = templates.find((template: any) => {
    const id = String(template.template_id || template.templateId || '').toLowerCase();
    const role = String(template.role_hint || template.roleHint || '').toLowerCase();
    const label = String(template.display_name || template.displayName || '').toLowerCase();
    return id.includes(hint) || role.includes(hint) || label.includes(hint);
  });
  if (found) return found.template_id || found.templateId;
  if (hint === 'coordinator') return 'coordinator';
  if (hint === 'reviewer') return 'reviewer';
  return 'coder';
}

function providerDefault(providers: any[]) {
  return providers[0]?.name || 'pi';
}

function statusLabel(agent: any) {
  const connection = String(agent?.connectionState || agent?.connection_state || '').toLowerCase();
  const live = Boolean(agent?.connected) || connection === 'connected';
  const status = live ? 'live' : 'offline';
  const task = agent?.currentTaskId ? ` · task ${agent.currentTaskId}` : '';
  return `${status}${task}`;
}

function searchMatches(agent: any, query: string) {
  const q = query.trim().toLowerCase();
  if (!q) return true;
  const remote = agentRemote(agent);
  const haystack = [
    agentId(agent),
    agentLabel(agent),
    agentTemplate(agent),
    agent?.agentRole || agent?.agent_role || '',
    agent?.providerProfile || agent?.provider_profile || '',
    agent?.projectId || agent?.project_id || '',
    statusLabel(agent),
    remote?.peerId || '',
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

export default function AgentPicker({ debugId, daemonUrl, clientToken = '', agents, projects, templates = [], providers = [], value = '', roleHint = '', defaultProjectId = '', remotePeersEnabled = false, onSelected, onRefreshAgents, selectionOnly = false }: AgentPickerProps) {
  const [query, setQuery] = useState('');
  const fallbackTemplate = templateDefault(templates, roleHint);
  const fallbackProvider = providerDefault(providers);
  const [existingId, setExistingId] = useState(value || '');
  const selectedId = existingId || value || '';
  const [runId, setRunId] = useState('');
  const [runTemplate, setRunTemplate] = useState(fallbackTemplate);
  const [runProvider, setRunProvider] = useState(fallbackProvider);
  const [runProject, setRunProject] = useState(defaultProjectId || '');
  const [runTier, setRunTier] = useState('normal');
  const [createId, setCreateId] = useState('');
  const [createName, setCreateName] = useState('');
  const [createTemplate, setCreateTemplate] = useState(fallbackTemplate);
  const [createProvider, setCreateProvider] = useState(fallbackProvider);
  const [createProject, setCreateProject] = useState(defaultProjectId || '');
  const [createTier, setCreateTier] = useState('normal');
  const [busy, setBusy] = useState('');
  const [error, setError] = useState('');
  const [remotePeers, setRemotePeers] = useState<any[]>([]);
  const [remoteLoading, setRemoteLoading] = useState(false);
  const [remoteError, setRemoteError] = useState('');

  useEffect(() => {
    setExistingId(value || '');
  }, [value]);

  useEffect(() => {
    setRunTemplate(fallbackTemplate);
    setCreateTemplate(fallbackTemplate);
  }, [fallbackTemplate]);

  useEffect(() => {
    setRunProvider(fallbackProvider);
    setCreateProvider(fallbackProvider);
  }, [fallbackProvider]);

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

  async function runAgent(agentInstanceId: string, templateId: string, provider: string, projectId: string, modelTier: string) {
    const trimmed = agentInstanceId.trim();
    if (!trimmed) return;
    setBusy(`run-${trimmed}`);
    setError('');
    try {
      const result = await daemonApi.startAgent({ daemonUrl, agentInstanceId: trimmed, provider, templateId, projectId, modelTier, agentRole: templateId });
      await refresh();
      await onSelected(trimmed, result);
    } catch (err: any) {
      setError(err?.message || 'Unable to run agent');
    } finally {
      setBusy('');
    }
  }

  async function createAndRun() {
    const trimmed = createId.trim();
    if (!trimmed) return;
    setBusy(`create-${trimmed}`);
    setError('');
    try {
      await daemonApi.createAgent({ daemonUrl, agentInstanceId: trimmed, displayName: createName.trim() || trimmed, providerProfile: createProvider, templateId: createTemplate, projectId: createProject, modelTier: createTier, agentRole: createTemplate });
      const result = await daemonApi.startAgent({ daemonUrl, agentInstanceId: trimmed, provider: createProvider, templateId: createTemplate, projectId: createProject, displayName: createName.trim() || trimmed, modelTier: createTier, agentRole: createTemplate });
      await refresh();
      await onSelected(trimmed, result);
    } catch (err: any) {
      setError(err?.message || 'Unable to create agent');
    } finally {
      setBusy('');
    }
  }

  async function selectRemoteAgent(peer: any, remoteAgent: any) {
    if (!clientToken || peerStatus(peer) !== 'linked' || busy) return;
    const remoteId = remoteAgentId(remoteAgent).trim();
    if (!remoteId) return;
    const peerId = String(peer?.peer_id || '').trim();
    if (!peerId) return;
    setBusy(`remote-${peerId}-${remoteId}`);
    setError('');
    try {
      const result = await daemonApi.bindRemoteProxy({
        daemonUrl,
        clientToken,
        peerId,
        remoteAgentInstanceId: remoteId,
        displayName: String(remoteAgent?.display_name || remoteAgent?.displayName || ''),
        templateId: String(remoteAgent?.template_id || remoteAgent?.templateId || ''),
        providerProfile: String(remoteAgent?.provider_profile || remoteAgent?.providerProfile || ''),
        modelTier: String(remoteAgent?.model_tier || remoteAgent?.modelTier || 'normal'),
        agentRole: String(remoteAgent?.agent_role || remoteAgent?.agentRole || ''),
      });
      const localProxyId = String(result?.agent?.agent_instance_id || result?.agent?.agentInstanceId || '');
      if (!localProxyId) throw new Error('Daemon did not return a local proxy id');
      setExistingId(localProxyId);
      await refresh();
      await onSelected(localProxyId, result);
    } catch (err: any) {
      setError(err?.message || 'Unable to select remote agent');
    } finally {
      setBusy('');
    }
  }

  const localAgents = useMemo(() => (agents || []).filter((agent) => agentId(agent) && !isRemoteProxyAgent(agent) && roleMatches(agent, roleHint) && searchMatches(agent, query)), [agents, roleHint, query]);
  const remoteProxyAgents = useMemo(() => (agents || []).filter((agent) => isRemoteProxyAgent(agent)), [agents]);
  const remoteProxyByKey = useMemo(() => {
    const map = new Map<string, any>();
    for (const agent of remoteProxyAgents) {
      const remote = agentRemote(agent);
      if (!remote?.peerId || !remote?.remoteAgentInstanceId) continue;
      map.set(`${remote.peerId}::${remote.remoteAgentInstanceId}`, agent);
    }
    return map;
  }, [remoteProxyAgents]);
  const selectedRemoteLabel = useMemo(() => {
    const selectedAgent = (agents || []).find((agent) => agentId(agent) === selectedId);
    const remote = selectedAgent ? agentRemote(selectedAgent) : null;
    if (selectedAgent && isRemoteProxyAgent(selectedAgent) && remote) return `${remote.remoteAgentInstanceId} · ${remote.peerId}`;
    return selectedId;
  }, [agents, selectedId]);
  const remoteSections = useMemo(() => {
    if (!remotePeersEnabled) return [];
    return (remotePeers || []).map((peer: any) => {
      const peerId = String(peer?.peer_id || '');
      const liveRows = (peer.remoteAgents || []).map((item: any) => ({ ...item, __rowKind: 'live' }));
      const proxyRows = remoteProxyAgents
        .filter((agent) => agentRemote(agent)?.peerId === peerId)
        .map((agent) => ({
          agent_instance_id: agentRemote(agent)?.remoteAgentInstanceId || '',
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

  const projectOptions = projects || [];
  const templateOptions = templates.length ? templates : [{ template_id: fallbackTemplate, display_name: fallbackTemplate }];
  const providerOptions = providers.length ? providers : [{ name: fallbackProvider }];

  return (
    <div data-debug-id={debugId} className="rounded-xl border border-white/10 bg-black/20 p-3 text-sm">
      <div className="flex items-center justify-between gap-3">
        <div>
          <div className="font-medium text-zinc-100">Agent picker</div>
          {roleHint && <div className="text-xs text-zinc-500">Filter: {roleHint}</div>}
        </div>
        {selectedId && <div className="max-w-[220px] truncate rounded-full bg-white/5 px-2 py-1 text-xs text-zinc-400">Selected {selectedRemoteLabel}</div>}
      </div>

      <input
        data-debug-id={`${debugId}-search-input`}
        value={query}
        onChange={(event) => setQuery(event.target.value)}
        placeholder="Search agents by name, id, role, project, live/offline…"
        className="mt-3 w-full rounded-xl border border-white/10 bg-black/30 px-3 py-2 text-sm outline-none focus:border-sky-400"
      />

      {remotePeersEnabled && <div className="mt-3 text-[10px] font-semibold uppercase tracking-[0.18em] text-zinc-500">Local agents</div>}
      <div data-debug-id={`${debugId}-agent-grid`} className="mt-3 grid max-h-[360px] min-w-0 gap-2 overflow-y-auto pr-1 md:grid-cols-2">
        {localAgents.length === 0 && <div data-debug-id={`${debugId}-no-matching-agents`} className="rounded-xl border border-dashed border-white/10 p-4 text-sm text-zinc-500 md:col-span-2">No matching agents.</div>}
        {localAgents.map((agent: any) => {
          const id = agentId(agent);
          const live = statusLabel(agent).startsWith('live');
          const selected = selectedId === id;
          const template = agentTemplate(agent);
          const provider = agent.providerProfile || agent.provider_profile || '';
          const project = agent.projectId || agent.project_id || '';
          return (
            <div
              key={id}
              role="button"
              tabIndex={0}
              data-debug-id={`${debugId}-agent-card-${id}`}
              aria-disabled={Boolean(busy)}
              onClick={async () => { if (busy) return; setExistingId(id); await onSelected(id); }}
              onKeyDown={async (event) => {
                if (event.key !== 'Enter' && event.key !== ' ') return;
                event.preventDefault();
                if (busy) return;
                setExistingId(id);
                await onSelected(id);
              }}
              className={`min-w-0 cursor-pointer rounded-2xl border p-3 text-left transition ${busy ? 'opacity-60' : ''} ${selected ? 'border-sky-400/60 bg-sky-400/10' : 'border-white/10 bg-black/20 hover:border-white/20 hover:bg-white/[0.05]'}`}
              title={`${agentLabel(agent)} · ${id}`}
            >
              <div className="flex min-w-0 items-start justify-between gap-3">
                <div className="min-w-0">
                  <div className="truncate text-sm font-semibold text-zinc-100">{agentLabel(agent)}</div>
                  <div className="mt-1 truncate font-mono text-[11px] text-zinc-500">{id}</div>
                </div>
                <span className={`shrink-0 rounded-full px-2 py-0.5 text-[10px] font-semibold ${live ? 'bg-emerald-400/15 text-emerald-200' : 'bg-zinc-500/15 text-zinc-300'}`}>{live ? 'LIVE' : 'OFFLINE'}</span>
              </div>
              <div className="mt-3 flex min-w-0 flex-wrap gap-1.5 text-[10px] text-zinc-400">
                {template && <span className="max-w-full truncate rounded-full bg-white/[0.05] px-2 py-0.5">{template}</span>}
                {provider && <span className="max-w-full truncate rounded-full bg-white/[0.05] px-2 py-0.5">{provider}</span>}
                {project && <span className="max-w-full truncate rounded-full bg-white/[0.05] px-2 py-0.5">home {project}</span>}
                <span className="max-w-full truncate rounded-full bg-white/[0.05] px-2 py-0.5">{statusLabel(agent)}</span>
              </div>
              {!selectionOnly && <div className="mt-3 flex justify-end">
                <button
                  data-debug-id={`${debugId}-agent-run-${id}`}
                  aria-label={`Run ${agentLabel(agent)}`}
                  title="Run agent"
                  disabled={Boolean(busy)}
                  onClick={(event) => {
                    event.stopPropagation();
                    setExistingId(id);
                    runAgent(id, template || fallbackTemplate, provider || fallbackProvider, project || defaultProjectId || '', agent.modelTier || agent.model_tier || 'normal');
                  }}
                  className="inline-flex h-8 w-8 items-center justify-center rounded-lg bg-sky-400 text-xs font-semibold text-black hover:bg-sky-300 disabled:opacity-60"
                >▶</button>
              </div>}
            </div>
          );
        })}
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
                    const key = `${peerId}::${remoteId}`;
                    const localProxy = remoteProxyByKey.get(key);
                    const selected = Boolean(localProxy && agentId(localProxy) === selectedId);
                    return (
                      <div
                        key={key}
                        role="button"
                        tabIndex={offline ? -1 : 0}
                        data-debug-id={`${debugId}-remote-card-${peerId}-${slug(remoteId)}`}
                        aria-disabled={offline || Boolean(busy)}
                        onClick={() => { if (offline || busy) return; void selectRemoteAgent(peer, remoteAgent); }}
                        onKeyDown={(event) => {
                          if (event.key !== 'Enter' && event.key !== ' ') return;
                          event.preventDefault();
                          if (offline || busy) return;
                          void selectRemoteAgent(peer, remoteAgent);
                        }}
                        className={`min-w-0 rounded-2xl border border-dashed p-3 text-left transition ${offline ? 'cursor-not-allowed opacity-55 border-red-400/20 bg-red-400/[0.03]' : 'cursor-pointer border-teal-400/25 bg-teal-400/[0.05] hover:border-teal-300/40 hover:bg-teal-400/[0.08]'} ${selected ? 'border-solid border-teal-300/60 bg-teal-400/[0.12]' : ''}`}
                        title={`${remoteId} · ${peerId}`}
                      >
                        <div className="flex min-w-0 items-start justify-between gap-3">
                          <div className="min-w-0">
                            <div className="truncate text-sm font-semibold text-zinc-100">{remoteAgentLabel(remoteAgent)}</div>
                            <div className="mt-1 truncate font-mono text-[11px] text-zinc-500">{remoteId} · {peerId}</div>
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

      {!selectionOnly && <details className="mt-3 rounded-xl bg-white/[0.035] p-3">
        <summary data-debug-id={`${debugId}-run-by-id-summary`} className="cursor-pointer text-xs font-semibold uppercase tracking-wide text-zinc-400">Run agent by ID</summary>
        <div className="mt-3 grid gap-2 md:grid-cols-2">
          <input data-debug-id={`${debugId}-run-id-input`} value={runId} onChange={(event) => setRunId(event.target.value)} placeholder="agent-instance-id" className="rounded-xl border border-white/10 bg-black/30 px-3 py-2 text-sm outline-none focus:border-sky-400" />
          <select data-debug-id={`${debugId}-run-template-select`} value={runTemplate} onChange={(event) => setRunTemplate(event.target.value)} className="rounded-xl border border-white/10 bg-black/30 px-3 py-2 text-sm outline-none focus:border-sky-400">{templateOptions.map((t: any) => <option key={t.template_id || t.templateId} value={t.template_id || t.templateId}>{t.display_name || t.displayName || t.template_id || t.templateId}</option>)}</select>
          <select data-debug-id={`${debugId}-run-provider-select`} value={runProvider} onChange={(event) => setRunProvider(event.target.value)} className="rounded-xl border border-white/10 bg-black/30 px-3 py-2 text-sm outline-none focus:border-sky-400">{providerOptions.map((p: any) => <option key={p.name} value={p.name}>{p.name}</option>)}</select>
          <select data-debug-id={`${debugId}-run-project-select`} value={runProject} onChange={(event) => setRunProject(event.target.value)} className="rounded-xl border border-white/10 bg-black/30 px-3 py-2 text-sm outline-none focus:border-sky-400"><option value="">No project</option>{projectOptions.map((p: any) => <option key={p.projectId || p.project_id} value={p.projectId || p.project_id}>{p.name || p.projectId || p.project_id}</option>)}</select>
          <select data-debug-id={`${debugId}-run-tier-select`} value={runTier} onChange={(event) => setRunTier(event.target.value)} className="rounded-xl border border-white/10 bg-black/30 px-3 py-2 text-sm outline-none focus:border-sky-400"><option value="normal">normal</option><option value="smart">smart</option><option value="cheap">cheap</option></select>
          <button data-debug-id={`${debugId}-run-submit-btn`} aria-label="Run agent" title="Run agent" disabled={!runId.trim() || Boolean(busy)} onClick={() => runAgent(runId, runTemplate, runProvider, runProject, runTier)} className="inline-flex h-10 w-10 items-center justify-center rounded-xl bg-sky-400 text-xs font-semibold text-black hover:bg-sky-300 disabled:opacity-50">▶</button>
        </div>
      </details>}

      {!selectionOnly && <details className="mt-3 rounded-xl bg-white/[0.035] p-3">
        <summary data-debug-id={`${debugId}-create-summary`} className="cursor-pointer text-xs font-semibold uppercase tracking-wide text-zinc-400">Create new agent ID and run</summary>
        <div className="mt-3 grid gap-2 md:grid-cols-2">
          <input data-debug-id={`${debugId}-create-id-input`} value={createId} onChange={(event) => setCreateId(event.target.value)} placeholder="new-agent-id" className="rounded-xl border border-white/10 bg-black/30 px-3 py-2 text-sm outline-none focus:border-sky-400" />
          <input data-debug-id={`${debugId}-create-name-input`} value={createName} onChange={(event) => setCreateName(event.target.value)} placeholder="Display name (optional)" className="rounded-xl border border-white/10 bg-black/30 px-3 py-2 text-sm outline-none focus:border-sky-400" />
          <select data-debug-id={`${debugId}-create-template-select`} value={createTemplate} onChange={(event) => setCreateTemplate(event.target.value)} className="rounded-xl border border-white/10 bg-black/30 px-3 py-2 text-sm outline-none focus:border-sky-400">{templateOptions.map((t: any) => <option key={t.template_id || t.templateId} value={t.template_id || t.templateId}>{t.display_name || t.displayName || t.template_id || t.templateId}</option>)}</select>
          <select data-debug-id={`${debugId}-create-provider-select`} value={createProvider} onChange={(event) => setCreateProvider(event.target.value)} className="rounded-xl border border-white/10 bg-black/30 px-3 py-2 text-sm outline-none focus:border-sky-400">{providerOptions.map((p: any) => <option key={p.name} value={p.name}>{p.name}</option>)}</select>
          <select data-debug-id={`${debugId}-create-project-select`} value={createProject} onChange={(event) => setCreateProject(event.target.value)} className="rounded-xl border border-white/10 bg-black/30 px-3 py-2 text-sm outline-none focus:border-sky-400"><option value="">No project</option>{projectOptions.map((p: any) => <option key={p.projectId || p.project_id} value={p.projectId || p.project_id}>{p.name || p.projectId || p.project_id}</option>)}</select>
          <select data-debug-id={`${debugId}-create-tier-select`} value={createTier} onChange={(event) => setCreateTier(event.target.value)} className="rounded-xl border border-white/10 bg-black/30 px-3 py-2 text-sm outline-none focus:border-sky-400"><option value="normal">normal</option><option value="smart">smart</option><option value="cheap">cheap</option></select>
          <button data-debug-id={`${debugId}-create-submit-btn`} aria-label="Create and run" title="Create and run" disabled={!createId.trim() || Boolean(busy)} onClick={createAndRun} className="inline-flex h-10 w-10 items-center justify-center rounded-xl bg-emerald-400 text-xs font-semibold text-black hover:bg-emerald-300 disabled:opacity-50">＋</button>
        </div>
      </details>}

      {busy && <div data-debug-id={`${debugId}-busy`} className="mt-2 text-xs text-sky-300">Working…</div>}
      {error && <div data-debug-id={`${debugId}-error`} className="mt-2 rounded-lg border border-red-400/30 bg-red-500/10 px-3 py-2 text-xs text-red-100">{error}</div>}
    </div>
  );
}
