import './helpers/vaultEndpointHarness.ts';
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { instantToScheduleLocal, scheduleLocalToInstant } from '../src/ui/components/actions/scheduleDateTime.ts';

test('wall clocks convert using the schedule zone, including DST and fractional offsets', () => {
  assert.equal(scheduleLocalToInstant('2026-12-01T09:00', 'Asia/Kolkata'), '2026-12-01T09:00:00+05:30');
  assert.equal(scheduleLocalToInstant('2026-12-01T09:00', 'Asia/Kathmandu'), '2026-12-01T09:00:00+05:45');
  assert.equal(scheduleLocalToInstant('2026-07-01T09:00', 'America/New_York'), '2026-07-01T09:00:00-04:00');
  assert.equal(scheduleLocalToInstant('2026-12-01T09:00', 'America/New_York'), '2026-12-01T09:00:00-05:00');
  assert.equal(scheduleLocalToInstant('2026-12-01T00:00', 'UTC'), '2026-12-01T00:00:00+00:00');
  assert.equal(scheduleLocalToInstant('2026-12-01T09:00:12.123', 'Asia/Kolkata'), '2026-12-01T09:00:12.123+05:30');
  assert.equal(instantToScheduleLocal('2026-11-30T23:30:12.123Z', 'Asia/Kolkata'), '2026-12-01T05:00:12.123');
});

test('gaps reject, folds choose the earlier occurrence, invalid zones and dates reject', () => {
  assert.throws(() => scheduleLocalToInstant('2026-03-08T02:30', 'America/New_York'), /does not exist/);
  assert.equal(scheduleLocalToInstant('2026-11-01T01:30', 'America/New_York'), '2026-11-01T01:30:00-04:00');
  assert.throws(() => scheduleLocalToInstant('2026-12-01T09:00', 'Invalid/Zone'));
  assert.throws(() => scheduleLocalToInstant('2026-02-30T09:00', 'UTC'), /valid date/);
  assert.equal(scheduleLocalToInstant('', 'UTC'), '');
});
