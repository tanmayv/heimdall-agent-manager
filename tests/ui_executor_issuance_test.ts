import {test} from 'node:test';
import assert from 'node:assert/strict';
import {FakeHub,USER} from './helpers/vaultDirectoryFixture.ts';
import {createDeviceIdentity,memoryDeviceStore} from '../src/ui/utils/deviceIdentity.ts';
import {importKeyring} from '../src/ui/utils/vaultKeyring.ts';
import {decryptVaultText} from '../src/ui/utils/vaultContent.ts';
import {prepareExecutorIssuance,executorIssuanceRelay,openExecutorIssuanceReply} from '../src/ui/api/executorIssuance.ts';
import {executorCanonical,executorParse,type ExecutorKind,type ExecutorDocument} from '../src/ui/api/executor.ts';
import {ownerPayloadDigest} from '../src/ui/api/ownerLocal.ts';
import {openSignedExecutorChannel,sealExecutorChannel} from '../src/ui/api/executorChannel.ts';

test('issuance client signs selectors, hides transport metadata, retains operation across retries and verifies current enrolled replies',async()=>{
  const identity=await createDeviceIdentity(memoryDeviceStore(),USER),hub=new FakeHub();
  await hub.genesis(identity);
  await hub.addBridge(identity,'owner');
  const host=await hub.addBridge(identity,'executor');
  const session={identity,chain:await hub.chain(),keyring:await importKeyring(await hub.keyringBytes(identity),USER)};
  const operation=await prepareExecutorIssuance(session,{ownerBridge:'owner',executorBridge:'executor',chainId:'chain',taskId:'task',agentId:'author',
    configurationRevision:'1',ownerIncarnation:'1',executorIncarnation:'1',
    selection:{provider:'codex',model:'模型🚀',provider_profile:'codex',directory_id:'remote_dir',policy_revision:'1',slot_id:'slot'}});
  const pending=await executorIssuanceRelay(session,operation),retry=await executorIssuanceRelay(session,operation);
  assert.equal(pending.operation.consent,retry.operation.consent);
  assert.notEqual(pending.scope.request_id,retry.scope.request_id);
  assert.equal('scope' in pending.relay,false);
  assert.equal(JSON.stringify(pending.relay).includes('模型'),false);
  const exchange=executorParse(await decryptVaultText(pending.relay.envelope,session.keyring),'issuance_exchange');
  const scope=executorParse(exchange.scope,'transport_scope');
  assert.equal(exchange.selection,operation.selection);
  const deviceKey={account_id:USER,principal_id:identity.deviceId,key_id:identity.deviceId,public_key:identity.signPub,kind:'device',enrolled:true,revoked:false};
  const consentRaw=await openSignedExecutorChannel(exchange.envelope,session.keyring,scope,deviceKey,BigInt(Date.now()));
  assert.equal(consentRaw,operation.consent);
  const consent=executorParse(operation.consent,'issuance_consent'),selection=executorParse(operation.selection,'issuance_selection');
  assert.throws(()=>executorParse(JSON.stringify({...selection,directory_path:'/caller'}),'issuance_selection'));
  const config:ExecutorDocument={protocol_version:'1',account_id:USER,owner_bridge_id:'owner',executor_bridge_id:'executor',executor_key_id:host.deviceId,
    chain_id:'chain',task_id:'task',instance_id:'inst_executor_generated',agent_id:'author',launch_epoch:'launch_generated',run_count:'1',
    token_generation:'a'.repeat(64),configuration_revision:'1',executor_incarnation:'1',...selection,directory_key:'b'.repeat(64),directory_path:'/repo'};
  const configuration=JSON.stringify(config);
  const sign=async(kind:ExecutorKind,value:ExecutorDocument)=>({...value,signature:Buffer.from(await crypto.subtle.sign({name:'ECDSA',hash:'SHA-256'},
    host.identity.privateKey,new TextEncoder().encode(executorCanonical(kind,value)))).toString('hex')});
  const issued=String(Date.now());
  const enrollment=await sign('enrollment',{protocol_version:'1',account_id:USER,owner_bridge_id:'owner',executor_bridge_id:'executor',chain_id:'chain',
    task_id:'task',instance_id:config.instance_id,configuration_revision:'1',configuration_digest:await ownerPayloadDigest(configuration),
    issued_ms:issued,request_expires_ms:consent.request_expires_ms,key_id:host.deviceId,signature:'0'.repeat(128)});
  const receipt=await sign('issuance_receipt',{protocol_version:'1',account_id:USER,owner_bridge_id:'owner',executor_bridge_id:'executor',chain_id:'chain',task_id:'task',
    operation_id:consent.operation_id,principal_id:identity.deviceId,request_digest:pending.scope.input_digest,configuration_digest:enrollment.configuration_digest,
    enrollment_digest:await ownerPayloadDigest(executorCanonical('enrollment',enrollment)),issued_ms:issued,request_expires_ms:consent.request_expires_ms,
    key_id:host.deviceId,signature:'0'.repeat(128)});
  const bundle={configuration,attestation:JSON.stringify(enrollment),issuance_receipt:JSON.stringify(receipt)};
  const envelope=await sealExecutorChannel(JSON.stringify(bundle),session.keyring,{...pending.scope,direction:'response'},BigInt(Date.now()));
  const reply={code:'ok',request_id:pending.scope.request_id,envelope};
  assert.deepEqual({...await openExecutorIssuanceReply(session,pending,reply)},bundle);
  await assert.rejects(openExecutorIssuanceReply(session,retry,{...reply,request_id:retry.scope.request_id}));
  await assert.rejects(openExecutorIssuanceReply(session,pending,{...reply,request_id:'another'}));
  const revoked={...session,chain:{...session.chain,trusted:new Map(session.chain.trusted)}};
  revoked.chain.trusted.delete(host.deviceId);
  await assert.rejects(executorIssuanceRelay(revoked,operation));
  await assert.rejects(openExecutorIssuanceReply(revoked,pending,reply));
  const forged=await sealExecutorChannel(JSON.stringify({...bundle,issuance_receipt:JSON.stringify({...receipt,signature:'0'.repeat(128)})}),
    session.keyring,{...pending.scope,direction:'response'},BigInt(Date.now()));
  await assert.rejects(openExecutorIssuanceReply(session,pending,{...reply,envelope:forged}));
});
