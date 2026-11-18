// Workspace persistence: the Main layout and aux strips persist GLOBALLY,
// never keyed by task chain; legacy chain-keyed workbench keys are cleared.
import './helpers/vaultEndpointHarness.ts';
import { test } from 'node:test';
import assert from 'node:assert/strict';

test('aux strips persist per agent (never keyed by task chain); legacy chain-keyed and global layout keys are cleared', async () => {
  const mockStorage: Record<string, string> = {
    'heimdall:window-layout:v1': '{}',
    'heimdall:workbench-layout:v1:chain:c1': '{}',
    'heimdall:workbench-layout:v1:agent:a1': '{}',
    'heimdall:other': 'keep',
  };
  const localStorage = {
    getItem: (key: string) => mockStorage[key] ?? null,
    setItem: (key: string, val: string) => { mockStorage[key] = String(val); },
    removeItem: (key: string) => { delete mockStorage[key]; },
    key: (i: number) => Object.keys(mockStorage)[i] ?? null,
    get length() { return Object.keys(mockStorage).length; },
  };
  (globalThis as any).window = { localStorage };

  const {
    readAuxPanesState,
    writeAuxPanesState,
    removeLegacyWorkbenchStorage,
  } = await import('../src/ui/utils/clientPersistence.ts');

  mockStorage['heimdall:workspace-layout:v1'] = '{}';
  writeAuxPanesState({ agentPanes: { a1: { tabs: [], activeTabId: 'overview' } } });
  assert.deepEqual(readAuxPanesState(), { agentPanes: { a1: { tabs: [], activeTabId: 'overview' } } });
  assert.ok(!Object.keys(mockStorage).some((k) => k.includes('chain:') && k.startsWith('heimdall:workspace')));

  removeLegacyWorkbenchStorage();
  assert.equal(mockStorage['heimdall:window-layout:v1'], undefined);
  assert.equal(mockStorage['heimdall:workbench-layout:v1:chain:c1'], undefined);
  assert.equal(mockStorage['heimdall:workbench-layout:v1:agent:a1'], undefined);
  assert.equal(mockStorage['heimdall:workspace-layout:v1'], undefined, 'the single global layout key is gone');
  assert.equal(mockStorage['heimdall:other'], 'keep');
});



test('REQ-ACCT-UI-1 Case 10: scoped logout preserves other accounts, drafts and aux panes', async () => {
  const { JSDOM } = await import('jsdom');
  const previous = (globalThis as any).window;
  const dom = new JSDOM('', { url: 'https://ui.test' });
  (globalThis as any).window = dom.window;
  try {
    const p = await import('../src/ui/utils/clientPersistence.ts');
    for (const storage of [window.localStorage, window.sessionStorage]) {
      storage.setItem(p.userScopedStorageKey('prefs', 'usr/a'), 'a');
      storage.setItem(p.userScopedStorageKey('lastRoute', 'usr/a'), '#/c/a');
      storage.setItem(p.userScopedStorageKey('prefs', 'usr/b'), 'b');
      storage.setItem('heimdall.user.usr%2Fa-longer.prefs', 'keep');
      storage.setItem('heimdall:composer:draft:agent', 'draft');
      storage.setItem(p.AUX_PANES_STORAGE_KEY, '{}');
    }
    p.removeUserClientStorage('usr/a');
    for (const storage of [window.localStorage, window.sessionStorage]) {
      assert.equal(storage.getItem(p.userScopedStorageKey('prefs', 'usr/a')), null);
      assert.equal(storage.getItem(p.userScopedStorageKey('lastRoute', 'usr/a')), null);
      assert.equal(storage.getItem(p.userScopedStorageKey('prefs', 'usr/b')), 'b');
      assert.equal(storage.getItem('heimdall.user.usr%2Fa-longer.prefs'), 'keep');
      assert.equal(storage.getItem('heimdall:composer:draft:agent'), 'draft');
      assert.equal(storage.getItem(p.AUX_PANES_STORAGE_KEY), '{}');
    }
    p.writeUserLastRoute('usr/b', '#/chains/b');
    assert.equal(p.readUserLastRoute('usr/b'), '#/chains/b');
    assert.equal(p.resolveSwitchedUserRoute('usr/b', '#/c/a'), '#/chains/b');
    for (const route of ['#/conversations/a?x=1', '#/c/a', '#/chains/a', '#/chains?x=1']) {
      assert.equal(p.resolveSwitchedUserRoute('usr/new', route), '#/home');
    }
    assert.equal(p.resolveSwitchedUserRoute('usr/new', '#/settings/account'), '#/settings/account');
    // REQ-SWFIX-ROUTE-1: ids of one account must not leak into another.
    for (const route of ['#/projects/p1', '#/agents/a1', '#/shells/s1', '#/memory/m1', '#/issues/i1', '#/settings/bridges', '#/device/enroll']) {
      assert.equal(p.resolveSwitchedUserRoute('usr/new', route), '#/home', route);
    }
    assert.equal(p.resolveSwitchedUserRoute('usr/new', '#/home'), '#/home');
    // saveRoute never persists the enrollment gate route.
    p.writeUserLastRoute('usr/new', '#/device/enroll');
    assert.equal(p.readUserLastRoute('usr/new'), '');
    p.writeUserLastRoute('usr/b', '#/device/enroll');
    assert.equal(p.readUserLastRoute('usr/b'), '#/chains/b');
    assert.equal(p.resolveSwitchedUserRoute('usr/new', ''), '#/home');
  } finally {
    (globalThis as any).window = previous;
    dom.window.close();
  }
});

