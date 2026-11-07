import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { ownerCanonical, ownerDigest, ownerParse, ownerVerifySignature } from '../src/ui/api/ownerLocal.ts';
import type { OwnerVerifiedKey } from '../src/ui/api/ownerLocal.ts';
import type { OwnerKind, OwnerDocuments } from '../src/ui/api/ownerSchema.ts';
import { ownerSchemas } from '../src/ui/api/ownerSchema.ts';
import { ownerMigrationAdmit, ownerVerifyMigrationControl, ownerVerifyMigrationImport, ownerVerifyMigrationSelection } from '../src/ui/api/ownerMigration.ts';

const fixture = JSON.parse(readFileSync(new URL('../src/contracts/fixtures/owner-migration-v1.json', import.meta.url), 'utf8'));
const document = <K extends OwnerKind>(kind: K): OwnerDocuments[K] => ownerParse(fixture.valid.find((entry: {kind: string}) => entry.kind === kind).raw, kind);
const device: OwnerVerifiedKey = { account_id:'account', principal_id:'device', key_id:'device_key', public_key:fixture.device_public_key, kind:'device', enrolled:true, revoked:false };
const owner: OwnerVerifiedKey = { ...device, principal_id:'bridge', key_id:'bridge_key', public_key:fixture.owner_public_key, kind:'bridge' };

test('migration proofs share exact native canonical bytes and signed field coverage', async () => {
  for (const entry of fixture.valid) {
    const kind = entry.kind as OwnerKind;
    const o = ownerParse(entry.raw, kind);
    assert.equal(ownerCanonical(kind, o), entry.canonical);
    assert.equal(await ownerDigest(kind, o), entry.digest);
    const signer = ['genesis','migration_import_receipt'].includes(kind) ? owner : device;
    const signature = kind === 'genesis' ? 'owner_signature' : 'signature';
    assert.equal(await ownerVerifySignature(kind, o, signature, signer), true);
    for (const [name, type] of ownerSchemas[kind]) {
      if (type === 'signature') continue;
      assert.equal(await ownerVerifySignature(kind, { ...o, [name]:'changed' }, signature, signer), false, `${kind}.${name}`);
    }
    assert.throws(() => ownerParse(entry.raw.replace('{', '{"unexpected":"x",'), kind));
    assert.throws(() => ownerParse(entry.raw.replace('{', '{"protocol_version":"1",'), kind));
  }
});

test('migration selection needs current approved device and explicit selected owner; expiry is fresh-admission only', async () => {
  const s = document('migration_selection');
  const empty = ownerParse(JSON.stringify({...s, expected_work_revision:'0'}), 'migration_selection');
  assert.equal(ownerMigrationAdmit('migration_selection', empty, 1000n, 0n), 'none');
  assert.equal(await ownerVerifyMigrationSelection(s, 'account', 'chain', device, owner), 'none');
  assert.equal(await ownerVerifyMigrationSelection(s, 'other', 'chain', device, owner), 'invalid_scope');
  assert.equal(await ownerVerifyMigrationSelection(s, 'account', 'other', device, owner), 'invalid_scope');
  for (const changed of [{...owner, principal_id:'other'}, {...owner, revoked:true}, {...owner, enrolled:false}])
    assert.equal(await ownerVerifyMigrationSelection(s, 'account', 'chain', device, changed), 'owner_mismatch');
  assert.equal(await ownerVerifyMigrationSelection(s, 'account', 'chain', {...device, kind:'bridge'}, owner), 'invalid_scope');
  assert.equal(await ownerVerifyMigrationSelection(s, 'account', 'chain', {...device, revoked:true}, owner), 'bad_signature');
  assert.equal(ownerMigrationAdmit('migration_selection', s, 1000n, 9007199254740993n), 'none');
  assert.equal(ownerMigrationAdmit('migration_selection', s, 1000n, 9007199254740992n), 'stale_revision');
  assert.equal(ownerMigrationAdmit('migration_selection', s, 2000n, 9007199254740993n), 'expired');
  assert.equal(ownerMigrationAdmit('migration_selection', s, -1n, 9007199254740993n), 'expired');
  assert.equal(ownerMigrationAdmit('migration_selection', {...s, request_expires_ms:'301001'}, 1000n, 9007199254740993n), 'expired');
  assert.equal(await ownerVerifyMigrationSelection(s, 'account', 'chain', device, owner), 'none');
});

test('import and cutover correlate selection, immutable genesis, schema, manifest and exact signed receipt', async () => {
  const s = document('migration_selection'), g = document('genesis'), r = document('migration_import_receipt'), c = document('migration_control');
  const manifest = fixture.manifest_digest, evidence = await ownerDigest('migration_import_receipt', r);
  assert.equal(await ownerVerifyMigrationImport(r, s, g, manifest, owner), 'none');
  assert.equal(await ownerVerifyMigrationImport(r, s, g, 'b'.repeat(64), owner), 'digest_mismatch');
  assert.equal(await ownerVerifyMigrationImport(r, s, g, manifest, {...owner, revoked:true}), 'bad_signature');
  assert.equal(await ownerVerifyMigrationImport({...r, migration_id:'other'}, s, g, manifest, owner), 'invalid_scope');
  assert.equal(await ownerVerifyMigrationImport({...r, schema_version:'30'}, s, g, manifest, owner), 'invalid_scope');
  assert.equal(await ownerVerifyMigrationImport(r, s, {...g, creation_op:'other'}, manifest, owner), 'digest_mismatch');
  assert.equal(await ownerVerifyMigrationControl(c, s, evidence, device), 'none');
  assert.equal(await ownerVerifyMigrationControl(c, s, manifest, device), 'digest_mismatch');
  assert.equal(await ownerVerifyMigrationControl({...c, action:'resume'}, s, evidence, device), 'bad_signature');
  assert.equal(await ownerVerifyMigrationControl({...c, chain_id:'other'}, s, evidence, device), 'invalid_scope');
  assert.equal(ownerMigrationAdmit('migration_control', c, 1000n, 3n), 'none');
  assert.equal(ownerMigrationAdmit('migration_control', c, 1000n, 2n), 'stale_revision');
  assert.equal(ownerMigrationAdmit('migration_control', c, 2000n, 3n), 'expired');
  assert.throws(() => ownerParse(JSON.stringify({...c, action:'activate'}), 'migration_control'));
  assert.equal(await ownerVerifySignature('migration_selection', c as never, 'signature', device), false);
});
