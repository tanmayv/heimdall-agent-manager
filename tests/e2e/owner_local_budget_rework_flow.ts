import { readFileSync } from 'node:fs';
import { prepareOwnerOperation, ownerId, ownerRelayFile, openOwnerReply, sendOwnerOperation } from '../../src/ui/api/ownerLocalClient.ts';
import { ownerPayloadDigest } from '../../src/ui/api/ownerLocal.ts';

// Actual signed commands against the disposable Bridge, including real children.
export async function ownerLocalBudgetReworkFlow(args:any) {
  const {session,bridgeId,hub,http,cli,launchChild,expect,stopOwner,restartOwner}=args;
  const children:any[]=[];
  const launch=async()=>{const c=await launchChild();children.push(c);return c;};
  const send=async(body:any)=>{const r=await http(hub,'POST','/api/v1/owner-local/relay',{body});if(r.status!==200)throw new Error(r.raw);return r.data;};
  const create=async(title:string,budget:any={max_attempts:5})=>{
    const chainId=ownerId('chain_'),taskId=ownerId('task_');let worker=await launch(),reviewer=await launch(),configuration='1';
    const human=async(method:string,input:any={})=>{
      const target=input.taskId??taskId;
      let revision=input.expectedRevision;
      if(revision===undefined){const read=await human(target?'runtime.read':'chain.read',{taskId:target,expectedRevision:'0'});revision=JSON.parse(read.body).revision;}
      const op=await prepareOwnerOperation(session,bridgeId,method,{chainId,taskId:target,...input,expectedRevision:revision});
      return openOwnerReply(session,op,await cli(await ownerRelayFile(session,op)));
    };
    const config=()=>({configuration_revision:configuration,author_agent_id:worker.agentId,reviewer_agent_id:reviewer.agentId,reviewer_instance_id:reviewer.instanceId,directory_id:ownerId('dir_'),merge_policy:'none',repository:'',worktree:'',source_branch:'',target_branch:'',base_head:''});
    const setup=async(tid:string,title:string,budget:any)=>{
      await human('task.create',{taskId:tid,expectedRevision:JSON.parse((await human('chain.read',{taskId:'',expectedRevision:'0'})).body).revision,title,body:'Signed native-parity regression'});
      await human('fleet.edit',{taskId:tid,instanceId:worker.instanceId,configurationRevision:configuration});
      await human('lifecycle.configure',{taskId:tid,lifecycleConfig:config()});
      await human('requirements.edit',{taskId:tid,requirementsRevision:'1',body:JSON.stringify({goal:title,acceptance:['Native admission parity'],budget})});
    };
    const state=async(tid=taskId)=>JSON.parse((await human('runtime.read',{taskId:tid,expectedRevision:'0'})).body);
    const call=async(child:any,method:string,lease:string,payload?:any,capability='',tid=taskId)=>child.call({protocol_version:'1',chain_id:chainId,task_id:tid,lease_id:lease,configuration_revision:configuration,expected_revision:(await state(tid)).revision,operation_id:ownerId('op_'),method,request_expires_ms:String(Date.now()+300000),capability,...(payload===undefined?{}:{payload:JSON.stringify(payload)})});
    const claim=async(tid=taskId,lease=ownerId('lease_'))=>{const r=await call(worker,'lease.claim',lease,undefined,'',tid);expect(r.status===0,'real current child claims '+title);return {lease,cap:JSON.parse(r.data.body).capability};};
    const submit=async(work:any,attempt:string,verdict='approve',tid=taskId)=>{
      for(const method of ['requirements.present','requirements.ack'])expect((await call(worker,method,work.lease,{requirements_revision:'1'},work.cap,tid)).status===0,'real '+method+' '+title);
      expect((await call(worker,'lease.submit',work.lease,{requirements_revision:'1',head:'',summary:'Complete'},work.cap,tid)).status===0,'real signed submit '+title);
      const p={requirements_revision:'1',attempt,head:'',verdict,summary:'Independent verdict'};
      const opened=await call(reviewer,'review.open',work.lease,p,'',tid);expect(opened.status===0,'real independent review opens '+title);
      expect((await call(reviewer,'review.post',work.lease,p,JSON.parse(opened.data.body).capability,tid)).status===0,'real independent review posts '+title);
    };
    await human('chain.create',{taskId:'',expectedRevision:'0',title,description:'Disposable review regressions'});
    await setup(taskId,title,budget);
    return {chainId,taskId,human,state,call,claim,submit,setup,config,worker:()=>worker,reviewer:()=>reviewer,rebind:async()=>{worker=await launch();reviewer=await launch();configuration='2';await human('fleet.edit',{instanceId:worker.instanceId,configurationRevision:configuration});await human('lifecycle.configure',{lifecycleConfig:config()});}};
  };
  try {
    // The enclosing owner-local flow has already provisioned the CLI transport.
    const raised=await create('Budget increase preserves held overlay',{max_attempts:1,hard_deadline:2});
    await raised.claim();
    for(const end=Date.now()+45000;;){if((await raised.state()).budget.reason==='budget_exhausted')break;if(Date.now()>end)throw new Error('real lease maintenance did not expire bounded work');await new Promise(r=>setTimeout(r,500));}
    await raised.human('task.hold',{body:'Keep this independent hold'});
    await raised.human('requirements.edit',{requirementsRevision:'2',body:JSON.stringify({goal:'Authorized budget increase',acceptance:['Keep hold'],budget:{max_attempts:2,hard_deadline:30}})});
    let state=await raised.state();expect(state.budget.reason==='' && state.controls[0][0]==='held','real budget increase clears owned block and retains independent hold');
    const held=await raised.call(raised.worker(),'lease.claim',ownerId('lease_'));
    expect(held.status!==0,'real held claim remains denied after budget recovery');
    await raised.human('task.release',{body:'Release hold'});await raised.claim();
    expect((await raised.state()).budget.counting_attempts==='2','real current child admits native next grant after budget increase');

    const osc=await create('Native oscillation admission');
    for(let n=1;n<=3;n++)await osc.submit(await osc.claim(),String(n),'request_changes');
    state=await osc.state();expect(state.budget.reason==='oscillation' && state.controls[0][0]==='blocked','real third rejection persists oscillation block');
    expect((await osc.call(osc.worker(),'lease.claim',ownerId('lease_'))).status!==0,'real fourth claim is denied by oscillation');
    await renderOscillation({...args,chainId:osc.chainId,taskId:osc.taskId});
    await osc.human('task.resolve',{body:'Explicit signed oscillation answer'});await osc.claim();
    expect((await osc.state()).budget.counting_attempts==='4','signed answer restores native fourth counting grant');

    const dep=await create('Native live dependency retirement',{max_attempts:1});const dest=ownerId('task_');
    await dep.setup(dest,'Prerequisite',{max_attempts:5});
    const work=await dep.claim();
    const edge=await prepareOwnerOperation(session,bridgeId,'dependency.edit',{chainId:dep.chainId,taskId:dep.taskId,expectedRevision:(await dep.state()).revision,body:JSON.stringify({prerequisite:dest,enabled:'1'})});
    await sendOwnerOperation(session,edge,send);
    state=await dep.state();expect(state.leases.length===0 && state.budget.counting_attempts==='1' && state.budget.last_release==='dep_added','real signed dependency addition retires exact source lease without spending next budget');
    expect((await dep.call(dep.worker(),'lease.heartbeat',work.lease,undefined,work.cap)).status!==0,'real retired dependency capability cannot renew');
    expect((await dep.call(dep.worker(),'lease.claim',ownerId('lease_'))).status!==0,'real source cannot claim before prerequisite completion');
    await dep.submit(await dep.claim(dest),'1','approve',dest);
    await dep.claim();state=await dep.state();
    expect(state.budget.attempt_no==='2' && state.budget.counting_attempts==='1','real prerequisite completion admits non-counting next grant at max1');

    const overlap=await create('Native exact history reconciliation');const old=await overlap.claim();
    expect((await overlap.call(overlap.worker(),'lease.handoff',old.lease,{requirements_revision:'1',summary:'Original shared work',next_steps:'Continue'},old.cap)).status===0,'real original shared lease hands off');
    const history=JSON.parse((await overlap.human('history.read',{taskId:'',expectedRevision:'0'})).body);
    const grant=history.items.find((e:any)=>e.kind==='lease.claim'),handoff=history.items.find((e:any)=>e.kind==='lease.handoff');
    const bundle=JSON.parse(readFileSync(new URL('../../src/contracts/fixtures/owner-native-budget.json',import.meta.url),'utf8'));
    const prov=JSON.stringify({requirements_revision:JSON.parse(old.cap).requirements_revision,configuration_revision:JSON.parse(old.cap).configuration_revision});
    bundle.owner_user_id=session.identity.userId;bundle.source_revision='overlap_snapshot';
    bundle.events=JSON.stringify(JSON.parse(bundle.events).map((raw:string)=>{
      const e={...JSON.parse(raw),chain_id:overlap.chainId,task_id:overlap.taskId,owner_user_id:bundle.owner_user_id,provenance_json:prov};
      if(e.kind==='lease_granted'){e.ts_ms=grant.ts_ms;e.payload_json=JSON.stringify({lease_id:old.lease,instance_id:overlap.worker().instanceId,bridge_id:bridgeId,attempt_no:5});}
      if(e.kind==='handoff'){e.ts_ms=handoff.ts_ms;e.actor_kind='agent';e.actor_id=handoff.actor_id;e.payload_json=JSON.stringify({lease_id:old.lease,attempt_no:5});}
      return JSON.stringify(e);
    }));
    bundle.attempts=JSON.stringify(JSON.parse(bundle.attempts).map((raw:string)=>JSON.stringify({...JSON.parse(raw),chain_id:overlap.chainId,task_id:overlap.taskId,owner_user_id:bundle.owner_user_id,holder_instance_id:overlap.worker().instanceId,started_at:new Date(Number(grant.ts_ms)).toISOString(),ended_at:new Date(Number(handoff.ts_ms)).toISOString(),provenance_json:prov})));
    await overlap.human('native.history.import',{body:JSON.stringify(bundle)});
    let digest=await ownerPayloadDigest(JSON.stringify(['native.budget.snapshot.v1',overlap.chainId,overlap.taskId,bundle.source_revision]));
    const records:any[]=[];for(const kind of ['attempt','event','facet'])for(const raw of JSON.parse(bundle[kind+'s'])){const r=JSON.parse(raw);records.push({kind,key:kind==='attempt'?r.attempt_no:kind==='event'?r.event_id:JSON.stringify([r.attempt_no,r.kind,r.v]),raw});}
    records.sort((a,b)=>a.kind<b.kind?-1:a.kind>b.kind?1:a.key<b.key?-1:a.key>b.key?1:0);for(const r of records)digest=await ownerPayloadDigest(JSON.stringify([digest,r.kind,r.key,r.raw]));
    const manifest={source_revision:bundle.source_revision,snapshot_digest:digest,native_cutoff:'9007199254740995',local_cutoff:(await overlap.state()).budget.local_cutoff,event_count:'3',attempt_count:'1',facet_count:'0',requirements_revision:'1',configuration_revision:'1',execution:'standalone',source_gate:'0',source_no_review:'0'};
    await overlap.human('budget.activate',{body:JSON.stringify(manifest)});
    state=await overlap.state();expect(state.budget.attempt_no==='5' && state.budget.counting_attempts==='5' && state.attempts.attempt_no==='1','real signed nonempty exact overlap reconciles once without renumbering local history');
    await stopOwner();await restartOwner();
    state=await overlap.state();expect(state.budget.counting_attempts==='5','real owner restart retains exact overlap disposition');
    await overlap.rebind();await overlap.claim();state=await overlap.state();
    expect(state.budget.attempt_no==='5' && state.budget.counting_attempts==='5','real rebound child continues reconciled native handoff without double counting');
  } finally {for(const child of children)await child.stop();}
}

