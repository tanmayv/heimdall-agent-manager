import { ownerCanonical, ownerParse } from './ownerLocal.ts';
import type { OwnerGenesis, OwnerMigration_Selection } from './ownerSchema.ts';
import { ownerId, type OwnerSession } from './ownerLocalClient.ts';
import { signDeviceText } from '../utils/deviceIdentity.ts';

// R3 one-shot legacy import. This device signs the selection and the
// destination genesis (creation_op = migration id); the Hub freezes the legacy
// chain, the owner Bridge imports it, and the Hub cuts over on the owner's
// signed receipt. The same signed request can be retried or handed to
// `ham-ctl task-chain migrate --request-file`.
export interface MigrationBlocker { code: string; count: number }
export interface MigrationPreflight { chain_id: string; state: string; migration_id: string; owner_bridge_id: string; work_revision: number; blockers: MigrationBlocker[] | null }
export interface MigrationRequest { selection: string; genesis: string }
export interface MigrationResult { state: string; migration_id: string; chain_id: string; manifest_digest: string; receipt_digest: string; replayed: boolean; activation_sent: boolean }

const BLOCKER_TEXT: Record<string, string> = {
  live_leases: 'agents still hold leases; wait for them to submit, hand off or expire',
  outstanding_effects: 'dispatched wakes, stops or merges are still unresolved',
  running_workflows: 'workflow executions are still pending or running',
  tasks_in_progress: 'tasks are in progress',
  tasks_in_review: 'tasks are awaiting review; record the verdicts first',
  pending_merges: 'approved work has not been merged back yet',
  merge_conflicts: 'merge conflicts need a human resolution',
};

export function describeMigrationBlockers(blockers: MigrationBlocker[] | null | undefined): string[] {
  return (blockers ?? []).map((b) => `${b.count} × ${BLOCKER_TEXT[b.code] ?? b.code}`);
}

// The Hub refuses a busy chain with error.details {code:'migration_blocked', blockers:[...]}.
export function migrationBlockersFromError(error: unknown): MigrationBlocker[] {
  const blockers = (error as { details?: { blockers?: unknown } } | null)?.details?.blockers;
  return Array.isArray(blockers) ? blockers as MigrationBlocker[] : [];
}

async function sign(session: OwnerSession, kind: 'migration_selection' | 'genesis', value: OwnerMigration_Selection | OwnerGenesis): Promise<string> {
  return JSON.parse(await signDeviceText(session.identity, ownerCanonical(kind, value as never))).sig as string;
}

export async function prepareMigrationRequest(session: OwnerSession, chainId: string, bridgeId: string, workRevision: number | string, migrationId = ownerId('mig_')): Promise<MigrationRequest> {
  const { identity, chain } = session;
  const bridge = [...chain.trusted.values()].find((d) => d.kind === 'bridge' && d.row.bridge_id === bridgeId);
  if (!bridge || !chain.trusted.has(identity.deviceId) || identity.userId !== chain.userId) throw new Error('This device and the owner Bridge must be currently enrolled in this account');
  const zeros = '0'.repeat(128);
  const selection: OwnerMigration_Selection = {
    protocol_version: '1', account_id: identity.userId, chain_id: chainId, migration_id: migrationId,
    owner_bridge_id: bridgeId, owner_key_id: bridge.device_id, principal_id: identity.deviceId, key_id: identity.deviceId,
    expected_work_revision: String(workRevision), request_expires_ms: String(Date.now() + 300000), signature: zeros,
  };
  selection.signature = await sign(session, 'migration_selection', selection);
  const genesis: OwnerGenesis = {
    protocol_version: '1', account_id: identity.userId, chain_id: chainId, creation_op: migrationId, owner_bridge_id: bridgeId,
    owner_key_id: bridge.device_id, creator_id: identity.deviceId, creator_key_id: identity.deviceId, schema_version: '1',
    creator_signature: zeros, owner_signature: zeros,
  };
  genesis.creator_signature = await sign(session, 'genesis', genesis);
  const request = { selection: JSON.stringify(selection), genesis: JSON.stringify(genesis) };
  ownerParse(request.selection, 'migration_selection');
  ownerParse(request.genesis, 'genesis');
  return request;
}
