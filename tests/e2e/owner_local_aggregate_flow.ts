import { readFileSync } from 'node:fs';
import { isDeepStrictEqual } from 'node:util';
import { prepareOwnerOperation, ownerId, ownerRelayFile, openOwnerReply } from '../../src/ui/api/ownerLocalClient.ts';

// Preserve exact integer tokens in the test oracle; upload original raw documents.
const exact=(raw:string)=>JSON.parse(raw,((key:string,value:any,context:any)=>{
  if(typeof value==='number' && Number.isInteger(value) && !Number.isSafeInteger(value)){
    if(!context?.source || !/^-?[0-9]+$/.test(context.source))throw new Error('Missing exact numeric source');
    return BigInt(context.source);
  }
  return value;
}) as any);

export async function ownerLocalAggregateFlow({session,bridgeId,cli,expect,stopOwner,restartOwner,launchChild,otherAccount,http,hub}:any) {
  const fixture=JSON.parse(readFileSync(new URL('../../src/contracts/fixtures/owner-native-aggregate.json',import.meta.url),'utf8'));
  const chainId=ownerId('rich_'),taskId=ownerId('live_'),archive='archive';
  const prepare=(method:string,input:any={})=>prepareOwnerOperation(session,bridgeId,method,{chainId,expectedRevision:'0',...input});
  const invoke=async(op:any)=>openOwnerReply(session,op,await cli(await ownerRelayFile(session,op)));
  const call=async(method:string,input:any={})=>invoke(await prepare(method,input));
  const read=async(method:string,input:any={})=>exact((await call(method,input)).body);
  const mutate=async(method:string,input:any={})=>{
    const revision=(await read(input.taskId?'task.read':'chain.read',input.taskId?{taskId:input.taskId}:{})).revision;
    return call(method,{expectedRevision:revision,...input});
  };
  const denied=async(method:string,input:any)=>{let rejected=false;try{await call(method,input);}catch{rejected=true;}expect(rejected,method+' preserves account/chain/cursor boundaries');};
  const scope=(raw:string)=>raw.replaceAll('"chain_id":"chain"','"chain_id":'+JSON.stringify(chainId)).replaceAll('"task_chain_id":"chain"','"task_chain_id":'+JSON.stringify(chainId));
  await call('chain.create',{title:'Full native aggregate',description:'C1f exact canonical source proof'});
  await call('task.create',{taskId:archive,expectedRevision:(await read('chain.read')).revision,title:'Original archive',body:'Immutable source scope holder'});
  await call('task.create',{taskId,expectedRevision:(await read('chain.read')).revision,title:'Live rich policy',body:'Ordinary signed exercise'});
  const accepted:any[]=[];
  const bundles=fixture.metadata.map((entry:any)=>({kind:entry.kind,raw:scope(entry.raw)}));
  for(const entry of bundles){
    const op=await prepare('native.metadata.import',{expectedRevision:(await read('chain.read')).revision,body:entry.raw});
    await invoke(op);accepted.push(op);
  }
  const history=JSON.parse(fixture.history);
  for(const kind of ['attempts','events','facets'])history[kind]=JSON.stringify(JSON.parse(history[kind]).map((raw:string)=>scope(raw)));
  const historyRaw=JSON.stringify(history);
  const originalHistory=await prepare('native.history.import',{taskId:archive,expectedRevision:'1',body:historyRaw});
  await invoke(originalHistory);
  const compare=async()=>{
    for(const entry of bundles){
      const expected=exact(entry.raw).records,seen=new Set<number>();let cursor='';
      do{
        const page=await read('native.metadata.read',{nativeSourceRevision:fixture.source_revision,nativeHistoryKind:entry.kind,cursor,limit:1});
        expect(page.owner_user_id==='original_user','original '+entry.kind+' owner is distinct from enrolled account');
        for(const row of page.items){
          const index=expected.findIndex((original:any)=>isDeepStrictEqual(row,original));
          expect(index>=0 && !seen.has(index),'every '+entry.kind+' field/type/tuple/timestamp survives exactly once');
          seen.add(index);
        }
        cursor=page.next_cursor;
      }while(cursor);
      expect(seen.size===expected.length,'complete '+entry.kind+' canonical export');
    }
    let chunked=false;
    for(const kind of ['attempt','event','facet']){
      for(const raw of JSON.parse(history[kind+'s'])){
        const record=JSON.parse(raw);
        const key=kind==='event'?record.event_id:kind==='attempt'?record.attempt_no:JSON.stringify([record.attempt_no,record.kind,record.v]);
        let offset='0',all='',chunks=0;
        do{
          const part=await read('native.history.fetch',{taskId:archive,nativeSourceRevision:fixture.source_revision,nativeHistoryKind:kind,nativeHistoryKey:key,offset});
          all+=part.record;offset=part.next_offset;chunks++;
        }while(offset);
        expect(all===raw,'exact original '+kind+' bytes including source author/time/version and unresolved refs');
        if(chunks>1)chunked=true;
      }
    }
    expect(chunked,'Unicode original evidence spans bounded fetch chunks without byte loss');
  };
  await compare();
  expect((await read('chain.read')).items.length===2,'rich source imports never create operational tasks');
  expect((await read('fleet.policy.read')).items.length===0,'native policy import cannot activate dispatch policy');
  expect((await invoke(accepted.find((op:any)=>JSON.parse(op.command).method==='native.metadata.import'))).replay,'exact original import receipt replays');
  const first=await read('native.metadata.read',{nativeSourceRevision:fixture.source_revision,nativeHistoryKind:'review',limit:1});
  expect(first.next_cursor.length<128,'long composite review identity has bounded opaque page cursor');
  await denied('native.metadata.read',{nativeSourceRevision:fixture.source_revision,nativeHistoryKind:'definition',cursor:first.next_cursor,limit:1});
  const otherChain=ownerId('isolated_');
  await call('chain.create',{chainId:otherChain,expectedRevision:'0',title:'Isolated chain',description:'No shared source lookup'});
  await denied('native.metadata.read',{chainId:otherChain,nativeSourceRevision:fixture.source_revision,nativeHistoryKind:'review',cursor:first.next_cursor,limit:1});
  const otherHub=await otherAccount();
  const invisible=await http(otherHub,'GET','/api/v1/owner-local/chains');
  expect(invisible.status===200 && invisible.data.length===0,'another enrolled account cannot discover source-chain metadata');
  const readOp=await prepare('native.metadata.read',{nativeSourceRevision:fixture.source_revision,nativeHistoryKind:'lease',limit:1});
  const cross=await http(otherHub,'POST','/api/v1/owner-local/relay',{body:await ownerRelayFile(session,readOp)});
  expect(cross.status!==200,'another enrolled account cannot relay original source reads');
  const worker=await launchChild(),reviewer=await launchChild();
  try{
    const follow=ownerId('follow_');
    await mutate('workflow.define',{body:JSON.stringify({workflow_id:follow,version:'1',title:'Rich output consumer',spec:JSON.stringify({schema:'workflow.v1',stages:[{key:'follow',brief:{goal:'Follow validated output',acceptance:['Preserve']}}]})})});
    await mutate('fleet.edit',{taskId,instanceId:worker.instanceId,configurationRevision:'1'});
    await mutate('lifecycle.configure',{taskId,lifecycleConfig:{configuration_revision:'1',author_agent_id:worker.agentId,reviewer_agent_id:reviewer.agentId,reviewer_instance_id:reviewer.instanceId,directory_id:ownerId('dir_'),merge_policy:'none',repository:'',worktree:'',source_branch:'',target_branch:'',base_head:''}});
    const brief=JSON.parse(fixture.operational_brief);
    brief.assignee=worker.agentId;brief.reviewers=[reviewer.agentId];brief.on_output.workflow=follow;
    await mutate('requirements.edit',{taskId,requirementsRevision:'1',body:JSON.stringify(brief)});
    await mutate('task.priority',{taskId,priority:'p0'});
    await mutate('task.comment',{taskId,body:'aggregate_live_needle original provenance'});
    let revision=(await read('task.read',{taskId})).revision;
    const input={protocol_version:'1',chain_id:chainId,task_id:taskId,lease_id:ownerId('lease_'),configuration_revision:'1',expected_revision:revision,operation_id:ownerId('op_'),method:'lease.claim',request_expires_ms:String(Date.now()+300000),capability:''};
    const claim=worker.call(input);expect(claim.status===0,'actual child claims rich ordinary policy');
    const cap=JSON.parse(claim.data.body).capability;
    const childCall=(child:any,method:string,payload:any,capability=cap)=>child.call({...input,operation_id:ownerId('op_'),method,expected_revision:revision,capability,payload:JSON.stringify(payload)});
    const present=childCall(worker,'requirements.present',{requirements_revision:'1'});
    expect(present.status===0,'actual child presents rich pinned requirements');
    const pins=JSON.parse(present.data.body).resolved_inputs;
    expect(pins.includes('art_original') && pins.includes('import_pending'),'actual context resolves original facet with explicit unresolved C3 body provenance');
    expect(childCall(worker,'requirements.ack',{requirements_revision:'1'}).status===0,'actual child acknowledges immutable rich requirements');
    expect(childCall(worker,'lease.submit',{requirements_revision:'1',head:'',summary:'Missing required output',output:'{}'}).status!==0,'rich output contract rejects invalid submission without retiring lease');
    const output=JSON.stringify({summary:'aggregate_output_needle',artifact_id:'art_original',message_id:'msg_original'});
    expect(childCall(worker,'lease.submit',{requirements_revision:'1',head:'',summary:'Rich checks passed',output}).status===0,'actual structured output submission succeeds');
    revision=(await read('task.read',{taskId})).revision;
    const verdict={requirements_revision:'1',attempt:'1',head:'',verdict:'approve',summary:'Independent rich review'};
    const opened=childCall(reviewer,'review.open',verdict,'');expect(opened.status===0,'independent actual reviewer opens bound attempt');
    expect(childCall(reviewer,'review.post',verdict,JSON.parse(opened.data.body).capability).status===0,'independent actual reviewer approves');
    expect((await read('runtime.read',{taskId})).state[0][0]==='in_review','original submitted human approval gate remains mandatory');
    await mutate('review.post',{taskId,requirementsRevision:'1',attempt:'1',head:'',verdict:'approve',body:'Explicit human rich gate'});
    expect((await read('runtime.read',{taskId})).state[0][0]==='done','explicit signed human verdict satisfies rich gate');
    for(const query of ['aggregate_live_needle','aggregate_output_needle']){
      const results=await read('chain.search',{query});
      expect(results.hits.length>0,'canonical rich live prose/output remains searchable: '+query);
    }
    const context=(await read('chain.read')).context;
    await compare();
    await stopOwner();await restartOwner();
    expect(isDeepStrictEqual((await read('chain.read')).context,context),'restart preserves exact canonical context checkpoint and source provenance');
    await compare();
    expect((await invoke(originalHistory)).replay && (await invoke(accepted[accepted.length-1])).replay,'history and all-field metadata receipts retain exact replay after live mutations/restart');
  }finally{await worker.stop();await reviewer.stop();}
}
