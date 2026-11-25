import './helpers/vaultEndpointHarness.ts';
import { test } from 'node:test';
import assert from 'node:assert/strict';
import React from 'react';

test('webhook creation shows credentials once, dismisses and rotates with confirmation', async () => {
  await (await import('./helpers/vaultEndpointHarness.ts')).makeVaultStore();
  const { JSDOM } = await import('jsdom');
  const dom = new JSDOM('<div id="root"></div>', { url: 'https://hub.example/', pretendToBeVisual: true });
  const g = globalThis as any;
  const names = ['window', 'document', 'HTMLElement', 'HTMLInputElement', 'Node', 'requestAnimationFrame', 'cancelAnimationFrame', 'IS_REACT_ACT_ENVIRONMENT'];
  const previous = new Map(names.map(name => [name, Object.getOwnPropertyDescriptor(g, name)]));
  for (const name of names) Object.defineProperty(g, name, { configurable: true, writable: true, value: name === 'IS_REACT_ACT_ENVIRONMENT' ? true : (dom.window as any)[name] });
  const originalFetch = globalThis.fetch;
  const calls: { url: string; method: string; body: any }[] = [];
  const row = { webhook_id: 'wh_one', name: 'CI', enabled: true, last_received_at: '' };
  globalThis.fetch = (async (url: any, init: any = {}) => {
    const method = init.method || 'GET'; calls.push({ url: String(url), method, body: init.body && JSON.parse(init.body) });
    const data = method === 'GET' ? [] : { webhook: row, token: String(url).endsWith('/rotate') ? 'rotated-secret' : 'once-secret' };
    return new Response(JSON.stringify({ data }), { headers: { 'content-type': 'application/json' } });
  }) as any;
  let root: any;
  try {
    const { createRoot } = await import('react-dom/client');
    const Webhooks = (await import('../src/ui/components/actions/WebhooksSection.tsx')).default;
    root = createRoot(dom.window.document.getElementById('root')!);
    await React.act(async () => root.render(React.createElement(Webhooks)));
    const doc = dom.window.document;
    const byId = (id: string) => doc.querySelector('[data-debug-id="' + id + '"]')!;
    const click = async (id: string) => { await React.act(async () => byId(id).dispatchEvent(new dom.window.MouseEvent('click', { bubbles: true }))); };
    await React.act(async () => {
      Object.getOwnPropertyDescriptor(dom.window.HTMLInputElement.prototype, 'value')!.set!.call(byId('webhook-name'), 'CI');
      byId('webhook-name').dispatchEvent(new dom.window.Event('input', { bubbles: true }));
    });
    assert.equal((byId('webhook-create') as HTMLButtonElement).disabled, false, 'name input updates React state');
    await React.act(async () => doc.querySelector('form')!.dispatchEvent(new dom.window.Event('submit', { bubbles: true, cancelable: true })));
    assert.ok(byId('webhook-token'), JSON.stringify(calls) + doc.body.textContent);
    assert.equal((byId('webhook-token') as HTMLInputElement).value, 'once-secret');
    assert.equal((byId('webhook-secret-url') as HTMLInputElement).value, 'https://hub.example/api/v1/hooks/wh_one/once-secret');
    assert.equal(doc.activeElement?.id, 'webhook-secret-title');
    assert.ok(doc.body.textContent?.includes('Anyone holding the secret URL can post events'));
    dom.window.confirm = () => false;
    await click('webhook-secret-dismiss');
    assert.ok(byId('webhook-token'));
    dom.window.confirm = () => true;
    await click('webhook-secret-dismiss');
    assert.equal(byId('webhook-token'), null);
    await React.act(async () => { await new Promise(resolve => dom.window.requestAnimationFrame(resolve)); });
    assert.equal(doc.activeElement, byId('webhook-name'));
    dom.window.confirm = () => false;
    await click('webhook-rotate-wh_one');
    assert.equal(calls.filter(c => c.url.endsWith('/rotate')).length, 0);
    await click('webhook-rotate-cancel');
    await click('webhook-rotate-wh_one');
    await click('webhook-rotate-confirm');
    assert.equal((byId('webhook-token') as HTMLInputElement).value, 'rotated-secret');
    assert.deepEqual(calls.find(c => c.method === 'POST' && !c.url.endsWith('/rotate'))?.body, { name: 'CI' });
    await React.act(async () => root.unmount());
    await React.act(async () => { root = createRoot(doc.getElementById('root')!); root.render(React.createElement(Webhooks)); });
    assert.equal(byId('webhook-token'), null, 'remount cannot recover the secret');
  } finally {
    if (root) await React.act(async () => root.unmount());
    globalThis.fetch = originalFetch;
    for (const [name, descriptor] of previous) { if (descriptor) Object.defineProperty(g, name, descriptor); else delete g[name]; }
    dom.window.close();
  }
});