async function renderOscillation({approver,hub,bridgeId,chainId,taskId,expect}:any){
  const {JSDOM}=await import('jsdom');const React=await import('react');
  const {installKeyringFromWrap,clearKeyringSession}=await import('../../src/ui/utils/vaultKeyringSession.ts');const {sessionHeaders}=await import('./hubOidc.mjs');
  await installKeyringFromWrap(approver.identity,approver.wrap,await approver.chain());
  const dom=new JSDOM('<div id="root"></div>',{url:hub.base}),keys=['window','document','navigator','HTMLElement','IS_REACT_ACT_ENVIRONMENT'],descriptors=keys.map(k=>Object.getOwnPropertyDescriptor(globalThis,k));
  for(const [k,value] of Object.entries({window:dom.window,document:dom.window.document,navigator:dom.window.navigator,HTMLElement:dom.window.HTMLElement,IS_REACT_ACT_ENVIRONMENT:true}))Object.defineProperty(globalThis,k,{value,configurable:true,writable:true});
  const saved=globalThis.fetch;globalThis.fetch=(url:any,init:any={})=>saved(new URL(String(url),hub.base),{...init,headers:{...Object.fromEntries(new Headers(sessionHeaders(hub.session,hub.base))),...Object.fromEntries(new Headers(init.headers))}});
  const {createRoot}=await import('react-dom/client'),{default:Panel}=await import('../../src/ui/components/taskchain/OwnerLocalPanel.tsx');const root=createRoot(dom.window.document.getElementById('root')!);
  const button=()=>dom.window.document.querySelector<HTMLButtonElement>('[data-debug-id=owner-local-runtime-read]')!;
  const wait=async(check:()=>boolean)=>{for(const end=Date.now()+15000;!check();){const e=dom.window.document.querySelector('[role=alert]');if(e)throw new Error(e.textContent??'panel failure');if(Date.now()>end)throw new Error('oscillation panel timeout');await React.act(async()=>{await new Promise(r=>setTimeout(r,50));});}};
  try{await React.act(async()=>root.render(React.createElement(Panel,{onClose:()=>{},initialBridgeId:bridgeId,initialChainId:chainId,initialTaskId:taskId})));await wait(()=>button() && !button().disabled);await React.act(async()=>button().click());await wait(()=>dom.window.document.querySelector('[data-debug-id=owner-local-budget]')?.textContent?.includes('Repeated review rejections')===true);expect(true,'production rendered UI exposes native oscillation reason');await wait(()=>!button().disabled);}finally{await React.act(async()=>root.unmount());globalThis.fetch=saved;clearKeyringSession();dom.window.close();keys.forEach((k,i)=>{if(descriptors[i])Object.defineProperty(globalThis,k,descriptors[i]!);else delete(globalThis as any)[k];});}
}
