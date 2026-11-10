// The members of the Bridge-owned ("owner") chain a conversation belongs to,
// for the conversation header's agent switcher. Members are the owner's own
// member rows (chain.metadata.read through the owner relay); the Hub task
// chain endpoints are never used.

import { useCallback, useEffect, useMemo, useState } from 'react';
import { freshOwnerSession, ownerRelaySend, type OwnerChainSummary, type OwnerSend } from './ownerChains';
import { useOwnerChains } from './ownerChainsStore';
import { readOwnerChainMembers, type OwnerChainMember } from './ownerCoordinator';
import type { OwnerSession } from './ownerLocalClient';

export interface OwnerChainSwitcherMember {
  instanceId: string;
  agentId: string;
  role: string;
  isCoordinator: boolean;
  /** The agent's display name, else the instance id. */
  title: string;
}

const ROLE_ORDER: Record<string, number> = { coordinator: 0, worker: 1, reviewer: 2 };

/**
 * The owner chain a conversation's agent belongs to: the chain the conversation
 * (or the pane's target) names when it is an owner chain, else the owner chain
 * whose bound coordinator is the agent. Undefined when it is in none.
 */
export function ownerChainForAgent(
  chains: readonly OwnerChainSummary[], agentInstanceId: string, chainId: string,
): OwnerChainSummary | undefined {
  if (chainId) {
    const named = chains.find((c) => c.chainId === chainId);
    if (named) return named;
  }
  if (!agentInstanceId) return undefined;
  return chains.find((c) => c.coordinatorAgentInstanceId === agentInstanceId);
}

/**
 * The switcher's list: enabled members only, the coordinator first, then
 * workers, then reviewers, then any other role (each group in member order).
 * The chain's bound coordinator counts as coordinator even when its member row
 * names another role, and is listed even before its row is read. Empty when
 * there is no chain or the conversation's agent is not one of the members.
 */
export function ownerChainSwitcherMembers(input: {
  chain: Pick<OwnerChainSummary, 'coordinatorAgentInstanceId'> | undefined;
  members: readonly OwnerChainMember[] | null | undefined;
  agentInstanceId: string;
  names?: Readonly<Record<string, string>>;
}): OwnerChainSwitcherMember[] {
  const { chain, members, agentInstanceId, names = {} } = input;
  if (!chain || !members || !agentInstanceId) return [];
  const coordinator = String(chain.coordinatorAgentInstanceId || '');
  const rows = new Map<string, OwnerChainMember>();
  for (const m of members) {
    if (!m.enabled || !m.instanceId || rows.has(m.instanceId)) continue;
    rows.set(m.instanceId, m);
  }
  if (coordinator && !rows.has(coordinator)) rows.set(coordinator, { instanceId: coordinator, agentId: '', role: 'coordinator', enabled: true });
  if (!rows.has(agentInstanceId)) return [];
  // A coordinator-role row that is not the bound coordinator (one being
  // replaced) follows the bound one.
  const isCoordinator = (m: OwnerChainMember) => (coordinator ? m.instanceId === coordinator : m.role === 'coordinator');
  const rank = (m: OwnerChainMember) => (isCoordinator(m) ? 0 : (ROLE_ORDER[m.role] ?? 3) + 0.5);
  return [...rows.values()]
    .map((m, index) => ({ m, index, rank: rank(m) }))
    .sort((a, b) => a.rank - b.rank || a.index - b.index)
    .map(({ m }) => ({
      instanceId: m.instanceId,
      agentId: m.agentId,
      role: isCoordinator(m) ? 'coordinator' : m.role,
      isCoordinator: isCoordinator(m),
      title: (m.agentId && names[m.agentId]) || m.instanceId,
    }));
}

// One owner read per chain, shared by every pane and kept until reloaded.
const memberReads = new Map<string, Promise<OwnerChainMember[]>>();

function readMembers(chain: OwnerChainSummary, session: () => Promise<OwnerSession>, send: OwnerSend, reload: boolean): Promise<OwnerChainMember[]> {
  const key = `${chain.ownerBridgeId}\u0000${chain.chainId}`;
  const cached = memberReads.get(key);
  if (cached && !reload) return cached;
  const read = session().then((s) => readOwnerChainMembers(s, chain.ownerBridgeId, chain.chainId, send));
  memberReads.set(key, read);
  read.catch(() => { if (memberReads.get(key) === read) memberReads.delete(key); });
  return read;
}

/** Tests only. */
export function resetOwnerChainMembersForTest(): void { memberReads.clear(); }

/**
 * The owner chain of `agentInstanceId` (see ownerChainForAgent) and its
 * enabled members' raw rows; `reload` reads them from the owner again. Members
 * stay null while unknown (no owner chain, owner offline, read failed).
 */
export function useOwnerChainMembers(
  agentInstanceId: string,
  chainId: string,
  options: { session?: () => Promise<OwnerSession>; send?: OwnerSend } = {},
): { chain: OwnerChainSummary | undefined; members: OwnerChainMember[] | null; reload: () => void } {
  const { chains } = useOwnerChains();
  const chain = useMemo(() => ownerChainForAgent(chains, agentInstanceId, chainId), [chains, agentInstanceId, chainId]);
  const session = options.session ?? freshOwnerSession;
  const send = options.send ?? ownerRelaySend;
  const [state, setState] = useState<{ key: string; members: OwnerChainMember[] | null }>({ key: '', members: null });
  const [revision, setRevision] = useState(0);
  const readable = Boolean(chain && chain.online && !chain.pending);
  const key = chain ? `${chain.ownerBridgeId}\u0000${chain.chainId}` : '';
  useEffect(() => {
    if (!chain || !readable) return;
    let cancelled = false;
    readMembers(chain, session, send, revision > 0).then(
      (members) => { if (!cancelled) setState({ key, members }); },
      () => { if (!cancelled) setState((prev) => (prev.key === key ? prev : { key, members: null })); },
    );
    return () => { cancelled = true; };
    // `session`/`send` are fixed per caller; the chain row is keyed by `key`.
  }, [key, readable, revision]); // eslint-disable-line react-hooks/exhaustive-deps
  const reload = useCallback(() => setRevision((r) => r + 1), []);
  return { chain, members: state.key === key ? state.members : null, reload };
}
