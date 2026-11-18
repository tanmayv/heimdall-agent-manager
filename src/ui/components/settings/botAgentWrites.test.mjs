import '../../../../tests/helpers/vaultEndpointHarness.ts';
import { test } from 'node:test';
import assert from 'node:assert/strict';
import React, { act } from 'react';
import { JSDOM } from 'jsdom';
import { createRoot } from 'react-dom/client';
import { Provider } from 'react-redux';
import { configureStore } from '@reduxjs/toolkit';
import { heimdallApi } from '../../api/heimdallApi.ts';
import { botsApi } from '../../api/endpoints/bots.ts';
import BotAgentWritesSection from './BotAgentWritesSection.tsx';

const row = (seq, action = 'create', actor_display_name = 'Ninjy bot') => ({
  write_id: 'aw_' + seq, seq, actor_agent_instance_id: 'inst_worker', actor_agent_id: 'agt_worker',
  actor_display_name, resource_kind: 'project', resource_id: 'proj_' + seq, action,
  fields: ['name', 'description'], created_at: '2026-11-18T05:00:00Z',
});

async function fixture(respond, run) {
  const dom = new JSDOM('<div id="root"></div>', { url: 'https://hub.test/' });
  const globals = { window: dom.window, document: dom.window.document, HTMLElement: dom.window.HTMLElement,
    Node: dom.window.Node, navigator: dom.window.navigator, IS_REACT_ACT_ENVIRONMENT: true };
  const saved = new Map(Object.keys(globals).map((key) => [key, Object.getOwnPropertyDescriptor(globalThis, key)]));
  const originalFetch = globalThis.fetch;
  for (const [key, value] of Object.entries(globals)) Object.defineProperty(globalThis, key, { value, configurable: true, writable: true });
  const requests = [];
  globalThis.fetch = async (url, init) => {
    const parsed = new URL(String(url), 'https://hub.test/');
    requests.push({ url: parsed, init });
    return respond(parsed, requests.length);
  };
  const store = configureStore({ reducer: { [heimdallApi.reducerPath]: heimdallApi.reducer }, middleware: (getDefault) => getDefault().concat(heimdallApi.middleware) });
  const root = createRoot(dom.window.document.getElementById('root'));
  const flush = async () => { await act(async () => { await new Promise((resolve) => setTimeout(resolve, 35)); }); };
  const find = (name) => dom.window.document.querySelector('[data-debug-id="settings-bots-agent-writes' + name + '"]');
  const click = async (node) => { assert.ok(node); await act(async () => node.click()); await flush(); };
  try {
    await act(async () => root.render(React.createElement(Provider, { store }, React.createElement(BotAgentWritesSection))));
    await flush();
    await run({ dom, requests, store, find, click, flush });
  } finally {
    await act(async () => { root.unmount(); store.dispatch(heimdallApi.util.resetApiState()); });
    globalThis.fetch = originalFetch;
    dom.window.close();
    for (const [key, descriptor] of saved) {
      if (descriptor) Object.defineProperty(globalThis, key, descriptor); else delete globalThis[key];
    }
  }
}

test('botAgentWrites renders rows, empty state and paging', async () => {
  const cursor = '2026-11-18T05:00:00Z|3&x=1';
  await fixture((url) => Response.json(url.searchParams.has('cursor')
    ? { data: [row(2, 'archive'), row(1, 'unarchive')], page: { next_cursor: '', has_more: false } }
    : { data: [row(4), row(3, 'update', '')], page: { next_cursor: cursor, has_more: true } }),
  async ({ dom, requests, find, click }) => {
    assert.equal(find('').textContent, 'Changes made by agents');
    assert.equal(find('-help').textContent, 'Projects, memories and agents that your agents created or changed. Newest first.');
    assert.equal(find('-empty'), null);
    const texts = () => [...dom.window.document.querySelectorAll('[data-debug-id="settings-bots-agent-writes-row"]')].map((node) => node.textContent);
    assert.equal(texts().length, 2);
    assert.match(texts()[0], /Ninjy bot · created project proj_4 · name, description/);
    assert.match(texts()[1], /inst_worker · updated project proj_3/);
    assert.ok(texts()[0].endsWith(new Date(row(4).created_at).toLocaleString()));
    assert.equal(requests[0].url.pathname, '/api/v1/me/agent-writes');
    assert.equal(requests[0].url.searchParams.get('limit'), '20');
    assert.equal(requests[0].init.credentials, 'include');
    await click(find('-more-btn'));
    assert.equal(requests[1].url.searchParams.get('cursor'), cursor);
    assert.deepEqual(texts().map((text) => text.match(/proj_\d/)[0]), ['proj_4', 'proj_3', 'proj_2', 'proj_1']);
    assert.match(texts()[2], /archived project/);
    assert.match(texts()[3], /restored project/);
    assert.equal(find('-more-btn'), null);
  });
  await fixture(() => Response.json({ data: [], page: { next_cursor: '' } }), async ({ find }) => {
    assert.equal(find('-empty').textContent, 'No changes by agents yet.');
    assert.equal(find('-row'), null);
    assert.equal(find('-more-btn'), null);
  });
});

test('botAgentWrites preserves loaded rows on page failure and retries the same cursor', async () => {
  let fail = true;
  await fixture((url) => {
    if (!url.searchParams.has('cursor')) return Response.json({ data: [row(2)], page: { next_cursor: 'older' } });
    if (fail) return Response.json({ error: { message: 'History unavailable' } }, { status: 500 });
    return Response.json({ data: [row(1)], page: {} });
  }, async ({ find, click, requests, dom }) => {
    await click(find('-more-btn'));
    assert.match(dom.window.document.body.textContent, /History unavailable/);
    assert.match(find('-row').textContent, /proj_2/);
    assert.equal(find('-empty'), null);
    fail = false;
    await click(find('-retry-btn'));
    assert.equal(requests.at(-1).url.searchParams.get('cursor'), 'older');
    assert.equal(dom.window.document.querySelectorAll('[data-debug-id="settings-bots-agent-writes-row"]').length, 2);
    assert.equal(find('-retry-btn'), null);
  });
});

test('botAgentWrites initial loading and failed request never show the empty state', async () => {
  let resolve;
  const response = new Promise((done) => { resolve = done; });
  await fixture(() => response, async ({ dom, find, flush }) => {
    assert.match(dom.window.document.body.textContent, /Loading…/);
    assert.equal(find('-empty'), null);
    await act(async () => resolve(Response.json({ error: { message: 'Please retry' } }, { status: 503 })));
    await flush();
    assert.match(dom.window.document.body.textContent, /Please retry/);
    assert.equal(find('-empty'), null);
  });
});
