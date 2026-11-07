// R4b: Bridge-owned chains are listed from the owner registry (paged, sealed
// titles opened client-side); a migrated chain shows once, as an owner chain,
// and its frozen Hub copy only lends its project placement.
//
// RUN: node --import ./tests/helpers/vaultEndpointHarness.ts --test tests/ui_owner_chain_list_test.ts

import './helpers/vaultEndpointHarness.ts';
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { ownerTestSession, registryRow } from './helpers/ownerFakeRelay.ts';
import { loadOwnerChainSummaries, mergeOwnerChains, ownerChainListItem } from '../src/ui/api/ownerChains.ts';
import { filterOwnerChains } from '../src/ui/components/taskchain/OwnerChainsGroup.tsx';
import { homeChainsWithOwners } from '../src/ui/components/home/homeChainSearchLogic.ts';
import { clearKeyringSession } from '../src/ui/utils/vaultKeyringSession.ts';

test('owner chains are listed across registry pages with decrypted chain and task titles', async () => {
  const env = await ownerTestSession();
  const { session, bridgeId } = env;
  // 104 chains (more than one registry page), one with two tasks, one tombstoned.
  const rows: any[] = [];
  for (let i = 0; i < 104; i++) {
    const chainId = 'chain_' + String(i).padStart(3, '0');
    rows.push(await registryRow(session, { chainId, bridgeId, online: i % 2 === 0, chainTitle: `Owner chain ${i}` }));
  }
  rows.push(await registryRow(session, { chainId: 'chain_000', taskId: 'task_a', bridgeId, online: true, chainTitle: 'Owner chain 0', taskTitle: 'First ticket' }));
  rows.push(await registryRow(session, { chainId: 'chain_000', taskId: 'task_b', bridgeId, online: true, chainTitle: 'Owner chain 0', taskTitle: 'Second ticket' }));
  rows.push(await registryRow(session, { chainId: 'chain_000', taskId: 'task_gone', bridgeId, online: true, taskTitle: 'Deleted', deleted: true }));
  rows.push(await registryRow(session, { chainId: 'chain_zzz', bridgeId, online: true, chainTitle: 'Deleted chain', deleted: true }));
  rows.sort((a, b) => a.chain_id.localeCompare(b.chain_id) || a.task_id.localeCompare(b.task_id));
  const paths: string[] = [];
  const fetchPage = async (path: string) => {
    paths.push(path);
    const q = new URL(path, 'https://hub.example.test').searchParams;
    assert.equal(q.get('page'), '1');
    const start = rows.findIndex((r) => r.chain_id > q.get('after_chain')! || (r.chain_id === q.get('after_chain') && r.task_id > q.get('after_task')!));
    const items = rows.slice(start, start + 100);
    const terminal = start + 100 >= rows.length;
    const last = items.at(-1)!;
    return { items, next_cursor: terminal ? { after_chain: '', after_task: '' } : { after_chain: last.chain_id, after_task: last.task_id }, terminal };
  };
  const chains = await loadOwnerChainSummaries(session, fetchPage);
  assert.equal(paths.length, 2, 'the registry is paged past 100 rows');
  assert.equal(chains.length, 104, 'tombstoned chains are not listed');
  const first = chains.find((c) => c.chainId === 'chain_000')!;
  assert.equal(first.title, 'Owner chain 0');
  assert.deepEqual(first.tasks.map((t) => t.title), ['First ticket', 'Second ticket']);
  assert.equal(first.bridgeName, 'Home Bridge', 'the owner Bridge is named by its enrolled label');
  assert.equal(first.online, true);
  assert.equal(chains.find((c) => c.chainId === 'chain_103')!.online, false);
  assert.equal(chains.find((c) => c.chainId === 'chain_103')!.title, 'Owner chain 103');
  assert.equal(first.sealed, false);
  const item = ownerChainListItem(first);
  assert.equal(item.taskCount, 2);
  assert.equal(item.owner.ownerBridgeId, bridgeId);
  clearKeyringSession();
});

test('a migrated chain shows once as an owner chain and keeps its Hub project', async () => {
  const owner = { chainId: 'moved', ownerBridgeId: 'brg', bridgeName: 'Home', online: true, title: 'Moved chain', description: '', sealed: false, tasks: [], projectId: '', projectName: '', migrated: false };
  const native = { ...owner, chainId: 'native', title: 'Native chain' };
  const hub = [
    { chainId: 'moved', projectId: 'proj_1', projectName: 'Apollo', title: 'frozen copy' },
    { chainId: 'legacy', projectId: 'proj_2', projectName: 'Zeus', title: 'Hub chain' },
  ];
  const merged = mergeOwnerChains(hub, [owner, native]);
  assert.deepEqual(merged.hub.map((c) => c.chainId), ['legacy'], 'the frozen Hub copy is dropped');
  const moved = merged.owners.find((o) => o.chainId === 'moved')!;
  assert.equal(moved.migrated, true);
  assert.equal(moved.projectId, 'proj_1');
  assert.equal(moved.projectName, 'Apollo');
  assert.equal(merged.owners.find((o) => o.chainId === 'native')!.migrated, false);

  const home = homeChainsWithOwners(
    [{ chainId: 'moved', title: 'frozen', status: 'active', projectId: 'proj_1', projectName: 'Apollo', updatedAt: '2026-01-01' },
     { chainId: 'legacy', title: 'Hub chain', status: 'active', projectId: '', projectName: '', updatedAt: '2026-01-02' }],
    [owner, native],
  );
  assert.deepEqual(home.map((c) => c.chainId), ['moved', 'native', 'legacy'], 'owner chains first, each chain once');
  assert.equal(home[0].title, 'Moved chain');
  assert.equal(home[0].projectName, 'Apollo');
  assert.deepEqual(home[0].owner, { bridgeId: 'brg', bridgeName: 'Home', online: true });
  assert.equal(home[2].owner, undefined);
});

