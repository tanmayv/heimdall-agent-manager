import { useState } from 'react';
import { useListAgentBridgeSupportQuery, usePatchAgentBridgeSupportMutation, useListBridgesQuery } from '../../api/endpoints/bridgeSupport';

export type AgentBridgesTabProps = {
  agentId: string;
  session: any;
  debugPrefix: string;
};

function bridgeCapabilitiesLabel(bridge: any): string {
  const caps = bridge?.capabilities || bridge?.provider_capabilities || {};
  const providers = caps?.providers || caps?.provider_profiles || [];
  const tiers = caps?.tiers || caps?.model_tiers || [];
  const parts: string[] = [];
  if (providers.length) parts.push(providers.join(', '));
  if (tiers.length) parts.push(tiers.join('/'));
  return parts.length ? parts.join(' · ') : '—';
}

// UI-9: Bridges tab — AgentBridgeSupport config for this agent.
// Shows which bridges this agent may run on, per-bridge preferred provider/tier
// defaults, priority, max_instances, enable/disable toggle. -> PATCH /agents/{id}/bridge-support.
// Provider/tier preferences are advisory; the bridge capability matrix is the
// hard runtime constraint.
export default function AgentBridgesTab({ agentId, session, debugPrefix }: AgentBridgesTabProps) {
  const supportQuery = useListAgentBridgeSupportQuery({ agentId }, { skip: !agentId || !session?.clientToken });
  const bridgesQuery = useListBridgesQuery(undefined, { skip: !session?.clientToken });
  const [patchSupport] = usePatchAgentBridgeSupportMutation();
  const [busyBridgeId, setBusyBridgeId] = useState('');
  const [error, setError] = useState('');

  const entries = supportQuery.data?.entries || [];
  const bridges = bridgesQuery.data?.bridges || [];
  const bridgeById = new Map<string, any>(bridges.map((bridge: any) => [String(bridge?.bridge_id || bridge?.bridgeId || ''), bridge]));
  const enabledCount = entries.filter((entry) => entry.enabled).length;

  async function toggle(entry: any, next: boolean) {
    setBusyBridgeId(entry.bridgeId);
    setError('');
    try {
      await patchSupport({ agentId, bridgeId: entry.bridgeId, enabled: next }).unwrap();
    } catch (err: any) {
      setError(String(err?.message || err || 'Unable to update bridge support'));
    } finally {
      setBusyBridgeId('');
    }
  }

  return (
    <div data-debug-id={`${debugPrefix}-bridges-tab`} className="space-y-3 text-[12.5px] text-zinc-300">
      <div data-debug-id={`${debugPrefix}-bridges-header`} className="rounded-xl border border-white/10 bg-white/[0.03] p-3">
        <div className="flex items-center justify-between gap-2">
          <div className="min-w-0">
            <div className="truncate text-sm font-medium text-zinc-100">Bridge support</div>
            <div data-debug-id={`${debugPrefix}-bridges-summary`} className="mt-0.5 text-[11px] text-zinc-500">{enabledCount} enabled · {entries.length} configured</div>
          </div>
        </div>
        <p className="mt-2 text-[11px] leading-5 text-zinc-500">An agent with no enabled support cannot launch. Provider/tier values are preferred defaults only; the Bridge capability matrix decides what can run.</p>
      </div>

      {error ? <div data-debug-id={`${debugPrefix}-bridges-error`} className="rounded-xl border border-red-400/30 bg-red-500/10 px-3 py-2 text-xs text-red-100">{error}</div> : null}

      {supportQuery.isFetching && entries.length === 0 ? <div className="rounded-xl border border-white/10 bg-black/20 p-4 text-sm text-zinc-500">Loading bridge support…</div> : null}

      {entries.length === 0 && !supportQuery.isFetching ? (
        <div data-debug-id={`${debugPrefix}-bridges-empty`} className="rounded-xl border border-dashed border-white/10 bg-[#111111]/70 p-4 text-center text-sm text-zinc-500">
          <div className="text-zinc-300">No bridge support configured.</div>
          <p className="mt-1 leading-5">Enable a bridge so this agent can launch.</p>
        </div>
      ) : (
        <div className="space-y-2">
          {entries.map((entry) => {
            const bridge = bridgeById.get(entry.bridgeId);
            const busy = busyBridgeId === entry.bridgeId;
            return (
              <div key={entry.bridgeId} data-debug-id={`${debugPrefix}-bridge-support-${entry.bridgeId}`} className={`rounded-xl border px-3 py-2.5 ${entry.enabled ? 'border-emerald-400/25 bg-emerald-400/[0.05]' : 'border-white/10 bg-white/[0.02]'}`}>
                <div className="flex items-start justify-between gap-2">
                  <div className="min-w-0">
                    <div className="truncate text-sm text-zinc-100">{bridge?.label || bridge?.name || entry.bridgeId}</div>
                    <div className="mt-0.5 truncate text-[11px] text-zinc-500"><code>{entry.bridgeId}</code>{bridge ? ` · ${bridgeCapabilitiesLabel(bridge)}` : ''}</div>
                    <div className="mt-1 flex flex-wrap gap-x-3 gap-y-0.5 text-[11px] text-zinc-500">
                      {entry.providerProfile ? <span>preferred provider: <span className="text-zinc-300">{entry.providerProfile}</span></span> : null}
                      {entry.modelTier ? <span>preferred tier: <span className="text-zinc-300">{entry.modelTier}</span></span> : null}
                      {entry.priority !== undefined ? <span>priority: <span className="text-zinc-300">{entry.priority}</span></span> : null}
                      {entry.maxInstances !== undefined ? <span>max: <span className="text-zinc-300">{entry.maxInstances}</span></span> : null}
                    </div>
                  </div>
                  <button
                    type="button"
                    data-debug-id={`${debugPrefix}-bridge-support-toggle-${entry.bridgeId}`}
                    onClick={() => void toggle(entry, !entry.enabled)}
                    disabled={busy}
                    className={`shrink-0 rounded-full border px-2.5 py-0.5 text-[11px] ${entry.enabled ? 'border-emerald-400/30 bg-emerald-400/10 text-emerald-100 hover:bg-emerald-400/20' : 'border-white/10 bg-white/5 text-zinc-400 hover:bg-white/10'} disabled:opacity-50`}
                  >
                    {busy ? '…' : entry.enabled ? 'Enabled' : 'Enable'}
                  </button>
                </div>
              </div>
            );
          })}
        </div>
      )}
    </div>
  );
}
