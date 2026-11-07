// R4b: local (Bridge-owned) search keeps every hit of a chain, grouped; walks
// the paged owner registry past 100 chains; and applies project/status filters
// to local hits where owner metadata allows, labelling the rest.
//
// RUN: node --import ./tests/helpers/vaultEndpointHarness.ts --test tests/ui_owner_search_test.ts

import './helpers/vaultEndpointHarness.ts';
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { fakeOwner, ownerTestSession, registryRow, type OwnerCall } from './helpers/ownerFakeRelay.ts';
import { decryptVaultText } from '../src/ui/utils/vaultContent.ts';
import { clearKeyringSession } from '../src/ui/utils/vaultKeyringSession.ts';
import { limitHitsByChain, searchOwnerChains } from '../src/ui/api/ownerSearchClient.ts';
import { filterOwnerSearchHits, searchTaskChainsEncrypted } from '../src/ui/utils/taskChainSearch.ts';
import { homeChainsFromSearchHits } from '../src/ui/components/home/homeChainSearchLogic.ts';

const CHAINS = 130;
const id = (i: number) => 'chain_' + String(i).padStart(3, '0');

async function ownerWorld() {
  const env = await ownerTestSession();
  const rows: any[] = [];
  for (let i = 0; i < CHAINS; i++) rows.push(await registryRow(env.session, { chainId: id(i), bridgeId: env.bridgeId, online: i !== 7, chainTitle: `Chain ${i}` }));
  const calls: OwnerCall[] = [];
  let inFlight = 0, maxInFlight = 0;
  const send = fakeOwner(env.session, async (call) => {
    inFlight++; maxInFlight = Math.max(maxInFlight, inFlight);
    await new Promise((r) => setTimeout(r, 1));
    inFlight--;
    assert.equal(call.method, 'chain.search');
    assert.equal(await decryptVaultText(call.payload.query_cipher, env.session.keyring), 'needle', 'the query crosses the Hub sealed');
    const chain = call.command.chain_id;
    const hit = (kind: string, extra: Record<string, string> = {}) => ({ chain_id: chain, task_id: '', kind, object_id: kind, object_revision: '1', attempt: '', title: '', description: 'needle snippet', ...extra });
    if (chain === id(5)) return { indexed_seq: '9', revision: '0', hits: [
      hit('task', { task_id: 'task_a', object_id: 'task_a', title: 'Fix login' }),
      hit('output', { task_id: 'task_a', object_id: 'task_a:2', object_revision: '2', attempt: '2' }),
      hit('comment', { task_id: 'task_a', object_id: 'p:op' }),
      hit('chain', { object_id: chain, title: 'Chain 5' }),
    ] };
    if (chain === id(120)) return { indexed_seq: '9', revision: '0', hits: [hit('archived_task', { task_id: 'task_stage', object_id: 'task_stage', title: 'deployprobe' })] };
    if (chain === id(64)) return { code: 'invalid_scope' };
    return { indexed_seq: '9', revision: '0', hits: [] };
  }, calls);
  return { env, rows, calls, send, maxInFlight: () => maxInFlight };
}

test('owner search covers more than 100 chains and keeps every hit of a chain, grouped', async () => {
  const w = await ownerWorld();
  try {
    const result = await searchOwnerChains(w.env.session, w.rows, 'needle', 20, w.send);
    assert.equal(w.calls.length, CHAINS - 1, 'every online chain is queried, offline ones are skipped');
    assert.ok(w.maxInFlight() <= 4, 'bounded concurrency');
    assert.equal(result.stale, true, 'an offline owner marks the result stale');
    assert.equal(result.ownedIds.size, CHAINS);
    assert.deepEqual(result.hits.map((h) => [h.chain_id, h.kind]), [
      [id(5), 'chain'], [id(5), 'task'], [id(5), 'comment'], [id(5), 'output'], [id(120), 'archived_task'],
    ]);
    const output = result.hits.find((h) => h.kind === 'output')!;
    assert.equal(output.title, 'Chain 5 — submission attempt 2');
    assert.equal(result.hits.find((h) => h.kind === 'task')!.match_title, 'Fix login');
    assert.equal(result.hits[0].owner_bridge_id, w.env.bridgeId);
    // A limit counts chains, never cuts a chain's matches.
    assert.deepEqual(limitHitsByChain(result.hits, 1).map((h) => h.chain_id), [id(5), id(5), id(5), id(5)]);
  } finally { clearKeyringSession(); }
});

