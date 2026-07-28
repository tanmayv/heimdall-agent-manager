export const APP_STORAGE_PREFIXES = ['odin.', 'heimdall.'] as const;
export const LAST_SEEN_USER_ID_KEY = 'heimdall.lastSeenUserId';

function storageKeys(storage: Storage): string[] {
  const keys: string[] = [];
  for (let index = 0; index < storage.length; index += 1) {
    const key = storage.key(index);
    if (key) keys.push(key);
  }
  return keys;
}

export function isAppOwnedStorageKey(key: string): boolean {
  return APP_STORAGE_PREFIXES.some((prefix) => key.startsWith(prefix));
}

export function removeAppOwnedClientStorage() {
  if (typeof window === 'undefined') return;
  for (const storage of [window.localStorage, window.sessionStorage]) {
    try {
      for (const key of storageKeys(storage)) {
        if (isAppOwnedStorageKey(key)) storage.removeItem(key);
      }
    } catch {
      // Best-effort cleanup: storage can be unavailable in hardened contexts.
    }
  }
}

export function readLastSeenUserId(): string {
  if (typeof window === 'undefined') return '';
  try { return window.localStorage.getItem(LAST_SEEN_USER_ID_KEY) || ''; } catch { return ''; }
}

export function writeLastSeenUserId(userId: string) {
  if (typeof window === 'undefined' || !userId) return;
  try { window.localStorage.setItem(LAST_SEEN_USER_ID_KEY, userId); } catch { /* ignore */ }
}

export function userScopedStorageKey(baseKey: string, userId = readLastSeenUserId()): string {
  const safeUserId = encodeURIComponent(userId || 'anonymous');
  const safeBase = baseKey.replace(/[^a-zA-Z0-9._:-]+/g, '_');
  return `heimdall.user.${safeUserId}.${safeBase}`;
}
