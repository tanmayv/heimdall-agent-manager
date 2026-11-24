import './helpers/vaultEndpointHarness.ts';
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { triggerSummary } from '../src/ui/components/actions/scheduleUtils.ts';
test('one pill summarizes cron, interval, once, preset and plain event', () => {
  const summarize = (kind: string, config: any) => triggerSummary({ kind, config, enabled: true } as any);
  assert.equal(summarize('schedule', { mode: 'cron', cron_expr: '0 9 * * 1-5', timezone: 'America/New_York' }), '0 9 * * 1-5 · New York');
  assert.equal(summarize('schedule', { mode: 'interval', interval_s: 3600 }), 'every 1 h');
  for (const [interval_s, label] of [[120, 'every 2 min'], [7200, 'every 2 h'], [86400, 'every 24 h'], [90, 'every 90 s']] as const) {
    assert.equal(summarize('schedule', { mode: 'interval', interval_s }), label);
  }
  assert.equal(summarize('schedule', { mode: 'once', run_at: '2026-12-01T09:00:00Z' }), 'once 2026-12-01 09:00 UTC');
  assert.equal(summarize('event', { event_type: 'chain.state', data: { state: 'completed' } }), 'Task chain completed');
  assert.equal(summarize('event', { event_type: 'chain.work_finished' }), 'chain.work_finished');
});
