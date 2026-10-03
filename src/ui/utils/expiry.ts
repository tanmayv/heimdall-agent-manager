/**
 * Expiration utilities for memories and action cards.
 * REQ-EXPIRY-UI-3: Expiration filtering in UI.
 */

/**
 * Returns true if m.expires_at is non-empty and new Date(m.expires_at).getTime() <= Date.now().
 */
export function isMemoryExpired(m: { expires_at?: string; expiresAt?: string } | null | undefined): boolean {
  const expiresAt = m?.expires_at || m?.expiresAt;
  if (!expiresAt || typeof expiresAt !== 'string' || !expiresAt.trim()) {
    return false;
  }
  const time = new Date(expiresAt).getTime();
  if (Number.isNaN(time)) {
    return false;
  }
  return time <= Date.now();
}

/**
 * Returns true if c.ttl_at is non-empty and new Date(c.ttl_at).getTime() <= Date.now().
 */
export function isCardExpired(c: { ttl_at?: string } | null | undefined): boolean {
  if (!c?.ttl_at || typeof c.ttl_at !== 'string' || !c.ttl_at.trim()) {
    return false;
  }
  const time = new Date(c.ttl_at).getTime();
  if (Number.isNaN(time)) {
    return false;
  }
  return time <= Date.now();
}
