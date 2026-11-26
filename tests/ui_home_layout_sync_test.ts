import assert from 'node:assert/strict';
import test from 'node:test';
import React from 'react';
import { ApiError } from '../src/ui/api/cookieFetch.ts';
import { setExpectedUserId, EXPECTED_USER_HEADER } from '../src/ui/utils/expectedUser.ts';
import { defaultHomeLayout, HomeLayoutConflict, HomeLayoutSession, homeLayoutStorageKey, moveHomeWidget, setWidgetHidden, type HomeLayout, type HomeLayoutAdapter, type HomeLayoutSnapshot } from '../src/ui/components/home/homeLayout.ts';
import { createServerHomeLayoutAdapter } from '../src/ui/components/home/serverHomeLayoutAdapter.ts';

const drain = async () => { for (let i = 0; i < 40; i++) await Promise.resolve(); };
function deferred<T>() {
  let resolve!: (value: T) => void;
  let reject!: (error: unknown) => void;
  const promise = new Promise<T>((yes, no) => { resolve = yes; reject = no; });
  return { promise, resolve, reject };
}
function storageFor(user: string, value?: unknown) {
  const data = new Map<string, string>();
  if (value !== undefined) data.set(homeLayoutStorageKey(user), typeof value === 'string' ? value : JSON.stringify(value));
  return { data, getItem: (key: string) => data.get(key) ?? null };
}
const changed = (id: 'chains' | 'fleet' = 'chains', version = 0) => ({ ...setWidgetHidden(defaultHomeLayout(), id, true), version });
const reply = (layout: HomeLayout) => Response.json({ data: layout, meta: { request_id: 'test' } });
const refusal = (status: number, code: string) => Response.json({ error: { code, message: code } }, { status });
type WireCall = { method: string; headers: Headers; body?: HomeLayout; signal?: AbortSignal | null };
function wire(t: any, handle: (call: WireCall) => Promise<Response> | Response) {
  const calls: WireCall[] = [];
  t.mock.method(globalThis, 'fetch', async (url: string, init: RequestInit) => {
    assert.equal(url, '/api/v1/me/home-layout');
    assert.equal(init.credentials, 'include');
    assert.equal(init.cache, 'no-store');
    const call = { method: init.method!, headers: new Headers(init.headers), body: init.body ? JSON.parse(String(init.body)) : undefined, signal: init.signal };
    calls.push(call);
    return handle(call);
  });
  return calls;
}
const adapterFor = (storage?: ReturnType<typeof storageFor>) => createServerHomeLayoutAdapter({ storage: () => storage, isCurrentUser: () => true });

test('Server layout wins over current-user backup; GET uses captured account and no write', async (t) => {
  const backup = storageFor('alice/a', changed('chains', 90));
  const saved = changed('fleet', 4);
  const calls = wire(t, () => reply(saved));
  assert.deepEqual(await adapterFor(backup).load('alice/a'), saved);
  assert.equal(calls.length, 1);
  assert.equal(calls[0].headers.get(EXPECTED_USER_HEADER), 'alice/a');
  assert.equal(calls[0].method, 'GET');
  assert.equal(JSON.parse(backup.getItem(homeLayoutStorageKey('alice/a'))!).version, 90);
});

test('First-use import discards browser revision and preserves backup, desktop/mobile order and options', async (t) => {
  let layout = moveHomeWidget(changed('fleet', 73), 'uptime', 'fleet', true);
  layout = moveHomeWidget(layout, 'fleet', 'activity');
  layout.widgets[0].options = { ...layout.widgets[0].options, nested: { custom: ['saved', 2] } };
  const backup = storageFor('alice', layout);
  const original = backup.getItem(homeLayoutStorageKey('alice'));
  const calls = wire(t, (call) => call.method === 'GET' ? reply(defaultHomeLayout()) : reply({ ...call.body!, version: 1 }));
  const imported = await adapterFor(backup).load('alice');
  assert.deepEqual(imported, { ...layout, version: 1 });
  assert.equal(calls.length, 2);
  assert.equal(calls[1].headers.get('If-Match'), '"0"');
  assert.equal(calls[1].headers.get(EXPECTED_USER_HEADER), 'alice');
  assert.equal(calls[1].headers.get('Content-Type'), 'application/json');
  assert.equal(calls[1].body!.version, 0);
  assert.equal(backup.getItem(homeLayoutStorageKey('alice')), original);
});

