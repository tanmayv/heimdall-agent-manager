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

test('native placement facets retain pre-grant zero without allowing zero work attempts', () => {
  const before = JSON.parse(readFileSync(new URL('../src/contracts/fixtures/owner-native-placement-pregrant.json', import.meta.url), 'utf8'));
  assert.deepEqual(JSON.parse(before.attempts), []);
  for (const raw of JSON.parse(before.facets)) {
    const facet = ownerParse(raw, 'native_history_facet');
    assert.equal(facet.kind, 'placement'); assert.equal(facet.attempt_no, '0'); assert.equal(facet.writer, 'hub');
    assert.throws(() => ownerParse(JSON.stringify({ ...facet, kind:'handoff' }), 'native_history_facet'));
    assert.throws(() => ownerParse(JSON.stringify({ ...facet, attempt_no:'-1' }), 'native_history_facet'));
    assert.throws(() => ownerParse(JSON.stringify({ ...facet, v:'0' }), 'native_history_facet'));
    ownerParse(JSON.stringify({ ...facet, attempt_no:'1' }), 'native_history_facet');
  }
  const later = JSON.parse(readFileSync(new URL('../src/contracts/fixtures/owner-native-placement-later.json', import.meta.url), 'utf8'));
  const attempt = JSON.parse(JSON.parse(later.attempts)[0]);
  assert.throws(() => ownerParse(JSON.stringify({ ...attempt, attempt_no:'0' }), 'native_history_attempt'));
});

test('native history imports require mutation and snapshot reads bind typed bounded payloads', () => {
  for (const method of ['native.history.read', 'native.history.fetch', 'native.history.import']) {
    const c = { ...doc('command'), method, expected_revision:'0' } as OwnerCommand;
    ownerParse(JSON.stringify(c), 'command');
    const readonly = { ...grant, method, can_mutate:false };
    assert.equal(ownerLiveAdmit(c, readonly, 1000n, 1n), method === 'native.history.import' ? 'invalid_scope' : 'none');
    assert.throws(() => ownerParse(JSON.stringify({ ...c, task_id:'' }), 'command'));
  }
  const page = { source_revision:'original_7', kind:'facet', cursor:'', limit:'100' };
  ownerParse(JSON.stringify(page), 'native_history_read');
  ownerParse(JSON.stringify({ ...page, cursor:'hash:["3","output","2"]' }), 'native_history_read');
  for (const patch of [{ kind:'summary' }, { limit:'101' }, { limit:'0' }, { cursor:'x'.repeat(513) }, { task_id:'forged' }])
    assert.throws(() => ownerParse(JSON.stringify({ ...page, ...patch }), 'native_history_read'));
  const read = { source_revision:'original_7', kind:'event', key:'9007199254740993', offset:'0' };
  assert.equal(ownerParse(JSON.stringify(read), 'native_history_fetch').key, '9007199254740993');
  assert.throws(() => ownerParse(JSON.stringify({ ...read, offset:'-1' }), 'native_history_fetch'));
  const history = JSON.parse(readFileSync(new URL('../src/contracts/fixtures/owner-native-history.json', import.meta.url), 'utf8'));
  const event = JSON.parse(JSON.parse(history.events).at(-1));
  assert.equal(ownerParse(JSON.stringify(event), 'native_history_event').actor_kind, 'coordinator');
  const facet = JSON.parse(JSON.parse(history.facets)[0]);
  assert.throws(() => ownerParse(JSON.stringify({ ...facet, writer:'coordinator' }), 'native_history_facet'));
});

test('native attempt records keep decimal identities, strict times and task read authority', async () => {
  const { ownerPayloadKind } = await import('../src/ui/api/ownerLocal.ts');
  assert.equal(ownerPayloadKind('attempt.read'), 'attempt_read_payload');
  const c = { ...doc('command'), method:'attempt.read', expected_revision:'0' } as OwnerCommand;
  ownerParse(JSON.stringify(c), 'command');
  const readonly = { ...grant, method:'attempt.read', can_mutate:false };
  assert.equal(ownerLiveAdmit(c, readonly, 1000n, 99n), 'none');
  assert.equal(ownerLiveAdmit(c, { ...readonly, revoked:true }, 1000n, 99n), 'invalid_scope');
  assert.throws(() => ownerParse(JSON.stringify({ ...c, task_id:'' }), 'command'));
  const record = { account_id:'account', chain_id:'chain', task_id:'task', attempt_no:'9007199254740993', started_ms:'1000', ended_ms:'1100', holder_instance_id:'instance', outcome:'submitted', counts_toward_budget:'1', work_lease_id:'lease', completeness:'full' };
  assert.equal(ownerParse(JSON.stringify(record), 'native_attempt').attempt_no, '9007199254740993');
  assert.equal(ownerParse(JSON.stringify({ ...record, outcome:'expired:chain_closed' }), 'native_attempt').outcome, 'expired:chain_closed');
  for (const patch of [{ ended_ms:'999' }, { ended_ms:'' }, { ended_ms:'unknown' }, { outcome:'assumed' }, { counts_toward_budget:'true' }])
    assert.throws(() => ownerParse(JSON.stringify({ ...record, ...patch }), 'native_attempt'));
  for (const payload of [{ attempt:'0' }, { attempt:'-1' }, { attempt:'1', lease_id:'forged' }])
    assert.throws(() => ownerParse(JSON.stringify(payload), 'attempt_read_payload'));
});

