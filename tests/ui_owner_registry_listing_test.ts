import { test } from 'node:test';
import assert from 'node:assert/strict';
import { listOwnerRegistryPages } from '../src/ui/api/ownerRegistryListing.ts';

test('registry traverses sparse and empty raw pages until explicit terminal, preserving all 105 tasks', async () => {
  const rows = Array.from({length: 106}, (_, i) => ({chain_id: 'chain', task_id: i ? 'task_' + String(i).padStart(3, '0') : ''}));
  for (const deleted of [false, true]) {
    const paths: string[] = [];
    const result = await listOwnerRegistryPages(async path => {
      paths.push(path);
      const q = new URL(path, 'http://fixture').searchParams;
      const start = q.get('after_task') === 'task_099' ? 100 : 0;
      const raw = rows.slice(start, start + 100);
      return {items: raw.filter(r => !deleted || !r.task_id || r.task_id === 'task_105'), next_cursor: {after_chain: 'chain', after_task: raw.at(-1)!.task_id}, terminal: start === 100};
    }, () => true);
    assert.equal(paths.length, 2);
    assert.equal(result.length, deleted ? 2 : 106);
    assert.equal(result.at(-1)?.task_id, 'task_105');
  }
  let calls = 0;
  assert.deepEqual(await listOwnerRegistryPages(async () => ++calls === 1
    ? {items: [], next_cursor: {after_chain: 'chain', after_task: 'task_099'}, terminal: false}
    : {items: [{task_id: 'last'}], next_cursor: {after_chain: '', after_task: ''}, terminal: true}, () => true), [{task_id: 'last'}]);
});

test('registry rejects stalled cursors and discards pages after session/account change', async () => {
  await assert.rejects(listOwnerRegistryPages(async () => ({items: [], next_cursor: {after_chain: '', after_task: ''}, terminal: false}), () => true), /did not advance/);
  let current = true;
  assert.deepEqual(await listOwnerRegistryPages(async () => {
    current = false;
    return {items: [{task_id: 'foreign'}], next_cursor: {after_chain: '', after_task: ''}, terminal: true};
  }, () => current), []);
});
