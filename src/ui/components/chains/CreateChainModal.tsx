import { useState, useEffect } from 'react';
import { Modal, Select, Button } from '@ui';
import { useCreateTaskChainMutation } from '../../api/endpoints/tasks';
import { useCreateAgentInstanceInChainMutation, useListAgentsQuery } from '../../api/endpoints/agents';
import { useListBridgesQuery } from '../../api/endpoints/bridgeSupport';

const PROVIDERS = ['anthropic', 'pi', 'openai'] as const;
const TIERS = ['normal', 'fast'] as const;

type Props = {
  projectId: string;
  isOpen: boolean;
  onClose: () => void;
  onCreated: (conversationPath: string) => void;
};

export default function CreateChainModal({ projectId, isOpen, onClose, onCreated }: Props) {
  const bridgesQuery = useListBridgesQuery(undefined, { skip: !isOpen });
  const agentsQuery = useListAgentsQuery(undefined, { skip: !isOpen });

  const bridges = (bridgesQuery.data?.bridges ?? []).filter(
    (b: any) => !String(b?.status || b?.runtime_status || b?.state || '').includes('revoke'),
  );
  const agents = agentsQuery.data?.agents ?? [];
  const coordinatorAgents = agents.filter((a: any) =>
    String(a.agentId || a.agent_id || a.id || '').includes('coordinator'),
  );
  const agentList = coordinatorAgents.length > 0 ? coordinatorAgents : agents;

  const defaultBridgeId = bridges[0]?.bridge_id ?? bridges[0]?.bridgeId ?? '';
  const defaultAgentId =
    agentList[0]?.agentId ?? agentList[0]?.agent_id ?? agentList[0]?.id ?? '';

  const [bridgeId, setBridgeId] = useState('');
  const [agentId, setAgentId] = useState('');
  const [provider, setProvider] = useState<string>('anthropic');
  const [tier, setTier] = useState<string>('normal');
  const [error, setError] = useState('');

  // Pre-select defaults once data loads
  useEffect(() => {
    if (defaultBridgeId && !bridgeId) setBridgeId(defaultBridgeId);
  }, [defaultBridgeId]); // eslint-disable-line react-hooks/exhaustive-deps

  useEffect(() => {
    if (defaultAgentId && !agentId) setAgentId(defaultAgentId);
  }, [defaultAgentId]); // eslint-disable-line react-hooks/exhaustive-deps

  const [createChain, createChainState] = useCreateTaskChainMutation();
  const [createInstance, createInstanceState] = useCreateAgentInstanceInChainMutation();

  const loading =
    bridgesQuery.isLoading ||
    agentsQuery.isLoading ||
    createChainState.isLoading ||
    createInstanceState.isLoading;

  async function handleSubmit() {
    setError('');
    try {
      const chainResult = await createChain({
        title: 'New chain',
        kind: 'team_work',
      }).unwrap();
      const chainId = String(
        chainResult?.chain_id ?? chainResult?.chainId ?? chainResult?.data?.chain_id ?? '',
      );
      if (!chainId) throw new Error('Chain creation returned no chain ID');

      const instanceResult = await createInstance({
        agentId,
        chainId,
        bridgeId: bridgeId || undefined,
        providerProfile: provider,
        modelTier: tier,
        projectId,
      }).unwrap();
      const instanceId = String(
        instanceResult?.agent_instance_id ??
          instanceResult?.agentInstanceId ??
          instanceResult?.data?.agent_instance_id ??
          '',
      );
      if (!instanceId) throw new Error('Agent instance creation returned no instance ID');

      onCreated('/conversations/' + instanceId);
    } catch (err: any) {
      setError(String(err?.message || err?.error || 'Failed to start chain'));
    }
  }

  function bridgeLabel(b: any): string {
    const label = String(b?.label ?? b?.display_name ?? b?.displayName ?? '');
    const id = String(b?.bridge_id ?? b?.bridgeId ?? '');
    const online = String(b?.status ?? b?.runtime_status ?? b?.state ?? '')
      .toLowerCase()
      .includes('online');
    const tag = online ? '● online' : '○ offline';
    return `${label || id} (${tag})`;
  }

  function agentLabel(a: any): string {
    return String(
      a?.label ?? a?.display_name ?? a?.displayName ?? a?.agentId ?? a?.agent_id ?? a?.id ?? '',
    );
  }

  function bridgeVal(b: any): string {
    return String(b?.bridge_id ?? b?.bridgeId ?? '');
  }

  function agentVal(a: any): string {
    return String(a?.agentId ?? a?.agent_id ?? a?.id ?? '');
  }

  return (
    <Modal
      open={isOpen}
      onOpenChange={(next) => { if (!next) onClose(); }}
      title="Start new chain"
      size="sm"
    >
      <Modal.Body className="space-y-4 px-5 py-4">
        {error ? (
          <div className="rounded-xl border border-danger/30 bg-danger-soft px-3 py-2 text-sm text-danger">
            {error}
          </div>
        ) : null}

        {/* Bridge */}
        <div className="space-y-1">
          <label className="text-[11.5px] font-semibold text-muted">Bridge</label>
          <Select value={bridgeId} onChange={setBridgeId} disabled={loading || bridges.length === 0}>
            {bridges.length === 0 ? (
              <option value="">No bridges available</option>
            ) : (
              bridges.map((b: any) => (
                <option key={bridgeVal(b)} value={bridgeVal(b)}>
                  {bridgeLabel(b)}
                </option>
              ))
            )}
          </Select>
        </div>

        {/* Coordinator agent */}
        <div className="space-y-1">
          <label className="text-[11.5px] font-semibold text-muted">Coordinator agent</label>
          <Select value={agentId} onChange={setAgentId} disabled={loading || agentList.length === 0}>
            {agentList.length === 0 ? (
              <option value="">No agents available</option>
            ) : (
              agentList.map((a: any) => (
                <option key={agentVal(a)} value={agentVal(a)}>
                  {agentLabel(a)}
                </option>
              ))
            )}
          </Select>
        </div>

        {/* Provider */}
        <div className="space-y-1">
          <label className="text-[11.5px] font-semibold text-muted">Provider</label>
          <Select value={provider} onChange={setProvider} disabled={loading}>
            {PROVIDERS.map((p) => (
              <option key={p} value={p}>{p}</option>
            ))}
          </Select>
        </div>

        {/* Tier */}
        <div className="space-y-1">
          <label className="text-[11.5px] font-semibold text-muted">Tier</label>
          <Select value={tier} onChange={setTier} disabled={loading}>
            {TIERS.map((t) => (
              <option key={t} value={t}>{t}</option>
            ))}
          </Select>
        </div>
      </Modal.Body>

      <Modal.Footer>
        <Button variant="ghost" onClick={onClose} disabled={loading}>
          Cancel
        </Button>
        <Button
          variant="primary"
          onClick={handleSubmit}
          disabled={loading || !agentId}
        >
          {loading ? 'Starting…' : 'Start chain →'}
        </Button>
      </Modal.Footer>
    </Modal>
  );
}
