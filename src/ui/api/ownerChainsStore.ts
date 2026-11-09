// One shared, session-bound snapshot of the owner chain registry for the
// sidebar, the chain list and the chain view. It loads once per vault session,
// on explicit refresh, and after a chain is created; it never polls.

import { useEffect, useSyncExternalStore } from 'react';
import { cookieJsonFetch } from './cookieFetch';
import { loadOwnerChainSummaries, ownerRelaySend, readOwnerChainStatuses, type OwnerChainSummary, type OwnerSend } from './ownerChains';
import { readOwnerChainCoordinator } from './ownerCoordinator';
import type { OwnerRegistryPage } from './ownerRegistryListing';
import { subscribeTaskChainCreation } from './taskChainCreationEvents';
import { getKeyringSession, subscribeKeyringSession } from '../utils/vaultKeyringSession';

export interface OwnerChainsState {
  status: 'locked' | 'loading' | 'ready' | 'error';
  chains: OwnerChainSummary[];
  error?: string;
}

const LOCKED: OwnerChainsState = { status: 'locked', chains: [] };
let state: OwnerChainsState = LOCKED;
let loadedFor: object | null = null;
let generation = 0;
const pending = new Map<string, OwnerChainSummary>();
const listeners = new Set<() => void>();
let fetchPage: (path: string) => Promise<OwnerRegistryPage> = cookieJsonFetch;
let send: OwnerSend = ownerRelaySend;
let wired = false;

function publish(next: OwnerChainsState) {
  state = next;
  listeners.forEach((l) => l());
}
function withPending(chains: OwnerChainSummary[]): OwnerChainSummary[] {
  const ids = new Set(chains.map((c) => c.chainId));
  for (const id of ids) pending.delete(id);
  return [...pending.values(), ...chains];
}

export function ownerChainsSnapshot(): OwnerChainsState { return state; }
export function subscribeOwnerChains(listener: () => void): () => void {
  listeners.add(listener);
  return () => { listeners.delete(listener); };
}

/** Reload the registry for the current vault session. */
export async function refreshOwnerChains(): Promise<void> {
  const session = getKeyringSession();
  const mine = ++generation;
  loadedFor = session;
  if (!session) { pending.clear(); publish(LOCKED); return; }
  publish({ status: 'loading', chains: state.status === 'locked' ? [...pending.values()] : state.chains });
  try {
    const current = () => getKeyringSession() === session && generation === mine;
    const chains = await loadOwnerChainSummaries(session, fetchPage, current);
    if (!current()) return;
    publish({ status: 'ready', chains: withPending(chains) });
    // Work status (active/completed) is owner state: read it from the online
    // owners, bounded; offline chains stay unknown.
    const statuses = await readOwnerChainStatuses(session, chains, send, current);
    if (!current()) return;
    publish({ status: 'ready', chains: state.chains.map((c) => (statuses.has(c.chainId) ? { ...c, status: statuses.get(c.chainId) } : c)) });
    // The bound coordinator is owner state too (member rows), read the same way.
    const coordinators = await readOwnerChainCoordinators(session, chains, current);
    if (!current()) return;
    publish({ status: 'ready', chains: state.chains.map((c) => (coordinators.has(c.chainId) ? { ...c, coordinatorAgentInstanceId: coordinators.get(c.chainId) } : c)) });
  } catch (error) {
    if (generation !== mine || getKeyringSession() !== session) return;
    publish({ status: 'error', chains: withPending([]), error: error instanceof Error ? error.message : String(error) });
  }
}

/** Bound coordinators of the online chains, at most four owner reads at once; failures stay unknown. */
async function readOwnerChainCoordinators(session: Parameters<typeof readOwnerChainCoordinator>[0], chains: OwnerChainSummary[], current: () => boolean): Promise<Map<string, string>> {
  const out = new Map<string, string>();
  const queue = chains.filter((c) => c.online && !c.pending);
  await Promise.all(Array.from({ length: Math.min(4, queue.length) }, async () => {
    for (let c = queue.shift(); c; c = queue.shift()) {
      if (!current()) return;
      try { out.set(c.chainId, await readOwnerChainCoordinator(session, c.ownerBridgeId, c.chainId, send)); } catch { /* unknown */ }
    }
  }));
  return out;
}

const coordinatorReads = new Map<string, Promise<string>>();

/**
 * The bound coordinator of an owner chain, or '' when it has none (callers then
 * open the chain view). `known` and a coordinator already read into the
 * snapshot ('' included: read, none bound) are used as is; an online chain
 * whose member rows were not read yet is read once now and recorded. Failures
 * resolve to ''.
 */
export async function resolveOwnerChainCoordinator(chainId: string, known?: string): Promise<string> {
  const direct = String(known || '').trim();
  if (direct || !chainId) return direct;
  const chain = ownerChainById(chainId);
  if (!chain) return '';
  if (typeof chain.coordinatorAgentInstanceId === 'string') return chain.coordinatorAgentInstanceId;
  const session = getKeyringSession();
  if (!session || !chain.online || chain.pending) return '';
  let read = coordinatorReads.get(chainId);
  if (!read) {
    read = readOwnerChainCoordinator(session, chain.ownerBridgeId, chainId, send)
      .then((instanceId) => {
        if (getKeyringSession() === session && ownerChainById(chainId)?.coordinatorAgentInstanceId === undefined) setOwnerChainCoordinator(chainId, instanceId);
        return instanceId;
      })
      .catch(() => '')
      .finally(() => { coordinatorReads.delete(chainId); });
    coordinatorReads.set(chainId, read);
  }
  return read;
}

/** Records a coordinator bound from this device without reloading the registry. */
export function setOwnerChainCoordinator(chainId: string, instanceId: string): void {
  publish({ ...state, chains: state.chains.map((c) => (c.chainId === chainId ? { ...c, coordinatorAgentInstanceId: instanceId } : c)) });
}

/** A chain created on this device before its registry entry reaches the Hub. */
export function addPendingOwnerChain(chain: OwnerChainSummary): void {
  pending.set(chain.chainId, { ...chain, pending: true });
  publish({ ...state, status: state.status === 'locked' ? 'loading' : state.status, chains: withPending(state.chains.filter((c) => c.chainId !== chain.chainId)) });
}

export function ownerChainById(chainId: string): OwnerChainSummary | undefined {
  return state.chains.find((c) => c.chainId === chainId);
}

function wire() {
  if (wired) return;
  wired = true;
  subscribeKeyringSession(() => { if (getKeyringSession() !== loadedFor) void refreshOwnerChains(); });
  subscribeTaskChainCreation(() => { void refreshOwnerChains(); });
}

/** The shared owner chain snapshot; the first subscriber of a session loads it. */
export function useOwnerChains(): OwnerChainsState {
  const snapshot = useSyncExternalStore(subscribeOwnerChains, ownerChainsSnapshot, ownerChainsSnapshot);
  useEffect(() => {
    wire();
    if (getKeyringSession() !== loadedFor || (state.status === 'locked' && getKeyringSession())) void refreshOwnerChains();
  }, []);
  return snapshot;
}

/** Tests only. */
export function resetOwnerChainsForTest(page?: (path: string) => Promise<OwnerRegistryPage>, relay?: OwnerSend): void {
  state = LOCKED; loadedFor = null; generation++; pending.clear(); coordinatorReads.clear();
  fetchPage = page ?? cookieJsonFetch;
  send = relay ?? ownerRelaySend;
  listeners.forEach((l) => l());
}
