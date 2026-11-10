// Add agent (Bridge-owned chains): launch an instance of a chosen agent on the
// chain's owner Bridge, wait until it runs, then bind it as a worker or
// reviewer with chain.member.set. The coordinator is started or replaced with
// OwnerCoordinatorControl instead.

import React, { useState } from 'react';
import { Button, Select, Text } from '@ui';
import { addOwnerChainAgent, type AddChainAgentStage } from '../../api/ownerCoordinator';
import { hubCoordinatorApi, type CoordinatorAgentChoice, type OwnerCoordinatorApi } from './OwnerCoordinatorControl';

export type ChainAgentRole = 'worker' | 'reviewer';

const ROLE_OPTIONS: { value: ChainAgentRole; label: string }[] = [
  { value: 'worker', label: 'Worker' },
  { value: 'reviewer', label: 'Reviewer' },
];

export const ADD_AGENT_STAGE_TEXT: Record<AddChainAgentStage, string> = {
  launching: 'Launching the agent on the owner Bridge…',
  waiting: 'Waiting for the agent to start…',
  binding: 'Adding it to the chain…',
  done: 'Agent added.',
};

export interface OwnerAddAgentControlProps {
  chainId: string;
  ownerBridgeId: string;
  disabled?: boolean;
  /** chain.member.set with `role` through the owner relay. */
  bind: (instanceId: string, agentId: string, role: ChainAgentRole) => Promise<void>;
  onAdded: (instanceId: string, role: ChainAgentRole) => void;
  api?: OwnerCoordinatorApi;
}

export function OwnerAddAgentControl({ chainId, ownerBridgeId, disabled, bind, onAdded, api = hubCoordinatorApi }: OwnerAddAgentControlProps) {
  const [open, setOpen] = useState(false);
  const [agents, setAgents] = useState<CoordinatorAgentChoice[] | null>(null);
  const [agentId, setAgentId] = useState('');
  const [role, setRole] = useState<ChainAgentRole>('worker');
  const [stage, setStage] = useState<AddChainAgentStage | ''>('');
  const [error, setError] = useState('');
  const running = stage !== '' && stage !== 'done';

  async function openPicker() {
    setOpen(true); setError(''); setStage('');
    if (agents) return;
    try {
      const list = await api.listAgents();
      setAgents(list);
      setAgentId(list[0]?.agentId ?? '');
    } catch (e) { setError(e instanceof Error ? e.message : String(e)); setAgents([]); }
  }

  async function add() {
    if (!agentId) return;
    setError('');
    try {
      const id = await addOwnerChainAgent({
        launch: () => api.launch({ agentId, chainId, bridgeId: ownerBridgeId }),
        status: api.status,
        bind: (instanceId) => bind(instanceId, agentId, role),
        onStage: (s) => setStage(s),
      });
      setOpen(false);
      onAdded(id, role);
    } catch (e) {
      setStage('');
      setError(e instanceof Error ? e.message : String(e));
    }
  }

  return (
    <div data-debug-id="owner-chain-add-agent" className="flex flex-wrap items-center gap-2">
      {!open && (
        <Button size="sm" variant="ghost" data-debug-id="owner-chain-add-agent-open" disabled={disabled || running} onClick={() => void openPicker()}>
          Add agent
        </Button>
      )}
      {open && (
        <>
          <Select
            size="sm"
            data-debug-id="owner-chain-add-agent-agent"
            aria-label="Agent"
            name="chain_agent"
            value={agentId}
            disabled={running || !agents}
            onChange={setAgentId}
            placeholder={!agents ? 'Loading agents…' : 'No agents'}
            options={(agents ?? []).map((a) => ({ value: a.agentId, label: a.name }))}
          />
          <Select
            size="sm"
            data-debug-id="owner-chain-add-agent-role"
            aria-label="Role"
            name="chain_agent_role"
            value={role}
            disabled={running}
            onChange={(v) => setRole(v as ChainAgentRole)}
            options={ROLE_OPTIONS}
          />
          <Button size="sm" data-debug-id="owner-chain-add-agent-launch" disabled={disabled || running || !agentId} onClick={() => void add()}>Add</Button>
          <Button size="sm" variant="ghost" disabled={running} onClick={() => { setOpen(false); setStage(''); }}>Cancel</Button>
        </>
      )}
      {stage && <Text as="span" role="caption" tone="muted" aria-live="polite" data-debug-id="owner-chain-add-agent-stage">{ADD_AGENT_STAGE_TEXT[stage]}</Text>}
      {error && <Text as="span" role="caption" tone="danger" data-debug-id="owner-chain-add-agent-error">{error}</Text>}
    </div>
  );
}

export default OwnerAddAgentControl;
