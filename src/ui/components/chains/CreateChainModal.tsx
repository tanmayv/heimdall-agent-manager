import { useState, useEffect } from 'react';
import { Modal, Select, Button } from '@ui';
import { useCreateTaskChainMutation, useUpdateTaskChainMutation } from '../../api/endpoints/tasks';
import {
  useCreateAgentInstanceInChainMutation,
  useListAgentIdentitiesQuery,
} from '../../api/endpoints/agents';
import {
  useListBridgesQuery,
  normalizeBridgeCapabilities,
} from '../../api/endpoints/bridgeSupport';

const FALLBACK_PROVIDERS = ['jetski', 'claude', 'pi', 'anthropic', 'openai'];
const FALLBACK_TIERS = ['cheap', 'normal', 'smart'];

type Props = {
  projectId: string;
  isOpen: boolean;
  onClose: () => void;
  onCreated: (conversationPath: string) => void;
};

function isCoordinator(a: any): boolean {
  const templateId = String(a?.template_id ?? a?.templateId ?? '');
  const role = String(a?.role ?? '');
  const name = String(a?.name ?? '').toLowerCase();
  const slug = String(a?.slug ?? '').toLowerCase();
  const id = String(a?.agent_id ?? a?.agentId ?? a?.id ?? '').toLowerCase();

  return (
    templateId === 'tmpl_coordinator' ||
    templateId.toLowerCase().includes('coordinator') ||
    role.toLowerCase().includes('coordinator') ||
    name.includes('coordinator') ||
    slug.includes('coordinator') ||
    id.includes('coordinator')
  );
}

function bridgeVal(b: any): string {
  return String(b?.bridge_id ?? b?.bridgeId ?? '');
}

function bridgeLabel(b: any): string {
  const label = String(b?.label ?? b?.display_name ?? b?.displayName ?? '');
  const id = bridgeVal(b);
  const online = String(b?.status ?? b?.runtime_status ?? b?.state ?? '')
    .toLowerCase()
    .includes('online');
  const tag = online ? '● online' : '○ offline';
  return `${label || id} (${tag})`;
}

function agentVal(a: any): string {
  return String(a?.agent_id ?? a?.agentId ?? a?.id ?? '');
}

function agentLabel(a: any): string {
  const id = agentVal(a);
  const name = String(a?.name ?? a?.display_name ?? a?.displayName ?? a?.slug ?? id);
  return id ? `${name} (${id})` : name;
}

