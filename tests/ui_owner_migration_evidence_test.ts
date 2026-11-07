import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {ownerCanonical,ownerDigest,ownerParse,ownerVerifySignature} from '../src/ui/api/ownerLocal.ts';
import type {OwnerVerifiedKey} from '../src/ui/api/ownerLocal.ts';
import {ownerSchemas,type OwnerKind,type OwnerDocuments as D} from '../src/ui/api/ownerSchema.ts';
import {migrationMappingMatches,migrationObservationAdmit,migrationSetDigest,verifyMigrationAdoption,verifyMigrationExecutorDrain,verifyMigrationExecutorInventory} from '../src/ui/api/ownerMigrationEvidence.ts';

const fixture=JSON.parse(readFileSync(new URL('../src/contracts/fixtures/migration-evidence-v1.json',import.meta.url),'utf8'));
const doc=<K extends OwnerKind>(kind:K):D[K]=>ownerParse(fixture.valid.find((e:{kind:string})=>e.kind===kind).raw,kind);
const device:OwnerVerifiedKey={account_id:'account',principal_id:'device',key_id:'device_key',public_key:fixture.device_public_key,kind:'device',enrolled:true,revoked:false};
const executor:OwnerVerifiedKey={...device,principal_id:'executor',key_id:'executor_key',public_key:fixture.executor_public_key,kind:'bridge'};
const pin=()=>{const b=doc('migration_origin_binding');return {root:b.directory_root,head:b.directory_head,sequence:5n,epoch:2n};};

test('migration evidence shares native canonical bytes, set digests and full detached field coverage',async()=>{
  for(const entry of fixture.valid){
    const kind=entry.kind as OwnerKind,o=ownerParse(entry.raw,kind);
    assert.equal(ownerCanonical(kind,o),entry.canonical);
    assert.equal(await ownerDigest(kind,o),entry.digest);
    assert.throws(()=>ownerParse(entry.raw.replace('{','{"unexpected":"x",'),kind));
    const first=ownerSchemas[kind][0][0];
    assert.throws(()=>ownerParse(entry.raw.replace('{','{"'+first+'":"x",'),kind));
    if(!('signature' in o)) continue;
    const key=['migration_selection','migration_origin_binding'].includes(kind)?device:executor;
    assert.equal(await ownerVerifySignature(kind,o,'signature',key),true);
    for(const [name,type] of ownerSchemas[kind]){
      if(type==='signature') continue;
      assert.equal(await ownerVerifySignature(kind,{...o,[name]:'changed'},'signature',key),false,kind+'.'+name);
    }
  }
  for(const [kind,label] of [['migration_effect','effects'],['migration_mapping','mappings'],['migration_inventory_reference','executors']] as const){
    const row=doc(kind);
    assert.equal(await migrationSetDigest(kind,[row]),fixture.sets[label]);
    await assert.rejects(migrationSetDigest(kind,[row,row]),/duplicate/);
  }
});

test('adoption binds complete mapping, independent source, selected identity and current directory pin',async()=>{
  const s=doc('migration_selection'),source=doc('migration_source_inventory'),i=doc('migration_executor_inventory'),b=doc('migration_origin_binding');
  const effect=doc('migration_effect'),mapping=doc('migration_mapping');
  const check=(value:D['migration_origin_binding']=b,sourceValue=source,set=b.executor_inventories_digest,map=b.mapping_digest,count=1n,directory=pin(),key=device)=>verifyMigrationAdoption(value,s,sourceValue,set,map,count,directory,key);
  assert.equal(await verifyMigrationExecutorInventory(i,source,b.nonce,executor),'none');
  assert.equal(await check(),'none');
  assert.equal(await check(b,{...source,source_generation:'9007199254740992'}),'invalid_scope');
  assert.equal(await check(b,source,b.executor_inventories_digest,b.mapping_digest,0n),'digest_mismatch');
  assert.equal(await check(b,source,'f'.repeat(64)),'digest_mismatch');
  assert.equal(await check(b,source,b.executor_inventories_digest,b.mapping_digest,1n,{...pin(),sequence:4n}),'invalid_scope');
  assert.equal(await check(b,source,b.executor_inventories_digest,b.mapping_digest,1n,pin(),{...device,revoked:true}),'bad_signature');
  assert.equal(await check({...b,signature:s.signature}),'bad_signature');
  assert.throws(()=>ownerParse(JSON.stringify({...b,purpose:'launch'}),'migration_origin_binding'));
  assert.equal(await migrationMappingMatches(effect,mapping),true);
  for(const field of ['parent_digest','entry_digest','effect_id','command_id','task_id','instance_id','lease_id'] as const)
    assert.equal(await migrationMappingMatches(effect,{...mapping,[field]:'changed'}),false,field);
  const replaced=await migrationSetDigest('migration_mapping',[{...mapping,launch_key:'f'.repeat(64)}]);
  assert.equal(await check(b,source,b.executor_inventories_digest,replaced),'digest_mismatch');
});

test('current signed drain refuses every live or unknown dimension, stale incarnation and stale challenge',async()=>{
  const source=doc('migration_source_inventory'),i=doc('migration_executor_inventory'),b=doc('migration_origin_binding'),d=doc('migration_executor_drain');
  const check=(value=d,observation=i,barrier=d.barrier_receipt_digest,challenge=d.challenge,key=executor)=>verifyMigrationExecutorDrain(value,observation,b,barrier,challenge,key);
  assert.equal(await check(),'none');
  for(const field of ['unresolved_count','admitted_handler_count','live_child_count','merge_count','queued_action_count'] as const)
    assert.equal(await check({...d,[field]:'1'}),'invalid_scope',field);
  assert.equal(await verifyMigrationExecutorInventory({...i,unknown_count:'1'},source,i.challenge,executor),'invalid_scope');
  assert.equal(await verifyMigrationExecutorInventory({...i,complete:'0'},source,i.challenge,executor),'invalid_scope');
  assert.equal(await verifyMigrationExecutorInventory({...i,coverage_version:'2'},source,i.challenge,executor),'invalid_scope');
  assert.equal(await check({...d,executor_incarnation:'2'}),'invalid_scope');
  assert.equal(await check({...d,journal_sequence:'4'}),'invalid_scope');
  assert.equal(await check(d,i,d.barrier_receipt_digest,i.challenge),'digest_mismatch');
  assert.equal(await check(d,i,d.barrier_receipt_digest,d.challenge,{...executor,revoked:true}),'bad_signature');
  for(const kind of ['migration_executor_inventory','migration_executor_drain','migration_origin_binding'] as const){
    const value=doc(kind);
    assert.equal(migrationObservationAdmit(kind,value,1000n),'none');
    assert.equal(migrationObservationAdmit(kind,value,999n),'expired');
    assert.equal(migrationObservationAdmit(kind,value,2000n),'expired');
    ownerParse(JSON.stringify({...value,source_generation:'0'}),kind);
    assert.throws(()=>ownerParse(JSON.stringify({...value,source_generation:'-1'}),kind));
  }
});
