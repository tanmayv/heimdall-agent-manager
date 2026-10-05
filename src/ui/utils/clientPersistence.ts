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

// Tab order here is only the set of valid values; the visual order lives in the
// panel that renders them. Kept as one const so a new tab cannot be added to the
// type while a storage read silently keeps rejecting it.
export const RIGHT_SIDEBAR_TABS = ['tasks', 'files', 'rundir', 'shells', 'chain', 'vcs'] as const;

export type RightSidebarTab = (typeof RIGHT_SIDEBAR_TABS)[number];

export function isRightSidebarTab(value: unknown): value is RightSidebarTab {
  return RIGHT_SIDEBAR_TABS.includes(value as RightSidebarTab);
}

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

export type SidebarPersistenceScope = {
  chainId?: string;
  instanceId?: string;
};

function resolveSidebarScope(
  scopeOrInstanceId?: string | SidebarPersistenceScope,
  maybeChainId?: string
): { chainId?: string; instanceId?: string } {
  if (typeof scopeOrInstanceId === 'object' && scopeOrInstanceId !== null) {
    return {
      chainId: scopeOrInstanceId.chainId || undefined,
      instanceId: scopeOrInstanceId.instanceId || undefined,
    };
  }
  return {
    chainId: maybeChainId || undefined,
    instanceId: typeof scopeOrInstanceId === 'string' ? scopeOrInstanceId || undefined : undefined,
  };
}

