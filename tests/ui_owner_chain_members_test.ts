// The conversation header's chain member switcher lists the Bridge-owned
// chain's own member rows: enabled members only, the coordinator first, then
// workers, then reviewers; a conversation whose agent is in no owner chain (or
// is not one of its enabled members) gets no switcher.
//
// RUN: node --import ./tests/helpers/vaultEndpointHarness.ts --test tests/ui_owner_chain_members_test.ts

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { ownerChainForAgent, ownerChainSwitcherMembers } from '../src/ui/api/ownerChainMembers.ts';
import type { OwnerChainSummary } from '../src/ui/api/ownerChains.ts';
import type { OwnerChainMember } from '../src/ui/api/ownerCoordinator.ts';

const summary = (chainId: string, coordinatorAgentInstanceId?: string): OwnerChainSummary => ({
  chainId, ownerBridgeId: 'brg_home', bridgeName: 'Home', online: true, title: chainId, description: '', sealed: false, tasks: [],
  projectId: '', projectName: '', migrated: false, coordinatorAgentInstanceId,
});
const member = (instanceId: string, role: string, enabled = true, agentId = `agt_${instanceId}`): OwnerChainMember => ({ instanceId, agentId, role, enabled });

test('orders the coordinator first, then workers, then reviewers, and drops disabled members', () => {
  const members = [
    member('rev1', 'reviewer'),
    member('wk1', 'worker'),
    member('old', 'coordinator', false),
    member('wk2', 'worker', false),
    member('coord', 'coordinator'),
    member('wk3', 'worker'),
    member('misc', 'observer'),
  ];
  const list = ownerChainSwitcherMembers({ chain: summary('chn_a', 'coord'), members, agentInstanceId: 'wk1', names: { agt_coord: 'Planner', agt_wk1: 'Builder' } });
  assert.deepEqual(list.map((m) => m.instanceId), ['coord', 'wk1', 'wk3', 'rev1', 'misc']);
  assert.deepEqual(list.map((m) => m.isCoordinator), [true, false, false, false, false]);
  // Display names from the agent identities, else the instance id.
  assert.deepEqual(list.map((m) => m.title), ['Planner', 'Builder', 'wk3', 'rev1', 'misc']);
});

test('the bound coordinator leads even before its member row is read', () => {
  const list = ownerChainSwitcherMembers({ chain: summary('chn_a', 'coord'), members: [member('wk1', 'worker')], agentInstanceId: 'wk1' });
  assert.deepEqual(list.map((m) => [m.instanceId, m.role]), [['coord', 'coordinator'], ['wk1', 'worker']]);
});

test('a coordinator being replaced follows the bound coordinator', () => {
  const list = ownerChainSwitcherMembers({ chain: summary('chn_a', 'coord_new'), members: [member('wk1', 'worker'), member('coord_old', 'coordinator'), member('coord_new', 'coordinator')], agentInstanceId: 'wk1' });
  assert.deepEqual(list.map((m) => [m.instanceId, m.isCoordinator]), [['coord_new', true], ['coord_old', false], ['wk1', false]]);
});

test('without a known coordinator the coordinator role leads', () => {
  const list = ownerChainSwitcherMembers({ chain: summary('chn_a'), members: [member('wk1', 'worker'), member('coord', 'coordinator')], agentInstanceId: 'coord' });
  assert.deepEqual(list.map((m) => m.instanceId), ['coord', 'wk1']);
  assert.equal(list[0].isCoordinator, true);
});

test('no switcher outside an owner chain, before members load, or for a non-member', () => {
  const members = [member('coord', 'coordinator'), member('wk1', 'worker'), member('gone', 'worker', false)];
  assert.deepEqual(ownerChainSwitcherMembers({ chain: undefined, members, agentInstanceId: 'wk1' }), []);
  assert.deepEqual(ownerChainSwitcherMembers({ chain: summary('chn_a', 'coord'), members: null, agentInstanceId: 'wk1' }), []);
  assert.deepEqual(ownerChainSwitcherMembers({ chain: summary('chn_a', 'coord'), members, agentInstanceId: 'stranger' }), []);
  assert.deepEqual(ownerChainSwitcherMembers({ chain: summary('chn_a', 'coord'), members, agentInstanceId: 'gone' }), []);
});

test('resolves the owner chain from the conversation chain id, else from the bound coordinator', () => {
  const chains = [summary('chn_a', 'coord_a'), summary('chn_b', 'coord_b')];
  assert.equal(ownerChainForAgent(chains, 'wk1', 'chn_b')?.chainId, 'chn_b');
  assert.equal(ownerChainForAgent(chains, 'coord_a', '')?.chainId, 'chn_a');
  // A Hub-only (non-owner) chain id falls back to the coordinator lookup.
  assert.equal(ownerChainForAgent(chains, 'coord_b', 'chn_hub')?.chainId, 'chn_b');
  assert.equal(ownerChainForAgent(chains, 'wk1', 'chn_hub'), undefined);
  assert.equal(ownerChainForAgent(chains, '', ''), undefined);
});
