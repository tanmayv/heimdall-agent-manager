/*
 * Decides where the page goes when the flow ends on `xak-flow-redirect`.
 *
 * Why: when user B signs in over user A's Authentik session (the add-account path), Django's
 * login() flushes the session, so the flow's saved `next` is lost and the flow ends on the
 * root redirect, which lands the user on Authentik's own /if/user/. We still have the original
 * query in our own URL, so resume the OIDC authorize request from there — without
 * `prompt=login`, which would demand a second login.
 *
 * Pure so it is node-testable (flow-resume.test.mjs) and so the open-redirect rules live in
 * one place.
 */

const AUTHORIZE_PREFIX = '/application/o/authorize/';

function isRootRedirect(to, origin) {
  if (to === undefined || to === null || to === '' || to === '/' || to === '/if/user/') return true;
  let u;
  try { u = new URL(String(to), origin); } catch { return false; }
  return u.origin === origin && (u.pathname === '/' || u.pathname === '/if/user/') && !u.search;
}

/** Return a safe relative authorize URL (prompt=login removed), or null if `next` is not one. */
export function resumeAuthorizeUrl(next, origin) {
  if (typeof next !== 'string' || !next.startsWith(AUTHORIZE_PREFIX)) return null;
  // Control characters and backslashes are stripped or reinterpreted by browsers.
  if (/[\\\u0000-\u001f\u007f]/.test(next)) return null;
  let u;
  try { u = new URL(next, origin); } catch { return null; }
  if (u.origin !== origin || !u.pathname.startsWith(AUTHORIZE_PREFIX)) return null;
  // Drop only the `login` token: consent / select_account are still wanted.
  const rest = (u.searchParams.get('prompt') || '').split(/\s+/).filter((p) => p && p !== 'login');
  if (rest.length) u.searchParams.set('prompt', rest.join(' ')); else u.searchParams.delete('prompt');
  return u.pathname + u.search;
}

/**
 * @param {string|undefined} to        challenge.to from xak-flow-redirect
 * @param {string} search              location.search of the login page
 * @param {string} origin              location.origin
 * @returns {string} URL to navigate to
 */
export function flowRedirectTarget(to, search, origin) {
  const fallback = to || '/';
  if (!isRootRedirect(to, origin)) return fallback;
  const resumed = resumeAuthorizeUrl(new URLSearchParams(search).get('next'), origin);
  return resumed || fallback;
}
