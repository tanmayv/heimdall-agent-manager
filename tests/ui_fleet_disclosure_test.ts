import { test } from 'node:test';
import assert from 'node:assert/strict';
import React from 'react';
import { makeVaultStore } from './helpers/vaultEndpointHarness.ts';

for (const mobile of [false, true]) test(`Fleet disclosure keeps drafts/errors/results and route focus with ${mobile ? 'mobile sheets' : 'desktop popups'}`, async () => {
  const { JSDOM } = await import('jsdom');
  const dom = new JSDOM('<!doctype html><div id="root"></div>', { url: 'http://localhost/' });
  const win = dom.window as any;
  win.matchMedia = () => ({ matches: mobile, addEventListener() {}, removeEventListener() {} });
  win.HTMLElement.prototype.scrollIntoView = function () {};
  win.CSS = { escape: (value: string) => value.replace(/[^a-zA-Z0-9_-]/g, (char: string) => String.fromCharCode(92) + char) };
  const keys = ['window', 'document', 'HTMLElement', 'Node', 'KeyboardEvent', 'MouseEvent', 'localStorage', 'CSS'] as const;
  const saved = new Map(keys.map((key) => [key, (globalThis as any)[key]]));
  const savedFetch = globalThis.fetch;
  const savedAct = (globalThis as any).IS_REACT_ACT_ENVIRONMENT;
  for (const key of keys) (globalThis as any)[key] = key === 'window' ? win : key === 'document' ? win.document : win[key];
  (globalThis as any).IS_REACT_ACT_ENVIRONMENT = true;
  globalThis.fetch = async () => new Response(JSON.stringify({ data: { affected_instances: 1 } }), { status: 200 });
  const { act } = await import('react');
  const { createRoot } = await import('react-dom/client');
  const { Provider } = await import('react-redux');
  const { FleetBridgeEditor } = await import('../src/ui/components/home/FleetBridgeEditor.tsx');
  const { heimdallApi } = await import('../src/ui/api/heimdallApi.ts');
  const store = await makeVaultStore();
  const root = createRoot(win.document.getElementById('root'));
  const runtime = { provider: 'codex', model: 'm1' };
  const settings = { bridge_id: 'b1', revision: 1, default_runtime: runtime, overrides: [{ agent_id: 'a', runtime }] };
  const bridge = { id: 'b1', label: 'First', os: 'Linux', agents: 1, online: true, provider: 'codex', model: 'm1', overrides: [] };
  const catalog = [{ provider: 'codex', models: ['m1', 'm2'] }, { provider: 'codex', profile_id: 'second-account', label: 'Codex second account', models: ['x1', 'x2'] }];
  const agents = [{ agent_id: 'a', name: 'Worker' }, { agent_id: 'b', name: 'Reviewer' }];
  let applies = 0;
  let retries = 0;
  let refreshes = 0;
  const props: any = { bridge, settings, catalog, agents,
    onApply: async () => { applies++; throw new Error('Controlled Apply failure'); },
    onRetry: async () => { retries++; }, onRefreshApplication: () => { refreshes++; } };
  const render = () => act(async () => root.render(React.createElement(Provider, { store },
    React.createElement(React.Fragment, null, React.createElement(FleetBridgeEditor, props),
      React.createElement(FleetBridgeEditor, { ...props, bridge: { ...bridge, id: 'b2', label: 'Second' }, settings: { ...settings, bridge_id: 'b2' } })))));
  const get = (id: string) => win.document.querySelector(`[data-debug-id="${id}"]`) as HTMLElement;
  const click = (id: string) => act(async () => get(id).click());
  const settle = () => act(async () => { await new Promise((resolve) => setTimeout(resolve, 50)); });
  try {
    await render(); await settle();
    const panel = get('home-fleet-body-b1');
    const panelId = panel.id;
    assert.equal(get('home-fleet-expand-b1').getAttribute('aria-controls'), panelId);
    assert.equal(panel.getAttribute('aria-hidden'), 'true');
    assert.equal(panel.hasAttribute('inert'), true);
    assert.ok(panel.contains(get('home-fleet-apply-b1')));
    assert.ok(panel.contains(get('home-fleet-reset-b1')));
    assert.equal(panel.contains(get('home-fleet-default-b1-model')), false);
    await click('home-fleet-expand-b1');
    assert.equal(panel.hasAttribute('inert'), false);
    assert.equal(get('home-fleet-expand-b2').getAttribute('aria-expanded'), 'false');
    await click('home-fleet-add-override-b1');
    await click('home-fleet-override-b1-b-model');
    await act(async () => ([...win.document.querySelectorAll('[role="option"]')].find((o: any) => o.textContent === 'm2') as HTMLElement).click());
    await settle();
    await click('home-fleet-apply-b1');
    assert.equal(applies, 1);
    assert.match(get('home-fleet-error-b1').textContent!, /Controlled Apply failure/);
    // A programmatic collapse while a portalled Select is open clears that popup,
    // returns focus, and keeps its edited value in the parent draft.
    await click('home-fleet-override-b1-b-model');
    if (!mobile) get('home-fleet-override-b1-b-model').focus();
    assert.ok(win.document.querySelector('[role="listbox"]'));
    await click('home-fleet-expand-b1');
    assert.equal(win.document.activeElement, get('home-fleet-expand-b1'));
    assert.equal(win.document.querySelector('[role="listbox"]'), null);
    assert.equal(panel.hasAttribute('inert'), true);
    await click('home-fleet-expand-b1');
    assert.equal(get('home-fleet-body-b1'), panel);
    assert.equal(panel.id, panelId);
    assert.match(get('home-fleet-override-b1-b-model').textContent!, /m2/);
    assert.match(get('home-fleet-error-b1').textContent!, /Controlled Apply failure/);
    props.application = { application_id: 'app', state: 'partial_failure', settings_saved: true, settings_revision: 1, targets: [
      { agent_id: 'a', agent_instance_id: 'i', state: 'failed', retryable: true, error_message: 'Controlled restart failure' },
    ] };
    props.applicationError = 'Controlled status error';
    await render();
    const result = get('home-fleet-result-b1');
    for (const id of ['home-fleet-result-b1', 'home-fleet-target-i', 'home-fleet-error-b1', 'home-fleet-retry-b1', 'home-fleet-status-refresh-b1']) assert.ok(panel.contains(get(id)), id);
    await click('home-fleet-expand-b1'); await click('home-fleet-expand-b1');
    assert.equal(get('home-fleet-result-b1'), result);
    assert.match(result.textContent!, /Controlled restart failure/);
    assert.deepEqual({ applies, retries, refreshes }, { applies: 1, retries: 0, refreshes: 0 });
    await click('home-fleet-expand-b1');
    win.history.replaceState(null, '', '/?widget=fleet&bridge=b1&agent=b');
    await render();
    assert.equal(get('home-fleet-expand-b1').getAttribute('aria-expanded'), 'true');
    assert.equal(panel.hasAttribute('inert'), false);
    assert.equal(win.document.activeElement, get('home-fleet-override-b1-b-agent'));
    assert.equal(get('home-fleet-expand-b2').getAttribute('aria-expanded'), 'false');
    await click('home-fleet-expand-b1');
    assert.equal(get('home-fleet-expand-b1').getAttribute('aria-expanded'), 'false', 'route focus does not lock the disclosure open');
    // Every field category shares sheet presentation, profile identity and draft-only changes.
    const choose = async (id: string, label: string) => {
      await click(id);
      assert.equal(!!win.document.querySelector('[role="dialog"][aria-modal="true"]'), mobile);
      const list = win.document.querySelector('[role="listbox"]');
      if (mobile) assert.equal(win.document.activeElement, list);
      await act(async () => ([...list.querySelectorAll('[role="option"]')].find((o: any) => o.textContent === label) as HTMLElement).click());
      await act(async () => { win.document.querySelector('[role="dialog"]')?.dispatchEvent(new win.Event('animationend', { bubbles: true })); });
    };
    await choose('home-fleet-default-b1-provider', 'Codex second account');
    assert.match(get('home-fleet-default-b1-model').textContent!, /x1/, 'provider/profile change resets model');
    await choose('home-fleet-default-b1-model', 'x2');
    await click('home-fleet-expand-b1');
    await choose('home-fleet-override-b1-b-provider', 'Codex second account');
    await choose('home-fleet-override-b1-b-model', 'x2');
    await choose('home-fleet-override-b1-a-agent', 'Worker');
    assert.equal(applies, 1, 'choices never Apply implicitly');
    await click('home-fleet-default-b1-model');
    await click('home-fleet-expand-b1');
    assert.equal(win.document.querySelector('[role="listbox"]'), null, 'collapse clears default as well as override choices');
    assert.equal(win.document.body.style.overflow, '');
    assert.match(get('home-fleet-default-b1-model').textContent!, /x2/, 'collapse keeps selected draft');
  } finally {
    await act(async () => root.unmount());
    store.dispatch(heimdallApi.util.resetApiState());
    dom.window.close();
    for (const [key, value] of saved) (globalThis as any)[key] = value;
    globalThis.fetch = savedFetch;
    (globalThis as any).IS_REACT_ACT_ENVIRONMENT = savedAct;
  }
});
