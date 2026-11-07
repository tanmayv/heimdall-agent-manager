import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { executorParse, executorCanonical, executorVerify, executorReceiptMatches, executorFenceReplyMatches, executorEnrollmentMatches, type ExecutorKind } from '../src/ui/api/executor.ts';
import { ownerParse, ownerPayloadKind } from '../src/ui/api/ownerLocal.ts';
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
  for (const method of ['activate','heartbeat']) {
    const action = await sign('action', {...executorParse(fixture.valid.find(r => r.kind === 'action')!.raw,'action'),method,owner_bridge_id:'owner',key_id:ownerKey.key_id},owner);
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
  }
});
test('executor schemas reject duplicate nested slots and noncanonical integers', () => {
  const policy = executorParse(fixture.valid[0].raw, 'policy');
  const slot = JSON.parse(policy.slots_json)[0];
  assert.throws(() => executorParse(JSON.stringify({...policy, slots_json: JSON.stringify([slot,slot])}), 'policy'));
  for (const capacity of ['0','01','+1','1.0','1e2','9223372036854775808']) {
    assert.throws(() => executorParse(JSON.stringify({...policy, device_capacity:capacity}), 'policy'));
  }
});

test('local launch requires exact enrolled device signature without owner or task authority', async () => {
  const pair = await crypto.subtle.generateKey({name:'ECDSA',namedCurve:'P-256'},true,['sign','verify']);
  const hex = (value: ArrayBuffer) => Buffer.from(value).toString('hex');
  const key = {account_id:'account',principal_id:'device',key_id:'device_key',public_key:hex(await crypto.subtle.exportKey('raw',pair.publicKey)),kind:'device' as const,enrolled:true,revoked:false};
  const consent = executorParse(fixture.valid.find(r => r.kind === 'local_launch')!.raw,'local_launch');
  const signature = hex(await crypto.subtle.sign({name:'ECDSA',hash:'SHA-256'},pair.privateKey,new TextEncoder().encode(executorCanonical('local_launch',consent))));
  const sealed = {...consent,signature};
  assert.equal(await executorVerify('local_launch',sealed,key),true);
  for (const changed of [{...key,kind:'bridge' as const},{...key,revoked:true},{...key,enrolled:false},{...key,principal_id:'other'},{...key,account_id:'other'}]) {
    assert.equal(await executorVerify('local_launch',sealed,changed),false);
  }
  for (const name of Object.keys(consent).filter(k => k !== 'signature')) {
    assert.equal(await executorVerify('local_launch',{...sealed,[name]:name === 'configuration_digest' ? 'd'.repeat(64) : '99'},key),false,name);
  }
  assert.throws(() => executorParse(JSON.stringify({...sealed,task_id:'task'}),'local_launch'));
  const c = executorParse(fixture.valid.find(r => r.kind === 'local_configuration')!.raw,'local_configuration');
  const unicode = executorParse(JSON.stringify({...c,model:'模型 🚀'}),'local_configuration');
  assert.equal(unicode.model,'模型 🚀');
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

test('remote enrollment binds exact device-selected configuration and enrolled executor key', async () => {
  const pair = await crypto.subtle.generateKey({name:'ECDSA',namedCurve:'P-256'},true,['sign','verify']);
  const hex = (value: ArrayBuffer) => Buffer.from(value).toString('hex');
  const key = {account_id:'account',principal_id:'executor',key_id:'operator',public_key:hex(await crypto.subtle.exportKey('raw',pair.publicKey)),kind:'bridge' as const,enrolled:true,revoked:false};
  const config = {protocol_version:'1',account_id:'account',owner_bridge_id:'owner1',executor_bridge_id:'executor',executor_key_id:'operator',
    chain_id:'chain',task_id:'task',instance_id:'instance',agent_id:'author',launch_epoch:'epoch',run_count:'1',token_generation:'a'.repeat(64),
    configuration_revision:'1',executor_incarnation:'1',policy_revision:'1',slot_id:'slot1',provider_profile:'default',provider:'codex',model:'模型🚀',
    directory_id:'remote_dir',directory_key:'b'.repeat(64),directory_path:'/repo'};
  const raw = JSON.stringify(config);
  assert.equal(ownerParse(raw,'remote_configuration').model,'模型🚀');
  const enrollment = {...executorParse(fixture.valid.find(r => r.kind === 'enrollment')!.raw,'enrollment'),configuration_digest:createHash('sha256').update(raw).digest('hex')};
  const signed = {...enrollment,signature:hex(await crypto.subtle.sign({name:'ECDSA',hash:'SHA-256'},pair.privateKey,new TextEncoder().encode(executorCanonical('enrollment',enrollment))))};
  assert.equal(await executorEnrollmentMatches(signed,raw,key,1200n),true);
  assert.equal(await executorEnrollmentMatches(signed,raw+' ',key,1200n),false);
  assert.equal(await executorEnrollmentMatches(signed,JSON.stringify({...config,executor_key_id:'other'}),key,1200n),false);
  assert.equal(await executorEnrollmentMatches(signed,raw,{...key,revoked:true},1200n),false);
  assert.equal(await executorEnrollmentMatches(signed,raw,{...key,principal_id:'other'},1200n),false);
  assert.equal(await executorEnrollmentMatches(signed,raw,key,2000n),false);
  assert.equal(await executorEnrollmentMatches(signed,raw,key,3000n,false),true);
  assert.equal(ownerPayloadKind('fleet.reserve'),'fleet_reserve_payload');
  const reservation = {configuration:raw,attestation:JSON.stringify(signed)};
  assert.deepEqual({...ownerParse(JSON.stringify(reservation),'remote_reservation')},reservation);
  assert.throws(() => ownerParse(JSON.stringify({...reservation,child:'synthetic'}),'remote_reservation'));
});

test('issuance binds enrolled device consent to selectors, generated configuration and signed response', async () => {
  const { executorIssuanceMatches } = await import('../src/ui/api/executor.ts');
  const device = await crypto.subtle.generateKey({name:'ECDSA',namedCurve:'P-256'},true,['sign','verify']);
  const host = await crypto.subtle.generateKey({name:'ECDSA',namedCurve:'P-256'},true,['sign','verify']);
  const hex = (value: ArrayBuffer) => Buffer.from(value).toString('hex');
  const key = async (pair: CryptoKeyPair, principal_id: string, key_id: string, kind: 'device' | 'bridge') =>
    ({account_id:'account',principal_id,key_id,kind,public_key:hex(await crypto.subtle.exportKey('raw',pair.publicKey)),enrolled:true,revoked:false});
  const deviceKey = await key(device,'owner2','owner2','device'), executorKey = await key(host,'executor','operator','bridge');
  const sign = async (kind: ExecutorKind, value: Record<string,string>, pair: CryptoKeyPair) =>
    ({...value,signature:hex(await crypto.subtle.sign({name:'ECDSA',hash:'SHA-256'},pair.privateKey,new TextEncoder().encode(executorCanonical(kind,value))))});
  const digest = (raw: string) => createHash('sha256').update(raw).digest('hex');
  const doc = (kind: ExecutorKind) => executorParse(fixture.valid.find(r => r.kind === kind)!.raw,kind);
  const selectionRaw = JSON.stringify(doc('issuance_selection'));
  const consent = await sign('issuance_consent',{...doc('issuance_consent'),selection_digest:digest(selectionRaw)},device);
  assert.equal(await executorVerify('issuance_consent',consent,deviceKey),true);
  assert.equal(await executorVerify('issuance_consent',consent,{...deviceKey,kind:'bridge'}),false);
  assert.equal(await executorVerify('issuance_consent',consent,{...deviceKey,revoked:true}),false);
  const config = {protocol_version:'1',account_id:'account',owner_bridge_id:'owner1',executor_bridge_id:'executor',executor_key_id:'operator',
    chain_id:'chain',task_id:'task',instance_id:'inst_generated',agent_id:'author',launch_epoch:'epoch_generated',run_count:'1',
    token_generation:'a'.repeat(64),configuration_revision:'1',executor_incarnation:'1',
    ...doc('issuance_selection'),directory_key:'b'.repeat(64),directory_path:'/repo'};
  const raw = JSON.stringify(config);
  const enrollment = await sign('enrollment',{...doc('enrollment'),instance_id:config.instance_id,configuration_digest:digest(raw)},host);
  const receipt = await sign('issuance_receipt',{...doc('issuance_receipt'),request_digest:digest(executorCanonical('issuance_consent',consent)),
    configuration_digest:digest(raw),enrollment_digest:digest(executorCanonical('enrollment',enrollment))},host);
  const matches = (r = receipt, c = consent, sel = selectionRaw, configuration = raw, e = enrollment, now = 1200n, current = true) =>
    executorIssuanceMatches(r,c,sel,configuration,e,deviceKey,executorKey,now,current);
  assert.equal(await matches(),true);
  assert.equal(await matches(receipt,consent,selectionRaw,raw,enrollment,2000n),false);
  assert.equal(await matches(receipt,consent,selectionRaw,raw,enrollment,3000n,false),true);
  assert.equal(await matches(receipt,consent,selectionRaw+' '),false);
  assert.equal(await matches(receipt,consent,selectionRaw,raw+' '),false);
  for (const name of ['account_id','owner_bridge_id','executor_bridge_id','chain_id','task_id','operation_id','principal_id','request_digest','configuration_digest','enrollment_digest']) {
    const value = receipt[name].length === 64 ? 'c'.repeat(64) : 'other';
    assert.equal(await matches(await sign('issuance_receipt',{...receipt,[name]:value},host)),false,name);
  }
  // Even freshly signed output from the enrolled executor cannot satisfy
  // consent for another task/agent/provider/directory/configuration revision.
  for (const name of ['task_id','agent_id','configuration_revision','provider','model','provider_profile','directory_id','policy_revision','slot_id']) {
    const changed = JSON.stringify({...config,[name]:name.endsWith('revision') ? '2' : 'other'});
    const attestation = await sign('enrollment',{...enrollment,task_id:name === 'task_id' ? 'other' : enrollment.task_id,
      configuration_revision:name === 'configuration_revision' ? '2' : enrollment.configuration_revision,
      configuration_digest:digest(changed)},host);
    const response = await sign('issuance_receipt',{...receipt,configuration_digest:digest(changed),enrollment_digest:digest(executorCanonical('enrollment',attestation))},host);
    assert.equal(await matches(response,consent,selectionRaw,changed,attestation),false,name);
  }
  assert.equal(await executorIssuanceMatches(receipt,consent,selectionRaw,raw,enrollment,{...deviceKey,revoked:true},executorKey,1200n),false);
  assert.equal(await executorIssuanceMatches(receipt,consent,selectionRaw,raw,enrollment,deviceKey,{...executorKey,revoked:true},1200n),false);
});