test('Missing/corrupt/invalid backup and another user backup use defaults without creating a row', async (t) => {
  const calls = wire(t, () => reply(defaultHomeLayout()));
  for (const value of [undefined, '{bad', null, { version: -1, widgets: [] }, { version: 2, widgets: [null] }, { version: 2, widgets: [{ id: 'fleet', options: { mobile_order: -1 } }] }]) {
    const backup = storageFor('alice', value);
    const count = calls.length;
    assert.deepEqual(await adapterFor(backup).load('alice'), defaultHomeLayout());
    assert.equal(calls.length, count + 1);
  }
  assert.deepEqual(await adapterFor(storageFor('bob', changed())).load('alice'), defaultHomeLayout());
  assert.ok(calls.every(({ method }) => method === 'GET'));
});

test('Legacy import normalizes retired/duplicate widgets and restores missing defaults', async (t) => {
  const backup = storageFor('alice', { version: 6, widgets: [{ id: 'retired' }, { id: 'fleet', width: 9, hidden: true }, { id: 'fleet', width: 1 }] });
  wire(t, (call) => reply(call.method === 'GET' ? defaultHomeLayout() : { ...call.body!, version: 1 }));
  const result = await adapterFor(backup).load('alice');
  assert.deepEqual(result.widgets[0], { id: 'fleet', width: 2, hidden: true });
  assert.equal(result.widgets.length, 4);
});

test('Two independent importing clients race once; loser reads the winner without overwriting', async (t) => {
  let saved = defaultHomeLayout();
  const reads = deferred<void>();
  let count = 0;
  const calls = wire(t, async (call) => {
    if (call.method === 'GET') {
      const value = structuredClone(saved);
      if (++count <= 2) { if (count === 2) reads.resolve(); await reads.promise; }
      return reply(value);
    }
    if (saved.version !== call.body!.version) return refusal(409, 'conflict');
    saved = { ...call.body!, version: 1 }; return reply(saved);
  });
  const [a, b] = await Promise.all([
    adapterFor(storageFor('alice', changed('chains', 80))).load('alice'),
    adapterFor(storageFor('alice', changed('fleet', 90))).load('alice'),
  ]);
  assert.deepEqual(a, b);
  assert.deepEqual(a, saved);
  assert.equal(calls.filter((call) => call.method === 'PUT').length, 2);
  assert.equal(calls.filter((call) => call.method === 'GET').length, 3);
});

test('Initial GET failure or malformed response never imports/writes; successful reload unlocks edits', async (t) => {
  for (const failure of ['offline', 'invalid']) {
    let fail = true;
    const calls = wire(t, (call) => {
      if (fail) { if (failure === 'offline') throw new Error('offline'); return Response.json({ data: { widgets: [] } }); }
      return reply(call.method === 'GET' ? defaultHomeLayout() : { ...call.body!, version: 1 });
    });
    let latest!: HomeLayoutSnapshot;
    const session = new HomeLayoutSession(adapterFor(storageFor('alice', changed())), 'alice', (value) => { latest = value; });
    await session.load();
    assert.equal(latest.status, 'error');
    assert.match(latest.error!, /could not be loaded/);
    assert.equal(latest.canEdit, false);
    session.edit((value) => setWidgetHidden(value, 'fleet', true));
    await session.flush(); session.dispose();
    assert.equal(calls.length, 1);
    assert.equal(calls[0].method, 'GET');
    // A fresh mounted session can retry; no write occurred before the good GET.
    fail = false;
    const retry = new HomeLayoutSession(adapterFor(storageFor('alice', changed())), 'alice', (value) => { latest = value; });
    await retry.load();
    assert.equal(latest.status, 'saved');
    assert.equal(latest.canEdit, true);
    assert.equal(calls[1].method, 'GET');
    assert.equal(calls[2].method, 'PUT');
    retry.dispose(); t.mock.restoreAll();
  }
});

