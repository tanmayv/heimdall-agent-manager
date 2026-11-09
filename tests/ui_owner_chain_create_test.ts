// R4b: creating a chain defaults to the user's online owner Bridge (a signed
// chain.create with a device-signed genesis through the owner relay). Chains
// are Bridge-owned only: there is no Hub placement.
//
// RUN: node --import ./tests/helpers/vaultEndpointHarness.ts --test tests/ui_owner_chain_create_test.ts

import { test } from 'node:test';
import assert from 'node:assert/strict';
import React from 'react';
import { JSDOM } from 'jsdom';
import { makeVaultStore } from './helpers/vaultEndpointHarness.ts';
import { fakeOwner, ownerTestSession, type OwnerCall } from './helpers/ownerFakeRelay.ts';
import { decryptVaultText } from '../src/ui/utils/vaultContent.ts';
import { clearKeyringSession } from '../src/ui/utils/vaultKeyringSession.ts';
import { ownerParse } from '../src/ui/api/ownerLocal.ts';
import { defaultChainPlacement, ownerBridgeChoices } from '../src/ui/api/ownerChains.ts';

// React DOM fixes its event support when first loaded: build the DOM first.
const dom = new JSDOM('<!DOCTYPE html><html><body></body></html>', { url: 'http://localhost/', pretendToBeVisual: true });
const win = dom.window as any;
win.matchMedia = (q: string) => ({ matches: false, media: q, addEventListener() {}, removeEventListener() {}, addListener() {}, removeListener() {} });
const raf = (cb: any) => setTimeout(cb, 0), caf = (id: any) => clearTimeout(id);
win.requestAnimationFrame = raf; win.cancelAnimationFrame = caf;
for (const [key, value] of Object.entries({ window: win, document: win.document, navigator: win.navigator, HTMLElement: win.HTMLElement, Node: win.Node,
  requestAnimationFrame: raf, cancelAnimationFrame: caf, IS_REACT_ACT_ENVIRONMENT: true })) {
  Object.defineProperty(globalThis, key, { value, writable: true, configurable: true });
}
const { createRoot } = await import('react-dom/client');
const { act } = await import('react');
const { Provider } = await import('react-redux');
const { CreateChainModal } = await import('../src/ui/components/taskchain/CreateChainModal.tsx');
const { heimdallApi } = await import('../src/ui/api/heimdallApi.ts');

test('placement defaults to an online enrolled Bridge, otherwise the first enrolled one', async () => {
  const env = await ownerTestSession('brg_home', 'Home Bridge');
  const chain = env.session.chain;
  const online = ownerBridgeChoices(chain, [{ bridge_id: 'brg_home', status: 'online', label: 'Home' }]);
  assert.deepEqual(online, [{ bridgeId: 'brg_home', name: 'Home', online: true }]);
  assert.equal(defaultChainPlacement(online), 'brg_home');
  const offline = ownerBridgeChoices(chain, [{ bridge_id: 'brg_home', status: 'offline' }]);
  assert.equal(offline[0].name, 'Home Bridge', 'falls back to the enrolled device label');
  assert.equal(defaultChainPlacement(offline), 'brg_home');
  assert.deepEqual(ownerBridgeChoices(chain, [{ bridge_id: 'brg_other', status: 'online' }]).map((c) => c.online), [false], 'only enrolled Bridges can own chains');
  assert.equal(defaultChainPlacement([]), '');
  clearKeyringSession();
});

