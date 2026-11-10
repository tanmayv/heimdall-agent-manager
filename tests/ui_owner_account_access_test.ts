// Owner chains use account-level trust: every paired, unrevoked device of the
// account reads and changes every owner chain, whoever created it (a device or
// the owner Bridge for an agent / New conversation). The app therefore never
// signs grant.* to reach a chain, and a refusal (an unpaired or revoked device)
// is shown as is, never retried through a recovery.
//
// RUN: node --import ./tests/helpers/vaultEndpointHarness.ts --test tests/ui_owner_account_access_test.ts

import './helpers/vaultEndpointHarness.ts';
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { fakeOwner, ownerTestSession, registryRow, type OwnerCall } from './helpers/ownerFakeRelay.ts';
import { loadOwnerChainSummaries, ownerErrorMessage, readOwnerChain, readOwnerChainStatuses } from '../src/ui/api/ownerChains.ts';
import { prepareOwnerOperation } from '../src/ui/api/ownerLocalClient.ts';
import { ownerGenesisBridgeCreator } from '../src/ui/api/ownerLocal.ts';
import { clearKeyringSession } from '../src/ui/utils/vaultKeyringSession.ts';

function accountOwner(session: any, refused: Set<string>, calls: OwnerCall[]) {
  return fakeOwner(session, (call) => {
    const chain = call.command.chain_id;
    if (refused.has(call.command.principal_id) || call.method.startsWith('grant.')) return { code: 'invalid_scope' };
    if (call.method === 'work.read') return { chain_id: chain, status: 'active', publish_state: 'published', work_revision: '1', items: [], next_cursor: '', pending_proposal_id: '', pending_proposal: null };
    return { title: 'Agent chain', description: '', revision: '5', items: [], next_cursor: '' };
  }, calls);
}

test('a Bridge-created chain lists like any other (no creator gating)', async () => {
  const { session, bridgeId } = await ownerTestSession();
  try {
    const rows = [
      { ...(await registryRow(session, { chainId: 'chain_a', bridgeId, online: true })), creator_id: bridgeId },
      { ...(await registryRow(session, { chainId: 'chain_b', bridgeId, online: true })), creator_id: session.identity.deviceId },
    ];
    const chains = await loadOwnerChainSummaries(session, async () => ({ items: rows, next_cursor: { after_chain: '', after_task: '' }, terminal: true }));
    assert.deepEqual(chains.map((c) => c.chainId), ['chain_a', 'chain_b']);
    assert.ok(chains.every((c) => !('bridgeCreated' in c)), 'no per-creator access flag');
  } finally { clearKeyringSession(); }
});

test('the paired root and a second paired device read a Bridge-created chain directly', async () => {
  const { session, bridgeId } = await ownerTestSession();
  try {
    const calls: OwnerCall[] = [];
    const send = accountOwner(session, new Set(), calls);
    const secondDevice = { ...session, chain: { ...session.chain, rootDeviceId: 'dev_other_root' } };
    for (const s of [session, secondDevice]) {
      const detail = await readOwnerChain(s, bridgeId, 'chain_agent', send);
      assert.equal(detail.title, 'Agent chain');
    }
    const statuses = await readOwnerChainStatuses(secondDevice, [{ chainId: 'chain_agent', ownerBridgeId: bridgeId, bridgeName: 'Home', online: true, title: 'A', description: '', sealed: false, tasks: [], projectId: '', projectName: '', migrated: false }], send);
    assert.equal(statuses.get('chain_agent'), 'active');
    assert.deepEqual(calls.map((c) => c.method), ['chain.read', 'chain.read', 'work.read'], 'no grant operation');
  } finally { clearKeyringSession(); }
});

test('an owner refusal is surfaced once, never retried through grant recovery', async () => {
  const { session, bridgeId } = await ownerTestSession();
  try {
    const calls: OwnerCall[] = [];
    const send = accountOwner(session, new Set([session.identity.deviceId]), calls);
    await assert.rejects(readOwnerChain(session, bridgeId, 'chain_agent', send), /invalid_scope/);
    const statuses = await readOwnerChainStatuses(session, [{ chainId: 'chain_agent', ownerBridgeId: bridgeId, bridgeName: 'Home', online: true, title: 'A', description: '', sealed: false, tasks: [], projectId: '', projectName: '', migrated: false }], send);
    assert.equal(statuses.get('chain_agent'), '');
    assert.deepEqual(calls.map((c) => c.method), ['chain.read', 'work.read']);
  } finally { clearKeyringSession(); }
});

test('the genesis mirror accepts only the chain\'s own owner Bridge key as creator', () => {
  const owner = { account_id: 'acct', principal_id: 'brg_1', key_id: 'brg_key', public_key: '04' + 'a'.repeat(128), kind: 'bridge' as const, enrolled: true, revoked: false };
  const g: any = { creator_id: 'brg_1', creator_key_id: 'brg_key', owner_bridge_id: 'brg_1', owner_key_id: 'brg_key' };
  assert.equal(ownerGenesisBridgeCreator(g, 'brg_1', owner, owner), true);
  assert.equal(ownerGenesisBridgeCreator(g, 'brg_1', { ...owner, public_key: '04' + 'b'.repeat(128) }, owner), false, 'another key with the owner ids');
  assert.equal(ownerGenesisBridgeCreator({ ...g, creator_id: 'brg_2', creator_key_id: 'brg2_key' }, 'brg_1', { ...owner, principal_id: 'brg_2', key_id: 'brg2_key' }, owner), false, 'a foreign Bridge');
  assert.equal(ownerGenesisBridgeCreator(g, 'brg_2', owner, owner), false, 'a different recipient');
  assert.equal(ownerGenesisBridgeCreator(g, 'brg_1', { ...owner, kind: 'device' }, owner), false);
});

test('grant methods are gone: the app cannot sign grant.* at all', async () => {
  const { session, bridgeId } = await ownerTestSession();
  try {
    for (const method of ['grant.set', 'grant.revoke', 'grant.read', 'grant.policy', 'grant.recover']) {
      await assert.rejects(prepareOwnerOperation(session, bridgeId, method as any, { chainId: 'chain_a', expectedRevision: '0' }), undefined, method);
    }
  } finally { clearKeyringSession(); }
});

test('Bridge relay refusals other than authorization have their own text, not "no access"', () => {
  const noAccess = ownerErrorMessage(new Error('invalid_scope'));
  for (const code of ['account_mismatch', 'expired', 'stale_epoch', 'directory_unverified', 'vault_locked', 'owner_mismatch']) {
    const text = ownerErrorMessage(new Error(code));
    assert.notEqual(text, noAccess, code);
    assert.ok(!text.includes('refused the request ('), `${code} has dedicated text: ${text}`);
  }
});