test('Typed stale conflict rolls back to confirmed layout; explicit reload fetches winner across clients', async (t) => {
  let saved = { ...defaultHomeLayout(), version: 2 };
  wire(t, (call) => {
    if (call.method === 'GET') return reply(saved);
    assert.equal(call.headers.get('If-Match'), `"${call.body!.version}"`);
    if (call.body!.version !== saved.version) return refusal(409, 'conflict');
    saved = { ...call.body!, version: saved.version + 1 }; return reply(saved);
  });
  let a!: HomeLayoutSnapshot, b!: HomeLayoutSnapshot;
  const first = new HomeLayoutSession(adapterFor(), 'alice', (value) => { a = value; });
  const second = new HomeLayoutSession(adapterFor(), 'alice', (value) => { b = value; });
  await Promise.all([first.load(), second.load()]);
  const confirmed = b.layout;
  first.edit((value) => setWidgetHidden(value, 'chains', true)); await first.flush();
  second.edit((value) => setWidgetHidden(value, 'fleet', true)); await second.flush();
  assert.equal(b.status, 'conflict'); assert.deepEqual(b.layout, confirmed);
  await second.refresh(); assert.equal(b.status, 'conflict');
  await second.load(); assert.deepEqual(b.layout, a.layout); assert.equal(b.status, 'saved');
  first.dispose(); second.dispose();
});

test('Network/auth/account mismatch failures preserve confirmed data and truthful feedback', async (t) => {
  for (const outcome of ['offline', 'server', 'auth', 'account']) {
    const saved = changed('chains', 5);
    wire(t, (call) => {
      if (call.method === 'GET') return reply(saved);
      if (outcome === 'offline') throw new Error('offline');
      return refusal(outcome === 'server' ? 500 : outcome === 'auth' ? 401 : 409, outcome === 'account' ? 'account_mismatch' : outcome);
    });
    let latest!: HomeLayoutSnapshot;
    const session = new HomeLayoutSession(adapterFor(), 'alice', (value) => { latest = value; });
    await session.load(); session.edit((value) => setWidgetHidden(value, 'fleet', true)); await session.flush();
    assert.equal(latest.status, 'error'); assert.equal(latest.canEdit, false); assert.deepEqual(latest.layout, saved);
    assert.match(latest.error!, /could not be saved/);
    assert.match(latest.error!, new RegExp(outcome === 'account' ? 'account_mismatch' : outcome));
    session.dispose(); t.mock.restoreAll();
  }
});

test('Default adapter fences changed identity during GET/import and supplies original account to switched-cookie server', async (t) => {
  setExpectedUserId('alice'); t.after(() => setExpectedUserId(''));
  const get = deferred<Response>();
  const calls = wire(t, () => get.promise);
  const adapter = createServerHomeLayoutAdapter({ storage: () => storageFor('alice', changed()) });
  const pending = adapter.load('alice');
  setExpectedUserId('bob'); get.resolve(reply(defaultHomeLayout()));
  await assert.rejects(pending, (error: any) => error.code === 'account_mismatch');
  assert.equal(calls.length, 1);
  await assert.rejects(adapter.save('alice', changed(), 0), (error: any) => error.code === 'account_mismatch');
  assert.equal(calls.length, 1);
  // Other tabs can change the cookie before local auth refresh sees it. The
  // server rejects the captured Alice header instead of writing under Bob.
  t.mock.restoreAll(); setExpectedUserId('alice');
  const guarded = wire(t, (call) => {
    assert.equal(call.headers.get(EXPECTED_USER_HEADER), 'alice');
    return refusal(409, 'account_mismatch');
  });
  await assert.rejects(adapter.save('alice', changed(), 0), (error: any) => error instanceof ApiError && !(error instanceof HomeLayoutConflict) && error.code === 'account_mismatch');
  assert.equal(guarded.length, 1);
});

