// The "On your Bridges" group of the chain list: Bridge-owned chains (native
// and moved-from-Hub) built from the owner registry, with an owner badge and
// the owner Bridge's online state.

import React from 'react';
import { Badge, StatusDot } from '@ui';
import Icon from '../Icon';
import type { OwnerChainSummary } from '../../api/ownerChains';

export type ChainStatusFilter = 'active' | 'completed' | 'archived' | 'all';

/**
 * Which owner chains a list filter keeps. The registry carries no chain status,
 * so owner chains show under Active and All only; a project filter keeps the
 * chains whose (migrated) Hub placement matched it.
 */
export function filterOwnerChains(
  chains: OwnerChainSummary[],
  f: { query: string; status: ChainStatusFilter; projectId: string; onlyWithTasks: boolean; kind: 'all' | 'ticket' | 'workflow' },
): OwnerChainSummary[] {
  const q = f.query.trim().toLowerCase();
  return chains.filter((c) => {
    if (f.status === 'completed' || f.status === 'archived') return false;
    if (f.kind === 'workflow') return false;
    if (f.projectId && c.projectId !== f.projectId) return false;
    if (f.onlyWithTasks && c.tasks.length === 0 && !c.pending) return false;
    if (!q) return true;
    return c.chainId.toLowerCase().includes(q) || c.title.toLowerCase().includes(q)
      || c.tasks.some((t) => t.title.toLowerCase().includes(q));
  });
}

export function OwnerChainRow({ chain, active, onSelect }: { chain: OwnerChainSummary; active: boolean; onSelect: (chainId: string) => void }) {
  return (
    <div data-debug-id={`task-chains-owner-row-${chain.chainId}`}
      className={`rounded-xl border px-3 py-2.5 transition-colors ${active ? 'border-accent/40 bg-accent/10' : 'border-subtle bg-surface hover:bg-surface-raised'}`}>
      <button type="button" data-debug-id={`task-chains-owner-open-${chain.chainId}`} onClick={() => onSelect(chain.chainId)} className="block w-full min-w-0 text-left">
        <span className="block min-w-0 truncate text-sm text-primary">{chain.title || chain.chainId}</span>
        <span className="mt-1 flex min-w-0 flex-wrap items-center gap-2">
          <Badge tone="info" data-debug-id={`task-chains-owner-badge-${chain.chainId}`}>Bridge-owned</Badge>
          <span className="inline-flex items-center gap-1 text-caption text-muted" data-debug-id={`task-chains-owner-state-${chain.chainId}`}>
            <StatusDot size="sm" tone={chain.online ? 'success' : 'neutral'} label={chain.online ? 'Owner online' : 'Owner offline'} />
            {chain.bridgeName} · {chain.online ? 'online' : 'offline'}
          </span>
          {chain.migrated && <Badge tone="neutral">Moved from Hub</Badge>}
          {chain.pending && <Badge tone="pending">Registering</Badge>}
          <span className="shrink-0 rounded-md border border-subtle bg-surface-raised px-1.5 py-0.5 text-caption text-muted"
            title={`${chain.tasks.length} ${chain.tasks.length === 1 ? 'ticket' : 'tickets'}`}>{chain.tasks.length}</span>
        </span>
      </button>
    </div>
  );
}

export function OwnerChainsGroup({ chains, activeChainId, onSelect, loading, error, collapsed, onToggle }: {
  chains: OwnerChainSummary[]; activeChainId: string; onSelect: (chainId: string) => void;
  loading: boolean; error?: string; collapsed: boolean; onToggle: () => void;
}) {
  return (
    <div data-debug-id="task-chains-owner-group" className="overflow-hidden rounded-2xl border border-subtle bg-surface">
      <div className="flex items-center justify-between gap-2 border-b border-subtle bg-surface-raised px-4 py-3">
        <button type="button" data-debug-id="task-chains-owner-group-toggle" onClick={onToggle} className="flex min-w-0 flex-1 items-center gap-3 text-left">
          <span className="shrink-0 text-muted"><Icon name={collapsed ? 'chevron-right' : 'chevron-down'} size={14} /></span>
          <span className="truncate text-sm font-semibold text-primary">On your Bridges</span>
        </button>
        <span data-debug-id="task-chains-owner-count" className="rounded-md border border-subtle bg-surface px-2 py-0.5 text-xs text-muted">
          {chains.length} {chains.length === 1 ? 'chain' : 'chains'}
        </span>
      </div>
      {!collapsed && (
        <div className="space-y-2 p-4">
          {error && <p role="status" className="text-xs text-muted">Could not load Bridge-owned chains. Reload to try again.</p>}
          {loading && chains.length === 0 && <p role="status" className="text-xs text-muted">Loading Bridge-owned chains…</p>}
          {chains.map((c) => <OwnerChainRow key={c.chainId} chain={c} active={activeChainId === c.chainId} onSelect={onSelect} />)}
        </div>
      )}
    </div>
  );
}
