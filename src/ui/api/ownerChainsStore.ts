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

/**
 * Reload the registry for the current vault session. The listing is published
 * first: it already names the coordinator of every chain whose owner published
 * its members on the registry row. Then, concurrently, the work status of the
 * online chains and the coordinator of those whose row predates the members
 * are read from their owners, each published as soon as it is known.
 */
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
    const statuses = readOwnerChainStatuses(session, chains, send, current).then((read) => {
      if (current()) publish({ ...state, chains: state.chains.map((c) => (read.has(c.chainId) ? { ...c, status: read.get(c.chainId) } : c)) });
    });
    await Promise.all([statuses, readUnknownCoordinators(session, chains, current)]);
  } catch (error) {
    if (generation !== mine || getKeyringSession() !== session) return;
    publish({ status: 'error', chains: withPending([]), error: error instanceof Error ? error.message : String(error) });
  }
}

type Session = NonNullable<ReturnType<typeof getKeyringSession>>;

/**
 * Coordinators the listing did not name (registry rows without members), from
 * the online owners' member rows, at most four reads at once. Each is recorded
 * as it arrives; a failure is recorded as failed.
 */
async function readUnknownCoordinators(session: Session, chains: OwnerChainSummary[], current: () => boolean): Promise<void> {
  const queue = chains.filter((c) => c.online && !c.pending && c.coordinatorAgentInstanceId === undefined);
  await Promise.all(Array.from({ length: Math.min(4, queue.length) }, async () => {
    for (let c = queue.shift(); c; c = queue.shift()) {
      if (!current()) return;
      await readCoordinator(session, c).catch(() => '');
    }
  }));
}

const coordinatorReads = new Map<string, Promise<string>>();

/**
 * One owner read of a chain's coordinator, shared while in flight and recorded
 * in the snapshot unless it changed meanwhile (a binding from this device or a
 * newer listing wins).
 */
function readCoordinator(session: Session, chain: OwnerChainSummary): Promise<string> {
  const { chainId } = chain;
  let read = coordinatorReads.get(chainId);
  if (read) return read;
  const once = () => readOwnerChainCoordinator(session, chain.ownerBridgeId, chainId, send);
  const record = (patch: Partial<OwnerChainSummary>) => {
    if (getKeyringSession() !== session || ownerChainById(chainId)?.coordinatorAgentInstanceId !== undefined) return;
    publish({ ...state, chains: state.chains.map((c) => (c.chainId === chainId ? { ...c, ...patch } : c)) });
  };
  read = once()
    .then((instanceId) => { record({ coordinatorAgentInstanceId: instanceId, coordinatorReadFailed: false }); return instanceId; })
    .catch((error) => { record({ coordinatorReadFailed: true }); throw error; })
    .finally(() => { coordinatorReads.delete(chainId); });
  coordinatorReads.set(chainId, read);
  return read;
}

/**
 * The bound coordinator of an owner chain, or '' when it has none (callers then
 * open the chain view). `known` and a coordinator already in the snapshot
 * ('' included: none bound) are used as is; an online chain whose coordinator
 * is not known yet is read once now (sharing a read already in flight) and
 * recorded. Failures resolve to '' (and are recorded as failed).
 */
export async function resolveOwnerChainCoordinator(chainId: string, known?: string): Promise<string> {
  const direct = String(known || '').trim();
  if (direct || !chainId) return direct;
  const chain = ownerChainById(chainId);
  if (!chain) return '';
  if (typeof chain.coordinatorAgentInstanceId === 'string') return chain.coordinatorAgentInstanceId;
  const session = getKeyringSession();
  if (!session || !chain.online || chain.pending) return '';
  return readCoordinator(session, chain).catch(() => '');
}

/** Records a coordinator bound from this device without reloading the registry. */
export function setOwnerChainCoordinator(chainId: string, instanceId: string): void {
  publish({ ...state, chains: state.chains.map((c) => (c.chainId === chainId ? { ...c, coordinatorAgentInstanceId: instanceId, coordinatorReadFailed: false } : c)) });
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
