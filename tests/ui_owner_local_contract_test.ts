import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { ownerParse, ownerCanonical, ownerDigest, ownerAuthenticateCommand, ownerLiveAdmit, ownerVerifyGenesis, ownerVerifyRegistry, ownerCreateBinding } from '../src/ui/api/ownerLocal.ts';
import type { OwnerKind, OwnerCommand, OwnerGenesis, OwnerRegistry, OwnerVerifiedKey, OwnerReadGrant } from '../src/ui/api/ownerLocal.ts';

const fixture = JSON.parse(readFileSync(new URL('../src/contracts/fixtures/owner-local-v1.json', import.meta.url), 'utf8'));
const doc = (kind: OwnerKind) => ownerParse(fixture.valid.find((v: any) => v.kind === kind).raw, kind);
const creator: OwnerVerifiedKey = {account_id:'acct_1', principal_id:'dev_1', key_id:'device_key', public_key:fixture.creator_public_key, kind:'device', enrolled:true, revoked:false};
const bridge: OwnerVerifiedKey = {...creator,principal_id:'brg_1',key_id:'bridge_key',public_key:fixture.bridge_public_key,kind:'bridge'};
const grant: OwnerReadGrant = {account_id:'acct_1', owner_bridge_id:'brg_1', chain_id:'chain_1',principal_id:'dev_1',key_id:'device_key',task_id:'task_1',method:'task.comment',revision:1n,expires_ms:1000000n,can_read:true,can_mutate:true,revoked:false};

test('shared strict wire and canonical digest fixtures', async () => {
  for (const v of fixture.valid) {
    const o = ownerParse(v.raw,v.kind);
    assert.equal(ownerCanonical(v.kind,o),v.canonical,v.kind);
    assert.equal(await ownerDigest(v.kind,o),v.digest,v.kind);
    const reordered = JSON.stringify(Object.fromEntries(Object.entries(o).reverse()));
    assert.equal(ownerCanonical(v.kind,ownerParse(reordered,v.kind)),v.canonical);
  }
  for (const v of fixture.invalid) assert.throws(()=>ownerParse(v.raw,v.kind), undefined, v.name);
  assert.throws(()=>ownerParse(' '.repeat(256*1024+1),'command'));
});

test('immutable genesis binds creating device and recipient Bridge; registry pins genesis', async () => {
  const g=doc('genesis') as OwnerGenesis;
  assert.equal(await ownerVerifyGenesis(g,'acct_1','brg_1',creator,bridge),'none');
  assert.equal(await ownerVerifyGenesis(g,'acct_other','brg_1',creator,bridge),'invalid_scope');
  assert.equal(await ownerVerifyGenesis(g,'acct_1','brg_other',creator,bridge),'owner_mismatch');
  assert.equal(await ownerVerifyGenesis(g,'acct_1','brg_1',{...creator,kind:'bridge'},bridge),'invalid_scope');
  assert.equal(await ownerVerifyGenesis({...g,creation_op:'op_other'},'acct_1','brg_1',creator,bridge),'bad_signature');
  const r=doc('registry') as OwnerRegistry;
  const digest=await ownerDigest('genesis',g);
  assert.equal(await ownerVerifyRegistry(r,'acct_1','brg_1',digest,bridge),'none');
  assert.equal(await ownerVerifyRegistry(r,'acct_1','brg_1','0'.repeat(64),bridge),'digest_mismatch');
  assert.equal(await ownerVerifyRegistry({...r,metadata_revision:'2'},'acct_1','brg_1',digest,bridge),'bad_signature');
});

test('current read authorization precedes historical replay; live admission checks expiry and CAS', async () => {
  const o=doc('command') as OwnerCommand, p=fixture.payload;
  const auth=(c=o,payload=p,k=creator,g=grant,now=1000n)=>ownerAuthenticateCommand(c,payload,k,g,now);
  assert.equal(await auth(),'none');
  assert.equal(ownerLiveAdmit(o,grant,1000n,9007199254740993n),'none');
  assert.equal(ownerLiveAdmit(o,{...grant,chain_id:'other'},1000n,9007199254740993n),'invalid_scope');
  assert.equal(ownerLiveAdmit(o,{...grant,owner_bridge_id:'other'},1000n,9007199254740993n),'owner_mismatch');
  assert.equal(await auth(o,p,creator,grant,10000n),'none');
  assert.equal(ownerLiveAdmit(o,grant,10000n,9007199254740994n),'expired');
  assert.equal(ownerLiveAdmit(o,grant,1000n,9007199254740994n),'stale_revision');
  assert.equal(await auth(o,'changed'),'digest_mismatch');
  assert.equal(await auth(o,p,creator,{...grant,revoked:true},10000n),'invalid_scope');
  for(const field of ['account_id','chain_id','principal_id','key_id','method','task_id']) {
    assert.equal(await auth({...o,[field]:field==='method'?'task.read':'other'}),'invalid_scope',field);
  }
  assert.equal(await auth({...o,immutable_owner_bridge:'brg_other'}),'owner_mismatch');
  for(const kind of ['content','bridge'] as const) assert.equal(await auth(o,p,{...creator,kind}),'invalid_scope');
  assert.equal(await auth(o,p,{...creator,enrolled:false}),'bad_signature');
  const readonly={...grant,can_mutate:false};
  assert.equal(await auth(o,p,creator,readonly),'none');
  assert.equal(ownerLiveAdmit(o,readonly,1000n,9007199254740993n),'invalid_scope');
  assert.equal(await auth({...o,operation_id:'tampered'},p,creator,grant,10000n),'bad_signature');
});

test('all V1 methods authenticate typed payloads and bind create to exact genesis', async () => {
  for (const v of fixture.commands) {
    const o = ownerParse(v.raw, 'command');
    const g = {...grant, task_id:'', method:o.method};
    assert.equal(await ownerAuthenticateCommand(o,v.payload,creator,g,1000n),'none',o.method);
    assert.equal(ownerLiveAdmit(o,g,1000n,0n),'none',o.method);
    if (['chain.read','task.read','receipt.read'].includes(o.method)) {
      assert.equal(ownerLiveAdmit(o,g,1000n,99n),'none');
      assert.equal(ownerLiveAdmit({...o,expected_revision:'98'},g,1000n,99n),'stale_revision');
    }
    if(o.method==='chain.create'){
      const genesis=doc('genesis') as OwnerGenesis;
      assert.equal(await ownerCreateBinding(o,genesis,v.payload),true);
      assert.equal(await ownerCreateBinding(o,{...genesis,creation_op:'other'},v.payload),false);
    }
    assert.equal(await ownerAuthenticateCommand(o,v.payload,creator,{...g,expires_ms:1000n},1000n),'invalid_scope');
  }
});