test('Account switch during import PUT prevents follow-up GET/replies; backup remains', async (t) => {
  let user = 'alice'; const put = deferred<Response>();
  const backup = storageFor('alice', changed('fleet', 23));
  const calls = wire(t, (call) => call.method === 'GET' ? reply(defaultHomeLayout()) : put.promise);
  const adapter = createServerHomeLayoutAdapter({ storage: () => backup, isCurrentUser: (id) => id === user });
  const pending = adapter.load('alice'); await drain();
  assert.equal(calls.length, 2); user = 'bob'; put.resolve(refusal(409, 'conflict'));
  await assert.rejects(pending, (error: any) => error.code === 'account_mismatch');
  assert.equal(calls.length, 2); assert.equal(JSON.parse(backup.getItem(homeLayoutStorageKey('alice'))!).version, 23);
});

test('Switching A to B and back to A cannot revive a delayed load/import', async (t) => {
  setExpectedUserId('alice'); t.after(() => setExpectedUserId(''));
  const get = deferred<Response>(); const calls = wire(t, () => get.promise);
  const adapter = createServerHomeLayoutAdapter({ storage: () => storageFor('alice', changed()) });
  const pending = adapter.load('alice');
  setExpectedUserId('bob'); setExpectedUserId('alice'); get.resolve(reply(defaultHomeLayout()));
  await assert.rejects(pending, (error: any) => error.code === 'account_mismatch');
  assert.equal(calls.length, 1);
});

test('Switch before debounce cancels writes; during save cancels queued edits and ignores old replies', async (t) => {
  t.mock.timers.enable({ apis: ['setTimeout'] });
  let active = true; const saving = deferred<HomeLayout>(); let writes = 0;
  const adapter: HomeLayoutAdapter = { load: async () => defaultHomeLayout(), save: async () => { writes++; return saving.promise; } };
  const snapshots: HomeLayoutSnapshot[] = [];
  const session = new HomeLayoutSession(adapter, 'alice', (value) => snapshots.push(value), 500, () => active);
  await session.load(); session.edit((value) => setWidgetHidden(value, 'chains', true));
  active = false; session.dispose(); t.mock.timers.tick(500); await drain(); assert.equal(writes, 0);
  active = true;
  const next = new HomeLayoutSession(adapter, 'alice', (value) => snapshots.push(value), 500, () => active);
  await next.load(); next.edit((value) => setWidgetHidden(value, 'chains', true));
  t.mock.timers.tick(500); await drain(); assert.equal(writes, 1);
  next.edit((value) => setWidgetHidden(value, 'fleet', true)); t.mock.timers.tick(500);
  active = false; next.dispose(); const count = snapshots.length;
  saving.resolve(changed('chains', 1)); await drain();
  assert.equal(writes, 1); assert.equal(snapshots.length, count);
});

test('Refreshes coalesce, defer through serialized saves, and ignore GET responses racing newer edits', async (t) => {
  t.mock.timers.enable({ apis: ['setTimeout'] });
  let reads = 0; const focus = deferred<HomeLayout>(); const save = deferred<HomeLayout>();
  let latest!: HomeLayoutSnapshot;
  const adapter: HomeLayoutAdapter = {
    load: async () => ++reads === 2 ? focus.promise : { ...changed('fleet'), version: reads },
    save: async () => save.promise,
  };
  const session = new HomeLayoutSession(adapter, 'alice', (value) => { latest = value; });
  await session.load();
  const pending = session.refresh(); session.refresh(); session.refresh(); await drain(); assert.equal(reads, 2);
  session.edit((value) => setWidgetHidden(value, 'chains', true));
  session.refresh(); t.mock.timers.tick(500); await drain();
  focus.resolve(defaultHomeLayout()); await pending;
  assert.equal(latest.status, 'saving'); assert.equal(latest.layout.widgets[1].hidden, true); assert.equal(reads, 2);
  session.refresh(); save.resolve({ ...latest.layout, version: 2 }); await drain();
  assert.equal(reads, 3); assert.equal(latest.status, 'saved'); assert.equal(latest.layout.version, 3);
  session.dispose();
});

