import React from 'react';
import { buildRouteHash } from '../../utils/appLocation';

export interface ChainCoordinatorPaneProps {
  chainId: string;
  /** Renders the chat for the chain's coordinator instance (unused: see below). */
  children?: (coordinatorAgentInstanceId: string, chainTitle: string) => React.ReactNode;
}

/**
 * A Main pane addressed by chain (`chain:<id>`, REQ-TV2-7). Its coordinator was
 * resolved through the Hub's GET /task-chains/{id}/conversation, which is gone
 * with the Hub task chains, so the pane now points to the chain on its Bridge.
 */
export function ChainCoordinatorPane({ chainId }: ChainCoordinatorPaneProps) {
  return (
    <div
      data-debug-id="chain-pane-no-coordinator"
      role="status"
      className="flex h-full w-full flex-col items-center justify-center gap-3 px-6 text-center text-sm text-muted"
    >
      <p>Chain conversations are no longer resolved by the Hub. Open the chain to see its tickets.</p>
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
