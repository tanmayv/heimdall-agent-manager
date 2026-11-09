// Start coordinator (native and imported Bridge-owned chains): launch an
// instance of a chosen agent on the chain's owner Bridge, wait until it runs,
// then bind it with chain.member.set role=coordinator. Imported chains keep
// their legacy members archive-only, so this is how they get a coordinator.

import React, { useState } from 'react';
import { Button } from '@ui';
import { cookieJsonFetch, cookieJsonFetchEnvelope, cookieMutation } from '../../api/cookieFetch';
import { createdInstanceId, startOwnerCoordinator, type StartCoordinatorStage } from '../../api/ownerCoordinator';

export interface CoordinatorAgentChoice { agentId: string; name: string }

/** The Hub calls Start coordinator makes; tests replace them. */
export interface OwnerCoordinatorApi {
  listAgents: () => Promise<CoordinatorAgentChoice[]>;
  launch: (input: { agentId: string; chainId: string; bridgeId: string }) => Promise<string>;
  status: (instanceId: string) => Promise<string>;
}

export const hubCoordinatorApi: OwnerCoordinatorApi = {
  async listAgents() {
    const body = await cookieJsonFetchEnvelope('/agents?limit=200&view=summary');
    const rows: any[] = Array.isArray(body?.data) ? body.data : (Array.isArray(body) ? body : (body?.data?.agents || []));
    return rows
      .filter((r) => r && r.agent_id && !r.archived_at)
      .map((r) => ({ agentId: String(r.agent_id), name: String(r.name || r.slug || r.agent_id) }));
  },
  async launch({ agentId, chainId, bridgeId }) {
    return createdInstanceId(await cookieMutation('/agent-instances', 'POST', { agent_id: agentId, chain_id: chainId, bridge_id: bridgeId }));
  },
  async status(instanceId) {
    const data: any = await cookieJsonFetch(`/agent-instances/${encodeURIComponent(instanceId)}`);
    return String(data?.runtime_status || data?.instance?.runtime_status || '');
  },
};

const STAGE_TEXT: Record<StartCoordinatorStage, string> = {
  launching: 'Launching the coordinator on the owner Bridge…',
  waiting: 'Waiting for the coordinator to start…',
  binding: 'Binding it as the chain’s coordinator…',
  done: 'Coordinator bound.',
};

export interface OwnerCoordinatorControlProps {
  chainId: string;
  ownerBridgeId: string;
  coordinatorId: string;
  disabled?: boolean;
  /** chain.member.set role=coordinator through the owner relay. */
  bind: (instanceId: string, agentId: string) => Promise<void>;
  onBound: (instanceId: string) => void;
  api?: OwnerCoordinatorApi;
}

export function OwnerCoordinatorControl({ chainId, ownerBridgeId, coordinatorId, disabled, bind, onBound, api = hubCoordinatorApi }: OwnerCoordinatorControlProps) {
  const [open, setOpen] = useState(false);
  const [agents, setAgents] = useState<CoordinatorAgentChoice[] | null>(null);
  const [agentId, setAgentId] = useState('');
  const [stage, setStage] = useState<StartCoordinatorStage | ''>('');
  const [error, setError] = useState('');
  const running = stage !== '' && stage !== 'done';

  async function openPicker() {
    setOpen(true); setError('');
    if (agents) return;
    try {
      const list = await api.listAgents();
      setAgents(list);
      if (list.length) setAgentId(list[0].agentId);
    } catch (e) { setError(e instanceof Error ? e.message : String(e)); setAgents([]); }
  }

  async function start() {
    if (!agentId) return;
    setError('');
    try {
      const id = await startOwnerCoordinator({
        launch: () => api.launch({ agentId, chainId, bridgeId: ownerBridgeId }),
        status: api.status,
        bind: (instanceId) => bind(instanceId, agentId),
        onStage: (s) => setStage(s),
      });
      setOpen(false);
      onBound(id);
    } catch (e) {
      setStage('');
      setError(e instanceof Error ? e.message : String(e));
    }
  }

  return (
    <div data-debug-id="owner-chain-coordinator" className="flex flex-wrap items-center gap-2 text-xs">
      {coordinatorId
        ? <span data-debug-id="owner-chain-coordinator-id" className="text-muted">Coordinator: <code>{coordinatorId}</code></span>
        : <span className="text-muted">No coordinator</span>}
      {!open && (
        <Button size="sm" variant="ghost" data-debug-id="owner-chain-start-coordinator" disabled={disabled || running} onClick={() => void openPicker()}>
          {coordinatorId ? 'Replace coordinator' : 'Start coordinator'}
        </Button>
      )}
      {open && (
        <>
          <select
            data-debug-id="owner-chain-coordinator-agent"
            aria-label="Coordinator agent"
            className="rounded border border-subtle bg-transparent px-2 py-1"
            value={agentId}
            disabled={running || !agents}
            onChange={(e) => setAgentId(e.target.value)}
          >
            {!agents && <option value="">Loading agents…</option>}
            {agents?.length === 0 && <option value="">No agents</option>}
            {agents?.map((a) => <option key={a.agentId} value={a.agentId}>{a.name}</option>)}
          </select>
          <Button size="sm" data-debug-id="owner-chain-coordinator-launch" disabled={disabled || running || !agentId} onClick={() => void start()}>Launch</Button>
          <Button size="sm" variant="ghost" disabled={running} onClick={() => { setOpen(false); setStage(''); }}>Cancel</Button>
        </>
      )}
      {stage && <span role="status" data-debug-id="owner-chain-coordinator-stage" className="text-muted">{STAGE_TEXT[stage]}</span>}
      {error && <span role="alert" data-debug-id="owner-chain-coordinator-error" className="text-danger">{error}</span>}
    </div>
  );
}

export default OwnerCoordinatorControl;
