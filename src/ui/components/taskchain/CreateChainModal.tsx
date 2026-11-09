import React, { useState } from 'react';
import { ChainPlacementField, useChainPlacementChoices } from './ChainPlacementField';
import { createOwnerChain, freshOwnerSession, ownerErrorMessage, type OwnerChainSummary } from '../../api/ownerChains';

export interface CreateChainModalProps {
  isOpen: boolean;
  onClose: () => void;
  /** `owner` is the new chain's summary on its owner Bridge. */
  onCreated?: (chainId: string, owner?: OwnerChainSummary) => void;
}

/**
 * Creates a Bridge-owned task chain: a signed chain.create with a device-signed
 * genesis through the owner relay. The Hub no longer stores chains.
 */
export const CreateChainModal: React.FC<CreateChainModalProps> = ({ isOpen, onClose, onCreated }) => {
  const [title, setTitle] = useState('');
  const [description, setDescription] = useState('');
  const [submitError, setSubmitError] = useState('');
  // Placement defaults to the user's online Bridge until they choose.
  const placementState = useChainPlacementChoices(isOpen);
  const [placementChoice, setPlacementChoice] = useState('');
  const [creating, setCreating] = useState(false);
  const placement = placementChoice || placementState.initial;
  const choice = placementState.choices.find((c) => c.bridgeId === placement);
  const placementReady = Boolean(choice?.online);

  if (!isOpen) return null;

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!title.trim() || !placementReady || creating) return;
    setSubmitError('');
    setCreating(true);
    try {
      const session = await freshOwnerSession();
      const chainId = await createOwnerChain(session, placement, { title: title.trim(), description: description.trim() });
      onCreated?.(chainId, {
        chainId, ownerBridgeId: placement, bridgeName: choice?.name || placement, online: true,
        title: title.trim(), description: description.trim(), sealed: false, tasks: [],
        projectId: '', projectName: '', migrated: false, pending: true, status: 'active',
      });
    } catch (err) {
      setSubmitError(ownerErrorMessage(err, choice?.name));
    } finally {
      setCreating(false);
    }
  };

  return (
    <div
      data-debug-id="create-chain-modal"
      className="fixed inset-0 z-50 flex items-center justify-center bg-black/60 p-4"
    >
      <div className="w-full max-w-lg rounded-2xl border border-subtle bg-surface p-6 text-left shadow-2xl space-y-4">
        <div className="flex items-center justify-between border-b border-subtle pb-3">
          <h2 className="text-base font-bold text-primary">New Task Chain</h2>
          <button
            type="button"
            onClick={onClose}
            aria-label="Close"
            className="text-faint hover:text-primary text-sm font-bold"
          >
            ✕
          </button>
        </div>

        <form onSubmit={handleSubmit} className="space-y-4 text-xs">
          <ChainPlacementField value={placement} onChange={setPlacementChoice} state={placementState} />

          <label className="flex flex-col gap-1 text-muted">
            <span className="font-semibold text-[11px]">Title</span>
            <input
              type="text"
              required
              value={title}
              onChange={(e) => setTitle(e.target.value)}
              placeholder="e.g. PTY streaming network optimization"
              className="rounded-lg border border-subtle bg-canvas px-3 py-2 text-primary text-xs outline-none focus:border-accent"
            />
          </label>

          <label className="flex flex-col gap-1 text-muted">
            <span className="font-semibold text-[11px]">Description</span>
            <textarea
              value={description}
              onChange={(e) => setDescription(e.target.value)}
              placeholder="Overview of the tickets, objectives, and acceptance guidelines…"
              rows={2}
              className="rounded-lg border border-subtle bg-canvas p-2.5 text-primary text-xs outline-none focus:border-accent"
            />
          </label>

          {submitError && (
            <p role="alert" data-debug-id="create-chain-error" className="whitespace-normal text-[11px] text-danger">
              {submitError}
            </p>
          )}

          <div className="flex items-center justify-end gap-2 pt-3 border-t border-subtle">
            <button
              type="button"
              onClick={onClose}
              className="rounded-lg border border-subtle bg-surface px-3 py-2 text-xs font-semibold text-muted hover:text-primary transition-colors"
            >
              Cancel
            </button>
            <button
              type="submit"
              disabled={creating || !title.trim() || !placementReady}
              className="rounded-lg bg-accent px-4 py-2 text-xs font-semibold text-accent-fg hover:opacity-90 transition-opacity disabled:opacity-50"
            >
              {creating ? 'Creating…' : 'Create Ticket Chain'}
            </button>
          </div>
        </form>
      </div>
    </div>
  );
};

export default CreateChainModal;
