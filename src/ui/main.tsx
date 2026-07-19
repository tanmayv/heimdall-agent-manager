import React from 'react';
import ReactDOM from 'react-dom/client';
import { Provider } from 'react-redux';
import App from './components/App';
import { store } from './store/store';
import { buildRouteHash } from './utils/appLocation';
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

ReactDOM.createRoot(document.getElementById('root')).render(
  <React.StrictMode>
    <Provider store={store}>
      <App />
    </Provider>
  </React.StrictMode>,
);
