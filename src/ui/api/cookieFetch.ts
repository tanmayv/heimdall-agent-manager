// UI-14/UI-15: shared cookie-authenticated JSON fetch helper for rewrite endpoints
// served behind the trusted proxy. The rewrite app uses the SAME cookie auth
// session as `/api/v1/me` (`credentials: 'include'`), NOT the legacy per-client
// token session (`withSessionQuery` + `session.clientToken`). Centralizing this
// stops each new cookie endpoint from reinventing its own apiUrl/fetch wrapper.

import { withApiBase } from './apiBase';

// `withApiBase` is the identity in every normal build; it only does something in a
// preview build, where the app is served under a path prefix (see apiBase.ts).
export function apiUrl(path: string): string {
  return withApiBase(path.startsWith('/api/v1') ? path : `/api/v1${path.startsWith('/') ? path : `/${path}`}`);
}

// GET `/api/v1/...` with cookie auth. Returns the unwrapped `data` array if the
// response is a list, otherwise the parsed body. Throws on non-2xx so RTK Query
// queryFn maps it to an error state.
export async function cookieJsonFetch(path: string): Promise<any> {
  const res = await fetch(apiUrl(path), { credentials: 'include' });
  if (!res.ok) {
    let msg = `Request failed (${res.status})`;
    try {
      const text = await res.text();
      const errBody = JSON.parse(text);
      if (errBody?.error?.message) msg = errBody.error.message;
      else if (errBody?.message) msg = errBody.message;
    } catch (e) {}
    throw new Error(msg);
  }
  let rawText: string;
  try {
    rawText = await res.text();
  } catch (e) {
    throw new Error(`Failed to read response body for ${path}`);
  }
  try {
    const body = JSON.parse(rawText);
    return body?.data !== undefined ? body.data : body;
  } catch (e) {
    console.error('[cookieJsonFetch] JSON parse error for', path, '— raw body (first 500 chars):', rawText.slice(0, 500));
    throw new Error(`JSON parse failed for ${path}: ${(e as Error).message}`);
  }
}

// Like cookieJsonFetch but returns the FULL response envelope ({data, page, meta})
// instead of unwrapping `data`. Needed by paginated endpoints (e.g. search) whose
// cursor/has_more live in the `page` sibling of `data`, which unwrapping strips.
// `init` carries an AbortSignal (and nothing else callers need today): a keyset
// paged list supersedes its in-flight page whenever the filters change, and
// `useInfiniteList` hands each fetch a signal it expects to be honoured.
export async function cookieJsonFetchEnvelope(path: string, init?: RequestInit): Promise<any> {
  const res = await fetch(apiUrl(path), { ...init, credentials: 'include' });
  if (!res.ok) {
    let msg = `Request failed (${res.status})`;
    try {
      const text = await res.text();
      const errBody = JSON.parse(text);
      if (errBody?.error?.message) msg = errBody.error.message;
      else if (errBody?.message) msg = errBody.message;
    } catch (e) {}
    throw new Error(msg);
  }
  return res.json();
}

export async function cookieMutation(path: string, method: string = 'POST', data?: any): Promise<any> {
  const res = await fetch(apiUrl(path), {
    method,
    headers: { 'Content-Type': 'application/json' },
    body: data ? JSON.stringify(data) : undefined,
    credentials: 'include'
  });
  if (!res.ok) {
    let msg = `Request failed (${res.status})`;
    try {
      const text = await res.text();
      const errBody = JSON.parse(text);
      if (errBody?.error?.message) msg = errBody.error.message;
      else if (errBody?.message) msg = errBody.message;
    } catch (e) {}
    throw new Error(msg);
  }
  const text = await res.text();
  if (!text) return {};
  try {
    const body = JSON.parse(text);
    return body?.data !== undefined ? body.data : body;
  } catch (e) {
    return text;
  }
}

/**
 * apiErrorText turns whatever a `queryFn`-based mutation's `.unwrap()` rejects with
 * into a human-readable string.
 *
 * These endpoints reject with an RTK `CUSTOM_ERROR` object
 * `{ status: "CUSTOM_ERROR", error: "<message>" }` — so the real message lives on
 * `err.error`, NOT `err.data` or `err.message`. A caller reading only
 * `err?.data?.error || err?.message` falls through to `String(err)` and renders the
 * useless "[object Object]". This also handles the `FetchBaseQueryError` shape
 * (`{ data: { error | message } }`), a plain `Error`, and a bare string.
 *
 * Lives here rather than beside one resource: every resource's endpoints module
 * needs the same unwrapping, and a second copy is a second thing to fix.
 */
export function apiErrorText(err: unknown, fallback = 'Something went wrong'): string {
  const nonBlank = (v: unknown): string | undefined =>
    typeof v === 'string' && v.trim() ? v : undefined;
  if (err == null) return fallback;
  if (typeof err === 'string') return nonBlank(err) ?? fallback;
  const e = err as any;
  const data = e.data;
  if (data) {
    if (typeof data === 'string') { const s = nonBlank(data); if (s) return s; }
    else {
      const s = nonBlank(data?.error?.message) ?? nonBlank(data?.error) ?? nonBlank(data?.message);
      if (s) return s;
    }
  }
  const fromError = nonBlank(e.error) ?? nonBlank(e.error?.message);
  if (fromError) return fromError;
  return nonBlank(e.message) ?? fallback;
}
