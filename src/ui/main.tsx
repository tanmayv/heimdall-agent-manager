import React from 'react';
import ReactDOM from 'react-dom/client';
import { Provider } from 'react-redux';
import AppShell from './components/shell/AppShell';
import ElectronDeviceAuthGate, { installElectronApiFetchBridge } from './components/ElectronDeviceAuthGate';
import { store } from './store/store';
import { buildRouteHash } from './utils/appLocation';
import { registerNotificationServiceWorker } from './services/notificationService';
import { resubscribeOnLoad } from './services/pushSubscriptionService';
import { selectNotificationsState } from './store/notificationsSlice';
import './debugCapture';
import './styles.css';

// Legacy deep-link migration: if the app was opened at a real path-based route
// (e.g. an old bookmark `.../workspace/chains/X/tasks/Y?...`) with no hash, fold
// that route into the hash and reset the document path to the app root. This keeps
// the loaded document at index.html so an Electron file:// refresh always works,
// while preserving the intended route.
(function migrateLegacyPathRoute() {
  try {
    if (typeof window === 'undefined') return;
    const { pathname, search, hash } = window.location;
    if (hash && hash.length > 1) return; // already hash-routed
    if (!pathname || !pathname.includes('/workspace')) return;
    const idx = pathname.indexOf('/workspace');
    const routePath = pathname.slice(idx) || '/workspace';
    window.history.replaceState(window.history.state || {}, '', buildRouteHash(routePath, search));
  } catch (_err) {
    // Non-fatal: fall back to default routing.
  }
})();

(window as any).__debugStore = store;
installElectronApiFetchBridge();

// Register the notification service worker early so OS notifications work on
// platforms where the in-page Notification constructor is unavailable (iOS
// Safari PWAs) and to install the click->route message listener. No-ops under
// Electron / insecure contexts. Never blocks startup.
void registerNotificationServiceWorker();

// Resubscribe-on-load: if the user previously enabled notifications (and the
// browser still reports permission granted), refresh the Web Push subscription
// with the Hub. iOS drops subscriptions across reinstalls and endpoints can
// rotate, so we re-register whenever the app boots with notifications enabled.
// No-ops under Electron / insecure contexts and when the server has no VAPID
// key. Never blocks startup.
{
  const settings = selectNotificationsState(store.getState());
  void resubscribeOnLoad(settings.enabled, settings.permission === 'granted');
}

ReactDOM.createRoot(document.getElementById('root')).render(
  <React.StrictMode>
    <Provider store={store}>
      <ElectronDeviceAuthGate>
        <AppShell />
      </ElectronDeviceAuthGate>
    </Provider>
  </React.StrictMode>,
);
