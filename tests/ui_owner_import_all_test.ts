import { test } from 'node:test';
import assert from 'node:assert/strict';
import { ApiError } from '../src/ui/api/cookieFetch.ts';
import { describeMigrationBlockers } from '../src/ui/api/ownerMigrationClient.ts';
import { importAllLegacyChains, listLegacyChains, type ImportAllProgress, type LegacyChain } from '../src/ui/api/ownerImportAll.ts';

function chain(id: string, state: LegacyChain['state'] = 'none', extra: Partial<LegacyChain> = {}): LegacyChain {
  return { chain_id: id, title: 'sealed:' + id, status: 'active', work_revision: 3, task_count: 2, state, migration_id: state === 'none' ? '' : 'mig_old_' + id, owner_bridge_id: state === 'none' ? '' : 'bridge_other', ...extra };
}

function harness(chains: LegacyChain[], opts: { failPost?: Set<string>; conflictOnce?: Set<string>; pageSize?: number; forcedHeld?: Record<string, string[]> } = {}) {
  const calls: string[] = [];
  const prepared: Array<[string, string, number]> = [];
  const conflicted = new Set<string>();
  const progress: ImportAllProgress[] = [];
  const pageSize = opts.pageSize ?? 200;
  const deps = {
    fetchJson: async (path: string) => {
      calls.push('GET ' + path);
      const url = new URL(path, 'http://hub');
      if (url.pathname === '/api/v1/owner-local/migrations/legacy-chains') {
        const after = url.searchParams.get('after') ?? '';
        const start = after ? chains.findIndex((c) => c.chain_id === after) + 1 : 0;
        const items = chains.slice(start, start + pageSize);
        const next = start + pageSize < chains.length ? items[items.length - 1].chain_id : '';
        return { items, next_after: next };
      }
      if (url.pathname === '/api/v1/owner-local/migrations/preflight') {
        return { chain_id: url.searchParams.get('chain_id'), state: 'none', migration_id: '', owner_bridge_id: '', work_revision: 9, blockers: null };
      }
      throw new Error('unexpected GET ' + path);
    },
    post: async (path: string, body: any) => {
      if (path === '/api/v1/owner-local/migrations/abort') { calls.push(`ABORT ${body.chain_id} ${body.migration_id}`); return {}; }
      if (path !== '/api/v1/owner-local/migrations') throw new Error('unexpected POST ' + path);
      const sel = JSON.parse(body.selection);
      calls.push(`IMPORT ${sel.chain_id} r${sel.rev}`);
      if (opts.failPost?.has(sel.chain_id)) throw new ApiError('owner Bridge rejected the import', 502, 'owner_unavailable');
      if (opts.conflictOnce?.has(sel.chain_id) && !conflicted.has(sel.chain_id)) {
        conflicted.add(sel.chain_id);
        throw new ApiError('work revision changed', 409, 'migration_conflict');
      }
      const forced = opts.forcedHeld?.[sel.chain_id] ?? [];
      return {
        state: 'imported', migration_id: 'mig_' + sel.chain_id, chain_id: sel.chain_id, manifest_digest: 'm', receipt_digest: 'r', replayed: false, activation_sent: true,
        neutralized: forced.length ? [{ code: 'tasks_force_held', count: forced.length, items: forced }, { code: 'live_leases_ended', count: 1 }] : null,
        forced_held: forced.length ? forced : null,
      };
    },
    prepare: async (chainId: string, bridgeId: string, rev: number) => {
      prepared.push([chainId, bridgeId, rev]);
      return { selection: JSON.stringify({ chain_id: chainId, rev }), genesis: '{}' };
    },
    decryptTitle: async (t: string) => {
      if (t === 'sealed:bad') throw new Error('cannot open');
      return t.replace('sealed:', 'Title ');
    },
    onProgress: (p: ImportAllProgress) => progress.push(p),
  };
  return { deps, calls, prepared, progress };
}

test('legacy chain listing pages with after/limit until next_after is empty', async () => {
  const chains = [chain('c1'), chain('c2'), chain('c3'), chain('c4'), chain('c5')];
  const { deps, calls } = harness(chains, { pageSize: 2 });
  const listed = await listLegacyChains(deps.fetchJson, 2);
  assert.deepEqual(listed.map((c) => c.chain_id), ['c1', 'c2', 'c3', 'c4', 'c5']);
  assert.deepEqual(calls, [
    'GET /api/v1/owner-local/migrations/legacy-chains?limit=2',
    'GET /api/v1/owner-local/migrations/legacy-chains?limit=2&after=c2',
    'GET /api/v1/owner-local/migrations/legacy-chains?limit=2&after=c4',
  ]);
});

