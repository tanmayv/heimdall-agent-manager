import { test } from 'node:test';
import assert from 'node:assert/strict';
import { applyRuntimeConfiguration } from '../src/ui/utils/applyRuntimeConfiguration.ts';

test('active Apply reconfigures once without requesting a second launch', async () => {
  const calls: string[] = [];
  await applyRuntimeConfiguration(false, async () => { calls.push('patch'); }, async () => { calls.push('start'); });
  assert.deepEqual(calls, ['patch']);
});
test('stopped Apply starts only after configuration is saved', async () => {
  const calls: string[] = [];
  await applyRuntimeConfiguration(true, async () => { calls.push('patch'); }, async () => { calls.push('start'); });
  assert.deepEqual(calls, ['patch', 'start']);
});
test('failed configuration never starts and propagates failure', async () => {
  let started = false;
  await assert.rejects(applyRuntimeConfiguration(true, async () => { throw new Error('offline'); }, async () => { started = true; }), /offline/);
  assert.equal(started, false);
});
test('failed startup is not reported as applied successfully', async () => {
  await assert.rejects(applyRuntimeConfiguration(true, async () => {}, async () => { throw new Error('spawn failed'); }), /spawn failed/);
});
