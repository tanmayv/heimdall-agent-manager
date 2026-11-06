import { test } from 'node:test';
import assert from 'node:assert/strict';
import { FakeHub, USER } from './helpers/vaultDirectoryFixture.ts';
import { createDeviceIdentity, memoryDeviceStore } from '../src/ui/utils/deviceIdentity.ts';
import { importKeyring } from '../src/ui/utils/vaultKeyring.ts';
import { decryptVaultText } from '../src/ui/utils/vaultContent.ts';
import { prepareOwnerOperation } from '../src/ui/api/ownerLocalClient.ts';
import { ownerParse, ownerLiveAdmit, ownerPayloadKind, ownerVerifySignature } from '../src/ui/api/ownerLocal.ts';

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
