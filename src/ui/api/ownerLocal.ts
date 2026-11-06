import { parseVaultEnvelope } from '../utils/vaultCrypto.ts';
import { parseOwnerRequestDocument } from './ownerJson.ts';
import { ownerSchemas } from './ownerSchema.ts';
import type { OwnerKind, OwnerDocuments, OwnerCommand, OwnerGenesis, OwnerRegistry } from './ownerSchema.ts';
export type { OwnerKind, OwnerDocuments, OwnerCommand, OwnerGenesis, OwnerRegistry } from './ownerSchema.ts';

export const OWNER_DOCUMENT_MAX = 256 * 1024;
export const OWNER_REQUEST_TTL_MS = 300000n;
const ascii = (s: string) => /^[\x20-\x7e]*$/.test(s);
const decimal = (s: string) => /^(0|[1-9][0-9]*)$/.test(s) && s.length <= 19 && BigInt(s) <= 9223372036854775807n;
const methods = new Set(['history.read','history.fetch','context.read','workflow.coordinator','grant.set','grant.revoke','grant.read','grant.policy','grant.recover','workflow.cancel','workflow.gate','workflow.define','workflow.run','workflow.retry','workflow.read','source.observe','source.consume','source.ack','source.retire','source.resolve','source.escalate','source.read','dependency.edit','review.roles','task.hold', 'task.release', 'task.cancel', 'task.reopen', 'task.resolve', 'merge.retry', 'submission.read', 'chain.edit', 'task.edit', 'task.delete', 'chain.search', 'chain.create', 'task.create', 'task.comment', 'chain.read', 'task.read', 'receipt.read', 'fleet.edit', 'runtime.read', 'lifecycle.configure', 'requirements.edit', 'review.post']);
function fieldValid(s: string, kind: string): boolean {
  if (kind === "document" || kind === "optional_document") return new TextEncoder().encode(s).length <= OWNER_DOCUMENT_MAX && (s !== "" || kind === "optional_document");
  if (!ascii(s)) return false;
  switch (kind) {
    case 'id': case 'optional': return (kind === 'optional' && s === '') || (s.length <= 160 && /^[a-zA-Z0-9_.:-]+$/.test(s));
    case 'version': return s === '1';
    case 'counter': case 'positive': return decimal(s) && (kind === 'counter' || s !== '0');
    case 'hash': return /^[0-9a-f]{64}$/.test(s);
    case 'signature': return /^[0-9a-f]{128}$/.test(s);
    case 'method': return methods.has(s);
    case 'lease_method': return s === 'lease.claim' || s === 'lease.heartbeat';
    case 'coordinator_methods': return s === 'workflow.gate.post';
    case 'lease_methods': return ['review.role.post,review.checkpoint','lease.claim,lease.heartbeat,requirements.present,requirements.ack,lease.submit,lease.handoff,lease.block,lease.switch','review.post,review.checkpoint','lease.claim,lease.heartbeat','lease.claim,lease.heartbeat,requirements.present,requirements.ack,lease.submit','review.post'].includes(s);
    case 'lifecycle_method': return ['workflow.gate.post','review.role.open','review.role.post','lease.handoff','lease.block','lease.switch','review.checkpoint','requirements.present','requirements.ack','lease.submit','review.open','review.post'].includes(s);
    case 'merge_policy': return s === 'none' || s === 'git';
    case 'verdict': return s === 'approve' || s === 'request_changes';
    case 'path': return s.length <= 4096 && (s === '' || (s.startsWith('/') && !s.includes('..') && !s.includes('\\')));
    case 'optional_commit': return s === '' || /^[0-9a-f]{40}([0-9a-f]{24})?$/.test(s);
    case 'optional_ref': return s === '' || (s.length <= 160 && !s.startsWith('-') && !s.includes('..') && !s.includes('//') && /^[a-zA-Z0-9_./-]+$/.test(s));
    case 'flag': return s === '0' || s === '1';
    case 'relay_cipher':
      if (s.length > 196608) return false;
      try { parseVaultEnvelope(s); return true; } catch { return false; }
    case 'cipher': case 'required_cipher':
      if (s === '') return kind === 'cipher';
      if (s.length > 65536) return false;
      try { parseVaultEnvelope(s); return true; } catch { return false; }
    case 'result_code': return s === 'ok' || s === 'retired';
    case 'error_code': return ['malformed', 'bad_signature', 'invalid_scope', 'owner_mismatch', 'digest_mismatch', 'operation_conflict', 'expired', 'retired', 'stale_revision', 'owner_unavailable', 'retention_capacity', 'storage_error', 'invalid_content', 'clock_uncertain', 'stale_cursor'].includes(s);
    default: return false;
  }
}
export function ownerDocumentValid<K extends OwnerKind>(kind: K, value: unknown): value is OwnerDocuments[K] {
  if (!Object.hasOwn(ownerSchemas, kind) || !value || typeof value !== 'object' || Array.isArray(value)) return false;
  const o = value as Record<string, unknown>;
  if (kind === 'submit_payload' && Object.hasOwn(o, 'output')) return ownerDocumentValid('submit_output_payload', value);
  const fields = ownerSchemas[kind];
  if (Object.keys(o).length !== fields.length) return false;
  for (const [name, type] of fields) if (!Object.hasOwn(o, name) || typeof o[name] !== 'string' || !fieldValid(o[name], type)) return false;
  if (kind === 'command') {
    if (['dependency.edit','review.roles','task.hold', 'task.release', 'task.cancel', 'task.reopen', 'task.resolve', 'merge.retry', 'submission.read', 'task.edit', 'task.delete', 'task.create', 'task.comment', 'task.read', 'fleet.edit', 'runtime.read', 'lifecycle.configure', 'requirements.edit', 'review.post'].includes(String(o.method)) !== (o.task_id !== '')) return false;
  }
  if (kind === 'registry' && o.deleted === '0') {
    if (o.task_id === '') {
      if (o.chain_title_cipher === '' || o.chain_description_cipher === '' || o.task_title_cipher !== '') return false;
    } else if (o.task_title_cipher === '' || o.chain_title_cipher !== '' || o.chain_description_cipher !== '') return false;
  }
  if (kind === 'registry' && o.deleted === '1' && (o.chain_title_cipher !== '' || o.chain_description_cipher !== '' || o.task_title_cipher !== '')) return false;
  if (kind === 'receipt' && o.result_code === 'retired' && o.result_cipher !== '') return false;
  if (kind === 'capability' && BigInt(String(o.expires_ms)) > BigInt(String(o.hard_ms))) return false;
  if (kind === 'lease_input' && ((o.method === 'lease.claim') !== (o.capability === ''))) return false;
  if (kind === 'read_payload' && BigInt(String(o.limit)) > 100n) return false;
  return true;
}
export function ownerPayloadKind(method: string): OwnerKind {
  switch (method) {
    case 'workflow.coordinator': return 'coordinator_payload';
    case 'workflow.gate.post': return 'workflow_gate';
    case 'workflow.cancel': case 'workflow.gate': case 'workflow.define': case 'workflow.run': case 'workflow.retry': case 'source.observe': case 'source.consume': case 'source.ack': case 'source.retire': case 'source.resolve': case 'source.escalate': case 'review.roles': return 'control_payload';
    case 'workflow.read': case 'source.read': return 'read_payload';
    case 'dependency.edit': return 'dependency_payload';
    case 'review.role.open': case 'review.role.post': return 'review_role_payload';
    case 'grant.set': case 'grant.recover': return 'grant_payload';
    case 'grant.revoke': return 'grant_revoke_payload';
    case 'grant.policy': return 'grant_policy_payload';
    case 'grant.read': return 'read_payload';
    case 'chain.create': return 'chain_create_payload';
    case 'task.create': case 'task.edit': return 'task_create_payload';
    case 'submission.read': return 'submission_read_payload';
    case 'chain.edit': return 'chain_edit_payload';
    case 'task.delete': return 'delete_payload';
    case 'chain.search': return 'search_payload';
    case 'task.comment': return 'comment_payload';
    case 'fleet.edit': return 'fleet_payload';
    case 'task.hold': case 'task.release': case 'task.cancel': case 'task.reopen': case 'task.resolve': return 'control_payload';
    case 'lease.handoff': return 'handoff_payload';
    case 'lease.block': return 'block_payload';
    case 'lease.switch': return 'switch_payload';
    case 'review.checkpoint': return 'checkpoint_payload';
    case 'merge.retry': return 'merge_retry_payload';
    case 'lifecycle.configure': return 'lifecycle_config_payload';
    case 'requirements.edit': return 'requirements_payload';
    case 'requirements.present': case 'requirements.ack': return 'ack_payload';
    case 'lease.submit': return 'submit_payload';
    case 'review.open': case 'review.post': return 'review_payload';
    case 'history.fetch': return 'history_fetch_payload';
    case 'history.read': case 'context.read': case 'chain.read': case 'task.read': case 'runtime.read': return 'read_payload';
    case 'receipt.read': return 'receipt_payload';
    default: throw new SyntaxError('Unsupported owner method');
  }
}
export function ownerParse<K extends OwnerKind>(raw: string, kind: K): OwnerDocuments[K] {
  if (raw.length > OWNER_DOCUMENT_MAX || new TextEncoder().encode(raw).length > OWNER_DOCUMENT_MAX) throw new SyntaxError('Owner document too large');
  const value = parseOwnerRequestDocument(raw);
  if (!ownerDocumentValid(kind, value)) throw new SyntaxError('Invalid owner document');
  return value;
}
export function ownerCanonical<K extends OwnerKind>(kind: K, o: OwnerDocuments[K]): string {
  if (kind === 'submit_payload' && Object.hasOwn(o, 'output')) return ownerCanonical('submit_output_payload', o as unknown as OwnerDocuments['submit_output_payload']);
  if (!ownerDocumentValid(kind, o)) throw new SyntaxError('Invalid owner document');
  const fields = o as unknown as Record<string, string>;
  return 'heimdall-owner-local/' + kind + '/v1\n' + ownerSchemas[kind]
    .filter(([, type]) => type !== 'signature')
    .map(([name]) => fields[name].length + ':' + fields[name] + ',').join('');
}
const bytes = (s: string) => new TextEncoder().encode(s);
const unhex = (s: string) => Uint8Array.from(s.match(/../g) ?? [], (s) => Number.parseInt(s, 16));
export async function ownerPayloadDigest(payload: string): Promise<string> {
  const hash = new Uint8Array(await crypto.subtle.digest('SHA-256', bytes(payload)));
  return Array.from(hash, (b) => b.toString(16).padStart(2, '0')).join('');
}
export async function ownerDigest<K extends OwnerKind>(kind: K, o: OwnerDocuments[K]): Promise<string> {
  return ownerPayloadDigest(ownerCanonical(kind, o));
}

