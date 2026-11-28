// Run: node --import ./tests/helpers/vaultEndpointHarness.ts --test src/ui/components/settings/botsLoading.test.mjs
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { JSDOM } from 'jsdom';
import React, { act } from 'react';
import { createRoot } from 'react-dom/client';
import { Provider } from 'react-redux';
import { configureStore } from '@reduxjs/toolkit';

const { default: BotsPanel } = await import('./BotsPanel.tsx');
const { heimdallApi } = await import('../../api/heimdallApi.ts');
const { default: vault } = await import('../../store/vaultSlice.ts');
const { default: auxPanes } = await import('../../store/auxPanesSlice.ts');

function bot(paired = false) {
  return { bot_id: 'bot_loading', display_name: 'Ninjy bot', status: 'ready', status_detail: '',
    telegram: { configured: true, bot_username: 'ninjy_test', binding: paired ? { state: 'active', display: '@alice', connected_at: '2026-11-18' } : null },
    whatsapp: { configured: false, phone_display: '', binding: null, window_open: false, reengage_sent: false, reengage_error: '', held_replies: [] },
    placement_revision: 3, advanced: { agent_instance_id: '', bridge_id: '', bridge_label: '', provider: '', model: '', runtime_status: '' } };
}
async function fixture(run, initial = bot(), holdInitial = '', initialRollout = { enabled: false, generation: 0, agent_instance_id: '', conversation_id: '', bot_id: '' }) {
  const dom = new JSDOM('<div id="root"></div>', { url: 'https://hub.test/', pretendToBeVisual: true });
  const saved = new Map();
  for (const [key, value] of Object.entries({ window: dom.window, document: dom.window.document, HTMLElement: dom.window.HTMLElement, Node: dom.window.Node,
    navigator: dom.window.navigator, CSS: { escape: value => value.replace(/[^a-zA-Z0-9_-]/g, char => String.fromCharCode(92) + char) }, requestAnimationFrame: dom.window.requestAnimationFrame.bind(dom.window), cancelAnimationFrame: dom.window.cancelAnimationFrame.bind(dom.window), IS_REACT_ACT_ENVIRONMENT: true })) {
    saved.set(key, Object.getOwnPropertyDescriptor(globalThis, key));
    Object.defineProperty(globalThis, key, { value, configurable: true, writable: true });
  }
  dom.window.HTMLElement.prototype.scrollIntoView = () => {};
  const previousFetch = globalThis.fetch;
  const requests = [];
  let current = initial;
  let rollout = initialRollout;
  let held = holdInitial && { method: 'GET', suffix: holdInitial };
  let release;
  let failure = false;
  globalThis.fetch = async (url, init = {}) => {
    const path = new URL(String(url), 'https://hub.test').pathname;
    const method = init.method || 'GET';
    requests.push({ path, method, body: init.body ? JSON.parse(init.body) : undefined });
    if (held && method === held.method && path.endsWith(held.suffix)) {
      await new Promise(resolve => { release = resolve; });
      held = null;
      if (failure) return Response.json({ error: { code: 'unavailable', message: 'Try again' } }, { status: 503 });
    }
    let data;
    if (path.endsWith('/experiments')) data = { experiments: [{ key: 'bots', enabled: true }] };
    else if (path.endsWith('/agent-writes')) data = [];
    else if (path.endsWith('/web-conversation')) {
      if (method === 'PUT') rollout = { ...rollout, enabled: false, generation: rollout.generation + 1 };
      data = rollout;
    }
    else if (path.endsWith('/placement/options')) data = { bridges: [{ bridge_id: 'brg_a', label: 'Laptop', providers: [{ provider: 'claude', label: 'Claude', models: ['opus'] }] }] };
    else if (path.endsWith('/placement')) data = { placement_revision: 3, candidates: [{ bridge_id: '*', provider: '*', model: '*', tier: 'allowed' }] };
    else if (path.endsWith('/deliveries')) data = { deliveries: [] };
    else if (path.endsWith('/pairing')) data = { pairing_url: 'https://t.me/test?start=abc', expires_at: '2026-11-18T01:00:00Z' };
    else if (path.endsWith('/telegram')) { current.telegram.binding = null; data = { disconnected: true }; }
    else if (method === 'POST') { current = bot(); data = current; }
    else if (method === 'DELETE') { current = null; data = { deleted: true }; }
    else if (!current) return Response.json({ error: { code: 'not_found', message: 'No bot' } }, { status: 404 });
    else data = current;
    return Response.json({ data });
  };
  const store = configureStore({ reducer: { vault, auxPanes, [heimdallApi.reducerPath]: heimdallApi.reducer },
    middleware: g => g({ serializableCheck: false }).concat(heimdallApi.middleware), enhancers: g => g({ autoBatch: false }) });
  const root = createRoot(dom.window.document.getElementById('root'));
  const get = id => dom.window.document.querySelector('[data-debug-id="' + id + '"]');
  const settle = async () => { await act(async () => { await new Promise(r => setTimeout(r, 30)); }); };
  const click = async (id, twice = false) => {
    assert.ok(get(id), id);
    await act(async () => { get(id).click(); if (twice) get(id).click(); });
    await settle();
  };
  try {
    await act(async () => root.render(React.createElement(Provider, { store, children: React.createElement(BotsPanel) })));
    await settle(); await settle();
    await run({ dom, get, requests, click, settle, hold: (method, suffix, fail = false) => { held = { method, suffix }; failure = fail; },
      release: async () => { assert.ok(release, 'request reached deferred fetch'); await act(async () => release()); await settle(); } });
  } finally {
    release?.();
    await act(async () => root.unmount());
    store.dispatch(heimdallApi.util.resetApiState());
    globalThis.fetch = previousFetch;
    dom.window.close();
    for (const [key, value] of saved) { if (value) Object.defineProperty(globalThis, key, value); else delete globalThis[key]; }
  }
}
const prefix = 'settings-bots-';

