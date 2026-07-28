import { useState } from 'react';
import { agentHasLiveSession } from '../../api/agentLiveness';

export type AgentSessionsTabProps = {
  durableAgentId: string;
  instances: any[];
  chainsById: Record<string, any>;
  providers?: any[];
  bridges?: any[];
  debugPrefix: string;
  onOpenInstance?: (agentInstanceId: string) => void;
  onStartInstance?: (agentInstanceId: string) => void | Promise<void>;
  onStopInstance?: (agentInstanceId: string) => void | Promise<void>;
  // UI-9: launch a NEW instance with no chain_id → creates a private/default
  // task chain + conversation + starts the instance into an empty live chat.
  onLaunchInstance?: (opts: { agentId: string; provider?: string; modelTier?: string; projectId?: string; bridgeId?: string }) => void | Promise<void>;
};

function statusTone(agent: any): string {
  if (agentHasLiveSession(agent)) return 'border-emerald-400/30 bg-emerald-400/10 text-emerald-200';
  return 'border-white/10 bg-[#141414] text-zinc-400';
}

function statusLabel(agent: any): string {
  if (agentHasLiveSession(agent)) return 'running';
  const st = String(agent?.startupStatus || agent?.status || '').toLowerCase();
  return st || 'stopped';
}

// UI-9: Sessions — every instance of this agent. Because an instance is 1:1 with
// a conversation (arch invariant 22a), the instances list and conversations list
// are the SAME list. Each row shows the INSTANCE ID (instead of a conversation
// title), plus bridge, provider/tier, runtime_status, and origin (chat/chain).
export default function AgentSessionsTab({ durableAgentId, instances, chainsById, providers = [], bridges = [], debugPrefix, onOpenInstance, onStartInstance, onStopInstance, onLaunchInstance }: AgentSessionsTabProps) {
  const [launchOpen, setLaunchOpen] = useState(false);
  const [launchProvider, setLaunchProvider] = useState(providers?.[0]?.name || 'pi');
  const [launchTier, setLaunchTier] = useState('normal');
  const [launchBusy, setLaunchBusy] = useState(false);
  const [launchError, setLaunchError] = useState('');

  const sorted = [...instances].sort((a, b) => Number(b?.lastSeenUnixMs || 0) - Number(a?.lastSeenUnixMs || 0));

  async function launch() {
    setLaunchBusy(true);
    setLaunchError('');
    try {
      await onLaunchInstance?.({ agentId: durableAgentId, provider: launchProvider, modelTier: launchTier });
      setLaunchOpen(false);
    } catch (err: any) {
      setLaunchError(String(err?.message || err || 'Unable to launch instance'));
    } finally {
      setLaunchBusy(false);
    }
  }

  return (
    <div data-debug-id={`${debugPrefix}-sessions-tab`} className="space-y-3 text-[12.5px] text-zinc-300">
      <div data-debug-id={`${debugPrefix}-sessions-header`} className="flex items-center justify-between gap-2 rounded-xl border border-white/10 bg-white/[0.03] p-3">
        <div className="min-w-0">
          <div className="truncate text-sm font-medium text-zinc-100">Sessions</div>
          <div className="mt-0.5 text-[11px] text-zinc-500">{instances.length} instance{instances.length === 1 ? '' : 's'} · 1:1 with conversations</div>
        </div>
        {onLaunchInstance ? (
          <button type="button" data-debug-id={`${debugPrefix}-sessions-launch-btn`} onClick={() => setLaunchOpen((open) => !open)} className="shrink-0 rounded-full border border-sky-400/30 bg-sky-400/10 px-3 py-1 text-[11px] text-sky-100 hover:bg-sky-400/20">＋ Launch instance</button>
        ) : null}
      </div>

      {launchOpen ? (
        <div data-debug-id={`${debugPrefix}-sessions-launch-panel`} className="rounded-xl border border-sky-400/25 bg-sky-400/[0.05] p-3">
          <div className="mb-2 text-[11.5px] text-sky-100/80">Launches a new instance with no chain_id — creates a private/default task chain + conversation and starts the instance into an empty live chat.</div>
          <div className="grid grid-cols-2 gap-2">
            <label className="block text-[11px] uppercase tracking-wide text-zinc-500">Provider
              <select data-debug-id={`${debugPrefix}-sessions-launch-provider`} value={launchProvider} onChange={(e) => setLaunchProvider(e.target.value)} className="mt-1 w-full rounded-lg border border-white/10 bg-black/30 px-2 py-1.5 text-sm text-zinc-100 outline-none">
                {(providers?.length ? providers : [{ name: 'pi' }]).map((p: any) => <option key={p.name} value={p.name}>{p.name}</option>)}
              </select>
            </label>
            <label className="block text-[11px] uppercase tracking-wide text-zinc-500">Tier
              <select data-debug-id={`${debugPrefix}-sessions-launch-tier`} value={launchTier} onChange={(e) => setLaunchTier(e.target.value)} className="mt-1 w-full rounded-lg border border-white/10 bg-black/30 px-2 py-1.5 text-sm text-zinc-100 outline-none">
                <option value="normal">normal</option>
                <option value="smart">smart</option>
                <option value="cheap">cheap</option>
              </select>
            </label>
          </div>
          {launchError ? <div className="mt-2 text-[11px] text-red-300">{launchError}</div> : null}
          <div className="mt-2 flex justify-end gap-2">
            <button type="button" data-debug-id={`${debugPrefix}-sessions-launch-cancel`} onClick={() => setLaunchOpen(false)} className="rounded-full border border-white/10 px-2.5 py-1 text-[11px] text-zinc-400 hover:bg-white/10">Cancel</button>
            <button type="button" data-debug-id={`${debugPrefix}-sessions-launch-confirm`} onClick={() => void launch()} disabled={launchBusy} className="rounded-full border border-sky-400/30 bg-sky-400/10 px-3 py-1 text-[11px] text-sky-100 hover:bg-sky-400/20 disabled:opacity-50">{launchBusy ? 'Launching…' : 'Launch'}</button>
          </div>
        </div>
      ) : null}

      {sorted.length === 0 ? (
        <div data-debug-id={`${debugPrefix}-sessions-empty`} className="rounded-xl border border-dashed border-white/10 bg-[#111111]/70 p-4 text-center text-sm text-zinc-500">
          <div className="text-zinc-300">No instances yet.</div>
          <p className="mt-1 leading-5">Launch an instance to start a private conversation.</p>
        </div>
      ) : (
        <div className="space-y-2">
          {sorted.map((instance) => {
            const id = String(instance?.id || instance?.agent_instance_id || instance?.agentInstanceId || '');
            const chainId = String(instance?.chainId || instance?.chain_id || '');
            const chain = chainId ? chainsById?.[chainId] : null;
            const live = agentHasLiveSession(instance);
            return (
              <div key={id} data-debug-id={`${debugPrefix}-session-row-${id}`} data-instance-id={id} className="rounded-xl border border-white/10 bg-white/[0.02] p-3">
                <div className="flex items-start justify-between gap-2">
                  <div className="min-w-0">
                    <div className="flex items-center gap-2">
                      <span className={`h-2 w-2 shrink-0 rounded-full ${live ? 'bg-emerald-400' : 'bg-zinc-600'}`} />
                      <code data-debug-id={`${debugPrefix}-session-instance-id-${id}`} className="min-w-0 truncate text-sm text-zinc-100">{id}</code>
                    </div>
                    <div className="mt-1 flex flex-wrap gap-x-3 gap-y-0.5 text-[11px] text-zinc-500">
                      <span>provider: <span className="text-zinc-300">{instance?.providerProfile || '—'}</span></span>
                      <span>tier: <span className="text-zinc-300">{instance?.modelTier || '—'}</span></span>
                      <span>origin: <span className="text-zinc-300">{chain ? 'chain' : 'chat'}</span></span>
                    </div>
                    {chain ? <div data-debug-id={`${debugPrefix}-session-chain-${id}`} className="mt-1 truncate text-[11px] text-zinc-500">chain: <span className="text-zinc-300">{chain.title || chainId}</span></div> : null}
                  </div>
                  <div className="flex shrink-0 flex-col items-end gap-1">
                    <span data-debug-id={`${debugPrefix}-session-status-${id}`} className={`rounded-full border px-2 py-0.5 text-[10.5px] ${statusTone(instance)}`}>{statusLabel(instance)}</span>
                    <div className="flex gap-1">
                      {onOpenInstance ? <button type="button" data-debug-id={`${debugPrefix}-session-open-${id}`} onClick={() => onOpenInstance?.(id)} className="text-[11px] text-zinc-400 hover:text-zinc-100">open</button> : null}
                      {live && onStopInstance ? <button type="button" data-debug-id={`${debugPrefix}-session-stop-${id}`} onClick={() => void onStopInstance?.(id)} className="text-[11px] text-zinc-400 hover:text-zinc-100">stop</button> : null}
                      {!live && onStartInstance ? <button type="button" data-debug-id={`${debugPrefix}-session-start-${id}`} onClick={() => void onStartInstance?.(id)} className="text-[11px] text-zinc-400 hover:text-zinc-100">start</button> : null}
                    </div>
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
