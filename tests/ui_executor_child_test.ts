import { readFileSync } from 'node:fs';
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { executorParse, executorVerify, executorBootstrapMatches, executorChildRequestMatches } from '../src/ui/api/executor.ts';
import type { OwnerVerifiedKey } from '../src/ui/api/ownerLocal.ts';
const f = JSON.parse(readFileSync(new URL('../src/contracts/fixtures/executor-child-v1.json',import.meta.url),'utf8')) as {
  activation_exchange: string; content_bad: string[]; owner_key: OwnerVerifiedKey; executor_key: OwnerVerifiedKey; prepare: string; action: string; bootstrap: string; child: string;
  configuration: string; body: string; input: string; bootstrap_bad: {name:string;raw:string}[]; child_bad: {name:string;raw:string}[];
};
const b = executorParse(f.bootstrap,'bootstrap'), p = executorParse(f.prepare,'prepare'), a = executorParse(f.action,'action');
const r = executorParse(f.child,'child_request');
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
