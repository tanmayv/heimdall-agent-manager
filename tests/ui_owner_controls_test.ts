import { test } from 'node:test';
import assert from 'node:assert/strict';
import { FakeHub, USER } from './helpers/vaultDirectoryFixture.ts';
import { createDeviceIdentity, memoryDeviceStore } from '../src/ui/utils/deviceIdentity.ts';
import { importKeyring } from '../src/ui/utils/vaultKeyring.ts';
import { decryptVaultText } from '../src/ui/utils/vaultContent.ts';
import { prepareOwnerOperation } from '../src/ui/api/ownerLocalClient.ts';
import { ownerParse, ownerCanonical, ownerLiveAdmit, ownerPayloadKind, ownerVerifySignature } from '../src/ui/api/ownerLocal.ts';
import { ownerSchemas } from '../src/ui/api/ownerSchema.ts';

test('owner-local attempt budget activation is no longer an owner method', async () => {
  // The owner-local attempt budget was removed by user decision on 2026-11-07.
  assert.throws(()=>ownerPayloadKind('budget.activate'),/Unsupported owner method/);
  const identity=await createDeviceIdentity(memoryDeviceStore(),USER);
  const hub=new FakeHub();await hub.genesis(identity);
  const verified=await hub.chain(),keyring=await importKeyring(await hub.keyringBytes(identity),USER);
  const chain={...verified,trusted:new Map(verified.trusted)};
  chain.trusted.set('bridge_key',{kind:'bridge',device_id:'bridge_key',row:{bridge_id:'bridge'}} as any);
  await assert.rejects(prepareOwnerOperation({identity,chain,keyring},'bridge','budget.activate',{chainId:'chain',taskId:'task',expectedRevision:'9',body:'{}'}));
});

test('control preparation encrypts reasons, signs exact CAS and keeps every control a mutation', async () => {
  const identity = await createDeviceIdentity(memoryDeviceStore(), USER);
  const hub = new FakeHub(); await hub.genesis(identity);
  const verified = await hub.chain();
  const keyring = await importKeyring(await hub.keyringBytes(identity), USER);
  const chain = { ...verified, trusted: new Map(verified.trusted) };
  chain.trusted.set('bridge_key', {kind:'bridge',device_id:'bridge_key',row:{bridge_id:'bridge'}} as any);
  const session = {identity,chain,keyring};
  for (const method of ['task.hold','task.release','task.cancel','task.reopen','task.resolve','merge.retry']) {
    const op = await prepareOwnerOperation(session,'bridge',method,{chainId:'chain',taskId:'task',expectedRevision:'7',body:'explicit private answer',configurationRevision:'2',requirementsRevision:'3',attempt:'4',head:'a'.repeat(40)});
    assert.ok(!op.payload.includes('explicit private answer'));
    const command = ownerParse(op.command,'command');
    const payload = ownerParse(op.payload,ownerPayloadKind(method));
    assert.equal(await decryptVaultText(payload.body_cipher,keyring),'explicit private answer');
    assert.equal(command.expected_revision,'7');
    assert.equal(await ownerVerifySignature('command',command,'signature',{account_id:USER,principal_id:identity.deviceId,key_id:identity.deviceId,public_key:identity.signPub,kind:'device',enrolled:true,revoked:false}),true);
    const grant = {account_id:USER,owner_bridge_id:'bridge',chain_id:'chain',task_id:'task',principal_id:identity.deviceId,key_id:identity.deviceId,method,revision:1n,expires_ms:BigInt(Date.now()+600000),can_read:true,can_mutate:false,revoked:false};
    assert.equal(ownerLiveAdmit(command,grant,BigInt(Date.now()),7n),'invalid_scope');
    assert.equal(ownerLiveAdmit(command,{...grant,can_mutate:true},BigInt(Date.now()),8n),'stale_revision');
    assert.equal(ownerLiveAdmit(command,{...grant,can_mutate:true},BigInt(Date.now()),7n),'none');
    assert.throws(()=>ownerParse(JSON.stringify({...command,task_id:''}),'command'));
  }
});

