import React, { useEffect, useState } from 'react';
import { ownerCoordinatorState } from '../../api/ownerChains';
import { resolveOwnerChainCoordinator, useOwnerChains } from '../../api/ownerChainsStore';
import { buildRouteHash } from '../../utils/appLocation';

export interface ChainCoordinatorPaneProps {
  chainId: string;
  /** Renders the chat for the chain's coordinator instance. */
  children?: (coordinatorAgentInstanceId: string, chainTitle: string) => React.ReactNode;
}

/**
 * A Main pane addressed by chain (`chain:<id>`, REQ-TV2-7). Chains are
 * Bridge-owned: the coordinator is the instance bound with role coordinator in
 * the owner's member rows (read into the shared owner chain snapshot). Without
 * one the pane points to the chain, where Start coordinator binds one. A
 * listed online chain whose coordinator is not known yet is read on demand;
 * until then (or while its owner is offline) the pane says so, never "none".
 */
export function ChainCoordinatorPane({ chainId, children }: ChainCoordinatorPaneProps) {
  const owners = useOwnerChains();
  const chain = owners.chains.find((c) => c.chainId === chainId);
  const coordinatorId = chain?.coordinatorAgentInstanceId || '';
  const unread = Boolean(chain && chain.coordinatorAgentInstanceId === undefined && chain.online && !chain.pending);
  // The chain whose on-demand read finished (a failed read stays unread).
  const [readChainId, setReadChainId] = useState('');
  useEffect(() => {
    if (!unread) return;
    let cancelled = false;
    void resolveOwnerChainCoordinator(chainId).then(() => { if (!cancelled) setReadChainId(chainId); });
    return () => { cancelled = true; };
  }, [unread, chainId]);
  if (coordinatorId && children) return <>{children(coordinatorId, chain?.title || chainId)}</>;
  const coordinator = ownerCoordinatorState(chain);
  // Unknown is never "no coordinator": it is looked up (or the owner is offline).
  const lookingUp = (chain ? coordinator.kind === 'loading' : owners.status === 'loading') || (unread && readChainId !== chainId);
  const text = lookingUp ? 'Looking up the chain’s coordinator…'
    : coordinator.kind === 'offline' ? `The chain’s owner Bridge ${chain?.bridgeName || chain?.ownerBridgeId} is offline, so its coordinator cannot be looked up.`
    : coordinator.kind === 'failed' ? 'The chain’s coordinator could not be looked up on its owner Bridge. Open the chain to try again or start one.'
    : 'This chain has no coordinator yet. Open the chain to start one.';
  return (
    <div
      data-debug-id="chain-pane-no-coordinator"
      data-coordinator-state={lookingUp ? 'loading' : chain ? coordinator.kind : 'none'}
      role="status"
      className="flex h-full w-full flex-col items-center justify-center gap-3 px-6 text-center text-sm text-muted"
    >
      <p>{text}</p>
      <a
        href={buildRouteHash(`/chains/${encodeURIComponent(chainId)}`, '')}
        className="rounded-lg border border-subtle px-3 py-1.5 text-primary hover:bg-neutral-soft"
      >
        Open task chain
      </a>
    </div>
  );
}

export default ChainCoordinatorPane;