test('home rows show each match of a chain under one chain heading', () => {
  const base = { project_id: '', status: '', updated_at: '', description: '' };
  const rows = homeChainsFromSearchHits([
    { ...base, chain_id: 'c1', kind: 'task', task_id: 't1', title: 'Chain one', match_title: 'Fix login', owner_bridge_id: 'brg', owner_online: true },
    { ...base, chain_id: 'c1', kind: 'comment', task_id: 't1', title: 'Chain one', match_title: '', owner_bridge_id: 'brg', owner_online: true, filters_unverified: ['status'] },
    { ...base, chain_id: 'c2', title: 'Hub chain' },
  ], []);
  assert.deepEqual(rows.map((r) => [r.chainId, r.firstInGroup, r.matchLabel]), [
    ['c1', true, 'Ticket: Fix login'], ['c1', false, 'Comment (status not checked)'], ['c2', true, ''],
  ]);
  assert.equal(new Set(rows.map((r) => r.rowKey)).size, 3, 'each row has its own key');
  assert.deepEqual(rows[0].owner, { bridgeId: 'brg', bridgeName: 'brg', online: true });
  assert.equal(rows[2].owner, undefined);
  assert.equal(homeChainsFromSearchHits([...Array(12)].map((_, i) => ({ ...base, chain_id: 'x' + i, title: 't' })), [], 10).length, 10);
});

test('project and status filters apply to local hits where owner metadata allows', () => {
  const hit = (chain_id: string) => ({ chain_id, project_id: '', status: '', updated_at: '', title: 'T', description: '', kind: 'task' });
  const hits = [hit('moved'), hit('native')];
  assert.deepEqual(filterOwnerSearchHits(hits, {}), hits);
  assert.deepEqual(filterOwnerSearchHits(hits, { status: 'archived' }), [], 'owner chains are never archived');
  assert.deepEqual(filterOwnerSearchHits(hits, { status: 'active' }).map((h) => h.filters_unverified), [['status'], ['status']], 'kept and labelled');
  const projectOf = (c: string) => (c === 'moved' ? 'proj_1' : c === 'native' ? '' : undefined);
  assert.deepEqual(filterOwnerSearchHits(hits, { projectId: 'proj_1', projectOf }).map((h) => [h.chain_id, h.filters_unverified]), [['moved', undefined]]);
  assert.deepEqual(filterOwnerSearchHits([hit('unknown')], { projectId: 'proj_1', projectOf }).map((h) => h.filters_unverified), [['project']]);
  assert.deepEqual(filterOwnerSearchHits([hit('unknown')], { projectId: 'proj_1' }).map((h) => h.filters_unverified), [['project']]);
});

test('the combined search pages the owner registry and filters local hits', async () => {
  const w = await ownerWorld();
  const saved = globalThis.fetch;
  const registryPaths: string[] = [];
  const sorted = [...w.rows].sort((a, b) => a.chain_id.localeCompare(b.chain_id));
  globalThis.fetch = (async (input: any, init: any = {}) => {
    const u = new URL(String(input?.url ?? input), 'https://hub.example.test');
    const ok = (data: unknown) => new Response(JSON.stringify({ data }), { status: 200, headers: { 'Content-Type': 'application/json' } });
    if (u.pathname === '/api/v1/vault/directory') return ok(w.env.hub.dir());
    if (u.pathname === '/api/v1/owner-local/chains') {
      registryPaths.push(u.search);
      assert.equal(u.searchParams.get('headers_only'), '1');
      assert.equal(u.searchParams.get('page'), '1', 'the paged registry, not the 100-row listing');
      const after = u.searchParams.get('after_chain') || '';
      const start = after ? sorted.findIndex((r) => r.chain_id > after) : 0;
      const items = sorted.slice(start, start + 100);
      const terminal = start + 100 >= sorted.length;
      return ok({ items, next_cursor: terminal ? { after_chain: '', after_task: '' } : { after_chain: items.at(-1).chain_id, after_task: '' }, terminal });
    }
    if (u.pathname === '/api/v1/owner-local/relay') return ok(await w.send(JSON.parse(init.body)));
    if (u.pathname === '/api/v1/bridges') return ok([]);
    return new Response('{}', { status: 404 });
  }) as typeof fetch;
  try {
    const user = w.env.session.identity.userId;
    const all = await searchTaskChainsEncrypted('needle', user, { limit: 20 });
    assert.equal(registryPaths.length, 2);
    assert.deepEqual([...new Set(all.hits.map((h) => h.chain_id))], [id(5), id(120)], 'chain 120 is found past the first registry page');
    assert.equal(all.hits.filter((h) => h.chain_id === id(5)).length, 4);
    const archived = await searchTaskChainsEncrypted('needle', user, { limit: 20, status: 'archived' });
    assert.deepEqual(archived.hits, []);
    const active = await searchTaskChainsEncrypted('needle', user, { limit: 20, status: 'active' });
    assert.equal(active.hits.length, 5, 'unverifiable status keeps local hits');
    assert.ok(active.hits.every((h) => h.filters_unverified?.includes('status')));
    const project = await searchTaskChainsEncrypted('needle', user, { limit: 20, projectId: 'proj_1', projectOf: (c) => (c === id(120) ? 'proj_1' : '') });
    assert.deepEqual([...new Set(project.hits.map((h) => h.chain_id))], [id(120)]);
  } finally {
    globalThis.fetch = saved;
    clearKeyringSession();
  }
});
