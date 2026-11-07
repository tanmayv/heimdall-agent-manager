import { test } from 'node:test';
import assert from 'node:assert/strict';
import { FakeHub, USER } from './helpers/vaultDirectoryFixture.ts';
import { createDeviceIdentity, memoryDeviceStore } from '../src/ui/utils/deviceIdentity.ts';
import { importKeyring } from '../src/ui/utils/vaultKeyring.ts';
import { ownerParse, ownerVerifySignature } from '../src/ui/api/ownerLocal.ts';
import { ownerVerifyMigrationSelection } from '../src/ui/api/ownerMigration.ts';
import { ApiError } from '../src/ui/api/cookieFetch.ts';
import { describeMigrationBlockers, migrationBlockersFromError, prepareMigrationRequest } from '../src/ui/api/ownerMigrationClient.ts';

test('legacy migration request is device-signed selection plus genesis created by the migration', async () => {
  const identity = await createDeviceIdentity(memoryDeviceStore(), USER);
  const hub = new FakeHub(); await hub.genesis(identity);
  const verified = await hub.chain();
  const keyring = await importKeyring(Uint8Array.from(await hub.keyringBytes(identity)), USER);
  const chain = {...verified, trusted:new Map(verified.trusted)};
  chain.trusted.set('bridge_key', {kind:'bridge',device_id:'bridge_key',row:{bridge_id:'bridge'}} as any);
  const session = {identity,chain,keyring};
  const request = await prepareMigrationRequest(session,'chain_1','bridge',7,'mig_1');
  const selection = ownerParse(request.selection,'migration_selection');
  const genesis = ownerParse(request.genesis,'genesis');
  assert.equal(selection.expected_work_revision,'7');
  assert.equal(selection.owner_key_id,'bridge_key');
  assert.equal(genesis.creation_op,'mig_1');
  assert.equal(genesis.owner_signature,'0'.repeat(128),'the owner Bridge adds its genesis signature on import');
  const device = {account_id:USER,principal_id:identity.deviceId,key_id:identity.deviceId,public_key:identity.signPub,kind:'device' as const,enrolled:true,revoked:false};
  const owner = {account_id:USER,principal_id:'bridge',key_id:'bridge_key',public_key:'',kind:'bridge' as const,enrolled:true,revoked:false};
  assert.equal(await ownerVerifyMigrationSelection(selection,USER,'chain_1',device,owner),'none');
  assert.equal(await ownerVerifySignature('genesis',genesis,'creator_signature',device),true);
  await assert.rejects(prepareMigrationRequest(session,'chain_1','unknown_bridge',7),/currently enrolled/);
});

test('busy-chain refusals are listed from the Hub error details', () => {
  const error = new ApiError('chain has live work',409,'conflict',undefined,undefined,{code:'migration_blocked',blockers:[{code:'live_leases',count:2},{code:'tasks_in_review',count:1},{code:'future_reason',count:3}]});
  const blockers = migrationBlockersFromError(error);
  assert.equal(blockers.length,3);
  const text = describeMigrationBlockers(blockers);
  assert.match(text[0],/^2 × agents still hold leases/);
  assert.match(text[1],/awaiting review/);
  assert.equal(text[2],'3 × future_reason');
  assert.deepEqual(migrationBlockersFromError(new Error('x')),[]);
  assert.deepEqual(describeMigrationBlockers(null),[]);
});
