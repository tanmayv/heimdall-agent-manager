import { prepareOwnerOperation, ownerId, ownerRelayFile, openOwnerReply } from '../../src/ui/api/ownerLocalClient.ts';

// Real signatures, CLI relay and observed children; only disposable services restart.
export async function ownerLocalWorkGraphFlow({session,bridgeId,cli,expect,stopOwner,restartOwner,launchChild}:any) {
  const chainId=ownerId('chain_'),first=ownerId('task_'),second=ownerId('task_');
  const prepare=(method:string,input:any={})=>prepareOwnerOperation(session,bridgeId,method,{chainId,expectedRevision:'0',...input});
  const invoke=async(op:any)=>openOwnerReply(session,op,await cli(await ownerRelayFile(session,op)));
  const call=async(method:string,input:any={})=>invoke(await prepare(method,input));
  const read=async(method:string,input:any={})=>JSON.parse((await call(method,input)).body);
  const mutate=async(method:string,input:any={})=>{
    const revision=(await read(input.taskId?'task.read':'chain.read',input.taskId?{taskId:input.taskId}:{})).revision;
    return call(method,{expectedRevision:revision,...input});
  };
  const denied=async(method:string,input:any)=>{let rejected=false;try{await mutate(method,input);}catch{rejected=true;}expect(rejected,method+' rejects inadmissible mutation');};
  const work=async()=>{
    let cursor='',header:any,items:any[]=[];
    do {const page=await read('work.read',{cursor,limit:3});header=page;items.push(...page.items);cursor=page.next_cursor;}while(cursor);
    return {...header,items};
  };
  await call('chain.create',{title:'Draft mixed graph',description:'C1e disposable signed relay'});
  await mutate('chain.draft');
  const proposal=await prepare('chain.propose',{expectedRevision:(await read('chain.read')).revision,body:JSON.stringify({kind:'task',rationale:'Ordered exact generation delivery',tasks:[
    {id:first,title:'Prerequisite',brief:{goal:'Produce first output',acceptance:['Independent approval']}},
    {id:second,title:'Consumer',brief:{goal:'Consume immutable output',acceptance:['Independent approval']},depends_on:[first]}
  ]})});
  await invoke(proposal);
  let graph=await work();
  expect(graph.publish_state==='draft' && graph.pending_proposal_id===JSON.parse(proposal.command).operation_id,'draft proposal retains stable signed operation identity');
  expect(!(await read('chain.read')).items.length,'pending proposal has no materialized tasks');
  await stopOwner();await restartOwner();
  expect((await invoke(proposal)).replay,'pending proposal exact retry survives Bridge restart');
  const decision=await prepare('chain.decide',{expectedRevision:(await read('chain.read')).revision,body:JSON.stringify({proposal_id:JSON.parse(proposal.command).operation_id,decision:'approve',note:'Publish atomically'})});
  await invoke(decision);
  graph=await work();
  expect(graph.publish_state==='published' && !graph.pending_proposal_id,'approval atomically publishes and clears pending');
  expect((await read('chain.read')).items.length===2,'approval materializes exactly two tasks');
  expect(graph.items.filter((row:any)=>row.kind==='dependency').length===1,'proposal dependency materializes once');
  const originalEdge=graph.items.find((row:any)=>row.kind==='dependency').record.dependency_id;
  await mutate('work.dependency.remove',{body:JSON.stringify({dependency_id:originalEdge,reason:'Verify supported legacy input capture'})});
  await mutate('dependency.edit',{taskId:second,body:JSON.stringify({prerequisite:first,enabled:'1'})});

  await denied('chain.decide',{body:JSON.stringify({proposal_id:JSON.parse(proposal.command).operation_id,decision:'approve',note:'Already decided'})});
  const children:any[]=[];
  try {
    const finish=async(taskId:string,blocked=false)=>{
      const worker=await launchChild(),reviewer=await launchChild();children.push(worker,reviewer);
      await mutate('fleet.edit',{taskId,instanceId:worker.instanceId,configurationRevision:'1'});
      await mutate('lifecycle.configure',{taskId,lifecycleConfig:{configuration_revision:'1',author_agent_id:worker.agentId,reviewer_agent_id:reviewer.agentId,reviewer_instance_id:reviewer.instanceId,directory_id:ownerId('dir_'),merge_policy:'none',repository:'',worktree:'',source_branch:'',target_branch:'',base_head:''}});
      const revision=(await read('task.read',{taskId})).revision;
      const input={protocol_version:'1',chain_id:chainId,task_id:taskId,lease_id:ownerId('lease_'),configuration_revision:'1',expected_revision:revision,operation_id:ownerId('op_'),method:'lease.claim',request_expires_ms:String(Date.now()+300000),capability:''};
      if(blocked){expect(worker.call(input).status!==0,'consumer cannot claim before prerequisite succeeds');return;}
      const claimed=worker.call(input);expect(claimed.status===0,'real worker claims published ready task');
      const cap=JSON.parse(claimed.data.body).capability;
      if(taskId===first){
        const draft=ownerId('draft_');
        await call('task.draft',{taskId:draft,expectedRevision:(await read('chain.read')).revision,title:'Unpublished switch target',body:'Publication fence'});
        await mutate('fleet.edit',{taskId:draft,instanceId:worker.instanceId,configurationRevision:'1'});
        await mutate('lifecycle.configure',{taskId:draft,lifecycleConfig:{configuration_revision:'1',author_agent_id:worker.agentId,reviewer_agent_id:reviewer.agentId,reviewer_instance_id:reviewer.instanceId,directory_id:ownerId('dir_'),merge_policy:'none',repository:'',worktree:'',source_branch:'',target_branch:'',base_head:''}});
        await mutate('requirements.edit',{taskId:draft,requirementsRevision:'1',body:JSON.stringify({goal:'Draft target',acceptance:['Publish first']})});
        const destinationRevision=(await read('task.read',{taskId:draft})).revision;
        const switched=worker.call({...input,operation_id:ownerId('op_'),method:'lease.switch',capability:cap,payload:JSON.stringify({requirements_revision:'1',summary:'Attempt draft switch',next_steps:'Remain on source',destination_chain_id:chainId,destination_task_id:draft,destination_revision:destinationRevision,destination_configuration_revision:'1',destination_requirements_revision:'1',destination_lease_id:ownerId('lease_')})});
        expect(switched.status!==0 && JSON.stringify(switched.reply).includes('operation_conflict'),'real switch rejects assigned unpublished draft destination');
        const source=await read('runtime.read',{taskId:first});
        expect(source.leases.length===1 && source.leases[0][0]===input.lease_id,'rejected draft switch retains live source lease');
        const target=await read('runtime.read',{taskId:draft});
        expect(target.leases.length===0 && target.attempts.attempt_no==='0','rejected draft switch creates no destination attempt');
        await mutate('task.cancel',{taskId:draft,body:'Exclude unstarted switch probe'});
        await mutate('work.scope',{body:JSON.stringify({item:{kind:'task',id:draft},action:'exclude',reason:'Completed publication rejection probe'})});
      }

      const childCall=(child:any,method:string,payload:any,capability=cap,expected_revision=revision)=>child.call({...input,operation_id:ownerId('op_'),method,expected_revision,capability,payload:JSON.stringify(payload)});
      for(const method of ['requirements.present','requirements.ack'])expect(childCall(worker,method,{requirements_revision:'1'}).status===0,'real '+method);
      expect(childCall(worker,'lease.submit',{requirements_revision:'1',head:'',summary:'Scoped verification passed'}).status===0,'real submission');
      const next=(await read('task.read',{taskId})).revision;
      const verdict={requirements_revision:'1',attempt:'1',head:'',verdict:'approve',summary:'Independent review'};
      const opened=childCall(reviewer,'review.open',verdict,'',next);expect(opened.status===0,'real independent review opens');
      expect(childCall(reviewer,'review.post',verdict,JSON.parse(opened.data.body).capability,next).status===0,'real review approves');
    };
    // Bind a blocked consumer first, then explicitly replace that configuration.
    await finish(second,true);
    await finish(first);
    // The disabled/idle first consumer configuration is safely rebound with revision2.
    const worker=await launchChild(),reviewer=await launchChild();children.push(worker,reviewer);
    await mutate('fleet.edit',{taskId:second,instanceId:worker.instanceId,configurationRevision:'2'});
    await mutate('lifecycle.configure',{taskId:second,lifecycleConfig:{configuration_revision:'2',author_agent_id:worker.agentId,reviewer_agent_id:reviewer.agentId,reviewer_instance_id:reviewer.instanceId,directory_id:ownerId('dir_'),merge_policy:'none',repository:'',worktree:'',source_branch:'',target_branch:'',base_head:''}});
    let revision=(await read('task.read',{taskId:second})).revision;
    const input={protocol_version:'1',chain_id:chainId,task_id:second,lease_id:ownerId('lease_'),configuration_revision:'2',expected_revision:revision,operation_id:ownerId('op_'),method:'lease.claim',request_expires_ms:String(Date.now()+300000),capability:''};
    const claimed=worker.call(input);expect(claimed.status===0,'consumer claims after successful prerequisite');
    const cap=JSON.parse(claimed.data.body).capability;
    graph=await work();
    const receipts=graph.items.filter((row:any)=>row.kind==='receipt').map((row:any)=>row.record);
    expect(receipts.length===1 && receipts[0].dependent.id===second && receipts[0].prerequisite.id===first && receipts[0].dependent_generation===1 && receipts[0].prerequisite_generation===1,'real consumer freezes exact generation receipt');
    await denied('task.reopen',{taskId:first,body:'Reject reopening legacy-consumed output'});

    const childCall=(child:any,method:string,payload:any,capability=cap)=>child.call({...input,operation_id:ownerId('op_'),method,expected_revision:revision,capability,payload:JSON.stringify(payload)});
    for(const method of ['requirements.present','requirements.ack'])expect(childCall(worker,method,{requirements_revision:'1'}).status===0,'consumer '+method);
    expect(childCall(worker,'lease.submit',{requirements_revision:'1',head:'',summary:'Consumer checks passed'}).status===0,'consumer submits');
    revision=(await read('task.read',{taskId:second})).revision;
    const verdict={requirements_revision:'1',attempt:'1',head:'',verdict:'approve',summary:'Independent consumer review'};
    const opened=childCall(reviewer,'review.open',verdict,'');expect(opened.status===0,'consumer review opens');
    expect(childCall(reviewer,'review.post',verdict,JSON.parse(opened.data.body).capability).status===0,'consumer approved');
    const before=await work();
    await denied('chain.complete',{body:JSON.stringify({expected_work_revision:'0',summary:'Stale'})});
    const complete=await prepare('chain.complete',{expectedRevision:(await read('chain.read')).revision,body:JSON.stringify({expected_work_revision:before.work_revision,summary:'Both included tasks independently approved'})});
    await invoke(complete);
    expect((await work()).status==='completed','exact work revision completes chain');
    await stopOwner();await restartOwner();
    expect((await invoke(decision)).replay && (await invoke(complete)).replay,'decision and completion replay remain byte-stable after restart');
    graph=await work();
    expect(graph.status==='completed' && graph.items.some((row:any)=>row.kind==='completion') && graph.items.filter((row:any)=>row.kind==='receipt').length===1,'completion and immutable receipt survive restart without duplicate expansion');
    expect(Number(graph.work_revision)>Number(before.work_revision),'completion advances local work revision');
  } finally {for(const child of children)await child.stop();}
}
