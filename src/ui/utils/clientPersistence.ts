export const APP_STORAGE_PREFIXES = ['odin.', 'heimdall.', 'heimdall:'] as const;
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
  for (const kind of ['localStorage', 'sessionStorage'] as const) {
    try {
      const storage = window[kind];
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

/** Explicit logout removes only this user's namespaced preferences and routes. */
export function removeUserClientStorage(userId: string): void {
  if (typeof window === 'undefined' || !userId) return;
  const prefix = `heimdall.user.${encodeURIComponent(userId)}.`;
  for (const kind of ['localStorage', 'sessionStorage'] as const) {
    try {
      const storage = window[kind];
      for (const key of storageKeys(storage)) {
        if (key.startsWith(prefix)) storage.removeItem(key);
      }
    } catch { /* best effort, including storage accessors that throw */ }
  }
}

export function readUserLastRoute(userId: string): string {
  if (typeof window === 'undefined' || !userId) return '';
  try { return window.localStorage.getItem(userScopedStorageKey('lastRoute', userId)) || ''; }
  catch { return ''; }
}

export function writeUserLastRoute(userId: string, routeHash: string): void {
  if (typeof window === 'undefined' || !userId) return;
  try { window.localStorage.setItem(userScopedStorageKey('lastRoute', userId), routeHash); }
  catch { /* ignore */ }
}

export function resolveSwitchedUserRoute(nextUserId: string, currentHash: string): string {
  return readUserLastRoute(nextUserId) || (
    /^#\/(conversations|c|chains)(\/|[?]|$)/.test(currentHash) ? '#/home' : currentHash || '#/home'
  );
}

export const ADD_ACCOUNT_INTENT_KEY = 'heimdall:add-account-intent-at';
export const ADD_ACCOUNT_INTENT_TTL_MS = 10 * 60_000;

/** Tab-local, single-use acknowledgement of an intentional OIDC account addition. */
export function recordAddAccountIntent(now = Date.now()): void {
  if (typeof window === 'undefined') return;
  try { window.sessionStorage.setItem(ADD_ACCOUNT_INTENT_KEY, String(now)); }
  catch { /* ignore */ }
}

export function consumeAddAccountIntent(now = Date.now()): boolean {
  if (typeof window === 'undefined') return false;
  try {
    const storage = window.sessionStorage;
    const raw = storage.getItem(ADD_ACCOUNT_INTENT_KEY);
    storage.removeItem(ADD_ACCOUNT_INTENT_KEY);
    if (!raw?.trim()) return false;
    const at = Number(raw);
    return Number.isFinite(at) && now >= at && now - at < ADD_ACCOUNT_INTENT_TTL_MS;
  } catch { return false; }
}

export function readChainOverviewCollapsedState(agentInstanceId?: string): Record<string, boolean> {
  if (typeof window === 'undefined') return {};
  try {
    const key = 'heimdall:chainOverview:collapsed:' + (agentInstanceId || 'default');
    const raw = window.localStorage.getItem(key);
    if (!raw) return {};
    const parsed = JSON.parse(raw);
    if (parsed && typeof parsed === 'object' && !Array.isArray(parsed)) {
      return parsed as Record<string, boolean>;
    }
    return {};
  } catch {
    return {};
  }
}

export function writeChainOverviewCollapsedState(state: Record<string, boolean>, agentInstanceId?: string): void {
  if (typeof window === 'undefined') return;
  try {
    const key = 'heimdall:chainOverview:collapsed:' + (agentInstanceId || 'default');
    window.localStorage.setItem(key, JSON.stringify(state));
  } catch {
    /* ignore */
  }
}

// --- Sidebar Chain Filter (REQ-CHAIN-UI-SIDEBAR-1) --------------------------
// --- Workspace (Main + Aux) Persistence --------------------------------------
// Never keyed by task chain. The open Main pane set lives in the URL and split
// geometry per id set in store/splitGroups.ts; here: the per-agent aux tab
// strips and the aux width.
export const AUX_PANES_STORAGE_KEY = 'heimdall:aux-panes:v1';
export const WORKSPACE_CHROME_STORAGE_KEY = 'heimdall:workspace-chrome:v1';

/** Superseded keys (removed on hydrate): chain-keyed workbench, window tiling,
 *  and the short-lived single global workspace layout. */
export const LEGACY_WORKSPACE_LAYOUT_STORAGE_KEY = 'heimdall:workspace-layout:v1';
export const LEGACY_WINDOW_LAYOUT_STORAGE_KEY = 'heimdall:window-layout:v1';
export const LEGACY_WORKBENCH_LAYOUT_STORAGE_PREFIX = 'heimdall:workbench-layout:v1:';

function readJsonObject<T>(key: string): T | null {
  if (typeof window === 'undefined') return null;
  try {
    const raw = window.localStorage.getItem(key);
    if (!raw) return null;
    const parsed = JSON.parse(raw);
    return parsed && typeof parsed === 'object' && !Array.isArray(parsed) ? (parsed as T) : null;
  } catch {
    return null;
  }
}

function writeJsonObject(key: string, value: unknown): void {
  if (typeof window === 'undefined') return;
  try {
    if (value === null || value === undefined) {
      window.localStorage.removeItem(key);
      return;
    }
    window.localStorage.setItem(key, JSON.stringify(value));
  } catch {
    /* ignore */
  }
}

/** Raw persisted aux strips; validated by `sanitizeAuxPanesState` on hydrate. */
export function readAuxPanesState<T = any>(): T | null {
  return readJsonObject<T>(AUX_PANES_STORAGE_KEY);
}

export function writeAuxPanesState(state: unknown): void {
  writeJsonObject(AUX_PANES_STORAGE_KEY, state);
}

export function readWorkspaceChromeState<T = any>(): T | null {
  return readJsonObject<T>(WORKSPACE_CHROME_STORAGE_KEY);
}

export function writeWorkspaceChromeState(state: { auxWidth: number | null }): void {
  writeJsonObject(WORKSPACE_CHROME_STORAGE_KEY, { auxWidth: state.auxWidth });
}

export function removeLegacyWorkbenchStorage(): void {
  if (typeof window === 'undefined') return;
  try {
    const storage = window.localStorage;
    for (const key of storageKeys(storage)) {
      if (
        key === LEGACY_WINDOW_LAYOUT_STORAGE_KEY ||
        key === LEGACY_WORKSPACE_LAYOUT_STORAGE_KEY ||
        key.startsWith(LEGACY_WORKBENCH_LAYOUT_STORAGE_PREFIX)
      ) {
        storage.removeItem(key);
      }
    }
  } catch {
    /* ignore */
  }
}

// --- Per-Instance Composer Draft Persistence (R3.1) -------------------------
export const COMPOSER_DRAFT_KEY_PREFIX = 'heimdall:composer:draft:';

export function getComposerDraftKey(agentInstanceId: string): string {
  return `${COMPOSER_DRAFT_KEY_PREFIX}${agentInstanceId || 'default'}`;
}

/** Restart preparation must observe storage failure instead of best-effort writes. */
export function writeClientStorageChecked(key: string, value: string | null): void {
  if (typeof window === 'undefined') throw new Error('Client storage unavailable');
  if (value === null) window.localStorage.removeItem(key);
  else window.localStorage.setItem(key, value);
  if (window.localStorage.getItem(key) !== value) throw new Error('Client storage verification failed');
}

export function writeComposerDraftChecked(agentInstanceId: string, draft: string): void {
  if (!agentInstanceId) throw new Error('Composer identity unavailable');
  writeClientStorageChecked(getComposerDraftKey(agentInstanceId), draft || null);
}

export function readComposerDraft(agentInstanceId: string): string {
  if (typeof window === 'undefined' || !agentInstanceId) return '';
  try {
    return window.localStorage.getItem(getComposerDraftKey(agentInstanceId)) || '';
  } catch {
    return '';
  }
}

export function writeComposerDraft(
  agentInstanceId: string,
  draft: string,
): void {
  if (typeof window === 'undefined' || !agentInstanceId) return;
  try {
    const key = getComposerDraftKey(agentInstanceId);
    if (!draft) {
      window.localStorage.removeItem(key);
    } else {
      window.localStorage.setItem(key, draft);
    }
  } catch {
    /* ignore */
  }
}
