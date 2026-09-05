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
    if (typeof window === 'undefined') return false;
    // Supported if EITHER the in-page Notification constructor exists OR the
    // service-worker path is available (iOS PWAs expose only the latter).
    const hasConstructor = 'Notification' in window && Boolean(window.Notification);
    const hasSW = 'serviceWorker' in navigator && 'Notification' in window;
    return hasConstructor || hasSW;
  } catch (_err) {
    return false;
  }
}

// A service worker is REQUIRED for notifications on iOS Safari PWAs and is the
// preferred path everywhere else (it survives tab-close for the click handler
// and is the only future-proof route to Web Push). We register lazily and cache
// the registration. Registration needs a secure context (HTTPS or localhost);
// under Electron (file://) it is skipped — Electron uses its own notifications.
let swRegistrationPromise: Promise<ServiceWorkerRegistration | null> | null = null;
const NOTIFICATION_SW_URL = 'notification-sw.js';

export function registerNotificationServiceWorker(): Promise<ServiceWorkerRegistration | null> {
  if (swRegistrationPromise) return swRegistrationPromise;
  swRegistrationPromise = (async () => {
    try {
      if (typeof window === 'undefined' || isElectronRuntime()) return null;
      if (!('serviceWorker' in navigator)) return null;
      if (!window.isSecureContext) return null;
      // Resolve the SW url against the app base so it works under Vite `base:./`
      // and when served from a sub-path.
      const base = (import.meta as any)?.env?.BASE_URL || '/';
      const url = new URL(NOTIFICATION_SW_URL, new URL(base, window.location.href)).toString();
      const existing = await navigator.serviceWorker.getRegistration();
      const reg = existing || (await navigator.serviceWorker.register(url));
      // Ensure the page listens for click hand-offs from the SW exactly once.
      installServiceWorkerMessageListener();
      return reg || null;
    } catch (_err) {
      return null;
    }
  })();
  return swRegistrationPromise;
}

let swMessageListenerInstalled = false;
function installServiceWorkerMessageListener() {
  if (swMessageListenerInstalled) return;
  if (typeof navigator === 'undefined' || !('serviceWorker' in navigator)) return;
  try {
    navigator.serviceWorker.addEventListener('message', (event: MessageEvent) => {
      const data = (event && event.data) || {};
      if (data && data.type === 'heimdall-notification-click' && data.route) {
        focusAndRoute(String(data.route));
      }
    });
    swMessageListenerInstalled = true;
  } catch (_err) {
    /* ignore */
  }
}

async function activeNotificationRegistration(): Promise<ServiceWorkerRegistration | null> {
  try {
    const reg = await registerNotificationServiceWorker();
    if (!reg) return null;
    // showNotification needs an active worker; wait briefly if it's still
    // installing/waiting (first load), but never block forever.
    if (reg.active) return reg;
    await navigator.serviceWorker.ready.catch(() => null);
    const ready = await navigator.serviceWorker.getRegistration().catch(() => null);
    return (ready && ready.active) ? ready : (reg.active ? reg : null);
  } catch (_err) {
    return null;
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

// Low-level: actually show the OS notification for a resolved plan. Resolves to
// true if a notification was created. No gating here — callers gate first.
//
// Prefers the service-worker path (reg.showNotification) — required on iOS
// Safari PWAs and preferred elsewhere — and falls back to the in-page
// Notification constructor when no active SW is available (e.g. insecure dev
// context or a browser without SW support). The two paths route clicks
// differently: the SW path via `notificationclick` -> postMessage -> the page's
// message listener; the constructor path via the in-page `onclick` below.
export async function showNativeNotification(plan: NotificationPlan): Promise<boolean> {
  if (typeof window === 'undefined' || !('Notification' in window)) return false;

  const icon = iconUrl();
  const data = { route: plan.route, href: routeToHref(plan.route) };

  // 1) Service-worker path (preferred; only path on iOS PWAs).
  try {
    const reg = await activeNotificationRegistration();
    if (reg) {
      await reg.showNotification(plan.title, {
        body: plan.body,
        tag: plan.tag,
        icon,
        renotify: true,
        data,
      } as NotificationOptions);
      return true;
    }
  } catch (_err) {
    /* fall through to the constructor path */
  }

  // 2) In-page constructor fallback.
  try {
    const notification = new window.Notification(plan.title, {
      body: plan.body,
      tag: plan.tag,
      icon,
      // renotify keeps a fresh alert when a burst collapses onto the same tag.
      renotify: true,
      data,
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

  // Fire-and-forget: showing is async (service-worker path), but the WS funnel is
  // synchronous and only uses the returned plan for tests/telemetry.
  void showNativeNotification(plan);
  return plan;
}