test('chain list filters apply to owner chains where the registry allows', () => {
  const base = { ownerBridgeId: 'brg', bridgeName: 'Home', online: true, description: '', sealed: false, projectName: '', migrated: false };
  const chains = [
    { ...base, chainId: 'a', title: 'Alpha', tasks: [{ taskId: 't', title: 'Login bug' }], projectId: 'proj_1' },
    { ...base, chainId: 'b', title: 'Beta', tasks: [], projectId: '' },
  ];
  const f = { query: '', status: 'active' as const, projectId: '', onlyWithTasks: false, kind: 'all' as const };
  assert.deepEqual(filterOwnerChains(chains, f).map((c) => c.chainId), ['a', 'b']);
  assert.deepEqual(filterOwnerChains(chains, { ...f, onlyWithTasks: true }).map((c) => c.chainId), ['a']);
  assert.deepEqual(filterOwnerChains(chains, { ...f, projectId: 'proj_1' }).map((c) => c.chainId), ['a']);
  assert.deepEqual(filterOwnerChains(chains, { ...f, query: 'login' }).map((c) => c.chainId), ['a'], 'task titles are searchable');
  assert.deepEqual(filterOwnerChains(chains, { ...f, status: 'archived' }), [], 'owner chains are never archived');
  assert.deepEqual(filterOwnerChains(chains, { ...f, projectId: 'proj_2' }), [], 'native chains (no project) are excluded under a project filter');
  assert.deepEqual(filterOwnerChains(chains, { ...f, kind: 'workflow' }), []);
});

test('list statuses come from online owners (bounded); completed chains leave Active, offline ones are unknown', async () => {
  const env = await ownerTestSession();
  const { readOwnerChainStatuses } = await import('../src/ui/api/ownerChains.ts');
  const { fakeOwner } = await import('./helpers/ownerFakeRelay.ts');
  const base = { ownerBridgeId: env.bridgeId, bridgeName: 'Home', description: '', sealed: false, tasks: [{ taskId: 't', title: 'x' }], projectId: '', projectName: '', migrated: false };
  const chains = Array.from({ length: 12 }, (_, i) => ({ ...base, chainId: 'c' + i, title: 'C' + i, online: i !== 11 }));
  let inFlight = 0, max = 0;
  const methods: string[] = [];
  const send = fakeOwner(env.session, async (call) => {
    methods.push(call.method);
    inFlight++; max = Math.max(max, inFlight); await new Promise((r) => setTimeout(r, 1)); inFlight--;
    if (call.command.chain_id === 'c10') return { code: 'storage_error' };
    return { chain_id: call.command.chain_id, status: call.command.chain_id === 'c3' ? 'completed' : 'active', publish_state: 'published', work_revision: '1', items: [], next_cursor: '', pending_proposal_id: '', pending_proposal: null };
  });
  try {
    const statuses = await readOwnerChainStatuses(env.session, chains, send);
    assert.ok(max <= 4, 'bounded concurrency');
    assert.ok(methods.every((m) => m === 'work.read'));
    assert.equal(methods.length, 11, 'the offline owner is not asked');
    assert.equal(statuses.get('c3'), 'completed');
    assert.equal(statuses.get('c0'), 'active');
    assert.equal(statuses.get('c10'), '', 'a failed read is unknown');
    assert.equal(statuses.has('c11'), false);
    const listed = chains.map((c) => ({ ...c, status: statuses.get(c.chainId) ?? '' }));
    const f = { query: '', status: 'active' as const, projectId: '', onlyWithTasks: false, kind: 'all' as const };
    const active = filterOwnerChains(listed, f).map((c) => c.chainId);
    assert.ok(!active.includes('c3') && active.includes('c11') && active.includes('c10'), 'completed leaves Active; unknown stays');
    assert.deepEqual(filterOwnerChains(listed, { ...f, status: 'completed' }).map((c) => c.chainId), ['c3']);
    assert.equal(filterOwnerChains(listed, { ...f, status: 'all' }).length, 12);
  } finally { clearKeyringSession(); }
});