test('REQ-ACCT-UI-1 Case 12: add-account intent is tab-local, expires, and is consumed once', async () => {
  const { JSDOM } = await import('jsdom');
  const previous = (globalThis as any).window;
  const dom = new JSDOM('', { url: 'https://ui.test' });
  (globalThis as any).window = dom.window;
  try {
    const p = await import('../src/ui/utils/clientPersistence.ts');
    p.recordAddAccountIntent(1_000);
    assert.equal(window.localStorage.getItem(p.ADD_ACCOUNT_INTENT_KEY), null);
    assert.equal(p.consumeAddAccountIntent(1_001), true);
    assert.equal(p.consumeAddAccountIntent(1_001), false);
    p.recordAddAccountIntent(1_000);
    assert.equal(p.consumeAddAccountIntent(1_000 + p.ADD_ACCOUNT_INTENT_TTL_MS), false);
    p.recordAddAccountIntent(2_000);
    assert.equal(p.consumeAddAccountIntent(1_999), false);
    for (const raw of ['', ' ', 'NaN', 'Infinity', 'bad']) {
      window.sessionStorage.setItem(p.ADD_ACCOUNT_INTENT_KEY, raw);
      assert.equal(p.consumeAddAccountIntent(2_000), false, raw);
      assert.equal(window.sessionStorage.getItem(p.ADD_ACCOUNT_INTENT_KEY), null);
    }
  } finally {
    (globalThis as any).window = previous;
    dom.window.close();
  }
});

test('scoped cleanup and intent helpers tolerate blocked storage accessors', async () => {
  const previous = (globalThis as any).window;
  (globalThis as any).window = {
    get localStorage() { throw new Error('blocked'); },
    get sessionStorage() { throw new Error('blocked'); },
  };
  try {
    const p = await import('../src/ui/utils/clientPersistence.ts');
    assert.doesNotThrow(() => p.removeUserClientStorage('usr_a'));
    assert.doesNotThrow(() => p.removeAppOwnedClientStorage());
    assert.doesNotThrow(() => p.writeUserLastRoute('usr_a', '#/home'));
    assert.doesNotThrow(() => p.recordAddAccountIntent());
    assert.equal(p.readUserLastRoute('usr_a'), '');
    assert.equal(p.consumeAddAccountIntent(), false);
  } finally { (globalThis as any).window = previous; }
});
