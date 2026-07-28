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
  const body = await res.json();
  return body?.data !== undefined ? body.data : body;
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
