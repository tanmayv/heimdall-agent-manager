import { ownerDigest, ownerDocumentValid, ownerVerifySignature, OWNER_REQUEST_TTL_MS } from './ownerLocal.ts';
import type { OwnerError, OwnerVerifiedKey } from './ownerLocal.ts';
import type { OwnerGenesis, OwnerMigration_Selection, OwnerMigration_Import_Receipt, OwnerMigration_Control } from './ownerSchema.ts';

// Consent and evidence validation only. Persistence must enforce freeze, drain,
// quarantine and cutover; these proofs never independently grant task authority.
export async function ownerVerifyMigrationSelection(o: OwnerMigration_Selection, account: string, chain: string, device: OwnerVerifiedKey, owner: OwnerVerifiedKey): Promise<OwnerError> {
  if (!ownerDocumentValid('migration_selection', o)) return 'malformed';
  if (o.account_id !== account || o.chain_id !== chain || device.account_id !== account || owner.account_id !== account) return 'invalid_scope';
  if (device.kind !== 'device' || device.principal_id !== o.principal_id || device.key_id !== o.key_id) return 'invalid_scope';
  if (owner.kind !== 'bridge' || owner.principal_id !== o.owner_bridge_id || owner.key_id !== o.owner_key_id || !owner.enrolled || owner.revoked) return 'owner_mismatch';
  return await ownerVerifySignature('migration_selection', o, 'signature', device) ? 'none' : 'bad_signature';
}

// Call only on a receipt miss. Expired exact retries authenticate and replay
// historical results without reopening either writer or extending any deadline.
export function ownerMigrationAdmit(kind: 'migration_selection' | 'migration_control', o: OwnerMigration_Selection | OwnerMigration_Control, now: bigint, expectedRevision: bigint): OwnerError {
  if (kind !== 'migration_selection' && kind !== 'migration_control') return 'malformed';
  if (!ownerDocumentValid(kind, o)) return 'malformed';
  const expires = BigInt(o.request_expires_ms);
  if (now < 0n || expires <= now || expires - now > OWNER_REQUEST_TTL_MS) return 'expired';
  const revision = kind === 'migration_selection' ? (o as OwnerMigration_Selection).expected_work_revision : (o as OwnerMigration_Control).expected_revision;
  return BigInt(revision) === expectedRevision ? 'none' : 'stale_revision';
}

export async function ownerVerifyMigrationImport(receipt: OwnerMigration_Import_Receipt, selection: OwnerMigration_Selection, genesis: OwnerGenesis, manifestDigest: string, owner: OwnerVerifiedKey): Promise<OwnerError> {
  if (!ownerDocumentValid('migration_import_receipt', receipt) || !ownerDocumentValid('migration_selection', selection) || !ownerDocumentValid('genesis', genesis) || !/^[0-9a-f]{64}$/.test(manifestDigest)) return 'malformed';
  const { account_id: account, chain_id: chain } = selection;
  if (owner.kind !== 'bridge' || owner.account_id !== account || owner.principal_id !== selection.owner_bridge_id || owner.key_id !== selection.owner_key_id) return 'owner_mismatch';
  for (const object of [receipt, genesis]) {
    if (object.account_id !== account || object.chain_id !== chain) return 'invalid_scope';
    if (object.owner_bridge_id !== owner.principal_id) return 'owner_mismatch';
  }
  if (receipt.key_id !== owner.key_id || genesis.owner_key_id !== owner.key_id) return 'owner_mismatch';
  if (receipt.selection_digest !== await ownerDigest('migration_selection', selection) || receipt.manifest_digest !== manifestDigest || receipt.genesis_digest !== await ownerDigest('genesis', genesis)) return 'digest_mismatch';
  if (receipt.migration_id !== selection.migration_id || genesis.creation_op !== selection.migration_id || genesis.creator_id !== selection.principal_id || genesis.creator_key_id !== selection.key_id || receipt.schema_version !== genesis.schema_version) return 'invalid_scope';
  return await ownerVerifySignature('migration_import_receipt', receipt, 'signature', owner) && await ownerVerifySignature('genesis', genesis, 'owner_signature', owner) ? 'none' : 'bad_signature';
}

// evidenceDigest is a separately verified import receipt for cutover, or a
// destination discard/retirement receipt for resume. No proof is inferred here.
export async function ownerVerifyMigrationControl(o: OwnerMigration_Control, selection: OwnerMigration_Selection, evidenceDigest: string, device: OwnerVerifiedKey): Promise<OwnerError> {
  if (!ownerDocumentValid('migration_control', o) || !ownerDocumentValid('migration_selection', selection) || !/^[0-9a-f]{64}$/.test(evidenceDigest)) return 'malformed';
  if (device.kind !== 'device' || device.account_id !== selection.account_id || device.principal_id !== o.principal_id || device.key_id !== o.key_id) return 'invalid_scope';
  for (const name of ['account_id', 'chain_id', 'migration_id', 'owner_bridge_id'] as const) if (o[name] !== selection[name]) return 'invalid_scope';
  if (o.selection_digest !== await ownerDigest('migration_selection', selection) || o.evidence_digest !== evidenceDigest) return 'digest_mismatch';
  return await ownerVerifySignature('migration_control', o, 'signature', device) ? 'none' : 'bad_signature';
}
