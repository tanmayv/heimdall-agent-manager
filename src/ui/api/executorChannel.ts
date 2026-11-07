import { executorCanonical, executorParse, executorVerify, executorIssuanceMatches, type ExecutorDocument, type ExecutorKind } from './executor.ts';
import { ownerPayloadDigest, type OwnerVerifiedKey } from './ownerLocal.ts';
import { currentKey, type VaultKeyring } from '../utils/vaultKeyring.ts';
import { parseVaultEnvelope, sealVaultEnvelope } from '../utils/vaultCrypto.ts';

export const EXECUTOR_CHANNEL_DOMAIN = 'heimdall-executor/channel/v1';
const encoder = new TextEncoder();
function scopeLive(scope: ExecutorDocument, keyring: VaultKeyring, now: bigint): boolean {
  executorParse(JSON.stringify(scope),'transport_scope');
  return scope.account_id === keyring.userId && now >= BigInt(scope.issued_ms) && now < BigInt(scope.request_expires_ms);
}
export function executorChannelAad(scope: ExecutorDocument, vaultId: string, epoch: number): Uint8Array {
  if (!/^[0-9a-f]{16}$/.test(vaultId) || vaultId === '0000000000000000' || !Number.isInteger(epoch) || epoch < 1 || epoch > 0xffffffff) throw new SyntaxError('Executor channel key scope');
  return encoder.encode(EXECUTOR_CHANNEL_DOMAIN+'\n'+vaultId+'\n'+epoch+'\n'+executorCanonical('transport_scope',scope));
}
// nonce is deterministic only for vectors; production callers omit it.
export async function sealExecutorChannel(plain: string, keyring: VaultKeyring, scope: ExecutorDocument, now: bigint, nonce?: Uint8Array): Promise<string> {
  const bytes = encoder.encode(plain);
  try {
    if (!scopeLive(scope,keyring,now) || bytes.length > 32768) throw new SyntaxError('Executor channel bounds');
    return await sealVaultEnvelope(bytes,currentKey(keyring),keyring.vaultId,keyring.currentEpoch,nonce,executorChannelAad(scope,keyring.vaultId,keyring.currentEpoch));
  } finally { bytes.fill(0); }
}
// AEAD only: current enrolled signatures and command admission remain mandatory.
export async function openExecutorChannel(token: string, keyring: VaultKeyring, expected: ExecutorDocument, now: bigint): Promise<string | null> {
  let payload: Uint8Array | undefined, ciphertext: Uint8Array | undefined;
  try {
    if (token.length > 65536 || !scopeLive(expected,keyring,now)) return null;
    const envelope = parseVaultEnvelope(token);
    payload = envelope.payload;
    if (envelope.vaultId !== keyring.vaultId || envelope.epoch !== keyring.currentEpoch || payload.length > 32768+28) return null;
    ciphertext = new Uint8Array(payload.length-12);
    ciphertext.set(payload.subarray(28));
    ciphertext.set(payload.subarray(12,28),payload.length-28);
    const clear = new Uint8Array(await crypto.subtle.decrypt({name:'AES-GCM',iv:payload.subarray(0,12) as BufferSource,
      additionalData:executorChannelAad(expected,keyring.vaultId,envelope.epoch) as BufferSource,tagLength:128},currentKey(keyring),ciphertext as BufferSource));
    try { return new TextDecoder('utf-8',{fatal:true}).decode(clear); }
    finally { clear.fill(0); }
  } catch { return null; }
  finally { payload?.fill(0);ciphertext?.fill(0); }
}

export async function openSignedExecutorChannel(token: string, keyring: VaultKeyring, expected: ExecutorDocument, key: OwnerVerifiedKey, now: bigint): Promise<string | null> {
  try {
    const {method,direction} = expected;
    const plain = await openExecutorChannel(token,keyring,expected,now);
    if (plain === null) return null;
    let kind: ExecutorKind = direction === 'request' && method === 'enrollment' ? 'issuance_consent' : method as ExecutorKind;
    if (direction === 'response') kind = method === 'prepare' || method === 'action' ? 'receipt' : method === 'fence_request' ? 'fence_reply' : kind;
    const value = executorParse(plain,kind);
    if (!await executorVerify(kind,value,key)) return null;
    if (kind === 'receipt' && ((method === 'prepare') !== (value.method === 'prepare'))) return null;
    for (const name of ['account_id','owner_bridge_id','executor_bridge_id','chain_id']) if (value[name] !== expected[name]) return null;
    if (method !== 'enrollment' && value.reservation_id !== expected.reservation_id) return null;
    for (const name of ['owner_incarnation','executor_incarnation']) if (name in value && value[name] !== expected[name]) return null;
    let input: string, fence: string;
    if (direction === 'request') {
      input = await ownerPayloadDigest(executorCanonical(kind,value));
      fence = method === 'prepare' ? input : method === 'fence_request' ? value.action_digest : method === 'enrollment' ? value.selection_digest : value.prepare_digest;
    } else if (method === 'enrollment') { input = value.configuration_digest;fence = input; }
    else if (method === 'fence_request') { input = value.request_digest;fence = value.action_digest; }
    else { input = value.input_digest;fence = value.prepare_digest; }
    return input === expected.input_digest && fence === expected.fence_digest ? plain : null;
  } catch { return null; }
}

export async function openExecutorIssuance(token: string, keyring: VaultKeyring, expected: ExecutorDocument,
  consent: ExecutorDocument, selection: string, deviceKey: OwnerVerifiedKey, executorKey: OwnerVerifiedKey,
  now: bigint, currentAdmission = true): Promise<string | null> {
  try {
    if (expected.method !== 'enrollment' || expected.direction !== 'response' ||
        expected.input_digest !== await ownerPayloadDigest(executorCanonical('issuance_consent',consent)) ||
        expected.fence_digest !== consent.selection_digest) return null;
    for (const name of ['account_id','owner_bridge_id','executor_bridge_id','chain_id']) if (expected[name] !== consent[name]) return null;
    const plain = await openExecutorChannel(token,keyring,expected,now);
    if (plain === null) return null;
    const bundle = executorParse(plain,'issuance_bundle');
    const receipt = executorParse(bundle.issuance_receipt,'issuance_receipt'), enrollment = executorParse(bundle.attestation,'enrollment');
    if (!await executorIssuanceMatches(receipt,consent,selection,bundle.configuration,enrollment,deviceKey,executorKey,now,currentAdmission)) return null;
    const configuration = JSON.parse(bundle.configuration);
    if (currentAdmission && configuration.executor_incarnation !== expected.executor_incarnation) return null;
    return plain;
  } catch { return null; }
}
