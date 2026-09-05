// Thin, side-effectful Web Push subscription service (Level 2).
//
// This is the ONLY module that touches `PushManager` / `pushManager.subscribe`.
// It fetches the Hub's VAPID public key, subscribes the browser's push service,
// and POSTs the resulting subscription to the Hub so the server can deliver
// background notifications even when the PWA is fully closed (the WS-driven
// local path in `notificationService.ts` cannot — iOS suspends page JS).
//
// Design (mirrors `notificationService.ts`):
//   - Keep all `pushManager` logic here, NOT in the redux slice.
//   - Guard `isElectronRuntime()` (Electron uses its own notifications) and
//     `window.isSecureContext` (Push requires HTTPS/localhost).
//   - Never throw to callers: every entry point resolves to a boolean/void so a
//     failed subscribe leaves the UI toggle logic untouched.
//   - Reuse the already-registered notification service worker.

import { cookieJsonFetch, cookieMutation } from '../api/cookieFetch';
import { isElectronRuntime, registerNotificationServiceWorker } from './notificationService';

const VAPID_PUBLIC_KEY_PATH = '/push/vapid-public-key';
const SUBSCRIPTIONS_PATH = '/me/push-subscriptions';

// True when the browser can actually do Web Push in this context. Web Push needs
// a secure context, a service worker, and the PushManager API. Electron is
// excluded (it owns native notifications in its main process).
export function isPushSupported(): boolean {
  try {
    if (typeof window === 'undefined' || isElectronRuntime()) return false;
    if (!window.isSecureContext) return false;
    if (!('serviceWorker' in navigator)) return false;
    if (!('PushManager' in window)) return false;
    return true;
  } catch (_err) {
    return false;
  }
}

// Decode a base64url (unpadded) VAPID public key into the Uint8Array that
// `pushManager.subscribe({ applicationServerKey })` requires. Re-pads and maps
// the URL-safe alphabet back to standard base64 before `atob`.
export function base64UrlToUint8Array(base64Url: string): Uint8Array<ArrayBuffer> {
  const padding = '='.repeat((4 - (base64Url.length % 4)) % 4);
  const base64 = (base64Url + padding).replace(/-/g, '+').replace(/_/g, '/');
  const raw = atob(base64);
  // Back the view with a concrete ArrayBuffer so it satisfies BufferSource for
  // pushManager.subscribe({ applicationServerKey }).
  const output = new Uint8Array(new ArrayBuffer(raw.length));
  for (let i = 0; i < raw.length; i += 1) {
    output[i] = raw.charCodeAt(i);
  }
  return output;
}

// Fetch the Hub's VAPID public key (base64url uncompressed P-256 point). Returns
// an empty string if push sending is disabled server-side (key unset) or on any
// error, so callers can cleanly skip subscribing.
async function fetchVapidPublicKey(): Promise<string> {
  try {
    const data = await cookieJsonFetch(VAPID_PUBLIC_KEY_PATH);
    const key = data?.vapid_public_key;
    return typeof key === 'string' ? key : '';
  } catch (_err) {
    return '';
  }
}

// Resolve the active service-worker registration (reusing the one registered by
// notificationService). Web Push subscriptions live on the registration.
async function activeRegistration(): Promise<ServiceWorkerRegistration | null> {
  try {
    const reg = await registerNotificationServiceWorker();
    if (!reg) return null;
    if (reg.active) return reg;
    await navigator.serviceWorker.ready.catch(() => null);
    const ready = await navigator.serviceWorker.getRegistration().catch(() => null);
    return ready?.active ? ready : (reg.active ? reg : null);
  } catch (_err) {
    return null;
  }
}

// POST a browser PushSubscription (its `.toJSON()` shape) to the Hub, upserting
// by endpoint. Returns true on success.
async function postSubscription(subscription: PushSubscription): Promise<boolean> {
  try {
    await cookieMutation(SUBSCRIPTIONS_PATH, 'POST', subscription.toJSON());
    return true;
  } catch (_err) {
    return false;
  }
}

