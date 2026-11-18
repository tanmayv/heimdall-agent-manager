import './helpers/vaultEndpointHarness.ts';
import { makeVaultStore, unlockVault } from './helpers/vaultEndpointHarness.ts';
import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import React, { act, useEffect } from 'react';
import { createRoot } from 'react-dom/client';
import { Provider } from 'react-redux';
import { JSDOM, VirtualConsole } from 'jsdom';
import { useAuthSessionState } from '../src/ui/components/auth/useAuthSessionState.ts';
import { useUserWebSocket } from '../src/ui/api/useUserWebSocket.ts';
import { subscribeMcpWorker, isMcpWorkerEnabled } from '../src/ui/services/mcpWorker.ts';
import * as dv from '../src/ui/services/deviceVault.ts';
import * as identity from '../src/ui/utils/deviceIdentity.ts';
import * as persistence from '../src/ui/utils/clientPersistence.ts';
import { getActiveVaultKey } from '../src/ui/utils/vaultCrypto.ts';
import { getKeyringSession } from '../src/ui/utils/vaultKeyringSession.ts';
import { heimdallApi } from '../src/ui/api/heimdallApi.ts';
import { clearUserClientState } from '../src/ui/store/chatSlice.ts';
import deviceVaultReducer from '../src/ui/store/deviceVaultSlice.ts';
import toastReducer from '../src/ui/store/toastSlice.ts';
import type { AuthState } from '../src/ui/components/auth/AuthUserContext.ts';

const { AuthAccountsProvider } = await import('../src/ui/components/auth/AuthUserContext.tsx');
const { default: AccountSwitcher } = await import('../src/ui/components/shell/AccountSwitcher.tsx');
const { default: AccountPanel } = await import('../src/ui/components/settings/AccountPanel.tsx');

const account = (id: string, active = false) => ({
  user_id: id, name: id, display_name: id, email: `${id}@example.test`, active, expires_at_ms: 9999999999999,
});

