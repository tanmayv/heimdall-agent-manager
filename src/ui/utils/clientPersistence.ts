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

export const RIGHT_SIDEBAR_WIDTH_KEY = 'heimdall.rightSidebar.width';
export const RIGHT_SIDEBAR_OPEN_KEY = 'heimdall.rightSidebar.open';
export const RIGHT_SIDEBAR_TAB_KEY = 'heimdall.rightSidebar.tab';

export const RIGHT_SIDEBAR_DEFAULT_WIDTH = 480;
export const RIGHT_SIDEBAR_MIN_WIDTH = 360;
export const CHAT_VIEW_MIN_WIDTH = 380;

export type RightSidebarTab = 'tasks' | 'files' | 'rundir' | 'jobs' | 'chain';

export function clampRightSidebarWidth(width: number, maxAllowedWidth?: number): number {
  if (!Number.isFinite(width) || Number.isNaN(width) || width <= 0) {
    return RIGHT_SIDEBAR_DEFAULT_WIDTH;
  }
  let clamped = Math.max(RIGHT_SIDEBAR_MIN_WIDTH, Math.round(width));
  if (typeof maxAllowedWidth === 'number' && Number.isFinite(maxAllowedWidth) && maxAllowedWidth >= RIGHT_SIDEBAR_MIN_WIDTH) {
    clamped = Math.min(clamped, Math.round(maxAllowedWidth));
  }
  return clamped;
}

export function readRightSidebarWidth(): number {
  if (typeof window === 'undefined') return RIGHT_SIDEBAR_DEFAULT_WIDTH;
  try {
    const raw = window.localStorage.getItem(RIGHT_SIDEBAR_WIDTH_KEY);
    if (!raw) return RIGHT_SIDEBAR_DEFAULT_WIDTH;
    const parsed = Number(raw);
    return clampRightSidebarWidth(parsed);
  } catch {
    return RIGHT_SIDEBAR_DEFAULT_WIDTH;
  }
}

export function writeRightSidebarWidth(width: number): void {
  if (typeof window === 'undefined') return;
  try {
    const clamped = clampRightSidebarWidth(width);
    window.localStorage.setItem(RIGHT_SIDEBAR_WIDTH_KEY, String(clamped));
  } catch {
    /* ignore */
  }
}

export function readRightSidebarOpen(instanceId?: string): boolean {
  if (typeof window === 'undefined') return false;
  try {
    if (instanceId) {
      const instanceRaw = window.localStorage.getItem(`heimdall:sidebar:open:${instanceId}`);
      if (instanceRaw !== null) {
        return instanceRaw === 'true' || instanceRaw === '1';
      }
    }
    const raw = window.localStorage.getItem(RIGHT_SIDEBAR_OPEN_KEY);
    if (raw === null) return false;
    return raw === 'true' || raw === '1';
  } catch {
    return false;
  }
}

export function writeRightSidebarOpen(open: boolean, instanceId?: string): void {
  if (typeof window === 'undefined') return;
  try {
    const val = open ? 'true' : 'false';
    window.localStorage.setItem(RIGHT_SIDEBAR_OPEN_KEY, val);
    if (instanceId) {
      window.localStorage.setItem(`heimdall:sidebar:open:${instanceId}`, val);
    }
  } catch {
    /* ignore */
  }
}

export function readRightSidebarTab(instanceId?: string): RightSidebarTab | null {
  if (typeof window === 'undefined') return null;
  try {
    if (instanceId) {
      const instanceRaw = window.localStorage.getItem(`heimdall:sidebar:tab:${instanceId}`);
      if (instanceRaw === 'tasks' || instanceRaw === 'files' || instanceRaw === 'rundir' || instanceRaw === 'jobs' || instanceRaw === 'chain') {
        return instanceRaw;
      }
    }
    const raw = window.localStorage.getItem(RIGHT_SIDEBAR_TAB_KEY);
    if (raw === 'tasks' || raw === 'files' || raw === 'rundir' || raw === 'jobs' || raw === 'chain') {
      return raw;
    }
    return null;
  } catch {
    return null;
  }
}

export function writeRightSidebarTab(tab: RightSidebarTab, instanceId?: string): void {
  if (typeof window === 'undefined') return;
  try {
    if (tab === 'tasks' || tab === 'files' || tab === 'rundir' || tab === 'jobs' || tab === 'chain') {
      window.localStorage.setItem(RIGHT_SIDEBAR_TAB_KEY, tab);
      if (instanceId) {
        window.localStorage.setItem(`heimdall:sidebar:tab:${instanceId}`, tab);
      }
    }
  } catch {
    /* ignore */
  }
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