test('shared bot settings can pause the pinned generation without offering legacy pairings or deletion', async () => {
  await fixture(async (h) => {
    assert.equal(h.get(prefix + 'telegram-card'), null);
    assert.equal(h.get(prefix + 'delete-btn'), null);
    await h.click('settings-bot-web-pause');
    assert.deepEqual(h.requests.find(request => request.method === 'PUT').body, { enabled: false, expected_generation: 5 });
    assert.match(h.dom.window.document.body.textContent, /Your shared conversation is paused/);
  }, bot(), '', { enabled: true, generation: 5, agent_instance_id: 'inst_new', conversation_id: 'chat_new', bot_id: 'bot_loading' });
});
function loading(h, id) {
  const button = h.get(prefix + id);
  assert.equal(button.getAttribute('aria-busy'), 'true');
  assert.equal(button.disabled, true);
  assert.ok(button.querySelector('.animate-spin'), 'Button renders its loading glyph');
}
for (const fail of [false, true]) {
  for (const action of ['create', 'placement', 'connect', 'disconnect', 'delete']) {
    test(action + ' keeps loader and rejects duplicate submission until ' + (fail ? 'failure' : 'success'), async () => {
      await fixture(async h => {
        const routes = { create: ['POST', '/bots/me', 'create-btn'], placement: ['PUT', '/placement', 'placement-save-btn'],
          connect: ['POST', '/pairing', 'telegram-connect-btn'], disconnect: ['DELETE', '/telegram', 'telegram-disconnect-confirm-btn'],
          delete: ['DELETE', '/bots/me', 'delete-confirm-btn'] };
        if (action === 'disconnect') await h.click(prefix + 'telegram-disconnect-btn');
        if (action === 'delete') await h.click(prefix + 'delete-btn');
        const [method, suffix, id] = routes[action];
        h.hold(method, suffix, fail);
        await h.click(prefix + id, true);
        loading(h, id);
        if (action === 'placement') {
          for (const control of ['placement-add-btn', 'placement-remove-0', 'placement-bridge-0', 'placement-provider-0', 'placement-tier-0']) assert.equal(h.get(prefix + control).disabled, true);
        }
        if (action === 'disconnect') assert.equal(h.get(prefix + 'telegram-disconnect-btn').disabled, true);
        await h.click(prefix + id);
        assert.equal(h.requests.filter(r => r.method === method && r.path.endsWith(suffix)).length, 1);
        await h.release();
        assert.equal(h.get(prefix + id)?.getAttribute('aria-busy') ?? null, null);
        if (fail) {
          assert.ok(h.dom.window.document.querySelector('[role="alert"]'));
          assert.equal(h.get(prefix + id).disabled, false, 'failure permits retry');
        }
      }, action === 'create' ? null : bot(action === 'disconnect'));
    });
  }
}
test('initial bot and placement-options loads render shared spinners', async () => {
  await fixture(async h => {
    assert.ok(h.dom.window.document.querySelector('[role="status"][aria-label="Loading…"]'));
    await h.release();
    assert.ok(h.get(prefix + 'status'));
  }, bot(), '/bots/me');
  await fixture(async h => {
    assert.ok(h.get(prefix + 'placement-toggle').closest('details').querySelector('[role="status"][aria-label="Loading…"]'));
    assert.equal(h.get(prefix + 'placement-save-btn').disabled, true);
    await h.release();
    assert.equal(h.get(prefix + 'placement-save-btn').disabled, false);
  }, bot(), '/placement/options');
});
test('copy link waits for clipboard and disables connect, including failure recovery', async () => {
  await fixture(async h => {
    await h.click(prefix + 'telegram-connect-btn');
    let release, count = 0;
    Object.defineProperty(h.dom.window.navigator, 'clipboard', { configurable: true, value: { writeText: () => { count++; return new Promise((_, reject) => { release = () => reject(new Error('Clipboard denied')); }); } } });
    await h.click(prefix + 'telegram-copy-btn', true);
    loading(h, 'telegram-copy-btn');
    assert.equal(h.get(prefix + 'telegram-connect-btn').disabled, true);
    assert.equal(count, 1);
    await act(async () => release()); await h.settle();
    assert.equal(h.get(prefix + 'telegram-copy-btn').disabled, false);
    assert.equal(h.get(prefix + 'telegram-connect-btn').disabled, false);
    assert.match(h.dom.window.document.querySelector('[role="alert"]').textContent, /Clipboard denied/);
  });
});

test('shared placement selects preserve machine, provider, model and tier wire values', async () => {
  await fixture(async h => {
    async function choose(id, text) {
      await h.click(prefix + id);
      const option = [...h.dom.window.document.querySelectorAll('[role="option"]')].find(e => e.textContent.includes(text));
      assert.ok(option, text);
      await act(async () => option.click());
      await h.settle();
    }
    await choose('placement-bridge-0', 'Laptop');
    await choose('placement-provider-0', 'Claude');
    assert.equal(h.get(prefix + 'placement-model-0').disabled, false);
    await choose('placement-model-0', 'opus');
    await choose('placement-tier-0', 'Preferred');
    await h.click(prefix + 'placement-save-btn');
    assert.deepEqual(h.requests.find(r => r.method === 'PUT').body, {
      expected_revision: 3, candidates: [{ bridge_id: 'brg_a', provider: 'claude', model: 'opus', tier: 'preferred' }]
    });
  });
});