test('REQ-ACCT-UI-2 Case 14: sidebar and settings render account controls and dispatch each action', async () => {
  const dom = new JSDOM('<div id="root"></div><button id="outside">Outside</button>', { url: 'https://ui.test/' });
  const saved = new Map<string, PropertyDescriptor | undefined>();
  for (const [key, value] of Object.entries({ window: dom.window, document: dom.window.document, IS_REACT_ACT_ENVIRONMENT: true })) {
    saved.set(key, Object.getOwnPropertyDescriptor(globalThis, key));
    Object.defineProperty(globalThis, key, { configurable: true, writable: true, value });
  }
  const root = createRoot(dom.window.document.getElementById('root')!);
  const calls: unknown[] = [];
  const store = await makeVaultStore();
  const user = account('usr_a', true);
  const actions = {
    switchAccount: async (id: string) => { calls.push(['switch', id]); },
    signOutAccount: async (opts?: unknown) => { calls.push(['logout', opts]); },
    addAccount: () => { calls.push(['add']); },
  };
  const render = async (accounts = [user, account('usr_b')], planLabel = 'Pro') => {
    await act(async () => root.render(React.createElement(Provider, { store },
      React.createElement(AuthAccountsProvider, { value: { ...actions, accounts } },
        React.createElement(AccountSwitcher, {
          user, avatar: React.createElement('span', { 'data-debug-id': 'shell-user-ws-owner', 'data-ws-status': 'open' }),
          isMobile: false, planLabel, openAccountSettings: () => { calls.push(['settings']); },
        }),
        React.createElement(AccountPanel, { user }),
      ),
    )));
  };
  const find = (id: string) => dom.window.document.querySelector<HTMLElement>(`[data-debug-id="${id}"]`);
  const click = async (id: string) => { assert.ok(find(id), id); await act(async () => find(id)!.click()); };
  const open = async () => { await click('account-switcher-toggle'); assert.ok(find('account-switcher-menu')); };
  try {
    await render();
    for (const id of ['shell-global-ownership-points', 'shell-user-ws-owner', 'shell-open-account', 'shell-current-user-owner', 'auth-logout-link', 'shell-subscription-tier', 'account-panel-sessions', 'account-panel-switch-usr_b', 'account-panel-logout-usr_a', 'account-panel-logout-usr_b', 'account-panel-add-account', 'account-panel-logout-all']) assert.ok(find(id), id);
    assert.match(find('account-panel-sessions')!.textContent!, /Active/);
    assert.equal(find('account-panel-switch-usr_a'), null);
    assert.match(find('account-switcher-toggle')!.textContent!, /2/);
    assert.equal(find('account-switcher-toggle')!.getAttribute('aria-expanded'), 'false');
    await open();
    assert.equal(find('account-switcher-toggle')!.getAttribute('aria-expanded'), 'true');
    assert.equal((find('account-switcher-item-usr_a') as HTMLButtonElement).disabled, true);
    for (const id of ['account-switcher-item-usr_b', 'account-switcher-logout-usr_a', 'account-switcher-logout-usr_b', 'account-switcher-add-account', 'account-switcher-logout-all']) assert.ok(find(id), id);
    await click('account-switcher-item-usr_a'); assert.deepEqual(calls, []);
    await click('account-switcher-item-usr_b'); assert.equal(find('account-switcher-menu'), null);
    await open(); await click('account-switcher-logout-usr_b');
    await open(); await click('account-switcher-logout-usr_a');
    await open(); await click('account-switcher-add-account');
    await open(); await click('account-switcher-logout-all');
    await click('shell-open-account'); await click('shell-subscription-tier'); await click('auth-logout-link');
    await click('account-panel-switch-usr_b');
    await click('account-panel-logout-usr_b'); await click('account-panel-logout-usr_a');
    await click('account-panel-add-account'); await click('account-panel-logout-all');
    assert.deepEqual(calls, [
      ['switch', 'usr_b'], ['logout', { userId: 'usr_b' }], ['logout', { userId: 'usr_a' }], ['add'], ['logout', { all: true }],
      ['settings'], ['settings'], ['logout', undefined], ['switch', 'usr_b'], ['logout', { userId: 'usr_b' }], ['logout', { userId: 'usr_a' }], ['add'], ['logout', { all: true }],
    ]);
    await open();
    await act(async () => { dom.window.document.dispatchEvent(new dom.window.KeyboardEvent('keydown', { key: 'Escape', bubbles: true })); });
    assert.equal(find('account-switcher-menu'), null);
    assert.equal(dom.window.document.activeElement, find('account-switcher-toggle'));
    await open();
    await act(async () => { dom.window.document.getElementById('outside')!.dispatchEvent(new dom.window.Event('pointerdown', { bubbles: true })); });
    assert.equal(find('account-switcher-menu'), null);
    await render([user], ''); await open();
    assert.equal(find('account-switcher-logout-all'), null); assert.equal(find('account-panel-logout-all'), null);
    assert.equal(find('shell-subscription-tier'), null);
    assert.doesNotMatch(find('account-switcher-toggle')!.textContent!, /1/);
    assert.ok(find('account-switcher-add-account')); assert.ok(find('account-panel-add-account'));
    // The production shell owns the outer footer and live WS indicator; the
    // switcher keeps them in place rather than creating another connection.
    const shell = fs.readFileSync(new URL('../src/ui/components/shell/AppShell.tsx', import.meta.url), 'utf8');
    assert.match(shell, /data-debug-id="shell-sidebar-account"[^>]*>\s*<AccountSwitcher user=\{user\} avatar=\{userAvatar\}/);
    assert.match(shell, /const userAvatar =[\s\S]*data-debug-id="shell-user-ws-owner" data-ws-status=\{wsStatus\}/);
  } finally {
    await act(async () => root.unmount());
    for (const [key, descriptor] of saved) {
      if (descriptor) Object.defineProperty(globalThis, key, descriptor); else delete (globalThis as any)[key];
    }
    dom.window.close();
  }
});

function deferred<T>() {
  let resolve!: (value: T) => void;
  const promise = new Promise<T>((r) => { resolve = r; });
  return { promise, resolve };
}

