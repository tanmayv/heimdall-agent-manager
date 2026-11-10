// R4b: creating a chain defaults to the user's online owner Bridge (a signed
// chain.create with a device-signed genesis through the owner relay). Chains
// are Bridge-owned only: there is no Hub placement. Creating a chain also
// starts its coordinator: once the chain is in the owner registry, the chosen
// agent (the coordinator agent by default) launches chain-bound on the owner
// Bridge and is bound with chain.member.set.
//
// RUN: node --import ./tests/helpers/vaultEndpointHarness.ts --test tests/ui_owner_chain_create_test.ts

import { test } from 'node:test';
import assert from 'node:assert/strict';
import React from 'react';
import { JSDOM } from 'jsdom';
import { makeVaultStore } from './helpers/vaultEndpointHarness.ts';
import { fakeOwner, ownerTestSession, registryRow, type OwnerCall } from './helpers/ownerFakeRelay.ts';
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

async function renderModal(bridgeStatus: string, bridgesReady: Promise<void> = Promise.resolve(), coordinator: { launchFails?: boolean } = {}) {
  const env = await ownerTestSession('brg_home', 'Home Bridge');
  const calls: OwnerCall[] = [];
  const hubPosts: string[] = [];
  // One ordered log of owner commands, registry reads and Hub coordinator calls.
  const log: string[] = [];
  const relay = fakeOwner(env.session, (call) => { log.push('owner:' + call.method); return { chain_id: call.command.chain_id, task_id: '', revision: '1' }; }, calls);
  let registryReads = 0;
  const registryPage = async () => {
    registryReads += 1;
    // The first read predates the owner's registry publish.
    const chainId = calls.find((c) => c.method === 'chain.create')?.command.chain_id;
    const listed = Boolean(chainId) && registryReads > 1;
    log.push(listed ? 'registry:listed' : 'registry:missing');
    return { items: listed ? [await registryRow(env.session, { chainId: chainId!, bridgeId: 'brg_home', online: true })] : [], next_cursor: { after_chain: '', after_task: '' }, terminal: true };
  };
  const coordinatorApi = {
    listAgents: async () => [{ agentId: 'agt_solo', name: 'Soloist', slug: 'soloist' }, { agentId: 'agt_coord', name: 'Coordinator', slug: 'coordinator' }],
  };
  // POST /chats bodies: the one request that creates the chain and its coordinator.
  const chats: any[] = [];
  const saved = globalThis.fetch;
  globalThis.fetch = (async (input: any, init: any = {}) => {
    const u = new URL(String(input?.url ?? input), 'http://localhost');
    const method = String(init?.method || 'GET').toUpperCase();
    const ok = (data: unknown) => new Response(JSON.stringify({ data }), { status: 200, headers: { 'Content-Type': 'application/json' } });
    if (method !== 'GET') hubPosts.push(method + ' ' + u.pathname);
    if (u.pathname === '/api/v1/bridges') return bridgesReady.then(() => ok([{ bridge_id: 'brg_home', label: 'Home Bridge', status: bridgeStatus }]));
    if (u.pathname === '/api/v1/vault/directory') return ok(env.hub.dir());
    if (u.pathname === '/api/v1/owner-local/relay') return ok(await relay(JSON.parse(init.body)));
    if (u.pathname === '/api/v1/owner-local/chains') return ok(await registryPage());
    if (u.pathname === '/api/v1/chats' && method === 'POST') {
      chats.push(JSON.parse(init.body));
      log.push('chats');
      if (coordinator.launchFails) {
        const failure = JSON.stringify({ error: { code: 'vault_locked', message: 'the Bridge could not create the task chain: the owner Bridge vault is locked' } });
        return new Response(failure, { status: 423, headers: { 'Content-Type': 'application/json' } });
      }
      return ok({ conversation_id: 'conv_new', agent_instance_id: 'inst_coord', chain_id: 'chain_new' });
    }
    if (u.pathname === '/api/v1/agent-instances/inst_coord') return ok({ agent_instance_id: 'inst_coord', chain_id: 'chain_new' });
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
      coordinatorApi,
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
  const advancedToggle = () => container.querySelector('button[aria-controls="create-chain-advanced"]') as HTMLButtonElement | null;
  const openAdvanced = async () => {
    if (advancedToggle()?.getAttribute('aria-expanded') === 'true') return;
    await act(async () => { advancedToggle()!.click(); });
  };
  return { env, calls, hubPosts, created, log, chats, $, typeTitle, submit, submitButton, settle, cleanup, container, advancedToggle, openAdvanced };
}

test('the create modal defaults to the owner Bridge and creates there with a signed genesis', async () => {
  const ui = await renderModal('online');
  try {
    // Title + Description by default; the defaulted placement and coordinator wait under Advanced.
    assert.equal(ui.advancedToggle()!.getAttribute('aria-expanded'), 'false', 'Advanced starts closed');
    assert.equal(ui.$('create-chain-advanced'), null);
    assert.equal(ui.$('create-chain-coordinator-agent'), null);
    assert.match(ui.advancedToggle()!.closest('section')!.textContent!, /Advanced.*·.*Coordinator/s, 'the closed Advanced names its defaults');
    await ui.openAdvanced();
    assert.equal(ui.$('create-chain-placement-bridge-brg_home-input')!.checked, true, 'the online owner Bridge is the default');
    assert.equal(ui.$('create-chain-placement-hub'), null, 'there is no Hub placement');

    assert.equal((ui.container.querySelector('input[name="coordinator_agent"]') as HTMLInputElement).value, 'agt_coord', 'the coordinator agent is the default');
    assert.match(ui.$('create-chain-coordinator-agent')!.textContent!, /Coordinator/);

    await ui.typeTitle('Bridge-first chain');
    await ui.submit();
    assert.deepEqual(ui.log, ['chats'], 'one request: no owner relay, registry wait, bind or restart');
    assert.equal(ui.calls.length, 0, 'the app signs no owner command');
    const [post] = ui.chats;
    assert.deepEqual({ agent: post.agent_id, bridge: post.bridge_id, create: post.create_owner_chain, chain: post.chain_id },
      { agent: 'agt_coord', bridge: 'brg_home', create: true, chain: undefined });
    assert.equal(await decryptVaultText(post.chain_title, ui.env.session.keyring), 'Bridge-first chain', 'the title travels sealed');
    assert.ok(!ui.hubPosts.some((p) => p.endsWith('/task-chains')), 'nothing is created on the Hub chain API');

    assert.equal(ui.created.length, 1);
    assert.equal(ui.created[0].id, 'chain_new', 'navigation targets the new owner chain');
    assert.equal(ui.created[0].owner.ownerBridgeId, 'brg_home');
    assert.equal(ui.created[0].owner.pending, true);
    assert.equal(ui.created[0].owner.coordinatorAgentInstanceId, 'inst_coord');
  } finally {
    await ui.cleanup();
  }
});

test('a refused chain shows the Bridge error and creates nothing', async () => {
  const ui = await renderModal('online', Promise.resolve(), { launchFails: true });
  try {
    await ui.typeTitle('Refused');
    await ui.submit();
    assert.equal(ui.chats.length, 1);
    assert.equal(ui.created.length, 0);
    assert.match(ui.$('create-chain-error')!.textContent!, /vault is locked/);
    assert.equal(ui.submitButton().textContent, 'Create chain', 'the user can retry');
  } finally {
    await ui.cleanup();
  }
});

test('with no online owner Bridge the modal cannot create and says why', async () => {
  const ui = await renderModal('offline');
  try {
    assert.ok(ui.$('create-chain-advanced'), 'Advanced opens itself to say why the placement cannot be used');
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
    await ui.openAdvanced();
    assert.equal(ui.$('create-chain-placement-bridge-brg_home-input')!.checked, true);
    await ui.submit();
    assert.equal(ui.chats.length, 1, 'created once the placement is known');
    assert.equal(ui.chats[0].bridge_id, 'brg_home');
  } finally {
    await ui.cleanup();
  }
});
