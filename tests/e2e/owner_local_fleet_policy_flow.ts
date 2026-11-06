import { prepareOwnerOperation, ownerId, ownerRelayFile, openOwnerReply } from '../../src/ui/api/ownerLocalClient.ts';

// Uses actual signed UI operations, real CLI and disposable Hub -> Bridge relay.
export async function ownerLocalFleetPolicyFlow({session,bridgeId,cli,expect,stopOwner,restartOwner,approver,hub}:any) {
  const chainId=ownerId('chain_');
  const prepare=(method:string,input:any={})=>prepareOwnerOperation(session,bridgeId,method,{chainId,expectedRevision:'0',...input});
  const invoke=async(op:any)=>openOwnerReply(session,op,await cli(await ownerRelayFile(session,op)));
  const call=async(method:string,input:any={})=>invoke(await prepare(method,input));
  const denied=async(method:string,input:any,message:string)=>{let rejected=false;try{await call(method,input);}catch{rejected=true;}expect(rejected,message);};
  await call('chain.create',{title:'Canonical durable fleet policy',description:'Disposable metadata regression'});
  const policy={provider_profile:'code-profile',task_chain_id:chainId,agent_id:'agent:durable:one',capacity:3,min_warm:1,idle_ttl_seconds:600,bridge_models_json:JSON.stringify({[bridgeId]:{provider_profile:'bridge-profile',provider:'codex',model:'模型🚀'}}),provider:'codex',model:'模型🚀',roles_json:'[ "worker", "security" ]',bridge_id:bridgeId,paused_roles_json:'["security"]',created_at:'2020-01-02T03:04:05.123456+05:30',updated_at:'2021-02-03T04:05:06Z'};
  const exact=await prepare('fleet.policy.set',{expectedRevision:'1',body:JSON.stringify(policy)});
  const accepted=await invoke(exact);
  expect(JSON.parse(accepted.body).revision==='2','real signed policy edit advances chain CAS');
  const read=async(input:any={})=>JSON.parse((await call('fleet.policy.read',input)).body);
  let page=await read();
  expect(Object.keys(page.items[0].policy).length===Object.keys(policy).length && Object.entries(policy).every(([key,value])=>page.items[0].policy[key]===value),'real CLI round-trips ordinary fleet shape, exact timestamps and Unicode');
  expect(page.items[0].accepted_seq===accepted.commit_seq,'policy links immutable accepted event');
  await denied('fleet.policy.set',{expectedRevision:'1',body:JSON.stringify(policy)},'real stale policy CAS rejected');
  await denied('fleet.policy.set',{expectedRevision:'2',body:JSON.stringify({...policy,task_chain_id:'other_chain'})},'cross-chain policy rejected');
  await denied('fleet.policy.set',{expectedRevision:'2',body:JSON.stringify({...policy,roles_json:'["worker","worker"]'})},'duplicate native roles rejected');
  await call('fleet.policy.set',{expectedRevision:'2',body:JSON.stringify({...policy,agent_id:'agent:durable:two'})});
  page=await read({limit:1});
  expect(page.items.length===1 && page.next_cursor,'real policy list supports bounded revision-bound pagination');
  const cursor=page.next_cursor;
  const next=await read({limit:1,cursor});
  expect(next.items.length===1 && !next.next_cursor,'real second policy page advances without duplicates');
  await call('fleet.policy.set',{expectedRevision:'3',body:JSON.stringify({...policy,capacity:5,updated_at:'2022-03-04T05:06:07+05:30'})});
  await denied('fleet.policy.read',{limit:1,cursor},'accepted policy change invalidates old list cursor');
  const replay=await invoke(exact);
  expect(replay.replay && replay.body===accepted.body,'historical signed policy retry replays original receipt after later update');
  const history=JSON.parse((await call('history.read')).body);
  const event=history.items.find((item:any)=>item.kind==='fleet.policy.set');
  const evidence=JSON.parse((await call('history.fetch',{eventSeq:event.seq})).body);
  expect(JSON.parse(JSON.parse(evidence.evidence).content).body===JSON.stringify(policy),'exact original fleet document retained in immutable accepted history');
  await stopOwner();await restartOwner();
  page=await read();
  expect(page.items[0].policy.capacity===5 && page.items[0].policy.created_at===policy.created_at && page.items[0].policy.roles_json===policy.roles_json && page.items[0].policy.bridge_models_json===policy.bridge_models_json,'owner restart preserves current policy and original native field bytes');
  expect((await invoke(exact)).replay,'owner restart preserves signed lost-reply replay');

  const {JSDOM}=await import('jsdom');
  const React=await import('react');
  const {installKeyringFromWrap,clearKeyringSession}=await import('../../src/ui/utils/vaultKeyringSession.ts');
  const {sessionHeaders}=await import('./hubOidc.mjs');
  const {default:OwnerLocalPanel}=await import('../../src/ui/components/taskchain/OwnerLocalPanel.tsx');
  await installKeyringFromWrap(approver.identity,approver.wrap,await approver.chain());
  const dom=new JSDOM('<div id="root"></div>',{url:hub.base});
  const keys=['window','document','navigator','HTMLElement','IS_REACT_ACT_ENVIRONMENT'];
  const descriptors=keys.map(k=>Object.getOwnPropertyDescriptor(globalThis,k));
  for(const [key,value] of Object.entries({window:dom.window,document:dom.window.document,navigator:dom.window.navigator,HTMLElement:dom.window.HTMLElement,IS_REACT_ACT_ENVIRONMENT:true}))Object.defineProperty(globalThis,key,{value,configurable:true,writable:true});
  const originalFetch=globalThis.fetch;
  globalThis.fetch=(url:any,init:any={})=>originalFetch(new URL(String(url),hub.base),{...init,headers:{...Object.fromEntries(new Headers(sessionHeaders(hub.session,hub.base))),...Object.fromEntries(new Headers(init.headers))}});
  const {createRoot}=await import('react-dom/client');
  const root=createRoot(dom.window.document.getElementById('root')!);
  const settled=async()=>{for(const end=Date.now()+15000;(dom.window.document.querySelector('[data-debug-id="owner-local-list"]') as HTMLButtonElement)?.disabled;){if(Date.now()>end)throw new Error('policy UI did not settle: '+dom.window.document.body.textContent);await React.act(async()=>{await new Promise(r=>setTimeout(r,50));});}};
  try{
    await React.act(async()=>root.render(React.createElement(OwnerLocalPanel,{onClose:()=>{},initialBridgeId:bridgeId,initialChainId:chainId})));
    await settled();
    await React.act(async()=>{(dom.window.document.querySelector('[data-debug-id="owner-local-fleet-policy-read"]') as HTMLButtonElement).click();});
    await settled();
    expect(dom.window.document.body.textContent?.includes('模型🚀'),'rendered UI reads ordinary durable fleet policy from actual owner');
    const textarea=dom.window.document.querySelector('[data-debug-id="owner-local-fleet-policy"]') as HTMLTextAreaElement;
    await React.act(async()=>{Object.getOwnPropertyDescriptor(dom.window.HTMLTextAreaElement.prototype,'value')!.set!.call(textarea,JSON.stringify({...policy,capacity:7,updated_at:'2023-04-05T06:07:08Z'}));textarea.dispatchEvent(new dom.window.Event('input',{bubbles:true}));});
    await React.act(async()=>{(dom.window.document.querySelector('[data-debug-id="owner-local-fleet-policy-save"]') as HTMLButtonElement).click();});
    await settled();
    expect(!dom.window.document.querySelector('[role="alert"]'),'rendered signed policy save succeeds with current chain CAS');
    const current=await read();
    expect(current.items[0].policy.capacity===7,'rendered UI mutation round-trips through actual relay and CLI observation');
  }finally{
    await React.act(async()=>root.unmount());
    globalThis.fetch=originalFetch;clearKeyringSession();dom.window.close();
    keys.forEach((key,i)=>{if(descriptors[i])Object.defineProperty(globalThis,key,descriptors[i]!);else delete(globalThis as any)[key];});
  }
}
