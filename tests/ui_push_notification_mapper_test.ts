import assert from 'node:assert/strict';

// The push mapper is pure (no DOM). Import it directly. It turns the raw Web
// Push wire payload the Hub sends into the concrete plan the service worker
// renders, and is TOTAL: a missing/garbage payload still yields a visible
// Heimdall fallback (iOS revokes push permission on a silent push).
const { planForPushPayload } = await import('../src/ui/api/pushNotificationMapper');

// --- Full payload round-trips faithfully ----------------------------------
{
  const plan = planForPushPayload({
    title: 'New message',
    body: 'Deployment finished successfully.',
    tag: 'heimdall:chat:conv_1',
    route: '/conversations/conv_1',
    category: 'chat',
    href: 'https://hub.test/index.html#/conversations/conv_1',
  });
  assert.equal(plan.title, 'New message');
  assert.match(plan.body, /Deployment finished/);
  assert.equal(plan.tag, 'heimdall:chat:conv_1', 'tag preserved for coalescing');
  assert.equal(plan.route, '/conversations/conv_1');
  assert.equal(plan.href, 'https://hub.test/index.html#/conversations/conv_1');
  assert.equal(plan.category, 'chat');
}

// --- attention category preserved -----------------------------------------
{
  const plan = planForPushPayload({
    title: 'Agent needs your input',
    body: 'An agent is waiting for your response.',
    tag: 'heimdall:attention:approval:chain_9',
    route: '/chains/chain_9',
    category: 'attention',
    href: 'https://hub.test/#/chains/chain_9',
  });
  assert.equal(plan.category, 'attention');
  assert.equal(plan.route, '/chains/chain_9');
}

// --- unknown/invalid category falls back to 'attention' -------------------
{
  const plan = planForPushPayload({ title: 't', body: 'b', category: 'weird' });
  assert.equal(plan.category, 'attention', 'unknown category => attention');
}

// --- TOTAL: null payload => visible Heimdall fallback ---------------------
{
  const plan = planForPushPayload(null);
  assert.equal(plan.title, 'Heimdall', 'null payload still shows a title');
  assert.equal(plan.body, 'You have a new notification.');
  assert.equal(plan.tag, 'heimdall:push');
  assert.equal(plan.route, '/conversations');
  assert.equal(plan.href, '');
  assert.equal(plan.category, 'attention');
}

// --- TOTAL: empty object => same fallback ---------------------------------
{
  const plan = planForPushPayload({});
  assert.equal(plan.title, 'Heimdall');
  assert.equal(plan.body, 'You have a new notification.');
  assert.equal(plan.route, '/conversations');
}

// --- partial payload: missing fields fall back individually ---------------
{
  const plan = planForPushPayload({ title: 'Only a title' });
  assert.equal(plan.title, 'Only a title', 'provided field kept');
  assert.equal(plan.body, 'You have a new notification.', 'missing body falls back');
  assert.equal(plan.tag, 'heimdall:push', 'missing tag falls back');
  assert.equal(plan.route, '/conversations', 'missing route falls back');
}

// --- body is whitespace-collapsed and truncated ---------------------------
{
  const long = 'x'.repeat(300);
  const plan = planForPushPayload({ title: 'a\n\tb', body: `line1\n\n   line2 ${long}` });
  assert.equal(plan.title, 'a b', 'whitespace collapsed in title');
  assert.ok(plan.body.length <= 140, 'body truncated to <=140 chars');
  assert.ok(plan.body.endsWith('…'), 'truncated body ends with ellipsis');
}

console.log('ui_push_notification_mapper_test: ok');
