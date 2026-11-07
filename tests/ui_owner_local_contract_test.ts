import { ownerWorkDocumentValid } from '../src/ui/api/ownerWork.ts';
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { ownerPinnedRef, ownerParse, ownerCanonical, ownerDigest, ownerAuthenticateCommand, ownerLiveAdmit, ownerVerifyGenesis, ownerVerifyRegistry, ownerCreateBinding } from '../src/ui/api/ownerLocal.ts';
import type { OwnerKind, OwnerCommand, OwnerGenesis, OwnerRegistry, OwnerVerifiedKey, OwnerReadGrant } from '../src/ui/api/ownerLocal.ts';

const fixture = JSON.parse(readFileSync(new URL('../src/contracts/fixtures/owner-local-v1.json', import.meta.url), 'utf8'));
const doc = (kind: OwnerKind) => ownerParse(fixture.valid.find((v: any) => v.kind === kind).raw, kind);
const creator: OwnerVerifiedKey = {account_id:'acct_1', principal_id:'dev_1', key_id:'device_key', public_key:fixture.creator_public_key, kind:'device', enrolled:true, revoked:false};
const bridge: OwnerVerifiedKey = {...creator,principal_id:'brg_1',key_id:'bridge_key',public_key:fixture.bridge_public_key,kind:'bridge'};
const grant: OwnerReadGrant = {account_id:'acct_1', owner_bridge_id:'brg_1', chain_id:'chain_1',principal_id:'dev_1',key_id:'device_key',task_id:'task_1',method:'task.comment',revision:1n,expires_ms:1000000n,can_read:true,can_mutate:true,revoked:false};

test('priority requires task scope, strict native enum, mutation grant and current CAS', () => {
  const c = {...doc('command'),method:'task.priority',expected_revision:'1'} as OwnerCommand;
  ownerParse(JSON.stringify(c),'command');
  assert.throws(()=>ownerParse(JSON.stringify({...c,task_id:''}),'command'));
  for(const priority of ['p0','p1','p2']) ownerParse(JSON.stringify({priority}),'priority_payload');
  for(const priority of ['P0','p3','',0]) assert.throws(()=>ownerParse(JSON.stringify({priority}),'priority_payload'));
  assert.throws(()=>ownerParse('{"priority":"p0","state":"ready"}','priority_payload'));
  assert.equal(ownerLiveAdmit(c,{...grant,method:c.method,can_mutate:false},1000n,1n),'invalid_scope');
  assert.equal(ownerLiveAdmit(c,{...grant,method:c.method},1000n,2n),'stale_revision');
  assert.equal(ownerLiveAdmit(c,{...grant,method:c.method},1000n,1n),'none');
});

test('fleet activation accepts an explicit pinned source without broadening ordinary payloads', () => {
  const registry=doc('registry');
  const body_cipher=registry.chain_title_cipher || registry.task_title_cipher;
  const payload={body_cipher,source_revision:'source_7'};
  ownerParse(JSON.stringify(payload),'fleet_policy_source_payload');
  ownerParse(JSON.stringify(payload),'fleet_policy_payload');
  for(const source_revision of ['', 'bad/source']) assert.throws(()=>ownerParse(JSON.stringify({...payload,source_revision}),'fleet_policy_payload'));
  assert.throws(()=>ownerParse(JSON.stringify({...payload,activate:'1'}),'fleet_policy_payload'));
});

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
  const record = { account_id:'account', chain_id:'chain', task_id:'task', attempt_no:'9007199254740993', started_ms:'1000', ended_ms:'1100', holder_instance_id:'instance', outcome:'submitted', work_lease_id:'lease', completeness:'full' };
  assert.equal(ownerParse(JSON.stringify(record), 'native_attempt').attempt_no, '9007199254740993');
  assert.equal(ownerParse(JSON.stringify({ ...record, outcome:'expired:chain_closed' }), 'native_attempt').outcome, 'expired:chain_closed');
  for (const patch of [{ ended_ms:'999' }, { ended_ms:'' }, { ended_ms:'unknown' }, { outcome:'assumed' }, { counts_toward_budget:'1' }])
    assert.throws(() => ownerParse(JSON.stringify({ ...record, ...patch }), 'native_attempt'));
  for (const payload of [{ attempt:'0' }, { attempt:'-1' }, { attempt:'1', lease_id:'forged' }])
    assert.throws(() => ownerParse(JSON.stringify(payload), 'attempt_read_payload'));
});