// DELETE a subscription from the Hub by its endpoint. Best-effort.
async function deleteSubscription(endpoint: string): Promise<boolean> {
  try {
    await cookieMutation(SUBSCRIPTIONS_PATH, 'DELETE', { endpoint });
    return true;
  } catch (_err) {
    return false;
  }
}

// Subscribe this browser to Web Push and register the subscription with the Hub.
// Idempotent: reuses an existing subscription when present. Returns true when a
// subscription exists and was POSTed to the Hub, false when push is unsupported,
// the server has no VAPID key, or any step failed (never throws).
export async function enablePushSubscription(): Promise<boolean> {
  if (!isPushSupported()) return false;
  try {
    const reg = await activeRegistration();
    if (!reg || !reg.pushManager) return false;

    // Reuse an existing subscription if the browser already has one; otherwise
    // create one with the server's VAPID key. Either way we (re)POST it so the
    // Hub always has the current endpoint (subscriptions can rotate).
    let subscription = await reg.pushManager.getSubscription();
    if (!subscription) {
      const vapidKey = await fetchVapidPublicKey();
      if (!vapidKey) return false; // server push disabled — nothing to subscribe to
      subscription = await reg.pushManager.subscribe({
        userVisibleOnly: true,
        applicationServerKey: base64UrlToUint8Array(vapidKey),
      });
    }
    installPushSubscriptionChangeListener();
    return await postSubscription(subscription);
  } catch (_err) {
    return false;
  }
}

// Unsubscribe this browser from Web Push and remove the subscription from the
// Hub. Best-effort; returns true when there was nothing to do or cleanup
// succeeded.
export async function disablePushSubscription(): Promise<boolean> {
  if (typeof window === 'undefined' || isElectronRuntime()) return true;
  try {
    if (!('serviceWorker' in navigator)) return true;
    const reg = await navigator.serviceWorker.getRegistration().catch(() => null);
    const subscription = reg?.pushManager ? await reg.pushManager.getSubscription() : null;
    if (!subscription) return true;
    const endpoint = subscription.endpoint;
    // Unsubscribe locally first so the browser stops receiving, then tell the
    // Hub to drop the (now-dead) endpoint.
    await subscription.unsubscribe().catch(() => false);
    await deleteSubscription(endpoint);
    return true;
  } catch (_err) {
    return false;
  }
}

// The service worker fires this when the push service rotates a subscription and
// (best-effort) resubscribes, handing the fresh subscription to the page. We
// POST it to the Hub so the stored endpoint stays current. Installed once.
let subscriptionChangeListenerInstalled = false;
function installPushSubscriptionChangeListener() {
  if (subscriptionChangeListenerInstalled) return;
  if (typeof navigator === 'undefined' || !('serviceWorker' in navigator)) return;
  try {
    navigator.serviceWorker.addEventListener('message', (event: MessageEvent) => {
      const data = (event && event.data) || {};
      if (data?.type !== 'heimdall-push-subscription-change') return;
      if (data.subscription) {
        // The SW already resubscribed; just persist the new endpoint/keys.
        void cookieMutation(SUBSCRIPTIONS_PATH, 'POST', data.subscription).catch(() => undefined);
      } else {
        // The SW could not resubscribe (e.g. missing key) — do a full resubscribe.
        void enablePushSubscription();
      }
    });
    subscriptionChangeListenerInstalled = true;
  } catch (_err) {
    /* ignore */
  }
}

// Resubscribe-on-load: called at startup so a returning user whose master
// toggle is ON (and permission granted) re-registers their push endpoint. iOS
// drops subscriptions across reinstalls, and endpoints can rotate, so we refresh
// the Hub's copy whenever the app boots with notifications enabled. No-ops when
// push is unsupported or notifications are disabled.
export async function resubscribeOnLoad(enabled: boolean, permissionGranted: boolean): Promise<void> {
  if (!enabled || !permissionGranted) return;
  if (!isPushSupported()) return;
  installPushSubscriptionChangeListener();
  await enablePushSubscription();
}
