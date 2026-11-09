// Agent `task-chain create`: the owner Bridge creates the chain with its own
// key, so no device holds a grant. Its owner store enables paired-root
// recovery from creation; the app recovers access automatically (the same
// signed grant.recover as the manual button) and retries the read, once.
// Device-created chains are never auto-recovered.
//
// RUN: node --import ./tests/helpers/vaultEndpointHarness.ts --test tests/ui_owner_auto_recover_test.ts

import './helpers/vaultEndpointHarness.ts';
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { fakeOwner, ownerTestSession, registryRow, type OwnerCall } from './helpers/ownerFakeRelay.ts';
import { loadOwnerChainSummaries, readOwnerChain, readOwnerChainStatuses, resetOwnerRecoveryAttempts, withOwnerRecovery } from '../src/ui/api/ownerChains.ts';
import { ownerGenesisBridgeCreator } from '../src/ui/api/ownerLocal.ts';
import { clearKeyringSession } from '../src/ui/utils/vaultKeyringSession.ts';

function grantedOwner(session: any, granted: Set<string>, calls: OwnerCall[]) {
  return fakeOwner(session, (call) => {
    const chain = call.command.chain_id;
    if (call.method === 'grant.read') return { revision: '4', policy_revision: '1', recovery_enabled: '1', next_cursor: '', grants: [] };
    if (call.method === 'grant.recover') { granted.add(chain); return { chain_id: chain, task_id: '', operation_id: call.command.operation_id, revision: '5' }; }
    if (!granted.has(chain)) return { code: 'invalid_scope' };
    if (call.method === 'work.read') return { chain_id: chain, status: 'active', publish_state: 'published', work_revision: '1', items: [], next_cursor: '', pending_proposal_id: '', pending_proposal: null };
    return { title: 'Agent chain', description: '', revision: '5', items: [], next_cursor: '' };
  }, calls);
}

test('the registry marks chains created by their owner Bridge', async () => {
  const { session, bridgeId } = await ownerTestSession();
  try {
    const rows = [
      { ...(await registryRow(session, { chainId: 'chain_a', bridgeId, online: true })), creator_id: bridgeId },
      { ...(await registryRow(session, { chainId: 'chain_b', bridgeId, online: true })), creator_id: session.identity.deviceId },
      await registryRow(session, { chainId: 'chain_c', bridgeId, online: true }),
    ];
    const chains = await loadOwnerChainSummaries(session, async () => ({ items: rows, next_cursor: { after_chain: '', after_task: '' }, terminal: true }));
    assert.deepEqual(chains.map((c) => [c.chainId, c.bridgeCreated]), [['chain_a', true], ['chain_b', false], ['chain_c', false]]);
  } finally { clearKeyringSession(); }
});

test('a Bridge-created chain is recovered once by the paired root, then read', async () => {
  const { session, bridgeId } = await ownerTestSession();
  resetOwnerRecoveryAttempts();
  try {
    const granted = new Set<string>(), calls: OwnerCall[] = [];
    const send = grantedOwner(session, granted, calls);
    const chain = { chainId: 'chain_agent', ownerBridgeId: bridgeId, bridgeCreated: true };
    const detail = await withOwnerRecovery(session, chain, () => readOwnerChain(session, bridgeId, chain.chainId, send), send);
    assert.equal(detail.title, 'Agent chain');
    assert.deepEqual(calls.map((c) => c.method), ['chain.read', 'grant.read', 'grant.recover', 'chain.read']);
    const recover = calls[2];
    assert.equal(recover.command.expected_revision, '4', 'recovery is bound to the current chain revision');
    assert.equal(recover.payload.principal_id, session.identity.deviceId, 'the grant is for this device');
    assert.equal(recover.payload.can_read, '1');
    assert.ok(BigInt(recover.payload.expires_ms) - BigInt(Date.now()) <= 2592000000n, 'within the 30-day grant bound');
    // Once per chain: a later refusal is not retried with another recovery.
    granted.clear(); calls.length = 0;
    await assert.rejects(withOwnerRecovery(session, chain, () => readOwnerChain(session, bridgeId, chain.chainId, send), send), /invalid_scope/);
    assert.deepEqual(calls.map((c) => c.method), ['chain.read']);
  } finally { clearKeyringSession(); }
});

test('device-created chains and non-root devices are never auto-recovered', async () => {
  const { session, bridgeId } = await ownerTestSession();
  resetOwnerRecoveryAttempts();
  try {
    const granted = new Set<string>(), calls: OwnerCall[] = [];
    const send = grantedOwner(session, granted, calls);
    const device = { chainId: 'chain_device', ownerBridgeId: bridgeId, bridgeCreated: false };
    await assert.rejects(withOwnerRecovery(session, device, () => readOwnerChain(session, bridgeId, device.chainId, send), send), /invalid_scope/);
    const notRoot = { ...session, chain: { ...session.chain, rootDeviceId: 'dev_other_root' } };
    const agent = { chainId: 'chain_agent', ownerBridgeId: bridgeId, bridgeCreated: true };
    await assert.rejects(withOwnerRecovery(notRoot, agent, () => readOwnerChain(notRoot, bridgeId, agent.chainId, send), send), /invalid_scope/);
    assert.deepEqual(calls.map((c) => c.method), ['chain.read', 'chain.read'], 'no grant operation was attempted');
  } finally { clearKeyringSession(); }
});

test('the chain listing recovers Bridge-created chains while reading their status', async () => {
  const { session, bridgeId } = await ownerTestSession();
  resetOwnerRecoveryAttempts();
  try {
    const granted = new Set<string>(['chain_device']), calls: OwnerCall[] = [];
    const send = grantedOwner(session, granted, calls);
    const base = { ownerBridgeId: bridgeId, bridgeName: 'Home', online: true, description: '', sealed: false, tasks: [], projectId: '', projectName: '', migrated: false };
    const statuses = await readOwnerChainStatuses(session, [
      { ...base, chainId: 'chain_agent', title: 'A', bridgeCreated: true },
      { ...base, chainId: 'chain_device', title: 'D', bridgeCreated: false },
    ], send);
    assert.equal(statuses.get('chain_agent'), 'active');
    assert.equal(statuses.get('chain_device'), 'active');
    assert.equal(calls.filter((c) => c.method === 'grant.recover').map((c) => c.command.chain_id).join(), 'chain_agent');
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
