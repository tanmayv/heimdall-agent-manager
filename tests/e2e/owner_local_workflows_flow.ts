// Real disposable owner Bridge, signed device relay, CLI and actual PTY children.
import { prepareOwnerOperation, ownerId, ownerRelayFile, openOwnerReply, sendOwnerOperation } from '../../src/ui/api/ownerLocalClient.ts';
import { ownerPayloadDigest } from '../../src/ui/api/ownerLocal.ts';

export async function ownerLocalWorkflowsFlow({session,bridgeId,hub,http,cli,launchChild,expect,approver,stopOwner,restartOwner,inspectHub}:any) {
  const cid=ownerId('chain_');
  const send=async(body:any)=>{const r=await http(hub,'POST','/api/v1/owner-local/relay',{body});if(r.status!==200)throw new Error(r.raw);return r.data;};
  const human=async(method:string,input:any={},useCli=false)=>{
    const op=await prepareOwnerOperation(session,bridgeId,method,{chainId:cid,taskId:'',expectedRevision:'0',...input});
    return useCli?openOwnerReply(session,op,await cli(await ownerRelayFile(session,op))):sendOwnerOperation(session,op,send);
  };
  const revision=async(taskId='')=>String(JSON.parse((await human(taskId?'runtime.read':'chain.read',{taskId})).body).revision);
  const mutate=async(method:string,body:any,useCli=false)=>human(method,{expectedRevision:await revision(),body:JSON.stringify(body)},useCli);
  await human('chain.create',{title:'workflow-private-chain',description:'workflow-private-description'});
  const stage=(key:string,deps:string[])=>({key,title:'workflow-private-'+key,body:'workflowprivateneedle',brief:JSON.stringify({goal:'workflow-private-'+key,acceptance:['Exact sequential completion']}),depends_on:JSON.stringify(deps)});
  const definition={workflow_id:'static_demo',version:'1',title:'workflowprivateneedle',stages:JSON.stringify([stage('first',[]),stage('second',['first'])])};
  await mutate('workflow.define',definition,true);
  let rejected=false;
  try {await mutate('workflow.define',{...definition,workflow_id:'dynamic_bad',inputs:{items:[]}});} catch {rejected=true;}
  expect(rejected,'real signed unsupported dynamic definition rejects without materialization');
  await mutate('workflow.run',{run_id:'demo_run',workflow_id:'static_demo',version:'1'},true);
  const workflow=async()=>JSON.parse((await human('workflow.read')).body);
  let observed=await workflow();
  const oldTask=observed.tasks.find((r:any)=>r[1]==='1' && r[2]==='first')[3];
  let worker=await launchChild(),reviewer=await launchChild(),auditor=await launchChild();
  const bind=async(taskId:string)=>{
    await human('fleet.edit',{taskId,expectedRevision:await revision(taskId),instanceId:worker.instanceId,configurationRevision:'1'});
    await human('lifecycle.configure',{taskId,expectedRevision:await revision(taskId),lifecycleConfig:{configuration_revision:'1',author_agent_id:worker.agentId,reviewer_agent_id:reviewer.agentId,reviewer_instance_id:reviewer.instanceId,directory_id:ownerId('dir_'),merge_policy:'none',repository:'',worktree:'',source_branch:'',target_branch:'',base_head:''}});
  };
  const input=(taskId:string,rev:string)=>({protocol_version:'1',chain_id:cid,task_id:taskId,lease_id:ownerId('lease_'),configuration_revision:'1',expected_revision:rev,operation_id:ownerId('op_'),method:'lease.claim',request_expires_ms:String(Date.now()+300000),capability:''});
  try {
    await bind(oldTask);
    const original=input(oldTask,await revision(oldTask));
    const claimed=worker.call(original);expect(claimed.status===0,'real generation1 worker claims');
    const oldCap=JSON.parse(claimed.data.body).capability;
    for(const method of ['requirements.present','requirements.ack']){
      expect(worker.call({...original,method,operation_id:ownerId('op_'),capability:oldCap,payload:JSON.stringify({requirements_revision:'1'})}).status===0,'old generation '+method);
    }
    const oldSubmit={...original,method:'lease.submit',operation_id:ownerId('op_'),capability:oldCap,payload:JSON.stringify({requirements_revision:'1',head:'',summary:'workflow-old-submitted-review'})};
    expect(worker.call(oldSubmit).status===0,'real generation1 submits before retry');
    expect(JSON.parse((await human('source.read')).body).items.some((r:any)=>r[0]==='local.review' && r[1]===oldTask && r[4]==='0'),'submitted old generation has a canonical unresolved review source');
    await mutate('workflow.retry',{run_id:'demo_run',execution:'1'},true);
    const replay=worker.call(original);expect(replay.status===0 && replay.data.replay,'old exact claim reply remains historical after retry');
    const submitReplay=worker.call(oldSubmit);expect(submitReplay.status===0 && submitReplay.data.replay,'old exact submit reply remains historical after retry');
    expect(worker.call({...oldSubmit,operation_id:ownerId('op_')}).status!==0,'superseded review cannot accept a fresh old submission');
    expect(worker.call({...original,operation_id:ownerId('op_'),lease_id:ownerId('lease_')}).status!==0,'old generation cannot mint fresh work');
    const fact=(episode:string,version:string,resolved:string)=>({origin_kind:'demo',origin_id:'same_origin',episode_id:episode,source_version:version,resolved,deadline_ms:'0',body:'sourceprivateneedle'});
    const action=(episode:string,version:string)=>({origin_kind:'demo',origin_id:'same_origin',episode_id:episode,source_version:version,consumer_fence_hash:'0'.repeat(64),result:'Exact source episode'});
    await mutate('source.observe',fact('old','7','0'));
    await mutate('source.escalate',action('old','7'),true);
    await mutate('source.observe',fact('old','8','1'));
    await mutate('source.observe',fact('new','9','0'));
    await worker.stop();await reviewer.stop();await auditor.stop();
    await stopOwner();await restartOwner();
    const cold=JSON.parse((await human('source.read')).body);
    expect(!cold.items.some((r:any)=>r[0]==='local.review' && r[1]===oldTask),'retry atomically resolves old canonical review source across real owner restart');
    expect(cold.items.some((r:any)=>r[2]==='old' && r[4]==='1' && r[9] && r[10]==='0'),'real cold discovery retains resolved episode with pending card');
    await mutate('source.resolve',action('old','8'),true);
    const retained=JSON.parse((await human('source.read')).body);
    expect(retained.items.some((r:any)=>r[2]==='new') && !retained.items.some((r:any)=>r[2]==='old'),'real old episode closes independently of newer recurrence');
    worker=await launchChild();reviewer=await launchChild();auditor=await launchChild();
    observed=await workflow();
    const current=observed.tasks.filter((r:any)=>r[1]==='2').sort((a:any,b:any)=>a[2].localeCompare(b[2]));
    for (const row of current) {
      await bind(row[3]);
      await human('review.roles',{taskId:row[3],expectedRevision:await revision(row[3]),body:JSON.stringify({configuration_revision:'1',requires_user_approval:'0',pairs:JSON.stringify([{role:'safety',agent_id:auditor.agentId,instance_id:auditor.instanceId}])})});
    }
    expect(worker.call(input(current[1][3],await revision(current[1][3]))).status!==0,'real dependency blocks second stage claim');
    for (const row of current) {
      const tid=row[3],rev=await revision(tid),base=input(tid,rev);
      const claimed=worker.call(base);expect(claimed.status===0,'real current stage claim '+row[2]);
      const cap=JSON.parse(claimed.data.body).capability;
      const call=(child:any,method:string,payload:any,capability:string,expected_revision=rev)=>child.call({...base,method,operation_id:ownerId('op_'),expected_revision,capability,payload:JSON.stringify(payload)});
      expect(call(worker,'requirements.present',{requirements_revision:'1'},cap).status===0,'real workflow brief presentation');
      expect(call(worker,'requirements.ack',{requirements_revision:'1'},cap).status===0,'real exact workflow ACK');
      const submitted=call(worker,'lease.submit',{requirements_revision:'1',head:'',summary:'workflowoutputneedle-'+row[2]},cap);expect(submitted.status===0,'real sequential stage submission');
      const rrev=await revision(tid),verdict={requirements_revision:'1',attempt:'1',head:'',verdict:'approve',summary:'Independent workflow review'};
      const primary=call(reviewer,'review.open',verdict,'',rrev);expect(primary.status===0,'real primary review opens');
      const role={...verdict,role:'safety'};
      const safety=call(auditor,'review.role.open',role,'',rrev);expect(safety.status===0,'real required role opens separately');
      const sourceBefore=JSON.parse((await human('source.read')).body).items.find((r:any)=>r[0]==='local.review' && r[1]===tid && r[2]==='1');
      expect(!!sourceBefore,'real canonical review source is available before result consumption');
      expect(call(reviewer,'review.post',verdict,JSON.parse(primary.data.body).capability,rrev).status===0,'real primary approval');
      const waiting=JSON.parse((await human('runtime.read',{taskId:tid})).body);
      expect(waiting.state[0][0]==='in_review','primary alone cannot bypass required role');
      expect(call(auditor,'review.role.post',role,JSON.parse(safety.data.body).capability,await revision(tid)).status===0,'real independent role approval');
      const done=JSON.parse((await human('runtime.read',{taskId:tid})).body);
      expect(done.state[0][0]==='done','stage gate completes before successor eligibility');
      const consumed={origin_kind:'local.review',origin_id:tid,episode_id:'1',source_version:sourceBefore[3],consumer_fence_hash:await ownerPayloadDigest(JSON.parse(primary.data.body).capability),result:'Exact primary review outcome'};
      await mutate('source.ack',consumed,true);
      await mutate('source.retire',consumed,true);
      expect(true,'real signed CLI ACK/retirement accepts exact historical consumption after completed producer advancement');
    }
    expect((await workflow()).runs[0][5]==='done','real workflow completion folds after all stages');
    await worker.stop();await reviewer.stop();await auditor.stop();
    await stopOwner();await restartOwner();
    expect((await workflow()).runs[0][5]==='done','real workflow completion survives owner restart');
    for (const query of ['workflowprivateneedle','workflowoutputneedle','sourceprivateneedle']) {
      expect(JSON.parse((await human('chain.search',{query})).body).hits.length>0,'real restart rebuild preserves scoped '+query);
    }
    for(const end=Date.now()+15000;;await new Promise(r=>setTimeout(r,200))){
      const rows=(await http(hub,'GET','/api/v1/owner-local/chains')).data.filter((r:any)=>r.chain_id===cid);
      if(rows.length===5)break;
      if(Date.now()>end)throw new Error('workflow protected metadata publication incomplete');
    }
    await inspectHub(cid,5);
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
    const wait=async(check:()=>boolean)=>{for(const end=Date.now()+15000;!check();){const error=dom.window.document.querySelector('[role=alert]');if(error)throw new Error(error.textContent??'panel failed');if(Date.now()>end)throw new Error('workflow panel timed out');await React.act(async()=>{await new Promise(r=>setTimeout(r,50));});}};
    try {
      await React.act(async()=>root.render(React.createElement(Panel,{onClose:()=>{},initialBridgeId:bridgeId,initialChainId:cid})));
      for(const [method,needle] of [['workflow-read','demo_run'],['source-read','same_origin']]){
        const button=()=>dom.window.document.querySelector<HTMLButtonElement>('[data-debug-id=owner-local-'+method+']')!;
        await wait(()=>!!button() && !button().disabled);
        await React.act(async()=>button().click());
        await wait(()=>!!dom.window.document.querySelector('pre')?.textContent?.includes(needle));
        // The detail arrives before perform() finishes its listing refresh.
        // Drain that work before unmounting and restoring global window.
        await wait(()=>!button().disabled);
        expect(dom.window.document.querySelector('pre')?.textContent?.includes(needle),'rendered production panel reads '+method+' after restart');
      }
    }finally{await React.act(async()=>root.unmount());globalThis.fetch=originalFetch;clearKeyringSession();dom.window.close();keys.forEach((k,i)=>{if(descriptors[i])Object.defineProperty(globalThis,k,descriptors[i]!);else delete(globalThis as any)[k];});}
  } finally {await worker.stop();await reviewer.stop();await auditor.stop();}
}
