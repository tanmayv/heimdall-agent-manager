import { test } from 'node:test';
import assert from 'node:assert/strict';
import { agentStopReasonLabel } from '../src/ui/utils/agentStatus.ts';

test('agentStopReasonLabel names coordinator idle stops and stays silent otherwise', () => {
  assert.equal(agentStopReasonLabel('stopped', 'coordinator_idle_completed'), 'Stopped automatically: idle after its chain completed');
  assert.equal(agentStopReasonLabel('stopping', 'coordinator_idle'), 'Stopped automatically: no user activity');
  assert.equal(agentStopReasonLabel('stopped', 'bot_idle'), 'Stopped automatically: bot idle');
  assert.equal(agentStopReasonLabel('stopped', 'user_requested'), 'Stopped by you');
  assert.equal(agentStopReasonLabel('stopped', 'recovery_force_stop'), 'Stopped: recovery force stop');
  // A running instance, or a stop the Hub did not request, shows nothing.
  assert.equal(agentStopReasonLabel('running', 'coordinator_idle'), '');
  assert.equal(agentStopReasonLabel('stopped', ''), '');
  assert.equal(agentStopReasonLabel(undefined, undefined), '');
});
