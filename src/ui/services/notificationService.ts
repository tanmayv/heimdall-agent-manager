// Thin, side-effectful native notification service.
//
// This is the ONLY module that touches window.Notification / permission /
// visibility / focus. The notify-vs-skip policy and content live in the pure
// notificationForWsEvent mapper; this service just gates and renders.
//
// Wiring: fireNotificationForWsEvent is called from the single handleUserWsEvent
// funnel (wsInvalidation.ts) for every user-WS event. It early-returns unless
// notifications are enabled + permission granted + the tab is open-but-unfocused.

import { buildRouteHash } from '../utils/appLocation';
import { notificationForWsEvent, type NotificationMapperCtx, type NotificationPlan } from '../api/notificationMapper';
import {
  categoryEnabled,
  notificationsActive,
  selectNotificationsState,
  type NotificationPermission,
} from '../store/notificationsSlice';

export function isNotificationSupported(): boolean {
  try {
    return typeof window !== 'undefined' && 'Notification' in window && Boolean(window.Notification);
  } catch (_err) {
    return false;
  }
}

// Electron runs its own main-process notification surface. Detect it via the
// injected odinApi bridge (same signal useUserWebSocket uses) so we cleanly
// no-op here and never double-notify (REQ-N7).
export function isElectronRuntime(): boolean {
  try {
    return typeof window !== 'undefined' && Boolean((window as any).odinApi);
  } catch (_err) {
    return false;
  }
}

// True when the tab is OPEN but NOT focused. If the tab is focused, the in-app
// toast path already surfaces the event, so we must not also raise an OS popup.
export function isTabBackgrounded(): boolean {
  try {
    if (typeof document === 'undefined') return false;
    if (document.visibilityState && document.visibilityState !== 'visible') return true;
    if (typeof document.hasFocus === 'function' && !document.hasFocus()) return true;
    return false;
  } catch (_err) {
    return false;
  }
}

// Request permission ONLY from an explicit user gesture (the Settings toggle).
// Never called on page load. Returns the resulting permission (or 'unsupported'
// / 'denied' on failure) and never throws or logs to the console.
export async function requestNotificationPermission(): Promise<NotificationPermission> {
  if (!isNotificationSupported()) return 'unsupported';
  try {
    const result = await window.Notification.requestPermission();
    if (result === 'granted' || result === 'denied' || result === 'default') return result;
    return 'default';
  } catch (_err) {
    return 'denied';
  }
}

function iconUrl(): string | undefined {
  try {
    // Reuse the app favicon/logo if present; undefined is a valid Notification
    // icon (the browser falls back to its own default).
    if (typeof document === 'undefined') return undefined;
    const link = document.querySelector('link[rel="icon"], link[rel="shortcut icon"]') as HTMLLinkElement | null;
    return link?.href || undefined;
  } catch (_err) {
    return undefined;
  }
}

// Absolute URL for the given in-app hash route, anchored at the current
// document (index.html). Used both for same-window navigation and as the
// new-window fallback target so the deep-link resolves identically.
function routeToHref(route: string): string {
  const hash = buildRouteHash(route, '');
  try {
    if (typeof window !== 'undefined' && window.location) {
      const base = `${window.location.origin}${window.location.pathname}${window.location.search}`;
      return `${base}${hash}`;
    }
  } catch (_err) {
    /* fall through */
  }
  return hash;
}

// Focus the existing Heimdall window and route it to the target chat/chain/task.
// If focusing the existing window isn't possible (e.g. the tab was closed, or
// the browser blocks refocus), fall back to opening the deep-link in a new
// window so the click still lands on the correct conversation (REQ-N4).
function focusAndRoute(route: string) {
  if (typeof window === 'undefined' || !route) return;

  // The notification was raised BY this window, so this window still exists.
  // Navigate it in place FIRST and ask the OS to bring it forward. We must not
  // gate on window.focus() succeeding: from a backgrounded tab focus() is often
  // silently blocked, and gating on document.hasFocus() there would wrongly
  // fall through to window.open() and spawn a duplicate tab (REQ-N4). In-place
  // hash navigation always lands on the correct conversation in the SAME tab.
  try {
    window.location.hash = buildRouteHash(route, '');
    try { window.focus(); } catch (_err) { /* focus may be blocked; navigation already applied */ }
    return;
  } catch (_err) {
    /* fall through to new-window fallback only if in-place nav actually threw */
  }

  // In-place navigation threw (very unusual) — open the deep-link in a named
  // window so repeated clicks reuse the same one instead of stacking tabs.
  try {
    const opened = window.open(routeToHref(route), 'heimdall');
    if (opened) {
      try { opened.focus(); } catch (_err) { /* ignore */ }
    }
  } catch (_err) {
    /* ignore */
  }
}

// Low-level: actually create the OS Notification for a resolved plan. Returns
// true if a notification was created. No gating here — callers gate first.
export function showNativeNotification(plan: NotificationPlan): boolean {
  if (!isNotificationSupported()) return false;
  try {
    const notification = new window.Notification(plan.title, {
      body: plan.body,
      tag: plan.tag,
      icon: iconUrl(),
      // renotify keeps a fresh alert when a burst collapses onto the same tag.
      renotify: true,
    } as NotificationOptions);
    notification.onclick = () => {
      focusAndRoute(plan.route);
      try {
        notification.close();
      } catch (_err) {
        /* ignore */
      }
    };
    return true;
  } catch (_err) {
    // Some browsers throw when constructing Notification directly (e.g. require
    // a ServiceWorkerRegistration). Fail silently — no console noise (REQ-N3).
    return false;
  }
}

// Entry point wired into handleUserWsEvent. `getState` is the redux store's
// getState (dependency-injected to avoid a circular store import). Returns the
// plan that fired (for tests/telemetry) or null when skipped.
export function fireNotificationForWsEvent(
  getState: () => any,
  payload: any,
  ctx: NotificationMapperCtx = {},
): NotificationPlan | null {
  // Electron owns native notifications in its main process — no-op here.
  if (isElectronRuntime()) return null;
  if (!isNotificationSupported()) return null;
  // Only when the tab is open-but-unfocused (REQ-N1/REQ-N2).
  if (!isTabBackgrounded()) return null;

  let settings;
  try {
    settings = selectNotificationsState(getState());
  } catch (_err) {
    return null;
  }
  if (!notificationsActive(settings)) return null;

  const plan = notificationForWsEvent(payload, ctx);
  if (!plan) return null;
  // Per-category opt-out.
  if (!categoryEnabled(settings, plan.category)) return null;

  return showNativeNotification(plan) ? plan : null;
}