// TRUSTED directory-verification/local-storage inputs, never envelope assertions.
// Possession of a content encryption key does not create either of these records.
export interface OwnerVerifiedKey {
  account_id: string; principal_id: string; key_id: string; public_key: string;
  kind: 'device' | 'bridge' | 'content'; enrolled: boolean; revoked: boolean;
}
export interface OwnerReadGrant {
  account_id: string; owner_bridge_id: string; chain_id: string; principal_id: string; key_id: string;
  task_id: string; method: string; revision: bigint; expires_ms: bigint;
  can_read: boolean; can_mutate: boolean; revoked: boolean;
}
export type OwnerError = 'none' | 'malformed' | 'bad_signature' | 'invalid_scope' | 'owner_mismatch' | 'digest_mismatch' | 'expired' | 'stale_revision';
export async function ownerVerifySignature<K extends OwnerKind>(kind: K, o: OwnerDocuments[K], field: string, key: OwnerVerifiedKey): Promise<boolean> {
  if (!key.enrolled || key.revoked || !['device', 'bridge'].includes(key.kind) || !ownerDocumentValid(kind, o)) return false;
  const sig = (o as unknown as Record<string, string>)[field];
  if (!/^[0-9a-f]{128}$/.test(sig ?? '') || !/^04[0-9a-f]{128}$/.test(key.public_key)) return false;
  try {
    const pub = await crypto.subtle.importKey('raw', unhex(key.public_key), { name: 'ECDSA', namedCurve: 'P-256' }, false, ['verify']);
    return await crypto.subtle.verify({ name: 'ECDSA', hash: 'SHA-256' }, pub, unhex(sig), bytes(ownerCanonical(kind, o)));
  } catch { return false; }
}
export async function ownerVerifyGenesis(o: OwnerGenesis, account: string, recipientBridge: string, creator: OwnerVerifiedKey, owner: OwnerVerifiedKey): Promise<OwnerError> {
  if (!ownerDocumentValid('genesis', o)) return 'malformed';
  if (o.account_id !== account || creator.account_id !== account || owner.account_id !== account) return 'invalid_scope';
  if (o.owner_bridge_id !== recipientBridge || owner.principal_id !== recipientBridge) return 'owner_mismatch';
  if (creator.kind !== 'device' || owner.kind !== 'bridge' || creator.principal_id !== o.creator_id || creator.key_id !== o.creator_key_id || owner.key_id !== o.owner_key_id) return 'invalid_scope';
  return await ownerVerifySignature('genesis', o, 'creator_signature', creator) && await ownerVerifySignature('genesis', o, 'owner_signature', owner) ? 'none' : 'bad_signature';
}
export async function ownerAuthenticateCommand(o: OwnerCommand, payload: string, key: OwnerVerifiedKey, grant: OwnerReadGrant, nowMs: bigint): Promise<OwnerError> {
  if (!ownerDocumentValid('command', o) || bytes(payload).length > OWNER_DOCUMENT_MAX) return 'malformed';
  if (nowMs < 0n || grant.revision < 1n || grant.expires_ms <= nowMs || grant.revoked || !grant.can_read) return 'invalid_scope';
  if (o.account_id !== grant.account_id || key.account_id !== grant.account_id || o.chain_id !== grant.chain_id || o.principal_id !== grant.principal_id || key.principal_id !== grant.principal_id || o.key_id !== grant.key_id || key.key_id !== grant.key_id || o.method !== grant.method || (grant.task_id !== '' && o.task_id !== grant.task_id) || key.kind !== 'device') return 'invalid_scope';
  if (o.immutable_owner_bridge !== grant.owner_bridge_id) return 'owner_mismatch';
  if (!await ownerVerifySignature('command', o, 'signature', key)) return 'bad_signature';
  if (await ownerPayloadDigest(payload) !== o.payload_digest) return 'digest_mismatch';
  try { ownerParse(payload, ownerPayloadKind(o.method)); } catch { return 'malformed'; }
  return 'none';
}
export function ownerLiveAdmit(o: OwnerCommand, grant: OwnerReadGrant, nowMs: bigint, currentRevision: bigint): OwnerError {
  if (!ownerDocumentValid('command', o)) return 'malformed';
  if (nowMs < 0n || !grant.can_read || grant.revoked || grant.revision < 1n || grant.expires_ms <= nowMs) return 'invalid_scope';
  if (o.account_id !== grant.account_id || o.chain_id !== grant.chain_id || o.principal_id !== grant.principal_id || o.key_id !== grant.key_id || o.method !== grant.method || (grant.task_id !== '' && o.task_id !== grant.task_id)) return 'invalid_scope';
  if (o.immutable_owner_bridge !== grant.owner_bridge_id) return 'owner_mismatch';
  const expires = BigInt(o.request_expires_ms);
  if (expires <= nowMs || expires - nowMs > OWNER_REQUEST_TTL_MS) return 'expired';
  const read = ['history.read','history.fetch','context.read', 'grant.read','workflow.read','source.read','submission.read', 'chain.search', 'chain.read', 'task.read', 'receipt.read', 'runtime.read'].includes(o.method);
  if (!read && !grant.can_mutate) return 'invalid_scope';
  if (currentRevision < 0n) return 'stale_revision';
  if (read && o.expected_revision === '0') return 'none';
  if (BigInt(o.expected_revision) !== currentRevision) return 'stale_revision';
  return 'none';
}

