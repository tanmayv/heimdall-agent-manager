import React, { useEffect, useState } from 'react';
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
 * listed online chain whose member rows are not read yet is read on demand.
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
  const lookingUp = owners.status === 'loading' || (unread && readChainId !== chainId);
  return (
    <div
      data-debug-id="chain-pane-no-coordinator"
      role="status"
      className="flex h-full w-full flex-col items-center justify-center gap-3 px-6 text-center text-sm text-muted"
    >
      <p>{lookingUp ? 'Looking up the chain’s coordinator…' : 'This chain has no coordinator yet. Open the chain to start one.'}</p>
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
