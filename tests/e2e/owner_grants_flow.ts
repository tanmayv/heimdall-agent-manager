// Disposable identities and services only. No grant table edits: every grant
// change crosses the production signed browser/CLI -> Hub -> owner boundary.
import { createDeviceIdentity, memoryDeviceStore } from '../../src/ui/utils/deviceIdentity.ts';
import { generatePairCode, generatePairSalt, derivePairKeys, pairHubOrigin } from '../../src/ui/utils/vaultPairing.ts';
import { buildPairedRegistration, checkBrowserCodeInfo, buildBrowserApproval, buildRevocation } from '../../src/ui/utils/vaultDeviceFlows.ts';
import { signedRequestHeaders } from '../../src/ui/utils/vaultRequestSigner.ts';
import { importKeyring } from '../../src/ui/utils/vaultKeyring.ts';
import { prepareOwnerOperation, sendOwnerOperation, ownerId, ownerRelayFile, openOwnerReply } from '../../src/ui/api/ownerLocalClient.ts';

export async function ownerGrantsFlow({hub, approver, bridgeId, http, expect, cli, stopOwner, restartOwner, rekeyOwner}: any) {
  const addBrowser = async (label: string) => {
    const identity = await createDeviceIdentity(memoryDeviceStore(), approver.userId);
    const salt = generatePairSalt();
    const keys = await derivePairKeys(generatePairCode(), {kind:'browser',userId:approver.userId,hubOrigin:pairHubOrigin(hub.base),pairSalt:salt});
    const reg = await buildPairedRegistration(identity,label,keys);
    const registered = await http(hub,'POST','/api/v1/vault/devices/register',{body:{statement:reg.statement,proof_signature:reg.signature,pair_lookup:reg.pairLookup,pair_key_mac:reg.pairKeyMac,pair_salt:salt,pair_hub_origin:pairHubOrigin(hub.base)}});
    expect(registered.status===200 || registered.status===201,'grant fixture browser registered: '+label);
    const verified = await http(hub,'POST','/api/v1/device/verify',{body:{pair_lookups:[keys.lookup]}});
    const paired = await checkBrowserCodeInfo(verified.data,keys,approver.userId);
    const approval = await buildBrowserApproval(approver.identity,await approver.chain(),paired,keys,label,approver.keyringBytes);
    const path = '/api/v1/vault/devices/'+identity.deviceId+'/approve';
    const approved = await http(hub,'POST',path,{body:approval,headers:await signedRequestHeaders(approver.identity,approver.userId,'POST',path,JSON.stringify(approval))});
    expect(approved.status===200,'grant fixture browser approved: '+label);
    return identity;
  };
  const a = await addBrowser('grant creator A');
  const b = await addBrowser('grant replacement B');
  const session = async (identity=approver.identity) => ({identity,chain:await approver.chain(),keyring:await importKeyring(Uint8Array.from(approver.keyringBytes),approver.userId)});
  const send = async (body:unknown) => {
    const response=await http(hub,'POST','/api/v1/owner-local/relay',{body});
    if(response.status!==200)throw new Error(response.raw);
    return response.data;
  };
  const call = async (s:any,method:any,input:any,viaCli=false) => {
    const op=await prepareOwnerOperation(s,bridgeId,method,input);
    return viaCli ? openOwnerReply(s,op,await cli(await ownerRelayFile(s,op))) : sendOwnerOperation(s,op,send);
  };
  const denied = async (fn:()=>Promise<unknown>,message:string) => {
    let refused=false;try{await fn();}catch{refused=true;}expect(refused,message);
  };
  const root=await session(), creator=await session(a), replacement=await session(b);
  const cid=ownerId('chain_'), tid=ownerId('task_');
  await call(creator,'chain.create',{chainId:cid,expectedRevision:'0',title:'Grant recovery chain',description:'signed access'});
  await call(creator,'task.create',{chainId:cid,taskId:tid,expectedRevision:'1',title:'Grant task',body:'grants-private-searchneedle'});
  const read=()=>call(replacement,'task.read',{chainId:cid,taskId:tid,expectedRevision:'0'});
  await denied(read,'enrolled B with the same content key is denied before a grant');
  const grant={chainId:cid,expectedRevision:'2',grantPrincipal:b.deviceId,grantExpiresMs:String(Date.now()+600000),grantCanMutate:false};
  await call(creator,'grant.set',grant,true);
  expect(JSON.parse((await read()).body).body==='grants-private-searchneedle','signed CLI grant permits B detail read');
  const search=()=>call(replacement,'chain.search',{chainId:cid,expectedRevision:'0',query:'searchneedle'});
  expect(JSON.parse((await search()).body).hits.length===1,'granted B searches canonical owner content');
  await denied(()=>call(replacement,'task.comment',{chainId:cid,taskId:tid,expectedRevision:'1',body:'forbidden write'}),'read-only B cannot write');
  await denied(()=>call(replacement,'grant.policy',{chainId:cid,expectedRevision:'3',policyRevision:'1',recoveryEnabled:true}),'delegated B cannot enable recovery or administer access');
  await call(creator,'grant.set',{...grant,expectedRevision:'3',grantCanMutate:true});
  const comment=await prepareOwnerOperation(replacement,bridgeId,'task.comment',{chainId:cid,taskId:tid,expectedRevision:'1',body:'grant once'});
  await sendOwnerOperation(replacement,comment,send);
  expect((await sendOwnerOperation(replacement,comment,send)).replay,'B historical write retries replay exactly once');
  await call(creator,'grant.revoke',{chainId:cid,expectedRevision:'5',grantPrincipal:b.deviceId},true);
  await denied(read,'revoked local grant denies B detail');
  await denied(search,'revoked local grant denies B search snippets');
  await denied(()=>sendOwnerOperation(replacement,comment,send),'revoked local grant denies historical receipt replay');
  const recoveryInput={chainId:cid,expectedRevision:'6',grantPrincipal:b.deviceId,grantExpiresMs:String(Date.now()+600000),grantCanMutate:true};
  await denied(()=>call(root,'grant.recover',recoveryInput),'paired root refuses recovery before explicit policy opt-in');
  await call(creator,'grant.policy',{chainId:cid,expectedRevision:'6',policyRevision:'1',recoveryEnabled:true});
  const oldCreator=await prepareOwnerOperation(creator,bridgeId,'task.read',{chainId:cid,taskId:tid,expectedRevision:'0'});

  // Exercise the rendered production grant controls on a separate root-created
  // chain, so creator A can later be revoked without UI/session fabrication.
  const uiChain=ownerId('chain_');
  await call(root,'chain.create',{chainId:uiChain,expectedRevision:'0',title:'UI grants',description:'root creator'});
  const {JSDOM}=await import('jsdom');
  const React=await import('react');
  const {installKeyringFromWrap,clearKeyringSession}=await import('../../src/ui/utils/vaultKeyringSession.ts');
  const {sessionHeaders}=await import('./hubOidc.mjs');
  await installKeyringFromWrap(approver.identity,approver.wrap,await approver.chain());
  const dom=new JSDOM('<div id="root"></div>',{url:hub.base});
  const globals=['window','document','navigator','HTMLElement','IS_REACT_ACT_ENVIRONMENT'];
  const descriptors=globals.map(k=>Object.getOwnPropertyDescriptor(globalThis,k));
  for(const [key,value] of Object.entries({window:dom.window,document:dom.window.document,navigator:dom.window.navigator,HTMLElement:dom.window.HTMLElement,IS_REACT_ACT_ENVIRONMENT:true}))Object.defineProperty(globalThis,key,{value,configurable:true,writable:true});
  const originalFetch=globalThis.fetch;
  globalThis.fetch=(url:any,init:any={})=>originalFetch(new URL(String(url),hub.base),{...init,headers:{...Object.fromEntries(new Headers(sessionHeaders(hub.session,hub.base))),...Object.fromEntries(new Headers(init.headers))}});
  const {createRoot}=await import('react-dom/client');
  const {default:OwnerLocalPanel}=await import('../../src/ui/components/taskchain/OwnerLocalPanel.tsx');
  const rendered=createRoot(dom.window.document.getElementById('root')!);
  const element=(id:string)=>dom.window.document.querySelector<HTMLElement>('[data-debug-id='+id+']')!;
  const wait=async(check:()=>boolean)=>{
    for(const end=Date.now()+20000;!check();){
      const error=dom.window.document.querySelector('[role=alert]');if(error)throw new Error(error.textContent??'panel failed');
      if(Date.now()>end)throw new Error('grant panel timed out: '+dom.window.document.body.textContent);
      await React.act(async()=>{await new Promise(r=>setTimeout(r,50));});
    }
  };
  const uiAction=async(id:string)=>{
    await wait(()=>!(element(id) as HTMLButtonElement).disabled);
    await React.act(async()=>element(id).click());
    await wait(()=>!(element(id) as HTMLButtonElement).disabled);
    const error=dom.window.document.querySelector('[role=alert]');if(error)throw new Error(error.textContent??'grant action failed');
  };
  try{
    await React.act(async()=>rendered.render(React.createElement(OwnerLocalPanel,{onClose:()=>{},initialBridgeId:bridgeId,initialChainId:uiChain})));
    await wait(()=>(element('owner-local-revision') as HTMLInputElement).value==='1' && !(element('owner-local-grant-set') as HTMLButtonElement).disabled);
    await React.act(async()=>{
      const select=element('owner-local-grant-principal') as HTMLSelectElement;
      select.value=b.deviceId;select.dispatchEvent(new dom.window.Event('change',{bubbles:true}));
    });
    await uiAction('owner-local-grant-set');
    expect(JSON.parse((await call(replacement,'chain.read',{chainId:uiChain,expectedRevision:'0'})).body).title==='UI grants','rendered UI Save device grant permits B');
    await uiAction('owner-local-grant-read');
    expect(dom.window.document.querySelector('pre')?.textContent?.includes(b.deviceId),'rendered UI lists current grant and recovery policy');
    await uiAction('owner-local-grant-revoke');
    await denied(()=>call(replacement,'chain.read',{chainId:uiChain,expectedRevision:'0'}),'rendered UI Revoke device grant denies B');
  }finally{
    await React.act(async()=>rendered.unmount());globalThis.fetch=originalFetch;clearKeyringSession();dom.window.close();
    globals.forEach((key,i)=>{if(descriptors[i])Object.defineProperty(globalThis,key,descriptors[i]!);else delete(globalThis as any)[key];});
  }
  // Actual directory revocation rotates the content epoch. Give the owner its
  // new wrap, and send A's old signature inside current-epoch ciphertext.
  const {body,nextKeyring}=await buildRevocation(approver.identity,await approver.chain(),a.deviceId,approver.keyringBytes);
  const revokePath='/api/v1/vault/devices/'+a.deviceId+'/revoke';
  const revoked=await http(hub,'POST',revokePath,{body,headers:await signedRequestHeaders(approver.identity,approver.userId,'POST',revokePath,JSON.stringify(body))});
  expect(revoked.status===200,'actual directory revokes creator A');
  approver.keyringBytes=nextKeyring;await rekeyOwner();
  const currentRoot=await session(), currentB=await session(b);
  await denied(async()=>{
    const relay=await ownerRelayFile(currentRoot,oldCreator);
    await openOwnerReply(currentRoot,oldCreator,await send(relay));
  },'current vault content key cannot revive revoked creator signature');
  const policy=JSON.parse((await call(currentRoot,'grant.read',{chainId:cid,expectedRevision:'0'})).body);
  expect(policy.recovery_enabled==='1','root can observe enabled policy independently of revoked creator');
  await call(currentRoot,'grant.recover',{...recoveryInput,expectedRevision:policy.revision},true);
  expect(JSON.parse((await call(currentB,'task.read',{chainId:cid,taskId:tid,expectedRevision:'0'})).body).body==='grants-private-searchneedle','paired root signed CLI recovery restores B access after creator revocation');
  await denied(()=>call(currentB,'chain.read',{chainId:uiChain,expectedRevision:'0'}),'recovered chain grant does not leak another chain');
  await stopOwner();
  const offline=await send(await ownerRelayFile(currentB,await prepareOwnerOperation(currentB,bridgeId,'task.read',{chainId:cid,taskId:tid,expectedRevision:'0'})));
  expect(offline.code==='owner_unavailable' && !offline.envelope,'granted B gets no details while owner is offline');
  await restartOwner();
  const current=JSON.parse((await call(currentRoot,'grant.read',{chainId:cid,expectedRevision:'0'})).body);
  await call(currentRoot,'grant.recover',{...recoveryInput,expectedRevision:current.revision,grantExpiresMs:String(Date.now()+4000)});
  const expiring=await prepareOwnerOperation(currentB,bridgeId,'task.comment',{chainId:cid,taskId:tid,expectedRevision:'2',body:'expires once'});
  await sendOwnerOperation(currentB,expiring,send);
  await new Promise(r=>setTimeout(r,4500));
  await denied(()=>sendOwnerOperation(currentB,expiring,send),'actual offline-window expiry denies historical replay');
  await denied(()=>call(currentB,'chain.search',{chainId:cid,expectedRevision:'0',query:'searchneedle'}),'expired B cannot search');
  console.log('    ok - real signed grants, rendered UI, CLI, creator revocation, paired-root recovery, expiry and offline checks');
}
