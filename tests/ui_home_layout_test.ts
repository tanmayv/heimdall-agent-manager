import { test } from 'node:test';
import assert from 'node:assert/strict';
import React from 'react';
import {
  createLocalHomeLayoutAdapter, defaultHomeLayout, homeLayoutStorageKey, HomeLayoutConflict, HomeLayoutSession,
  moveHomeWidget, visibleHomeWidgets, normalizeHomeLayout, packHomeRows, setWidgetHidden, type HomeLayout, type HomeLayoutAdapter, type HomeLayoutSnapshot,
} from '../src/ui/components/home/homeLayout.ts';

const drain = async () => { for (let i = 0; i < 8; i++) await Promise.resolve(); };
function memoryStorage() {
  const values = new Map<string, string>();
  return { getItem: (key: string) => values.get(key) ?? null, setItem: (key: string, value: string) => { values.set(key, value); } };
}
test('Greedy packing covers every mix of full/half widths through eight tiles, preserving stored widths', () => {
  for (let size = 0; size <= 8; size++) for (let mask = 0; mask < 2 ** size; mask++) {
    const items = Array.from({ length: size }, (_, i) => ({ width: ((mask >> i) & 1 ? 2 : 1) as 1 | 2 }));
    const original = JSON.stringify(items);
    const rows: typeof items[] = [];
    for (const item of items) {
      const last = rows.at(-1);
      if (item.width === 1 && last?.length === 1 && last[0].width === 1) last.push(item);
      else rows.push([item]);
    }
    const expected = rows.flatMap((row) => row.map(() => row.length === 1 ? 2 : 1));
    assert.deepEqual(packHomeRows(items).map((entry) => entry.span), expected, JSON.stringify(items));
    assert.equal(JSON.stringify(items), original);
  }
  // Add tile is a half-width partner; removing it stretches the widget again.
  const half = { width: 1 as const };
  assert.deepEqual(packHomeRows([half, half]).map((entry) => entry.span), [1, 1]);
  assert.deepEqual(packHomeRows([half]).map((entry) => entry.span), [2]);
});
test('Removing/readding keeps previous slot and width; reorder takes the target slot', () => {
  let layout = defaultHomeLayout();
  layout = setWidgetHidden(layout, 'chains', true);
  layout = setWidgetHidden(layout, 'chains', false);
  assert.deepEqual(layout, defaultHomeLayout());
  layout = moveHomeWidget(layout, 'activity', 'uptime');
  assert.deepEqual(layout.widgets.map((item) => item.id), ['chains', 'uptime', 'activity', 'fleet']);
  assert.equal(layout.widgets[2].width, 2);
  assert.equal(moveHomeWidget(layout, 'fleet', 'fleet'), layout);
});
test('Mobile default, reorder/reload and reset retain desktop order and widths', async () => {
  const adapter = createLocalHomeLayoutAdapter(memoryStorage());
  const initial = defaultHomeLayout();
  assert.deepEqual(visibleHomeWidgets(initial, true).map((item) => item.id), ['uptime', 'chains', 'fleet']);
  const mobileEdit = moveHomeWidget(initial, 'uptime', 'fleet', true);
  assert.deepEqual(visibleHomeWidgets(mobileEdit, true).map((item) => item.id), ['chains', 'fleet', 'uptime']);
  assert.deepEqual(mobileEdit.widgets.map(({ id, width }) => ({ id, width })), initial.widgets.map(({ id, width }) => ({ id, width })));
  await adapter.save('mobile-user', mobileEdit, 0);
  const reloaded = await adapter.load('mobile-user');
  assert.deepEqual(visibleHomeWidgets(reloaded, true).map((item) => item.id), ['chains', 'fleet', 'uptime']);
  assert.deepEqual(visibleHomeWidgets(reloaded, false).map((item) => item.id), ['activity', 'chains', 'uptime', 'fleet']);
  assert.deepEqual(visibleHomeWidgets(defaultHomeLayout(), true).map((item) => item.id), ['uptime', 'chains', 'fleet']);
});

