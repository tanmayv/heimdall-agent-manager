import assert from 'node:assert/strict';

// H11: unit tests for the Send-test-notification button's PURE logic — the
// sample plan it fires and the always-shown in-app toast feedback message across
// every environment case (native fired / electron / unsupported / denied /
// default). The button itself always dispatches a toast (visible feedback) and,
// when supported+granted, also fires showNativeNotification with TEST_NOTIFICATION_PLAN.
import { TEST_NOTIFICATION_PLAN, testNotificationFeedback } from '../src/ui/components/settings/NotificationsPanel';

// --- The sample plan is a valid NotificationPlan with the test identity. ---
assert.equal(TEST_NOTIFICATION_PLAN.title, 'Heimdall test notification', 'plan title');
assert.ok(TEST_NOTIFICATION_PLAN.body.length > 0, 'plan has a body');
assert.equal(TEST_NOTIFICATION_PLAN.tag, 'heimdall-test', 'plan uses the heimdall-test coalescing tag');
assert.equal(TEST_NOTIFICATION_PLAN.category, 'attention', 'plan has a valid category');
assert.ok(TEST_NOTIFICATION_PLAN.route.startsWith('#/'), 'plan routes to an in-app hash route');

// --- Feedback message ALWAYS returns a non-empty string (toast always fires). ---
const cases = [
  { nativeShown: true, electron: false, supported: true, permission: 'granted' },
  { nativeShown: false, electron: true, supported: false, permission: 'unsupported' },
  { nativeShown: false, electron: false, supported: false, permission: 'default' },
  { nativeShown: false, electron: false, supported: true, permission: 'denied' },
  { nativeShown: false, electron: false, supported: true, permission: 'default' },
];
for (const c of cases) {
  const msg = testNotificationFeedback(c);
  assert.ok(typeof msg === 'string' && msg.length > 0, `feedback non-empty for ${JSON.stringify(c)}`);
}

// --- Each case yields the RIGHT message (distinct, user-meaningful). ---
assert.match(
  testNotificationFeedback({ nativeShown: true, electron: false, supported: true, permission: 'granted' }),
  /native notification/i,
  'granted+shown => native fired message',
);
assert.match(
  testNotificationFeedback({ nativeShown: false, electron: true, supported: false, permission: 'unsupported' }),
  /desktop app/i,
  'electron => desktop-app message',
);
assert.match(
  testNotificationFeedback({ nativeShown: false, electron: false, supported: false, permission: 'default' }),
  /no Notifications API/i,
  'unsupported => no-API message',
);
assert.match(
  testNotificationFeedback({ nativeShown: false, electron: false, supported: true, permission: 'denied' }),
  /blocked/i,
  'denied => blocked message',
);

// --- Non-throwing for any input shape. ---
assert.doesNotThrow(() =>
  testNotificationFeedback({ nativeShown: false, electron: false, supported: true, permission: 'weird' as any }),
);

console.log('ui_notifications_test_button_test: ok');
