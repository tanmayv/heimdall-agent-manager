// Heimdall notification service worker (Level 1 — local notifications).
//
// Purpose: enable OS notifications on platforms where the in-page
// `new Notification()` constructor is unavailable/blocked — most importantly
// iOS/iPadOS Safari installed as a Home-Screen PWA (16.4+), which ONLY supports
// notifications via ServiceWorkerRegistration.showNotification(). On desktop
// Chrome/Edge/Firefox/Safari this path also works and is preferred.
//
// This SW intentionally does NOT do Web Push (that's a later, server-touching
// change). It only (a) exists so the page can call reg.showNotification(), and
// (b) routes notification clicks back to an existing app window (or opens one).

/* eslint-disable no-restricted-globals */

// Activate immediately so the first registration can show notifications without
// requiring a reload.
self.addEventListener('install', () => {
  self.skipWaiting();
});
self.addEventListener('activate', (event) => {
  event.waitUntil(self.clients.claim());
});

// Notification click: focus an existing Heimdall window and tell it which route
// to open; if none is open, open a new window at the deep-link. The click data
// is attached by the page when it calls showNotification({ data: { route, href } }).
self.addEventListener('notificationclick', (event) => {
  const notification = event.notification;
  const data = (notification && notification.data) || {};
  const route = data.route || '';
  const href = data.href || '';
  try { notification.close(); } catch (_e) { /* ignore */ }

  event.waitUntil((async () => {
    const all = await self.clients.matchAll({ type: 'window', includeUncontrolled: true });
    for (const client of all) {
      // Reuse any open Heimdall window: focus it and hand off the route so the
      // in-page router navigates (SPA hash routing lives in the page, not the SW).
      try {
        await client.focus();
        client.postMessage({ type: 'heimdall-notification-click', route });
        return;
      } catch (_e) {
        /* try the next client */
      }
    }
    // No open window — open the deep-link (absolute href includes the hash route).
    if (href && self.clients.openWindow) {
      try { await self.clients.openWindow(href); } catch (_e) { /* ignore */ }
    }
  })());
});