test('history overlays full true/false trace, shows seen and missing values, and hides edited trees', async () => {
  const { renderToStaticMarkup } = await import('react-dom/server');
  const { RunMatch, runRowText } = await import('../src/ui/components/actions/RunHistory.tsx');
  const { JSDOM } = await import('jsdom');
  const triggers: any = [{ id: 'tr', kind: 'event', rev: 7, enabled: true, config: { event_type: 'webhook.received', filter: { any: [
    { field: 'data.action', op: 'eq', value: 'opened' }, { field: 'data.missing', op: 'exists', value: true },
  ] } } }];
  const run: any = { id: 'run', trigger_id: 'tr', event_params: { _match: { rev: 7, nodes: 'TTF' }, _omitted: [], data: { action: 'opened' } } };
  const dom = new JSDOM(renderToStaticMarkup(React.createElement(RunMatch, { run, triggers })));
  assert.equal(dom.window.document.querySelectorAll('[role="treeitem"]').length, 3);
  assert.match(dom.window.document.body.textContent!, /saw: "opened"/);
  assert.match(dom.window.document.body.textContent!, /saw: missing/);
  assert.ok(dom.window.document.querySelector('[aria-label*="Did not match"]'));
  dom.window.close();
  triggers[0].rev = 8;
  const edited = renderToStaticMarkup(React.createElement(RunMatch, { run, triggers }));
  assert.match(edited, /Rule edited since this run/);
  assert.match(edited, /opened/);
  assert.doesNotMatch(edited, /role="tree"/);
  assert.match(renderToStaticMarkup(React.createElement(RunMatch, { run, triggers: [] })), /Rule edited since/);
  assert.match(runRowText({ ...run, state: 'delivered', batch_size: 3 }), /delivered with 2 other actions/);
  assert.equal(runRowText({ ...run, state: 'deferred', target_instance_id: 'inst' }), 'Waiting for the agent to read the previous prompt');
});


test('seen values distinguish missing, omitted, truncated and unrecorded paths', async () => {
  const { seenValue, recordedValues } = await import('../src/ui/components/actions/runTrace.ts');
  assert.equal(seenValue({ _omitted: [], data: { draft: false, count: 2, nil: null } }, 'data.draft'), 'false');
  assert.equal(seenValue({ _omitted: [], data: {} }, 'data.absent'), 'missing');
  assert.equal(seenValue({ data: {} }, 'data.absent'), 'missing or value not recorded');
  assert.equal(seenValue({ _omitted: ['data.repo'], data: {} }, 'data.repo.name'), 'value not recorded (snapshot limit)');
  assert.equal(seenValue({ _omitted: [], data: { repo: { _truncated: true, bytes: 3000 } } }, 'data.repo.name'), 'value truncated (3000 bytes)');
  assert.equal(seenValue({ _omitted: [], _omitted_count: 3, data: {} }, 'data.absent'), 'missing or value not recorded');
  assert.match(seenValue({ data: { title: 'partial…[truncated 3000 bytes]' } }, 'data.title'), /truncated 3000 bytes/);
  assert.deepEqual(recordedValues({ _match: { rev: 1, nodes: 'T' }, data: { _custom: 2 }, _omitted: ['data.repo'] }), [['data._custom', '2'], ['data.repo', 'value not recorded (snapshot limit)']]);
});
