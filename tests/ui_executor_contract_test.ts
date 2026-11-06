import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { executorParse, executorCanonical, executorVerify, executorReceiptMatches, executorFenceReplyMatches, type ExecutorKind } from '../src/ui/api/executor.ts';
const fixture = JSON.parse(readFileSync(new URL('../src/contracts/fixtures/executor-v1.json', import.meta.url), 'utf8')) as {
 valid: {kind: ExecutorKind; raw: string; canonical: string; digest: string}[];
 invalid: {kind: ExecutorKind; raw: string; name: string}[];
};
test('executor shared canonical wire vectors and fail-closed inputs', () => {
  for (const row of fixture.valid) {
    const value = executorParse(row.raw, row.kind);
    const canonical = executorCanonical(row.kind, value);
    assert.equal(canonical, row.canonical);
    assert.equal(createHash('sha256').update(canonical).digest('hex'), row.digest);
  }
  for (const row of fixture.invalid) assert.throws(() => executorParse(row.raw, row.kind), row.name);
});

test('executor bilateral fence exchange binds pending challenge, action and both enrolled keys', async () => {
  const owner = await crypto.subtle.generateKey({name:'ECDSA',namedCurve:'P-256'},true,['sign','verify']);
  const host = await crypto.subtle.generateKey({name:'ECDSA',namedCurve:'P-256'},true,['sign','verify']);
  const hex = (value: ArrayBuffer) => Buffer.from(value).toString('hex');
  const key = async (pair: CryptoKeyPair, principal: string) => ({account_id:'account',principal_id:principal,key_id:principal+'_key',public_key:hex(await crypto.subtle.exportKey('raw',pair.publicKey)),kind:'bridge' as const,enrolled:true,revoked:false});
  const ownerKey = await key(owner,'owner'), hostKey = await key(host,'executor');
  const sign = async (kind: ExecutorKind, value: Record<string,string>, pair: CryptoKeyPair) => ({...value,signature:hex(await crypto.subtle.sign({name:'ECDSA',hash:'SHA-256'},pair.privateKey,new TextEncoder().encode(executorCanonical(kind,value))))});
  const digest = (kind: ExecutorKind, value: Record<string,string>) => createHash('sha256').update(executorCanonical(kind,value)).digest('hex');
  const action = await sign('action', {...executorParse(fixture.valid.find(r => r.kind === 'action')!.raw,'action'),owner_bridge_id:'owner',key_id:ownerKey.key_id},owner);
  const request = await sign('fence_request', {...executorParse(fixture.valid.find(r => r.kind === 'fence_request')!.raw,'fence_request'),action_digest:digest('action',action),key_id:hostKey.key_id},host);
  const reply = await sign('fence_reply', {...executorParse(fixture.valid.find(r => r.kind === 'fence_reply')!.raw,'fence_reply'),request_digest:digest('fence_request',request),action_digest:digest('action',action),prepare_digest:action.prepare_digest,owner_commit_seq:action.owner_commit_seq,key_id:ownerKey.key_id},owner);
  assert.equal(await executorFenceReplyMatches(reply,request,action,ownerKey,hostKey,1200n),true);
  for (const name of ['account_id','executor_bridge_id','owner_bridge_id','chain_id','reservation_id','executor_incarnation','owner_incarnation','challenge','action_digest','request_digest','prepare_digest','owner_commit_seq']) {
    const changed = {...reply,[name]: /^[0-9a-f]{64}$/.test(reply[name]) ? (reply[name] === 'a'.repeat(64) ? 'b' : 'a').repeat(64) : '99'};
    const sealed = await sign('fence_reply',changed,owner);
    assert.equal(await executorFenceReplyMatches(sealed,request,action,ownerKey,hostKey,1200n),false,name);
  }
  for (const now of [999n,1099n,2000n,99999n]) assert.equal(await executorFenceReplyMatches(reply,request,action,ownerKey,hostKey,now),false);
  assert.equal(await executorFenceReplyMatches(reply,request,action,{...ownerKey,revoked:true},hostKey,1200n),false);
  assert.equal(await executorFenceReplyMatches(reply,request,action,ownerKey,{...hostKey,enrolled:false},1200n),false);
  assert.equal(await executorVerify('fence_request',request,ownerKey),false);
  assert.equal(await executorVerify('fence_reply',reply,hostKey),false);
});
test('executor schemas reject duplicate nested slots and noncanonical integers', () => {
  const policy = executorParse(fixture.valid[0].raw, 'policy');
  const slot = JSON.parse(policy.slots_json)[0];
  assert.throws(() => executorParse(JSON.stringify({...policy, slots_json: JSON.stringify([slot,slot])}), 'policy'));
  for (const capacity of ['0','01','+1','1.0','1e2','9223372036854775808']) {
    assert.throws(() => executorParse(JSON.stringify({...policy, device_capacity:capacity}), 'policy'));
  }
});

test('executor P256 receipt binds scope/digest/incarnation and historical admission', async () => {
  const pair = await crypto.subtle.generateKey({name:'ECDSA',namedCurve:'P-256'},true,['sign','verify']);
  const hex = (value: ArrayBuffer) => Buffer.from(value).toString('hex');
  const key = {account_id:'account',principal_id:'executor',key_id:'operator',public_key:hex(await crypto.subtle.exportKey('raw',pair.publicKey)),kind:'bridge' as const,enrolled:true,revoked:false};
  const request = executorParse(fixture.valid.find((row) => row.kind === 'prepare')!.raw,'prepare');
  const receipt = executorParse(fixture.valid.find((row) => row.kind === 'receipt')!.raw,'receipt');
  const sign = async (value: Record<string,string>) => ({...value,signature:hex(await crypto.subtle.sign({name:'ECDSA',hash:'SHA-256'},pair.privateKey,new TextEncoder().encode(executorCanonical('receipt',value))))});
  const sealed = await sign(receipt);
  assert.equal(await executorVerify('receipt',sealed,key),true);
  assert.equal(await executorReceiptMatches(sealed,request,'prepare',key,1000n),true);
  assert.equal(await executorReceiptMatches(sealed,{...request,chain_id:'other'},'prepare',key,1000n),false);
  assert.equal(await executorReceiptMatches(sealed,request,'prepare',{...key,revoked:true},1000n),false);
  assert.equal(await executorReceiptMatches(sealed,request,'prepare',key,3000n),false);
  assert.equal(await executorVerify('receipt',{...sealed,historical:'1'},key),false);
  const historical = await sign({...receipt,historical:'1'});
  assert.equal(await executorReceiptMatches(historical,request,'prepare',key,1000n),false);
  assert.equal(await executorReceiptMatches(historical,request,'prepare',key,5000n,false),true);
});