test('native attempt projection has explicit completeness and strict release vocabulary', () => {
  const state = { attempt_no: '4', counting_attempts: '2', last_release: 'handoff', work_lease_id: 'lease_2', completeness: 'full' };
  assert.equal(ownerParse(JSON.stringify(state), 'attempt_state').attempt_no, '4');
  assert.equal(ownerParse(JSON.stringify({ ...state, completeness: 'incomplete' }), 'attempt_state').completeness, 'incomplete');
  for (const patch of [{ completeness: 'assumed' }, { last_release: 'unknown' }, { attempt_no: '-1' }, { counting_attempts: '2.5' }, { budget_allowed: '1' }]) {
    assert.throws(() => ownerParse(JSON.stringify({ ...state, ...patch }), 'attempt_state'));
  }
});

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

test('runtime proof signatures bind exact child and scoped resource', async () => {
  const {ownerVerifySignature}=await import('../src/ui/api/ownerLocal.ts');
  for (const kind of ['capability','lease_command','lifecycle_command'] as const) {
    const o=doc(kind) as any;
    assert.equal(await ownerVerifySignature(kind,o,'signature',bridge),true);
    for (const name of ['account_id','chain_id','task_id','lease_id','instance_id','launch_epoch','token_generation','configuration_revision']) {
      const value=name==='token_generation'?'b'.repeat(64):name==='configuration_revision'?'4':'other';
      assert.equal(await ownerVerifySignature(kind,{...o,[name]:value},'signature',bridge),false,name);
    }
  }
});


test('event history uses strict chain-scoped read contracts', async () => {
  const { ownerPayloadKind } = await import('../src/ui/api/ownerLocal.ts');
  assert.equal(ownerPayloadKind('history.read'), 'read_payload');
  assert.equal(ownerPayloadKind('history.fetch'), 'history_fetch_payload');
  const c = doc('command') as OwnerCommand;
  for (const method of ['history.read', 'history.fetch']) {
    const command = {...c, method, task_id:'', expected_revision:'0'};
    ownerParse(JSON.stringify(command), 'command');
    const readonly = {...grant, method, task_id:'', can_mutate:false};
    assert.equal(ownerLiveAdmit(command, readonly, 1000n, 99n), 'none');
    assert.equal(ownerLiveAdmit(command, {...readonly,revoked:true}, 1000n, 99n), 'invalid_scope');
    assert.throws(()=>ownerParse(JSON.stringify({...command,task_id:'task_1'}),'command'));
  }
  assert.equal(ownerParse('{"seq":"9007199254740993","offset":"0"}','history_fetch_payload').seq,'9007199254740993');
  for(const raw of ['{"seq":"0","offset":"0"}','{"seq":"1","offset":"-1"}','{"seq":"1","offset":"0","task_id":"other"}'])
    assert.throws(()=>ownerParse(raw,'history_fetch_payload'));
});

test('durable fleet policy is chain scoped and signed mutation differs from read authority', async () => {
  const { ownerPayloadKind } = await import('../src/ui/api/ownerLocal.ts');
  for (const method of ['fleet.policy.set', 'fleet.policy.read']) {
    const command = { ...doc('command'), method, task_id:'', expected_revision:'0' };
    ownerParse(JSON.stringify(command), 'command');
    assert.throws(() => ownerParse(JSON.stringify({...command,task_id:'task_1'}), 'command'));
    const readonly = {...grant,method,task_id:'',can_mutate:false};
    assert.equal(ownerLiveAdmit(command, readonly, 1000n, 1n), method === 'fleet.policy.set' ? 'invalid_scope' : 'none');
  }
  assert.equal(ownerPayloadKind('fleet.policy.set'), 'fleet_policy_payload');
  assert.equal(ownerPayloadKind('fleet.policy.read'), 'read_payload');
});

test('native metadata snapshots have strict chain scope and distinct read and mutation authority', () => {
  for (const method of ['native.metadata.import', 'native.metadata.read']) {
    const c = { ...doc('command'), method, task_id:'', expected_revision:'0' } as OwnerCommand;
    ownerParse(JSON.stringify(c), 'command');
    const readonly = { ...grant, task_id:'', method, can_mutate:false };
    assert.equal(ownerLiveAdmit(c, readonly, 1000n, 1n), method === 'native.metadata.import' ? 'invalid_scope' : 'none');
    assert.throws(() => ownerParse(JSON.stringify({ ...c, task_id:'task_1' }), 'command'));
  }
  const page = { source_revision:'pinned_7', kind:'member', cursor:'', limit:'100' };
  ownerParse(JSON.stringify(page), 'native_metadata_read');
  for (const kind of ['directory', 'chain', 'task', 'comment', 'summary'])
    ownerParse(JSON.stringify({ ...page, kind }), 'native_metadata_read');
  for (const patch of [{ kind:'fleet' }, { limit:'101' }, { limit:'0' }, { task_id:'forged' }])
    assert.throws(() => ownerParse(JSON.stringify({ ...page, ...patch }), 'native_metadata_read'));
});
