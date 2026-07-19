// Hash-based routing location helpers.
//
// The desktop app is loaded in production via Electron `loadFile(index.html)` over
// `file://`. If the route lived in the real path (history/pushState to
// `/workspace/chains/X/tasks/Y`), a page refresh would ask Electron to load a
// non-existent file at that path and the window would come up blank -- this is the
// "refresh on the task view doesn't open" bug.
//
// Storing the route in the URL *hash* (`index.html#/workspace/chains/X/tasks/Y?...`)
// makes refresh always reload `index.html` (the part before `#`), while the hash is
// preserved so the app re-derives the same route. It also keeps relative asset URLs
// (`base: './'`) resolving against `index.html` at any route depth.
//
// Hash grammar: `#<pathname>[?<search>]`

function rawHash(): string {
  const hash = typeof window !== 'undefined' ? window.location.hash || '' : '';
  return hash.startsWith('#') ? hash.slice(1) : '';
}

// Route pathname (e.g. `/workspace/chains/c1/tasks/t2`). Falls back to the real
// document pathname on the very first load before any hash has been written.
export function getRoutePathname(): string {
  if (typeof window === 'undefined') return '/';
  const raw = rawHash();
  if (!raw) return window.location.pathname || '/';
  const qIndex = raw.indexOf('?');
  const path = qIndex >= 0 ? raw.slice(0, qIndex) : raw;
  return path || '/';
}

// Route search string including the leading `?` (e.g. `?memoryId=m1`). Falls back to
// the real document search on first load so existing `?view=...` deep links keep
// working before the app migrates them into the hash.
export function getRouteSearch(): string {
  if (typeof window === 'undefined') return '';
  const hash = window.location.hash || '';
  if (hash.startsWith('#')) {
    const raw = hash.slice(1);
    const qIndex = raw.indexOf('?');
    return qIndex >= 0 ? raw.slice(qIndex) : '';
  }
  return window.location.search || '';
}

// Build the `#`-prefixed URL fragment for pushState/replaceState.
export function buildRouteHash(pathname: string, search: string): string {
  const normalizedSearch = search && !search.startsWith('?') ? `?${search}` : search || '';
  const normalizedPath = pathname && pathname.startsWith('/') ? pathname : `/${pathname || ''}`;
  return `#${normalizedPath}${normalizedSearch}`;
}