async function harness() {
  const dom = new JSDOM('<div id="root"></div>', { url: 'https://ui.test/#/conversations/a', virtualConsole: new VirtualConsole() });
  const saved = new Map<string, PropertyDescriptor | undefined>();
  const install = (key: string, value: unknown) => {
    saved.set(key, Object.getOwnPropertyDescriptor(globalThis, key));
    Object.defineProperty(globalThis, key, { configurable: true, writable: true, value });
  };
  install('window', dom.window); install('document', dom.window.document);
  install('CustomEvent', dom.window.CustomEvent); install('IS_REACT_ACT_ENVIRONMENT', true);
  const trace: string[] = [];
  const requests: Array<{ url: string; body: any }> = [];
  let activeId = 'usr_a';
  let authFailure: 'unauthenticated' | 'forbidden' | null = null;
  let ringIds = ['usr_a', 'usr_b'];
  let switchResponse: (() => Promise<Response>) | null = null;
  let logoutResponse: (() => Promise<Response>) | null = null;
  const ring = () => ringIds.map((id) => account(id, id === activeId));
  const fetcher = async (input: any, init?: RequestInit) => {
    const url = String(input);
    const body = init?.body ? JSON.parse(String(init.body)) : undefined;
    requests.push({ url, body });
    if (url.endsWith('/auth/sessions')) return Response.json({ data: { active_user_id: activeId, accounts: ring() } });
    if (url.endsWith('/auth/switch')) {
      trace.push('POST switch');
      if (switchResponse) return switchResponse();
      activeId = body.user_id;
      return Response.json({ data: { active_user_id: activeId, user: account(activeId, true), accounts: ring() } });
    }
    if (url.endsWith('/auth/logout')) {
      trace.push('POST logout');
      if (logoutResponse) return logoutResponse();
      const target = body.user_id || activeId;
      ringIds = body.all ? [] : ringIds.filter((id) => id !== target);
      if (!ringIds.includes(activeId)) activeId = ringIds[0] || '';
      return Response.json({ data: {
        active_user_id: activeId, switched_user: activeId && target === 'usr_a' ? account(activeId, true) : null,
        accounts: ring(), logout_url: activeId ? '' : '/signed-out',
      } });
    }
    throw new Error(`Unexpected fetch ${url}`);
  };
  (dom.window as any).fetch = fetcher;
  install('fetch', fetcher);
  class Socket {
    readyState = 0;
    onclose: any; onerror: any; onmessage: any; onopen: any;
    constructor(_url: string) { trace.push(`open ${activeId}`); }
    send() {}
    close() { trace.push(`close ${this.owner}`); this.readyState = 3; }
    owner = activeId;
  }
  install('WebSocket', Socket);
  const actions: any[] = [];
  const store = await makeVaultStore({
    extraReducers: { deviceVault: deviceVaultReducer, toasts: toastReducer },
    extraMiddleware: [() => (next: any) => (action: any) => {
      actions.push(action);
      if (action.type === 'vault/keyringCleared') trace.push('purge vault');
      if (action.type === 'deviceVault/deviceVaultStatusChanged' && action.payload.status === 'initializing') trace.push(`boot ${action.payload.userId}`);
      return next(action);
    }],
  });
  const dispatch = store.dispatch;
  const clearPriorUserClientState = (dispatch: any, id: string) => {
    trace.push(`reset ${id}`);
    dispatch(heimdallApi.util.resetApiState());
    dispatch({ type: 'heimdall/priorUserClientStateCleared' });
    dispatch(clearUserClientState({ userId: id }));
  };
  const bootstrapAuth = async (): Promise<AuthState> => {
    trace.push(`identity ${activeId}`);
    if (authFailure) {
      window.dispatchEvent(new dom.window.CustomEvent(`heimdall:api-${authFailure}`));
      return { status: authFailure, user: null, error: '' };
    }
    return activeId ? { status: 'authenticated', user: account(activeId, true), error: '' } : { status: 'unauthenticated', user: null, error: '' };
  };
  dv.stopDeviceVault();
  dv.configureDeviceVault({
    kv: identity.memoryDeviceStore(), bridges: null, connectors: null,
    api: { fetchVaultDirectory: async () => { throw new TypeError('offline test vault'); } } as any,
  });
  const unsubscribe = subscribeMcpWorker(() => trace.push('MCP disabled'));
  let latest!: ReturnType<typeof useAuthSessionState>;
  function Shell() {
    useUserWebSocket();
    useEffect(() => () => { trace.push('shell unmounted'); }, []);
    return React.createElement('div', { 'data-debug-id': 'authenticated-shell' }, activeId);
  }
  function Gate() {
    latest = useAuthSessionState({ dispatch, bootstrapAuth, clearPriorUserClientState });
    if (latest.auth.status !== 'authenticated') return React.createElement('div', { 'data-debug-id': `auth-${latest.auth.status}` });
    return React.createElement(Shell, { key: latest.auth.user?.user_id });
  }
  const root = createRoot(dom.window.document.getElementById('root')!);
  persistence.writeLastSeenUserId('usr_a');
  persistence.writeUserLastRoute('usr_b', '#/chains/b');
  window.localStorage.setItem('heimdall.user.usr_a.preference', 'keep-a');
  window.localStorage.setItem('heimdall.user.usr_b.preference', 'keep-b');
  window.localStorage.setItem('heimdall:composer:draft:agent-a', 'draft');
  window.localStorage.setItem(persistence.AUX_PANES_STORAGE_KEY, '{"saved":true}');
  await act(async () => { root.render(React.createElement(Provider, { store }, React.createElement(Gate))); });
  return {
    dom, trace, actions, requests, store,
    get session() { return latest; },
    failIdentity(status: 'unauthenticated' | 'forbidden') { authFailure = status; },
    setActive(id: string) { activeId = id; persistence.writeLastSeenUserId(id); },
    setSwitchResponse(fn: () => Promise<Response>) { switchResponse = fn; },
    setLogoutResponse(fn: () => Promise<Response>) { logoutResponse = fn; },
    async cleanup() {
      await act(async () => { root.unmount(); });
      unsubscribe();
      dv.stopDeviceVault();
      for (const [key, descriptor] of saved) {
        if (descriptor) Object.defineProperty(globalThis, key, descriptor);
        else delete (globalThis as any)[key];
      }
      dom.window.close();
    },
  };
}

