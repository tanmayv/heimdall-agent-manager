// One-shot legacy chain import ("Import all") against the disposable
// enrollment harness (real Hub, real enrolled Bridge). The Hub task-chain
// engine is removed: nothing creates Hub chains any more, so the legacy
// fixture is seeded straight into the Hub DB (seedLegacy), including a busy
// chain (live lease, in-progress and in-review tasks, a running workflow).
// Run with HEIMDALL_E2E_OWNER_LOCAL=1 and HEIMDALL_E2E_OWNER_MIGRATION_ONLY=1.
import { prepareOwnerOperation, openOwnerReply, ownerRelayFile } from '../../src/ui/api/ownerLocalClient.ts';
import { prepareMigrationRequest } from '../../src/ui/api/ownerMigrationClient.ts';
import { importAllLegacyChains, listLegacyChains, type ImportAllResult } from '../../src/ui/api/ownerImportAll.ts';
import { decryptVaultText, encryptVaultText } from '../../src/ui/utils/vaultContent.ts';

const IDLE = 'chain_legacy_idle';
const BUSY = 'chain_legacy_busy';

export async function ownerMigrationFlow({session,bridgeId,hub,http,expect,cli,stopOwner,restartOwner,ownerLog,seedLegacy,queryHub}:any) {
  const bridgeDiagnostics=()=>{
    const lines=String(ownerLog?.() ?? '').split('\n').filter((l)=>l.includes('owner_migration_import storage_error'));
    return lines.length? ' owner Bridge: '+lines.slice(-5).join(' | ') : '';
  };
  const enc=(s:string)=>encryptVaultText(s,session.keyring);
  const account=session.identity.userId;

  // New Hub chains are refused with the typed 410.
  const created=await http(hub,'POST','/api/v1/task-chains',{body:{title:await enc('never created'),kind:'mixed_work'}});
  expect(created.status===410 && created.raw.includes('hub_chains_removed'),'Hub chain creation answers 410 hub_chains_removed: '+created.status+' '+created.raw);

  // Legacy fixture: one idle chain and one busy chain.
  const now=new Date().toISOString();
  const chainRow=async(id:string,title:string)=>['INSERT INTO task_chains(chain_id,owner_user_id,title,description,publish_state,status,kind,created_at,updated_at) VALUES(?,?,?,?,?,?,?,?,?)',
    [id,account,await enc(title),await enc(title+' description'),'published','active','mixed_work',now,now]];
  const taskRow=async(id:string,chain:string,state:string,attempt:number)=>['INSERT INTO tasks(task_id,chain_id,owner_user_id,title,description,publish_state,state,attempt_no,brief_json,created_at,updated_at) VALUES(?,?,?,?,?,?,?,?,?,?,?)',
    [id,chain,account,await enc('task '+id),await enc('body '+id),'published',state,attempt,'{"goal":"Ship it","acceptance":["Works"]}',now,now]];
  await seedLegacy([
    await chainRow(IDLE,'Legacy idle chain'),
    await taskRow('task_idle_ready',IDLE,'ready',0),
    await chainRow(BUSY,'Legacy busy chain'),
    await taskRow('task_busy_progress',BUSY,'in_progress',1),
    await taskRow('task_busy_review',BUSY,'in_review',1),
    await taskRow('task_busy_ready',BUSY,'ready',0),
    ['INSERT INTO task_leases(lease_id,task_id,chain_id,owner_user_id,attempt_no,holder_instance_id,kind,granted_at,expires_at,hard_deadline_at,delivery) VALUES(?,?,?,?,?,?,?,?,?,?,?)',
      ['lease_busy','task_busy_progress',BUSY,account,1,'inst_gone','work',now,now,now,'wake']],
    ['INSERT INTO workflow_runs(run_id,chain_id,owner_user_id,title,definition_ref,spec_json,inputs_json,current_execution_no,request_id,request_hash,created_by_kind,created_by_id,created_at,updated_at,revision) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)',
      ['wrun_busy',BUSY,account,'Run','def:1','{}','{}',1,'req_busy','hash_busy','user',account,now,now,1]],
    ['INSERT INTO workflow_run_executions(run_id,execution_no,chain_id,owner_user_id,state,resolved_inputs_json,output_manifest_json,revision) VALUES(?,?,?,?,?,?,?,?)',
      ['wrun_busy',1,BUSY,account,'running','{}','{}',1]],
  ]);
  const still=await http(hub,'POST','/api/v1/task-chains/'+BUSY+'/tasks',{body:{title:'late'}});
  expect(still.status===410,'legacy Hub task routes answer 410: '+still.status);

  const listed=await listLegacyChains(async(p:string)=>{const r=await http(hub,'GET',p);if(r.status!==200) throw new Error(r.raw);return r.data;});
  const byId=new Map(listed.map((c)=>[c.chain_id,c]));
  expect(byId.get(IDLE)?.state==='none' && byId.get(BUSY)?.state==='none' && byId.get(BUSY)?.task_count===3,'Import all lists both legacy chains as not imported: '+JSON.stringify(listed));
  const preflight=await http(hub,'GET','/api/v1/owner-local/migrations/preflight?chain_id='+BUSY);
  const codes=(preflight.data?.blockers??[]).map((b:any)=>b.code);
  expect(preflight.status===200 && codes.includes('live_leases') && codes.includes('running_workflows') && codes.includes('tasks_in_review'),'preflight reports the live work the import will neutralize: '+preflight.raw);

  const deps={
    fetchJson:async(p:string)=>{const r=await http(hub,'GET',p);if(r.status!==200) throw Object.assign(new Error(r.raw),{status:r.status});return r.data;},
    post:async(p:string,body:unknown)=>{const r=await http(hub,'POST',p,{body});if(r.status!==200){let code='';try{code=JSON.parse(r.raw).error?.code??'';}catch{}throw Object.assign(new Error(r.raw),{status:r.status,code});}return r.data;},
    prepare:(chainId:string,bridge:string,revision:number)=>prepareMigrationRequest(session,chainId,bridge,revision),
    decryptTitle:(t:string)=>decryptVaultText(t,session.keyring),
  };
  const only=(results:ImportAllResult[])=>results.filter((r)=>r.chainId===IDLE || r.chainId===BUSY);

  // Owner offline: both chains freeze (busy work neutralized in the freeze
  // transaction) and stay frozen; nothing is imported.
  await stopOwner();
  const offline=only(await importAllLegacyChains(bridgeId,deps));
  expect(offline.length===2 && offline.every((r)=>r.outcome==='failed' && /owner_unavailable|offline/i.test(r.message)),'offline owner: both imports fail and stay frozen: '+JSON.stringify(offline));
  const frozen=await http(hub,'GET','/api/v1/owner-local/migrations/preflight?chain_id='+BUSY);
  const neutralized=(frozen.data?.neutralized??[]).map((b:any)=>b.code);
  expect(frozen.data?.state==='frozen' && JSON.stringify(frozen.data?.forced_held)===JSON.stringify(['task_busy_progress'])
    && neutralized.includes('live_leases_ended') && neutralized.includes('workflows_cancelled') && neutralized.includes('tasks_in_review_carried'),
    'the busy chain froze with its work neutralized: '+frozen.raw);
  const hubState=await queryHub(`SELECT (SELECT count(*) FROM task_leases WHERE chain_id=?),(SELECT state FROM workflow_run_executions WHERE run_id='wrun_busy')`,[BUSY]);
  expect(hubState[0][0]===0 && hubState[0][1]==='cancelled','the live lease ended and the running workflow was cancelled in the Hub DB: '+JSON.stringify(hubState));

  // Owner back: Import all aborts the unfinished moves (their signed requests
  // are not ours), re-signs and imports both. Retried while the Bridge reconnects.
  await restartOwner();
  let results:ImportAllResult[]=[];const tried:string[]=[];
  for(let i=0;i<20;i++){
    results=only(await importAllLegacyChains(bridgeId,deps));
    tried.push(results.map((r)=>r.chainId+':'+r.outcome).join('|'));
    if(results.every((r)=>r.outcome==='imported' || r.outcome==='skipped')) break;
    await new Promise((r)=>setTimeout(r,1000));
  }
  const busy=results.find((r)=>r.chainId===BUSY);
  expect(results.every((r)=>r.outcome==='imported' || r.outcome==='skipped') && results.some((r)=>r.chainId===IDLE),'Import all imports both chains: '+JSON.stringify(results)+' tries='+tried.join(',')+bridgeDiagnostics());
  expect(busy?.outcome!=='imported' || JSON.stringify(busy?.forcedHeld)===JSON.stringify(['task_busy_progress']),'the import result names the force-held task: '+JSON.stringify(busy));

  // Idempotent: a second run skips every imported chain.
  const again=only(await importAllLegacyChains(bridgeId,deps));
  expect(again.length===2 && again.every((r)=>r.outcome==='skipped'),'re-running Import all skips imported chains: '+JSON.stringify(again));
  const after=await listLegacyChains(deps.fetchJson);
  expect(after.filter((c)=>c.chain_id===IDLE || c.chain_id===BUSY).every((c)=>c.state==='imported' && c.owner_bridge_id===bridgeId),'both chains are imported to this Bridge');

  // The owner serves the imported chain; the in-progress task arrived held and
  // the in-review task in review.
  const relay=async(chainId:string,method:string,input:any)=>{
    const op=await prepareOwnerOperation(session,bridgeId,method,{chainId,...input});
    return openOwnerReply(session,op,await cli(await ownerRelayFile(session,op)));
  };
  let read:any=null;
  for(let i=0;i<40 && !read;i++){
    try{ read=JSON.parse((await relay(BUSY,'chain.read',{expectedRevision:'0'})).body); }catch{await new Promise((r)=>setTimeout(r,1000));}
  }
  expect(read && JSON.stringify(read).includes('Legacy busy chain'),'owner serves the imported busy chain decrypted locally: '+JSON.stringify(read));
  const held=JSON.parse((await relay(BUSY,'runtime.read',{taskId:'task_busy_progress',expectedRevision:'0'})).body);
  expect(JSON.stringify(held.controls ?? []).includes('"held"'),'the force-held task is held on the owner: '+JSON.stringify(held));
  const review=JSON.parse((await relay(BUSY,'runtime.read',{taskId:'task_busy_review',expectedRevision:'0'})).body);
  expect(JSON.stringify(review.state ?? []).includes('"in_review"'),'the in-review task is carried over in review: '+JSON.stringify(review));

  let registered=false;
  for(let i=0;i<20 && !registered;i++){
    const rows=await http(hub,'GET','/api/v1/owner-local/chains?chain_id='+encodeURIComponent(IDLE));
    registered=rows.status===200 && (rows.data??[]).some((r:any)=>r.chain_id===IDLE && r.owner_bridge_id===bridgeId);
    if(!registered) await new Promise((r)=>setTimeout(r,1000));
  }
  expect(registered,'owner-signed registry publication is accepted for the imported chain');
}
