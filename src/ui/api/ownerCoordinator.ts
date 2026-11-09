// The coordinator of a Bridge-owned chain (native or imported). Import keeps
// legacy member rows archive-only, so a chain gets a coordinator only by
// launching an instance on its owner Bridge and binding it with
// chain.member.set role=coordinator. The bound coordinator is read back from
// chain.metadata.read member rows.

import { ownerCall, ownerRelaySend, readOwnerChain, type OwnerSend } from './ownerChains';
import type { OwnerSession } from './ownerLocalClient';

/** One chain.metadata.read item (src/lib/owner_local/chain_metadata.odin). */
export interface OwnerMetadataItem {
  kind?: string;
  accepted_seq?: string;
  body?: string;
  entity_id?: string;
  enabled?: string;
  current?: string;
}

/** The bound coordinator: its instance and the agent it was bound with. */
export interface OwnerCoordinatorMember { instanceId: string; agentId: string }

/**
 * The bound coordinator member among metadata items: the latest member
 * version per instance (current='1') that is enabled with role coordinator.
 * The highest accepted_seq wins; null when none.
 */
export function coordinatorMemberFromMetadataItems(items: OwnerMetadataItem[]): OwnerCoordinatorMember | null {
  let best: OwnerCoordinatorMember | null = null;
  let bestSeq = -1;
  for (const item of items) {
    if (item?.kind !== 'member' || item.current !== '1' || item.enabled !== '1') continue;
    let body: any = {};
    try { body = JSON.parse(String(item.body || '{}')); } catch { continue; }
    if (body?.role !== 'coordinator') continue;
    const instanceId = String(body.instance_id || item.entity_id || '');
    const seq = Number(item.accepted_seq || 0);
    if (instanceId && seq > bestSeq) { best = { instanceId, agentId: String(body.agent_id || '') }; bestSeq = seq; }
  }
  return best;
}

/** The bound coordinator instance id among metadata items; '' when none. */
export function coordinatorFromMetadataItems(items: OwnerMetadataItem[]): string {
  return coordinatorMemberFromMetadataItems(items)?.instanceId ?? '';
}

/** Bounded metadata scan: at most this many pages (3 items each). */
export const COORDINATOR_SCAN_PAGES = 40;

/**
 * Pages chain.metadata.read (newest first) until the bound coordinator is
 * found. Items arrive in descending accepted_seq, so the first current,
 * enabled coordinator member is the latest binding.
 */
export async function scanOwnerChainCoordinator(
  read: (cursor: string) => Promise<{ items?: OwnerMetadataItem[]; next_cursor?: string }>,
  maxPages = COORDINATOR_SCAN_PAGES,
): Promise<string> {
  return (await scanOwnerChainCoordinatorMember(read, maxPages))?.instanceId ?? '';
}

/** Like scanOwnerChainCoordinator, but returns the member (instance and agent). */
export async function scanOwnerChainCoordinatorMember(
  read: (cursor: string) => Promise<{ items?: OwnerMetadataItem[]; next_cursor?: string }>,
  maxPages = COORDINATOR_SCAN_PAGES,
): Promise<OwnerCoordinatorMember | null> {
  let cursor = '';
  for (let page = 0; page < maxPages; page += 1) {
    const data = await read(cursor);
    const found = coordinatorMemberFromMetadataItems(Array.isArray(data?.items) ? data.items : []);
    if (found) return found;
    cursor = String(data?.next_cursor || '');
    if (!cursor) break;
  }
  return null;
}

export async function readOwnerChainCoordinatorMember(
  session: OwnerSession, bridgeId: string, chainId: string, send: OwnerSend = ownerRelaySend,
): Promise<OwnerCoordinatorMember | null> {
  return scanOwnerChainCoordinatorMember((cursor) => ownerCall(session, bridgeId, 'chain.metadata.read', { chainId, expectedRevision: '0', cursor, limit: 3 }, send));
}

/** One chain member (the latest version of its member row). */
export interface OwnerChainMember { instanceId: string; agentId: string; role: string; enabled: boolean }