test('REQ-ACCT-WS-1 Case 8 and UI-1 Case 10: teardown precedes POST, only the selected account reconnects, storage survives', async () => {
  const h = await harness();
  try {
    await act(async () => { await unlockVault(h.store, 'ab'.repeat(32)); });
    assert.ok(getActiveVaultKey());
    const response = deferred<Response>();
    h.setSwitchResponse(() => response.promise);
    let pending!: Promise<void>;
    await act(async () => { pending = h.session.switchAccount('usr_b'); });
    assert.equal(h.session.auth.status, 'switching');
    assert.ok(document.querySelector('[data-debug-id="auth-switching"]'));
    assert.equal(getKeyringSession(), null);
    assert.equal(getActiveVaultKey(), null);
    assert.equal(isMcpWorkerEnabled(), false);
    for (const event of ['purge vault', 'close usr_a', 'MCP disabled', 'shell unmounted']) {
      assert.ok(h.trace.indexOf(event) >= 0 && h.trace.indexOf(event) < h.trace.indexOf('POST switch'), `${event}: ${h.trace}`);
    }
    assert.deepEqual(h.trace.filter((s) => s.startsWith('open ')), ['open usr_a']);
    assert.equal(persistence.readUserLastRoute('usr_a'), '#/conversations/a');
    await act(async () => {
      h.setActive('usr_b');
      response.resolve(Response.json({ data: { active_user_id: 'usr_b', user: account('usr_b', true), accounts: [account('usr_b', true), account('usr_a')] } }));
      await pending;
    });
    assert.equal(h.session.auth.user?.user_id, 'usr_b');
    assert.equal(window.location.hash, '#/chains/b');
    assert.equal(persistence.readLastSeenUserId(), 'usr_b');
    assert.deepEqual(h.trace.filter((s) => s.startsWith('open ')), ['open usr_a', 'open usr_b']);
    assert.ok(h.trace.includes('reset usr_b'));
    assert.ok(h.trace.includes('boot usr_b'));
    assert.ok(h.actions.some((a) => a.type === 'heimdallApi/resetApiState'));
    assert.ok(h.actions.some((a) => a.type === 'heimdall/priorUserClientStateCleared'));
    assert.ok(h.actions.some((a) => a.type === 'chat/clearUserClientState' && a.payload.userId === 'usr_b'));
    assert.equal(window.localStorage.getItem('heimdall.user.usr_a.preference'), 'keep-a');
    assert.equal(window.localStorage.getItem('heimdall.user.usr_b.preference'), 'keep-b');
    assert.equal(window.localStorage.getItem('heimdall:composer:draft:agent-a'), 'draft');
    assert.equal(window.localStorage.getItem(persistence.AUX_PANES_STORAGE_KEY), '{"saved":true}');
  } finally { await h.cleanup(); }
});

