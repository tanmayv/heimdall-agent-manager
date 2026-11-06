// Disposable real owner Bridge/CLI and actual synthetic PTY children.
import fs from 'node:fs/promises';
import { prepareOwnerOperation, ownerId, ownerRelayFile, openOwnerReply, sendOwnerOperation } from '../../src/ui/api/ownerLocalClient.ts';

export async function ownerLocalLanguageFlow({session,bridgeId,hub,http,cli,launchChild,expect,stopOwner,restartOwner,approver}:any) {
  const chainId=ownerId('chain_');
  const relay=async(body:any)=>{const r=await http(hub,'POST','/api/v1/owner-local/relay',{body});if(r.status!==200)throw new Error(r.raw);return r.data;};
  const human=async(method:string,input:any={},useCli=false)=>{
    const op=await prepareOwnerOperation(session,bridgeId,method,{chainId,taskId:'',expectedRevision:'0',...input});
    return useCli?openOwnerReply(session,op,await cli(await ownerRelayFile(session,op))):sendOwnerOperation(session,op,relay);
  };
  const detail=async(method:string,input:any={})=>JSON.parse((await human(method,input)).body);
  const revision=async(taskId='')=>String((await detail(taskId?'runtime.read':'chain.read',{taskId})).revision);
  const mutate=async(method:string,body:any,useCli=true)=>human(method,{expectedRevision:await revision(),body:JSON.stringify(body)},useCli);
  await human('chain.create',{title:'language-private-chain',description:'workflow language parity'});
  for(const name of ['explore_plan_build','fix_flaky_tests','security_audit']) {
    const spec=await fs.readFile(new URL('../../src/prompts/workflows/'+name+'.json',import.meta.url),'utf8');
    await mutate('workflow.define',{workflow_id:name,version:'1',title:name,spec});
  }
  await mutate('workflow.define',{workflow_id:'follow',version:'1',title:'Follow',spec:JSON.stringify({schema:'workflow.v1',name:'follow',stages:[{key:'follow',title:'Follow {{inputs.summary}}',brief:{goal:'{{inputs.summary}}',acceptance:['Follow-up completed']}}]})});
  const spec={schema:'workflow.v1',name:'dynamic',stages:[
    {key:'source',title:'Source {{inputs.goal}}',brief:{goal:'Produce scoped dynamic tasks',output:{schema:'task_list.v1'},on_output:{workflow:'follow',inputs:{summary:'{{output.summary}}'}}}},
    {key:'gate',kind:'gate',depends_on:['source'],approver:'user_or_coordinator',prompt:'Approve {{stage.source.output.summary}}'},
    {key:'write',depends_on:['gate'],for_each:'source.outputs[0].tasks',max_parallel:1,title:'Write {{item.title}} {{stage.index}}/{{stage.count}}',brief:{goal:'{{item.goal}}',acceptance:['Done']}},
    {key:'result',depends_on:['write'],brief:{goal:'Result {{stage.source.output.summary}}',acceptance:['Combined result checked']}}
  ]};
  await mutate('workflow.define',{workflow_id:'dynamic',version:'1',title:'dynamic-private-definition',spec:JSON.stringify(spec)});
  await mutate('workflow.run',{run_id:'dynamic',workflow_id:'dynamic',version:'1',inputs:JSON.stringify({goal:'real demo'})});
  const worker=await launchChild(),reviewer=await launchChild(),coordinator=await launchChild();
  const inventory=()=>detail('workflow.read',{limit:100});
  const tasks=async(run:string,execution:string,stage:string)=>(await inventory()).tasks.filter((r:any)=>r[0]===run && r[1]===execution && r[2].startsWith(stage+':'));
  const finish=async(taskId:string,output?:any)=>{
    await human('fleet.edit',{taskId,expectedRevision:await revision(taskId),instanceId:worker.instanceId,configurationRevision:'1'});
    await human('lifecycle.configure',{taskId,expectedRevision:await revision(taskId),lifecycleConfig:{configuration_revision:'1',author_agent_id:worker.agentId,reviewer_agent_id:reviewer.agentId,reviewer_instance_id:reviewer.instanceId,directory_id:ownerId('dir_'),merge_policy:'none',repository:'',worktree:'',source_branch:'',target_branch:'',base_head:''}});
    const base={protocol_version:'1',chain_id:chainId,task_id:taskId,lease_id:ownerId('lease_'),configuration_revision:'1',expected_revision:await revision(taskId),operation_id:ownerId('op_'),method:'lease.claim',request_expires_ms:String(Date.now()+300000),capability:''};
    const claimed=worker.call(base);expect(claimed.status===0,'dynamic real child claim '+taskId);
    const cap=JSON.parse(claimed.data.body).capability;
    const call=async(child:any,method:string,payload:any,capability:string)=>child.call({...base,method,operation_id:ownerId('op_'),expected_revision:await revision(taskId),capability,payload:JSON.stringify(payload)});
    for(const method of ['requirements.present','requirements.ack']) expect((await call(worker,method,{requirements_revision:'1'},cap)).status===0,'dynamic '+method);
    const payload:any={requirements_revision:'1',head:'',summary:'dynamic-language-output'};
    if(output!==undefined)payload.output=JSON.stringify(output);
    const submitted=await call(worker,'lease.submit',payload,cap);
    expect(submitted.status===0,'dynamic structured submit');
    const verdict={requirements_revision:'1',attempt:'1',head:'',verdict:'approve',summary:'Independent dynamic review'};
    const opened=await call(reviewer,'review.open',verdict,'');expect(opened.status===0,'dynamic independent review opens');
    expect((await call(reviewer,'review.post',verdict,JSON.parse(opened.data.body).capability)).status===0,'dynamic independent review approves');
    if(output!==undefined) {
      const retained=await detail('submission.read',{taskId,attempt:'1',offset:'0'});
      expect(JSON.stringify(JSON.parse(retained.output))===JSON.stringify(output),'structured output retained through real relay');
    }
  };
  try {
    const binding=JSON.parse((await mutate('workflow.coordinator',{configuration_revision:'1',agent_id:coordinator.agentId,instance_id:coordinator.instanceId})).body);
    const source=(await tasks('dynamic','1','source'))[0][3];
    await finish(source,{summary:'dynamic-planned',tasks:[{key:'a',title:'Alpha',goal:'Build alpha'},{key:'b',title:'Beta',goal:'Build beta'}]});
    expect((await tasks('dynamic','1','write')).length===0,'real dynamic fan-out waits for gate');
    const gate=(await tasks('dynamic','1','gate'))[0][3];
    const vote={protocol_version:'1',chain_id:chainId,task_id:gate,lease_id:ownerId('gate_'),configuration_revision:'1',expected_revision:await revision(gate),operation_id:ownerId('op_'),method:'workflow.gate.post',request_expires_ms:String(Date.now()+300000),capability:binding.capability,payload:JSON.stringify({run_id:'dynamic',execution:'1',stage_key:'gate',verdict:'approve',summary:'Configured coordinator approves'})};
    const voted=coordinator.call(vote);expect(voted.status===0,'actual exact coordinator child gate');
    expect(coordinator.call(vote).data.replay,'actual coordinator lost-reply replay');
    const writes=await tasks('dynamic','1','write');
    expect(writes.length===2,'real dynamic output creates two deterministic items');
    for(const row of writes)await finish(row[3]);
    const result=(await tasks('dynamic','1','result'))[0][3];await finish(result);
    const all=await inventory();
    expect(all.runs.find((r:any)=>r[0]==='dynamic')[5]==='done','real dynamic source/fanout/result completes');
    const follow=all.tasks.find((r:any)=>r[0]!=='dynamic' && r[2]==='follow:0');
    expect(!!follow,'on_output sibling starts after source run success');
    const followDetail=await detail('task.read',{taskId:follow[3]});expect(followDetail.title==='Follow dynamic-planned','real on_output binding preserves output until submission');
    let blocked=false;try{await mutate('workflow.retry',{run_id:'dynamic',execution:'1'});}catch{blocked=true;}expect(blocked,'real consumed sibling output fences parent retry');
    await finish(follow[3]);
    await mutate('workflow.run',{run_id:'builtin',workflow_id:'fix_flaky_tests',version:'1',inputs:JSON.stringify({suite:'tests'})});
    await finish((await tasks('builtin','1','reproduce'))[0][3],{tasks:[{key:'canonical',title:'Canonical template item',goal:'Fix canonical flake'}]});
    await finish((await tasks('builtin','1','fix'))[0][3]);
    await finish((await tasks('builtin','1','confirm'))[0][3]);
    expect((await inventory()).runs.find((r:any)=>r[0]==='builtin')[5]==='done','unmodified imported fix_flaky_tests template executes locally end to end');
    const emptySpec={schema:'workflow.v1',stages:[{key:'source',brief:{goal:'Summary-only source',acceptance:['Done'],on_output:{start_workflow:'follow',inputs:{summary:'summary-only',rate:1.5}}}}]};
    await mutate('workflow.define',{workflow_id:'empty_output',version:'1',title:'Empty output trigger',spec:JSON.stringify(emptySpec)});
    await mutate('workflow.run',{run_id:'empty_output',workflow_id:'empty_output',version:'1',inputs:'{}'});
    await finish((await tasks('empty_output','1','source'))[0][3]);
    let summaryFollow='';
    for(const row of (await inventory()).tasks.filter((r:any)=>r[2]==='follow:0')) {
      if((await detail('task.read',{taskId:row[3]})).title==='Follow summary-only')summaryFollow=row[3];
    }
    expect(!!summaryFollow,'summary-only submission launches on_output with empty output fallback');
    await finish(summaryFollow);
    const retrySpec={schema:'workflow.v1',stages:[{key:'gate',kind:'gate',approver:'user'},{key:'result',depends_on:['gate'],brief:{goal:'Retry result',acceptance:['Done']}}]};
    await mutate('workflow.define',{workflow_id:'retry',version:'1',title:'Retry',spec:JSON.stringify(retrySpec)});
    await mutate('workflow.run',{run_id:'retry',workflow_id:'retry',version:'1',inputs:'{}'});
    const userGate=(await tasks('retry','1','gate'))[0][3];
    const denied=coordinator.call({...vote,task_id:userGate,expected_revision:'1',operation_id:ownerId('op_'),payload:JSON.stringify({run_id:'retry',execution:'1',stage_key:'gate',verdict:'approve',summary:'Must reject coordinator'})});
    expect(denied.status!==0,'real user-only gate denies configured coordinator');
    await mutate('workflow.gate',{run_id:'retry',execution:'1',stage_key:'gate',verdict:'request_changes',summary:'Retry explicitly'});
    await mutate('workflow.retry',{run_id:'retry',execution:'1'});
    await mutate('workflow.gate',{run_id:'retry',execution:'2',stage_key:'gate',verdict:'approve',summary:'Human approves fresh generation'});
    await finish((await tasks('retry','2','result'))[0][3]);
    await worker.stop();await reviewer.stop();await coordinator.stop();
    await stopOwner();await restartOwner();
    expect((await inventory()).runs.find((r:any)=>r[0]==='retry')[5]==='done','real language execution and retry survive owner restart');
    expect((await detail('chain.search',{query:'dynamic-planned'})).hits.length>0,'structured output remains searchable after cold rebuild');

    const {JSDOM}=await import('jsdom');const React=await import('react');
    const {installKeyringFromWrap,clearKeyringSession}=await import('../../src/ui/utils/vaultKeyringSession.ts');
    const {sessionHeaders}=await import('./hubOidc.mjs');
    await installKeyringFromWrap(approver.identity,approver.wrap,await approver.chain());
    const dom=new JSDOM('<div id="root"></div>',{url:hub.base});
    const keys=['window','document','navigator','HTMLElement','IS_REACT_ACT_ENVIRONMENT'];const descriptors=keys.map(k=>Object.getOwnPropertyDescriptor(globalThis,k));
    for(const [key,value] of Object.entries({window:dom.window,document:dom.window.document,navigator:dom.window.navigator,HTMLElement:dom.window.HTMLElement,IS_REACT_ACT_ENVIRONMENT:true}))Object.defineProperty(globalThis,key,{value,configurable:true,writable:true});
    const originalFetch=globalThis.fetch;
    globalThis.fetch=(url:any,init:any={})=>originalFetch(new URL(String(url),hub.base),{...init,headers:{...Object.fromEntries(new Headers(sessionHeaders(hub.session,hub.base))),...Object.fromEntries(new Headers(init.headers))}});
    const {createRoot}=await import('react-dom/client');const {default:Panel}=await import('../../src/ui/components/taskchain/OwnerLocalPanel.tsx');const root=createRoot(dom.window.document.getElementById('root')!);
    const wait=async(check:()=>boolean)=>{for(const end=Date.now()+15000;!check();){const error=dom.window.document.querySelector('[role=alert]');if(error)throw new Error(error.textContent??'panel failed');if(Date.now()>end)throw new Error('dynamic panel timed out');await React.act(async()=>{await new Promise(r=>setTimeout(r,50));});}};
    try {
      await React.act(async()=>root.render(React.createElement(Panel,{onClose:()=>{},initialBridgeId:bridgeId,initialChainId:chainId})));
      const button=()=>dom.window.document.querySelector<HTMLButtonElement>('[data-debug-id=owner-local-workflow-read]')!;
      await wait(()=>!!button() && !button().disabled);
      await React.act(async()=>button().click());
      await wait(()=>!!dom.window.document.querySelector('pre')?.textContent?.includes('dynamic'));
      await wait(()=>!button().disabled);
      expect(!!dom.window.document.querySelector('pre')?.textContent?.includes('write:1'),'rendered production UI shows actual dynamic fan-out history after restart');
    } finally {await React.act(async()=>root.unmount());globalThis.fetch=originalFetch;clearKeyringSession();dom.window.close();keys.forEach((k,i)=>{if(descriptors[i])Object.defineProperty(globalThis,k,descriptors[i]!);else delete(globalThis as any)[k];});}

    expect(true,'real dynamic templates/fan-out/gates/coordinator/results/on_output/retry passed');
  } finally {await worker.stop();await reviewer.stop();await coordinator.stop();}
}
