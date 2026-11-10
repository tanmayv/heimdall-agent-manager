import React, { useEffect, useState } from 'react';
import { Alert, Button, FormField, IconButton, Input, SectionHeader, Select, Text, Textarea } from '@ui';
import { ChainPlacementField, useChainPlacementChoices } from './ChainPlacementField';
import { defaultCoordinatorAgentId, hubCoordinatorApi, type CoordinatorAgentChoice, type OwnerCoordinatorApi } from './OwnerCoordinatorControl';
import type { OwnerChainSummary } from '../../api/ownerChains';
import { useCreateLaunchConversationMutation } from '../../api/endpoints/chats';

export interface CreateChainModalProps {
  isOpen: boolean;
  onClose: () => void;
  /** `owner` is the new chain's summary on its owner Bridge. */
  onCreated?: (chainId: string, owner?: OwnerChainSummary) => void;
  /** The coordinator agent list; tests replace it. */
  coordinatorApi?: Pick<OwnerCoordinatorApi, 'listAgents'>;
}

/** The Bridge the last chain was placed on; the next chain defaults to it. */
export const LAST_CHAIN_PLACEMENT_KEY = 'heimdall:last-chain-placement';

function readLastPlacement(): string {
  try { return window.localStorage.getItem(LAST_CHAIN_PLACEMENT_KEY) || ''; } catch { return ''; }
}

function rememberPlacement(bridgeId: string): void {
  try { window.localStorage.setItem(LAST_CHAIN_PLACEMENT_KEY, bridgeId); } catch { /* per-device convenience only */ }
}

/**
 * Creates a Bridge-owned task chain with its coordinator in ONE request, the
 * same one a coordinator New conversation makes: POST /chats with
 * create_owner_chain. The placement Bridge creates the chain with its owner
 * key and the coordinator boots bound to it; the title and description travel
 * sealed. Nothing is left behind when the Bridge refuses.
 */
export const CreateChainModal: React.FC<CreateChainModalProps> = ({ isOpen, onClose, onCreated, coordinatorApi = hubCoordinatorApi }) => {
  const [launch] = useCreateLaunchConversationMutation();
  const [title, setTitle] = useState('');
  const [description, setDescription] = useState('');
  const [submitError, setSubmitError] = useState('');
  // Placement defaults to the user's online Bridge until they choose.
  const placementState = useChainPlacementChoices(isOpen);
  const [placementChoice, setPlacementChoice] = useState('');
  const [creating, setCreating] = useState(false);
  const [agents, setAgents] = useState<CoordinatorAgentChoice[] | null>(null);
  const [agentId, setAgentId] = useState('');
  const [advancedOpen, setAdvancedOpen] = useState(false);
  // The last-used Bridge while it is online, else the placement default.
  const lastPlacement = readLastPlacement();
  const lastOnline = placementState.choices.some((c) => c.bridgeId === lastPlacement && c.online);
  const placement = placementChoice || (lastOnline ? lastPlacement : placementState.initial);
  const choice = placementState.choices.find((c) => c.bridgeId === placement);
  const placementReady = Boolean(choice?.online);
  // Advanced opens itself when its defaults cannot be used, so the reason shows.
  const advancedShown = advancedOpen || (!placementState.loading && !placementReady) || (agents !== null && !agentId);

  // A reopened modal starts a new chain.
  useEffect(() => { if (!isOpen) setSubmitError(''); }, [isOpen]);
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
    if (!title.trim() || !placementReady || !agentId || creating) return;
    setSubmitError('');
    setCreating(true);
    rememberPlacement(placement);
    try {
      const result = await launch({ agentId, bridgeId: placement, createOwnerChain: true, chainTitle: title.trim(), chainDescription: description.trim(), body: '' }).unwrap();
      const chainId = String(result.conversation?.chain_id || result.instance?.chain_id || '');
      const instanceId = String(result.conversation?.agent_instance_id || result.instance?.agent_instance_id || '');
      if (!chainId) throw new Error('The Bridge did not return the new chain.');
      onCreated?.(chainId, {
        chainId, ownerBridgeId: placement, bridgeName: choice?.name || placement, online: true,
        title: title.trim(), description: description.trim(), sealed: false, tasks: [],
        projectId: '', projectName: '', migrated: false, pending: true, status: 'active', coordinatorAgentInstanceId: instanceId || undefined,
      });
    } catch (err: any) {
      setSubmitError(String(err?.error || err?.message || err));
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

          <section className="space-y-3">
            <SectionHeader
              level="h3"
              title="Advanced"
              description={[choice?.name || placement, agents?.find((a) => a.agentId === agentId)?.name].filter(Boolean).join(' · ') || undefined}
              collapsible
              expanded={advancedShown}
              onToggle={setAdvancedOpen}
              controls="create-chain-advanced"
            />
            {advancedShown && (
              <div id="create-chain-advanced" data-debug-id="create-chain-advanced" className="space-y-4">
                <ChainPlacementField value={placement} onChange={setPlacementChoice} state={placementState} />

                <FormField label="Coordinator">
                  <Select
                    data-debug-id="create-chain-coordinator-agent"
                    name="coordinator_agent"
                    width="full"
                    value={agentId}
                    disabled={creating || !agents?.length}
                    onChange={setAgentId}
                    placeholder={!agents ? 'Loading agents…' : 'No agents'}
                    options={(agents ?? []).map((a) => ({ value: a.agentId, label: a.name }))}
                  />
                </FormField>
              </div>
            )}
          </section>

          {submitError && (
            <div data-debug-id="create-chain-error"><Alert tone="danger">{submitError}</Alert></div>
          )}

          <div className="flex items-center justify-end gap-2 border-t border-subtle pt-3">
            <Button type="button" variant="secondary" onClick={onClose}>Cancel</Button>
            <Button
              type="submit"
              variant="primary"
              data-debug-id="create-chain-submit"
              disabled={creating || !title.trim() || !placementReady || !agentId}
            >
              {creating ? 'Creating…' : 'Create chain'}
            </Button>
          </div>
        </form>
      </div>
    </div>
  );
};

export default CreateChainModal;
