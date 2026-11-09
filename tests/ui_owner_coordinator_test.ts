// Owner chain coordinators (native and imported chains): the bound coordinator
// is read from chain.metadata.read member rows, and Start coordinator launches
// on the owner Bridge, waits until the instance runs, then binds it.
//
// RUN: node --import ./tests/helpers/vaultEndpointHarness.ts --test tests/ui_owner_coordinator_test.ts

import './helpers/vaultEndpointHarness.ts';
import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  coordinatorFromMetadataItems, createdInstanceId, scanOwnerChainCoordinator, startOwnerCoordinator, type OwnerMetadataItem,
} from '../src/ui/api/ownerCoordinator.ts';
import { ownerChainListItem, type OwnerChainSummary } from '../src/ui/api/ownerChains.ts';

const member = (seq: number, instanceId: string, role: string, enabled = '1', current = '1'): OwnerMetadataItem => ({
  kind: 'member', accepted_seq: String(seq), entity_id: instanceId, enabled, current,
  body: JSON.stringify({ instance_id: instanceId, agent_id: 'agt_' + instanceId, role }),
});

test('the bound coordinator is the latest current, enabled coordinator member row', () => {
  assert.equal(coordinatorFromMetadataItems([]), '');
  assert.equal(coordinatorFromMetadataItems([
    { kind: 'summary', accepted_seq: '9', body: 'x', entity_id: '', enabled: '', current: '1' },
    member(8, 'inst_worker', 'worker'),
    member(7, 'inst_old', 'coordinator', '1', '0'),   // superseded version
    member(6, 'inst_off', 'coordinator', '0', '1'),   // disabled
  ]), '');
  assert.equal(coordinatorFromMetadataItems([member(4, 'inst_a', 'coordinator'), member(5, 'inst_b', 'coordinator')]), 'inst_b');
  assert.equal(coordinatorFromMetadataItems([{ ...member(3, 'inst_bad', 'coordinator'), body: '{' }]), '', 'unparsable bodies are skipped');
});

test('the coordinator scan pages chain.metadata.read until it finds one, bounded', async () => {
  const pages: Record<string, { items: OwnerMetadataItem[]; next_cursor: string }> = {
    '': { items: [member(10, 'inst_w', 'worker')], next_cursor: 'c1' },
    c1: { items: [member(9, 'inst_coord', 'coordinator')], next_cursor: 'c2' },
    c2: { items: [member(1, 'inst_never', 'coordinator')], next_cursor: '' },
  };
  const seen: string[] = [];
  const read = async (cursor: string) => { seen.push(cursor); return pages[cursor]; };
  assert.equal(await scanOwnerChainCoordinator(read), 'inst_coord');
  assert.deepEqual(seen, ['', 'c1'], 'stops at the first (latest) binding');
  // An imported chain with only archive rows and no binding has none.
  assert.equal(await scanOwnerChainCoordinator(async () => ({ items: [], next_cursor: '' })), '');
  let calls = 0;
  assert.equal(await scanOwnerChainCoordinator(async () => { calls += 1; return { items: [], next_cursor: 'again' }; }, 3), '');
  assert.equal(calls, 3, 'the scan is bounded');
});

test('owner chain list rows carry the bound coordinator', () => {
  const summary: OwnerChainSummary = {
    chainId: 'chain_imp', ownerBridgeId: 'brg_owner', bridgeName: 'Owner', online: true, title: 'Imported', description: '',
    sealed: false, tasks: [], projectId: '', projectName: '', migrated: true,
  };
  assert.equal(ownerChainListItem(summary).coordinatorAgentInstanceId, '');
  assert.equal(ownerChainListItem({ ...summary, coordinatorAgentInstanceId: 'inst_coord' }).coordinatorAgentInstanceId, 'inst_coord');
});

test('start coordinator launches, waits until running, binds, then restarts it with the coordinator role', async () => {
  const log: string[] = [];
  const statuses = ['starting', '', 'running', 'launching', 'running'];
  let clock = 0;
  const id = await startOwnerCoordinator({
    launch: async () => { log.push('launch'); return 'inst_new'; },
    status: async (instanceId) => { log.push('status:' + instanceId); return statuses.shift() ?? 'running'; },
    bind: async (instanceId) => { log.push('bind:' + instanceId); },
    restart: async (instanceId) => { log.push('restart:' + instanceId); },
    onStage: (stage) => log.push('stage:' + stage),
    sleep: async (ms) => { clock += ms; },
    now: () => clock,
  });
  assert.equal(id, 'inst_new');
  assert.deepEqual(log, [
    'stage:launching', 'launch', 'stage:waiting', 'status:inst_new', 'status:inst_new', 'status:inst_new', 'stage:binding', 'bind:inst_new',
    'stage:restarting', 'restart:inst_new', 'status:inst_new', 'status:inst_new', 'stage:done',
  ]);
});

test('start coordinator reports a relaunch that fails after the bind', async () => {
  const statuses = ['running', 'failed'];
  let restarted = 0;
  await assert.rejects(startOwnerCoordinator({
    launch: async () => 'inst_re', status: async () => statuses.shift() ?? 'failed', bind: async () => {},
    restart: async () => { restarted += 1; }, sleep: async () => {},
  }), /failed before it restarted/);
  assert.equal(restarted, 1);
});

test('start coordinator never binds an instance that failed or did not start in time', async () => {
  let bound = 0;
  await assert.rejects(startOwnerCoordinator({
    launch: async () => 'inst_fail', status: async () => 'failed', bind: async () => { bound += 1; }, restart: async () => {}, sleep: async () => {},
  }), /failed before it started/);
  let clock = 0;
  await assert.rejects(startOwnerCoordinator({
    launch: async () => 'inst_slow', status: async () => 'starting', bind: async () => { bound += 1; }, restart: async () => {},
    sleep: async (ms) => { clock += ms; }, now: () => clock,
  }, 10_000), /did not start in time/);
  await assert.rejects(startOwnerCoordinator({
    launch: async () => '', status: async () => 'running', bind: async () => { bound += 1; }, restart: async () => {}, sleep: async () => {},
  }), /not created/);
  assert.equal(bound, 0);
});

test('the created instance id is read from the Hub reply shapes', () => {
  assert.equal(createdInstanceId({ agent_instance_id: 'inst_1' }), 'inst_1');
  assert.equal(createdInstanceId({ instance: { agent_instance_id: 'inst_2' } }), 'inst_2');
  assert.equal(createdInstanceId({ data: { agent_instance_id: 'inst_3' } }), 'inst_3');
  assert.equal(createdInstanceId({}), '');
});