export function readRightSidebarOpen(instanceId?: string): boolean;
export function readRightSidebarOpen(scope?: SidebarPersistenceScope): boolean;
export function readRightSidebarOpen(
  scopeOrInstanceId?: string | SidebarPersistenceScope,
  chainId?: string
): boolean {
  if (typeof window === 'undefined') return false;
  try {
    const scope = resolveSidebarScope(scopeOrInstanceId, chainId);
    if (scope.chainId) {
      const chainRaw = window.localStorage.getItem(`heimdall:sidebar:open:chain:${scope.chainId}`);
      if (chainRaw !== null) {
        return chainRaw === 'true' || chainRaw === '1';
      }
    }
    if (scope.instanceId) {
      const instanceRaw = window.localStorage.getItem(`heimdall:sidebar:open:${scope.instanceId}`);
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

export function writeRightSidebarOpen(open: boolean, instanceId?: string): void;
export function writeRightSidebarOpen(open: boolean, scope?: SidebarPersistenceScope): void;
export function writeRightSidebarOpen(
  open: boolean,
  scopeOrInstanceId?: string | SidebarPersistenceScope,
  chainId?: string
): void {
  if (typeof window === 'undefined') return;
  try {
    const scope = resolveSidebarScope(scopeOrInstanceId, chainId);
    const val = open ? 'true' : 'false';
    window.localStorage.setItem(RIGHT_SIDEBAR_OPEN_KEY, val);
    if (scope.instanceId) {
      window.localStorage.setItem(`heimdall:sidebar:open:${scope.instanceId}`, val);
    }
    if (scope.chainId) {
      window.localStorage.setItem(`heimdall:sidebar:open:chain:${scope.chainId}`, val);
    }
  } catch {
    /* ignore */
  }
}

export function readRightSidebarTab(instanceId?: string): RightSidebarTab | null;
export function readRightSidebarTab(scope?: SidebarPersistenceScope): RightSidebarTab | null;
export function readRightSidebarTab(
  scopeOrInstanceId?: string | SidebarPersistenceScope,
  chainId?: string
): RightSidebarTab | null {
  if (typeof window === 'undefined') return null;
  try {
    const scope = resolveSidebarScope(scopeOrInstanceId, chainId);
    if (scope.chainId) {
      const chainRaw = window.localStorage.getItem(`heimdall:sidebar:tab:chain:${scope.chainId}`);
      if (chainRaw === 'rundir') return 'files';
      if (isRightSidebarTab(chainRaw)) return chainRaw;
    }
    if (scope.instanceId) {
      const instanceRaw = window.localStorage.getItem(`heimdall:sidebar:tab:${scope.instanceId}`);
      if (instanceRaw === 'rundir') return 'files';
      if (isRightSidebarTab(instanceRaw)) return instanceRaw;
    }
    const raw = window.localStorage.getItem(RIGHT_SIDEBAR_TAB_KEY);
    if (raw === 'rundir') return 'files';
    if (isRightSidebarTab(raw)) return raw;
    return null;
  } catch {
    return null;
  }
}

export function writeRightSidebarTab(tab: RightSidebarTab, instanceId?: string): void;
export function writeRightSidebarTab(tab: RightSidebarTab, scope?: SidebarPersistenceScope): void;
export function writeRightSidebarTab(
  tab: RightSidebarTab,
  scopeOrInstanceId?: string | SidebarPersistenceScope,
  chainId?: string
): void {
  if (typeof window === 'undefined') return;
  try {
    const scope = resolveSidebarScope(scopeOrInstanceId, chainId);
    const targetTab = tab === 'rundir' ? 'files' : tab;
    if (isRightSidebarTab(targetTab)) {
      window.localStorage.setItem(RIGHT_SIDEBAR_TAB_KEY, targetTab);
      if (scope.instanceId) {
        window.localStorage.setItem(`heimdall:sidebar:tab:${scope.instanceId}`, targetTab);
      }
      if (scope.chainId) {
        window.localStorage.setItem(`heimdall:sidebar:tab:chain:${scope.chainId}`, targetTab);
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

// --- Agent Monitor pinned agents (REQ-AM-1) --------------------------------
// The set of agent-instance ids the user has pinned to the /agent-monitor grid,
// persisted per-browser. Reads fail soft to an empty list; writes are best-effort.
const MONITOR_KEY = 'heimdall:monitor:pinned-agents';

export function readPinnedMonitorAgents(): string[] {
  if (typeof window === 'undefined') return [];
  try {
    const parsed = JSON.parse(window.localStorage.getItem(MONITOR_KEY) || '[]');
    return Array.isArray(parsed) ? (parsed as string[]) : [];
  } catch {
    return [];
  }
}

export function writePinnedMonitorAgents(ids: string[]): void {
  if (typeof window === 'undefined') return;
  try {
    window.localStorage.setItem(MONITOR_KEY, JSON.stringify(ids));
  } catch {
    /* ignore */
  }
}

export function addPinnedMonitorAgent(id: string): void {
  const cur = readPinnedMonitorAgents();
  if (!cur.includes(id)) writePinnedMonitorAgents([...cur, id]);
}

export function removePinnedMonitorAgent(id: string): void {
  writePinnedMonitorAgents(readPinnedMonitorAgents().filter((x) => x !== id));
}

// --- Bottom Dock persistence (REQ-DOCK-1) -----------------------------------
export const BOTTOM_DOCK_OPEN_KEY = 'heimdall.bottomDock.open';
export const BOTTOM_DOCK_HEIGHT_KEY = 'heimdall.bottomDock.height';
export const BOTTOM_DOCK_DEFAULT_HEIGHT = 260;
export const BOTTOM_DOCK_MIN_HEIGHT = 140;

export function readBottomDockOpen(): boolean {
  if (typeof window === 'undefined') return false;
  try {
    return window.localStorage.getItem(BOTTOM_DOCK_OPEN_KEY) === 'true';
  } catch {
    return false;
  }
}

export function writeBottomDockOpen(open: boolean): void {
  if (typeof window === 'undefined') return;
  try {
    window.localStorage.setItem(BOTTOM_DOCK_OPEN_KEY, open ? 'true' : 'false');
  } catch {
    /* ignore */
  }
}

/**
 * Restore the stored dock height, clamped into `[BOTTOM_DOCK_MIN_HEIGHT, maxHeight]`.
 *
 * REQ-DOCK-TOUCH-1: the floor used to be the only bound, and desktop and phone share a
 * storage origin — so a 650px height dragged on a laptop was restored verbatim on a 402px
 * phone and painted a dock taller than the screen. Callers pass the CURRENT visible region
 * as `maxHeight` so a stale value cannot outlive the viewport it was chosen on. Omitting
 * `maxHeight` keeps the old floor-only behaviour for callers with no viewport to measure.
 */
export function readBottomDockHeight(maxHeight?: number): number {
  const ceiling = Number.isFinite(maxHeight) && (maxHeight as number) >= BOTTOM_DOCK_MIN_HEIGHT
    ? (maxHeight as number)
    : Number.POSITIVE_INFINITY;
  const clamp = (value: number) => Math.min(ceiling, Math.max(BOTTOM_DOCK_MIN_HEIGHT, value));
  if (typeof window === 'undefined') return clamp(BOTTOM_DOCK_DEFAULT_HEIGHT);
  try {
    const raw = window.localStorage.getItem(BOTTOM_DOCK_HEIGHT_KEY);
    if (!raw) return clamp(BOTTOM_DOCK_DEFAULT_HEIGHT);
    const parsed = Number(raw);
    if (Number.isFinite(parsed) && parsed >= BOTTOM_DOCK_MIN_HEIGHT) {
      return clamp(parsed);
    }
    return clamp(BOTTOM_DOCK_DEFAULT_HEIGHT);
  } catch {
    return clamp(BOTTOM_DOCK_DEFAULT_HEIGHT);
  }
}

export function writeBottomDockHeight(height: number): void {
  if (typeof window === 'undefined') return;
  try {
    window.localStorage.setItem(BOTTOM_DOCK_HEIGHT_KEY, String(Math.round(height)));
  } catch {
    /* ignore */
  }
}

// --- Sidebar Chain Filter (REQ-CHAIN-UI-SIDEBAR-1) --------------------------
export const SIDEBAR_CHAIN_FILTER_KEY = 'heimdall:sidebar-chain-filter';
export type SidebarChainFilter = 'all' | 'active';

export function isSidebarChainFilter(val: unknown): val is SidebarChainFilter {
  return val === 'all' || val === 'active';
}

export function readSidebarChainFilter(): SidebarChainFilter {
  if (typeof window === 'undefined') return 'all';
  try {
    const raw = window.localStorage.getItem(SIDEBAR_CHAIN_FILTER_KEY);
    if (raw === 'active' || raw === 'active-only') return 'active';
    return 'all';
  } catch {
    return 'all';
  }
}

export function writeSidebarChainFilter(filter: SidebarChainFilter): void {
  if (typeof window === 'undefined') return;
  try {
    window.localStorage.setItem(SIDEBAR_CHAIN_FILTER_KEY, filter);
  } catch {
    /* ignore */
  }
}

export type ChainStatusLike = {
  chainId?: string;
  status?: string;
  archived?: boolean;
  projectId?: string;
};

export function filterSidebarChains<T extends ChainStatusLike>(
  chains: T[],
  filter: SidebarChainFilter,
  archivedProjectIds?: Set<string>,
): T[] {
  return chains.filter((c) => {
    if (c.status === 'archived' || Boolean(c.archived)) return false;
    if (c.projectId && archivedProjectIds && archivedProjectIds.has(c.projectId)) return false;
    if (filter === 'active' && c.status !== 'active') return false;
    return true;
  });
}



