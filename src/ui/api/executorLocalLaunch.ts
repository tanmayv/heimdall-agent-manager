import {executorCanonical,executorParse,executorVerify,type ExecutorDocument} from './executor.ts';
import {ownerPayloadDigest,type OwnerVerifiedKey} from './ownerLocal.ts';
import {ownerId,type OwnerSession} from './ownerLocalClient.ts';
import {signDeviceText} from '../utils/deviceIdentity.ts';
import {encryptVaultText,decryptVaultText} from '../utils/vaultContent.ts';

export interface LocalLaunchDraftRef {
  executorBridge: string; draftId: string; revision: string; configurationDigest: string;
}
export interface LocalLaunchOperation { request: string }
export interface PendingLocalLaunch {
  operation: LocalLaunchOperation; relay: ExecutorDocument;
}
function currentKeys(session: OwnerSession, bridgeId: string): [OwnerVerifiedKey,OwnerVerifiedKey] {
  const device = session.chain.trusted.get(session.identity.deviceId);
  const host = [...session.chain.trusted.values()].find(d => d.kind === 'bridge' && d.row.bridge_id === bridgeId);
  if (session.chain.userId !== session.identity.userId || session.keyring.userId !== session.identity.userId ||
      device?.kind !== 'browser' || device.sign_public_key !== session.identity.signPub || !host) {
    throw new Error('Current paired device and execution Bridge required');
  }
  return [
    {account_id:session.identity.userId,principal_id:session.identity.deviceId,key_id:session.identity.deviceId,
      public_key:device.sign_public_key,kind:'device',enrolled:true,revoked:false},
    {account_id:session.identity.userId,principal_id:bridgeId,key_id:host.device_id,
      public_key:host.sign_public_key,kind:'bridge',enrolled:true,revoked:false},
  ];
}

// Save this exact signed operation until its reply is authenticated. Transport
// retries replace only the envelope/request ID, never the command identity.
export async function prepareLocalLaunchOperation(session: OwnerSession, draft: LocalLaunchDraftRef,
  method: 'prepare'|'inspect'|'authorize'|'cancel', operationId = ownerId('local_')): Promise<LocalLaunchOperation> {
  currentKeys(session,draft.executorBridge);
  const now = Date.now();
  const request: ExecutorDocument = {protocol_version:'1',account_id:session.identity.userId,
    executor_bridge_id:draft.executorBridge,principal_id:session.identity.deviceId,operation_id:operationId,method,
    draft_id:draft.draftId,draft_revision:draft.revision,configuration_digest:draft.configurationDigest,
    issued_ms:String(now),request_expires_ms:String(now+60000),key_id:session.identity.deviceId,signature:'0'.repeat(128)};
  request.signature = JSON.parse(await signDeviceText(session.identity,executorCanonical('local_draft',request))).sig as string;
  executorParse(JSON.stringify(request),'local_draft');
  return {request:JSON.stringify(request)};
}
export async function localLaunchRelay(session: OwnerSession, operation: LocalLaunchOperation): Promise<PendingLocalLaunch> {
  const command = executorParse(operation.request,'local_draft'), [device] = currentKeys(session,command.executor_bridge_id);
  if (!await executorVerify('local_draft',command,device)) throw new Error('Local launch operation is not owned by this device');
  const relay: ExecutorDocument = {protocol_version:'1',bridge_id:command.executor_bridge_id,request_id:ownerId('local_req_'),
    expires_ms:String(Date.now()+60000),envelope:await encryptVaultText(operation.request,session.keyring)};
  executorParse(JSON.stringify(relay),'local_relay');
  return {operation,relay};
}
// A reply is an authenticated observation, never a fresh launch permission.
// Historical authorize replies can report their original state after cancel;
// a new inspect operation retrieves current state.
export async function openLocalLaunchReply(session: OwnerSession, pending: PendingLocalLaunch,
  reply: {request_id?:string;envelope?:string}): Promise<{code:string;body:string}> {
  const request = executorParse(pending.operation.request,'local_draft');
  const [,host] = currentKeys(session,request.executor_bridge_id);
  if (reply.request_id !== pending.relay.request_id || !reply.envelope || BigInt(Date.now()) >= BigInt(pending.relay.expires_ms)) {
    throw new Error('Local launch response expired or mismatched');
  }
  const bundle = executorParse(await decryptVaultText(reply.envelope,session.keyring),'local_bundle');
  const receipt = executorParse(bundle.receipt,'local_result'), now = BigInt(Date.now());
  if (!await executorVerify('local_result',receipt,host) ||
      receipt.account_id !== request.account_id || receipt.executor_bridge_id !== request.executor_bridge_id ||
      receipt.principal_id !== request.principal_id || receipt.operation_id !== request.operation_id ||
      receipt.request_id !== pending.relay.request_id || receipt.request_expires_ms !== pending.relay.expires_ms ||
      now < BigInt(receipt.issued_ms) || now >= BigInt(receipt.request_expires_ms) ||
      receipt.request_digest !== await ownerPayloadDigest(executorCanonical('local_draft',request)) ||
      receipt.result_digest !== await ownerPayloadDigest(bundle.body)) throw new Error('Local launch response signature or binding mismatch');
  const result: unknown = JSON.parse(bundle.body);
  if (!result || typeof result !== 'object' || Object.keys(result).length !== 2 ||
      !('code' in result) || typeof result.code !== 'string' || !('body' in result) || typeof result.body !== 'string') {
    throw new Error('Malformed local launch result');
  }
  return {code:result.code,body:result.body};
}
