import React, { useEffect, useState } from 'react';
import { Alert, Button, FormField, IconButton, Input, Select, Text, Textarea } from '@ui';
import { ChainPlacementField, useChainPlacementChoices } from './ChainPlacementField';
import { COORDINATOR_STAGE_TEXT, defaultCoordinatorAgentId, hubCoordinatorApi, type CoordinatorAgentChoice, type OwnerCoordinatorApi } from './OwnerCoordinatorControl';
import { createOwnerChain, freshOwnerSession, ownerErrorMessage, waitForOwnerChainListed, type OwnerChainSummary, type OwnerRegistryWaitOptions } from '../../api/ownerChains';
import { bindOwnerCoordinator, createChainWithCoordinator, type NewChainCoordinatorStage } from '../../api/ownerCoordinator';

export interface CreateChainModalProps {
  isOpen: boolean;
  onClose: () => void;
  /** `owner` is the new chain's summary on its owner Bridge. */
  onCreated?: (chainId: string, owner?: OwnerChainSummary) => void;
  /** Hub calls of the coordinator launch; tests replace them. */
  coordinatorApi?: OwnerCoordinatorApi;
  /** Registry wait options; tests replace the clock. */
  registryWait?: OwnerRegistryWaitOptions;
}

/**
 * Creates a Bridge-owned task chain: a signed chain.create with a device-signed
 * genesis through the owner relay (the Hub no longer stores chains). Then it
 * starts the chain's coordinator: once the chain is in the owner registry, an
 * instance of the chosen agent (the coordinator agent by default) launches on
 * the owner Bridge bound to the chain, and is bound with chain.member.set.
 */
export const CreateChainModal: React.FC<CreateChainModalProps> = ({ isOpen, onClose, onCreated, coordinatorApi = hubCoordinatorApi, registryWait }) => {
  const [title, setTitle] = useState('');
  const [description, setDescription] = useState('');
  const [submitError, setSubmitError] = useState('');
  // Placement defaults to the user's online Bridge until they choose.
  const placementState = useChainPlacementChoices(isOpen);
  const [placementChoice, setPlacementChoice] = useState('');
  const [creating, setCreating] = useState(false);
  const [agents, setAgents] = useState<CoordinatorAgentChoice[] | null>(null);
  const [agentId, setAgentId] = useState('');
  const [stage, setStage] = useState<NewChainCoordinatorStage | ''>('');
  // A chain created whose coordinator did not start; the user can still open it.
  const [created, setCreated] = useState<OwnerChainSummary | null>(null);
  const placement = placementChoice || placementState.initial;
  const choice = placementState.choices.find((c) => c.bridgeId === placement);
  const placementReady = Boolean(choice?.online);

  // A reopened modal starts a new chain.
  useEffect(() => { if (!isOpen) { setCreated(null); setStage(''); setSubmitError(''); } }, [isOpen]);
  useEffect(() => {
    if (!isOpen || agents) return;
    let live = true;
    coordinatorApi.listAgents().then(
      (list) => { if (live) { setAgents(list); setAgentId((current) => current || defaultCoordinatorAgentId(list)); } },
      (e) => { if (live) { setAgents([]); setSubmitError(e instanceof Error ? e.message : String(e)); } },
    );
    return () => { live = false; };
  }, [isOpen, agents, coordinatorApi]);

  if (!isOpen) return null;

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    if (created) { onCreated?.(created.chainId, created); return; }
    if (!title.trim() || !placementReady || !agentId || creating) return;
    setSubmitError('');
    setCreating(true);
    // Set by the chain.create step (a closure, so not a narrowed local).
    const made: { owner: OwnerChainSummary | null } = { owner: null };
    try {
      const session = await freshOwnerSession();
      const { chainId, instanceId } = await createChainWithCoordinator({
        createChain: () => createOwnerChain(session, placement, { title: title.trim(), description: description.trim() }),
        onChainCreated: (chainId) => {
          made.owner = {
            chainId, ownerBridgeId: placement, bridgeName: choice?.name || placement, online: true,
            title: title.trim(), description: description.trim(), sealed: false, tasks: [],
            projectId: '', projectName: '', migrated: false, pending: true, status: 'active',
          };
        },
        waitListed: (chainId) => waitForOwnerChainListed(chainId, registryWait),
        launch: (chainId) => coordinatorApi.launch({ agentId, chainId, bridgeId: placement }),
        status: coordinatorApi.status,
        restart: coordinatorApi.restart,
        bind: (chainId, id) => bindOwnerCoordinator(session, placement, chainId, id, agentId),
        onStage: (s) => setStage(s),
      });
      onCreated?.(chainId, { ...made.owner!, coordinatorAgentInstanceId: instanceId });
    } catch (err) {
      setStage('');
      if (made.owner) {
        setCreated(made.owner);
        setSubmitError(`The chain was created, but its coordinator did not start: ${err instanceof Error ? err.message : String(err)} Open the chain to start one.`);
      } else {
        setSubmitError(ownerErrorMessage(err, choice?.name));
      }
    } finally {
      setCreating(false);
    }
  };

  return (
    <div
      data-debug-id="create-chain-modal"
      className="fixed inset-0 z-50 flex items-center justify-center bg-black/60 p-4"
    >
      <div role="dialog" aria-modal="true" aria-labelledby="create-chain-title" className="w-full max-w-lg space-y-4 rounded-[var(--radius-xl)] border border-subtle bg-surface-raised p-6 text-left shadow-2xl">
        <div className="flex items-center justify-between border-b border-subtle pb-3">
          <Text as="h2" role="heading" id="create-chain-title">New task chain</Text>
          <IconButton icon="close" label="Close" size="sm" onClick={onClose} />
        </div>

        <form onSubmit={handleSubmit} className="space-y-4">
          <ChainPlacementField value={placement} onChange={setPlacementChoice} state={placementState} />

          <FormField label="Coordinator">
            <Select
              data-debug-id="create-chain-coordinator-agent"
              name="coordinator_agent"
              width="full"
              value={agentId}
              disabled={creating || Boolean(created) || !agents?.length}
              onChange={setAgentId}
              placeholder={!agents ? 'Loading agents…' : 'No agents'}
              options={(agents ?? []).map((a) => ({ value: a.agentId, label: a.name }))}
            />
          </FormField>

          <FormField label="Title">
            <Input
              required
              value={title}
              onChange={setTitle}
              placeholder="e.g. PTY streaming network optimization"
            />
          </FormField>

          <FormField label="Description">
            <Textarea
              value={description}
              onChange={setDescription}
              placeholder="Overview of the tickets, objectives, and acceptance guidelines…"
              rows={2}
            />
          </FormField>

          {stage && (
            <Text as="p" role="caption" tone="muted" aria-live="polite" data-debug-id="create-chain-stage">{COORDINATOR_STAGE_TEXT[stage]}</Text>
          )}

          {submitError && (
            <div data-debug-id="create-chain-error"><Alert tone="danger">{submitError}</Alert></div>
          )}

          <div className="flex items-center justify-end gap-2 border-t border-subtle pt-3">
            <Button type="button" variant="secondary" onClick={onClose}>Cancel</Button>
            <Button
              type="submit"
              variant="primary"
              data-debug-id="create-chain-submit"
              disabled={!created && (creating || !title.trim() || !placementReady || !agentId)}
            >
              {created ? 'Open chain' : creating ? 'Creating…' : 'Create chain'}
            </Button>
          </div>
        </form>
      </div>
    </div>
  );
};

export default CreateChainModal;