test('import all skips imported chains, aborts unfinished moves first and imports the rest in order', async () => {
  const chains = [chain('c1'), chain('c2', 'imported'), chain('c3', 'frozen'), chain('c4', 'draining')];
  const { deps, calls, prepared } = harness(chains);
  const results = await importAllLegacyChains('bridge_a', deps);
  assert.deepEqual(results.map((r) => [r.chainId, r.outcome]), [['c1', 'imported'], ['c2', 'skipped'], ['c3', 'imported'], ['c4', 'imported']]);
  assert.equal(results[1].message, 'Already imported');
  assert.equal(results[0].title, 'Title c1');
  assert.deepEqual(calls.filter((c) => !c.startsWith('GET')), [
    'IMPORT c1 r3',
    'ABORT c3 mig_old_c3', 'IMPORT c3 r3',
    'ABORT c4 mig_old_c4', 'IMPORT c4 r3',
  ]);
  assert.ok(prepared.every(([, bridge]) => bridge === 'bridge_a'));
  assert.ok(!prepared.some(([id]) => id === 'c2'), 'imported chains are never re-signed');
});

test('a failing chain is recorded and the batch continues; titles fall back to the chain id', async () => {
  const chains = [chain('c1'), chain('bad'), chain('c3')];
  const { deps } = harness(chains, { failPost: new Set(['c1']) });
  const results = await importAllLegacyChains('bridge_a', deps);
  assert.deepEqual(results.map((r) => r.outcome), ['failed', 'imported', 'imported']);
  assert.equal(results[0].message, 'owner Bridge rejected the import');
  assert.equal(results[1].title, 'bad', 'undecryptable title falls back to chain id');
});

test('progress reports each chain then a final done snapshot', async () => {
  const chains = [chain('c1'), chain('c2', 'imported'), chain('c3')];
  const { deps, progress } = harness(chains);
  await importAllLegacyChains('bridge_a', deps);
  assert.deepEqual(progress.map((p) => [p.index, p.total, p.currentTitle, p.done, p.results.length]), [
    [1, 3, 'Title c1', false, 0],
    [2, 3, 'Title c2', false, 1],
    [3, 3, 'Title c3', false, 2],
    [3, 3, '', true, 3],
  ]);
});

test('force-held tasks and neutralized work are surfaced per chain', async () => {
  const { deps } = harness([chain('c1'), chain('c2')], { forcedHeld: { c1: ['task_a', 'task_b'] } });
  const results = await importAllLegacyChains('bridge_a', deps);
  assert.deepEqual(results[0].forcedHeld, ['task_a', 'task_b']);
  assert.deepEqual(results[1].forcedHeld, []);
  const text = describeMigrationBlockers(results[0].neutralized);
  assert.match(text[0], /^2 × in-progress tasks were held/);
  assert.match(text[1], /^1 × live leases were ended/);
});

test('a work-revision conflict re-reads preflight once and retries with the new revision', async () => {
  const { deps, calls } = harness([chain('c1')], { conflictOnce: new Set(['c1']) });
  const results = await importAllLegacyChains('bridge_a', deps);
  assert.equal(results[0].outcome, 'imported');
  assert.deepEqual(calls.filter((c) => !c.includes('legacy-chains')), [
    'IMPORT c1 r3',
    'GET /api/v1/owner-local/migrations/preflight?chain_id=c1',
    'IMPORT c1 r9',
  ]);
});

test('a second conflict fails that chain only; a changed vault session stops the batch', async () => {
  const { deps } = harness([chain('c1'), chain('c2')]);
  let posts = 0;
  const conflicting = { ...deps, post: async (path: string, body: any) => {
    if (path === '/api/v1/owner-local/migrations' && JSON.parse(body.selection).chain_id === 'c1') { posts++; throw new ApiError('conflict', 409, 'migration_conflict'); }
    return deps.post(path, body);
  } };
  const results = await importAllLegacyChains('bridge_a', conflicting);
  assert.equal(posts, 2);
  assert.deepEqual(results.map((r) => r.outcome), ['failed', 'imported']);

  let current = true;
  const stopping = { ...deps, isCurrent: () => current, onProgress: () => { current = false; } };
  await assert.rejects(importAllLegacyChains('bridge_a', stopping), /Vault session changed/);
});

test('an offline owner Bridge (409 bridge_offline) fails the chain without aborting its frozen move', async () => {
  const h = harness([chain('chain_off')]);
  const post = h.deps.post;
  h.deps.post = async (path: string, body: any) => {
    if (path === '/api/v1/owner-local/migrations') {
      h.calls.push('IMPORT chain_off');
      throw new ApiError('owner Bridge is offline', 409, 'bridge_offline');
    }
    return post(path, body);
  };
  const results = await importAllLegacyChains('bridge_1', h.deps);
  assert.equal(results[0].outcome, 'failed');
  assert.deepEqual(h.calls.filter((c) => c.startsWith('IMPORT') || c.startsWith('ABORT')), ['IMPORT chain_off']);
});
