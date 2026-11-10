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
    launch: async (input: { agentId: string; chainId: string; bridgeId: string }) => {
      log.push(`launch:${input.agentId}:${input.chainId}:${input.bridgeId}`);
      if (coordinator.launchFails) throw new Error('No provider is available.');
      return 'inst_coord';
    },
    status: async (id: string) => { log.push('status:' + id); return 'running'; },
    restart: async (id: string) => { log.push('restart:' + id); },
  };
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
      coordinatorApi, registryWait: { sleep: async () => {} },
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
  return { env, calls, hubPosts, created, log, $, typeTitle, submit, submitButton, settle, cleanup, container };
}

test('the create modal defaults to the owner Bridge and creates there with a signed genesis', async () => {
  const ui = await renderModal('online');
  try {
    assert.equal(ui.$('create-chain-placement-bridge-brg_home-input')!.checked, true, 'the online owner Bridge is the default');
    assert.equal(ui.$('create-chain-placement-hub'), null, 'there is no Hub placement');

    assert.equal((ui.container.querySelector('input[name="coordinator_agent"]') as HTMLInputElement).value, 'agt_coord', 'the coordinator agent is the default');
    assert.match(ui.$('create-chain-coordinator-agent')!.textContent!, /Coordinator/);

    await ui.typeTitle('Bridge-first chain');
    await ui.submit();
    const call = ui.calls[0];
    assert.equal(call.method, 'chain.create');
    assert.equal(call.command.immutable_owner_bridge, 'brg_home');
    const genesis = ownerParse(call.genesis, 'genesis');
    assert.equal(genesis.owner_bridge_id, 'brg_home');
    assert.equal(genesis.chain_id, call.command.chain_id);
    assert.notEqual(genesis.creator_signature, '0'.repeat(128), 'the genesis is device-signed');
    assert.equal(await decryptVaultText(call.payload.title_cipher, ui.env.session.keyring), 'Bridge-first chain');
    assert.ok(!ui.hubPosts.some((p) => p.endsWith('/task-chains')), 'nothing is created on the Hub');

    // The coordinator: launched chain-bound on the owner Bridge only once the
    // chain is listed, bound when running, then relaunched with the role.
    const chainId = call.command.chain_id;
    assert.deepEqual(ui.log, [
      'owner:chain.create', 'registry:missing', 'registry:listed', `launch:agt_coord:${chainId}:brg_home`, 'status:inst_coord',
      'owner:chain.metadata.read', 'owner:chain.read', 'owner:chain.member.set', 'restart:inst_coord', 'status:inst_coord',
    ]);
    const bind = ui.calls.find((c) => c.method === 'chain.member.set')!;
    assert.deepEqual({ chain: bind.command.chain_id, instance: bind.payload.instance_id, agent: bind.payload.agent_id, role: bind.payload.role, enabled: bind.payload.enabled },
      { chain: chainId, instance: 'inst_coord', agent: 'agt_coord', role: 'coordinator', enabled: '1' });

    assert.equal(ui.created.length, 1);
    assert.equal(ui.created[0].id, chainId, 'navigation targets the new owner chain');
    assert.equal(ui.created[0].owner.ownerBridgeId, 'brg_home');
    assert.equal(ui.created[0].owner.pending, true);
    assert.equal(ui.created[0].owner.coordinatorAgentInstanceId, 'inst_coord');
  } finally {
    await ui.cleanup();
  }
});

test('a coordinator that fails to launch leaves the created chain openable', async () => {
  const ui = await renderModal('online', Promise.resolve(), { launchFails: true });
  try {
    await ui.typeTitle('Half-made');
    await ui.submit();
    assert.equal(ui.calls.filter((c) => c.method === 'chain.create').length, 1);
    assert.equal(ui.calls.filter((c) => c.method === 'chain.member.set').length, 0, 'nothing is bound');
    assert.equal(ui.created.length, 0);
    assert.match(ui.$('create-chain-error')!.textContent!, /chain was created, but its coordinator did not start: No provider is available/);
    assert.equal(ui.submitButton().textContent, 'Open chain');
    await ui.submit();
    assert.equal(ui.created.length, 1);
    assert.equal(ui.created[0].id, ui.calls[0].command.chain_id);
    assert.equal(ui.created[0].owner.coordinatorAgentInstanceId, undefined);
    assert.equal(ui.calls.filter((c) => c.method === 'chain.create').length, 1, 'opening does not create another chain');
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
