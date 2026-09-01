import assert from 'node:assert/strict';

// End-to-end funnel test: drive the REAL handleUserWsEvent (wsInvalidation.ts)
// through the REAL redux store and assert that a native Notification fires only
// when the tab is open-but-unfocused, for curated events only. This exercises
// the exact wiring the running UI uses (thunk -> fireNotificationForWsEvent ->
// mapper -> showNativeNotification), not a mock of it.

const created: Array<{ title: string; options: any }> = [];
const storage = new Map<string, string>();

class FakeNotification {
  onclick: (() => void) | null = null;
  static permission: 'default' | 'granted' | 'denied' = 'granted';
  constructor(title: string, options: any) { created.push({ title, options }); }
  static async requestPermission() { return FakeNotification.permission; }
  close() {}
}

const view = { visibility: 'hidden' as 'hidden' | 'visible', focus: false, hash: '' };

(globalThis as any).document = {
  get visibilityState() { return view.visibility; },
  hasFocus() { return view.focus; },
  querySelector() { return null; },
  addEventListener() {},
  removeEventListener() {},
};
(globalThis as any).window = {
  Notification: FakeNotification,
  localStorage: {
    getItem(k: string) { return storage.has(k) ? storage.get(k)! : null; },
    setItem(k: string, v: string) { storage.set(k, v); },
    removeItem(k: string) { storage.delete(k); },
  },
  location: { origin: 'https://hub.test', pathname: '/index.html', search: '', get hash() { return view.hash; }, set hash(v: string) { view.hash = v; } },
  focus() { view.focus = true; },
  open() { return { focus() {} }; },
  addEventListener() {},
  removeEventListener() {},
  matchMedia: () => ({ matches: false, addEventListener() {}, removeEventListener() {}, addListener() {}, removeListener() {} }),
  odinApi: undefined,
};
(globalThis as any).Notification = FakeNotification;

// Build a minimal store from the REAL notifications reducer + thunk middleware
// (the app store module hard-codes import.meta.env.DEV which tsx cannot stub).
// handleUserWsEvent + the notifications reducer are the real modules under test.
const { configureStore } = await import('@reduxjs/toolkit');
const { handleUserWsEvent } = await import('../src/ui/api/wsInvalidation');
const notificationsMod: any = await import('../src/ui/store/notificationsSlice');
const { notificationsEnabledSet, notificationPermissionSet } = notificationsMod;
const { heimdallApi }: any = await import('../src/ui/api/heimdallApi');
const store = configureStore({
  reducer: { notifications: notificationsMod.default, [heimdallApi.reducerPath]: heimdallApi.reducer },
  middleware: (getDefault: any) => getDefault().concat(heimdallApi.middleware),
});

// Enable notifications through the real reducers (permission granted first).
store.dispatch(notificationPermissionSet('granted'));
store.dispatch(notificationsEnabledSet(true));
assert.equal((store.getState() as any).notifications.enabled, true, 'notifications enabled in store');

const chatEvent = {
  type: 'chat_event',
  direction: 'agent_to_user',
  agent_instance_id: 'inst_a',
  conversation_id: 'conv_1',
  message: { message_id: 'm1', direction: 'agent_to_user', body: 'Build finished', created_unix_ms: Date.now() },
};

// Backgrounded (open but unfocused) => exactly one native notification.
created.length = 0;
view.visibility = 'hidden';
view.focus = false;
handleUserWsEvent(store.dispatch, chatEvent, {});
assert.equal(created.length, 1, 'backgrounded curated event fires exactly one notification');
assert.equal(created[0].options.tag, 'heimdall:chat:conv_1');

// Focused tab => no native notification (in-app toast path handles it).
created.length = 0;
view.visibility = 'visible';
view.focus = true;
handleUserWsEvent(store.dispatch, chatEvent, {});
assert.equal(created.length, 0, 'focused tab fires no native notification');

// Backgrounded excluded event => no notification.
created.length = 0;
view.visibility = 'hidden';
view.focus = false;
handleUserWsEvent(store.dispatch, { type: 'agent_runtime_changed', agent_instance_id: 'inst_a' }, {});
assert.equal(created.length, 0, 'excluded event never notifies');

// Backgrounded needs-attention approval => one notification.
created.length = 0;
handleUserWsEvent(store.dispatch, {
  type: 'chat_approval',
  event: 'chat_approval_created',
  approval: { approval_id: 'ap1', chain_id: 'chain_9', agent_instance_id: 'inst_a', kind: 'question', body: 'Deploy now?', state: 'open' },
}, {});
assert.equal(created.length, 1, 'chat_approval_created fires one notification');
assert.equal(created[0].options.tag, 'heimdall:attention:approval:chain_9');

console.log('ui_notification_funnel_integration_test: ok');
