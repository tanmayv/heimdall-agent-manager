// Disposable Hub/Bridge/PTY only: signed baseline, real CLI admission, restart,
// rendered exhaustion and explicit signed recovery without changing history IDs.
import { readFileSync } from 'node:fs';
import { prepareOwnerOperation, ownerId, ownerRelayFile, openOwnerReply, sendOwnerOperation } from '../../src/ui/api/ownerLocalClient.ts';
import { ownerPayloadDigest } from '../../src/ui/api/ownerLocal.ts';

export async function ownerLocalBudgetFlow({session,bridgeId,hub,http,cli,launchChild,expect,approver,stopOwner,restartOwner}:any) {
  const chainId=ownerId('chain_'),taskId=ownerId('task_');
  const children:any[]=[];
  const launch=async()=>{const child=await launchChild();children.push(child);return child;};
  const send=async(body:any)=>{const r=await http(hub,'POST','/api/v1/owner-local/relay',{body});if(r.status!==200)throw new Error(r.raw);return r.data;};
  const human=async(method:string,input:any,useCli=false)=>{
    const op=await prepareOwnerOperation(session,bridgeId,method,{chainId,taskId,...input});
    return useCli?openOwnerReply(session,op,await cli(await ownerRelayFile(session,op))):sendOwnerOperation(session,op,send);
  };
  const runtime=async()=>JSON.parse((await human('runtime.read',{expectedRevision:'0'},true)).body);
  const config=(worker:any,reviewer:any,revision:string)=>({configuration_revision:revision,author_agent_id:worker.agentId,reviewer_agent_id:reviewer.agentId,reviewer_instance_id:reviewer.instanceId,directory_id:ownerId('dir_'),merge_policy:'none',repository:'',worktree:'',source_branch:'',target_branch:'',base_head:''});
  try {
    // The enrollment harness provisions its real CLI transport token here.
    await stopOwner();await restartOwner();
    const worker=await launch(),reviewer=await launch();
    await human('chain.create',{taskId:'',expectedRevision:'0',title:'Native budget demonstration',description:'Disposable signed baseline'});
    await human('task.create',{expectedRevision:'1',title:'Native attempt budget',body:'Preserve logical outcomes'});
    await human('fleet.edit',{expectedRevision:'1',instanceId:worker.instanceId,configurationRevision:'1'});
    await human('lifecycle.configure',{expectedRevision:'2',lifecycleConfig:config(worker,reviewer,'1')});
    await human('requirements.edit',{expectedRevision:'3',requirementsRevision:'1',body:JSON.stringify({goal:'Native budget parity',acceptance:['Exact logical count'],budget:{max_attempts:5}})});
    const bundle=JSON.parse(readFileSync(new URL('../../src/contracts/fixtures/owner-native-budget.json',import.meta.url),'utf8'));
    const records:{kind:string;key:string;raw:string}[]=[];
    for(const kind of ['attempt','event','facet']){
      bundle[kind+'s']=JSON.stringify(JSON.parse(bundle[kind+'s']).map((raw:string)=>{
        const r={...JSON.parse(raw),chain_id:chainId,task_id:taskId};
        const key=kind==='attempt'?r.attempt_no:kind==='event'?r.event_id:JSON.stringify([r.attempt_no,r.kind,r.v]);
        const changed=JSON.stringify(r);records.push({kind,key,raw:changed});return changed;
      }));
    }
    await human('native.history.import',{expectedRevision:'4',body:JSON.stringify(bundle)},true);
    expect((await runtime()).budget.reason==='activation_required','archival import cannot silently supply admission authority');
    const input={protocol_version:'1',chain_id:chainId,task_id:taskId,lease_id:ownerId('lease_'),configuration_revision:'1',expected_revision:'5',operation_id:ownerId('op_'),method:'lease.claim',request_expires_ms:String(Date.now()+300000),capability:''};
    expect(worker.call(input).status!==0,'actual child cannot claim before explicit baseline activation');
    let digest=await ownerPayloadDigest(JSON.stringify(['native.budget.snapshot.v1',chainId,taskId,bundle.source_revision]));
    records.sort((a,b)=>a.kind<b.kind?-1:a.kind>b.kind?1:a.key<b.key?-1:a.key>b.key?1:0);
    for(const r of records)digest=await ownerPayloadDigest(JSON.stringify([digest,r.kind,r.key,r.raw]));
    const cutoff=(await runtime()).budget.local_cutoff;
    const manifest={source_revision:bundle.source_revision,snapshot_digest:digest,native_cutoff:'9007199254740995',local_cutoff:cutoff,event_count:'3',attempt_count:'1',facet_count:'0',requirements_revision:'1',configuration_revision:'1',execution:'standalone',source_gate:'0',source_no_review:'0'};
    await human('budget.activate',{expectedRevision:'5',body:JSON.stringify(manifest)},true);
    input.expected_revision='6';input.operation_id=ownerId('op_');
    const claim=worker.call(input);expect(claim.status===0,'real child continues final native handoff attempt at the limit');
    let state=await runtime();
    expect(state.budget.attempt_no==='5' && state.budget.counting_attempts==='5' && state.attempts.attempt_no==='1','unified budget preserves native seed and separate immutable local ordinals');
    const block={...input,method:'lease.block',operation_id:ownerId('op_'),capability:JSON.parse(claim.data.body).capability,payload:JSON.stringify({requirements_revision:'1',summary:'Budget exhaustion demonstration',next_steps:'Explicit recovery',waiting_on:'human'})};
    expect(worker.call(block).status===0,'real CLI closes continuation and exhausts counting budget');
    state=await runtime();expect(state.budget.reason==='budget_exhausted' && state.leases.length===0,'real signed CLI read shows exhausted durable state');
    await stopOwner();await restartOwner();
    state=await runtime();expect(state.budget.reason==='budget_exhausted' && state.budget.counting_attempts==='5','actual owner restart retains immutable baseline and exhausted count');
    const replacement=await launch(),reviewer2=await launch();
    await human('fleet.edit',{expectedRevision:'7',instanceId:replacement.instanceId,configurationRevision:'2'});
    await human('lifecycle.configure',{expectedRevision:'8',lifecycleConfig:config(replacement,reviewer2,'2')});
    await human('requirements.edit',{expectedRevision:'9',requirementsRevision:'2',body:JSON.stringify({goal:'Revised text keeps budget',acceptance:['Count retained'],budget:{max_attempts:5}})});
    const next={...input,configuration_revision:'2',expected_revision:'10',operation_id:ownerId('op_'),lease_id:ownerId('lease_')};
    const denied=replacement.call(next);
    expect(denied.status!==0 && JSON.stringify(denied.reply).includes('budget_exhausted'),'new current child/config/revision cannot bypass exhausted budget');
    await renderBudgetRecovery({approver,hub,bridgeId,chainId,taskId,expect});
    next.expected_revision='12';next.operation_id=ownerId('op_');
    const recovered=replacement.call(next);expect(recovered.status===0,'rendered signed cancel/reopen authorizes a new non-counting recovery attempt');
    state=await runtime();expect(state.budget.attempt_no==='6' && state.budget.counting_attempts==='5' && state.budget.reason==='','recovery preserves spent count and original numbering');
  } finally {for(const child of children)await child.stop();}
}

