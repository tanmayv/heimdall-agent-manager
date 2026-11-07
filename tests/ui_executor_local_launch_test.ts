import {test} from 'node:test';
import assert from 'node:assert/strict';
import {FakeHub,USER} from './helpers/vaultDirectoryFixture.ts';
import {createDeviceIdentity,memoryDeviceStore} from '../src/ui/utils/deviceIdentity.ts';
import {importKeyring} from '../src/ui/utils/vaultKeyring.ts';
import {encryptVaultText,decryptVaultText} from '../src/ui/utils/vaultContent.ts';
import {prepareLocalLaunchOperation,localLaunchRelay,openLocalLaunchReply} from '../src/ui/api/executorLocalLaunch.ts';
import {executorCanonical,executorParse,executorVerify,type ExecutorDocument} from '../src/ui/api/executor.ts';
import {ownerPayloadDigest} from '../src/ui/api/ownerLocal.ts';

test('local draft client retains signed operation and verifies exact enrolled execution result',async()=>{
  const identity=await createDeviceIdentity(memoryDeviceStore(),USER),hub=new FakeHub();
  await hub.genesis(identity);
  const host=await hub.addBridge(identity,'executor');
  const session={identity,chain:await hub.chain(),keyring:await importKeyring(await hub.keyringBytes(identity),USER)};
  const draft={executorBridge:'executor',draftId:'a'.repeat(64),revision:'1',configurationDigest:'b'.repeat(64)};
  const operation=await prepareLocalLaunchOperation(session,draft,'prepare');
  const pending=await localLaunchRelay(session,operation),retry=await localLaunchRelay(session,operation);
  assert.equal(pending.operation.request,retry.operation.request);
  assert.notEqual(pending.relay.request_id,retry.relay.request_id);
  assert.equal('chain_id' in pending.relay,false);
  assert.equal('scope' in pending.relay,false);
  assert.equal(JSON.stringify(pending.relay).includes(draft.draftId),false);
  assert.equal(await decryptVaultText(pending.relay.envelope,session.keyring),operation.request);
  const request=executorParse(operation.request,'local_draft');
  const deviceKey={account_id:USER,principal_id:identity.deviceId,key_id:identity.deviceId,public_key:identity.signPub,kind:'device',enrolled:true,revoked:false};
  assert.equal(await executorVerify('local_draft',request,deviceKey),true);
  for(const method of ['inspect','authorize','cancel'] as const) {
    const other=await prepareLocalLaunchOperation(session,draft,method);
    const command=executorParse(other.request,'local_draft');
    assert.equal(command.method,method);
    assert.equal(await executorVerify('local_draft',command,deviceKey),true);
    assert.equal(await executorVerify('local_draft',{...command,method:'prepare'},deviceKey),false);
  }
  const body=JSON.stringify({code:'ok',body:JSON.stringify({draft_id:draft.draftId,state:'prepared'})});
  const receipt:ExecutorDocument={protocol_version:'1',account_id:USER,executor_bridge_id:'executor',principal_id:identity.deviceId,
    operation_id:request.operation_id,request_id:pending.relay.request_id,request_digest:await ownerPayloadDigest(executorCanonical('local_draft',request)),
    result_digest:await ownerPayloadDigest(body),issued_ms:String(Date.now()),request_expires_ms:pending.relay.expires_ms,
    key_id:host.deviceId,signature:'0'.repeat(128)};
  const sign=async(value:ExecutorDocument)=>({...value,signature:Buffer.from(await crypto.subtle.sign({name:'ECDSA',hash:'SHA-256'},
    host.identity.privateKey,new TextEncoder().encode(executorCanonical('local_result',value)))).toString('hex')});
  const sealed=await sign(receipt);
  const wrap=async(value:ExecutorDocument,result=body)=>encryptVaultText(JSON.stringify({receipt:JSON.stringify(value),body:result}),session.keyring);
  const reply={request_id:pending.relay.request_id,envelope:await wrap(sealed)};
  assert.deepEqual(await openLocalLaunchReply(session,pending,reply),JSON.parse(body));
  await assert.rejects(openLocalLaunchReply(session,retry,{...reply,request_id:retry.relay.request_id}));
  for(const name of ['principal_id','account_id','executor_bridge_id','operation_id','request_id','request_digest','result_digest','key_id']) {
    const changed={...receipt,[name]:name.endsWith('digest')?'c'.repeat(64):'other'};
    await assert.rejects(openLocalLaunchReply(session,pending,{...reply,envelope:await wrap(await sign(changed))}),name);
  }
  await assert.rejects(openLocalLaunchReply(session,pending,{...reply,envelope:await wrap({...sealed,signature:'0'.repeat(128)})}));
  await assert.rejects(openLocalLaunchReply(session,pending,{...reply,envelope:await wrap(sealed,JSON.stringify({code:'ok',body:'forged'}))}));
  const revoked={...session,chain:{...session.chain,trusted:new Map(session.chain.trusted)}};
  revoked.chain.trusted.delete(host.deviceId);
  await assert.rejects(localLaunchRelay(revoked,operation));
  await assert.rejects(openLocalLaunchReply(revoked,pending,reply));
  const foreign={...request,principal_id:'other'};
  await assert.rejects(localLaunchRelay(session,{request:JSON.stringify(foreign)}));
});