test('Local adapter roundtrips versioned per-user layouts, drops unknown/duplicate ids and handles corrupt data', async () => {
  const storage = memoryStorage();
  const adapter = createLocalHomeLayoutAdapter(storage);
  const alice = setWidgetHidden(defaultHomeLayout(), 'activity', true);
  alice.widgets[1].options = { metric: 'tasks_completed' };
  const saved = await adapter.save('alice/a', alice, 0);
  assert.equal(saved.version, 1);
  assert.deepEqual(await adapter.load('alice/a'), saved);
  assert.deepEqual(await adapter.load('bob'), defaultHomeLayout());
  await assert.rejects(adapter.save('alice/a', defaultHomeLayout(), 0), (error: any) => error.status === 409);
  const secondTab = createLocalHomeLayoutAdapter(storage);
  assert.deepEqual(await secondTab.load('alice/a'), saved);
  storage.setItem(homeLayoutStorageKey('bob'), '{invalid');
  assert.deepEqual(await adapter.load('bob'), defaultHomeLayout());
  const raw = { version: 9, widgets: [{ id: 'retired', width: 2 }, { id: 'fleet', width: 17, hidden: true }, { id: 'fleet', width: 1 }] };
  const clean = normalizeHomeLayout(raw);
  assert.equal(clean.widgets.filter((item) => item.id === 'fleet').length, 1);
  assert.deepEqual(clean.widgets[0], { id: 'fleet', width: 2, hidden: true });
  assert.equal(clean.widgets.length, 4);
});
test('Session debounces for 500ms after the final edit and flushes navigation edits', async (t) => {
  t.mock.timers.enable({ apis: ['setTimeout'] });
  const saved: HomeLayout[] = [];
  const adapter: HomeLayoutAdapter = { load: async () => defaultHomeLayout(), save: async (_user, layout, version) => {
    saved.push(layout); return { ...layout, version: version + 1 };
  } };
  const snapshots: HomeLayoutSnapshot[] = [];
  const session = new HomeLayoutSession(adapter, 'alice', (value) => snapshots.push(value));
  await session.load();
  session.edit((layout) => setWidgetHidden(layout, 'chains', true));
  t.mock.timers.tick(499); await drain(); assert.equal(saved.length, 0);
  session.edit((layout) => setWidgetHidden(layout, 'uptime', true));
  t.mock.timers.tick(499); await drain(); assert.equal(saved.length, 0);
  t.mock.timers.tick(1); await drain(); assert.equal(saved.length, 1);
  assert.equal(snapshots.at(-1)!.layout.version, 1);
  assert.equal(snapshots.at(-1)!.status, 'saved');
  session.edit((layout) => setWidgetHidden(layout, 'fleet', true));
  session.dispose(); await drain();
  assert.equal(saved.length, 2);
  assert.equal(saved[1].widgets.find((item) => item.id === 'fleet')!.hidden, true);
});
test('Session serializes slow saves and retains edits made during an earlier request', async (t) => {
  t.mock.timers.enable({ apis: ['setTimeout'] });
  const requests: { layout: HomeLayout; version: number; resolve: (value: HomeLayout) => void }[] = [];
  const adapter: HomeLayoutAdapter = {
    load: async () => defaultHomeLayout(),
    save: async (_user, layout, version) => new Promise((resolve) => requests.push({ layout, version, resolve })),
  };
  let latest: HomeLayoutSnapshot;
  const session = new HomeLayoutSession(adapter, 'alice', (value) => { latest = value; });
  await session.load();
  session.edit((layout) => setWidgetHidden(layout, 'chains', true));
  t.mock.timers.tick(500); await drain(); assert.equal(requests.length, 1);
  session.edit((layout) => setWidgetHidden(layout, 'fleet', true));
  t.mock.timers.tick(500); await drain(); assert.equal(requests.length, 1);
  requests[0].resolve({ ...requests[0].layout, version: 1 }); await drain();
  assert.equal(requests.length, 2);
  assert.equal(requests[1].version, 1);
  assert.equal(latest!.layout.widgets.find((item) => item.id === 'fleet')!.hidden, true);
  requests[1].resolve({ ...requests[1].layout, version: 2 }); await drain();
  assert.equal(latest!.layout.version, 2); assert.equal(latest!.status, 'saved');
  session.dispose();
});
test('Fake 409 and storage errors roll back all pending changes to the last accepted layout', async () => {
  for (const error of [new HomeLayoutConflict(), new Error('Storage quota')]) {
    const good = { ...setWidgetHidden(defaultHomeLayout(), 'activity', true), version: 7 };
    const adapter: HomeLayoutAdapter = { load: async () => good, save: async () => { throw error; } };
    let latest: HomeLayoutSnapshot;
    const session = new HomeLayoutSession(adapter, 'alice', (value) => { latest = value; });
    await session.load();
    session.edit((layout) => setWidgetHidden(layout, 'fleet', true));
    await session.flush();
    assert.deepEqual(latest!.layout, good);
    assert.equal(latest!.status, error instanceof HomeLayoutConflict ? 'conflict' : 'error');
    await session.load();
    assert.equal(latest!.status, 'saved');
    session.dispose();
  }
});

