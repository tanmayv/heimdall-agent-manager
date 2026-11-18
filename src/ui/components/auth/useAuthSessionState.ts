import { useEffect, useRef, useState } from 'react';
import type { AuthAccounts, AuthState, AuthUserIdentity } from './AuthUserContext';
import { addAccountHref, fetchAuthSessions, postLogoutAccount, postSwitchAccount, type AuthSessionAccount, type LogoutAccountOptions } from '../../auth/oidcSession';
import { apiUrl } from '../../api/cookieFetch';
import { analytics } from '../../analytics/analytics';
import { bootDeviceVault, stopDeviceVault } from '../../services/deviceVault';
import { setMcpWorkerEnabled } from '../../services/mcpWorker';
import { setExpectedUserId } from '../../utils/expectedUser';
import { showToast } from '../../store/toastSlice';
import { LAST_SEEN_USER_ID_KEY, readLastSeenUserId, recordAddAccountIntent, removeAppOwnedClientStorage, removeUserClientStorage, resolveSwitchedUserRoute, writeLastSeenUserId, writeUserLastRoute } from '../../utils/clientPersistence';

type SessionOptions = {
  dispatch: (action: any) => any;
  bootstrapAuth: () => Promise<AuthState>;
  clearPriorUserClientState: (dispatch: any, nextUserId: string) => void;
};

const userId = (user: AuthUserIdentity | null) => String(user?.user_id || '').trim();

/** REQ-SWFIX-MCP-1: the worker unregister must reach the hub before the cookie changes. */
const MCP_UNREGISTER_TIMEOUT_MS = 1500;
async function unregisterMcpWorkerBeforeSwitch(): Promise<void> {
  let timer: ReturnType<typeof setTimeout> | undefined;
  try {
    await Promise.race([
      setMcpWorkerEnabled(false).catch(() => undefined),
      new Promise<void>((resolve) => { timer = setTimeout(resolve, MCP_UNREGISTER_TIMEOUT_MS); }),
    ]);
  } finally {
    if (timer) clearTimeout(timer);
  }
}

const sameIdentity = (a: AuthUserIdentity | null, b: AuthUserIdentity | null) => JSON.stringify(a) === JSON.stringify(b);

