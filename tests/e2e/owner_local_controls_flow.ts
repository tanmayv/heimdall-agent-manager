// Real signed controls and actual CLI children in the disposable enrollment demo.
import { prepareOwnerOperation, ownerId, ownerRelayFile, openOwnerReply, sendOwnerOperation } from '../../src/ui/api/ownerLocalClient.ts';

export async function ownerLocalControlsFlow({session,bridgeId,hub,http,cli,launchChild,expect,approver}:any) {
  const cid=ownerId('chain_'),source=ownerId('task_'),dest=ownerId('task_');
  const worker=await launchChild(),reviewer=await launchChild(),replacement=await launchChild();
  const send=async(body:any)=>{const r=await http(hub,'POST','/api/v1/owner-local/relay',{body});if(r.status!==200)throw new Error(r.raw);return r.data;};
  const human=async(method:string,input:any,useCli=false)=>{
    const op=await prepareOwnerOperation(session,bridgeId,method,{chainId:cid,taskId:source,...input});
    return useCli?openOwnerReply(session,op,await cli(await ownerRelayFile(session,op))):sendOwnerOperation(session,op,send);
  };
  try {
    await human('chain.create',{taskId:'',expectedRevision:'0',title:'controls-private-chain',description:'controls-private-description'});
    await human('task.create',{expectedRevision:'1',title:'controls-private-source',body:'source'});
    await human('task.create',{taskId:dest,expectedRevision:'2',title:'controls-private-destination',body:'destination'});
    const config=(child:any,revision='1')=>({configuration_revision:revision,author_agent_id:child.agentId,reviewer_agent_id:reviewer.agentId,reviewer_instance_id:reviewer.instanceId,directory_id:ownerId('dir_'),merge_policy:'none',repository:'',worktree:'',source_branch:'',target_branch:'',base_head:''});
    for(const tid of [source,dest]){
      await human('fleet.edit',{taskId:tid,expectedRevision:'1',instanceId:worker.instanceId,configurationRevision:'1'});
      await human('lifecycle.configure',{taskId:tid,expectedRevision:'2',lifecycleConfig:config(worker)});
      await human('requirements.edit',{taskId:tid,expectedRevision:'3',requirementsRevision:'1',body:JSON.stringify({goal:'controls-private-goal',acceptance:['Exact child transitions']})});
    }
    const input={protocol_version:'1',chain_id:cid,task_id:source,lease_id:ownerId('lease_'),configuration_revision:'1',expected_revision:'4',operation_id:ownerId('op_'),method:'lease.claim',request_expires_ms:String(Date.now()+300000),capability:''};
    const claimed=worker.call(input);expect(claimed.status===0,'controls real worker claims source');
    const cap=JSON.parse(claimed.data.body).capability;
    const destinationLease=ownerId('lease_');
    const payload={requirements_revision:'1',summary:'controls-private-switchneedle',next_steps:'Continue destination',destination_chain_id:cid,destination_task_id:dest,destination_revision:'4',destination_configuration_revision:'1',destination_requirements_revision:'1',destination_lease_id:destinationLease};
    const change={...input,method:'lease.switch',operation_id:ownerId('op_'),capability:cap,payload:JSON.stringify(payload)};
    expect(worker.call({...change,operation_id:ownerId('op_'),payload:JSON.stringify({...payload,destination_revision:'3'})}).status!==0,'real CLI rejects stale destination before releasing source');
    let state=JSON.parse((await human('runtime.read',{expectedRevision:'0'})).body);
    expect(state.leases.length===1 && state.leases[0][0]===input.lease_id,'failed switch preserves source lease');
    const switched=worker.call(change);expect(switched.status===0,'real CLI commits atomic same-owner switch');
    const retry=worker.call(change);expect(retry.status===0 && retry.data.replay && retry.data.body===switched.data.body,'real switch lost reply replays identical destination capability');
    let destinationCap=JSON.parse(switched.data.body).capability;
    state=JSON.parse((await human('runtime.read',{taskId:dest,expectedRevision:'0'})).body);
    expect(state.leases.length===1 && state.leases[0][0]===destinationLease,'real runtime observes destination lease');

    // Render the production panel and click real signed controls against Hub/Bridge.
    const {JSDOM}=await import('jsdom');
    const React=await import('react');
    const {installKeyringFromWrap,clearKeyringSession}=await import('../../src/ui/utils/vaultKeyringSession.ts');
    const {sessionHeaders}=await import('./hubOidc.mjs');
    await installKeyringFromWrap(approver.identity,approver.wrap,await approver.chain());
    const dom=new JSDOM('<div id="root"></div>',{url:hub.base});
    const keys=['window','document','navigator','HTMLElement','IS_REACT_ACT_ENVIRONMENT'];
    const descriptors=keys.map(k=>Object.getOwnPropertyDescriptor(globalThis,k));
    for(const [key,value] of Object.entries({window:dom.window,document:dom.window.document,navigator:dom.window.navigator,HTMLElement:dom.window.HTMLElement,IS_REACT_ACT_ENVIRONMENT:true}))Object.defineProperty(globalThis,key,{value,configurable:true,writable:true});
    const originalFetch=globalThis.fetch;
    globalThis.fetch=(url:any,init:any={})=>originalFetch(new URL(String(url),hub.base),{...init,headers:{...Object.fromEntries(new Headers(sessionHeaders(hub.session,hub.base))),...Object.fromEntries(new Headers(init.headers))}});
    const {createRoot}=await import('react-dom/client');
    const {default:OwnerLocalPanel}=await import('../../src/ui/components/taskchain/OwnerLocalPanel.tsx');
    const root=createRoot(dom.window.document.getElementById('root')!);
    const wait=async(check:()=>boolean)=>{
      for(const end=Date.now()+15000;!check();){
        const error=dom.window.document.querySelector('[role=alert]');if(error)throw new Error(error.textContent??'panel failed');
        if(Date.now()>end)throw new Error('control panel timed out: '+dom.window.document.querySelector('pre')?.textContent);
        await React.act(async()=>{await new Promise(r=>setTimeout(r,50));});
      }
    };
    try {
      await React.act(async()=>root.render(React.createElement(OwnerLocalPanel,{onClose:()=>{},initialBridgeId:bridgeId,initialChainId:cid,initialTaskId:source})));
      const revision=()=>dom.window.document.querySelector<HTMLInputElement>('[data-debug-id=owner-local-revision]')?.value;
      await wait(()=>revision()==='5');
      const text=dom.window.document.querySelector<HTMLTextAreaElement>('[data-debug-id=owner-local-body]')!;
      await React.act(async()=>{Object.getOwnPropertyDescriptor(dom.window.HTMLTextAreaElement.prototype,'value')!.set!.call(text,'controls-private-rendered-reason');text.dispatchEvent(new dom.window.Event('input',{bubbles:true}));});
      let rev=5;
      for(const action of ['hold','release','cancel','reopen']){
        const button=()=>dom.window.document.querySelector<HTMLButtonElement>('[data-debug-id=owner-local-task-'+action+']')!;
        await wait(()=>!button().disabled);
        await React.act(async()=>button().click());
        rev++; await wait(()=>revision()===String(rev));
        await wait(()=>!button().disabled);
        expect(revision()===String(rev),'rendered '+action+' performs signed owner CAS');
      }
    } finally {
      await React.act(async()=>root.unmount());globalThis.fetch=originalFetch;clearKeyringSession();dom.window.close();
      keys.forEach((key,i)=>{if(descriptors[i])Object.defineProperty(globalThis,key,descriptors[i]!);else delete(globalThis as any)[key];});
    }
    // Hold a live destination lease. The actual provider receives the checkpoint
    // notice and can renew without a new claim or a changed hard deadline.
    await human('task.hold',{taskId:dest,expectedRevision:'4',body:'Native live hold'});
    state=JSON.parse((await human('runtime.read',{taskId:dest,expectedRevision:'0'})).body);
    expect(state.controls[0][0]==='held' && state.leases[0][0]===destinationLease && state.attempts.completeness==='full','hold retains live owner lease and native attempt evidence');
    const hard=state.leases[0][3];
    for(const end=Date.now()+15000;!worker.readNotices().includes('task.hold on task '+dest);){
      if(Date.now()>end)throw new Error('live holder did not receive exact task hold checkpoint');
      await new Promise(r=>setTimeout(r,100));
    }
    expect(worker.readNotices().includes('task.hold on task '+dest),'real PTY live holder receives checkpoint notification');
    const heartbeat={...input,task_id:dest,lease_id:destinationLease,expected_revision:'5',operation_id:ownerId('op_'),method:'lease.heartbeat',capability:destinationCap};
    const renewed=worker.call(heartbeat);expect(renewed.status===0,'live held child renews exact lease after checkpoint notification');
    destinationCap=JSON.parse(renewed.data.body).capability;
    state=JSON.parse((await human('runtime.read',{taskId:dest,expectedRevision:'0'})).body);
    expect(state.leases[0][3]===hard && state.attempts.attempt_no==='1' && state.attempts.counting_attempts==='1','hold and heartbeat preserve native attempt and hard deadline');
    await human('task.release',{taskId:dest,expectedRevision:'5',body:'Continue live lease'},true);
    heartbeat.expected_revision='6';
    const blocked=worker.call({...heartbeat,operation_id:ownerId('op_'),method:'lease.block',capability:destinationCap,payload:JSON.stringify({requirements_revision:'1',summary:'controls-private-blockneedle',next_steps:'Await explicit answer',waiting_on:'human'})});
    expect(blocked.status===0,'real CLI records human block and releases exact child');
    state=JSON.parse((await human('runtime.read',{taskId:dest,expectedRevision:'0'})).body);
    expect(state.controls[0][0]==='blocked' && state.leases.length===0,'real block state remains visible');
    await human('task.resolve',{taskId:dest,expectedRevision:'7',body:'Signed explicit controls answer'},true);
    state=JSON.parse((await human('runtime.read',{taskId:dest,expectedRevision:'0'})).body);
    expect(state.controls[0][0]==='ready','real signed CLI relay resolves block explicitly');

    await human('fleet.edit',{expectedRevision:'9',instanceId:replacement.instanceId,configurationRevision:'2'});
    await human('lifecycle.configure',{expectedRevision:'10',lifecycleConfig:config(replacement,'2')});
    const next={...input,lease_id:ownerId('lease_'),operation_id:ownerId('op_'),expected_revision:'11',configuration_revision:'2'};
    const nextClaim=replacement.call(next);expect(nextClaim.status===0,'rebound running child claims future source authority');
    const handoff=replacement.call({...next,method:'lease.handoff',operation_id:ownerId('op_'),capability:JSON.parse(nextClaim.data.body).capability,payload:JSON.stringify({requirements_revision:'1',summary:'controls-private-handoffneedle',next_steps:'Continue after checkpoint'})});
    expect(handoff.status===0,'real CLI persists handoff and exact stop intent');
    for(const query of ['controls-private-switchneedle','controls-private-blockneedle','controls-private-handoffneedle']){
      const hits=JSON.parse((await human('chain.search',{taskId:'',expectedRevision:'0',query})).body).hits;
      expect(hits.some((h:any)=>h.kind==='handoff'),'real scoped search indexes '+query);
    }
    expect(replacement.call({...next,method:'lease.heartbeat',operation_id:ownerId('op_'),capability:JSON.parse(nextClaim.data.body).capability}).status!==0,'released child cannot renew stale lease');
  } finally {await worker.stop();await reviewer.stop();await replacement.stop();}
}
