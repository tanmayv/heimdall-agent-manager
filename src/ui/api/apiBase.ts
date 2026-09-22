// Where the renderer's `/api/v1` requests are rooted.
//
// Normally: nowhere. The app is served at the origin root, `/api/v1/...` is an
// absolute same-origin path, and `API_BASE` is the empty string — the produced
// bundle is byte-for-byte what it has always been.
//
// The ONE case that needs more is the Heimdall shell-session preview. There the
// app is served THROUGH the bridge→hub tunnel, under a path prefix the app cannot
// know at build time and never sees itself:
//
//     https://<hub>/api/v1/preview/<session_id>/          ← the document
//     http://127.0.0.1:<local_endpoint_port>/proxy/<session_id>/   ← the same thing, locally
//
// The browser resolves an ABSOLUTE `/api/v1/me` against the ORIGIN, dropping the
// prefix, so it lands on whatever happens to live at that origin's root rather
// than on the server behind the tunnel. Building with `VITE_API_BASE=.` makes the
// API paths document-relative instead, so they inherit the prefix exactly the way
// `base: './'` already makes the asset URLs inherit it.
//
// Opt-in, and build-time only: Vite statically replaces `import.meta.env.*`, so an
// ordinary `npm run build` (no VITE_API_BASE in the environment) emits `''` here
// and every call site keeps its absolute path.
const configured = String((import.meta as any).env?.VITE_API_BASE ?? '').trim();

/** `''` in every normal build; `'.'` (document-relative) in a preview build. */
export const API_BASE: string = configured;

/** Roots an absolute `/api/v1/...` path at `API_BASE`. Identity when unset. */
export function withApiBase(path: string): string {
  if (!API_BASE) return path;
  return `${API_BASE}${path.startsWith('/') ? path : `/${path}`}`;
}

/**
 * The absolute URL an API path resolves to, for the places that need a real URL
 * rather than a fetch-relative one (a WebSocket, an `<a href>`). Resolved against
 * `document.baseURI`, which carries the preview prefix.
 */
export function apiAbsoluteUrl(path: string): string {
  const base = typeof document !== 'undefined' ? document.baseURI : undefined;
  return new URL(withApiBase(path), base ?? window.location.href).toString();
}
