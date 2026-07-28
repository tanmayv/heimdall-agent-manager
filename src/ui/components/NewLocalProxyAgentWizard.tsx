import { useEffect, useMemo, useState } from 'react';
import * as daemonApi from '../api/daemonApi';

// NewLocalProxyAgentWizard
//
// Guides the user through creating a durable LOCAL proxy agent-id that attaches
// to an agent-id on a linked remote daemon. Two source modes:
//   - existing: attach to an agent-id already advertised by the remote peer
//   - create:   create a brand-new agent-id on the remote, then attach
//
// The wizard only creates the durable proxy identity (no instance launch):
// it calls bindRemoteProxy({ start_instance: false }). The resulting local
// proxy agent-id is dormant and can be launched later like any other agent-id.

type Mode = 'existing' | 'create';

export type NewLocalProxyAgentWizardProps = {
  debugId?: string;
  daemonUrl: string;
  clientToken: string;
  templates?: any[];
  providers?: any[];
  onClose: () => void;
  onCreated?: (localAgentId: string) => void | Promise<void>;
};

const TIERS = ['cheap', 'normal', 'smart'];

function safeIdPart(value: string): string {
  return String(value || '').toLowerCase().replace(/[^a-z0-9_-]+/g, '-').replace(/^-+|-+$/g, '');
}

function peerId(peer: any): string {
  return String(peer?.peer_id || peer?.peerId || '');
}
function peerDaemonId(peer: any): string {
  return String(peer?.daemon_id || peer?.daemonId || peerId(peer));
}
function peerLinked(peer: any): boolean {
  return String(peer?.status || '').toLowerCase() === 'linked';
}
function providerName(p: any): string {
  return String(p?.name || p?.id || p?.provider_profile || p || '');
}
function remoteAgentId(a: any): string {
  return String(a?.agent_id || a?.agentId || (a?.agent_instance_id ? String(a.agent_instance_id).split('@')[0] : '') || '');
}
function remoteAgentLabel(a: any): string {
  return String(a?.display_name || a?.displayName || remoteAgentId(a));
}