test('native attempt projection has explicit completeness and strict release vocabulary', () => {
  const state = { attempt_no: '4', last_release: 'handoff', work_lease_id: 'lease_2', completeness: 'full' };
  assert.equal(ownerParse(JSON.stringify(state), 'attempt_state').attempt_no, '4');
  assert.equal(ownerParse(JSON.stringify({ ...state, completeness: 'incomplete' }), 'attempt_state').completeness, 'incomplete');
  for (const patch of [{ completeness: 'assumed' }, { last_release: 'unknown' }, { attempt_no: '-1' }, { counting_attempts: '2' }, { budget_allowed: '1' }]) {
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
  ownerParse(JSON.stringify({...page,kind:'fleet'}), 'native_metadata_read');
  for (const patch of [{ kind:'unknown' }, { limit:'101' }, { limit:'0' }, { task_id:'forged' }])
    assert.throws(() => ownerParse(JSON.stringify({ ...page, ...patch }), 'native_metadata_read'));
});

test('curated summary uses chain scope, mutation CAS and strict encrypted prose; history is read-only', () => {
  const base = {...doc('command'),task_id:'',expected_revision:'1'} as OwnerCommand;
  const c = {...base,method:'chain.summary.set'};
  ownerParse(JSON.stringify(c),'command');
  assert.throws(()=>ownerParse(JSON.stringify({...c,task_id:'task'}),'command'));
  const g = {...grant,method:c.method,task_id:''};
  assert.equal(ownerLiveAdmit(c,{...g,can_mutate:false},1000n,1n),'invalid_scope');
  assert.equal(ownerLiveAdmit(c,g,1000n,2n),'stale_revision');
  assert.equal(ownerLiveAdmit(c,g,1000n,1n),'none');
  const read = {...base,method:'chain.metadata.read',expected_revision:'0'};
  ownerParse(JSON.stringify(read),'command');
  assert.equal(ownerLiveAdmit(read,{...g,method:read.method,can_mutate:false},1000n,2n),'none');
  assert.throws(()=>ownerParse(JSON.stringify({body_cipher:'plain text'}),'comment_payload'));
});

test('defaults is a chain-scoped mutation distinct from review-role installation', () => {
  const c = {...doc('command'),task_id:'',method:'chain.defaults.set',expected_revision:'1'} as OwnerCommand;
  ownerParse(JSON.stringify(c),'command');
  assert.throws(()=>ownerParse(JSON.stringify({...c,task_id:'task'}),'command'));
  const g = {...grant,method:c.method,task_id:''};
  assert.equal(ownerLiveAdmit(c,{...g,can_mutate:false},1000n,1n),'invalid_scope');
  assert.equal(ownerLiveAdmit(c,g,1000n,2n),'stale_revision');
  assert.equal(ownerLiveAdmit(c,g,1000n,1n),'none');
});

test('operational members and directories are strict chain mutations', () => {
  for (const method of ['chain.member.set','chain.directory.set']) {
    ownerParse(JSON.stringify({...doc('command'),method,task_id:''}),'command');
    assert.throws(()=>ownerParse(JSON.stringify({...doc('command'),method,task_id:'task'}),'command'));
  }
  const member={instance_id:'instance',agent_id:'agent',role:'worker',enabled:'1'};
  ownerParse(JSON.stringify(member),'member_payload');
  ownerParse(JSON.stringify({...member,role:'security'}),'member_payload');
  for(const patch of [{role:'security role'},{enabled:true},{capability:'grant'}]) assert.throws(()=>ownerParse(JSON.stringify({...member,...patch}),'member_payload'));
  const registry=doc('registry');
  ownerParse(JSON.stringify({directory_id:'directory',enabled:'1',body_cipher:registry.chain_title_cipher || registry.task_title_cipher}),'directory_payload');
  assert.throws(()=>ownerParse('{"directory_id":"directory","enabled":"1","body_cipher":""}','directory_payload'));
});

test('brief reference vocabulary mirrors immutable owner admission',()=>{
  for(const raw of ['#7','output:task:1:2','facet:task:1:handoff','facet:task:1:output:2','output:task:durable:1:2','facet:task:durable:1:output:2','facet:task:0:placement:1']) assert.ok(ownerPinnedRef(raw));
  for(const raw of ['output:task','output:task:1','output:task:01:1','#0','facet:task:1:unknown','facet:task:1:output:0','artifact:mutable',' file@main']) assert.equal(ownerPinnedRef(raw),null);
});

test('shared native work request documents reject unknown fields, duplicate keys and imprecise counters',()=>{
  const cases=JSON.parse(readFileSync(new URL('../src/contracts/fixtures/owner-work.json',import.meta.url),'utf8'));
  for(const row of cases)assert.equal(ownerWorkDocumentValid(row.raw,row.method),row.valid,row.raw);
  const c={...doc('command'),method:'work.read',task_id:'',expected_revision:'0'} as OwnerCommand;
  ownerParse(JSON.stringify(c),'command');
  assert.equal(ownerLiveAdmit(c,{...grant,task_id:'',method:c.method,can_mutate:false},1000n,1n),'none');
  for(const method of ['chain.propose','chain.decide','chain.complete']){
    assert.equal(ownerLiveAdmit({...c,method},{...grant,task_id:'',method,can_mutate:false},1000n,1n),'invalid_scope');
  }
});

test('rich aggregate metadata kinds retain strict read scope and preserve raw numeric source documents',()=>{
  const fixture=JSON.parse(readFileSync(new URL('../src/contracts/fixtures/owner-native-aggregate.json',import.meta.url),'utf8'));
  assert.equal(Object.keys(fixture.structs).length,23);
  for(const entry of fixture.metadata){
    ownerParse(JSON.stringify({source_revision:'rich_source_7',kind:entry.kind,cursor:'',limit:'1'}),'native_metadata_read');
    assert.equal(typeof entry.raw,'string');
  }
  assert(fixture.metadata.some((entry:any)=>entry.raw.includes('9007199254740993')));
  assert.throws(()=>ownerParse(JSON.stringify({source_revision:'rich_source_7',kind:'unknown_native',cursor:'',limit:'1'}),'native_metadata_read'));
});

test('linked methods require signed chain scope, strict versions and current read or write grants', () => {
  for (const method of ['linked.put','linked.delete','linked.restore','linked.read','linked.fetch','linked.backup','linked.facet.read','envelope.read']) {
    const c = {...doc('command'),method,task_id:'',expected_revision:'1'} as OwnerCommand;
    ownerParse(JSON.stringify(c),'command');
    assert.throws(()=>ownerParse(JSON.stringify({...c,task_id:'task_1'}),'command'));
    const read=['linked.read','linked.fetch','linked.backup','linked.facet.read','envelope.read'].includes(method);
    assert.equal(ownerLiveAdmit(c,{...grant,method,task_id:'',can_mutate:false},1000n,1n),read?'none':'invalid_scope');
  }
  ownerParse('{"kind":"artifact","object_id":"original","revision":"9007199254740993"}','linked_delete');
  for(const patch of [{kind:'file'},{revision:'0'},{revision:'01'},{chain_id:'other'}])
    assert.throws(()=>ownerParse(JSON.stringify({kind:'artifact',object_id:'a',revision:'1',...patch}),'linked_delete'));
  assert.throws(()=>ownerParse('{"kind":"artifact","kind":"blob","object_id":"a","revision":"1"}','linked_delete'));
  assert.throws(()=>ownerParse('{"cursor":"","limit":"101"}','linked_page'));
  assert.throws(()=>ownerParse('{"kind":"artifact","object_id":"a","revision":"1","offset":"-1"}','linked_fetch'));
});