for (const failure of ['404', 'network']) {
  test(`REQ-ACCT-UI-1 Case 11: switch ${failure} rolls back to A and reboots its vault`, async () => {
    const h = await harness();
    try {
      h.setSwitchResponse(async () => {
        if (failure === 'network') throw new TypeError('offline');
        return new Response('{}', { status: 404 });
      });
      let pending!: Promise<void>;
      await act(async () => { pending = h.session.switchAccount('usr_b'); });
      await act(async () => { await pending; });
      assert.equal(h.session.auth.status, 'authenticated');
      assert.equal(h.session.auth.user?.user_id, 'usr_a');
      assert.equal(h.trace.filter((s) => s === 'boot usr_a').length, 2);
      assert.deepEqual(h.trace.filter((s) => s.startsWith('open ')), ['open usr_a', 'open usr_a']);
      assert.ok(!h.trace.includes('reset usr_b'));
      assert.ok(h.actions.some((a) => a.type === 'toasts/showToast' && a.payload.kind === 'error'));
      assert.equal(window.localStorage.getItem('heimdall.user.usr_a.preference'), 'keep-a');
    } finally { await h.cleanup(); }
  });
}

test('REQ-ACCT-UI-1 Case 13: cross-tab storage sync tears down A and restores B without deleting storage', async () => {
  const h = await harness();
  try {
    await act(async () => {
      h.setActive('usr_b');
      window.dispatchEvent(new h.dom.window.StorageEvent('storage', { key: persistence.LAST_SEEN_USER_ID_KEY, oldValue: 'usr_a', newValue: 'usr_b' }));
    });
    assert.equal(h.session.auth.user?.user_id, 'usr_b');
    assert.ok(h.trace.indexOf('close usr_a') < h.trace.indexOf('open usr_b'));
    assert.ok(h.trace.includes('reset usr_b'));
    assert.equal(window.location.hash, '#/chains/b');
    assert.equal(window.localStorage.getItem('heimdall.user.usr_a.preference'), 'keep-a');
    assert.ok(!h.trace.includes('POST switch'));
    const checks = h.trace.filter((s) => s.startsWith('identity ')).length;
    await act(async () => { window.dispatchEvent(new h.dom.window.StorageEvent('storage', { key: 'unrelated', newValue: 'usr_c' })); });
    assert.equal(h.trace.filter((s) => s.startsWith('identity ')).length, checks);
  } finally { await h.cleanup(); }
});

test('REQ-ACCT-UI-1 Case 10: logout of a deselected account leaves A mounted and removes only B storage', async () => {
  const h = await harness();
  try {
    await act(async () => { await h.session.signOutAccount({ userId: 'usr_b' }); });
    assert.equal(h.session.auth.user?.user_id, 'usr_a');
    assert.ok(!h.trace.includes('close usr_a'));
    assert.equal(window.localStorage.getItem('heimdall.user.usr_b.preference'), null);
    assert.equal(window.localStorage.getItem('heimdall.user.usr_a.preference'), 'keep-a');
    assert.equal(h.session.accounts.length, 1);
  } finally { await h.cleanup(); }
});

test('REQ-ACCT-UI-1 Case 10: active logout promotes B only after teardown and clears only A storage', async () => {
  const h = await harness();
  try {
    let pending!: Promise<void>;
    await act(async () => { pending = h.session.signOutAccount({ userId: 'usr_a' }); });
    await act(async () => { await pending; });
    assert.ok(h.trace.indexOf('close usr_a') < h.trace.indexOf('POST logout'));
    assert.equal(h.session.auth.user?.user_id, 'usr_b');
    assert.equal(window.localStorage.getItem('heimdall.user.usr_a.preference'), null);
    assert.equal(window.localStorage.getItem('heimdall.user.usr_b.preference'), 'keep-b');
    assert.equal(window.location.hash, '#/chains/b');
  } finally { await h.cleanup(); }
});

test('REQ-ACCT-UI-1 Case 10: signing out all accounts clears app-owned storage', async () => {
  const h = await harness();
  try {
    window.localStorage.setItem('third-party.preference', 'keep');
    let pending!: Promise<void>;
    await act(async () => { pending = h.session.signOutAccount({ all: true }); });
    await act(async () => { await pending; });
    assert.ok(h.trace.indexOf('close usr_a') < h.trace.indexOf('POST logout'));
    assert.equal(h.session.auth.status, 'unauthenticated');
    assert.equal(window.localStorage.getItem('heimdall.user.usr_a.preference'), null);
    assert.equal(window.localStorage.getItem('heimdall.user.usr_b.preference'), null);
    assert.equal(window.localStorage.getItem(persistence.AUX_PANES_STORAGE_KEY), null);
    assert.equal(window.localStorage.getItem('third-party.preference'), 'keep');
  } finally { await h.cleanup(); }
});

