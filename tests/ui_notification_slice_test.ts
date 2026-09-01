import assert from 'node:assert/strict';

// Drive the notifications slice's persistence + permission gating with a fake
// window/localStorage. No real DOM needed.

const storage = new Map<string, string>();
let permission: 'default' | 'granted' | 'denied' = 'default';

(globalThis as any).window = {
  get Notification() {
    return { get permission() { return permission; } };
  },
  localStorage: {
    getItem(k: string) { return storage.has(k) ? storage.get(k)! : null; },
    setItem(k: string, v: string) { storage.set(k, v); },
    removeItem(k: string) { storage.delete(k); },
  },
};
(globalThis as any).Notification = (globalThis as any).window.Notification;

const mod = await import('../src/ui/store/notificationsSlice');
const {
  default: reducer,
  notificationsEnabledSet,
  notificationCategorySet,
  notificationPermissionSet,
  notificationPermissionRefreshed,
  notificationsActive,
  categoryEnabled,
} = mod as any;

// Default state: OFF, categories default on.
let state = reducer(undefined, { type: '@@init' });
assert.equal(state.enabled, false, 'defaults OFF');
assert.equal(state.categories.chat, true);
assert.equal(state.categories.attention, true);

// Cannot enable while permission != granted.
state = reducer(state, notificationsEnabledSet(true));
assert.equal(state.enabled, false, 'cannot enable without granted permission');

// Grant permission, then enable => active + persisted.
state = reducer(state, notificationPermissionSet('granted'));
assert.equal(state.permission, 'granted');
state = reducer(state, notificationsEnabledSet(true));
assert.equal(state.enabled, true, 'enable after grant');
assert.equal(notificationsActive(state), true);
assert.equal(categoryEnabled(state, 'chat'), true);
assert.ok(storage.get('heimdall:notifications:v1'), 'persisted to localStorage');

// Category opt-out reflected in categoryEnabled.
state = reducer(state, notificationCategorySet({ category: 'chat', enabled: false }));
assert.equal(categoryEnabled(state, 'chat'), false, 'chat category off');
assert.equal(categoryEnabled(state, 'attention'), true, 'attention still on');

// Losing permission (revoked in browser settings) disables + persists off.
permission = 'denied';
state = reducer(state, notificationPermissionRefreshed());
assert.equal(state.permission, 'denied');
assert.equal(state.enabled, false, 'revoked permission disables notifications');
assert.equal(notificationsActive(state), false);

// buildInitialState (load-time gate): persisted-enabled is only honored when
// the browser permission is 'granted' at load. The slice captures initialState
// at import, so exercise the exported builder logic directly via a fresh import
// under two permission states using a query-busted module specifier.
async function freshInitial(perm: 'default' | 'granted' | 'denied', persistedEnabled: boolean) {
  permission = perm;
  storage.set('heimdall:notifications:v1', JSON.stringify({ enabled: persistedEnabled, categories: { chat: true, attention: true } }));
  const fresh: any = await import(`../src/ui/store/notificationsSlice?load=${perm}-${persistedEnabled}`);
  return fresh.default(undefined, { type: '@@init' });
}

const deniedLoad = await freshInitial('default', true);
assert.equal(deniedLoad.enabled, false, 'persisted-enabled ignored when permission not granted at load');

const grantedLoad = await freshInitial('granted', true);
assert.equal(grantedLoad.enabled, true, 'persisted-enabled honored when granted at load');

console.log('ui_notification_slice_test: ok');
