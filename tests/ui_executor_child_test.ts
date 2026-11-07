import { readFileSync } from 'node:fs';
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { executorParse, executorCanonical, executorVerify, executorBootstrapMatches, executorChildRequestMatches, executorChildResultMatches } from '../src/ui/api/executor.ts';
import type { OwnerVerifiedKey } from '../src/ui/api/ownerLocal.ts';
const f = JSON.parse(readFileSync(new URL('../src/contracts/fixtures/executor-child-v1.json',import.meta.url),'utf8')) as {
  activation_exchange: string; content_bad: string[]; owner_key: OwnerVerifiedKey; executor_key: OwnerVerifiedKey; prepare: string; action: string; bootstrap: string; child: string;
  configuration: string; body: string; input: string; bootstrap_bad: {name:string;raw:string}[]; child_bad: {name:string;raw:string}[];
  child_result: string; result_body: string; result_bad: {name:string;raw:string}[]; expired_input: string; expired_child: string;
};
const b = executorParse(f.bootstrap,'bootstrap'), p = executorParse(f.prepare,'prepare'), a = executorParse(f.action,'action');
const r = executorParse(f.child,'child_request');
test('owner child result binds the exact attestation and result bytes, including Unicode',async () => {
  const result = executorParse(f.child_result,'child_result');
  assert.equal(await executorChildResultMatches(result,r,f.result_body,f.owner_key,1400n),true);
  for (const bad of f.result_bad) assert.equal(await executorChildResultMatches(executorParse(bad.raw,'child_result'),r,f.result_body,f.owner_key,1400n),false,bad.name);
  assert.equal(await executorChildResultMatches(result,r,f.result_body+' ',f.owner_key,1400n),false);
  assert.equal(await executorChildResultMatches(result,r,f.result_body,f.executor_key,1400n),false);
  assert.equal(await executorChildResultMatches(result,r,f.result_body,{...f.owner_key,revoked:true},1400n),false);
  for (const now of [1299n,1800n]) assert.equal(await executorChildResultMatches(result,r,f.result_body,f.owner_key,now),false);
  assert.equal(await executorChildRequestMatches(executorParse(f.expired_child,'child_request'),b,f.expired_input,f.executor_key,f.owner_key,1300n),true,'original expired inputs must reach owner receipt replay');
});
test('owner bootstrap rejects correctly signed scope, launch, configuration, body and deadline substitution',async () => {
  const check = (value = b, config = f.configuration, body = f.body, now = 1300n) =>
    executorBootstrapMatches(value,p,a,config,body,b.launch_key,f.owner_key,now);
  assert.equal(await check(),true);
  for (const row of f.bootstrap_bad) assert.equal(await check(executorParse(row.raw,'bootstrap')),false,row.name);
  assert.equal(await check(b,f.configuration+' '),false);
  assert.equal(await check(b,f.configuration,f.body+' '),false);
  for (const now of [1099n,1900n,2000n]) assert.equal(await check(b,f.configuration,f.body,now),false);
  assert.equal(await executorVerify('bootstrap',b,f.executor_key),false);
  assert.equal(await executorBootstrapMatches(b,p,a,f.configuration,f.body,b.launch_key,{...f.owner_key,revoked:true},1300n),false);
});
test('executor child request rejects correctly signed exact-child and input substitution',async () => {
  const check = (value = r, input = f.input, now = 1300n) => executorChildRequestMatches(value,b,input,f.executor_key,f.owner_key,now);
  assert.equal(await check(),true);
  for (const row of f.child_bad) assert.equal(await check(executorParse(row.raw,'child_request')),false,row.name);
  for (const input of [f.input+' ','{}']) assert.equal(await check(r,input),false);
  for (const now of [1199n,1800n,2000n]) assert.equal(await check(r,f.input,now),false);
  assert.equal(await executorVerify('child_request',r,f.owner_key),false);
  assert.equal(await executorChildRequestMatches(r,b,f.input,{...f.executor_key,revoked:true},f.owner_key,1300n),false);
});
test('child record parser rejects added authority, duplicate keys and oversized or noncanonical deadlines', () => {
  for (const kind of ['bootstrap','child_request'] as const) {
    const raw = kind === 'bootstrap' ? f.bootstrap : f.child;
    const parsed = executorParse(raw,kind);
    assert.throws(() => executorParse(JSON.stringify({...parsed,task_state:'done'}),kind));
    assert.throws(() => executorParse(raw.replace('{','{"account_id":"other",'),kind));
    for (const request_expires_ms of ['01','0','999999','1100']) {
      assert.throws(() => executorParse(JSON.stringify({...parsed,request_expires_ms}),kind));
    }
  }
});

test('bootstrap content permits Unicode and rejects executable and skill path injection', () => {
  assert.doesNotThrow(() => executorParse(f.body,'bootstrap_content'));
  assert.doesNotThrow(() => executorParse(f.activation_exchange,'activation_bootstrap_exchange'));
  for (const raw of f.content_bad) assert.throws(() => executorParse(raw,'bootstrap_content'));
});


test('confirmed renewal supplements the immutable bootstrap deadline with exact signed scope',async () => {
  const owner = await crypto.subtle.generateKey({name:'ECDSA',namedCurve:'P-256'},true,['sign','verify']);
  const executor = await crypto.subtle.generateKey({name:'ECDSA',namedCurve:'P-256'},true,['sign','verify']);
  const hex = (value: ArrayBuffer) => Buffer.from(value).toString('hex');
  const ownerKey = {...f.owner_key,public_key:hex(await crypto.subtle.exportKey('raw',owner.publicKey))};
  const executorKey = {...f.executor_key,public_key:hex(await crypto.subtle.exportKey('raw',executor.publicKey))};
  const sign = async (kind: 'action'|'bootstrap'|'child_request', value: Record<string,string>, pair: CryptoKeyPair) =>
    ({...value,signature:hex(await crypto.subtle.sign({name:'ECDSA',hash:'SHA-256'},pair.privateKey,new TextEncoder().encode(executorCanonical(kind,value))))});
  const bootstrap = await sign('bootstrap',b,owner);
  const renewal = await sign('action',{...a,method:'heartbeat',operation_id:'renewal',deadline_version:'2',expires_ms:'8000',request_expires_ms:'6000'},owner);
  const child = await sign('child_request',{...r,deadline_version:'2',expires_ms:'8000',issued_ms:'5100',request_expires_ms:'5500'},executor);
  assert.equal(await executorChildRequestMatches(child,bootstrap,f.input,executorKey,ownerKey,5200n,renewal),true);
  assert.equal(await executorChildRequestMatches(child,bootstrap,f.input,executorKey,ownerKey,5200n),false);
  for (const name of ['reservation_id','grant_generation','executor_incarnation','owner_incarnation','prepare_digest','hard_ms']) {
    const changed = await sign('action',{...renewal,[name]:name === 'prepare_digest' ? 'b'.repeat(64) : name === 'reservation_id' ? 'other' : '9999'},owner);
    assert.equal(await executorChildRequestMatches(child,bootstrap,f.input,executorKey,ownerKey,5200n,changed),false,name);
  }
  const unsigned = {...renewal,expires_ms:'4000'};
  assert.equal(await executorChildRequestMatches(child,bootstrap,f.input,executorKey,ownerKey,5200n,unsigned),false);
  assert.equal(await executorChildRequestMatches(child,bootstrap,f.input,executorKey,{...ownerKey,revoked:true},5200n,renewal),false);
});
