import { prepareOwnerOperation, ownerId, ownerRelayFile, openOwnerReply } from '../../src/ui/api/ownerLocalClient.ts';
import { readFileSync } from 'node:fs';

// Actual CLI -> Hub relay -> enrolled disposable Bridge, using UI signatures.
export async function ownerLocalMetadataFlow({session,bridgeId,cli,expect,stopOwner,restartOwner,launchChild}:any) {
  const chainId=ownerId('chain_');
  const prepare=(method:string,input:any={})=>prepareOwnerOperation(session,bridgeId,method,{chainId,expectedRevision:'0',...input});
  const invoke=async(op:any)=>openOwnerReply(session,op,await cli(await ownerRelayFile(session,op)));
  const call=async(method:string,input:any={})=>invoke(await prepare(method,input));
  const denied=async(method:string,input:any,message:string)=>{let rejected=false;try{await call(method,input);}catch{rejected=true;}expect(rejected,message);};
  await call('chain.create',{title:'Native metadata snapshot',description:'Disposable C1d source provenance'});
  const fixture=(kind:string)=>{
    const bundle=JSON.parse(readFileSync(new URL('../../src/contracts/fixtures/owner-native-metadata-'+kind+'.json',import.meta.url),'utf8'));
    bundle.chain_id=chainId;
    for(const row of bundle.records)row.chain_id=chainId;
    return bundle;
  };
  const members=fixture('members'),directories=fixture('directories');
  const exact=await prepare('native.metadata.import',{expectedRevision:'1',body:JSON.stringify(members)});
  const accepted=await invoke(exact);
  expect(JSON.parse(accepted.body).revision==='2','signed native metadata import advances chain CAS');
  await call('native.metadata.import',{expectedRevision:'2',body:JSON.stringify(directories)});
  const read=async(kind:string,input:any={})=>JSON.parse((await call('native.metadata.read',{nativeSourceRevision:'native_revision_7',nativeHistoryKind:kind,...input})).body);
  for(const bundle of [members,directories]){
    const page=await read(bundle.kind);
    expect(page.owner_user_id==='native_owner','original owner retained independently of local account');
    expect(page.items.length===bundle.records.length && page.items.every((row:any)=>bundle.records.some((expected:any)=>Object.keys(row).length===Object.keys(expected).length && Object.entries(expected).every(([key,value])=>row[key]===value))),'real CLI round-trips every ordinary native member/directory field');
  }
  const first=await read('member',{limit:1}),second=await read('member',{limit:1,cursor:first.next_cursor});
  expect(first.items.length===1 && first.next_cursor && second.items.length===1 && !second.next_cursor,'immutable source pages include empty native instance key once');
  await denied('native.metadata.read',{nativeSourceRevision:'native_revision_7',nativeHistoryKind:'directory',cursor:first.next_cursor},'source page cannot cross kind');
  await denied('native.metadata.import',{expectedRevision:'2',body:JSON.stringify(members)},'stale import CAS rejected');
  const changed={...directories,records:directories.records.map((row:any)=>({...row,path:'/changed'}))};
  await denied('native.metadata.import',{expectedRevision:'3',body:JSON.stringify(changed)},'same pinned source revision rejects conflicting native metadata');
  const later={...members,source_revision:'native_revision_8',records:members.records.map((row:any)=>({...row,role:'reviewer'}))};
  await call('native.metadata.import',{expectedRevision:'3',body:JSON.stringify(later)});
  const old=await read('member'),latest=await read('member',{nativeSourceRevision:'native_revision_8'});
  expect(old.items.some((row:any)=>row.role==='coordinator') && latest.items.every((row:any)=>row.role==='reviewer'),'later source revision preserves complete old snapshot');
  expect((await invoke(exact)).replay,'exact signed lost-reply replay survives later imports');
  const events=JSON.parse((await call('history.read')).body);
  const event=events.items.find((item:any)=>item.kind==='native.metadata.import');
  const evidence=JSON.parse((await call('history.fetch',{eventSeq:event.seq})).body);
  expect(JSON.parse(JSON.parse(evidence.evidence).content).body===JSON.stringify(members),'exact original imported document remains in signed immutable history');

  const facts=['chain','task','comment','summary'].map(fixture);
  let revision=4;
  for(const bundle of facts) {
    const prepared=await prepare('native.metadata.import',{expectedRevision:String(revision),body:JSON.stringify(bundle)});
    await invoke(prepared);revision++;
    const page=await read(bundle.kind);
    expect(page.items.length===1 && Object.keys(page.items[0]).length===Object.keys(bundle.records[0]).length && Object.entries(bundle.records[0]).every(([key,value])=>page.items[0][key]===value),'real CLI preserves all native '+bundle.kind+' fields and scalar types');
    expect((await invoke(prepared)).replay,'exact source '+bundle.kind+' replay');
    const later={...bundle,source_revision:'native_revision_8',records:bundle.records.map((row:any)=>({...row,[bundle.kind==='chain'||bundle.kind==='task'?'title':'body']:'later source text'}))};
    await call('native.metadata.import',{expectedRevision:String(revision),body:JSON.stringify(later)});revision++;
    const old=(await read(bundle.kind)).items[0];
    expect(Object.entries(bundle.records[0]).every(([key,value])=>old[key]===value),'old source '+bundle.kind+' snapshot remains exact');
  }
  const taskId=ownerId('priority_task_');
  await call('task.create',{taskId,expectedRevision:String(revision),title:'Priority target',body:'Operational priority'});
  const priority=await prepare('task.priority',{taskId,expectedRevision:'1',priority:'p0'});
  await invoke(priority);
  expect(JSON.parse((await call('task.read',{taskId})).body).priority==='p0','signed ordinary priority update is consumed by task read');
  expect((await invoke(priority)).replay,'priority exact retry preserves accepted receipt');
  await denied('task.priority',{taskId,expectedRevision:'1',priority:'p1'},'stale priority CAS rejected');
  const listed=JSON.parse((await call('chain.read')).body);
  expect(listed.items.find((row:any)=>row.task_id===taskId)?.priority==='p0','chain listing consumes operational priority');
  const history=JSON.parse(readFileSync(new URL('../../src/contracts/fixtures/owner-native-history.json',import.meta.url),'utf8'));
  await denied('native.history.import',{taskId,expectedRevision:'2',body:JSON.stringify(history)},'native history rejects owner conflicting with metadata origins');
  history.owner_user_id=members.owner_user_id;
  for(const kind of ['attempts','events','facets']) {
    history[kind]=JSON.stringify(JSON.parse(history[kind]).map((raw:string)=>JSON.stringify({...JSON.parse(raw),chain_id:chainId,task_id:taskId,owner_user_id:history.owner_user_id})));
  }
  await call('native.history.import',{taskId,expectedRevision:'2',body:JSON.stringify(history)});
  const fleetRaw=readFileSync(new URL('../../src/contracts/fixtures/owner-fleet-policy.json',import.meta.url),'utf8').replace(/"task_chain_id":\s*"chain"/,'"task_chain_id":'+JSON.stringify(chainId));
  const fleet=JSON.parse(fleetRaw);
  const fleetSource='fleet_source_7';
  const fleetBundle=JSON.stringify({chain_id:chainId,owner_user_id:members.owner_user_id,source_revision:fleetSource,kind:'fleet'}).slice(0,-1)+',"records":['+fleetRaw+']}';
  let liveRevision=JSON.parse((await call('chain.read')).body).revision;
  await call('native.metadata.import',{expectedRevision:liveRevision,body:fleetBundle});
  expect(JSON.parse((await call('fleet.policy.read')).body).items.length===0,'fleet source import preserves snapshot without activating operational policy');
  const sourceFleet=await read('fleet',{nativeSourceRevision:fleetSource});
  expect(sourceFleet.items.length===1 && Object.entries(fleet).every(([key,value])=>sourceFleet.items[0][key]===value),'fleet snapshot preserves every ordinary source field');
  liveRevision=JSON.parse((await call('chain.read')).body).revision;
  await denied('fleet.policy.set',{expectedRevision:liveRevision,nativeSourceRevision:fleetSource,body:fleetRaw.replace('9007199254740993','9007199254740994')},'source-linked activation rejects policy drift');
  await call('fleet.policy.set',{expectedRevision:liveRevision,nativeSourceRevision:fleetSource,body:fleetRaw});
  expect(JSON.parse((await call('fleet.policy.read')).body).items[0].source_revision===fleetSource,'signed activation records pinned fleet source revision');
  liveRevision=JSON.parse((await call('chain.read')).body).revision;
  const curated=await prepare('chain.summary.set',{expectedRevision:liveRevision,body:'Curated notes: retained relay evidence 界'});
  await invoke(curated);
  expect((await invoke(curated)).replay,'summary exact receipt replays');
  await denied('chain.summary.set',{expectedRevision:liveRevision,body:'stale notes'},'summary stale chain CAS rejects');
  const summaries=JSON.parse((await call('chain.metadata.read')).body);
  expect(summaries.items[0].curated_body==='Curated notes: retained relay evidence 界','metadata history retains exact curated Unicode notes');
  const context=JSON.parse((await call('chain.read')).body).context;
  expect(context.body.includes('retained relay evidence'),'materialized context consumes operational notes');
  liveRevision=JSON.parse((await call('chain.read')).body).revision;
  const nativeDefaults='{ "review_roles": {"reviewer":"Curated 界 role description"}, "proposal":{"state":"pending"} }';
  const defaults=await prepare('chain.defaults.set',{expectedRevision:liveRevision,body:nativeDefaults});
  await invoke(defaults);
  expect((await invoke(defaults)).replay,'defaults exact receipt replays');
  expect(JSON.parse((await call('chain.read')).body).defaults_json===nativeDefaults,'ordinary chain read consumes exact native defaults');
  const defaultPage=JSON.parse((await call('chain.metadata.read',{limit:1})).body);
  expect(defaultPage.items[0].defaults_json===nativeDefaults && defaultPage.next_cursor,'bounded metadata page lists newest defaults');
  const summaryPage=JSON.parse((await call('chain.metadata.read',{limit:1,cursor:defaultPage.next_cursor})).body);
  expect(summaryPage.items[0].kind==='summary','metadata cursor advances across operational kinds');
  await stopOwner();await restartOwner();
  expect(JSON.parse((await call('chain.read')).body).defaults_json===nativeDefaults,'restart preserves exact operational defaults');
  expect((await invoke(defaults)).replay,'defaults receipt survives restart');
  expect(JSON.parse((await call('chain.metadata.read')).body).items.find((row:any)=>row.kind==='summary')?.curated_body==='Curated notes: retained relay evidence 界','restart preserves operational notes');
  expect((await invoke(curated)).replay,'summary receipt survives restart');
  expect(JSON.parse((await call('fleet.policy.read')).body).items[0].source_revision===fleetSource,'restart preserves fleet activation provenance');
  expect(JSON.parse((await call('task.read',{taskId})).body).priority==='p0','restart preserves operational priority');
  expect((await invoke(priority)).replay,'priority receipt survives restart and later task revisions');
  expect((await read('directory')).items[0].vcs_info_json===directories.records[0].vcs_info_json,'restart preserves native VCS string bytes and Unicode path');
  for(const bundle of facts) {
    expect((await read(bundle.kind)).items[0].updated_at===bundle.records[0].updated_at,'restart retains exact native '+bundle.kind+' timestamp');
    expect((await read(bundle.kind,{nativeSourceRevision:'native_revision_8'})).items.length===1,'restart retains newer '+bundle.kind+' source snapshot');
  }
  expect((await invoke(exact)).replay,'restart retains exact accepted import receipt');
  // Operational configuration uses live exact children, independently of the
  // imported provenance above. Read current revisions for every signed CAS.
  const worker=await launchChild(),reviewer=await launchChild();
  try {
    const chainRevision=async()=>JSON.parse((await call('chain.read')).body).revision;
    const mutate=async(method:string,input:any)=>call(method,{expectedRevision:await chainRevision(),...input});
    const join=await prepare('chain.member.set',{expectedRevision:await chainRevision(),instanceId:worker.instanceId,agentId:worker.agentId,memberRole:'worker'});
    await invoke(join);
    expect((await invoke(join)).replay,'real exact member retry returns original receipt');
    await denied('chain.member.set',{expectedRevision:await chainRevision(),instanceId:worker.instanceId,agentId:reviewer.agentId},'member requires Bridge-observed durable agent identity');
    await mutate('chain.member.set',{instanceId:reviewer.instanceId,agentId:reviewer.agentId,memberRole:'coordinator'});
    await denied('chain.member.set',{expectedRevision:await chainRevision(),instanceId:reviewer.instanceId,agentId:reviewer.agentId,memberRole:'coordinator',enabled:false},'real sole coordinator removal rejected');
    const directoryId=ownerId('dir_');
    const directory={directory_id:directoryId,chain_id:chainId,owner_user_id:session.identity.userId,path:'/operational/界',bridge_id:bridgeId,vcs_kind:'git',vcs_info_json:'{ "branch": "original" }',created_at:'original-time',updated_at:'updated-time'};
    const directoryOp=await prepare('chain.directory.set',{expectedRevision:await chainRevision(),directoryId,body:JSON.stringify(directory)});
    await invoke(directoryOp);
    expect((await invoke(directoryOp)).replay,'real directory retry preserves exact encrypted payload');
    const consumer=ownerId('task_');
    await mutate('task.create',{taskId:consumer,title:'Pinned input consumer',body:'Immutable output evidence'});
    await call('fleet.edit',{taskId:consumer,expectedRevision:'1',instanceId:worker.instanceId,configurationRevision:'1'});
    const config=(revision:string)=>({configuration_revision:revision,author_agent_id:worker.agentId,reviewer_agent_id:reviewer.agentId,reviewer_instance_id:reviewer.instanceId,directory_id:directoryId,merge_policy:'none',repository:'',worktree:'',source_branch:'',target_branch:'',base_head:''});
    await call('lifecycle.configure',{taskId:consumer,expectedRevision:'2',lifecycleConfig:config('1')});
    await denied('requirements.edit',{taskId:consumer,expectedRevision:'3',requirementsRevision:'1',body:JSON.stringify({goal:'Reject mutable input',acceptance:['Pinned only'],inputs:['output:'+taskId]})},'real requirements reject mutable latest output');
    const inputRef='output:'+taskId+':3:1';
    await call('requirements.edit',{taskId:consumer,expectedRevision:'3',requirementsRevision:'1',body:JSON.stringify({goal:'Read pinned native output',acceptance:['Preserve source'],inputs:[inputRef]})});
    const request={protocol_version:'1',chain_id:chainId,task_id:consumer,lease_id:ownerId('lease_'),configuration_revision:'1',expected_revision:'4',operation_id:ownerId('op_'),method:'lease.claim',request_expires_ms:String(Date.now()+300000),capability:''};
    const claim=worker.call(request);expect(claim.status===0,'real child claims pinned consumer');
    const capability=JSON.parse(claim.data.body).capability;
    const present={...request,method:'requirements.present',operation_id:ownerId('op_'),capability,payload:JSON.stringify({requirements_revision:'1'})};
    const shown=worker.call(present);expect(shown.status===0,'real child presents pinned requirements');
    const resolved=JSON.parse(JSON.parse(shown.data.body).resolved_inputs);
    expect(resolved.length===1 && resolved[0].ref===inputRef && resolved[0].chain_id===chainId && resolved[0].account_id===session.identity.userId && resolved[0].body.includes('import_pending'),'real presentation returns exact scoped immutable output and unresolved artifact provenance');
    await mutate('chain.member.set',{instanceId:worker.instanceId,agentId:worker.agentId,enabled:false});
    expect(worker.call(present).status!==0,'removed real member cannot replay prior authorized content');
    const removed=JSON.parse((await call('runtime.read',{taskId:consumer})).body);
    expect(removed.leases.length===0,'member removal retires current lease');
    const closed=JSON.parse((await call('attempt.read',{taskId:consumer,attempt:'1'})).body);
    expect(closed.completeness==='full' && closed.outcome==='expired:replaced' && closed.ended_ms,'member removal preserves complete native attempt expiry evidence');
    await mutate('chain.member.set',{instanceId:worker.instanceId,agentId:worker.agentId});
    expect(worker.call({...present,operation_id:ownerId('op_')}).status!==0,'rejoin does not revive old lifecycle capability');
    await call('fleet.edit',{taskId:consumer,expectedRevision:'5',instanceId:worker.instanceId,configurationRevision:'3'});
    await call('lifecycle.configure',{taskId:consumer,expectedRevision:'6',lifecycleConfig:config('3')});
    const fresh={...request,lease_id:ownerId('lease_'),configuration_revision:'3',expected_revision:'7',operation_id:ownerId('op_')};
    const reclaim=worker.call(fresh);expect(reclaim.status===0,'explicit fresh fleet/lifecycle enrollment restores dispatch');
    const newCap=JSON.parse(reclaim.data.body).capability;
    await mutate('chain.directory.set',{directoryId,body:JSON.stringify({...directory,path:'/operational/replacement',updated_at:'later'})});
    expect(worker.call({...fresh,method:'requirements.present',operation_id:ownerId('op_'),capability:newCap,payload:JSON.stringify({requirements_revision:'1'})}).status!==0,'changed directory invalidates active path binding and capability');
    const pathClosed=JSON.parse((await call('attempt.read',{taskId:consumer,attempt:'2'})).body);
    expect(pathClosed.completeness==='full' && pathClosed.outcome==='expired:replaced' && pathClosed.ended_ms,'directory mutation preserves complete native attempt expiry evidence');
    await mutate('chain.directory.set',{directoryId,enabled:false,body:JSON.stringify({...directory,path:'/operational/replacement',updated_at:'removed'})});
    const all:any[]=[];let cursor='';
    do {const page=JSON.parse((await call('chain.metadata.read',{limit:3,cursor})).body);all.push(...page.items);cursor=page.next_cursor;} while(cursor);
    expect(all.some((row:any)=>row.kind==='member' && row.current==='1' && row.entity_id===worker.instanceId && row.enabled==='1'),'real inventory consumes current operational membership');
    expect(all.some((row:any)=>row.kind==='directory' && row.current==='1' && row.entity_id===directoryId && row.enabled==='0'),'real inventory preserves directory removal tombstone');
    await stopOwner();await restartOwner();
    expect((await invoke(join)).replay && (await invoke(directoryOp)).replay,'restart retains original operational receipts after later revocations');
    expect(worker.call(present).status!==0,'restart preserves removed path authority fence');
  } finally { await worker.stop();await reviewer.stop(); }

}