test('REQ-ACCT-UI-1 Case 12: device vault consumes intent and acknowledges the added account', async () => {
  const dom = new JSDOM('', { url: 'https://ui.test' });
  const previous = (globalThis as any).window;
  (globalThis as any).window = dom.window;
  const kv = identity.memoryDeviceStore();
  await kv.put('pinned-users', ['usr_a']);
  const actions: any[] = [];
  dv.stopDeviceVault();
  dv.configureDeviceVault({ kv, bridges: null, connectors: null, api: {
    fetchVaultDirectory: async () => null,
    postVaultGenesis: async () => { throw new TypeError('offline after acknowledgement'); },
  } as any });
  try {
    await dv.bootDeviceVault('usr_b', (a) => { actions.push(a); });
    assert.ok(actions.some((a) => a.payload?.status === 'other-account'), 'no intent: keep the original warning');
    dv.stopDeviceVault();
    actions.length = 0;
    persistence.recordAddAccountIntent();
    await dv.bootDeviceVault('usr_b', (a) => { actions.push(a); });
    assert.equal(await kv.get('other-account-ack:usr_b'), true);
    assert.equal(persistence.consumeAddAccountIntent(), false);
    assert.ok(!actions.some((a) => a.payload?.status === 'other-account'));
  } finally {
    dv.stopDeviceVault();
    (globalThis as any).window = previous;
    dom.window.close();
  }
});