test('switch and review checkpoint are explicit strict contracts without a verdict shortcut', () => {
  const payload={requirements_revision:'2',summary:'checkpoint',next_steps:'continue',destination_chain_id:'chain',destination_task_id:'task',destination_revision:'9',destination_configuration_revision:'3',destination_requirements_revision:'4',destination_lease_id:'lease'};
  assert.equal(ownerParse(JSON.stringify(payload),'switch_payload').destination_revision,'9');
  for(const patch of [{destination_owner:'other'},{destination_revision:'0'},{destination_requirements_revision:'04'}])
    assert.throws(()=>ownerParse(JSON.stringify({...payload,...patch}),'switch_payload'));
  const checkpoint={requirements_revision:'2',attempt:'1',head:'',summary:'review unfinished',next_steps:'inspect next file'};
  assert.equal(ownerParse(JSON.stringify(checkpoint),'checkpoint_payload').summary,'review unfinished');
  assert.throws(()=>ownerParse(JSON.stringify({...checkpoint,verdict:'approve'}),'checkpoint_payload'));
  assert.equal(ownerPayloadKind('review.checkpoint'),'checkpoint_payload');
  assert.equal(ownerPayloadKind('lease.block'),'block_payload');
  assert.throws(()=>ownerParse(JSON.stringify({requirements_revision:'2',summary:'reason',next_steps:''}),'block_payload'));
});

test('static workflow and source operations use signed encrypted owner commands with exact task scope', async () => {
  const identity = await createDeviceIdentity(memoryDeviceStore(), USER);
  const hub = new FakeHub(); await hub.genesis(identity);
  const verified = await hub.chain();
  const keyring = await importKeyring(await hub.keyringBytes(identity), USER);
  const chain = { ...verified, trusted: new Map(verified.trusted) };
  chain.trusted.set('bridge_key', {kind:'bridge',device_id:'bridge_key',row:{bridge_id:'bridge'}} as any);
  const session = {identity,chain,keyring};
  for (const method of ['workflow.cancel','workflow.gate','workflow.define','workflow.run','workflow.retry','source.observe','source.consume','source.ack','source.retire','source.resolve','source.escalate']) {
    const taskId = '';
    const body = '{"private":"source and workflow content"}';
    const op = await prepareOwnerOperation(session,'bridge',method,{chainId:'chain',taskId,expectedRevision:'7',body});
    const command = ownerParse(op.command,'command');
    const payload = ownerParse(op.payload,'control_payload');
    assert.ok(!op.payload.includes('private'));
    assert.equal(await decryptVaultText(payload.body_cipher,keyring),body);
    assert.equal(await ownerVerifySignature('command',command,'signature',{account_id:USER,principal_id:identity.deviceId,key_id:identity.deviceId,public_key:identity.signPub,kind:'device',enrolled:true,revoked:false}),true);
    assert.throws(()=>ownerParse(JSON.stringify({...command,task_id:taskId?'':'task'}),'command'));
    const grant = {account_id:USER,owner_bridge_id:'bridge',chain_id:'chain',task_id:taskId,principal_id:identity.deviceId,key_id:identity.deviceId,method,revision:1n,expires_ms:BigInt(Date.now()+600000),can_read:true,can_mutate:false,revoked:false};
    assert.equal(ownerLiveAdmit(command,grant,BigInt(Date.now()),7n),'invalid_scope');
  }
  // A task's review gate is brief.reviewers + requires_user_approval only.
  assert.equal(Object.hasOwn(ownerSchemas,'review_pair'),false);
  const fact = {origin_kind:'attention',origin_id:'origin',episode_id:'episode',source_version:'8',resolved:'1',deadline_ms:'0',body:'private source'};
  assert.equal(ownerParse(JSON.stringify(fact),'source_fact').episode_id,'episode');
  assert.throws(()=>ownerParse(JSON.stringify({...fact,source_version:'0'}),'source_fact'));
  assert.throws(()=>ownerParse(JSON.stringify({...fact,owner_bridge_id:'other'}),'source_fact'));
});

test('workflow structured output canonicalization and coordinator scope are exact', () => {
  const output=ownerParse(JSON.stringify({requirements_revision:'1',head:'',summary:'Done',output:'{}'}),'submit_payload');
  const first=ownerCanonical('submit_payload',output);
  const changed=ownerParse(JSON.stringify({...output,output:'{"changed":true}'}),'submit_payload');
  assert.notEqual(first,ownerCanonical('submit_payload',changed));
  assert.equal(ownerPayloadKind('workflow.coordinator'),'coordinator_payload');
  assert.equal(ownerPayloadKind('workflow.gate.post'),'workflow_gate');
  assert.equal(ownerParse(JSON.stringify({configuration_revision:'1',agent_id:'agt_coordinator',instance_id:'inst_running'}),'coordinator_payload').agent_id,'agt_coordinator');
  assert.throws(()=>ownerParse(JSON.stringify({...output,unknown:'ignored?'}),'submit_payload'));
});