async function renderBudgetRecovery({approver,hub,bridgeId,chainId,taskId,expect}:any){
  const {JSDOM}=await import('jsdom');const React=await import('react');
  const {installKeyringFromWrap,clearKeyringSession}=await import('../../src/ui/utils/vaultKeyringSession.ts');
  const {sessionHeaders}=await import('./hubOidc.mjs');
  await installKeyringFromWrap(approver.identity,approver.wrap,await approver.chain());
  const dom=new JSDOM('<div id="root"></div>',{url:hub.base});
  const keys=['window','document','navigator','HTMLElement','IS_REACT_ACT_ENVIRONMENT'];const descriptors=keys.map(k=>Object.getOwnPropertyDescriptor(globalThis,k));
  for(const [key,value] of Object.entries({window:dom.window,document:dom.window.document,navigator:dom.window.navigator,HTMLElement:dom.window.HTMLElement,IS_REACT_ACT_ENVIRONMENT:true}))Object.defineProperty(globalThis,key,{value,configurable:true,writable:true});
  const originalFetch=globalThis.fetch;
  globalThis.fetch=(url:any,init:any={})=>originalFetch(new URL(String(url),hub.base),{...init,headers:{...Object.fromEntries(new Headers(sessionHeaders(hub.session,hub.base))),...Object.fromEntries(new Headers(init.headers))}});
  const {createRoot}=await import('react-dom/client');const {default:OwnerLocalPanel}=await import('../../src/ui/components/taskchain/OwnerLocalPanel.tsx');
  const root=createRoot(dom.window.document.getElementById('root')!);
  const button=(id:string)=>dom.window.document.querySelector<HTMLButtonElement>('[data-debug-id='+id+']')!;
  const revision=()=>dom.window.document.querySelector<HTMLInputElement>('[data-debug-id=owner-local-revision]')?.value;
  const wait=async(check:()=>boolean)=>{for(const end=Date.now()+15000;!check();){const error=dom.window.document.querySelector('[role=alert]');if(error)throw new Error(error.textContent??'panel failed');if(Date.now()>end)throw new Error('budget panel timed out');await React.act(async()=>{await new Promise(r=>setTimeout(r,50));});}};
  try{
    await React.act(async()=>root.render(React.createElement(OwnerLocalPanel,{onClose:()=>{},initialBridgeId:bridgeId,initialChainId:chainId,initialTaskId:taskId})));
    await wait(()=>revision()==='10' && !button('owner-local-runtime-read').disabled);
    await React.act(async()=>button('owner-local-runtime-read').click());
    await wait(()=>dom.window.document.querySelector('[data-debug-id=owner-local-budget]')?.textContent?.includes('Attempt budget exhausted')===true);
    expect(dom.window.document.querySelector('[data-debug-id=owner-local-budget]')?.textContent?.includes('5 / 5'),'actual rendered UI displays spent native count and exhaustion');
    await wait(()=>!button('owner-local-task-cancel').disabled);
    const text=dom.window.document.querySelector<HTMLTextAreaElement>('[data-debug-id=owner-local-body]')!;
    await React.act(async()=>{Object.getOwnPropertyDescriptor(dom.window.HTMLTextAreaElement.prototype,'value')!.set!.call(text,'Explicit authorized budget recovery');text.dispatchEvent(new dom.window.Event('input',{bubbles:true}));});
    for(const [action,rev] of [['cancel','11'],['reopen','12']]){
      await wait(()=>!button('owner-local-task-'+action).disabled);
      await React.act(async()=>button('owner-local-task-'+action).click());
      await wait(()=>revision()===rev && !button('owner-local-task-'+action).disabled);
    }
  }finally{
    await React.act(async()=>root.unmount());globalThis.fetch=originalFetch;clearKeyringSession();dom.window.close();
    keys.forEach((key,i)=>{if(descriptors[i])Object.defineProperty(globalThis,key,descriptors[i]!);else delete(globalThis as any)[key];});
  }
}
