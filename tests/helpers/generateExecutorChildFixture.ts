import { readFileSync, writeFileSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { executorCanonical, executorSchemas, executorParse, type ExecutorKind } from '../../src/ui/api/executor.ts';

const root = new URL('../../', import.meta.url);
const fixture = JSON.parse(readFileSync(new URL('src/contracts/fixtures/executor-v1.json',root),'utf8'));
const doc = (kind: ExecutorKind) => executorParse(fixture.valid.find((r: {kind: string}) => r.kind === kind).raw,kind);
const hex = (v: ArrayBuffer) => Buffer.from(v).toString('hex');
const digest = (v: string) => createHash('sha256').update(v).digest('hex');
const owner = await crypto.subtle.generateKey({name:'ECDSA',namedCurve:'P-256'},true,['sign','verify']);
const executor = await crypto.subtle.generateKey({name:'ECDSA',namedCurve:'P-256'},true,['sign','verify']);
const key = async (pair: CryptoKeyPair, principal: string) => ({account_id:'account',principal_id:principal,key_id:principal+'_key',
  public_key:hex(await crypto.subtle.exportKey('raw',pair.publicKey)),kind:'bridge',enrolled:true,revoked:false});
const ownerKey = await key(owner,'owner1'), executorKey = await key(executor,'executor');
const sign = async (kind: ExecutorKind, value: Record<string,string>, pair = owner) => {
  const o = {...value};
  o.signature = hex(await crypto.subtle.sign({name:'ECDSA',hash:'SHA-256'},pair.privateKey,new TextEncoder().encode(executorCanonical(kind,o))));
  return o;
};
const p = await sign('prepare',{...doc('prepare'),key_id:ownerKey.key_id});
const a = await sign('action',{...doc('action'),prepare_digest:digest(executorCanonical('prepare',p)),key_id:ownerKey.key_id});
const config = {protocol_version:'1',account_id:p.account_id,owner_bridge_id:p.owner_bridge_id,executor_bridge_id:p.executor_bridge_id,
  executor_key_id:executorKey.key_id,chain_id:p.chain_id,task_id:p.task_id,instance_id:p.instance_id,agent_id:'agent',
  launch_epoch:p.launch_epoch,run_count:p.run_count,token_generation:p.token_generation,configuration_revision:p.configuration_revision,
  executor_incarnation:p.executor_incarnation,policy_revision:p.policy_revision,slot_id:p.slot_id,provider_profile:p.provider_profile,
  provider:'codex',model:'模型🚀',directory_id:'directory',directory_key:p.directory_key,directory_path:'/repo'};
const configuration = JSON.stringify(config);
const body = JSON.stringify({agents_md:'# Worker\n模型🚀',memory_md:'',task_md:'# Assigned task'});
const b: Record<string,string> = {};
for (const [name] of executorSchemas.bootstrap) b[name] = p[name] ?? a[name] ?? '';
Object.assign(b,{prepare_digest:digest(executorCanonical('prepare',p)),action_digest:digest(executorCanonical('action',a)),
  configuration_digest:digest(configuration),body_digest:digest(body),launch_key:'c'.repeat(64),issued_ms:'1100',request_expires_ms:'1900',
  key_id:ownerKey.key_id,signature:'0'.repeat(128)});
const bootstrap = await sign('bootstrap',b);
const input = JSON.stringify({protocol_version:'1',chain_id:p.chain_id,task_id:p.task_id,lease_id:p.lease_id,
  configuration_revision:p.configuration_revision,expected_revision:'1',operation_id:'heartbeat',method:'lease.heartbeat',
  request_expires_ms:'1900',capability:'capability'});
const r: Record<string,string> = {};
for (const [name] of executorSchemas.child_request) r[name] = bootstrap[name] ?? '';
Object.assign(r,{bootstrap_digest:digest(executorCanonical('bootstrap',bootstrap)),input_digest:digest(input),issued_ms:'1200',
  request_expires_ms:'1800',key_id:executorKey.key_id,signature:'0'.repeat(128)});
const child = await sign('child_request',r,executor);
const replacement = (v: string) => /^[0-9a-f]{64}$/.test(v) ? (v === 'd'.repeat(64) ? 'e' : 'd').repeat(64) : /^[0-9]+$/.test(v) ? String(BigInt(v)+1n) : v+'_other';
const bootstrap_bad = [], child_bad = [];
for (const [name] of executorSchemas.bootstrap) {
  if (['signature','key_id','issued_ms','request_expires_ms','protocol_version'].includes(name)) continue;
  const changed = await sign('bootstrap',{...bootstrap,[name]:replacement(bootstrap[name])});
  bootstrap_bad.push({name,raw:JSON.stringify(changed)});
}
for (const [name] of executorSchemas.child_request) {
  if (['signature','key_id','issued_ms','request_expires_ms','protocol_version'].includes(name)) continue;
  const changed = await sign('child_request',{...child,[name]:replacement(child[name])},executor);
  child_bad.push({name,raw:JSON.stringify(changed)});
}
const result = {owner_key:ownerKey,executor_key:executorKey,prepare:JSON.stringify(p),action:JSON.stringify(a),configuration,body,input,
  bootstrap:JSON.stringify(bootstrap),child:JSON.stringify(child),bootstrap_bad,child_bad};
writeFileSync(new URL('src/contracts/fixtures/executor-child-v1.json',root),JSON.stringify(result,null,2)+'\n');
