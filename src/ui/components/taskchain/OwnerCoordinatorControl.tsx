// Start coordinator (native and imported Bridge-owned chains): launch an
// instance of a chosen agent on the chain's owner Bridge, wait until it runs,
// then bind it with chain.member.set role=coordinator. Imported chains keep
// their legacy members archive-only, so this is how they get a coordinator.

import React, { useState } from 'react';
import { Button, Select, Text } from '@ui';
import { cookieJsonFetch, cookieJsonFetchEnvelope, cookieMutation } from '../../api/cookieFetch';
import { createdInstanceId, isCoordinatorAgent, startOwnerCoordinator, type NewChainCoordinatorStage, type StartCoordinatorStage } from '../../api/ownerCoordinator';

export interface CoordinatorAgentChoice { agentId: string; name: string; slug?: string }

/** The picker's default: the coordinator agent when there is one, else the first agent ('' when none). */
export function defaultCoordinatorAgentId(agents: CoordinatorAgentChoice[]): string {
  return (agents.find(isCoordinatorAgent) ?? agents[0])?.agentId ?? '';
}

/** The Hub calls Start coordinator makes; tests replace them. */
export interface OwnerCoordinatorApi {
  listAgents: () => Promise<CoordinatorAgentChoice[]>;
  launch: (input: { agentId: string; chainId: string; bridgeId: string }) => Promise<string>;
  status: (instanceId: string) => Promise<string>;
  restart: (instanceId: string) => Promise<void>;
}

export const hubCoordinatorApi: OwnerCoordinatorApi = {
  async listAgents() {
    const body = await cookieJsonFetchEnvelope('/agents?limit=200&view=summary');
    const rows: any[] = Array.isArray(body?.data) ? body.data : (Array.isArray(body) ? body : (body?.data?.agents || []));
    return rows
      .filter((r) => r && r.agent_id && !r.archived_at)
      .map((r) => ({ agentId: String(r.agent_id), name: String(r.name || r.slug || r.agent_id), slug: String(r.slug || '') }));
  },
  async launch({ agentId, chainId, bridgeId }) {
    return createdInstanceId(await cookieMutation('/agent-instances', 'POST', { agent_id: agentId, chain_id: chainId, bridge_id: bridgeId }));
  },
  async status(instanceId) {
    const data: any = await cookieJsonFetch(`/agent-instances/${encodeURIComponent(instanceId)}`);
    return String(data?.runtime_status || data?.instance?.runtime_status || '');
  },
  async restart(instanceId) {
    await cookieMutation(`/agent-instances/${encodeURIComponent(instanceId)}/restart`, 'POST', {});
  },
};

export const COORDINATOR_STAGE_TEXT: Record<NewChainCoordinatorStage, string> = {
  creating: 'Creating the chain on its owner Bridge…',
  registering: 'Waiting for the chain to register…',
  launching: 'Launching the coordinator on the owner Bridge…',
  waiting: 'Waiting for the coordinator to start…',
  binding: 'Binding it as the chain’s coordinator…',
  restarting: 'Restarting it with the coordinator role…',
  done: 'Coordinator bound.',
};

export interface OwnerCoordinatorControlProps {
  chainId: string;
  ownerBridgeId: string;
  /** The bound coordinator; '' when none is bound, undefined while it is looked up. */
  coordinatorId: string | undefined;
  /** The owner read of an unknown coordinator failed. */
  lookupFailed?: boolean;
  disabled?: boolean;
  /** chain.member.set role=coordinator through the owner relay. */
  bind: (instanceId: string, agentId: string) => Promise<void>;
  onBound: (instanceId: string) => void;
  api?: OwnerCoordinatorApi;
}

export function OwnerCoordinatorControl({ chainId, ownerBridgeId, coordinatorId, lookupFailed, disabled, bind, onBound, api = hubCoordinatorApi }: OwnerCoordinatorControlProps) {
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
      setAgentId(defaultCoordinatorAgentId(list));
    } catch (e) { setError(e instanceof Error ? e.message : String(e)); setAgents([]); }
  }

  async function start() {
    if (!agentId) return;
    setError('');
    try {
      const id = await startOwnerCoordinator({
        launch: () => api.launch({ agentId, chainId, bridgeId: ownerBridgeId }),
        status: api.status,
        restart: api.restart,
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
    <div data-debug-id="owner-chain-coordinator" className="flex flex-wrap items-center gap-2">
      {coordinatorId
        ? <Text as="span" role="caption" tone="muted" data-debug-id="owner-chain-coordinator-id">Coordinator: <Text as="code" role="code-sm">{coordinatorId}</Text></Text>
        : coordinatorId === '' ? <Text as="span" role="caption" tone="muted" data-debug-id="owner-chain-coordinator-none">No coordinator</Text>
        : lookupFailed ? <Text as="span" role="caption" tone="muted" data-debug-id="owner-chain-coordinator-unknown">Coordinator could not be looked up</Text>
        : <Text as="span" role="caption" tone="muted" aria-live="polite" data-debug-id="owner-chain-coordinator-loading">Looking up coordinator…</Text>}
      {/* Start/Replace only once the coordinator is known (or its lookup failed). */}
      {!open && (coordinatorId !== undefined || lookupFailed) && (
        <Button size="sm" variant="ghost" data-debug-id="owner-chain-start-coordinator" disabled={disabled || running} onClick={() => void openPicker()}>
          {coordinatorId ? 'Replace coordinator' : 'Start coordinator'}
        </Button>
      )}
      {open && (
        <>
          <Select
            size="sm"
            data-debug-id="owner-chain-coordinator-agent"
            aria-label="Coordinator agent"
            name="coordinator_agent"
            value={agentId}
            disabled={running || !agents}
            onChange={setAgentId}
            placeholder={!agents ? 'Loading agents…' : 'No agents'}
            options={(agents ?? []).map((a) => ({ value: a.agentId, label: a.name }))}
          />
          <Button size="sm" data-debug-id="owner-chain-coordinator-launch" disabled={disabled || running || !agentId} onClick={() => void start()}>Launch</Button>
          <Button size="sm" variant="ghost" disabled={running} onClick={() => { setOpen(false); setStage(''); }}>Cancel</Button>
        </>
      )}
      {stage && <Text as="span" role="caption" tone="muted" aria-live="polite" data-debug-id="owner-chain-coordinator-stage">{COORDINATOR_STAGE_TEXT[stage]}</Text>}
      {error && <Text as="span" role="caption" tone="danger" data-debug-id="owner-chain-coordinator-error">{error}</Text>}
    </div>
  );
}

export default OwnerCoordinatorControl;
