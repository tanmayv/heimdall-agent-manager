import './helpers/vaultEndpointHarness.ts';
import {test} from 'node:test';
import assert from 'node:assert/strict';
import React, {act} from 'react';
import {createRoot} from 'react-dom/client';
import {JSDOM} from 'jsdom';
import {FakeHub,USER,newBrowser} from './helpers/vaultDirectoryFixture.ts';
import {installKeyringFromWrap,clearKeyringSession,getKeyringSession} from '../src/ui/utils/vaultKeyringSession.ts';
import {encryptVaultText,decryptVaultText} from '../src/ui/utils/vaultContent.ts';
import {executorParse,executorCanonical,type ExecutorDocument} from '../src/ui/api/executor.ts';
import {ownerPayloadDigest} from '../src/ui/api/ownerLocal.ts';
const {AgentFailureNotice} = await import('../src/ui/components/agents/AgentFailureNotice.tsx');

test('mounted local approval retains exact authorization through reload/lost reply and verifies fresh enrollment',async()=>{
  const dom = new JSDOM('<div id="root"></div>',{url:'https://hub.example.test/',pretendToBeVisual:true});
  const saved = new Map<string,PropertyDescriptor|undefined>();
  for (const [key,value] of Object.entries({window:dom.window,document:dom.window.document,sessionStorage:dom.window.sessionStorage,
    HTMLElement:dom.window.HTMLElement,Node:dom.window.Node,IS_REACT_ACT_ENVIRONMENT:true})) {
    saved.set(key,Object.getOwnPropertyDescriptor(globalThis,key));
    Object.defineProperty(globalThis,key,{value,writable:true,configurable:true});
  }
  const previousFetch = globalThis.fetch;
  const identity = await newBrowser(), hub = new FakeHub();
  await hub.genesis(identity);const host = await hub.addBridge(identity,'executor');
  await installKeyringFromWrap(identity,hub.wraps.get(identity.deviceId),await hub.chain());
  const config = JSON.stringify({protocol_version:'1',account_id:USER,executor_bridge_id:'executor',instance_id:'instance',launch_epoch:'epoch',
    run_count:'1',token_generation:'a'.repeat(64),configuration_revision:'1',executor_incarnation:'1',policy_revision:'1',slot_id:'slot',
    provider:'claude',model:'model',provider_profile:'claude',directory_id:'workspace',directory_revision:'1',directory_key:'b'.repeat(64),purpose:'manual',spawn_digest:'c'.repeat(64)});
  const digest = await ownerPayloadDigest(config), draftId = 'd'.repeat(64);
  const error = {class:'recoverable',cause:'agent_launch_failed',message:JSON.stringify({code:'launch_authorization_required',executor_bridge_id:'executor',draft_id:draftId,draft_revision:'1',configuration_digest:digest})};
  let state = 'pending', child = '', loseAuthorize = true, revokeReply = false, directoryReads = 0;
  const commands:ExecutorDocument[] = [];
  globalThis.fetch = (async(input:any,init:any={})=>{
    const path = new URL(String(input),'https://hub.example.test').pathname;
    if (path === '/api/v1/vault/directory') {directoryReads++;return Response.json({data:hub.dir()});}
    assert.equal(path,'/api/v1/executor/local-launch');
    const relay = JSON.parse(init.body), session = getKeyringSession()!;
    const request = executorParse(await decryptVaultText(relay.envelope,session.keyring),'local_draft');commands.push(request);
    if (request.method === 'prepare') state = 'prepared';
    if (request.method === 'authorize') {state = 'authorized';child = 'active';if (loseAuthorize) {loseAuthorize = false;throw new Error('lost reply');}}
    if (request.method === 'cancel') {state = 'cancelled';child = 'released';}
    const body = JSON.stringify({code:'ok',body:JSON.stringify({draft_id:draftId,draft_revision:'1',configuration:config,configuration_digest:digest,state,launch_state:child})});
    const receipt:ExecutorDocument = {protocol_version:'1',account_id:USER,executor_bridge_id:'executor',principal_id:identity.deviceId,
      operation_id:request.operation_id,request_id:relay.request_id,request_digest:await ownerPayloadDigest(executorCanonical('local_draft',request)),
      result_digest:await ownerPayloadDigest(body),issued_ms:String(Date.now()),request_expires_ms:relay.expires_ms,key_id:host.deviceId,signature:'0'.repeat(128)};
    receipt.signature = Buffer.from(await crypto.subtle.sign({name:'ECDSA',hash:'SHA-256'},host.identity.privateKey,new TextEncoder().encode(executorCanonical('local_result',receipt)))).toString('hex');
    const envelope = await encryptVaultText(JSON.stringify({receipt:JSON.stringify(receipt),body}),session.keyring);
    if (revokeReply) await hub.revoke(identity,host.deviceId);
    return Response.json({data:{request_id:relay.request_id,envelope,code:'ok'}});
  }) as typeof fetch;
  let root = createRoot(dom.window.document.getElementById('root')!);
  const button = (id:string) => dom.window.document.querySelector(`[data-debug-id="local-launch-${id}"]`) as HTMLButtonElement;
  const flush = async() => {for(let i=0;i<30;i++) await act(async()=>{await new Promise(r=>setTimeout(r,5));});};
  const render = async(lastError:any=error,runtimeStatus='failed') => {await act(async()=>root.render(React.createElement(AgentFailureNotice,{instanceId:'instance',lastError,runtimeStatus})));await flush();};
  const click = async(id:string) => {assert.equal(button(id).disabled,false,id);await act(async()=>button(id).click());await flush();};
  try {
    await render();assert.ok(button('authorize').disabled);
    await click('prepare');assert.match(dom.window.document.body.textContent||'',/workspace/);
    await click('authorize');assert.match(dom.window.document.body.textContent||'',/lost reply/);
    const original = commands.at(-1)!;
    assert.equal(original.method,'authorize');
    const ciphertext = [...Array(sessionStorage.length)].map((_,i)=>sessionStorage.getItem(sessionStorage.key(i)!)!).join('');
    assert.equal(ciphertext.includes(original.signature),false);
    // Reopen after a lost reply. Only exact retry is enabled; new operations
    // cannot silently replace the outstanding signed authorization.
    await act(async()=>root.unmount());root = createRoot(dom.window.document.getElementById('root')!);
    await render();assert.ok(button('prepare').disabled);
    await click('retry');assert.deepEqual(commands.at(-1),original);
    assert.match(dom.window.document.body.textContent||'',/authorized active/);
    await render(null,'running');assert.ok(button('inspect'),'controls survive cleared instance error');
    await click('inspect');assert.match(dom.window.document.body.textContent||'',/authorized active/);
    await click('cancel');assert.match(dom.window.document.body.textContent||'',/cancelled released/);
    assert.ok(directoryReads >= commands.length*2,'enrollment checked before and after relay I/O');
    revokeReply = true;
    await click('inspect');
    assert.match(dom.window.document.body.textContent||'',/Current paired device and execution Bridge required|epoch|session changed/i);
    assert.ok(button('retry'),'unaccepted reply retains exact operation');
  } finally {
    await act(async()=>{root.unmount();clearKeyringSession();});globalThis.fetch = previousFetch;
    for (const [key,descriptor] of saved) {if (descriptor) Object.defineProperty(globalThis,key,descriptor);else delete (globalThis as any)[key];}
    dom.window.close();
  }
});
