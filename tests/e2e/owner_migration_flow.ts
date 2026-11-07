// R3 one-shot legacy chain migration against the disposable enrollment harness
// (real Hub, real enrolled Bridge). Run with HEIMDALL_E2E_OWNER_LOCAL=1 and
// HEIMDALL_E2E_OWNER_MIGRATION_ONLY=1.
import { prepareOwnerOperation, openOwnerReply, ownerRelayFile } from '../../src/ui/api/ownerLocalClient.ts';
import { prepareMigrationRequest } from '../../src/ui/api/ownerMigrationClient.ts';
import { encryptVaultText } from '../../src/ui/utils/vaultContent.ts';

export async function ownerMigrationFlow({session,bridgeId,hub,http,expect,cli,stopOwner,restartOwner}:any) {
  const enc=(s:string)=>encryptVaultText(s,session.keyring);
  const created=await http(hub,'POST','/api/v1/task-chains',{body:{title:await enc('Legacy migration chain'),description:await enc('Moved by R3'),kind:'mixed_work'}});
  expect(created.status===200 || created.status===201,'legacy chain created on the Hub: '+created.status+' '+created.raw);
  const chainId=created.data.chain_id;
  const task=await http(hub,'POST','/api/v1/task-chains/'+chainId+'/tasks',{body:{title:await enc('Legacy task'),description:await enc('legacy body'),brief:{goal:'Ship it',acceptance:['Works']}}});
  expect(task.status===200 || task.status===201,'legacy task created: '+task.status+' '+task.raw);
  const preflight=await http(hub,'GET','/api/v1/owner-local/migrations/preflight?chain_id='+encodeURIComponent(chainId));
  expect(preflight.status===200 && preflight.data.state==='none' && (preflight.data.blockers??[]).length===0,'idle legacy chain has no blockers: '+preflight.raw);
  const request=await prepareMigrationRequest(session,chainId,bridgeId,preflight.data.work_revision);
  // Owner offline: the chain freezes and stays frozen; nothing is imported.
  await stopOwner();
  const offline=await http(hub,'POST','/api/v1/owner-local/migrations',{body:request});
  expect(offline.status>=400 && /owner_unavailable|offline/i.test(offline.raw),'offline owner leaves the chain frozen: '+offline.status+' '+offline.raw);
  const frozenWrite=await http(hub,'PUT','/api/v1/task-chains/'+chainId+'/summary',{body:{body:'late legacy write'}});
  expect(frozenWrite.status>=400,'frozen legacy chain refuses writes: '+frozenWrite.status);
  await restartOwner();
  let moved:any;
  for(let i=0;i<20;i++){
    moved=await http(hub,'POST','/api/v1/owner-local/migrations',{body:request});
    if(moved.status===200) break;
    await new Promise((r)=>setTimeout(r,1000));
  }
  expect(moved.status===200 && moved.data.state==='imported','exact retry imports and cuts over: '+moved.raw);
  const replay=await http(hub,'POST','/api/v1/owner-local/migrations',{body:request});
  expect(replay.status===200 && replay.data.replayed && replay.data.manifest_digest===moved.data.manifest_digest,'same digest replays');
  const legacyWrite=await http(hub,'PUT','/api/v1/task-chains/'+chainId+'/summary',{body:{body:'after cutover'}});
  expect(legacyWrite.status>=400,'legacy writer stays disabled after cutover: '+legacyWrite.status);
  const relay=async(method:string,input:any)=>{
    const op=await prepareOwnerOperation(session,bridgeId,method,{chainId,...input});
    return openOwnerReply(session,op,await cli(await ownerRelayFile(session,op)));
  };
  const read=JSON.parse((await relay('chain.read',{expectedRevision:'0'})).body);
  expect(JSON.stringify(read).includes('Legacy migration chain'),'owner serves the imported chain decrypted locally');
  // Activation follows the Hub cutover; the first local mutation may race it.
  let commented=false;
  for(let i=0;i<40 && !commented;i++){
    try{
      await relay('task.comment',{taskId:task.data.task_id,expectedRevision:'1',body:'first owner-local comment'});commented=true;
    }catch{await new Promise((r)=>setTimeout(r,1000));}
  }
  expect(commented,'owner admits mutations only after activation');
  let listed=false;
  for(let i=0;i<20 && !listed;i++){
    const rows=await http(hub,'GET','/api/v1/owner-local/chains?chain_id='+encodeURIComponent(chainId));
    listed=rows.status===200 && (rows.data??[]).some((r:any)=>r.chain_id===chainId && r.owner_bridge_id===bridgeId);
    if(!listed) await new Promise((r)=>setTimeout(r,1000));
  }
  expect(listed,'owner-signed registry publication is accepted for the imported chain');
}