test('Successful explicit reload after an initial failure unlocks the same session', async () => {
  let failed = true, writes = 0; let latest!: HomeLayoutSnapshot;
  const session = new HomeLayoutSession({
    load: async () => { if (failed) throw new Error('offline'); return defaultHomeLayout(); },
    save: async (_id, value) => { writes++; return { ...value, version: 1 }; },
  }, 'alice', (value) => { latest = value; });
  await session.load(); session.edit((value) => setWidgetHidden(value, 'fleet', true)); await session.flush(); assert.equal(writes, 0);
  failed = false; await session.load(); session.edit((value) => setWidgetHidden(value, 'fleet', true)); await session.flush();
  assert.equal(latest.status, 'saved'); assert.equal(writes, 1); session.dispose();
});

test('Home default hook uses server, visible focus/online coalesce and account replacement resets immediately', async (t) => {
  const { JSDOM } = await import('jsdom');
  const dom = new JSDOM('<div id="root"></div>', { url: 'http://localhost/', pretendToBeVisual: true });
  const keys = ['window', 'document', 'HTMLElement', 'Node', 'navigator'] as const;
  const descriptors = keys.map((key) => [key, Object.getOwnPropertyDescriptor(globalThis, key)] as const);
  for (const key of keys) Object.defineProperty(globalThis, key, { configurable: true, value: (dom.window as any)[key] });
  const oldAct = (globalThis as any).IS_REACT_ACT_ENVIRONMENT; (globalThis as any).IS_REACT_ACT_ENVIRONMENT = true;
  const { act } = await import('react'); const { createRoot } = await import('react-dom/client');
  const { useHomeLayout } = await import('../src/ui/components/home/useHomeLayout.ts');
  let current!: ReturnType<typeof useHomeLayout>;
  function View({ user }: { user: string }) { current = useHomeLayout(user); return React.createElement('span', null, current.layout.version); }
  const oldLoad = deferred<Response>(), newLoad = deferred<Response>();
  let delayLoads = false;
  const calls = wire(t, (call) => delayLoads
    ? (call.headers.get(EXPECTED_USER_HEADER) === 'alice' ? oldLoad.promise : newLoad.promise)
    : reply(changed('fleet', 7)));
  const root = createRoot(dom.window.document.getElementById('root')!);
  try {
    setExpectedUserId('alice'); await act(async () => { root.render(React.createElement(View, { user: 'alice' })); await drain(); });
    assert.equal(current.layout.version, 7); assert.equal(calls.length, 1);
    delayLoads = true;
    await act(async () => { dom.window.dispatchEvent(new dom.window.Event('focus')); dom.window.dispatchEvent(new dom.window.Event('online')); await drain(); });
    assert.equal(calls.length, 2);
    await act(async () => { setExpectedUserId('bob'); root.render(React.createElement(View, { user: 'bob' })); await drain(); });
    assert.equal(current.status, 'loading'); assert.equal(current.layout.version, 0);
    await act(async () => { oldLoad.resolve(reply(changed('chains', 8))); await drain(); });
    assert.equal(current.layout.version, 0); assert.equal(current.status, 'loading');
    await act(async () => { newLoad.resolve(reply(changed('fleet', 3))); await drain(); });
    assert.equal(current.layout.version, 3);
    assert.equal(calls[2].headers.get(EXPECTED_USER_HEADER), 'bob');
    const count = calls.length;
    await act(async () => { Object.defineProperty(dom.window.document, 'visibilityState', { configurable: true, value: 'hidden' }); dom.window.dispatchEvent(new dom.window.Event('focus')); dom.window.dispatchEvent(new dom.window.Event('online')); await drain(); });
    assert.equal(calls.length, count);
  } finally {
    await act(async () => root.unmount()); setExpectedUserId(''); dom.window.close();
    for (const [key, descriptor] of descriptors) { if (descriptor) Object.defineProperty(globalThis, key, descriptor); else delete (globalThis as any)[key]; }
    (globalThis as any).IS_REACT_ACT_ENVIRONMENT = oldAct;
  }
});
