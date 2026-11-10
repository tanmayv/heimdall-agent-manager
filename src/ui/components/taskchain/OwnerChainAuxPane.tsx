// The chain panes of a coordinator conversation's aux dock (Chain overview,
// Tickets board, one ticket) for a Bridge-owned chain. Each is the owner chain
// view in one layout, backed by the same signed owner reads as the Task Chains
// page; the chain itself comes from the shared owner registry snapshot.

import React, { useEffect, useRef } from 'react';
import { ButtonLink, EmptyState, Spinner } from '@ui';
import type { OwnerSend } from '../../api/ownerChains';
import { useOwnerChains } from '../../api/ownerChainsStore';
import type { OwnerSession } from '../../api/ownerLocalClient';
import { buildRouteHash, navigateTo } from '../../utils/appLocation';
import { ChainTokenUsageSection } from './ChainTokenUsage';
import { OwnerChainView } from './OwnerChainView';

/** Owner chains have no push events: the aux panes re-read their owner this often while visible. */
export const OWNER_AUX_REFRESH_MS = 30_000;

/** Opens an agent's conversation in Main (with the tasks panel on desktop). */
export function openAgentConversation(instanceId: string, isMobile = false): void {
  if (!instanceId) return;
  navigateTo(buildRouteHash(`/conversations/${encodeURIComponent(instanceId)}`, isMobile ? '' : '?panel=tasks'));
  if (isMobile) window.dispatchEvent(new CustomEvent('heimdall:close-sidebar'));
}

export interface OwnerChainAuxPaneProps {
  chainId: string;
  layout: 'overview' | 'board' | 'ticket';
  /** Ticket layout: the ticket shown. Board layout: a ticket to open once. */
  taskId?: string;
  onOpenTicket: (taskId: string, title: string) => void;
  onShowBoard?: () => void;
  onSwitchTicket?: (taskId: string, title: string) => void;
  onOpenAgent?: (instanceId: string, title?: string) => void;
  onTitle?: (title: string) => void;
  /** Board layout: the one-shot taskId was opened. */
  onFocusConsumed?: () => void;
  refreshMs?: number;
  /** Tests replace the owner transport. */
  send?: OwnerSend;
  session?: () => Promise<OwnerSession>;
}

/** A pane that has nothing to show yet: the shared empty state, centred in the pane. */
function Notice({ debugId, title, role, action }: { debugId: string; title: React.ReactNode; role?: 'status' | 'alert'; action?: React.ReactNode }) {
  return (
    <div data-debug-id={debugId} role={role} className="grid h-full place-items-center p-6">
      <EmptyState title={title} action={action} />
    </div>
  );
}

export function OwnerChainAuxPane({
  chainId, layout, taskId, onOpenTicket, onShowBoard, onSwitchTicket, onOpenAgent, onTitle, onFocusConsumed,
  refreshMs = OWNER_AUX_REFRESH_MS, send, session,
}: OwnerChainAuxPaneProps) {
  const owners = useOwnerChains();
  const chain = owners.chains.find((c) => c.chainId === chainId);

  // A board opened for a ticket (from the overview) opens that ticket's tab once.
  const opened = useRef(false);
  useEffect(() => {
    if (layout !== 'board' || !taskId || !chain || opened.current) return;
    opened.current = true;
    const title = chain.tasks.find((t) => t.taskId === taskId)?.title || taskId;
    onOpenTicket(taskId, title);
    onFocusConsumed?.();
  }, [layout, taskId, chain]); // eslint-disable-line react-hooks/exhaustive-deps

  if (!chainId) {
    return <Notice debugId={`aux-${layout}-no-chain`} title="This agent is not part of a task chain." />;
  }
  if (!chain) {
    const link = (
      <ButtonLink size="sm" href={buildRouteHash(`/chains/${encodeURIComponent(chainId)}`, '')}>Open Task Chains</ButtonLink>
    );
    if (owners.status === 'locked') return <Notice debugId="aux-owner-chain-locked" title="Unlock the vault to see this task chain." />;
    if (owners.status === 'loading') {
      return <Notice debugId="aux-owner-chain-loading" role="status" title={<span className="inline-flex items-center gap-2"><Spinner size="sm" />Loading task chain…</span>} />;
    }
    if (owners.status === 'error') {
      return <Notice debugId="aux-owner-chain-error" role="alert" title={`Task chains could not be loaded${owners.error ? `: ${owners.error}` : '.'}`} action={link} />;
    }
    return <Notice debugId="aux-owner-chain-missing" title="This task chain is not on any of your Bridges." action={link} />;
  }
  if (layout === 'ticket' && !taskId) {
    return <Notice debugId="aux-owner-ticket-missing" title="No ticket selected." />;
  }
  return (
    <OwnerChainView
      key={`${chain.chainId}:${layout}:${layout === 'ticket' ? taskId : ''}`}
      chain={chain}
      layout={layout}
      focusTaskId={layout === 'ticket' ? taskId : undefined}
      refreshMs={refreshMs}
      onOpenTicket={onOpenTicket}
      onShowBoard={onShowBoard}
      onSwitchTicket={onSwitchTicket}
      onOpenAgent={onOpenAgent}
      onTitle={onTitle}
      extra={layout === 'overview' ? <ChainTokenUsageSection chainId={chain.chainId} embedded /> : undefined}
      {...(send ? { send } : {})}
      {...(session ? { session } : {})}
    />
  );
}

export default OwnerChainAuxPane;