export default function CreateChainModal({ projectId, isOpen, onClose, onCreated }: Props) {
  const bridgesQuery = useListBridgesQuery(undefined, { skip: !isOpen });
  const agentsQuery = useListAgentIdentitiesQuery(undefined, { skip: !isOpen });

  const bridges = (bridgesQuery.data?.bridges ?? []).filter(
    (b: any) => !String(b?.status || b?.runtime_status || b?.state || '').includes('revoke'),
  );

  const allAgents = agentsQuery.data?.agents ?? [];
  const activeAgents = allAgents.filter(
    (a: any) => String(a?.state ?? '').toLowerCase() !== 'archived',
  );
  const agents = activeAgents.length > 0 ? activeAgents : allAgents;

  const coordinatorAgents = agents.filter(isCoordinator);
  const agentList = coordinatorAgents.length > 0 ? coordinatorAgents : agents;

  const defaultBridgeId = bridgeVal(bridges[0]);
  const defaultAgentId = agentVal(agentList[0]);

  const [bridgeId, setBridgeId] = useState('');
  const [agentId, setAgentId] = useState('');
  const [provider, setProvider] = useState<string>('jetski');
  const [tier, setTier] = useState<string>('smart');
  const [error, setError] = useState('');

  // Selected bridge and dynamic capabilities
  const selectedBridge = bridges.find((b: any) => bridgeVal(b) === bridgeId) ?? bridges[0];
  const capabilities = normalizeBridgeCapabilities(selectedBridge);

  const bridgeProviders = Array.from(
    new Set(capabilities.map((c) => c.provider).filter(Boolean)),
  );
  const providers = bridgeProviders.length > 0 ? bridgeProviders : FALLBACK_PROVIDERS;

  const selectedCap = capabilities.find((c) => c.provider === provider);
  const capTiers = Array.from(
    new Set([
      ...(selectedCap?.tiers ?? []),
      ...(selectedCap?.defaultTier ? [selectedCap.defaultTier] : []),
    ]),
  ).filter(Boolean);
  const tiers = capTiers.length > 0 ? capTiers : FALLBACK_TIERS;

  // Pre-select defaults once data loads
  useEffect(() => {
    if (defaultBridgeId && (!bridgeId || !bridges.some((b: any) => bridgeVal(b) === bridgeId))) {
      setBridgeId(defaultBridgeId);
    }
  }, [defaultBridgeId, bridges, bridgeId]);

  useEffect(() => {
    if (defaultAgentId && (!agentId || !agentList.some((a: any) => agentVal(a) === agentId))) {
      setAgentId(defaultAgentId);
    }
  }, [defaultAgentId, agentList, agentId]);

  // Keep provider synchronized with supported providers
  useEffect(() => {
    if (providers.length > 0 && !providers.includes(provider)) {
      setProvider(providers.includes('jetski') ? 'jetski' : providers[0]);
    }
  }, [providers, provider]);

  // Keep tier synchronized with supported tiers, preferring 'smart' when available
  useEffect(() => {
    if (tiers.length > 0 && !tiers.includes(tier)) {
      const preferredTier = tiers.includes('smart')
        ? 'smart'
        : (selectedCap?.defaultTier && tiers.includes(selectedCap.defaultTier)
            ? selectedCap.defaultTier
            : tiers[0]);
      setTier(preferredTier);
    }
  }, [tiers, tier, selectedCap]);

  useEffect(() => {
    if (!isOpen) {
      setError('');
    }
  }, [isOpen]);

  const [createChain, createChainState] = useCreateTaskChainMutation();
  const [createInstance, createInstanceState] = useCreateAgentInstanceInChainMutation();
  const [updateChain] = useUpdateTaskChainMutation();

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
        coordinatorAgentId: agentId,
        bridgeId: bridgeId || undefined,
        provider: provider,
        tier: tier,
        projectId,
      }).unwrap();

      let instanceId = String(
        chainResult?.coordinator_agent_instance_id ??
          chainResult?.coordinatorAgentInstanceId ??
          chainResult?.data?.coordinator_agent_instance_id ??
          chainResult?.data?.coordinatorAgentInstanceId ??
          '',
      );

      if (!instanceId) {
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
        instanceId = String(
          instanceResult?.agent_instance_id ??
            instanceResult?.agentInstanceId ??
            instanceResult?.data?.agent_instance_id ??
            '',
        );
        if (instanceId) {
          await updateChain({ chainId, coordinatorAgentInstanceId: instanceId }).unwrap();
        }
      }

      if (!instanceId) throw new Error('Agent instance creation returned no instance ID');

      onCreated('/conversations/' + instanceId);
    } catch (err: any) {
      setError(String(err?.message || err?.error || 'Failed to start chain'));
    }
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
        <div className="space-y-1.5">
          <label className="text-xs font-semibold text-muted">Bridge</label>
          <Select
            width="full"
            value={bridgeId}
            onChange={(val) => {
              setBridgeId(val);
              setProvider('');
              setTier('');
            }}
            disabled={loading || bridges.length === 0}
          >
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
        <div className="space-y-1.5">
          <label className="text-xs font-semibold text-muted">Coordinator agent</label>
          <Select
            width="full"
            value={agentId}
            onChange={setAgentId}
            disabled={loading || agentList.length === 0}
          >
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
        <div className="space-y-1.5">
          <label className="text-xs font-semibold text-muted">Provider</label>
          <Select
            width="full"
            value={provider}
            onChange={(val) => {
              setProvider(val);
              setTier('');
            }}
            disabled={loading || providers.length === 0}
          >
            {providers.map((p) => (
              <option key={p} value={p}>{p}</option>
            ))}
          </Select>
        </div>

        {/* Tier */}
        <div className="space-y-1.5">
          <label className="text-xs font-semibold text-muted">Tier</label>
          <Select
            width="full"
            value={tier}
            onChange={setTier}
            disabled={loading || tiers.length === 0}
          >
            {tiers.map((t) => (
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
          disabled={loading || !agentId || !provider || !tier}
        >
          {loading ? 'Starting…' : 'Start chain →'}
        </Button>
      </Modal.Footer>
    </Modal>
  );
}