export async function ownerVerifyRegistry(o: OwnerRegistry, account: string, bridge: string, genesisDigest: string, key: OwnerVerifiedKey): Promise<OwnerError> {
  if (!ownerDocumentValid('registry', o)) return 'malformed';
  if (key.kind !== 'bridge' || key.account_id !== account || o.account_id !== account || key.key_id !== o.key_id) return 'invalid_scope';
  if (key.principal_id !== bridge || o.owner_bridge_id !== bridge) return 'owner_mismatch';
  if (o.genesis_digest !== genesisDigest) return 'digest_mismatch';
  return await ownerVerifySignature('registry', o, 'signature', key) ? 'none' : 'bad_signature';
}

export async function ownerCreateBinding(command: OwnerCommand, genesis: OwnerGenesis, payload: string): Promise<boolean> {
  if (!ownerDocumentValid('command', command) || !ownerDocumentValid('genesis', genesis) || command.method !== 'chain.create') return false;
  if (command.account_id !== genesis.account_id || command.chain_id !== genesis.chain_id || command.immutable_owner_bridge !== genesis.owner_bridge_id || command.principal_id !== genesis.creator_id || command.key_id !== genesis.creator_key_id || command.operation_id !== genesis.creation_op) return false;
  try {
    const p = ownerParse(payload, 'chain_create_payload');
    return p.genesis_digest === await ownerDigest('genesis', genesis) && command.payload_digest === await ownerPayloadDigest(payload);
  } catch { return false; }
}