/** The latest member row per instance among metadata items, newest first. */
export function membersFromMetadataItems(items: OwnerMetadataItem[]): OwnerChainMember[] {
  const out = new Map<string, OwnerChainMember>();
  for (const item of items) {
    if (item?.kind !== 'member' || item.current !== '1') continue;
    let body: any = {};
    try { body = JSON.parse(String(item.body || '{}')); } catch { continue; }
    const instanceId = String(body?.instance_id || item.entity_id || '');
    if (!instanceId || out.has(instanceId)) continue;
    out.set(instanceId, { instanceId, agentId: String(body?.agent_id || ''), role: String(body?.role || ''), enabled: item.enabled === '1' });
  }
  return [...out.values()];
}

/** Every member of a chain (bounded metadata scan, like the coordinator read). */
export async function readOwnerChainMembers(
  session: OwnerSession, bridgeId: string, chainId: string, send: OwnerSend = ownerRelaySend, maxPages = COORDINATOR_SCAN_PAGES,
): Promise<OwnerChainMember[]> {
  const items: OwnerMetadataItem[] = [];
  let cursor = '';
  for (let page = 0; page < maxPages; page += 1) {
    const data = await ownerCall(session, bridgeId, 'chain.metadata.read', { chainId, expectedRevision: '0', cursor, limit: 3 }, send);
    if (Array.isArray(data?.items)) items.push(...data.items);
    cursor = String(data?.next_cursor || '');
    if (!cursor) break;
  }
  return membersFromMetadataItems(items);
}

export async function readOwnerChainCoordinator(
  session: OwnerSession, bridgeId: string, chainId: string, send: OwnerSend = ownerRelaySend,
): Promise<string> {
  return scanOwnerChainCoordinator((cursor) => ownerCall(session, bridgeId, 'chain.metadata.read', { chainId, expectedRevision: '0', cursor, limit: 3 }, send));
}

/**
 * chain.member.set role=coordinator for `instanceId`, against the chain
 * revision read right before binding (a launch wait may outlast a loaded
 * revision). Authority is per instance: a replaced coordinator keeps it until
 * its member row is disabled, so the previous one is demoted once the new one
 * is bound (the owner refuses to disable a chain's last coordinator).
 */
export async function bindOwnerCoordinator(
  session: OwnerSession, bridgeId: string, chainId: string, instanceId: string, agentId: string, send: OwnerSend = ownerRelaySend,
): Promise<void> {
  const chainRevision = async () => (await readOwnerChain(session, bridgeId, chainId, send)).revision;
  const previous = await readOwnerChainCoordinatorMember(session, bridgeId, chainId, send);
  await ownerCall(session, bridgeId, 'chain.member.set', { chainId, expectedRevision: await chainRevision(), instanceId, agentId, memberRole: 'coordinator' }, send);
  if (previous && previous.instanceId !== instanceId) {
    await ownerCall(session, bridgeId, 'chain.member.set', { chainId, expectedRevision: await chainRevision(), instanceId: previous.instanceId, agentId: previous.agentId, memberRole: 'coordinator', enabled: false }, send);
  }
}

/** The default coordinator agent is the one with the coordinator slug (the seeded multi-agent workflow agent). */
export function isCoordinatorAgent(agent: { slug?: string } | null | undefined): boolean {
  return agent?.slug === 'coordinator';
}

export type StartCoordinatorStage = 'launching' | 'waiting' | 'binding' | 'restarting' | 'done';

export interface StartCoordinatorDeps {
  /** Launches an instance on the owner Bridge; resolves its instance id. */
  launch: () => Promise<string>;
  /** The instance's current runtime_status. */
  status: (instanceId: string) => Promise<string>;
  /** chain.member.set role=coordinator for the running instance. */
  bind: (instanceId: string) => Promise<void>;
  /**
   * Relaunches the bound instance. The first launch could not know its role
   * (binding needs the live child), so the owner Bridge gives the relaunch the
   * coordinator role and bootstrap.
   */
  restart: (instanceId: string) => Promise<void>;
  onStage?: (stage: StartCoordinatorStage, instanceId: string) => void;
  sleep?: (ms: number) => Promise<void>;
  now?: () => number;
}