async function renderModal(bridgeStatus: string, bridgesReady: Promise<void> = Promise.resolve()) {
  const env = await ownerTestSession('brg_home', 'Home Bridge');
  const calls: OwnerCall[] = [];
  const hubPosts: string[] = [];
  const relay = fakeOwner(env.session, (call) => ({ chain_id: call.command.chain_id, task_id: '', revision: '1' }), calls);
  const saved = globalThis.fetch;
  globalThis.fetch = (async (input: any, init: any = {}) => {
    const u = new URL(String(input?.url ?? input), 'http://localhost');
    const method = String(init?.method || 'GET').toUpperCase();
    const ok = (data: unknown) => new Response(JSON.stringify({ data }), { status: 200, headers: { 'Content-Type': 'application/json' } });
    if (method !== 'GET') hubPosts.push(method + ' ' + u.pathname);
    if (u.pathname === '/api/v1/bridges') return bridgesReady.then(() => ok([{ bridge_id: 'brg_home', label: 'Home Bridge', status: bridgeStatus }]));
    if (u.pathname === '/api/v1/vault/directory') return ok(env.hub.dir());
    if (u.pathname === '/api/v1/owner-local/relay') return ok(await relay(JSON.parse(init.body)));
    return ok({});
  }) as typeof fetch;
  const store = await makeVaultStore();
  const container = win.document.createElement('div');
  win.document.body.appendChild(container);
  const root = createRoot(container);
  const created: Array<{ id: string; owner: any }> = [];
  const settle = async () => { for (let i = 0; i < 30; i++) await act(async () => { await new Promise((r) => setTimeout(r, 3)); }); };
  await act(async () => {
    root.render(React.createElement(Provider, { store }, React.createElement(CreateChainModal, {
      isOpen: true, onClose: () => {},
      onCreated: (id: string, owner?: any) => { created.push({ id, owner }); },
    })));
  });
  await settle();
  const $ = (id: string) => container.querySelector(`[data-debug-id="${id}"]`) as HTMLInputElement | null;
  const typeTitle = async (value: string) => {
    const input = container.querySelector('input[type="text"]') as HTMLInputElement;
    const setter = Object.getOwnPropertyDescriptor(win.HTMLInputElement.prototype, 'value')!.set!;
    await act(async () => { setter.call(input, value); input.dispatchEvent(new win.Event('input', { bubbles: true })); });
  };
  const submitButton = () => container.querySelector('button[type="submit"]') as HTMLButtonElement;
  const submit = async () => {
    const button = container.querySelector('button[type="submit"]') as HTMLButtonElement;
    assert.equal(button.disabled, false);
    await act(async () => { button.click(); });
    await settle();
  };
  const cleanup = async () => {
    await act(async () => root.unmount());
    store.dispatch(heimdallApi.util.resetApiState());
    container.remove();
    globalThis.fetch = saved;
    clearKeyringSession();
  };
  return { env, calls, hubPosts, created, $, typeTitle, submit, submitButton, settle, cleanup, container };
}

test('the create modal defaults to the owner Bridge and creates there with a signed genesis', async () => {
  const ui = await renderModal('online');
  try {
    assert.equal(ui.$('create-chain-placement-bridge-brg_home-input')!.checked, true, 'the online owner Bridge is the default');
    assert.equal(ui.$('create-chain-placement-hub'), null, 'there is no Hub placement');

    await ui.typeTitle('Bridge-first chain');
    await ui.submit();
    assert.equal(ui.calls.length, 1);
    const call = ui.calls[0];
    assert.equal(call.method, 'chain.create');
    assert.equal(call.command.immutable_owner_bridge, 'brg_home');
    const genesis = ownerParse(call.genesis, 'genesis');
    assert.equal(genesis.owner_bridge_id, 'brg_home');
    assert.equal(genesis.chain_id, call.command.chain_id);
    assert.notEqual(genesis.creator_signature, '0'.repeat(128), 'the genesis is device-signed');
    assert.equal(await decryptVaultText(call.payload.title_cipher, ui.env.session.keyring), 'Bridge-first chain');
    assert.ok(!ui.hubPosts.some((p) => p.endsWith('/task-chains')), 'nothing is created on the Hub');
    assert.equal(ui.created.length, 1);
    assert.equal(ui.created[0].id, call.command.chain_id, 'navigation targets the new owner chain');
    assert.equal(ui.created[0].owner.ownerBridgeId, 'brg_home');
    assert.equal(ui.created[0].owner.pending, true);
  } finally {
    await ui.cleanup();
  }
});

test('with no online owner Bridge the modal cannot create and says why', async () => {
  const ui = await renderModal('offline');
  try {
    assert.equal(ui.$('create-chain-placement-hub'), null);
    assert.equal(ui.$('create-chain-placement-bridge-brg_home-input')!.disabled, true);
    assert.match(ui.$('create-chain-placement-note')!.textContent!, /None of your enrolled Bridges is online/);
    await ui.typeTitle('Nowhere');
    assert.equal(ui.submitButton().disabled, true, 'nothing can be created without an online Bridge');
  } finally {
    await ui.cleanup();
  }
});

test('a fast submit cannot create while the Bridges are still being checked', async () => {
  let release!: () => void;
  const ui = await renderModal('online', new Promise<void>((r) => { release = r; }));
  try {
    await ui.typeTitle('Too quick');
    assert.equal(ui.submitButton().disabled, true, 'submit waits for the placement default');
    await ui.settle();
    release();
    await ui.settle();
    assert.equal(ui.$('create-chain-placement-bridge-brg_home-input')!.checked, true);
    await ui.submit();
    assert.equal(ui.calls[0]?.method, 'chain.create');
    assert.ok(!ui.hubPosts.some((p) => p.endsWith('/task-chains')));
  } finally {
    await ui.cleanup();
  }
});
