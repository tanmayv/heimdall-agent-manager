// REQ-SWFIX-STALE-1 / REQ-SWFIX-SEND-1: the account THIS browser context believes is
// signed in. It is in-memory and per document on purpose: localStorage is shared by
// every tab, so it would follow another tab's switch and defeat stale-context detection.

export const EXPECTED_USER_HEADER = 'X-Heimdall-Expected-User';
export const ACCOUNT_MISMATCH_EVENT = 'heimdall:account-mismatch';
export const ACCOUNT_MISMATCH_CODE = 'account_mismatch';

let expectedUserId = '';

export function setExpectedUserId(userId: string | null | undefined): void {
  expectedUserId = String(userId || '').trim();
}

export function getExpectedUserId(): string {
  return expectedUserId;
}

/** Endpoints that decide or change which account is active must see the real session. */
export function isAccountNeutralPath(pathname: string): boolean {
  return pathname === '/api/v1/me' || pathname.startsWith('/api/v1/auth/');
}

/** True for the hub's 409 `account_mismatch` answer (does not consume the body). */
export async function isAccountMismatchResponse(response: Response): Promise<boolean> {
  if (response.status !== 409) return false;
  try {
    const body = await response.clone().json();
    return body?.error?.code === ACCOUNT_MISMATCH_CODE || body?.code === ACCOUNT_MISMATCH_CODE;
  } catch {
    return false;
  }
}