/** AuthGate owns this hook; its switching render is a barrier for shell effect cleanup. */
export function useAuthSessionState({ dispatch, bootstrapAuth, clearPriorUserClientState }: SessionOptions): { auth: AuthState } & AuthAccounts {
  const [auth, setAuthState] = useState<AuthState>({ status: 'checking', user: null, error: '' });
  const [accounts, setAccounts] = useState<AuthSessionAccount[]>([]);
  const authRef = useRef(auth);
  const lastSeenUserRef = useRef(readLastSeenUserId());
  const running = useRef(false);
  // True while `running` is held by a background refreshIdentity (not a user action).
  const refreshing = useRef(false);
  // The global fetch observer also reports this hook's own /me probe; those answers are ours.
  const probing = useRef(false);
  // An auth-failure event that arrived mid-probe. It is our own feedback only if the probe failed too.
  const probeFailure = useRef(false);
  // A user click that arrived while another user action was settling; replayed by finish().
  const pendingAction = useRef<(() => void) | null>(null);
  const queuedRefresh = useRef(false);
  const generation = useRef(0);
  const mounted = useRef(false);
  const switchingCommit = useRef<((committed: boolean) => void) | null>(null);
  const refreshRef = useRef<(reason: string) => Promise<void>>(async () => {});

  function setAuth(next: AuthState) {
    authRef.current = next;
    // The account this document acts as, stamped on API calls (REQ-SWFIX-STALE-1).
    setExpectedUserId(next.status === 'authenticated' ? userId(next.user) : '');
    setAuthState(next);
  }

  useEffect(() => {
    // React runs the deleted shell's passive cleanups before this effect. Merely
    // calling setState and awaiting fetch would let React batch away the teardown.
    // Depend on the state object so a queued second switch also commits a barrier
    // when React batches away the intermediate authenticated render.
    if (auth.status === 'switching') {
      switchingCommit.current?.(true);
      switchingCommit.current = null;
    }
  }, [auth]);

  function enterSwitching(): Promise<boolean> {
    stopDeviceVault(dispatch);
    return new Promise((resolve) => {
      switchingCommit.current = resolve;
      setAuth({ status: 'switching', user: null, error: '' });
    });
  }

  function saveRoute(previous: AuthState) {
    if (previous.status === 'authenticated') writeUserLastRoute(userId(previous.user), window.location.hash);
  }

  function boot(id: string) {
    if (id) void bootDeviceVault(id, dispatch);
  }

  function applyIdentity(next: AuthState, previousId: string) {
    const id = userId(next.user);
    if (id && previousId && id !== previousId) {
      clearPriorUserClientState(dispatch, id);
      analytics.reset();
      window.location.hash = resolveSwitchedUserRoute(id, window.location.hash);
    }
    if (id) {
      writeLastSeenUserId(id);
      lastSeenUserRef.current = id;
      analytics.identify(id);
      boot(id);
    }
    setAuth(next);
  }

  function finish() {
    running.current = false;
    refreshing.current = false;
    const action = pendingAction.current;
    if (action && mounted.current) {
      pendingAction.current = null;
      action();
      return;
    }
    if (queuedRefresh.current && mounted.current) {
      queuedRefresh.current = false;
      void refreshRef.current('queued');
    }
  }

  async function loadAccounts() {
    return fetchAuthSessions(window.fetch.bind(window), apiUrl('/auth/sessions'));
  }

  async function refreshIdentity(_reason: string) {
    if (running.current) { queuedRefresh.current = true; return; }
    running.current = true;
    refreshing.current = true;
    const currentGeneration = generation.current;
    const valid = () => mounted.current && generation.current === currentGeneration;
    try {
      const previous = authRef.current;
      const previousId = userId(previous.user) || lastSeenUserRef.current;
      probing.current = true;
      probeFailure.current = false;
      let next: AuthState;
      try { next = await bootstrapAuth(); } finally { probing.current = false; }
      // A 401/403/account_mismatch seen mid-probe while the probe itself succeeded came from
      // another request (our own failed /me would not have authenticated): probe again.
      if (probeFailure.current && next.status === 'authenticated') queuedRefresh.current = true;
      probeFailure.current = false;
      if (!valid()) return;
      // REQ-SWFIX-IDENT-1: same account still signed in. Keep the auth object (so the
      // AuthUserProvider tree does not re-render) and do not reboot the vault.
      if (previous.status === 'authenticated' && next.status === 'authenticated' && userId(next.user) === userId(previous.user)) {
        if (!sameIdentity(previous.user, next.user)) setAuth(next);
        const ring = await loadAccounts().catch(() => null);
        if (ring && valid()) setAccounts(ring.accounts);
        return;
      }
      const changed = next.status === 'authenticated' && userId(next.user) !== previousId;
      if (changed || (previous.status === 'authenticated' && next.status !== 'authenticated')) {
        saveRoute(previous);
        if (!await enterSwitching() || !valid()) return;
      }
      if (next.status === 'authenticated') {
        applyIdentity(next, previousId);
        const ring = await loadAccounts().catch(() => null);
        if (ring && valid()) setAccounts(ring.accounts);
      } else {
        stopDeviceVault(dispatch);
        setAuth(next);
      }
    } finally {
      if (valid()) finish();
    }
  }
  refreshRef.current = refreshIdentity;

  async function rollback(previous: AuthState, error: unknown) {
    const ring = await loadAccounts().catch(() => null);
    if (!mounted.current) return;
    if (ring) setAccounts(ring.accounts);
    // A network error may arrive after the server changed the cookie. Reconcile
    // that case before opening any socket under the previous UI identity.
    if (ring && ring.activeUserId !== userId(previous.user)) {
      const next = await bootstrapAuth();
      if (!mounted.current) return;
      applyIdentity(next, userId(previous.user));
    } else {
      boot(userId(previous.user));
      setAuth(previous);
    }
    dispatch(showToast({ kind: 'error', title: 'Unable to update account', message: String((error as Error)?.message || error) }));
  }

  /**
   * REQ-SWFIX-IDENT-1: user actions pre-empt a background refresh (its generation goes
   * stale) and wait for another user action; they are never dropped silently.
   * Returns false when the action was deferred.
   */
  function claim(action: () => void): boolean {
    if (running.current && refreshing.current) {
      generation.current += 1;
      queuedRefresh.current = false;
      running.current = false;
      refreshing.current = false;
      if (authRef.current.status === 'switching') {
        // The pre-empted refresh was mid-switch; its outcome is unknown. Reconcile first.
        pendingAction.current = action;
        void refreshRef.current('preempted');
        return false;
      }
    } else if (running.current) {
      pendingAction.current = action;
      return false;
    }
    running.current = true;
    return true;
  }

  async function switchAccount(nextUserId: string): Promise<void> {
    if (!claim(() => { void switchAccount(nextUserId); })) return;
    const previous = authRef.current;
    if (previous.status !== 'authenticated' || !nextUserId || nextUserId === userId(previous.user)) { finish(); return; }
    saveRoute(previous);
    try {
      if (!await enterSwitching() || !mounted.current) return;
      await unregisterMcpWorkerBeforeSwitch();
      const result = await postSwitchAccount(window.fetch.bind(window), nextUserId, apiUrl('/auth/switch'));
      if (!mounted.current) return;
      setAccounts(result.accounts);
      applyIdentity({ status: 'authenticated', user: result.user, error: '' }, userId(previous.user));
    } catch (error) {
      await rollback(previous, error);
    } finally { if (mounted.current) finish(); }
  }

  async function signOutAccount(opts: LogoutAccountOptions = {}): Promise<void> {
    if (!claim(() => { void signOutAccount(opts); })) return;
    const previous = authRef.current;
    if (previous.status !== 'authenticated') { finish(); return; }
    const activeId = userId(previous.user);
    const targetId = opts.userId || activeId;
    const leavingActive = Boolean(opts.all || targetId === activeId);
    try {
      if (leavingActive) {
        saveRoute(previous);
        if (!await enterSwitching() || !mounted.current) return;
        await unregisterMcpWorkerBeforeSwitch();
      }
      const result = await postLogoutAccount(window.fetch.bind(window), opts, apiUrl('/auth/logout'));
      if (!mounted.current) return;
      if (opts.all || !result.activeUserId) {
        stopDeviceVault(dispatch);
        removeAppOwnedClientStorage();
        clearPriorUserClientState(dispatch, '');
        analytics.reset();
        setAccounts([]);
        setAuth({ status: 'unauthenticated', user: null, error: '' });
        window.location.assign(result.logoutUrl || '/');
        return;
      }
      removeUserClientStorage(targetId);
      setAccounts(result.accounts);
      if (leavingActive) {
        const next = result.switchedUser
          ? { status: 'authenticated' as const, user: result.switchedUser, error: '' }
          : await bootstrapAuth();
        applyIdentity(next, activeId);
      }
    } catch (error) {
      if (leavingActive) await rollback(previous, error);
      else dispatch(showToast({ kind: 'error', title: 'Unable to sign out account', message: String((error as Error)?.message || error) }));
    } finally { if (mounted.current) finish(); }
  }

  function addAccount() {
    if (!claim(addAccount)) return;
    const previous = authRef.current;
    if (previous.status !== 'authenticated') { finish(); return; }
    // REQ-SWFIX-ROUTE-1: remember where this account was, and send the new login home.
    saveRoute(previous);
    recordAddAccountIntent();
    window.location.assign(addAccountHref({ pathname: window.location.pathname, search: window.location.search, hash: '#/home' }));
    // Electron opens the login in a popup and this document stays mounted; a cancelled
    // popup cannot reach this hook, so never hold the action lock across its lifetime.
    finish();
  }

  useEffect(() => {
    mounted.current = true;
    const refresh = (reason: string) => { void refreshRef.current(reason); };
    // The global fetch observer also emits for this hook's own /me probe.
    // It already handles those answers; queuing them would recurse on 401/403.
    // Answers that arrive mid-refresh are queued (not dropped) while an account is signed
    // in; once signed out the probe's own 401 must not re-queue forever.
    const onAuthFailure = (reason: string) => {
      if (!running.current) refresh(reason);
      else if (probing.current) probeFailure.current = true;
      else if (authRef.current.status === 'authenticated') queuedRefresh.current = true;
    };
    const onUnauthenticated = () => onAuthFailure('unauthenticated');
    const onForbidden = () => onAuthFailure('forbidden');
    const onFocus = () => refresh('focus');
    const onVisibility = () => { if (document.visibilityState === 'visible') refresh('visibilitychange'); };
    const onUserWsReconnect = () => refresh('user-ws-reconnect');
    const onStorage = (event: StorageEvent) => {
      if (event.key === LAST_SEEN_USER_ID_KEY && event.newValue !== userId(authRef.current.user)) refresh('storage');
    };
    const retryTimer = window.setInterval(() => {
      if (authRef.current.status === 'unavailable') refresh('unavailable-retry');
    }, 5000);
    window.addEventListener('heimdall:api-unauthenticated', onUnauthenticated);
    window.addEventListener('heimdall:api-forbidden', onForbidden);
    window.addEventListener('focus', onFocus);
    window.addEventListener('storage', onStorage);
    document.addEventListener('visibilitychange', onVisibility);
    window.addEventListener('heimdall:user-ws-reconnected', onUserWsReconnect);
    refresh('initial');
    return () => {
      mounted.current = false;
      generation.current += 1;
      running.current = false;
      refreshing.current = false;
      pendingAction.current = null;
      queuedRefresh.current = false;
      switchingCommit.current?.(false);
      switchingCommit.current = null;
      stopDeviceVault(dispatch);
      window.clearInterval(retryTimer);
      window.removeEventListener('heimdall:api-unauthenticated', onUnauthenticated);
      window.removeEventListener('heimdall:api-forbidden', onForbidden);
      window.removeEventListener('focus', onFocus);
      window.removeEventListener('storage', onStorage);
      document.removeEventListener('visibilitychange', onVisibility);
      window.removeEventListener('heimdall:user-ws-reconnected', onUserWsReconnect);
    };
  }, [dispatch, bootstrapAuth, clearPriorUserClientState]);

  return { auth, accounts, switchAccount, signOutAccount, addAccount };
}
