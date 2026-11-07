import {readFileSync,writeFileSync} from 'node:fs';
import {createHash} from 'node:crypto';
import {executorCanonical,executorSchemas,type ExecutorKind,type ExecutorDocument} from '../../src/ui/api/executor.ts';

const root=new URL('../../',import.meta.url);
const old=JSON.parse(readFileSync(new URL('src/contracts/fixtures/executor-child-v1.json',root),'utf8'));
const hex=(v:ArrayBuffer)=>Buffer.from(v).toString('hex');
const digest=(s:string)=>createHash('sha256').update(s).digest('hex');
const owner=await crypto.subtle.generateKey({name:'ECDSA',namedCurve:'P-256'},true,['sign','verify']);
const executor=await crypto.subtle.generateKey({name:'ECDSA',namedCurve:'P-256'},true,['sign','verify']);
const key=async(pair:CryptoKeyPair,principal:string)=>({account_id:'account',principal_id:principal,key_id:principal+'_key',
  public_key:hex(await crypto.subtle.exportKey('raw',pair.publicKey)),kind:'bridge',enrolled:true,revoked:false});
const ownerKey=await key(owner,'owner1'),executorKey=await key(executor,'executor');
const sign=async(kind:ExecutorKind,o:ExecutorDocument,pair=owner)=>({...o,signature:hex(await crypto.subtle.sign({name:'ECDSA',hash:'SHA-256'},
  pair.privateKey,new TextEncoder().encode(executorCanonical(kind,o))))});
const bootstrap=await sign('bootstrap',JSON.parse(old.bootstrap));
const message='[owner-local] task.hold on task task; inspect owner-local runtime.\n€ 日本語 😀\tcheckpoint';
const n:ExecutorDocument={};
for(const [name] of executorSchemas.notification) n[name]=bootstrap[name]??'';
Object.assign(n,{intent_id:'a'.repeat(64),owner_commit_seq:'17',message_digest:digest(message),issued_ms:'1200',request_expires_ms:'1800',signature:'0'.repeat(128)});
const notice=await sign('notification',n);
const r:ExecutorDocument={};
for(const [name] of executorSchemas.notification_result) r[name]=notice[name]??'';
Object.assign(r,{input_digest:digest(executorCanonical('notification',notice)),pid:'42',ticket:'opaque-ticket',input_profile:'provider-validated-profile',
  esc_written:'1',message_bytes_written:String(Buffer.byteLength(message)),enter_written:'1',status:'delivered',
  issued_ms:'1300',request_expires_ms:'1800',key_id:executorKey.key_id,signature:'0'.repeat(128)});
const result=await sign('notification_result',r,executor);
const q:ExecutorDocument={};
for(const [name] of executorSchemas.notification_fence_request) q[name]=notice[name]??'';
Object.assign(q,{notification:JSON.stringify(notice),claim_attempt:'1',action_digest:digest(executorCanonical('notification',notice)),challenge:'b'.repeat(64),
  issued_ms:'1250',request_expires_ms:'1700',key_id:executorKey.key_id,signature:'0'.repeat(128)});
const challenge=await sign('notification_fence_request',q,executor);
const f:ExecutorDocument={};
for(const [name] of executorSchemas.notification_fence_reply) f[name]=challenge[name]??notice[name]??'';
Object.assign(f,{request_digest:digest(executorCanonical('notification_fence_request',challenge)),prepare_digest:notice.prepare_digest,
  checked_ms:'1300',key_id:ownerKey.key_id,signature:'0'.repeat(128)});
const fence=await sign('notification_fence_reply',f);
const replacement=(v:string)=>/^[0-9a-f]{64}$/.test(v)?'e'.repeat(64):/^[0-9]+$/.test(v)?String(BigInt(v)+1n):v+'_other';
const noticeBad=[];
for(const name of ['account_id','owner_bridge_id','executor_bridge_id','chain_id','task_id','lease_id','reservation_id','instance_id','launch_epoch','run_count',
  'token_generation','configuration_revision','grant_generation','owner_incarnation','executor_incarnation','prepare_digest','launch_key','hard_ms','message_digest']) {
  noticeBad.push({name,raw:JSON.stringify(await sign('notification',{...notice,[name]:replacement(notice[name])}))});
}
const resultBad=[];
for(const name of ['account_id','owner_bridge_id','executor_bridge_id','chain_id','reservation_id','owner_incarnation','executor_incarnation','prepare_digest','input_digest','intent_id']) {
  resultBad.push({name,raw:JSON.stringify(await sign('notification_result',{...result,[name]:replacement(result[name])},executor))});
}
const fenceBad=[];
for(const name of ['request_digest','action_digest','prepare_digest','challenge','owner_commit_seq','owner_incarnation','executor_incarnation']) {
  fenceBad.push({name,raw:JSON.stringify(await sign('notification_fence_reply',{...fence,[name]:replacement(fence[name])}))});
}
const unsupported=await sign('notification_result',{...result,pid:'0',ticket:'',input_profile:'',esc_written:'0',message_bytes_written:'0',enter_written:'0',status:'unsupported_not_delivered'},executor);
const malformedDelivered=await sign('notification_result',{...result,message_bytes_written:'1'},executor);
writeFileSync(new URL('src/contracts/fixtures/executor-notification-v1.json',root),JSON.stringify({owner_key:ownerKey,executor_key:executorKey,
  bootstrap:JSON.stringify(bootstrap),notification:JSON.stringify(notice),message,result:JSON.stringify(result),challenge:JSON.stringify(challenge),
  fence:JSON.stringify(fence),notice_bad:noticeBad,result_bad:resultBad,fence_bad:fenceBad,unsupported:JSON.stringify(unsupported),
  malformed_delivered:JSON.stringify(malformedDelivered)},null,2)+'\n');
