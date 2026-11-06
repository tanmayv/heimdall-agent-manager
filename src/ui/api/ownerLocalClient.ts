import { ownerCanonical, ownerDigest, ownerParse, ownerPayloadDigest, ownerPayloadKind, type OwnerCommand, type OwnerGenesis } from './ownerLocal.ts';
import { signDeviceText, type DeviceIdentity } from '../utils/deviceIdentity.ts';
import { encryptVaultText, decryptVaultText } from '../utils/vaultContent.ts';
import type { VaultKeyring } from '../utils/vaultKeyring.ts';
import type { VerifiedChain } from '../utils/vaultDirectoryVerify.ts';

export interface OwnerSession { identity: DeviceIdentity; chain: VerifiedChain; keyring: VaultKeyring }
export interface OwnerOperation { command: string; payload: string; genesis: string }
export interface OwnerInput {
  chainId: string; taskId?: string; expectedRevision: string;
  query?: string; limit?: number; offset?: string; eventSeq?: string; nativeSourceRevision?: string; nativeHistoryKind?: string; nativeHistoryKey?: string;
  title?: string; description?: string; body?: string; cursor?: string; operationId?: string;
  grantPrincipal?: string; grantExpiresMs?: string; grantCanMutate?: boolean; recoveryEnabled?: boolean; policyRevision?: string;
  instanceId?: string; configurationRevision?: string; enabled?: boolean;
  lifecycleConfig?: Record<string, string>; requirementsRevision?: string; attempt?: string; head?: string; verdict?: 'approve' | 'request_changes';
}
export const ownerId = (prefix: string) => prefix + crypto.randomUUID().replaceAll('-', '');
const zeros = '0'.repeat(128);
async function signed(session: OwnerSession, kind: 'command' | 'genesis', value: OwnerCommand | OwnerGenesis) {
  return JSON.parse(await signDeviceText(session.identity, ownerCanonical(kind, value))).sig as string;
}
export async function prepareOwnerOperation(session: OwnerSession, bridgeId: string, method: OwnerCommand['method'], input: OwnerInput): Promise<OwnerOperation> {
  const { identity, chain, keyring } = session;
  const bridge = [...chain.trusted.values()].find((d) => d.kind === 'bridge' && d.row.bridge_id === bridgeId);
  if (!bridge || !chain.trusted.has(identity.deviceId) || identity.userId !== chain.userId) throw new Error('Device and owner must be currently enrolled in this account');
  for (const [field,text] of [['title',input.title],['description',input.description],['body',input.body]] as const) {
    if (text === undefined) continue;
    const nativeImportBody = method === 'native.history.import' && field === 'body';
    const plainLimit = nativeImportBody ? 65536 : 8192;
    const encodedLimit = nativeImportBody ? 131072 : 16384;
    if (new TextEncoder().encode(text).length > plainLimit || new TextEncoder().encode(JSON.stringify(text)).length > encodedLimit) throw new Error(`Owner ${field} is limited to ${plainLimit} UTF-8 bytes and ${encodedLimit} JSON-encoded bytes`);
  }
  if (method === "chain.search" && (new TextEncoder().encode(input.query ?? "").length > 256 || (input.query ?? "").trim().length < 2 || !Number.isInteger(input.limit ?? 20) || (input.limit ?? 20) < 1 || (input.limit ?? 20) > 50)) throw new Error("Search requires 2–256 UTF-8 bytes and a limit of 1–50");
  if (method === 'grant.recover' && identity.deviceId !== chain.rootDeviceId) throw new Error('Recovery requires the currently enrolled paired root');
  const operationId = input.operationId ?? ownerId('op_');
  let genesis = '';
  let payload: Record<string, string>;
  if (['workflow.cancel','workflow.gate','workflow.define','workflow.run','workflow.retry','source.observe','source.consume','source.ack','source.retire','source.resolve','source.escalate','review.roles'].includes(method)) payload = { body_cipher: await encryptVaultText(input.body ?? '', keyring) };
  else if (method === 'workflow.coordinator') payload = { ...ownerParse(input.body ?? '', 'coordinator_payload') };
  else if (method === 'dependency.edit') payload = { ...ownerParse(input.body ?? '', 'dependency_payload') };
  else if (method === 'grant.set' || method === 'grant.recover') {
    const target = chain.trusted.get(input.grantPrincipal ?? '');
    if (!target || target.kind !== 'browser') throw new Error('Grant recipient must be a currently enrolled browser');
    const expires = input.grantExpiresMs ?? '';
    if (!/^[1-9][0-9]*$/.test(expires) || BigInt(expires) <= BigInt(Date.now()) || BigInt(expires) - BigInt(Date.now()) > 2592000000n) throw new Error('Grant expiry must be within 30 days');
    payload = { principal_id: target.device_id, key_id: target.device_id, expires_ms: expires, can_read: '1', can_mutate: input.grantCanMutate ? '1' : '0' };
  }
  else if (method === 'grant.revoke') payload = { principal_id: input.grantPrincipal ?? '', key_id: input.grantPrincipal ?? '' };
  else if (method === 'grant.policy') payload = { policy_revision: input.policyRevision ?? '', recovery_enabled: input.recoveryEnabled ? '1' : '0' };
  else if (method === 'chain.edit') payload = { title_cipher: await encryptVaultText(input.title ?? '', keyring), description_cipher: await encryptVaultText(input.description ?? '', keyring) };
  else if (method === 'chain.search') payload = { query_cipher: await encryptVaultText(input.query ?? '', keyring), limit: String(input.limit ?? 20) };
  else if (method === 'task.delete') payload = { protocol_version: '1' };
  else if (method === 'chain.create') {
    const g: OwnerGenesis = { protocol_version: '1', account_id: identity.userId, chain_id: input.chainId, creation_op: operationId, owner_bridge_id: bridgeId, owner_key_id: bridge.device_id, creator_id: identity.deviceId, creator_key_id: identity.deviceId, schema_version: '1', creator_signature: zeros, owner_signature: zeros };
    g.creator_signature = await signed(session, 'genesis', g);
    genesis = JSON.stringify(g);
    payload = { genesis_digest: await ownerDigest('genesis', g), title_cipher: await encryptVaultText(input.title ?? '', keyring), description_cipher: await encryptVaultText(input.description ?? '', keyring) };
  } else if ((method === 'task.create' || method === 'task.edit')) payload = { title_cipher: await encryptVaultText(input.title ?? '', keyring), body_cipher: await encryptVaultText(input.body ?? '', keyring) };
  else if (method === 'task.comment') payload = { body_cipher: await encryptVaultText(input.body ?? '', keyring) };
  else if (method === 'fleet.edit') payload = { instance_id: input.instanceId ?? '', configuration_revision: input.configurationRevision ?? '', enabled: input.enabled === false ? '0' : '1' };
  else if (['task.hold', 'task.release', 'task.cancel', 'task.reopen', 'task.resolve'].includes(method)) payload = { body_cipher: await encryptVaultText(input.body ?? '', keyring) };
  else if (method === 'merge.retry') payload = { attempt: input.attempt ?? '', requirements_revision: input.requirementsRevision ?? '', head: input.head ?? '', configuration_revision: input.configurationRevision ?? '', body_cipher: await encryptVaultText(input.body ?? '', keyring) };
  else if (method === 'lifecycle.configure') payload = input.lifecycleConfig ?? {};
  else if (method === 'requirements.edit') payload = { requirements_revision: input.requirementsRevision ?? '', body_cipher: await encryptVaultText(input.body ?? '', keyring) };
  else if (method === 'review.post') payload = { requirements_revision: input.requirementsRevision ?? '', attempt: input.attempt ?? '', head: input.head ?? '', verdict: input.verdict ?? 'approve', summary: input.body ?? '' };
  else if (method === 'native.history.import') payload = { body_cipher: await encryptVaultText(input.body ?? '', keyring) };
  else if (method === 'native.history.read') payload = { source_revision: input.nativeSourceRevision ?? '', kind: input.nativeHistoryKind ?? '', cursor: input.cursor ?? '', limit: String(input.limit ?? 20) };
  else if (method === 'native.history.fetch') payload = { source_revision: input.nativeSourceRevision ?? '', kind: input.nativeHistoryKind ?? '', key: input.nativeHistoryKey ?? '', offset: input.offset ?? '0' };
  else if (method === 'attempt.read') payload = { attempt: input.attempt ?? '' };
  else if (method === 'history.fetch') payload = { seq: input.eventSeq ?? '', offset: input.offset ?? '0' };
  else if (method === 'submission.read') payload = { attempt: input.attempt ?? '', offset: input.offset ?? '0' };
  else if (method === 'receipt.read') payload = { operation_id: input.operationId ?? '' };
  else payload = { cursor: input.cursor ?? '', limit: '20' };
  const payloadRaw = JSON.stringify(payload);
  ownerParse(payloadRaw, ownerPayloadKind(method));
  const command: OwnerCommand = { protocol_version: '1', account_id: identity.userId, chain_id: input.chainId, immutable_owner_bridge: bridgeId, principal_id: identity.deviceId, operation_id: operationId, method, task_id: input.taskId ?? '', expected_revision: input.expectedRevision, request_expires_ms: String(Date.now() + 300000), payload_digest: await ownerPayloadDigest(payloadRaw), key_id: identity.deviceId, signature: zeros };
  command.signature = await signed(session, 'command', command);
  ownerParse(JSON.stringify(command), 'command');
  return { command: JSON.stringify(command), payload: payloadRaw, genesis };
}
export async function ownerRelayFile(session: OwnerSession, operation: OwnerOperation) {
  const command = ownerParse(operation.command, 'command');
  return { protocol_version: '1', chain_id: command.chain_id, bridge_id: command.immutable_owner_bridge, request_id: ownerId('req_'), expires_ms: String(Date.now() + 60000), envelope: await encryptVaultText(JSON.stringify(operation), session.keyring) };
}
export interface OwnerResult { request_id: string; input_digest: string; code: string; body: string; commit_seq: string; replay: boolean }
export async function openOwnerReply(session: OwnerSession, operation: OwnerOperation, reply: any, requestId?: string): Promise<OwnerResult> {
  if (reply?.code !== 'ok' || typeof reply.envelope !== 'string') throw new Error(reply?.code ?? 'owner_unavailable');
  const result = JSON.parse(await decryptVaultText(reply.envelope, session.keyring)) as OwnerResult;
  if ((requestId && result.request_id !== requestId) || result.input_digest !== await ownerDigest('command', ownerParse(operation.command, 'command'))) throw new Error('Owner reply binding mismatch');
  if (result.code !== 'ok') throw new Error(result.code);
  return result;
}
export async function sendOwnerOperation(session: OwnerSession, operation: OwnerOperation, send: (body: unknown) => Promise<unknown>) {
  const relay = await ownerRelayFile(session, operation);
  return openOwnerReply(session, operation, await send(relay), relay.request_id);
}
