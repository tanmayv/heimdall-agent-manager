import { ownerCanonical, ownerDigest, ownerParse, ownerPayloadDigest, type OwnerCommand, type OwnerGenesis } from './ownerLocal.ts';
import { signDeviceText, type DeviceIdentity } from '../utils/deviceIdentity.ts';
import { encryptVaultText, decryptVaultText } from '../utils/vaultContent.ts';
import type { VaultKeyring } from '../utils/vaultKeyring.ts';
import type { VerifiedChain } from '../utils/vaultDirectoryVerify.ts';

export interface OwnerSession { identity: DeviceIdentity; chain: VerifiedChain; keyring: VaultKeyring }
export interface OwnerOperation { command: string; payload: string; genesis: string }
export interface OwnerInput {
  chainId: string; taskId?: string; expectedRevision: string;
  title?: string; description?: string; body?: string; cursor?: string; operationId?: string;
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
  for (const text of [input.title, input.description, input.body]) if (text && new TextEncoder().encode(text).length > 8192) throw new Error('V1 fields are limited to 8192 UTF-8 bytes');
  const operationId = input.operationId ?? ownerId('op_');
  let genesis = '';
  let payload: Record<string, string>;
  if (method === 'chain.create') {
    const g: OwnerGenesis = { protocol_version: '1', account_id: identity.userId, chain_id: input.chainId, creation_op: operationId, owner_bridge_id: bridgeId, owner_key_id: bridge.device_id, creator_id: identity.deviceId, creator_key_id: identity.deviceId, schema_version: '1', creator_signature: zeros, owner_signature: zeros };
    g.creator_signature = await signed(session, 'genesis', g);
    genesis = JSON.stringify(g);
    payload = { genesis_digest: await ownerDigest('genesis', g), title_cipher: await encryptVaultText(input.title ?? '', keyring), description_cipher: await encryptVaultText(input.description ?? '', keyring) };
  } else if (method === 'task.create') payload = { title_cipher: await encryptVaultText(input.title ?? '', keyring), body_cipher: await encryptVaultText(input.body ?? '', keyring) };
  else if (method === 'task.comment') payload = { body_cipher: await encryptVaultText(input.body ?? '', keyring) };
  else if (method === 'receipt.read') payload = { operation_id: input.operationId ?? '' };
  else payload = { cursor: input.cursor ?? '', limit: '20' };
  const payloadRaw = JSON.stringify(payload);
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
