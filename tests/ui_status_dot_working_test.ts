import assert from 'node:assert/strict';

// H13: the sidebar status dot animates ONLY when the agent is actually working
// (runtime live AND activity_status in {active,busy,working}); a live-but-idle
// agent renders a static dot. This unit-tests the pure isAgentWorking predicate
// that drives StatusDot's animate-pulse + data-working attribute.

import { isAgentWorking } from '../src/ui/components/shell/agentWorking';

// Live + working activity => working (dot pulses).
assert.equal(isAgentWorking('live', 'active'), true, 'live+active => working');
assert.equal(isAgentWorking('live', 'busy'), true, 'live+busy => working');
assert.equal(isAgentWorking('live', 'working'), true, 'live+working => working');
assert.equal(isAgentWorking('live', 'ACTIVE'), true, 'case-insensitive');

// Live + idle (or unknown/empty) => NOT working (static dot).
assert.equal(isAgentWorking('live', 'idle'), false, 'live+idle => static, not working');
assert.equal(isAgentWorking('live', ''), false, 'live+empty => static');
assert.equal(isAgentWorking('live', undefined), false, 'live+undefined => static');

// Non-live runtime never counts as working regardless of stale activity.
assert.equal(isAgentWorking('starting', 'active'), false, 'starting is not working');
assert.equal(isAgentWorking('stopped', 'active'), false, 'stopped is not working (stale activity ignored)');
assert.equal(isAgentWorking('', 'active'), false, 'unknown state is not working');

console.log('ui_status_dot_working_test: ok');