test('AuthGate wires the production lifecycle to its switching screen and context; reset preserves storage', () => {
  const source = fs.readFileSync(new URL('../src/ui/components/shell/AppShell.tsx', import.meta.url), 'utf8');
  assert.match(source, /useAuthSessionState\(\{ dispatch, bootstrapAuth, clearPriorUserClientState \}\)/);
  assert.match(source, /auth.status === 'switching'.*debugId="auth-switching"/);
  assert.match(source, /AuthAccountsProvider value=\{accountSession\}/);
  assert.match(source, /AuthenticatedShell key=\{authUserId\(auth.user\)/);
  const reset = source.slice(source.indexOf('function clearPriorUserClientState'), source.indexOf('function AuthGate'));
  assert.match(reset, /resetApiState/);
  assert.match(reset, /priorUserClientStateCleared/);
  assert.match(reset, /clearUserClientState/);
  assert.doesNotMatch(reset, /removeAppOwnedClientStorage/);
});

test('REQ-ACCT-WS-1: stopping a vault fences an in-flight keyring unwrap', async () => {
  const { FakeHub, newBrowser } = await import('./helpers/vaultDirectoryFixture.ts');
  const { installKeyringFromWrap, clearKeyringSession } = await import('../src/ui/utils/vaultKeyringSession.ts');
  const hub = new FakeHub('usr_a');
  const browser = await newBrowser('usr_a');
  await hub.genesis(browser);
  const chain = await hub.chain();
  clearKeyringSession();
  const opening = installKeyringFromWrap(browser, hub.wraps.get(browser.deviceId), chain);
  // Sign-out/switch can happen while WebCrypto is opening the old user's wrap.
  dv.stopDeviceVault();
  await assert.rejects(opening, /session changed/);
  assert.equal(getKeyringSession(), null);
});

test('queued cross-tab sync during a switch reaches the newest identity without another switch POST', async () => {
  const h = await harness();
  try {
    const response = deferred<Response>();
    h.setSwitchResponse(() => response.promise);
    let pending!: Promise<void>;
    await act(async () => { pending = h.session.switchAccount('usr_b'); });
    await act(async () => {
      h.setActive('usr_c');
      window.dispatchEvent(new h.dom.window.StorageEvent('storage', { key: persistence.LAST_SEEN_USER_ID_KEY, newValue: 'usr_c' }));
      response.resolve(Response.json({ data: { active_user_id: 'usr_b', user: account('usr_b', true), accounts: [account('usr_b', true)] } }));
      await pending;
    });
    assert.equal(h.session.auth.status, 'authenticated');
    assert.equal(h.session.auth.user?.user_id, 'usr_c');
    assert.equal(h.requests.filter((r) => r.url.endsWith('/auth/switch')).length, 1);
    assert.ok(h.trace.includes('reset usr_c'));
    assert.equal(window.localStorage.getItem('heimdall.user.usr_a.preference'), 'keep-a');
  } finally { await h.cleanup(); }
});

test('lost switch response reconciles the cookie identity before reopening a socket', async () => {
  const h = await harness();
  try {
    h.setSwitchResponse(async () => { h.setActive('usr_b'); throw new TypeError('response lost'); });
    let pending!: Promise<void>;
    await act(async () => { pending = h.session.switchAccount('usr_b'); });
    await act(async () => { await pending; });
    assert.equal(h.session.auth.user?.user_id, 'usr_b');
    assert.deepEqual(h.trace.filter((s) => s.startsWith('open ')), ['open usr_a', 'open usr_b']);
    assert.equal(h.trace.filter((s) => s === 'boot usr_a').length, 1);
  } finally { await h.cleanup(); }
});

test('failed active logout restores A and leaves both accounts storage intact', async () => {
  const h = await harness();
  try {
    h.setLogoutResponse(async () => new Response('{}', { status: 500 }));
    let pending!: Promise<void>;
    await act(async () => { pending = h.session.signOutAccount(); });
    await act(async () => { await pending; });
    assert.equal(h.session.auth.user?.user_id, 'usr_a');
    assert.equal(window.localStorage.getItem('heimdall.user.usr_a.preference'), 'keep-a');
    assert.equal(window.localStorage.getItem('heimdall.user.usr_b.preference'), 'keep-b');
    assert.equal(h.trace.filter((s) => s === 'boot usr_a').length, 2);
  } finally { await h.cleanup(); }
});

test('signing out the last account clears app storage and leaves no selected socket', async () => {
  const h = await harness();
  try {
    await act(async () => { await h.session.signOutAccount({ userId: 'usr_b' }); });
    let pending!: Promise<void>;
    await act(async () => { pending = h.session.signOutAccount(); });
    await act(async () => { await pending; });
    assert.equal(h.session.auth.status, 'unauthenticated');
    assert.equal(h.session.accounts.length, 0);
    assert.equal(window.localStorage.getItem('heimdall.user.usr_a.preference'), null);
    assert.ok(h.trace.includes('close usr_a'));
    assert.deepEqual(h.trace.filter((s) => s.startsWith('open ')), ['open usr_a']);
  } finally { await h.cleanup(); }
});

for (const status of ['unauthenticated', 'forbidden'] as const) {
  test(`identity observer ${status} feedback does not recursively probe /me`, async () => {
    const h = await harness();
    try {
      const initialChecks = h.trace.filter((s) => s.startsWith('identity ')).length;
      await act(async () => {
        h.failIdentity(status);
        window.dispatchEvent(new h.dom.window.CustomEvent(`heimdall:api-${status}`));
      });
      assert.equal(h.session.auth.status, status);
      assert.equal(h.trace.filter((s) => s.startsWith('identity ')).length, initialChecks + 1);
      assert.ok(h.trace.includes('close usr_a'));
    } finally { await h.cleanup(); }
  });
}

test('REQ-SWFIX-IDENT-1: a same-user focus refresh keeps the auth object and does not reboot the vault', async () => {
  const h = await harness();
  try {
    const user = h.session.auth.user;
    assert.ok(user);
    const boots = () => h.trace.filter((t) => t.startsWith('boot ')).length;
    const bootsBefore = boots();
    const identitiesBefore = h.trace.filter((t) => t.startsWith('identity ')).length;
    await act(async () => { window.dispatchEvent(new h.dom.window.Event('focus')); await new Promise((r) => setTimeout(r, 20)); });
    assert.ok(h.trace.filter((t) => t.startsWith('identity ')).length > identitiesBefore, 'the refresh ran');
    assert.equal(h.session.auth.user, user, 'same object reference');
    assert.equal(boots(), bootsBefore, 'no vault reboot');
  } finally { await h.cleanup(); }
});

test('REQ-SWFIX-IDENT-1: a switch clicked during a background refresh is not dropped', async () => {
  const h = await harness();
  try {
    let pending!: Promise<void>;
    await act(async () => {
      window.dispatchEvent(new h.dom.window.Event('focus'));
      pending = h.session.switchAccount('usr_b');
    });
    await act(async () => { await pending; });
    assert.equal(h.requests.filter((r) => r.url.endsWith('/auth/switch')).length, 1);
  } finally { await h.cleanup(); }
});
