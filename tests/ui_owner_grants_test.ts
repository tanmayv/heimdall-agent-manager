import { test } from 'node:test';
import assert from 'node:assert/strict';
import { FakeHub, USER } from './helpers/vaultDirectoryFixture.ts';
import { createDeviceIdentity, memoryDeviceStore } from '../src/ui/utils/deviceIdentity.ts';
import { importKeyring } from '../src/ui/utils/vaultKeyring.ts';
import { prepareOwnerOperation, ownerRelayFile } from '../src/ui/api/ownerLocalClient.ts';
import { ownerParse, ownerPayloadKind, ownerVerifySignature, ownerAuthenticateCommand, ownerLiveAdmit } from '../src/ui/api/ownerLocal.ts';

test('grant preparation binds exact account, chain, enrolled recipient, rights, expiry and signed CLI export', async () => {
  const identity = await createDeviceIdentity(memoryDeviceStore(), USER);
  const target = await createDeviceIdentity(memoryDeviceStore(), USER);
  const hub = new FakeHub(); await hub.genesis(identity);
  const verified = await hub.chain();
  const keyring = await importKeyring(Uint8Array.from(await hub.keyringBytes(identity)), USER);
  const chain = {...verified, trusted:new Map(verified.trusted)};
  chain.trusted.set('bridge_key', {kind:'bridge',device_id:'bridge_key',row:{bridge_id:'bridge'}} as any);
  chain.trusted.set(target.deviceId, {kind:'browser',device_id:target.deviceId,row:{}} as any);
  const session = {identity,chain,keyring};
  const key = {account_id:USER,principal_id:identity.deviceId,key_id:identity.deviceId,public_key:identity.signPub,kind:'device' as const,enrolled:true,revoked:false};
  for (const method of ['grant.set','grant.revoke','grant.read','grant.policy','grant.recover']) {
    const operation = await prepareOwnerOperation(session,'bridge',method,{
      chainId:'chain',expectedRevision:'7',grantPrincipal:target.deviceId,grantExpiresMs:String(Date.now()+600000),
      grantCanMutate:false,policyRevision:'1',recoveryEnabled:true,
    });
    const command = ownerParse(operation.command,'command');
    const payload = ownerParse(operation.payload,ownerPayloadKind(method));
    assert.equal(command.task_id,'');
    assert.equal(command.account_id,USER);
    assert.equal(command.chain_id,'chain');
    assert.equal(command.expected_revision,'7');
    assert.equal(await ownerVerifySignature('command',command,'signature',key),true);
    const relay = await ownerRelayFile(session,operation);
    assert.ok(!JSON.stringify(relay).includes(target.deviceId));
    if (method === 'grant.set' || method === 'grant.recover') {
      assert.equal(payload.principal_id,target.deviceId);
      assert.equal(payload.key_id,target.deviceId);
      assert.equal(payload.can_mutate,'0');
    }
    const grant = {account_id:USER,owner_bridge_id:'bridge',chain_id:'chain',task_id:'',principal_id:identity.deviceId,key_id:identity.deviceId,method,revision:1n,expires_ms:BigInt(Date.now()+600000),can_read:true,can_mutate:false,revoked:false};
    assert.equal(ownerLiveAdmit(command,grant,BigInt(Date.now()),7n),method === 'grant.read' ? 'none':'invalid_scope');
    assert.equal(await ownerAuthenticateCommand(command,operation.payload,key,{...grant,revoked:true},BigInt(Date.now())),'invalid_scope');
    assert.equal(await ownerAuthenticateCommand(command,operation.payload,key,{...grant,expires_ms:1n},BigInt(Date.now())),'invalid_scope');
    assert.throws(()=>ownerParse(JSON.stringify({...command,task_id:'task'}),'command'));
  }
  await assert.rejects(prepareOwnerOperation(session,'bridge','grant.set',{chainId:'chain',expectedRevision:'7',grantPrincipal:'missing',grantExpiresMs:String(Date.now()+600000)}),/enrolled browser/);
  await assert.rejects(prepareOwnerOperation(session,'bridge','grant.set',{chainId:'chain',expectedRevision:'7',grantPrincipal:target.deviceId,grantExpiresMs:String(Date.now()+2592000000+60000)}),/within 30 days/);
  await assert.rejects(prepareOwnerOperation({...session,identity:target},'bridge','grant.recover',{chainId:'chain',expectedRevision:'7',grantPrincipal:target.deviceId,grantExpiresMs:String(Date.now()+600000)}),/paired root/);
  assert.throws(()=>ownerParse('{"policy_revision":"01","recovery_enabled":"1"}','grant_policy_payload'));
  assert.throws(()=>ownerParse('{"principal_id":"device","key_id":"device","extra":"authority"}','grant_revoke_payload'));
});