export const COORDINATOR_START_TIMEOUT_MS = 120_000;
const COORDINATOR_POLL_MS = 2_000;
const TERMINAL_STATUSES = new Set(['stopped', 'failed']);

async function waitUntilRunning(deps: StartCoordinatorDeps, instanceId: string, timeoutMs: number, what: string): Promise<void> {
  const sleep = deps.sleep ?? ((ms: number) => new Promise<void>((resolve) => setTimeout(resolve, ms)));
  const now = deps.now ?? Date.now;
  const deadline = now() + timeoutMs;
  for (;;) {
    const status = await deps.status(instanceId).catch(() => '');
    if (status === 'running') return;
    if (TERMINAL_STATUSES.has(status)) throw new Error(`The coordinator instance ${status} before it ${what}.`);
    if (now() >= deadline) throw new Error(`The coordinator instance did not ${what === 'started' ? 'start' : 'restart'} in time.`);
    await sleep(COORDINATOR_POLL_MS);
  }
}

/**
 * Launch -> wait until running -> bind -> restart -> wait until running.
 * Binding needs the live child (the owner records the launch it observes), so
 * it only happens once the instance reports running; the relaunch then boots
 * with the coordinator role. Throws on launch failure, a terminal status or
 * timeout, and never binds an instance that did not start. The Hub marks a
 * restarted instance launching synchronously, so the second wait cannot see
 * the pre-restart 'running'.
 */
export async function startOwnerCoordinator(deps: StartCoordinatorDeps, timeoutMs = COORDINATOR_START_TIMEOUT_MS): Promise<string> {
  deps.onStage?.('launching', '');
  const instanceId = await deps.launch();
  if (!instanceId) throw new Error('The coordinator instance was not created.');
  deps.onStage?.('waiting', instanceId);
  await waitUntilRunning(deps, instanceId, timeoutMs, 'started');
  deps.onStage?.('binding', instanceId);
  await deps.bind(instanceId);
  deps.onStage?.('restarting', instanceId);
  await deps.restart(instanceId);
  await waitUntilRunning(deps, instanceId, timeoutMs, 'restarted');
  deps.onStage?.('done', instanceId);
  return instanceId;
}

export type NewChainCoordinatorStage = 'creating' | 'registering' | StartCoordinatorStage;

export interface NewChainCoordinatorDeps extends Omit<StartCoordinatorDeps, 'launch' | 'bind' | 'onStage'> {
  /** chain.create on the owner Bridge; resolves the new chain id. */
  createChain: () => Promise<string>;
  /** Resolves once the chain is listed in the owner registry (waitForOwnerChainListed). */
  waitListed: (chainId: string) => Promise<void>;
  /** Launches the instance on the owner Bridge with this chain_id; resolves its id. */
  launch: (chainId: string) => Promise<string>;
  bind: (chainId: string, instanceId: string) => Promise<void>;
  /** The chain exists from here on, even if its coordinator then fails to start. */
  onChainCreated?: (chainId: string) => void;
  onStage?: (stage: NewChainCoordinatorStage, instanceId: string) => void;
}

/**
 * A new chain with a running, bound coordinator: create the chain, wait until
 * it is in the owner registry (the Hub refuses a chain_id it cannot route, so
 * launching earlier fails), then launch -> wait -> bind -> restart like
 * startOwnerCoordinator. The instance is launched chain-bound.
 */
export async function createChainWithCoordinator(deps: NewChainCoordinatorDeps, timeoutMs = COORDINATOR_START_TIMEOUT_MS): Promise<{ chainId: string; instanceId: string }> {
  deps.onStage?.('creating', '');
  const chainId = await deps.createChain();
  deps.onChainCreated?.(chainId);
  deps.onStage?.('registering', '');
  await deps.waitListed(chainId);
  const instanceId = await startOwnerCoordinator({
    ...deps,
    launch: () => deps.launch(chainId),
    bind: (id) => deps.bind(chainId, id),
  }, timeoutMs);
  return { chainId, instanceId };
}

/** The instance id in a POST /agent-instances reply. */
export function createdInstanceId(data: any): string {
  return String(data?.agent_instance_id || data?.instance?.agent_instance_id || data?.data?.agent_instance_id || data?.instance_id || '');
}