test('Dashboard edit controls: keyboard menu reorder/width, removal, checkbox menu, handle-only drop and reload isolation', async () => {
  const { JSDOM } = await import('jsdom');
  const dom = new JSDOM('<!doctype html><html><body><div id="root"></div></body></html>', { url: 'http://localhost/' });
  const win = dom.window as any;
  let mobile = false;
  const mediaListeners = new Set<() => void>();
  win.matchMedia = () => ({ get matches() { return mobile; }, addEventListener(_name: string, fn: () => void) { mediaListeners.add(fn); }, removeEventListener(_name: string, fn: () => void) { mediaListeners.delete(fn); } });
  win.HTMLElement.prototype.scrollIntoView = function () {};
  win.CSS = { escape: (value: string) => value };
  const keys = ['window', 'document', 'HTMLElement', 'Node', 'KeyboardEvent', 'MouseEvent', 'localStorage', 'CSS'] as const;
  const saved = new Map(keys.map((key) => [key, (globalThis as any)[key]]));
  const savedAct = (globalThis as any).IS_REACT_ACT_ENVIRONMENT;
  for (const key of keys) (globalThis as any)[key] = key === 'window' ? win : key === 'document' ? win.document : win[key];
  (globalThis as any).IS_REACT_ACT_ENVIRONMENT = true;
  const { createRoot } = await import('react-dom/client');
  const { act } = await import('react');
  const { HomeDashboard } = await import('../src/ui/components/home/HomePage.tsx');
  const { WidgetHeading } = await import('../src/ui/components/home/WidgetShared.tsx');
  const widgets = Object.fromEntries(['activity', 'chains', 'uptime', 'fleet'].map((id) => [id,
    React.createElement('section', { 'data-debug-id': 'test-widget-' + id }, React.createElement(WidgetHeading, { id: id + '-title', title: id }), React.createElement('input', { 'data-debug-id': 'test-control-' + id })),
  ]));
  const storage = memoryStorage();
  const adapter = createLocalHomeLayoutAdapter(storage);
  const root = createRoot(win.document.getElementById('root'));
  const doc = win.document;
  const get = (id: string) => doc.querySelector('[data-debug-id="' + id + '"]') as HTMLElement;
  const order = () => [...doc.querySelectorAll('.home-widget-slot')].map((el: any) => el.getAttribute('data-debug-id').replace('home-layout-slot-', ''));
  const click = async (id: string) => { assert.ok(get(id), id); await act(async () => get(id).click()); };
  const render = async (userId = 'alice') => { await act(async () => { root.render(React.createElement(HomeDashboard, { key: userId, userId, adapter, widgets })); await drain(); }); };
  try {
    await render();
    assert.equal(get('home-layout-handle-chains'), null);
    await click('home-layout-edit');
    assert.equal(get('home-layout-edit').textContent, 'Done');
    assert.ok(get('home-layout-add-tile'));
    assert.equal(get('home-layout-handle-chains').getAttribute('draggable'), 'true');
    assert.equal(get('home-layout-slot-chains').getAttribute('draggable'), null);
    assert.equal(get('test-control-chains').getAttribute('draggable'), null);
    await click('home-layout-handle-chains');
    assert.equal(doc.activeElement, get('home-layout-earlier-chains'));
    await act(async () => get('home-layout-earlier-chains').dispatchEvent(new win.KeyboardEvent('keydown', { key: 'ArrowDown', bubbles: true })));
    assert.equal(doc.activeElement, get('home-layout-later-chains'));
    await act(async () => (doc.activeElement as HTMLElement).click());
    assert.deepEqual(order(), ['activity', 'uptime', 'chains', 'fleet']);
    assert.equal(doc.activeElement, get('home-layout-handle-chains'));
    await click('home-layout-handle-chains'); await click('home-layout-width-chains');
    assert.equal(get('home-layout-slot-chains').getAttribute('data-stored-width'), '2');
    await click('home-layout-remove-uptime');
    assert.equal(get('home-layout-slot-uptime'), null);
    await click('home-layout-add-uptime');
    assert.deepEqual(order(), ['activity', 'uptime', 'chains', 'fleet']);
    await click('home-layout-add-menu');
    assert.equal(doc.querySelectorAll('[role="menuitemcheckbox"]').length, 4);
    assert.match(doc.querySelector('[role="menu"]')!.textContent!, /Daily heatmap of tasks, chains, agents and bridges/);
    await click('home-layout-toggle-activity');
    assert.equal(get('home-layout-slot-activity'), null);
    const drag = async (id: string, type: string) => {
      const event = new win.Event(type, { bubbles: true, cancelable: true });
      Object.defineProperty(event, 'dataTransfer', { value: { setData() {}, setDragImage() {}, effectAllowed: '', dropEffect: '' } });
      await act(async () => get(id).dispatchEvent(event));
    };
    const beforeExternalDrop = order();
    await drag('home-layout-slot-fleet', 'drop');
    assert.deepEqual(order(), beforeExternalDrop);
    await drag('home-layout-handle-fleet', 'dragstart');
    await drag('home-layout-slot-uptime', 'dragover');
    assert.ok(get('home-layout-slot-uptime').classList.contains('is-drop-target'));
    await drag('home-layout-slot-uptime', 'drop');
    assert.deepEqual(order(), ['fleet', 'uptime', 'chains']);
    assert.equal(doc.querySelector('.is-dragging'), null);
    // Flush-on-navigation persists only Alice's layout; Bob gets untouched defaults.
    await render('bob');
    assert.deepEqual(order(), ['activity', 'chains', 'uptime', 'fleet']);
    await render('alice');
    assert.deepEqual(order(), ['fleet', 'uptime', 'chains']);
    await click('home-layout-edit');
    await click('home-layout-add-activity');
    await click('home-layout-handle-fleet'); await click('home-layout-reset-fleet');
    assert.deepEqual(order(), ['activity', 'chains', 'uptime', 'fleet']);
    await act(async () => { mobile = true; mediaListeners.forEach((fn) => fn()); });
    assert.equal(get('home-layout-slot-activity'), null);
    assert.deepEqual(order(), ['uptime', 'chains', 'fleet']);
    assert.equal(get('home-layout-handle-uptime'), null);
    assert.equal(doc.querySelector('[draggable="true"]'), null);
    assert.equal((get('home-layout-up-uptime') as HTMLButtonElement).disabled, true);
    assert.equal((get('home-layout-down-fleet') as HTMLButtonElement).disabled, true);
    assert.equal(get('home-layout-up-chains').getAttribute('aria-label'), 'Move Task chains widget up');
    get('home-layout-down-uptime').focus();
    await click('home-layout-down-uptime');
    assert.deepEqual(order(), ['chains', 'uptime', 'fleet']);
    assert.ok(doc.activeElement === get('home-layout-down-uptime'), 'retain activated arrow focus after moving');
    assert.equal(get('home-layout-announcement').textContent, 'Uptime moved to position 2 of 3.');
    await click('home-layout-down-uptime');
    assert.deepEqual(order(), ['chains', 'fleet', 'uptime']);
    assert.ok(doc.activeElement === get('home-layout-up-uptime'), 'focus enabled sibling at the boundary');
    await click('home-layout-up-uptime');
    await render('bob'); await render('alice');
    assert.deepEqual(order(), ['chains', 'uptime', 'fleet']);
    await click('home-layout-edit');
    await click('home-layout-options-chains');
    assert.ok(get('home-layout-actions-sheet-chains')?.matches('[role="dialog"][aria-modal="true"]'));
    assert.equal(doc.body.style.overflow, 'hidden');
    assert.equal(get('home-layout-width-chains'), null);
    assert.equal(get('home-layout-earlier-chains'), null);
    await act(async () => get('home-layout-menu-remove-chains').dispatchEvent(new win.KeyboardEvent('keydown', { key: 'Escape', bubbles: true })));
    assert.equal(get('home-layout-options-chains').getAttribute('aria-expanded'), 'false');
    assert.equal(doc.body.style.overflow, '');
    await act(async () => { get('home-layout-actions-sheet-chains')?.dispatchEvent(new win.Event('animationend', { bubbles: true })); });
    await click('home-layout-add-menu');
    assert.ok(get('home-layout-add-sheet')?.matches('[role="dialog"][aria-modal="true"]'));
    assert.equal(get('home-layout-add-menu').getAttribute('aria-haspopup'), 'dialog');
    assert.equal(doc.querySelectorAll('[role="menuitemcheckbox"]').length, 3);
    assert.equal(get('home-layout-toggle-activity'), null);
    assert.ok(get('home-layout-add-sheet').contains(doc.activeElement));
    assert.equal(doc.body.style.overflow, 'hidden');
    await click('home-layout-toggle-fleet');
    assert.equal(get('home-layout-slot-fleet'), null);
    assert.ok(get('home-layout-add-sheet').contains(doc.activeElement), 'multi-toggle keeps focus in the sheet');
    assert.equal(get('home-layout-add-menu').getAttribute('aria-expanded'), 'true');
    assert.equal(get('home-layout-toggle-fleet').getAttribute('aria-checked'), 'false');
    await click('home-layout-toggle-fleet');
    assert.equal(get('home-layout-toggle-fleet').getAttribute('aria-checked'), 'true');
    await act(async () => doc.activeElement!.dispatchEvent(new win.KeyboardEvent('keydown', { key: 'Escape', bubbles: true })));
    const finishSheetExit = async () => { await act(async () => { await new Promise((resolve) => setTimeout(resolve, 320)); }); };
    await finishSheetExit();
    await click('home-layout-add-menu');
    assert.equal(get('home-layout-toggle-fleet').getAttribute('aria-checked'), 'true');
    await click('home-layout-toggle-fleet');
    await act(async () => doc.activeElement!.dispatchEvent(new win.KeyboardEvent('keydown', { key: 'Escape', bubbles: true })));
    await finishSheetExit();
    await click('home-layout-add-menu');
    await act(async () => doc.activeElement!.dispatchEvent(new win.KeyboardEvent('keydown', { key: 'Escape', bubbles: true })));
    assert.equal(get('home-layout-add-menu').getAttribute('aria-expanded'), 'false');
    assert.ok(doc.activeElement === get('home-layout-add-menu'), 'Escape restores trigger focus');
    assert.equal(doc.body.style.overflow, '');
    await finishSheetExit();
    await click('home-layout-add-menu');
    await click('home-layout-toggle-fleet');
    await act(async () => doc.activeElement!.dispatchEvent(new win.KeyboardEvent('keydown', { key: 'Escape', bubbles: true })));
    await finishSheetExit();
    await click('home-layout-add-menu');
    await act(async () => get('home-layout-add-sheet').parentElement!.dispatchEvent(new win.MouseEvent('mousedown', { bubbles: true })));
    assert.equal(get('home-layout-add-menu').getAttribute('aria-expanded'), 'false');
    await finishSheetExit();
    await render('bob'); await render('alice');
    assert.deepEqual(order(), ['chains', 'uptime', 'fleet'], 'remove/add persists with mobile order');
    await act(async () => { mobile = false; mediaListeners.forEach((fn) => fn()); });
    assert.deepEqual(order(), ['activity', 'chains', 'uptime', 'fleet'], 'mobile reorder preserves desktop order');
    await act(async () => { mobile = true; mediaListeners.forEach((fn) => fn()); });
    await click('home-layout-edit');
    await click('home-layout-options-chains');
    await act(async () => { mobile = false; mediaListeners.forEach((fn) => fn()); });
    assert.equal(doc.querySelector('[role="dialog"]'), null, 'breakpoint crossing removes the action sheet');
    assert.equal(doc.body.style.overflow, '');
    await act(async () => { mobile = true; mediaListeners.forEach((fn) => fn()); });
    await click('home-layout-options-chains');
    await click('home-layout-menu-remove-chains');
    assert.equal(doc.querySelector('[role="dialog"]'), null);
    assert.equal(doc.activeElement, get('home-layout-edit'), 'removed action trigger returns focus to Edit');
    await click('home-layout-add-chains');
    await click('home-layout-options-chains');
    await click('home-layout-edit');
    assert.equal(doc.querySelector('[role="dialog"]'), null, 'edit completion removes the action sheet');
    assert.equal(doc.activeElement, get('home-layout-edit'));
    await click('home-layout-edit');
    await click('home-layout-options-chains'); await click('home-layout-reset-chains');
    assert.deepEqual(order(), ['uptime', 'chains', 'fleet']);
    for (const id of ['uptime', 'chains', 'fleet']) await click('home-layout-remove-' + id);
    assert.match(get('home-layout-empty').textContent!, /No widgets on your home page/);
    await click('home-layout-add-all');
    assert.equal(order().length, 3);
  } finally {
    await act(async () => root.unmount());
    dom.window.close();
    for (const key of keys) {
      const value = saved.get(key);
      if (value === undefined) delete (globalThis as any)[key]; else (globalThis as any)[key] = value;
    }
    (globalThis as any).IS_REACT_ACT_ENVIRONMENT = savedAct;
  }
});
