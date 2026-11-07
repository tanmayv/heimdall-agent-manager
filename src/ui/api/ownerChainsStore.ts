// One shared, session-bound snapshot of the owner chain registry for the
// sidebar, the chain list and the chain view. It loads once per vault session,
// on explicit refresh, and after a chain is created; it never polls.

import { useEffect, useSyncExternalStore } from 'react';
import { cookieJsonFetch } from './cookieFetch';
import { loadOwnerChainSummaries, type OwnerChainSummary } from './ownerChains';
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
    const chains = await loadOwnerChainSummaries(session, fetchPage, () => getKeyringSession() === session && generation === mine);
    if (generation !== mine || getKeyringSession() !== session) return;
    publish({ status: 'ready', chains: withPending(chains) });
  } catch (error) {
    if (generation !== mine || getKeyringSession() !== session) return;
    publish({ status: 'error', chains: withPending([]), error: error instanceof Error ? error.message : String(error) });
  }
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
export function resetOwnerChainsForTest(page?: (path: string) => Promise<OwnerRegistryPage>): void {
  state = LOCKED; loadedFor = null; generation++; pending.clear();
  fetchPage = page ?? cookieJsonFetch;
  listeners.forEach((l) => l());
}
