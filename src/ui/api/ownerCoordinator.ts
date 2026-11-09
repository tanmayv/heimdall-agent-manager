// The coordinator of a Bridge-owned chain (native or imported). Import keeps
// legacy member rows archive-only, so a chain gets a coordinator only by
// launching an instance on its owner Bridge and binding it with
// chain.member.set role=coordinator. The bound coordinator is read back from
// chain.metadata.read member rows.

import { ownerCall, ownerRelaySend, type OwnerSend } from './ownerChains';
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

/**
 * The bound coordinator instance among metadata items: the latest member
 * version per instance (current='1') that is enabled with role coordinator.
 * The highest accepted_seq wins; '' when none.
 */
export function coordinatorFromMetadataItems(items: OwnerMetadataItem[]): string {
  let best = '';
  let bestSeq = -1;
  for (const item of items) {
    if (item?.kind !== 'member' || item.current !== '1' || item.enabled !== '1') continue;
    let body: any = {};
    try { body = JSON.parse(String(item.body || '{}')); } catch { continue; }
    if (body?.role !== 'coordinator') continue;
    const instanceId = String(body.instance_id || item.entity_id || '');
    const seq = Number(item.accepted_seq || 0);
    if (instanceId && seq > bestSeq) { best = instanceId; bestSeq = seq; }
  }
  return best;
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
  let cursor = '';
  for (let page = 0; page < maxPages; page += 1) {
    const data = await read(cursor);
    const found = coordinatorFromMetadataItems(Array.isArray(data?.items) ? data.items : []);
    if (found) return found;
    cursor = String(data?.next_cursor || '');
    if (!cursor) break;
  }
  return '';
}

export async function readOwnerChainCoordinator(
  session: OwnerSession, bridgeId: string, chainId: string, send: OwnerSend = ownerRelaySend,
): Promise<string> {
  return scanOwnerChainCoordinator((cursor) => ownerCall(session, bridgeId, 'chain.metadata.read', { chainId, expectedRevision: '0', cursor, limit: 3 }, send));
}

export type StartCoordinatorStage = 'launching' | 'waiting' | 'binding' | 'done';

export interface StartCoordinatorDeps {
  /** Launches an instance on the owner Bridge; resolves its instance id. */
  launch: () => Promise<string>;
  /** The instance's current runtime_status. */
  status: (instanceId: string) => Promise<string>;
  /** chain.member.set role=coordinator for the running instance. */
  bind: (instanceId: string) => Promise<void>;
  onStage?: (stage: StartCoordinatorStage, instanceId: string) => void;
  sleep?: (ms: number) => Promise<void>;
  now?: () => number;
}

export const COORDINATOR_START_TIMEOUT_MS = 120_000;
const COORDINATOR_POLL_MS = 2_000;
const TERMINAL_STATUSES = new Set(['stopped', 'failed']);

/**
 * Launch -> wait until running -> bind. Binding needs the live child (the
 * owner records the launch it observes), so it only happens once the instance
 * reports running. Throws on launch failure, a terminal status or timeout.
 */
export async function startOwnerCoordinator(deps: StartCoordinatorDeps, timeoutMs = COORDINATOR_START_TIMEOUT_MS): Promise<string> {
  const sleep = deps.sleep ?? ((ms: number) => new Promise<void>((resolve) => setTimeout(resolve, ms)));
  const now = deps.now ?? Date.now;
  deps.onStage?.('launching', '');
  const instanceId = await deps.launch();
  if (!instanceId) throw new Error('The coordinator instance was not created.');
  deps.onStage?.('waiting', instanceId);
  const deadline = now() + timeoutMs;
  for (;;) {
    const status = await deps.status(instanceId).catch(() => '');
    if (status === 'running') break;
    if (TERMINAL_STATUSES.has(status)) throw new Error(`The coordinator instance ${status} before it started.`);
    if (now() >= deadline) throw new Error('The coordinator instance did not start in time; bind it once it is running.');
    await sleep(COORDINATOR_POLL_MS);
  }
  deps.onStage?.('binding', instanceId);
  await deps.bind(instanceId);
  deps.onStage?.('done', instanceId);
  return instanceId;
}

/** The instance id in a POST /agent-instances reply. */
export function createdInstanceId(data: any): string {
  return String(data?.agent_instance_id || data?.instance?.agent_instance_id || data?.data?.agent_instance_id || data?.instance_id || '');
}
