import './helpers/vaultEndpointHarness.ts';
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { runRowText, RUN_REASON_TEXT } from '../src/ui/components/actions/RunHistory.tsx';
const base: any = { not_before: '2026-12-01T09:00:00Z', joined_run_id: 'arun_12345678901234', joined_count: 0, delivery_expires_at: '2026-12-02T09:00:00Z' };
test('all seven run states have the required text', () => {
  assert.equal(runRowText({ ...base, state: 'queued' }), 'Waiting');
  assert.equal(runRowText({ ...base, state: 'deferred' }), 'Deferred until ' + base.not_before);
  assert.equal(runRowText({ ...base, state: 'routed' }, 'Laptop'), 'Sent to Laptop, waiting for it · expires ' + base.delivery_expires_at);
  assert.equal(runRowText({ ...base, state: 'delivered', joined_count: 3 }), 'Delivered · +3 merged');
  assert.equal(runRowText({ ...base, state: 'joined' }), 'Merged into arun_1234567');
  for (const state of ['skipped', 'failed']) for (const [reason, expected] of Object.entries(RUN_REASON_TEXT)) assert.equal(runRowText({ ...base, state, reason }), expected);
});
test('v7 delivery failure reasons have exact wording', () => {
  assert.deepEqual(Object.fromEntries(['bridge_offline', 'no_answer', 'start_failed', 'bridge_too_old', 'no_placement', 'target_missing', 'delivery_failed'].map(k => [k, RUN_REASON_TEXT[k]])), {
    bridge_offline: 'The machine stayed offline', no_answer: 'The machine did not answer', start_failed: 'The agent could not be started on that machine', bridge_too_old: "The machine's bridge needs an update", no_placement: 'No machine matched the rules', target_missing: 'The target no longer exists', delivery_failed: 'The prompt could not be stored',
  });
});