export default function NewLocalProxyAgentWizard({
  debugId = 'new-local-proxy-wizard',
  daemonUrl,
  clientToken,
  templates = [],
  providers = [],
  onClose,
  onCreated,
}: NewLocalProxyAgentWizardProps) {
  const [step, setStep] = useState(1);
  const [mode, setMode] = useState<Mode>('existing');

  // peers
  const [peers, setPeers] = useState<any[]>([]);
  const [peersLoading, setPeersLoading] = useState(false);
  const [peersError, setPeersError] = useState('');
  const [selectedPeerId, setSelectedPeerId] = useState('');

  // advertised remote agent-ids for the chosen peer
  const [remoteAgents, setRemoteAgents] = useState<any[]>([]);
  const [remoteDaemonId, setRemoteDaemonId] = useState('');
  const [remoteLoading, setRemoteLoading] = useState(false);
  const [remoteError, setRemoteError] = useState('');
  const [remoteSearch, setRemoteSearch] = useState('');
  const [selectedRemoteAgentId, setSelectedRemoteAgentId] = useState('');

  // create-new-remote fields
  const [newRemoteAgentId, setNewRemoteAgentId] = useState('');
  const [newRemoteDisplayName, setNewRemoteDisplayName] = useState('');

  // shared config
  const fallbackTemplate = String(templates[0]?.template_id || templates[0]?.templateId || 'agent');
  const providerOptions = useMemo(() => {
    const vals = providers.map(providerName).filter(Boolean);
    return vals.length ? vals : ['pi'];
  }, [providers]);
  const [templateId, setTemplateId] = useState(fallbackTemplate);
  const [providerProfile, setProviderProfile] = useState(providerOptions[0] || 'pi');
  const [modelTier, setModelTier] = useState('normal');

  // local proxy identity fields
  const [localAgentId, setLocalAgentId] = useState('');
  const [localAgentIdTouched, setLocalAgentIdTouched] = useState(false);
  const [displayName, setDisplayName] = useState('');

  const [submitting, setSubmitting] = useState(false);
  const [submitError, setSubmitError] = useState('');

  useEffect(() => { setTemplateId(fallbackTemplate); }, [fallbackTemplate]);
  useEffect(() => { setProviderProfile(providerOptions[0] || 'pi'); }, [providerOptions]);

  // Load linked peers on mount.
  useEffect(() => {
    let cancelled = false;
    async function load() {
      if (!daemonUrl || !clientToken) { setPeersError('Missing daemon session'); return; }
      setPeersLoading(true);
      setPeersError('');
      try {
        const list = await daemonApi.listFederationPeers({ daemonUrl, clientToken });
        if (!cancelled) setPeers(list || []);
      } catch (err: any) {
        if (!cancelled) setPeersError(err?.message || 'Unable to load peers');
      } finally {
        if (!cancelled) setPeersLoading(false);
      }
    }
    load();
    return () => { cancelled = true; };
  }, [daemonUrl, clientToken]);

  const selectedPeer = useMemo(() => peers.find((p) => peerId(p) === selectedPeerId) || null, [peers, selectedPeerId]);

  // Load advertised remote agents when peer chosen (existing mode).
  useEffect(() => {
    let cancelled = false;
    async function load() {
      if (!selectedPeerId || !peerLinked(selectedPeer)) { setRemoteAgents([]); setRemoteDaemonId(peerDaemonId(selectedPeer)); return; }
      setRemoteLoading(true);
      setRemoteError('');
      try {
        const data = await daemonApi.listPeerAdvertisedAgents({ daemonUrl, clientToken, peerId: selectedPeerId });
        if (!cancelled) { setRemoteAgents(data.agents || []); setRemoteDaemonId(data.daemonId || peerDaemonId(selectedPeer)); }
      } catch (err: any) {
        if (!cancelled) { setRemoteAgents([]); setRemoteError(err?.message || 'Unable to load remote agents'); }
      } finally {
        if (!cancelled) setRemoteLoading(false);
      }
    }
    load();
    return () => { cancelled = true; };
  }, [selectedPeerId, selectedPeer, daemonUrl, clientToken]);

  // The effective remote agent-id being attached to.
  const effectiveRemoteAgentId = mode === 'existing' ? selectedRemoteAgentId : safeIdPart(newRemoteAgentId);

  // Auto-suggest local agent-id from remote id + peer, unless user edited it.
  useEffect(() => {
    if (localAgentIdTouched) return;
    if (!effectiveRemoteAgentId || !selectedPeerId) { setLocalAgentId(''); return; }
    setLocalAgentId(safeIdPart(`${effectiveRemoteAgentId}-${selectedPeerId}`));
  }, [effectiveRemoteAgentId, selectedPeerId, localAgentIdTouched]);

  const filteredRemoteAgents = useMemo(() => {
    const q = remoteSearch.trim().toLowerCase();
    const rows = (remoteAgents || []).filter((a) => remoteAgentId(a));
    if (!q) return rows;
    return rows.filter((a) => `${remoteAgentId(a)} ${remoteAgentLabel(a)}`.toLowerCase().includes(q));
  }, [remoteAgents, remoteSearch]);

  const linkedPeers = useMemo(() => peers.filter(peerLinked), [peers]);

  function resetForNewPeer() {
    setSelectedRemoteAgentId('');
    setNewRemoteAgentId('');
    setLocalAgentIdTouched(false);
  }

  const canProceedStep1 = Boolean(selectedPeerId) && peerLinked(selectedPeer);
  const canProceedStep2 = mode === 'existing' ? Boolean(selectedRemoteAgentId) : Boolean(safeIdPart(newRemoteAgentId));
  const localAgentIdValid = Boolean(localAgentId) && safeIdPart(localAgentId) === localAgentId;
  const canSubmit = canProceedStep1 && canProceedStep2 && localAgentIdValid && !submitting;

  async function handleSubmit() {
    if (!canSubmit) return;
    setSubmitting(true);
    setSubmitError('');
    try {
      const result = await daemonApi.bindRemoteProxy({
        daemonUrl,
        clientToken,
        peerId: selectedPeerId,
        originDaemonId: remoteDaemonId || peerDaemonId(selectedPeer),
        remoteAgentInstanceId: '',            // agent-id only, no concrete instance
        remoteAgentId: effectiveRemoteAgentId,
        localAgentId,
        displayName: displayName.trim() || localAgentId,
        templateId: templateId || fallbackTemplate,
        providerProfile,
        modelTier,
        createRemoteAgentId: mode === 'create',
        startInstance: false,                 // create durable proxy agent-id only
      });
      const createdId = String(result?.identity?.agent_id || result?.identity?.agentId || localAgentId);
      await onCreated?.(createdId);
      onClose();
    } catch (err: any) {
      setSubmitError(err?.message || 'Unable to create local proxy agent-id');
    } finally {
      setSubmitting(false);
    }
  }

  const templateOptions = templates.length ? templates : [{ template_id: fallbackTemplate, display_name: fallbackTemplate }];

  const stepLabels = ['Peer', 'Remote agent-id', 'Local proxy'];

  return (
    <div className="fixed inset-0 z-50 flex items-start justify-center bg-black/60 px-4 py-16 backdrop-blur-sm" onMouseDown={onClose}>
      <div data-debug-id={debugId} className="w-full max-w-2xl rounded-3xl border border-white/10 bg-[#101217] p-5 shadow-2xl shadow-black/50" onMouseDown={(e) => e.stopPropagation()}>
        {/* Header */}
        <div className="mb-4 flex items-start justify-between gap-4">
          <div className="min-w-0">
            <h2 className="text-lg font-semibold text-zinc-100">New local proxy agent-id</h2>
            <p className="mt-1 text-sm text-zinc-500">Attach a local proxy identity to an agent-id on a linked remote daemon.</p>
          </div>
          <button type="button" data-debug-id={`${debugId}-close-btn`} onClick={onClose} className="flex h-8 w-8 items-center justify-center rounded-xl border border-white/10 bg-white/[0.03] text-zinc-400 transition hover:border-white/20 hover:text-zinc-100" aria-label="Close">×</button>
        </div>

        {/* Stepper */}
        <div data-debug-id={`${debugId}-stepper`} className="mb-5 flex items-center gap-2">
          {stepLabels.map((label, i) => {
            const n = i + 1;
            const active = step === n;
            const done = step > n;
            return (
              <div key={label} className="flex flex-1 items-center gap-2">
                <div className={`flex h-6 w-6 flex-none items-center justify-center rounded-full text-[11px] font-semibold ${active ? 'bg-sky-400 text-black' : done ? 'bg-emerald-400/20 text-emerald-200' : 'bg-white/5 text-zinc-500'}`}>{done ? '✓' : n}</div>
                <span className={`truncate text-xs ${active ? 'text-zinc-100' : 'text-zinc-500'}`}>{label}</span>
                {i < stepLabels.length - 1 ? <div className={`h-px flex-1 ${done ? 'bg-emerald-400/30' : 'bg-white/10'}`} /> : null}
              </div>
            );
          })}
        </div>

        {/* Step 1 — pick peer */}
        {step === 1 ? (
          <div data-debug-id={`${debugId}-step-peer`} className="space-y-3">
            <label className="block text-[11px] uppercase tracking-wide text-zinc-500">Linked remote daemon (peer)</label>
            {peersLoading ? (
              <div data-debug-id={`${debugId}-peers-loading`} className="rounded-xl border border-dashed border-white/10 p-4 text-sm text-zinc-500">Loading peers…</div>
            ) : peersError ? (
              <div data-debug-id={`${debugId}-peers-error`} className="rounded-xl border border-red-400/30 bg-red-500/10 px-3 py-2 text-sm text-red-100">{peersError}</div>
            ) : linkedPeers.length === 0 ? (
              <div data-debug-id={`${debugId}-peers-empty`} className="rounded-xl border border-dashed border-white/10 p-4 text-sm text-zinc-500">No linked peers. Link a peer daemon in Settings first.</div>
            ) : (
              <div className="space-y-2">
                {linkedPeers.map((peer) => {
                  const id = peerId(peer);
                  const selected = selectedPeerId === id;
                  return (
                    <button
                      key={id}
                      type="button"
                      data-debug-id={`${debugId}-peer-row-${id}`}
                      onClick={() => { setSelectedPeerId(id); resetForNewPeer(); }}
                      className={`flex w-full items-center justify-between gap-3 rounded-2xl border px-4 py-3 text-left transition ${selected ? 'border-sky-400/55 bg-sky-400/10' : 'border-white/10 bg-black/20 hover:border-white/20 hover:bg-white/[0.04]'}`}
                    >
                      <div className="min-w-0">
                        <div className="truncate text-sm font-semibold text-zinc-100">{peerDaemonId(peer)}</div>
                        <div className="mt-0.5 truncate font-mono text-[11px] text-zinc-500">{id}</div>
                      </div>
                      <span className="flex-none rounded-full bg-emerald-400/15 px-2 py-0.5 text-[10px] font-semibold text-emerald-200">LINKED</span>
                    </button>
                  );
                })}
              </div>
            )}
          </div>
        ) : null}

        {/* Step 2 — choose existing vs create remote agent-id */}
        {step === 2 ? (
          <div data-debug-id={`${debugId}-step-remote`} className="space-y-4">
            <div className="grid grid-cols-2 gap-2">
              <button type="button" data-debug-id={`${debugId}-mode-existing-btn`} onClick={() => setMode('existing')} className={`rounded-xl border px-3 py-2 text-left text-sm transition ${mode === 'existing' ? 'border-sky-400/55 bg-sky-400/10 text-sky-50' : 'border-white/10 bg-black/20 text-zinc-300 hover:border-white/20'}`}>
                <div className="font-semibold">Existing remote agent-id</div>
                <div className="mt-0.5 text-[11px] text-zinc-500">Attach to one advertised by the peer</div>
              </button>
              <button type="button" data-debug-id={`${debugId}-mode-create-btn`} onClick={() => setMode('create')} className={`rounded-xl border px-3 py-2 text-left text-sm transition ${mode === 'create' ? 'border-sky-400/55 bg-sky-400/10 text-sky-50' : 'border-white/10 bg-black/20 text-zinc-300 hover:border-white/20'}`}>
                <div className="font-semibold">Create new remote agent-id</div>
                <div className="mt-0.5 text-[11px] text-zinc-500">Create it on the remote, then attach</div>
              </button>
            </div>

            {mode === 'existing' ? (
              <div className="space-y-2">
                <input
                  data-debug-id={`${debugId}-remote-search-input`}
                  value={remoteSearch}
                  onChange={(e) => setRemoteSearch(e.target.value)}
                  placeholder="Search remote agent-ids…"
                  className="w-full rounded-xl border border-white/10 bg-black/30 px-3 py-2 text-sm outline-none focus:border-sky-400"
                />
                {remoteLoading ? (
                  <div data-debug-id={`${debugId}-remote-loading`} className="rounded-xl border border-dashed border-white/10 p-4 text-sm text-zinc-500">Loading remote agents…</div>
                ) : remoteError ? (
                  <div data-debug-id={`${debugId}-remote-error`} className="rounded-xl border border-red-400/30 bg-red-500/10 px-3 py-2 text-sm text-red-100">{remoteError}</div>
                ) : filteredRemoteAgents.length === 0 ? (
                  <div data-debug-id={`${debugId}-remote-empty`} className="rounded-xl border border-dashed border-white/10 p-4 text-sm text-zinc-500">No advertised remote agent-ids. Switch to “Create new remote agent-id”.</div>
                ) : (
                  <div className="max-h-[260px] space-y-2 overflow-y-auto pr-1">
                    {filteredRemoteAgents.map((agent) => {
                      const rid = remoteAgentId(agent);
                      const selected = selectedRemoteAgentId === rid;
                      return (
                        <button
                          key={rid}
                          type="button"
                          data-debug-id={`${debugId}-remote-agent-row-${rid}`}
                          onClick={() => { setSelectedRemoteAgentId(rid); setLocalAgentIdTouched(false); }}
                          className={`flex w-full items-center justify-between gap-3 rounded-2xl border px-4 py-3 text-left transition ${selected ? 'border-teal-400/55 bg-teal-400/10' : 'border-white/10 bg-black/20 hover:border-white/20 hover:bg-white/[0.04]'}`}
                        >
                          <div className="min-w-0">
                            <div className="truncate text-sm font-semibold text-zinc-100">{remoteAgentLabel(agent)}</div>
                            <div className="mt-0.5 truncate font-mono text-[11px] text-zinc-500">{rid} · {remoteDaemonId}</div>
                          </div>
                          <span className="flex-none rounded-full bg-teal-400/15 px-2 py-0.5 text-[10px] font-semibold text-teal-200">remote</span>
                        </button>
                      );
                    })}
                  </div>
                )}
              </div>
            ) : (
              <div className="grid gap-3 md:grid-cols-2">
                <div>
                  <label className="block text-[11px] uppercase tracking-wide text-zinc-500">New remote agent-id</label>
                  <input
                    data-debug-id={`${debugId}-new-remote-id-input`}
                    value={newRemoteAgentId}
                    onChange={(e) => { setNewRemoteAgentId(e.target.value); setLocalAgentIdTouched(false); }}
                    placeholder="e.g. researcher"
                    className="mt-1 w-full rounded-xl border border-white/10 bg-black/30 px-3 py-2 text-sm outline-none focus:border-sky-400"
                  />
                  {newRemoteAgentId && safeIdPart(newRemoteAgentId) !== newRemoteAgentId ? <div className="mt-1 text-[11px] text-amber-300">Will be created as “{safeIdPart(newRemoteAgentId)}”.</div> : null}
                </div>
                <div>
                  <label className="block text-[11px] uppercase tracking-wide text-zinc-500">Display name (optional)</label>
                  <input
                    data-debug-id={`${debugId}-new-remote-name-input`}
                    value={newRemoteDisplayName}
                    onChange={(e) => setNewRemoteDisplayName(e.target.value)}
                    placeholder="Researcher"
                    className="mt-1 w-full rounded-xl border border-white/10 bg-black/30 px-3 py-2 text-sm outline-none focus:border-sky-400"
                  />
                </div>
                <div className="md:col-span-2 rounded-xl border border-amber-400/20 bg-amber-400/[0.05] px-3 py-2 text-[11px] text-amber-200/90">
                  The agent-id will be created on <b>{remoteDaemonId || peerDaemonId(selectedPeer)}</b> and then attached locally.
                </div>
              </div>
            )}
          </div>
        ) : null}

        {/* Step 3 — local proxy config + confirm */}
        {step === 3 ? (
          <div data-debug-id={`${debugId}-step-local`} className="space-y-3">
            <div className="rounded-xl border border-white/10 bg-black/20 px-3 py-2 text-[12px] text-zinc-400">
              Attaching to <b className="text-teal-200">{effectiveRemoteAgentId}</b>{mode === 'create' ? ' (new)' : ''} on <b className="text-zinc-200">{remoteDaemonId || peerDaemonId(selectedPeer)}</b> via <span className="font-mono">{selectedPeerId}</span>
            </div>
            <div className="grid gap-3 md:grid-cols-2">
              <div>
                <label className="block text-[11px] uppercase tracking-wide text-zinc-500">Local proxy agent-id</label>
                <input
                  data-debug-id={`${debugId}-local-id-input`}
                  value={localAgentId}
                  onChange={(e) => { setLocalAgentId(e.target.value); setLocalAgentIdTouched(true); }}
                  className="mt-1 w-full rounded-xl border border-white/10 bg-black/30 px-3 py-2 text-sm outline-none focus:border-sky-400"
                />
                {localAgentId && !localAgentIdValid ? <div className="mt-1 text-[11px] text-amber-300">Use lowercase letters, digits, - or _ (try “{safeIdPart(localAgentId)}”).</div> : null}
              </div>
              <div>
                <label className="block text-[11px] uppercase tracking-wide text-zinc-500">Display name (optional)</label>
                <input
                  data-debug-id={`${debugId}-local-name-input`}
                  value={displayName}
                  onChange={(e) => setDisplayName(e.target.value)}
                  placeholder={localAgentId}
                  className="mt-1 w-full rounded-xl border border-white/10 bg-black/30 px-3 py-2 text-sm outline-none focus:border-sky-400"
                />
              </div>
              <div>
                <label className="block text-[11px] uppercase tracking-wide text-zinc-500">Template</label>
                <select data-debug-id={`${debugId}-template-select`} value={templateId} onChange={(e) => setTemplateId(e.target.value)} className="mt-1 w-full rounded-xl border border-white/10 bg-black/30 px-3 py-2 text-sm outline-none focus:border-sky-400">
                  {templateOptions.map((t: any) => <option key={t.template_id || t.templateId} value={t.template_id || t.templateId}>{t.display_name || t.displayName || t.template_id || t.templateId}</option>)}
                </select>
              </div>
              <div className="grid grid-cols-2 gap-2">
                <div>
                  <label className="block text-[11px] uppercase tracking-wide text-zinc-500">Provider</label>
                  <select data-debug-id={`${debugId}-provider-select`} value={providerProfile} onChange={(e) => setProviderProfile(e.target.value)} className="mt-1 w-full rounded-xl border border-white/10 bg-black/30 px-3 py-2 text-sm outline-none focus:border-sky-400">
                    {providerOptions.map((p) => <option key={p} value={p}>{p}</option>)}
                  </select>
                </div>
                <div>
                  <label className="block text-[11px] uppercase tracking-wide text-zinc-500">Tier</label>
                  <select data-debug-id={`${debugId}-tier-select`} value={modelTier} onChange={(e) => setModelTier(e.target.value)} className="mt-1 w-full rounded-xl border border-white/10 bg-black/30 px-3 py-2 text-sm outline-none focus:border-sky-400">
                    {TIERS.map((t) => <option key={t} value={t}>{t}</option>)}
                  </select>
                </div>
              </div>
            </div>
            {submitError ? <div data-debug-id={`${debugId}-submit-error`} className="rounded-xl border border-red-400/30 bg-red-500/10 px-3 py-2 text-sm text-red-100">{submitError}</div> : null}
          </div>
        ) : null}

        {/* Footer navigation */}
        <div className="mt-6 flex items-center gap-3 border-t border-white/10 pt-4">
          {step > 1 ? (
            <button type="button" data-debug-id={`${debugId}-back-btn`} onClick={() => setStep((s) => Math.max(1, s - 1))} className="rounded-xl border border-white/10 bg-white/[0.04] px-4 py-2 text-sm font-semibold text-zinc-200 transition hover:border-white/20 hover:bg-white/[0.07]">Back</button>
          ) : null}
          <button type="button" data-debug-id={`${debugId}-cancel-btn`} onClick={onClose} className="ml-auto rounded-xl border border-white/10 bg-white/[0.04] px-4 py-2 text-sm font-semibold text-zinc-300 transition hover:border-white/20 hover:bg-white/[0.07]">Cancel</button>
          {step < 3 ? (
            <button
              type="button"
              data-debug-id={`${debugId}-next-btn`}
              onClick={() => setStep((s) => Math.min(3, s + 1))}
              disabled={step === 1 ? !canProceedStep1 : !canProceedStep2}
              className="rounded-xl bg-sky-400 px-5 py-2 text-sm font-semibold text-[#05141c] transition hover:bg-sky-300 disabled:cursor-not-allowed disabled:opacity-40"
            >
              Next
            </button>
          ) : (
            <button
              type="button"
              data-debug-id={`${debugId}-submit-btn`}
              onClick={handleSubmit}
              disabled={!canSubmit}
              className="rounded-xl bg-emerald-400 px-5 py-2 text-sm font-semibold text-[#052015] transition hover:bg-emerald-300 disabled:cursor-not-allowed disabled:opacity-40"
            >
              {submitting ? 'Creating…' : 'Create proxy agent-id'}
            </button>
          )}
        </div>
      </div>
    </div>
  );
}
