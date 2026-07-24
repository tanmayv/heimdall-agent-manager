// UI-14/UI-15: shared cookie-authenticated JSON fetch helper for rewrite endpoints
// served behind the trusted proxy. The rewrite app uses the SAME cookie auth
// session as `/api/v1/me` (`credentials: 'include'`), NOT the legacy per-client
// token session (`withSessionQuery` + `session.clientToken`). Centralizing this
// stops each new cookie endpoint from reinventing its own apiUrl/fetch wrapper.

export function apiUrl(path: string): string {
  return path.startsWith('/api/v1') ? path : `/api/v1${path.startsWith('/') ? path : `/${path}`}`;
}

// GET `/api/v1/...` with cookie auth. Returns the unwrapped `data` array if the
// response is a list, otherwise the parsed body. Throws on non-2xx so RTK Query
// queryFn maps it to an error state.
export async function cookieJsonFetch(path: string): Promise<any> {
  const res = await fetch(apiUrl(path), { credentials: 'include' });
  if (!res.ok) throw new Error(`Request failed (${res.status})`);
  const body = await res.json();
  return Array.isArray(body?.data) ? body.data : body;
}
