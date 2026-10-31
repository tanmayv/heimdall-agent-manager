import { apiUrl, errorFromResponse } from '../cookieFetch';
import { currentDeviceIdentity } from '../../services/deviceVault';
import { signedRequestHeaders } from '../../utils/vaultRequestSigner';
import type { McpConsentBody, McpConsentRequest } from '../../utils/mcpConsent';

const BASE = '/api/v1/mcp/oauth';

async function request<T>(method: string, suffix: string, value?: unknown): Promise<T> {
  const identity = currentDeviceIdentity();
  if (!identity) throw new Error('An approved unlocked Ninjy device is required');
  const path = `${BASE}${suffix}`;
  const body = value === undefined ? '' : JSON.stringify(value);
  const headers = await signedRequestHeaders(identity, identity.userId, method, path.split('?')[0], body);
  if (body) headers['Content-Type'] = 'application/json';
  const res = await fetch(apiUrl(path), { method, credentials: 'include', headers, body: body || undefined });
  if (!res.ok) throw await errorFromResponse(res);
  return res.json() as Promise<T>;
}

export function fetchMcpConsent(ticket: string): Promise<McpConsentRequest> {
  return request('GET', `/consent?request=${encodeURIComponent(ticket)}`);
}
export function completeMcpConsent(body: McpConsentBody): Promise<{ redirect: string }> {
  return request('POST', '/consent', body);
}
export interface McpConnection { grant: string; client: string; resource: string; mode: string; created_ms: number; revoked: boolean }
export function fetchMcpConnections(): Promise<McpConnection[]> { return request('GET', '/connections'); }
export function disconnectMcpConnection(grant: string): Promise<{ disconnected: boolean }> { return request('POST', '/disconnect', { grant }); }
