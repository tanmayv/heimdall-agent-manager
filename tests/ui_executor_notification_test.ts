import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {executorParse,executorVerify} from '../src/ui/api/executor.ts';
import {executorNotificationMatches,executorNotificationResultMatches,executorNotificationFenceMatches,notificationMessageValid} from '../src/ui/api/executorNotification.ts';
const f=JSON.parse(readFileSync(new URL('../src/contracts/fixtures/executor-notification-v1.json',import.meta.url),'utf8'));
const n=executorParse(f.notification,'notification'),b=executorParse(f.bootstrap,'bootstrap');
test('notification signatures bind the exact original bootstrap and literal message',async()=>{
  assert.equal(await executorNotificationMatches(n,b,f.message,f.owner_key,1400),true);
  for(const row of f.notice_bad) assert.equal(await executorNotificationMatches(executorParse(row.raw,'notification'),b,f.message,f.owner_key,1400),false,row.name);
  assert.equal(await executorNotificationMatches(n,b,f.message+' ',f.owner_key,1400),false);
  for(const now of [1199,1800,2000]) assert.equal(await executorNotificationMatches(n,b,f.message,f.owner_key,now),false);
  assert.equal(await executorNotificationMatches(n,b,f.message,{...f.owner_key,revoked:true},1400),false);
  assert.equal(await executorVerify('bootstrap',n,f.owner_key),false);
  for(const invalid of ['\u0000','\u001b','\u007f','\u0080','\ud800']) assert.equal(notificationMessageValid(invalid),false);
});
test('notification results correlate signed input, scope and exact progress',async()=>{
  const r=executorParse(f.result,'notification_result');
  assert.equal(await executorNotificationResultMatches(r,n,f.message,f.executor_key,1400),true);
  for(const row of f.result_bad) assert.equal(await executorNotificationResultMatches(executorParse(row.raw,'notification_result'),n,f.message,f.executor_key,1400),false,row.name);
  assert.equal(await executorNotificationResultMatches(executorParse(f.unsupported,'notification_result'),n,f.message,f.executor_key,1400),true);
  assert.equal(await executorNotificationResultMatches(executorParse(f.malformed_delivered,'notification_result'),n,f.message,f.executor_key,1400),false);
  assert.equal(await executorNotificationResultMatches(r,n,f.message,f.owner_key,1400),false);
  assert.equal(await executorNotificationResultMatches(r,n,f.message,f.executor_key,1800),false);
});
test('checkpoint nonce signatures cannot authorize activation or a different hold effect',async()=>{
  const q=executorParse(f.challenge,'notification_fence_request'),r=executorParse(f.fence,'notification_fence_reply');
  assert.equal(await executorNotificationFenceMatches(r,q,n,f.owner_key,f.executor_key,1400),true);
  for(const row of f.fence_bad) assert.equal(await executorNotificationFenceMatches(executorParse(row.raw,'notification_fence_reply'),q,n,f.owner_key,f.executor_key,1400),false,row.name);
  assert.equal(await executorVerify('fence_request',q,f.executor_key),false);
  assert.equal(await executorVerify('fence_reply',r,f.owner_key),false);
  assert.equal(await executorNotificationFenceMatches(r,q,n,f.owner_key,f.executor_key,1700),false);
});
