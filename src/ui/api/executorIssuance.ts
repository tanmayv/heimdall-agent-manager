import {executorCanonical,executorParse,type ExecutorDocument} from './executor.ts';
import {ownerPayloadDigest,type OwnerVerifiedKey} from './ownerLocal.ts';
import {sealExecutorChannel,openExecutorIssuance} from './executorChannel.ts';
import {ownerId,type OwnerSession} from './ownerLocalClient.ts';
import {signDeviceText} from '../utils/deviceIdentity.ts';
import {encryptVaultText} from '../utils/vaultContent.ts';

export interface ExecutorIssuanceInput {
  ownerBridge: string; executorBridge: string; chainId: string; taskId: string; agentId: string;
  configurationRevision: string; ownerIncarnation: string; executorIncarnation: string;
  selection: ExecutorDocument; operationId?: string;
}
export interface ExecutorIssuanceOperation { consent: string; selection: string; scope: ExecutorDocument }
export interface PendingExecutorIssuance {
  operation: ExecutorIssuanceOperation; scope: ExecutorDocument;
  relay: {protocol_version:string;chain_id:string;bridge_id:string;request_id:string;expires_ms:string;envelope:string};
}
function bridge(session: OwnerSession, id: string) {
  return [...session.chain.trusted.values()].find(d => d.kind === 'bridge' && d.row.bridge_id === id);
}
function enrolledKeys(session: OwnerSession, executorBridge: string, executorKey: string): [OwnerVerifiedKey,OwnerVerifiedKey] {
  const device = session.chain.trusted.get(session.identity.deviceId), host = bridge(session,executorBridge);
  if (session.chain.userId !== session.identity.userId || session.keyring.userId !== session.identity.userId ||
      device?.kind !== 'browser' || device.sign_public_key !== session.identity.signPub || !host || host.device_id !== executorKey) {
    throw new Error('Current paired device and executor enrollment required');
  }
  return [
    {account_id:session.identity.userId,principal_id:session.identity.deviceId,key_id:session.identity.deviceId,
      public_key:device.sign_public_key,kind:'device',enrolled:true,revoked:false},
    {account_id:session.identity.userId,principal_id:executorBridge,key_id:executorKey,
      public_key:host.sign_public_key,kind:'bridge',enrolled:true,revoked:false},
  ];
}
// Keep this operation for lost-reply recovery; never regenerate its consent or
// operation id. Runtime credentials and canonical paths are executor-generated.
export async function prepareExecutorIssuance(session: OwnerSession, input: ExecutorIssuanceInput): Promise<ExecutorIssuanceOperation> {
  const host = bridge(session,input.executorBridge), owner = bridge(session,input.ownerBridge);
  if (!host || !owner || input.ownerBridge === input.executorBridge) throw new Error('Distinct enrolled owner and executor required');
  enrolledKeys(session,input.executorBridge,host.device_id);
  const selection = JSON.stringify(executorParse(JSON.stringify(input.selection),'issuance_selection'));
  const now = Date.now();
  const consent: ExecutorDocument = {protocol_version:'1',account_id:session.identity.userId,owner_bridge_id:input.ownerBridge,
    executor_bridge_id:input.executorBridge,executor_key_id:host.device_id,chain_id:input.chainId,task_id:input.taskId,
    agent_id:input.agentId,configuration_revision:input.configurationRevision,operation_id:input.operationId ?? ownerId('issue_'),
    principal_id:session.identity.deviceId,selection_digest:await ownerPayloadDigest(selection),issued_ms:String(now),
    request_expires_ms:String(now+300000),key_id:session.identity.deviceId,signature:'0'.repeat(128)};
  consent.signature = JSON.parse(await signDeviceText(session.identity,executorCanonical('issuance_consent',consent))).sig as string;
  const scope: ExecutorDocument = {protocol_version:'1',account_id:consent.account_id,owner_bridge_id:input.ownerBridge,
    executor_bridge_id:input.executorBridge,chain_id:input.chainId,reservation_id:'',request_id:ownerId('req_'),
    method:'enrollment',direction:'request',input_digest:await ownerPayloadDigest(executorCanonical('issuance_consent',consent)),
    fence_digest:consent.selection_digest,owner_incarnation:input.ownerIncarnation,executor_incarnation:input.executorIncarnation,
    issued_ms:String(now),request_expires_ms:String(now+60000)};
  executorParse(JSON.stringify(scope),'transport_scope');
  return {consent:JSON.stringify(consent),selection,scope};
}
export async function executorIssuanceRelay(session: OwnerSession, operation: ExecutorIssuanceOperation): Promise<PendingExecutorIssuance> {
  const consent = executorParse(operation.consent,'issuance_consent'), now = BigInt(Date.now());
  const scope: ExecutorDocument = {...operation.scope,request_id:ownerId('req_'),issued_ms:String(now),request_expires_ms:String(now+60000n)};
  enrolledKeys(session,consent.executor_bridge_id,consent.executor_key_id);
  if (scope.method !== 'enrollment' || scope.direction !== 'request' || scope.executor_bridge_id !== consent.executor_bridge_id ||
      scope.input_digest !== await ownerPayloadDigest(executorCanonical('issuance_consent',consent)) ||
      scope.fence_digest !== await ownerPayloadDigest(operation.selection)) throw new Error('Issuance operation mismatch');
  const envelope = await sealExecutorChannel(operation.consent,session.keyring,scope,now);
  const exchange = JSON.stringify({scope:JSON.stringify(scope),envelope,selection:operation.selection});
  executorParse(exchange,'issuance_exchange');
  return {operation,scope,relay:{protocol_version:'1',chain_id:scope.chain_id,bridge_id:scope.executor_bridge_id,request_id:scope.request_id,
    expires_ms:scope.request_expires_ms,envelope:await encryptVaultText(exchange,session.keyring)}};
}
export async function openExecutorIssuanceReply(session: OwnerSession, pending: PendingExecutorIssuance, reply: {code?:string;request_id?:string;envelope?:string}) {
  const consent = executorParse(pending.operation.consent,'issuance_consent');
  const [device,host] = enrolledKeys(session,consent.executor_bridge_id,consent.executor_key_id);
  if (reply.code !== 'ok' || reply.request_id !== pending.scope.request_id || typeof reply.envelope !== 'string') throw new Error(reply.code ?? 'Executor unavailable');
  const plain = await openExecutorIssuance(reply.envelope,session.keyring,{...pending.scope,direction:'response'},consent,
    pending.operation.selection,device,host,BigInt(Date.now()));
  if (plain === null) throw new Error('Executor issuance response binding mismatch');
  return executorParse(plain,'issuance_bundle');
}
